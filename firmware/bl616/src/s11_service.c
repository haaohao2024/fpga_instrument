#include "record_observer.h"
#include "sd_lease.h"
#include "bus_fault.h"
#include "record_trace.h"
#include "record_hot.h"
#include "s11_service.h"
#include "s11_storage.h"
#include "s9_protocol.h"
#include <string.h>
#ifdef ENSEMBLE_CAPTURE_DIAG
#include "link_diag.h"
#define CAP_DIAG(k,a,b,c) link_diag_event(k,(uint32_t)(a),(uint32_t)(b),(uint32_t)(c))
#else
#define CAP_DIAG(k,a,b,c) ((void)0)
#endif

/* Bounded memcpy/memset operations used before DMA publication or after
 * physical receive retirement. Word accesses are aligned and may-alias;
 * neither routine reads/writes beyond the requested extent. */
typedef uint32_t record_alias_word __attribute__((__may_alias__));
RECORD_HOT void record_zero(void *dest,unsigned n){
 uint8_t *d=dest;
 while(n&&((uintptr_t)d&3u)){*d++=0;--n;}
 while(n>=4){*(volatile record_alias_word*)d=0;d+=4;n-=4;}
 while(n--)*d++=0;
}
RECORD_HOT void record_copy(void *dest,const void *source,unsigned n){
 uint8_t *d=dest;const uint8_t *s=source;
 if((((uintptr_t)d^(uintptr_t)s)&3u)==0){
  while(n&&((uintptr_t)d&3u)){*d++=*s++;--n;}
  while(n>=4){*(volatile record_alias_word*)d=*(const volatile record_alias_word*)s;d+=4;s+=4;n-=4;}
 }
 while(n--)*d++=*s++;
}
/* 28 KiB of the 32 KiB removed loop-token duplication becomes PCM credit. */
static uint8_t pcm[90112] __attribute__((aligned(32)));
/* File task pins a contiguous PCM ring span through synchronous FatFs/SD RPC. */
#if defined(__riscv)
/* CPU-only event ring. No DMA engine receives this address: the file task
 * copies valid cells to its existing stack page before SD RPC. Reuse the
 * same SDK WRAM BSS bank already validated for loop/phase state. */
static uint8_t events[4096] __attribute__((section(".wifi_ram.record_events"),aligned(32)));
#else
static uint8_t events[4096];
#endif
static uint32_t pcm_write,pcm_read,event_write,event_read;
static uint64_t pcm_first;
static s11_service_stats stats;
typedef struct {uint64_t millisecond;uint16_t total,sd;} occupancy;
static occupancy history[101];
static uint64_t sd_started,backlog_started;
static uint64_t card_completed,backlog_baseline;
static int strict_media_guard=1;
RECORD_HOT void s11_service_set_media_guard(int active){strict_media_guard=active!=0;}
static int sd_active;static uint32_t sd_limit;
static uint32_t next_block[2];
static uint8_t sent_ack_kind;static uint32_t sent_ack_sequence;
static uint64_t last_record_id;
/* Highest recording id the FPGA has reported. It survives an MCU-only reset
 * and accepts START only for a larger id (s11_recording_subsystem can_start). */
static uint64_t remote_record_id;
static uint8_t stop_after_start;
static volatile uint8_t ram_sink;
static uint8_t qualified_version;
void s11_service_wire_qualified(unsigned version){qualified_version=(uint8_t)version;}
static uint32_t rolling(uint64_t now,int sd);
static uint32_t pcm_pending(void){return __atomic_load_n(&pcm_write,__ATOMIC_ACQUIRE)-__atomic_load_n(&pcm_read,__ATOMIC_ACQUIRE);}
static uint32_t event_pending(void){return __atomic_load_n(&event_write,__ATOMIC_ACQUIRE)-__atomic_load_n(&event_read,__ATOMIC_ACQUIRE);}
/* Release native-capture ring credit once each complete file submission is
 * written and CRC-accounted. Media playback retains its existing 4KiB path. */
static unsigned file_quantum=8192;
int s11_service_set_file_quantum(unsigned bytes){
 if(stats.active||pcm_pending()||event_pending()||(bytes!=2048&&bytes!=4096&&bytes!=8192&&bytes!=16384))return -1;
 file_quantum=bytes;return 0;
}
void s11_service_init(void){qualified_version=0;strict_media_guard=1;memset(&stats,0,sizeof stats);memset(history,0,sizeof history);memset(next_block,0,sizeof next_block);last_record_id=0;pcm_write=pcm_read=event_write=event_read=0;sd_active=0;backlog_started=0;card_completed=0;sent_ack_kind=0;sent_ack_sequence=0;stop_after_start=0;ram_sink=0;}
uint8_t *s11_service_idle_buffer(unsigned *capacity){
 if(ram_sink||stats.active||pcm_pending()||event_pending())return 0;
 *capacity=sizeof pcm;return pcm;
}
RECORD_HOT const s11_service_stats *s11_service_statistics(void){return &stats;}
RECORD_HOT int s11_service_active(void){return stats.active;}
RECORD_HOT unsigned s11_service_receive_credit(void){
 if(!stats.active)return 0;
 if((stats.mask&S11_KIND_PCM)&&sizeof pcm-pcm_pending()<S11_BULK_PAYLOAD_BYTES)return 0;
 if((stats.mask&S11_KIND_EVENT)&&sizeof events-event_pending()<512u)return 0;
 return (stats.mask&S11_MASK_PCM)?S11_BULK_PAYLOAD_BYTES:512u;
}
int s11_service_can_start(uint64_t id,unsigned mask){
 if(bus_fault_active())return S9_E_IO;
 if(!id||!mask||(mask&~3u))return S9_E_RANGE;
 if(qualified_version!=S11_RECORD_VERSION)return S9_E_STATE;
 if(ram_sink||stats.active||pcm_pending()||event_pending())return S9_E_BUSY;
 if(id<=last_record_id)return S9_E_STALE;
 if(stats.command_sequence==UINT32_MAX)return S9_E_RANGE;
 return 0;
}
RECORD_HOT int s11_service_ram_owned(void){return ram_sink;}
uint64_t s11_service_next_id(void){uint64_t base=last_record_id>remote_record_id?last_record_id:remote_record_id;return base==UINT64_MAX?0:base+1;}
int s11_service_ram_start(uint64_t id){int r=s11_service_start(id,2);if(!r)ram_sink=1;return r;}
int s11_service_ram_caught_up(void){return ram_sink&&!pcm_pending()&&!event_pending()&&!stats.command&&!stats.ack_pending&&!stats.error;}
unsigned s11_service_ram_pop(uint8_t *out,unsigned max_cells){
 if(!ram_sink||!out)return 0;
 unsigned n=event_pending()/32;if(n>max_cells)n=max_cells;uint32_t head=event_read;
 for(unsigned i=0;i<n*32;i++)out[i]=events[(head+i)%sizeof events];
 __atomic_store_n(&event_read,head+n*32,__ATOMIC_RELEASE);stats.stored_cells+=n;stats.event_buffered=(uint16_t)event_pending();
 return n;
}
int s11_service_ram_release(void){
 if(!ram_sink)return 0;
 if(pcm_pending()||event_pending()||stats.command||stats.ack_pending||
   (stats.wire_state!=S11_CLOSED&&stats.wire_state!=S11_INCOMPLETE&&stats.wire_state!=S11_ERROR))return S9_E_BUSY;
 stats.active=0;ram_sink=0;return 0;
}
int s11_service_start(uint64_t id,unsigned mask){
 int r=s11_service_can_start(id,mask);if(r)return r;
 uint32_t seq=stats.command_sequence+1;last_record_id=id;memset(&stats,0,sizeof stats);memset(next_block,0,sizeof next_block);stats.command_sequence=seq;stats.recording_id=id;stats.mask=(uint8_t)mask;stats.command=S11_REC_START;stats.active=1;stats.first_frame=stats.last_frame=stats.missing_frame=stats.missing_event_frame=UINT64_MAX;pcm_write=pcm_read=event_write=event_read=0;backlog_started=0;stop_after_start=0;return 0;
}
int s11_service_stop(uint64_t id){if(id!=stats.recording_id)return S9_E_STALE;if(!stats.active)return 0;if(stats.command==S11_REC_STOP||stop_after_start)return 0;if(stats.command_sequence==UINT32_MAX)return S9_E_RANGE;
 /* The remote does not yet know a newly prepared rid. Preserve START until
  * its explicit accepted fence; STOP may not replace an in-flight START. */
 if(stats.command==S11_REC_START){stop_after_start=1;return 0;}
 stop_after_start=2;
 stats.command_sequence++;stats.command=S11_REC_STOP;return 0;
}
uint32_t s11_service_command_target(void){return stats.command_sequence+(stop_after_start==1);}
void s11_service_fail(int reason,uint64_t missing){if(!stats.error){CAP_DIAG(18,reason,stats.wire_state,stats.received_cells);stats.error=(uint8_t)(reason?reason:S11_E_SERVICE);stats.missing_frame=missing;stats.service_violations++;(void)s11_service_stop(stats.recording_id);}}
void s11_service_bus_abort(void){
 if(!bus_fault_active()||!stats.active)return;
 if(!stats.error)stats.error=S11_E_STORAGE;
 stats.remote_stop_unconfirmed=1;
 if(!ram_sink)s11_storage_bus_abort();
 /* Local lifecycle ends; keep actual remote wire state, queued command,
  * ACK and buffers as evidence. A fatal bus cannot confirm remote STOP. */
 stats.active=0;
}
RECORD_HOT unsigned s11_service_request_mode(uint8_t p[S11_WIRE_BYTES],const uint8_t *media,unsigned length,unsigned reverse_capacity){
 unsigned data_payload=0;unsigned requested=reverse_capacity==S11_BULK_PAYLOAD_BYTES?S11_BULK_WIRE_BYTES:S11_WIRE_BYTES;record_zero(p,requested);record_copy(p,"S11P",4);p[4]=S11_RECORD_VERSION;
 if(media&&length>=36){record_copy(p+5,media+5,27);unsigned n=s9_get16(media+6);if(media[5]==S11_MEDIA_DATA&&n<=128&&length>=36+4*n){record_copy(p+64,media+32,4*n);data_payload=n!=0;}}
 s9_put64(p+32,stats.recording_id);p[40]=stats.command;p[41]=stats.mask;p[42]=stats.ack_kind;s9_put32(p+44,stats.command_sequence);s9_put32(p+48,stats.ack_sequence);
 if(!stats.command&&stats.ack_kind)p[40]=S11_REC_ACK;
 unsigned wire=reverse_capacity==0&&(p[5]==S11_MEDIA_NOP||p[5]==S11_MEDIA_STATUS)&&s9_get16(p+6)==0&&(p[40]==S11_REC_ACK||p[40]==S11_REC_QUERY)?68:requested;
 s9_put16(p+52,(uint16_t)(wire==68?0:wire-68));s9_put32(p+60,s9_crc32(p,60));s9_put32(p+wire-4,wire==68?UINT32_C(0x2144df1c):data_payload?s9_crc32(p,wire-4):wire==S11_BULK_WIRE_BYTES?UINT32_C(0xe80f8923):UINT32_C(0xac727b17));stats.wire_transactions++;
 sent_ack_kind=p[42];sent_ack_sequence=s9_get32(p+48);return wire;
}
void s11_service_request(uint8_t p[S11_WIRE_BYTES],const uint8_t *media,unsigned length){(void)s11_service_request_mode(p,media,length,512);}
RECORD_HOT int s11_service_response_bytes(const uint8_t *p,unsigned length){
 if((length!=68&&length!=580&&length!=S11_BULK_WIRE_BYTES)||memcmp(p,"S7ST",4)||p[4]!=S11_RECORD_VERSION||s9_get32(p+60)!=s9_crc32(p,60)||s9_get32(p+length-4)!=(length==68?UINT32_C(0x2144df1c):~s9_crc32_update(UINT32_C(0xdebb20e3),p+64,length-68)))return S9_E_CRC;
 uint64_t remote=s9_get64(p+24);if(remote>remote_record_id)remote_record_id=remote;
 if(remote!=stats.recording_id){
  /* An unaccepted internal RAM-sink START below the FPGA's id would be retried
   * forever; move it past that id. App recordings keep their own ids. */
  if(ram_sink&&stats.command==S11_REC_START&&!stats.last_command&&remote>=stats.recording_id&&remote!=UINT64_MAX)stats.recording_id=last_record_id=remote+1;
  return S9_E_STALE;
 }
 stats.wire_state=p[6];stats.last_command=s9_get32(p+32);
 if(stats.last_command==stats.command_sequence)stats.command=0;
 if(stop_after_start==1&&!stats.command){stop_after_start=2;stats.command_sequence++;stats.command=S11_REC_STOP;}
 unsigned first_fault=(p[7]&2)&&!stats.error;
 if(first_fault){CAP_DIAG(19,s9_get32(p+52),p[6],s9_get32(p+40));stats.error=(uint8_t)s9_get32(p+52);if(!stats.error)stats.error=S11_E_STORAGE;}
 if((p[7]&3)==2){if(p[7]&4)stats.missing_event_frame=s9_get64(p+40);else stats.missing_frame=s9_get64(p+40);}
 /* Either recorder fault stops the pair of requested recorders. The FPGA
  * still drains its valid prefix under DRAINING+incomplete; no closed file
  * is produced until the explicit terminal state and final ACK fence. */
 if(first_fault&&stats.active&&(stats.wire_state==S11_CAPTURING||stats.wire_state==S11_DRAINING)){
  int r=s11_service_stop(stats.recording_id);if(r)return r;
 }
 /* A short transaction carries the immutable header, not its advertised
  * block payload. It only retires our matching ACK after a valid wire fence. */
 if(length==68){if(sent_ack_kind==stats.ack_kind&&sent_ack_sequence==stats.ack_sequence)stats.ack_pending=0;return 0;}
 if(!(p[7]&1))return 0;
 unsigned kind=p[22],bytes=s9_get16(p+48),items=s9_get16(p+50);uint32_t seq=s9_get32(p+36);uint64_t first=s9_get64(p+40);
 if((kind!=S11_KIND_PCM&&kind!=S11_KIND_EVENT)||bytes>(kind==S11_KIND_PCM?S11_BULK_PAYLOAD_BYTES:512u)||!bytes||!(stats.mask&kind)||bytes!=(kind==1?items*4:items*32))return S9_E_FORMAT;
 /* A legacy forward-media packet can report a larger pinned block.
  * Its prefix is not a complete block: never publish or ACK it. */
 if(bytes>length-68)return 0;
 unsigned index=kind-1;
 if(next_block[index]&&seq==next_block[index]-1){stats.duplicate_blocks++;stats.ack_sequence=seq;stats.ack_kind=(uint8_t)kind;stats.ack_pending=1;return 0;}
 if(seq!=next_block[index])return S9_E_SEQUENCE;
 if(kind==S11_KIND_PCM){
  if(first>UINT64_MAX-(items-1))return S9_E_RANGE;
  if(bytes>sizeof pcm-pcm_pending())return S9_E_BUSY;
  if(stats.received_pcm&&first!=stats.last_frame+1){s11_service_fail(S11_E_SEQUENCE,first);return S9_E_SEQUENCE;}

  if(!stats.received_pcm)stats.first_frame=first;
  stats.last_frame=first+items-1;stats.received_pcm+=items;
  uint32_t tail=pcm_write;unsigned at=tail%sizeof pcm,n=sizeof pcm-at;if(n>bytes)n=bytes;record_copy(pcm+at,p+64,n);record_copy(pcm,p+64+n,bytes-n);__atomic_store_n(&pcm_write,tail+bytes,__ATOMIC_RELEASE);
 }else{if(bytes>sizeof events-event_pending())return S9_E_BUSY;uint32_t tail=event_write;unsigned at=tail%sizeof events,n=sizeof events-at;if(n>bytes)n=bytes;record_copy(events+at,p+64,n);record_copy(events,p+64+n,bytes-n);stats.received_cells+=items;__atomic_store_n(&event_write,tail+bytes,__ATOMIC_RELEASE);}
 next_block[index]++;stats.block_sequence++;stats.ack_sequence=seq;stats.ack_kind=(uint8_t)kind;stats.ack_pending=1;stats.pcm_buffered=(uint32_t)pcm_pending();stats.event_buffered=(uint16_t)event_pending();return 0;
}
int s11_service_response(const uint8_t p[S11_WIRE_BYTES]){return s11_service_response_bytes(p,580);}
/* Ring bytes (4 per stereo pair) up to the next file quantum boundary; the
 * file stores S11_FILE_BYTES_PER_PAIR per pair after the 512-byte header. */
#define EVENT_DRAIN_PAGES 9u
static unsigned native_target(unsigned quantum){
 unsigned file=quantum-(unsigned)((512u+stats.stored_pcm*S11_FILE_BYTES_PER_PAIR)%quantum);
 return file/S11_FILE_BYTES_PER_PAIR*4u;
}
int s11_service_file_ready(int media){
 if(ram_sink||bus_fault_active()||!stats.active)return 0;
 unsigned quantum=media?4096u:file_quantum,index=pcm_read%sizeof pcm;
 unsigned target=media?4096u:native_target(quantum);
 if(target>sizeof pcm-index)target=sizeof pcm-index;
 unsigned pending=pcm_pending();
 return event_pending()||(pending&&(pending>=target||stats.wire_state!=S11_CAPTURING));
}
int s11_service_file_step(int media){
 if(bus_fault_active()){s11_service_bus_abort();return S9_E_IO;}
 if(ram_sink)return 0;
 int r=0;
 /* The synchronous file call owns this ring span until both SD IO and
  * file CRC finish. Do not return receive credit while FatFs/RPC uses it.
  * Native PCM batches end at the configured file boundary (512-byte WAV header).
  * External media retains the smaller service quantum. Physical ring wrap
  * can shorten a batch; waiting for a full 16KiB across wrap would deadlock. */
 /* Events first, and the whole ring: receive credit needs 512 free event
  * bytes, so a burst left behind PCM blocked every FPGA read (PCM included)
  * until the SD grant was refused. A page is 15 cells/512 B; 9 pages cover
  * the 128-cell ring. */
 for(unsigned pages=0;!r&&event_pending()&&pages<EVENT_DRAIN_PAGES;pages++){
  uint8_t b[480];unsigned n=event_pending();if(n>sizeof b)n=sizeof b;
  uint32_t head=event_read;for(unsigned i=0;i<n;i++)b[i]=events[(head+i)%sizeof events];
  record_observer_phase(OBS_FILE,OBS_EVENT);r=s11_storage_events(stats.recording_id,b,n/32);
  if(!r){__atomic_store_n(&event_read,head+n,__ATOMIC_RELEASE);stats.stored_cells+=n/32;record_observer_progress(OBS_FILE,(uint32_t)stats.stored_cells);}
 }
 uint32_t head=__atomic_load_n(&pcm_read,__ATOMIC_ACQUIRE);
 unsigned index=head%sizeof pcm;
 unsigned quantum=media?4096u:file_quantum;
 unsigned target=media?4096u:native_target(quantum);
 if(target>sizeof pcm-index)target=sizeof pcm-index;
 unsigned pending=pcm_pending();
 if(pending&&(pending>=target||stats.wire_state!=S11_CAPTURING)){
  unsigned n=pending<target?pending:target;
  /* Keep the8KiB readiness boundary, but finish native spans in <=2KiB
   * commits. Each synchronous call retires FatFs/SD and file CRC before
   * publishing credit; later pieces never refer back to a released piece.
   * Media playback keeps its existing single4KiB submission. */
  while(n){
   unsigned part=!media&&n>2048u?2048u:n;
   record_observer_phase(OBS_FILE,OBS_PCM);r=s11_storage_pcm(stats.recording_id,stats.first_frame+stats.stored_pcm,pcm+index,part/4);
   if(r)break;
   head+=part;index+=part;n-=part;stats.stored_pcm+=part/4;record_observer_progress(OBS_FILE,(uint32_t)stats.stored_pcm);
   pcm_first=stats.first_frame+stats.stored_pcm;
   __atomic_store_n(&pcm_read,head,__ATOMIC_RELEASE);
  }
 }
 stats.pcm_buffered=(uint32_t)pcm_pending();stats.event_buffered=(uint16_t)event_pending();
 if(r){
  if(bus_fault_active()){s11_service_bus_abort();return r;}
  s11_service_fail(S11_E_STORAGE,stats.first_frame+stats.stored_pcm);__atomic_store_n(&pcm_read,__atomic_load_n(&pcm_write,__ATOMIC_ACQUIRE),__ATOMIC_RELEASE);__atomic_store_n(&event_read,__atomic_load_n(&event_write,__ATOMIC_ACQUIRE),__ATOMIC_RELEASE);return r;
 }
 if(stats.active&&!pcm_pending()&&!event_pending()&&!stats.command&&!stats.ack_pending&&(stats.wire_state==S11_CLOSED||stats.wire_state==S11_INCOMPLETE||stats.wire_state==S11_ERROR)){
  /* Preserve the final capture window before full-file reread overwrites the trace. */
  if(!stats.error)order_trace_freeze(0);
  if(stats.error||stats.wire_state!=S11_CLOSED)s11_storage_failure(stats.error?stats.error:S11_E_STORAGE);
  s11_storage_event_missing(stats.missing_event_frame);
  record_observer_phase(OBS_FILE,OBS_FINISH);r=s11_storage_finish(stats.recording_id,stats.error||stats.wire_state!=S11_CLOSED,stats.missing_frame,media);stats.active=0;return r;
 }
 if(!stats.active&&!media&&s11_storage_statistics()->state==S11_STORE_VERIFY_PENDING)return s11_storage_verify();
 return 0;
}
void s11_service_info(uint8_t b[72]){
 const s11_storage_stats *s=s11_storage_statistics();memset(b,0,72);s9_put64(b,s->recording_id);b[8]=s->state;b[9]=s->recording_id==stats.recording_id?stats.wire_state:S11_STOPPED;b[10]=s->kinds;
 if(s->state==S11_STORE_SAVED)b[11]=(uint8_t)(s->kinds&3u);
 if(s->state==S11_STORE_INCOMPLETE||s->state==S11_STORE_ERROR)b[11]|=4;
 s9_put32(b+12,(uint32_t)(s->error?s->error:(s->recording_id==stats.recording_id?stats.error:0)));s9_put64(b+16,s->captured_pairs);s9_put64(b+24,s->event_units);s9_put64(b+32,(s->kinds&1)?512ull+s->pcm_bytes:0);s9_put64(b+40,(s->kinds&2)?512ull+512ull*s->event_pages:0);s9_put32(b+48,s->pcm_file_crc);s9_put32(b+52,s->event_file_crc);s9_put64(b+56,(s->kinds&1)?s->first_frame:s->first_event_frame);s9_put64(b+64,(s->kinds&1)?s->last_frame:s->last_event_frame);
}
RECORD_HOT void s11_service_wire(uint64_t now,uint32_t duration,int sd){
 uint64_t start=now>=duration?now-duration:0;
 while(start<now){uint64_t ms=start/1000,end=(ms+1)*1000;if(end>now)end=now;occupancy *p=&history[ms%101];if(p->millisecond!=ms){p->millisecond=ms;p->total=p->sd=0;}p->total=(uint16_t)(p->total+end-start);if(sd)p->sd=(uint16_t)(p->sd+end-start);start=end;}
 if(strict_media_guard&&!sd&&stats.active&&rolling(now,0)>S11_TOTAL_BUS_BUDGET_US)s11_service_fail(S11_E_SERVICE,stats.received_pcm?stats.last_frame+1:UINT64_MAX);
}
static uint32_t rolling(uint64_t now,int sd){uint64_t lower=now>100000?now-100000:0;uint32_t sum=0;for(unsigned i=0;i<101;i++)if(history[i].millisecond*1000+1000>lower&&history[i].millisecond*1000<=now)sum+=sd?history[i].sd:history[i].total;return sum;}
int s11_service_wire_begin(uint64_t now,uint32_t duration){
 if(!stats.active)return 0;
 if(sd_active){stats.wire_waits++;return S9_E_BUSY;}
 if(strict_media_guard&&(duration>S11_TOTAL_BUS_BUDGET_US||rolling(now,0)>S11_TOTAL_BUS_BUDGET_US-duration)){stats.wire_waits++;return S9_E_BUSY;}
 return 0;
}
int s11_service_sd_begin(uint64_t now,int stock){return s11_service_sd_reserve(now,stock,2000);}
int s11_service_sd_reserve(uint64_t now,int stock,uint32_t limit){
 if(sd_active||!stock||!limit||limit>sd_lease_ceiling(strict_media_guard))return S9_E_BUSY;
 if(strict_media_guard&&(rolling(now,1)>30000-limit||rolling(now,0)>S11_TOTAL_BUS_BUDGET_US-limit))return S9_E_BUSY;
 sd_started=now;sd_active=1;sd_limit=limit;return 0;
}
int s11_service_sd_end(uint64_t now,uint64_t occupied){
 if(!sd_active||now<sd_started)return S9_E_STATE;
 sd_active=0;s11_service_wire(now,(uint32_t)occupied,1);
 if(occupied>sd_limit||rolling(now,1)>30000||rolling(now,0)>S11_TOTAL_BUS_BUDGET_US){
  if(strict_media_guard){s11_service_fail(S11_E_SERVICE,pcm_first);return S9_E_TIMEOUT;}
  if(stats.service_violations++==0)CAP_DIAG(31,occupied,sd_limit,rolling(now,0));
 }
 return 0;
}
int s11_service_card_progress(uint64_t now,uint32_t bytes,uint32_t pending){
 card_completed+=bytes;
 if(strict_media_guard&&backlog_started&&now>=backlog_started){uint64_t elapsed=now-backlog_started;if(elapsed>20000){uint64_t required=(elapsed-20000)*S11_FILE_SERVICE_BYTES_PER_SECOND/1000000;if(card_completed-backlog_baseline+511<required){s11_service_fail(S11_E_SERVICE,pcm_first);return S9_E_TIMEOUT;}}}
 if(!pending){backlog_started=0;backlog_baseline=card_completed;return 0;}
 if(!backlog_started){backlog_started=now;backlog_baseline=card_completed;return 0;}
 if(now<backlog_started)return S9_E_STATE;
 uint64_t elapsed=now-backlog_started;if(strict_media_guard&&elapsed>20000){uint64_t required=(elapsed-20000)*S11_FILE_SERVICE_BYTES_PER_SECOND/1000000;if(card_completed-backlog_baseline+511<required){s11_service_fail(S11_E_SERVICE,pcm_first);return S9_E_TIMEOUT;}}
 return 0;
}
