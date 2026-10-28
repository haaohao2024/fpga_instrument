#include "record_observer.h"
#include "audio_timebase.h"
#include "bus_fault.h"
#include "record_trace.h"
#include "score_hal.h"
/* Actual recorder files use the existing sole FatFs caller. Complete files
 * are not downloadable until sync, close and a separate reopen verification.
 * There is deliberately no power-fail atomicity claim. */
#include "s11_storage.h"
#include "s9_protocol.h"
#include "ff.h"
#include "diskio.h"
#include "s9_storage.h"
#include <string.h>
#include <stdio.h>
#include "FreeRTOS.h"
#include "task.h"
/* Read-only maintenance loops otherwise keep the file(4)/bus(5) RPC pair
 * permanently ready and starve the BLE host (priority 3) for seconds. */
static void maintenance_yield(void){vTaskDelay(1);}
#ifdef ENSEMBLE_CAPTURE_DIAG
#include "link_diag.h"
#include "sd_spi.h"
#define SD_DIAG(k,a,b,c) link_diag_event(k,a,b,c)
#else
#define SD_DIAG(k,a,b,c) ((void)0)
#endif
static FIL pcm_file,event_file;
static uint8_t page[512],event_page[512];
static char pcm_tmp[20],pcm_final[20],event_tmp[20],event_final[20];
static unsigned pcm_open,event_open,event_used;
static volatile int write_scope;
static uint32_t pcm_running_crc,event_running_crc;
static uint32_t file_number;
static s11_storage_stats stats;
static const uint32_t record_rates[4]={RECORD_PCM_HZ,INSTRUMENT_AUDIO_HZ,0,0};
static const uint32_t record_filter[4]={0x00080003,335,768000,0};
static uint32_t update_crc(uint32_t c,const uint8_t *p,unsigned n){uint64_t began=hal_time_us();uint32_t result=s9_crc32_update(c,p,n);record_trace_measure(5,(uint32_t)(hal_time_us()-began));return result;}
static __attribute__((noinline)) void name(char out[20],char prefix,uint32_t number,const char ext[4]){
 memcpy(out,"0:/",3);out[3]=prefix;for(unsigned i=0;i<7;i++){out[10-i]=(char)('0'+number%10);number/=10;}out[11]='.';memcpy(out+12,ext,4);
}
static __attribute__((noinline)) uint32_t numbered_name(const char *s){
 if((s[0]!='W'&&s[0]!='E'&&s[0]!='M')||s[8]!='.'||strlen(s)!=12)return 0;
 uint32_t n=0;for(unsigned i=1;i<8;i++){if(s[i]<'0'||s[i]>'9')return 0;n=n*10u+(unsigned)(s[i]-'0');}return n;
}
/* The full 64-bit stream identity is independent of the 8.3 filename number.
 * Preparing/download occurs with maintenance allowed, never in a BLE callback.
 * Persisted files and retained partial files reserve their number across boots. */
static int allocate_number(uint32_t *out){
 DIR dir;FILINFO info;uint32_t maximum=0;FRESULT dir_result=f_opendir(&dir,"0:/");if(dir_result!=FR_OK){SD_DIAG(21,1,dir_result,0);return S9_E_IO;}int r=0;
 for(unsigned seen=0;;){if(f_readdir(&dir,&info)!=FR_OK){r=S9_E_IO;break;}if(!info.fname[0])break;uint32_t n=numbered_name(info.fname);if(n>maximum)maximum=n;if(!(++seen&63u))maintenance_yield();}
 if(f_closedir(&dir)!=FR_OK)r=S9_E_IO;
 if(r)return r;
 if(maximum>=9999999)return S9_E_RANGE;
 *out=maximum+1;return 0;
}
static void wav_header(uint8_t b[512],uint32_t pairs){
 const uint32_t frame=S11_FILE_BYTES_PER_PAIR;
 memset(b,0,512);memcpy(b,"RIFF",4);s9_put32(b+4,504u+frame*pairs);memcpy(b+8,"WAVEfmt ",8);
 s9_put32(b+16,16);s9_put16(b+20,1);s9_put16(b+22,(uint16_t)S11_PCM_CHANNELS);s9_put32(b+24,stats.pcm_rate);
 s9_put32(b+28,stats.pcm_rate*frame);s9_put16(b+32,(uint16_t)frame);s9_put16(b+34,16);
 memcpy(b+36,"JUNK",4);s9_put32(b+40,460);memcpy(b+504,"data",4);s9_put32(b+508,frame*pairs);
}
static void evr_header(uint8_t b[512]){
 memset(b,0,512);memcpy(b,"EVR2",4);s9_put32(b+4,2);s9_put64(b+8,stats.recording_id);s9_put32(b+16,stats.event_rate);s9_put32(b+20,stats.event_clock_hz);s9_put32(b+24,stats.event_units);s9_put32(b+28,stats.event_pages);s9_put64(b+32,stats.first_event_frame);s9_put64(b+40,stats.last_event_frame);s9_put64(b+48,stats.missing_event_frame);b[56]=stats.state; b[57]=stats.kinds;s9_put16(b+58,(uint16_t)stats.error);s9_put32(b+508,s9_crc32(b,508));
}
static int written(FIL *f,const uint8_t *b,unsigned bytes){UINT n=0;write_scope=1;uint64_t began=hal_time_us();FRESULT r=f_write(f,b,bytes,&n);record_trace_measure(4,(uint32_t)(hal_time_us()-began));write_scope=0;if(r!=FR_OK||n!=bytes){SD_DIAG(21,4,r,n);SD_DIAG(25,sd_get_diagnostics()->io_errors,sd_get_diagnostics()->deadline_errors,sd_get_diagnostics()->max_selected_us);SD_DIAG(26,sd_get_diagnostics()->last_timeout_phase,sd_get_diagnostics()->last_timeout_us,sd_get_diagnostics()->last_limit_us);SD_DIAG(27,sd_get_diagnostics()->max_setup_us,sd_get_diagnostics()->max_bulk_us,0);}return r==FR_OK&&n==bytes?0:S9_E_IO;}
/* FatFs may flush a dirty partial sector while seeking back to a header.
 * This is still a recorder-owned write, including during media playback. */
static __attribute__((noinline)) int seek_owned(FIL *f,FSIZE_t offset){write_scope=1;FRESULT r=f_lseek(f,offset);write_scope=0;return r==FR_OK?0:S9_E_IO;}
static __attribute__((noinline)) int sync_file(FIL *f){record_observer_phase(OBS_FILE,OBS_SYNC);write_scope=1;FRESULT r=f_sync(f);DRESULT d=r==FR_OK?disk_ioctl(0,CTRL_SYNC,0):RES_ERROR;write_scope=0;if(r!=FR_OK||d!=RES_OK)SD_DIAG(21,5,r,d);return r==FR_OK&&d==RES_OK?0:S9_E_IO;}
static __attribute__((noinline)) int close_handle(FIL *f,unsigned *opened){record_observer_phase(OBS_FILE,OBS_CLOSE);if(!*opened)return 0;write_scope=1;FRESULT r=f_close(f);write_scope=0;*opened=0;return r==FR_OK?0:S9_E_IO;}
static int error(int e){stats.error=e;stats.state=S11_STORE_ERROR;return e;}
int s11_storage_write_authorized(void){return write_scope;}
const s11_storage_stats *s11_storage_statistics(void){return &stats;}
void s11_storage_event_missing(uint64_t frame){stats.missing_event_frame=frame;}
void s11_storage_failure(int reason){if(!stats.error)stats.error=reason?reason:S11_E_STORAGE;}
void s11_storage_bus_abort(void){
 /* FF_FS_LOCK=0: invalidate only these sole-owner RAM handles. No sync,
  * rename, catalogue write or success publication can run on a frozen bus.
  * Existing TMP sectors remain untouched for later forensic inspection. */
 _Static_assert(FF_FS_LOCK==0,"Local abandon requires the existing unlocked FatFs configuration");
 if(!bus_fault_active())return;
 pcm_open=event_open=event_used=0;
 memset(&pcm_file,0,sizeof pcm_file);memset(&event_file,0,sizeof event_file);
 stats.verified_pcm=stats.verified_event=0;
 stats.state=S11_STORE_INCOMPLETE;if(!stats.error)stats.error=S11_E_STORAGE;
}
static int save_catalogue(void);
int s11_storage_prepare(uint64_t id,unsigned kinds){
 if(bus_fault_active())return S9_E_IO;
 if(!id||!kinds||(kinds&~3u))return S9_E_RANGE;
 if(pcm_open||event_open||stats.state==S11_STORE_CAPTURING||stats.state==S11_STORE_DRAINING||stats.state==S11_STORE_VERIFY_PENDING)return S9_E_BUSY;
 /* A new id needs no catalogue scan: files take a fresh number and
  * FA_CREATE_NEW, and the service already requires ids to increase. */
 int nr=allocate_number(&file_number);if(nr)return nr;
 memset(&stats,0,sizeof stats);stats.recording_id=id;stats.kinds=(uint8_t)kinds;stats.first_frame=stats.last_frame=stats.missing_frame=UINT64_MAX;
 stats.first_event_frame=stats.last_event_frame=stats.missing_event_frame=UINT64_MAX;
 stats.pcm_rate=RECORD_PCM_HZ;stats.event_rate=INSTRUMENT_AUDIO_HZ;stats.event_clock_hz=INSTRUMENT_SYS_HZ;event_used=0;pcm_running_crc=event_running_crc=~0u;
 name(pcm_tmp,'W',file_number,"TMP");name(pcm_final,'W',file_number,"WAV");name(event_tmp,'E',file_number,"TMP");name(event_final,'E',file_number,"EVR");
 FILINFO info;if(f_stat(pcm_final,&info)==FR_OK||f_stat(event_final,&info)==FR_OK)return error(S9_E_CONFLICT);
 if(kinds&S11_KIND_PCM){FRESULT fr=f_open(&pcm_file,pcm_tmp,FA_CREATE_NEW|FA_READ|FA_WRITE);if(fr!=FR_OK){SD_DIAG(21,2,fr,0);return error(S9_E_IO);}pcm_open=1;wav_header(page,0);if(written(&pcm_file,page,512))goto fail;}
 if(kinds&S11_KIND_EVENT){FRESULT fr=f_open(&event_file,event_tmp,FA_CREATE_NEW|FA_READ|FA_WRITE);if(fr!=FR_OK){SD_DIAG(21,3,fr,0);goto fail;}event_open=1;evr_header(page);if(written(&event_file,page,512))goto fail;memset(event_page,0,512);}
 if((pcm_open&&sync_file(&pcm_file))||(event_open&&sync_file(&event_file)))goto fail;
 stats.state=S11_STORE_CAPTURING;return 0;
 fail:close_handle(&pcm_file,&pcm_open);close_handle(&event_file,&event_open);return error(S9_E_IO);
}
/* Mono = (L+R)/2 of each little-endian 16-bit stereo pair. One 512-pair
 * chunk matches the native 2 KiB service part and keeps file writes
 * sector aligned. */
#define MONO_CHUNK_PAIRS 512u
static uint8_t mono[MONO_CHUNK_PAIRS*S11_FILE_BYTES_PER_PAIR];
static void downmix(uint8_t *out,const uint8_t *lr,unsigned pairs){
 for(unsigned i=0;i<pairs;i++){
  int32_t left=(int16_t)(lr[4*i]|(lr[4*i+1]<<8));
  int32_t right=(int16_t)(lr[4*i+2]|(lr[4*i+3]<<8));
  int32_t sum=(left+right)>>1;
  out[2*i]=(uint8_t)sum;
  out[2*i+1]=(uint8_t)(sum>>8);
 }
}
int s11_storage_pcm(uint64_t id,uint64_t first,const uint8_t *data,unsigned pairs){
 if(id!=stats.recording_id)return S9_E_STALE;
 if(stats.state!=S11_STORE_CAPTURING||!pcm_open)return S9_E_STATE;
 const uint32_t bytes=pairs*S11_FILE_BYTES_PER_PAIR;
 if(!data||!pairs||pairs>4096||stats.pcm_bytes>1073741824u-bytes)return S9_E_RANGE;
 if(stats.captured_pairs&&first!=stats.last_frame+1)return error(S9_E_SEQUENCE);
 if(first>UINT64_MAX-(pairs-1))return error(S9_E_RANGE);
 for(unsigned done=0;done<pairs;){
  unsigned chunk=pairs-done;
  if(chunk>MONO_CHUNK_PAIRS)chunk=MONO_CHUNK_PAIRS;
  downmix(mono,data+done*4u,chunk);
  if(written(&pcm_file,mono,chunk*S11_FILE_BYTES_PER_PAIR))return error(S9_E_IO);
  pcm_running_crc=update_crc(pcm_running_crc,mono,chunk*S11_FILE_BYTES_PER_PAIR);
  done+=chunk;
 }
 if(!stats.captured_pairs)stats.first_frame=first;
 stats.last_frame=first+pairs-1;stats.captured_pairs+=pairs;stats.pcm_bytes+=bytes;stats.written_pcm+=bytes;return 0;
}
static int event_flush(void){
 if(!event_used)return 0;
 memcpy(event_page,"E11P",4);s9_put16(event_page+4,1);s9_put16(event_page+6,(uint16_t)event_used);s9_put32(event_page+8,stats.event_pages+1);s9_put64(event_page+12,stats.recording_id);s9_put32(event_page+508,s9_crc32(event_page,508));
 if(written(&event_file,event_page,512))return S9_E_IO;
 event_running_crc=update_crc(event_running_crc,event_page,512);stats.event_pages++;stats.written_event+=512;event_used=0;memset(event_page,0,512);return 0;
}
int s11_storage_events(uint64_t id,const uint8_t *units,unsigned count){
 if(id!=stats.recording_id)return S9_E_STALE;
 if(stats.state!=S11_STORE_CAPTURING||!event_open)return S9_E_STATE;
 if(!units||!count||count>15||stats.event_units>UINT32_MAX-count)return S9_E_RANGE;
 for(unsigned i=0;i<count;i++){
  const uint8_t *cell=units+i*32;uint64_t frame=s9_get64(cell+8);
  /* Event-only files still have a meaningful first/last executed frame.
   * PCM files retain the exact contiguous DAC range, which need not equal
   * the event snapshot range. */
  if(!stats.event_units){stats.first_event_frame=frame;}
  stats.last_event_frame=frame;
  if(cell[0]==S11_CELL_OVERFLOW)stats.missing_event_frame=frame;
  memcpy(event_page+28+event_used*32,cell,32);event_used++;stats.event_units++;if(event_used==15&&event_flush())return error(S9_E_IO);
 }return 0;
}
static int rewrite_and_close(void){
 if(event_open&&event_flush())return S9_E_IO;
 if(stats.state==S11_STORE_DRAINING)stats.state=S11_STORE_CLOSED;
 if(pcm_open){wav_header(page,stats.captured_pairs);if(seek_owned(&pcm_file,0)||written(&pcm_file,page,512)||sync_file(&pcm_file))return S9_E_IO;}
 if(event_open){evr_header(page);if(seek_owned(&event_file,0)||written(&event_file,page,512)||sync_file(&event_file))return S9_E_IO;}
 if(close_handle(&pcm_file,&pcm_open)||close_handle(&event_file,&event_open))return S9_E_IO;
 stats.pcm_crc=~pcm_running_crc;stats.event_crc=~event_running_crc;return 0;
}
int s11_storage_finish(uint64_t id,int incomplete,uint64_t missing,int media){
 if(id!=stats.recording_id)return S9_E_STALE;
 if(!pcm_open&&!event_open)return S9_E_STATE;
 stats.missing_frame=missing;stats.state=incomplete?S11_STORE_INCOMPLETE:S11_STORE_DRAINING;
 if(incomplete&&!stats.error)stats.error=S11_E_STORAGE;
 if(rewrite_and_close()){close_handle(&pcm_file,&pcm_open);close_handle(&event_file,&event_open);return error(S9_E_IO);}
 if(incomplete){stats.state=S11_STORE_INCOMPLETE;int r=save_catalogue();return r?error(r):0;}
 stats.state=S11_STORE_VERIFY_PENDING;
 return media?0:s11_storage_verify();
}
static int verify_file(const char *name,unsigned kind){record_observer_phase(OBS_FILE,OBS_VERIFY);
 FIL f;UINT n;uint32_t bytes=kind==S11_KIND_PCM?stats.pcm_bytes:stats.event_pages*512u;uint32_t expected=kind==S11_KIND_PCM?stats.pcm_crc:stats.event_crc;
 if(f_open(&f,name,FA_READ)!=FR_OK)return S9_E_IO;
 int r=0;if(f_size(&f)!=(FSIZE_t)512+bytes)r=S9_E_LENGTH;
 if(!r&&(f_read(&f,page,512,&n)!=FR_OK||n!=512))r=S9_E_IO;
 if(!r&&kind==S11_KIND_PCM){uint8_t expected_header[512];wav_header(expected_header,stats.captured_pairs);if(memcmp(page,expected_header,512))r=S9_E_FORMAT;}
 if(!r&&kind==S11_KIND_EVENT){if((memcmp(page,"EVR1",4)&&memcmp(page,"EVR2",4))||s9_get64(page+8)!=stats.recording_id||s9_crc32(page,508)!=s9_get32(page+508))r=S9_E_CRC;}
 uint32_t c=~0u,full=update_crc(~0u,page,512),offset=0;
 while(!r&&offset<bytes){unsigned want=bytes-offset;if(want>512)want=512;if(f_read(&f,page,want,&n)!=FR_OK||n!=want){r=S9_E_IO;break;}if(kind==S11_KIND_EVENT&&(memcmp(page,"E11P",4)||s9_get16(page+4)!=1||s9_get16(page+6)>15||s9_get32(page+8)!=offset/512+1||s9_get64(page+12)!=stats.recording_id||s9_crc32(page,508)!=s9_get32(page+508))){r=S9_E_CRC;break;}c=update_crc(c,page,want);full=update_crc(full,page,want);offset+=want;record_observer_progress(OBS_FILE,offset);if(!(offset&16383u))maintenance_yield();}
 if(!r&&~c!=expected)r=S9_E_CRC;
 if(f_close(&f)!=FR_OK)r=S9_E_IO;
 if(!r){if(kind==S11_KIND_PCM){stats.verified_pcm=bytes;stats.pcm_file_crc=~full;}else{stats.verified_event=bytes;stats.event_file_crc=~full;}}return r;
}
/* File-task-only diagnosis of an existing retained TMP. Never changes it or
 * publishes it as saved. Reuses the idle page; no additional large buffer. */

static void catalogue(uint8_t b[512]){
 memset(b,0,512);memcpy(b,"S11M",4);s9_put32(b+4,2);s9_put64(b+8,stats.recording_id);b[16]=stats.kinds;b[17]=stats.state==S11_STORE_VERIFY_PENDING?S11_STORE_SAVED:stats.state;s9_put32(b+20,stats.captured_pairs);s9_put32(b+24,stats.event_units);s9_put32(b+28,stats.event_pages);s9_put32(b+32,stats.pcm_bytes);s9_put32(b+36,stats.pcm_file_crc);s9_put32(b+40,stats.event_file_crc);s9_put32(b+44,stats.pcm_crc);s9_put32(b+48,stats.event_crc);s9_put64(b+56,stats.first_frame);s9_put64(b+64,stats.last_frame);
 /* Normal SAVED catalog bytes remain compatible. Only partial files use
  * reserved error32@52 and first_missing_frame64@72; CRC covers0..507. */
 if(b[17]!=S11_STORE_SAVED){s9_put32(b+52,(uint32_t)stats.error);s9_put64(b+72,stats.missing_frame);}
 s9_put64(b+72,stats.missing_frame);memcpy(b+80,record_rates,sizeof record_rates);
 s9_put64(b+96,stats.first_event_frame);s9_put64(b+104,stats.last_event_frame);s9_put64(b+112,stats.missing_event_frame);
 s9_put32(b+120,stats.event_clock_hz);memcpy(b+124,record_filter,sizeof record_filter);
 s9_put32(b+508,s9_crc32(b,508));
}
static int save_catalogue(void){record_observer_phase(OBS_FILE,OBS_CATALOGUE);
 char path[20];name(path,'M',file_number,"MET");catalogue(page);FIL f;
 if(f_open(&f,path,FA_WRITE|FA_READ|FA_CREATE_NEW)!=FR_OK)return S9_E_IO;
 int r=written(&f,page,512);if(!r)r=sync_file(&f);unsigned open=1;if(close_handle(&f,&open))r=S9_E_IO;
 if(r)return r;
 if(f_open(&f,path,FA_READ)!=FR_OK)return S9_E_IO;
 UINT n;uint8_t check[512];
 r=f_read(&f,check,512,&n)==FR_OK&&n==512&&f_size(&f)==512&&!memcmp(check,page,512)?0:S9_E_IO;if(f_close(&f)!=FR_OK)r=S9_E_IO;return r;
}
int s11_storage_select(uint64_t id){
 if(bus_fault_active())return S9_E_IO;
 if(!id)return S9_E_RANGE;
 if(pcm_open||event_open||stats.state==S11_STORE_VERIFY_PENDING)return S9_E_BUSY;
 if(id==stats.recording_id&&stats.state==S11_STORE_SAVED)return 0;
 /* Newest first: one directory pass finds the highest number, then known
  * names are opened downwards. Reopening every catalogue in directory order
  * cost one directory search each and stalled the bus for seconds. */
 uint32_t next=0;int r=allocate_number(&next);if(r==S9_E_RANGE){next=10000000;r=0;}if(r)return r;
 r=S9_E_EXPIRED;uint32_t found=0;
 for(uint32_t number=next-1;number;number--){
  maintenance_yield();char path[20];name(path,'M',number,"MET");FIL f;FRESULT fr=f_open(&f,path,FA_READ);if(fr==FR_NO_FILE)continue;if(fr!=FR_OK){r=S9_E_IO;break;}
  UINT n;int read=f_read(&f,page,512,&n)==FR_OK&&n==512&&f_size(&f)==512?0:S9_E_IO;if(f_close(&f)!=FR_OK)read=S9_E_IO;if(read){r=read;break;}
  if(!memcmp(page,"S11M",4)&&s9_get64(page+8)==id){found=number;r=0;break;}
 }
 if(r)return r;
 file_number=found;
 if(memcmp(page,"S11M",4)||(s9_get32(page+4)!=1&&s9_get32(page+4)!=2)||s9_get64(page+8)!=id||(page[17]!=S11_STORE_SAVED&&page[17]!=S11_STORE_INCOMPLETE&&page[17]!=S11_STORE_ERROR)||s9_crc32(page,508)!=s9_get32(page+508))return S9_E_CRC;
 memset(&stats,0,sizeof stats);stats.recording_id=id;stats.kinds=page[16];stats.state=page[17];stats.captured_pairs=s9_get32(page+20);stats.event_units=s9_get32(page+24);stats.event_pages=s9_get32(page+28);stats.pcm_bytes=s9_get32(page+32);stats.pcm_file_crc=s9_get32(page+36);stats.event_file_crc=s9_get32(page+40);stats.pcm_crc=s9_get32(page+44);stats.event_crc=s9_get32(page+48);stats.first_frame=s9_get64(page+56);stats.last_frame=s9_get64(page+64);stats.written_pcm=stats.pcm_bytes;stats.written_event=stats.event_pages*512;
 if(stats.state==S11_STORE_SAVED){stats.verified_pcm=stats.pcm_bytes;stats.verified_event=stats.event_pages*512;stats.missing_frame=UINT64_MAX;}else{stats.error=(int32_t)s9_get32(page+52);stats.missing_frame=s9_get64(page+72);}
 name(pcm_final,'W',file_number,"WAV");name(event_final,'E',file_number,"EVR");
 if(s9_get32(page+4)==2){
  stats.pcm_rate=s9_get32(page+80);stats.event_rate=s9_get32(page+84);stats.event_clock_hz=s9_get32(page+120);
  stats.first_event_frame=s9_get64(page+96);stats.last_event_frame=s9_get64(page+104);stats.missing_event_frame=s9_get64(page+112);
  if(memcmp(page+80,record_rates,sizeof record_rates)||memcmp(page+124,record_filter,sizeof record_filter))return S9_E_FORMAT;
 }else{
  stats.first_event_frame=stats.last_event_frame=stats.missing_event_frame=UINT64_MAX;
  stats.pcm_rate=stats.event_rate=0;stats.event_clock_hz=0;
  /* Legacy metadata did not separate PCM/event units. Read immutable file
   * headers; never replace their native recording rate with the new48k rate. */
  for(unsigned kind=1;kind<=2;kind++)if(stats.kinds&kind){
   char path[20];name(path,kind==1?'W':'E',file_number,stats.state==S11_STORE_SAVED?(kind==1?"WAV":"EVR"):"TMP");
   FIL f;UINT n;if(f_open(&f,path,FA_READ)!=FR_OK)return S9_E_IO;
   int hr=f_read(&f,page,512,&n)==FR_OK&&n==512?0:S9_E_IO;if(f_close(&f)!=FR_OK)hr=S9_E_IO;if(hr)return hr;
   if(kind==1){if(memcmp(page,"RIFF",4)||memcmp(page+8,"WAVEfmt ",8)||s9_get16(page+22)!=2||s9_get16(page+32)!=4||s9_get16(page+34)!=16||!audio_file_rate(s9_get32(page+24)))return S9_E_FORMAT;stats.pcm_rate=s9_get32(page+24);}
   else{if((memcmp(page,"EVR1",4)&&memcmp(page,"EVR2",4))||s9_get64(page+8)!=id||s9_crc32(page,508)!=s9_get32(page+508)||!audio_file_rate(s9_get32(page+16)))return S9_E_FORMAT;
    stats.event_rate=s9_get32(page+16);stats.event_clock_hz=s9_get32(page+20);stats.first_event_frame=s9_get64(page+32);stats.last_event_frame=s9_get64(page+40);stats.missing_event_frame=s9_get64(page+48);
   }
  }
  if(!(stats.kinds&S11_KIND_PCM))stats.first_frame=stats.last_frame=stats.missing_frame=UINT64_MAX;
 }return 0;
}
int s11_storage_verify(void){
 if(bus_fault_active())return S9_E_IO;
 if(stats.state!=S11_STORE_VERIFY_PENDING||pcm_open||event_open)return S9_E_STATE;
 int r=0;if((stats.kinds&S11_KIND_PCM)&&(r=verify_file(pcm_tmp,S11_KIND_PCM)))return error(r);
 if((stats.kinds&S11_KIND_EVENT)&&(r=verify_file(event_tmp,S11_KIND_EVENT)))return error(r);
 /* No replacement: recording IDs and FA_CREATE_NEW protect previous files.
  * Rename failures leave TMP/prefix evidence and never advertise SAVED. */
 record_observer_phase(OBS_FILE,OBS_RENAME);write_scope=1;
 if((stats.kinds&S11_KIND_PCM)&&f_rename(pcm_tmp,pcm_final)!=FR_OK)r=S9_E_IO;
 if(!r&&(stats.kinds&S11_KIND_EVENT)&&f_rename(event_tmp,event_final)!=FR_OK)r=S9_E_IO;
 if(!r&&disk_ioctl(0,CTRL_SYNC,0)!=RES_OK)r=S9_E_IO;
 write_scope=0;if(r)return error(r);
 /* Rename rewrites only the directory entry; the data verified above is
  * unchanged, so it is not read back a second time. */
 if((r=save_catalogue()))return error(r);
 stats.state=S11_STORE_SAVED;record_observer_phase(OBS_FILE,OBS_TERMINAL);return 0;
}
int s11_storage_download(uint64_t id,unsigned kind,uint32_t offset,uint8_t *out,unsigned cap,unsigned *count){
 if(bus_fault_active())return S9_E_IO;
 if(!count||!out||!cap||cap>480)return S9_E_RANGE;
 *count=0;
 if(id!=stats.recording_id){int r=s11_storage_select(id);if(r)return r;}
 if(stats.state!=S11_STORE_SAVED||!(stats.kinds&kind)||(kind!=1&&kind!=2))return S9_E_STATE;
 uint32_t size=512+(kind==1?stats.pcm_bytes:stats.event_pages*512);if(offset>size)return S9_E_RANGE;
 unsigned n=size-offset;if(n>cap)n=cap;
 FIL f;if(f_open(&f,kind==1?pcm_final:event_final,FA_READ)!=FR_OK)return S9_E_IO;
 UINT got=0;int r=f_lseek(&f,offset)==FR_OK&&f_read(&f,out,n,&got)==FR_OK&&got==n?0:S9_E_IO;if(f_close(&f)!=FR_OK)r=S9_E_IO;if(!r)*count=n;return r;
}
typedef struct {uint64_t id,time;uint8_t key,note,pressure;} export_note;
static export_note export_notes[32];
static uint64_t export_density[128];
static uint8_t export_page[512],export_identity[16];
static uint8_t export_pending[16];static int export_have_pending;
static uint32_t export_count,export_bytes,export_crc,export_page_sequence,export_page_used,export_offset;
static uint64_t export_origin,export_end,export_previous;
static unsigned export_group,export_write;
static uint32_t export_rate;
/* SCORE v1 holds notes only: key slot, note, pressure and time. Sound
 * settings (timbre, pan, gain, effects, key map, glide, vibrato) are not part
 * of it and are skipped, so playback uses the settings current at that time.
 * Notes already sounding when recording began have no ON here and are left
 * out; notes still held at END are released there. */
static unsigned export_voice(uint64_t id){return (unsigned)((id&31u)|((id>>17)&32u));}
static int export_emit_page(void){
 if(export_page_sequence){s9_put32(export_page,export_page_sequence);s9_put16(export_page+4,(uint16_t)export_page_used);}
 s9_put32(export_page+508,s9_crc32(export_page,508));export_crc=update_crc(export_crc,export_page,512);
 if(export_write){int r=s9_storage_append(export_identity,export_offset,export_page,500);if(r)return r;r=s9_storage_append(export_identity,export_offset+500,export_page+500,12);if(r)return r;}
 export_offset+=512;export_page_sequence++;export_page_used=0;memset(export_page,0,512);return 0;
}
static int export_record(uint64_t time,unsigned op,unsigned key,unsigned note,unsigned pressure){
 if(export_count>=1000000)return S9_E_RANGE;
 if(export_count&&time<export_previous)return S9_E_SEQUENCE;
 if(export_count>=128&&time-export_density[export_count%128]<export_rate/10u)return S9_E_RANGE;
 if(export_count&&time==export_previous){if(++export_group>64)return S9_E_RANGE;}else export_group=1;
 export_density[export_count%128]=time;export_previous=time;
 if(export_have_pending){
  s9_put32(export_pending+12,s9_get64(export_pending)==time?0:1);
  memcpy(export_page+16+export_page_used*16,export_pending,16);export_page_used++;
  if(export_page_used==30){int r=export_emit_page();if(r)return r;}
 }
 memset(export_pending,0,16);s9_put64(export_pending,time);export_pending[8]=(uint8_t)op;export_pending[9]=(uint8_t)key;export_pending[10]=(uint8_t)note;export_pending[11]=(uint8_t)pressure;
 export_have_pending=1;export_count++;return 0;
}
static int export_pass(int writing,uint32_t expected_records,uint64_t end){
 FIL f;UINT n;if(f_open(&f,event_final,FA_READ)!=FR_OK)return S9_E_IO;
 memset(export_notes,0,sizeof export_notes);memset(export_density,0,sizeof export_density);memset(export_page,0,512);export_count=export_page_used=export_page_sequence=export_offset=0;export_have_pending=0;export_crc=~0u;export_origin=UINT64_MAX;export_previous=export_end=0;export_group=0;export_write=(unsigned)writing;
 /* Read the original file rate before emitting its score header. */
 if(f_read(&f,page,512,&n)!=FR_OK||n!=512||s9_crc32(page,508)!=s9_get32(page+508)||!audio_file_rate(s9_get32(page+16))){f_close(&f);return S9_E_FORMAT;}
 export_rate=s9_get32(page+16);
 if(f_lseek(&f,0)!=FR_OK){f_close(&f);return S9_E_IO;}
 /* First pass counts only; second/third use the fixed counted header. */
 memcpy(export_page,"S7EV",4);s9_put32(export_page+4,1);s9_put32(export_page+8,export_rate);s9_put32(export_page+12,expected_records);s9_put64(export_page+16,end);
 int r=export_emit_page();if(r){f_close(&f);return r;}
 if(f_read(&f,page,512,&n)!=FR_OK||n!=512){f_close(&f);return S9_E_IO;}
 unsigned v2=!memcmp(page,"EVR2",4)&&s9_get32(page+4)==2;
 if(!v2&&(memcmp(page,"EVR1",4)||s9_get32(page+4)!=1)){f_close(&f);return S9_E_FORMAT;}
 uint32_t cell_sequence=0;
 for(uint32_t page_index=0;!r&&page_index<stats.event_pages;page_index++){
  if(f_read(&f,page,512,&n)!=FR_OK||n!=512){r=S9_E_IO;break;}
  if(memcmp(page,"E11P",4)||s9_get32(page+8)!=page_index+1||s9_crc32(page,508)!=s9_get32(page+508)){r=S9_E_CRC;break;}
  unsigned count=s9_get16(page+6);if(!count||count>15){r=S9_E_FORMAT;break;}
  for(unsigned i=0;!r&&i<count;i++){
   const uint8_t *c=page+28+i*32;unsigned type=c[0],flags=c[1];uint64_t frame=s9_get64(c+8),id=s9_get64(c+16),payload=s9_get64(c+24);
   if(s9_get32(c+4)!=cell_sequence++){r=S9_E_SEQUENCE;break;}
   if(type==S11_CELL_START){if(export_origin!=UINT64_MAX||id||payload>>16||flags!=3){r=S9_E_FORMAT;break;}export_origin=frame;continue;}
   if(export_origin==UINT64_MAX||frame<export_origin){r=S9_E_FORMAT;break;}uint64_t time=frame-export_origin;export_end=time;
   if(type==S11_CELL_END){
    for(unsigned k=0;k<32;k++)if(export_notes[k].id){r=export_record(time,2,k,0,0);export_notes[k].id=0;if(r)break;}
    continue;}
   if(type!=S11_CELL_NOTE_ON&&type!=S11_CELL_NOTE_OFF&&type!=S11_CELL_EXPRESSION)continue;
   unsigned note=(unsigned)((payload>>16)&127),pressure=(unsigned)((payload>>23)&255);int slot=-1;
   for(unsigned k=0;k<32;k++)if(export_notes[k].id==id&&id){slot=(int)k;break;}
   if(type==S11_CELL_NOTE_ON){
    /* A repeated identity, or (EVR2) a new note on the same voice, ends the old one. */
    for(unsigned k=0;k<32;k++)if(export_notes[k].id&&(export_notes[k].id==id||(v2&&export_voice(export_notes[k].id)==export_voice(id)))){
     r=export_record(time,2,k,0,0);export_notes[k].id=0;if(r)break;
    }
    if(r)break;
    slot=-1;for(unsigned k=0;k<32;k++)if(!export_notes[k].id){slot=(int)k;break;}
    if(slot<0)continue; /* more than 32 held notes: this one is left out */
    if(!pressure)pressure=1;
    export_notes[slot].id=id;export_notes[slot].note=(uint8_t)note;export_notes[slot].pressure=(uint8_t)pressure;export_notes[slot].time=time;
    r=export_record(time,1,(unsigned)slot,note,pressure);
   }else if(slot<0)continue; /* note began before recording, or was left out */
   else if(type==S11_CELL_NOTE_OFF){r=export_record(time,2,(unsigned)slot,0,0);export_notes[slot].id=0;}
   else{
    /* Pressure: at most one update per 20ms per note, and only on change. */
    if(pressure==export_notes[slot].pressure||time-export_notes[slot].time<export_rate/50u)continue;
    export_notes[slot].pressure=(uint8_t)pressure;export_notes[slot].time=time;
    r=export_record(time,3,(unsigned)slot,note,pressure);
   }
  }
 }
 for(unsigned k=0;!r&&k<32;k++)if(export_notes[k].id){r=export_record(export_end,2,k,0,0);export_notes[k].id=0;}
 if(!r&&export_origin==UINT64_MAX)r=S9_E_FORMAT;
 if(!r)r=export_record(export_end,4,0,0,0);
 if(!r&&export_have_pending){s9_put32(export_pending+12,1);memcpy(export_page+16+export_page_used*16,export_pending,16);export_page_used++;export_have_pending=0;}
 if(!r&&export_page_used)r=export_emit_page();
 if(f_close(&f)!=FR_OK)r=S9_E_IO;
 return r;
}
int s11_storage_export(uint64_t id){
 if(bus_fault_active())return S9_E_IO;
 if(id!=stats.recording_id)return S9_E_STALE;
 if(stats.state!=S11_STORE_SAVED||!(stats.kinds&S11_KIND_EVENT))return S9_E_STATE;
 int r=export_pass(0,0,0);if(r)return r;uint32_t count=export_count;uint64_t end=export_end;
 r=export_pass(0,count,end);if(r)return r;export_bytes=export_offset;uint32_t crc=~export_crc;
 s9_put64(export_identity,id);s9_put64(export_identity+8,id);r=s9_storage_begin(export_identity,export_bytes,crc,1);if(r)return r;
 r=export_pass(1,count,end);if(r){(void)s9_storage_cancel(export_identity);return r;}return s9_storage_commit(export_identity);
}
