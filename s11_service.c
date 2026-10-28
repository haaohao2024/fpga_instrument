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

static uint8_t pcm[32768],events[4096];
static uint32_t pcm_write,pcm_read,event_write,event_read;
static uint64_t pcm_first;
static s11_service_stats stats;
typedef struct {uint64_t millisecond;uint16_t total,sd;} occupancy;
static occupancy history[101];
static uint64_t sd_started,backlog_started;
static uint64_t card_completed,backlog_baseline;
static int sd_active;static uint32_t sd_limit;
static uint32_t next_block[2];
static uint8_t sent_ack_kind;static uint32_t sent_ack_sequence;
static uint64_t last_record_id;
static uint8_t stop_after_start;
static volatile uint8_t ram_sink;
static uint32_t rolling(uint64_t now,int sd);
static uint32_t pcm_pending(void){return __atomic_load_n(&pcm_write,__ATOMIC_ACQUIRE)-__atomic_load_n(&pcm_read,__ATOMIC_ACQUIRE);}
static uint32_t event_pending(void){return __atomic_load_n(&event_write,__ATOMIC_ACQUIRE)-__atomic_load_n(&event_read,__ATOMIC_ACQUIRE);}
void s11_service_init(void){memset(&stats,0,sizeof stats);memset(history,0,sizeof history);memset(next_block,0,sizeof next_block);last_record_id=0;pcm_write=pcm_read=event_write=event_read=0;sd_active=0;backlog_started=0;card_completed=0;sent_ack_kind=0;sent_ack_sequence=0;stop_after_start=0;ram_sink=0;}
const s11_service_stats *s11_service_statistics(void){return &stats;}
int s11_service_active(void){return stats.active;}
int s11_service_can_start(uint64_t id,unsigned mask){
 if(!id||!mask||(mask&~3u))return S9_E_RANGE;
 if(ram_sink||stats.active||pcm_pending()||event_pending())return S9_E_BUSY;
 if(id<=last_record_id)return S9_E_STALE;
 if(stats.command_sequence==UINT32_MAX)return S9_E_RANGE;
 return 0;
}
int s11_service_ram_owned(void){return ram_sink;}
uint64_t s11_service_next_id(void){return last_record_id==UINT64_MAX?0:last_record_id+1;}
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
 uint32_t seq=stats.command_sequence+1;last_record_id=id;memset(&stats,0,sizeof stats);memset(next_block,0,sizeof next_block);stats.command_sequence=seq;stats.recording_id=id;stats.mask=(uint8_t)mask;stats.command=S11_REC_START;stats.active=1;stats.first_frame=stats.last_frame=stats.missing_frame=UINT64_MAX;pcm_write=pcm_read=event_write=event_read=0;backlog_started=0;stop_after_start=0;return 0;
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
unsigned s11_service_request_mode(uint8_t p[S11_WIRE_BYTES],const uint8_t *media,unsigned length,unsigned reverse_capacity){
 memset(p,0,S11_WIRE_BYTES);memcpy(p,"S11P",4);p[4]=1;
 if(media&&length>=36){memcpy(p+5,media+5,27);unsigned n=s9_get16(media+6);if(media[5]==S11_MEDIA_DATA&&n<=128&&length>=36+4*n)memcpy(p+64,media+32,4*n);}
 s9_put64(p+32,stats.recording_id);p[40]=stats.command;p[41]=stats.mask;p[42]=stats.ack_kind;s9_put32(p+44,stats.command_sequence);s9_put32(p+48,stats.ack_sequence);
 if(!stats.command&&stats.ack_kind)p[40]=S11_REC_ACK;
 unsigned wire=reverse_capacity==0&&(p[5]==S11_MEDIA_NOP||p[5]==S11_MEDIA_STATUS)&&s9_get16(p+6)==0&&(p[40]==S11_REC_ACK||p[40]==S11_REC_QUERY)?68:580;
 s9_put16(p+52,(uint16_t)(wire==68?0:512));s9_put32(p+60,s9_crc32(p,60));s9_put32(p+wire-4,s9_crc32(p,wire-4));stats.wire_transactions++;
 sent_ack_kind=p[42];sent_ack_sequence=s9_get32(p+48);return wire;
}
void s11_service_request(uint8_t p[S11_WIRE_BYTES],const uint8_t *media,unsigned length){(void)s11_service_request_mode(p,media,length,512);}
int s11_service_response_bytes(const uint8_t *p,unsigned length){
 if((length!=68&&length!=580)||memcmp(p,"S7ST",4)||p[4]!=1||s9_get32(p+60)!=s9_crc32(p,60)||s9_get32(p+length-4)!=s9_crc32(p,length-4))return S9_E_CRC;
 if(s9_get64(p+24)!=stats.recording_id)return S9_E_STALE;
 stats.wire_state=p[6];stats.last_command=s9_get32(p+32);
 if(stats.last_command==stats.command_sequence)stats.command=0;
 if(stop_after_start==1&&!stats.command){stop_after_start=2;stats.command_sequence++;stats.command=S11_REC_STOP;}
 unsigned first_fault=(p[7]&2)&&!stats.error;
 if(first_fault){CAP_DIAG(19,s9_get32(p+52),p[6],s9_get32(p+40));stats.error=(uint8_t)s9_get32(p+52);if(!stats.error)stats.error=S11_E_STORAGE;}
 if((p[7]&3)==2)stats.missing_frame=s9_get64(p+40);
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
 if((kind!=S11_KIND_PCM&&kind!=S11_KIND_EVENT)||bytes>512||!bytes||!(stats.mask&kind)||bytes!=(kind==1?items*4:items*32))return S9_E_FORMAT;
 unsigned index=kind-1;
 if(next_block[index]&&seq==next_block[index]-1){stats.duplicate_blocks++;stats.ack_sequence=seq;stats.ack_kind=(uint8_t)kind;stats.ack_pending=1;return 0;}
 if(seq!=next_block[index])return S9_E_SEQUENCE;
 if(kind==S11_KIND_PCM){
  if(first>UINT64_MAX-(items-1))return S9_E_RANGE;
  if(bytes>sizeof pcm-pcm_pending())return S9_E_BUSY;
  if(stats.received_pcm&&first!=stats.last_frame+1){s11_service_fail(S11_E_SEQUENCE,first);return S9_E_SEQUENCE;}

  if(!stats.received_pcm)stats.first_frame=first;
  stats.last_frame=first+items-1;stats.received_pcm+=items;
  uint32_t tail=pcm_write;for(unsigned i=0;i<bytes;i++)pcm[(tail+i)%sizeof pcm]=p[64+i];__atomic_store_n(&pcm_write,tail+bytes,__ATOMIC_RELEASE);
 }else{if(bytes>sizeof events-event_pending())return S9_E_BUSY;uint32_t tail=event_write;for(unsigned i=0;i<bytes;i++)events[(tail+i)%sizeof events]=p[64+i];stats.received_cells+=items;__atomic_store_n(&event_write,tail+bytes,__ATOMIC_RELEASE);}
 next_block[index]++;stats.block_sequence++;stats.ack_sequence=seq;stats.ack_kind=(uint8_t)kind;stats.ack_pending=1;stats.pcm_buffered=(uint16_t)pcm_pending();stats.event_buffered=(uint16_t)event_pending();return 0;
}
int s11_service_response(const uint8_t p[S11_WIRE_BYTES]){return s11_service_response_bytes(p,580);}
int s11_service_file_step(int media){
 if(ram_sink)return 0;
 uint8_t b[512];int r=0;
 if(pcm_pending()){unsigned n=pcm_pending();if(n>512)n=512;uint32_t head=pcm_read;for(unsigned i=0;i<n;i++)b[i]=pcm[(head+i)%sizeof pcm];r=s11_storage_pcm(stats.recording_id,stats.first_frame+stats.stored_pcm,b,n/4);if(!r){__atomic_store_n(&pcm_read,head+n,__ATOMIC_RELEASE);pcm_first=stats.first_frame+stats.stored_pcm+n/4;stats.stored_pcm+=n/4;}}
 if(!r&&event_pending()){unsigned n=event_pending();if(n>480)n=480;uint32_t head=event_read;for(unsigned i=0;i<n;i++)b[i]=events[(head+i)%sizeof events];r=s11_storage_events(stats.recording_id,b,n/32);if(!r){__atomic_store_n(&event_read,head+n,__ATOMIC_RELEASE);stats.stored_cells+=n/32;}}
 stats.pcm_buffered=(uint16_t)pcm_pending();stats.event_buffered=(uint16_t)event_pending();
 if(r){s11_service_fail(S11_E_STORAGE,stats.first_frame+stats.stored_pcm);__atomic_store_n(&pcm_read,__atomic_load_n(&pcm_write,__ATOMIC_ACQUIRE),__ATOMIC_RELEASE);__atomic_store_n(&event_read,__atomic_load_n(&event_write,__ATOMIC_ACQUIRE),__ATOMIC_RELEASE);return r;}
 if(stats.active&&!pcm_pending()&&!event_pending()&&!stats.command&&!stats.ack_pending&&(stats.wire_state==S11_CLOSED||stats.wire_state==S11_INCOMPLETE||stats.wire_state==S11_ERROR)){
  if(stats.error||stats.wire_state!=S11_CLOSED)s11_storage_failure(stats.error?stats.error:S11_E_STORAGE);
  r=s11_storage_finish(stats.recording_id,stats.error||stats.wire_state!=S11_CLOSED,stats.missing_frame,media);stats.active=0;return r;
 }
 if(!stats.active&&!media&&s11_storage_statistics()->state==S11_STORE_VERIFY_PENDING)return s11_storage_verify();
 return 0;
}
void s11_service_info(uint8_t b[72]){
 const s11_storage_stats *s=s11_storage_statistics();memset(b,0,72);s9_put64(b,s->recording_id);b[8]=s->state;b[9]=s->recording_id==stats.recording_id?stats.wire_state:S11_STOPPED;b[10]=s->kinds;
 if(s->state==S11_STORE_SAVED)b[11]=(uint8_t)(s->kinds&3u);
 if(s->state==S11_STORE_INCOMPLETE||s->state==S11_STORE_ERROR)b[11]|=4;
 s9_put32(b+12,(uint32_t)s->error);s9_put64(b+16,s->captured_pairs);s9_put64(b+24,s->event_units);s9_put64(b+32,(s->kinds&1)?512ull+s->pcm_bytes:0);s9_put64(b+40,(s->kinds&2)?512ull+512ull*s->event_pages:0);s9_put32(b+48,s->pcm_file_crc);s9_put32(b+52,s->event_file_crc);s9_put64(b+56,s->first_frame);s9_put64(b+64,s->last_frame);
}
void s11_service_wire(uint64_t now,uint32_t duration,int sd){
 uint64_t start=now>=duration?now-duration:0;
 while(start<now){uint64_t ms=start/1000,end=(ms+1)*1000;if(end>now)end=now;occupancy *p=&history[ms%101];if(p->millisecond!=ms){p->millisecond=ms;p->total=p->sd=0;}p->total=(uint16_t)(p->total+end-start);if(sd)p->sd=(uint16_t)(p->sd+end-start);start=end;}
 if(!sd&&stats.active&&rolling(now,0)>S11_TOTAL_BUS_BUDGET_US)s11_service_fail(S11_E_SERVICE,stats.received_pcm?stats.last_frame+1:UINT64_MAX);
}
static uint32_t rolling(uint64_t now,int sd){uint64_t lower=now>100000?now-100000:0;uint32_t sum=0;for(unsigned i=0;i<101;i++)if(history[i].millisecond*1000+1000>lower&&history[i].millisecond*1000<=now)sum+=sd?history[i].sd:history[i].total;return sum;}
int s11_service_wire_begin(uint64_t now,uint32_t duration){
 if(!stats.active)return 0;
 if(sd_active||duration>S11_TOTAL_BUS_BUDGET_US||rolling(now,0)>S11_TOTAL_BUS_BUDGET_US-duration){stats.wire_waits++;return S9_E_BUSY;}
 return 0;
}
int s11_service_sd_begin(uint64_t now,int stock){return s11_service_sd_reserve(now,stock,2000);}
int s11_service_sd_reserve(uint64_t now,int stock,uint32_t limit){
 if(sd_active||!stock||!limit||limit>2000)return S9_E_BUSY;
 if(rolling(now,1)>30000-limit||rolling(now,0)>S11_TOTAL_BUS_BUDGET_US-limit)return S9_E_BUSY;
 sd_started=now;sd_active=1;sd_limit=limit;return 0;
}
int s11_service_sd_end(uint64_t now,uint64_t occupied){
 if(!sd_active||now<sd_started)return S9_E_STATE;
 sd_active=0;s11_service_wire(now,(uint32_t)occupied,1);
 if(occupied>sd_limit||rolling(now,1)>30000||rolling(now,0)>S11_TOTAL_BUS_BUDGET_US){s11_service_fail(S11_E_SERVICE,pcm_first);return S9_E_TIMEOUT;}return 0;
}
int s11_service_card_progress(uint64_t now,uint32_t bytes,uint32_t pending){
 card_completed+=bytes;
 if(backlog_started&&now>=backlog_started){uint64_t elapsed=now-backlog_started;if(elapsed>20000){uint64_t required=(elapsed-20000)*S11_FILE_SERVICE_BYTES_PER_SECOND/1000000;if(card_completed-backlog_baseline+511<required){s11_service_fail(S11_E_SERVICE,pcm_first);return S9_E_TIMEOUT;}}}
 if(!pending){backlog_started=0;backlog_baseline=card_completed;return 0;}
 if(!backlog_started){backlog_started=now;backlog_baseline=card_completed;return 0;}
 if(now<backlog_started)return S9_E_STATE;
 uint64_t elapsed=now-backlog_started;if(elapsed>20000){uint64_t required=(elapsed-20000)*S11_FILE_SERVICE_BYTES_PER_SECOND/1000000;if(card_completed-backlog_baseline+511<required){s11_service_fail(S11_E_SERVICE,pcm_first);return S9_E_TIMEOUT;}}
 return 0;
}
