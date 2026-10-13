/* Actual recorder files use the existing sole FatFs caller. Complete files
 * are not downloadable until sync, close and a separate reopen verification.
 * There is deliberately no power-fail atomicity claim. */
#include "s11_storage.h"
#include "s9_protocol.h"
#include "ff.h"
#include "diskio.h"
#include "s9_storage.h"
#include <string.h>
static FIL pcm_file,event_file;
static uint8_t page[512],event_page[512];
static char pcm_tmp[20],pcm_final[20],event_tmp[20],event_final[20];
static unsigned pcm_open,event_open,event_used;
static volatile int write_scope;
static uint32_t pcm_running_crc,event_running_crc;
static uint32_t file_number;
static s11_storage_stats stats;
static uint32_t update_crc(uint32_t c,const uint8_t *p,unsigned n){while(n--){c^=*p++;for(unsigned j=0;j<8;j++)c=c&1?(c>>1)^0xedb88320u:c>>1;}return c;}
static void name(char out[20],char prefix,uint32_t number,const char ext[4]){
 memcpy(out,"0:/",3);out[3]=prefix;for(unsigned i=0;i<7;i++){out[10-i]=(char)('0'+number%10);number/=10;}out[11]='.';memcpy(out+12,ext,4);
}
static uint32_t numbered_name(const char *s){
 if((s[0]!='W'&&s[0]!='E'&&s[0]!='M')||s[8]!='.'||strlen(s)!=12)return 0;
 uint32_t n=0;for(unsigned i=1;i<8;i++){if(s[i]<'0'||s[i]>'9')return 0;n=n*10u+(unsigned)(s[i]-'0');}return n;
}
/* The full 64-bit stream identity is independent of the 8.3 filename number.
 * Preparing/download occurs with maintenance allowed, never in a BLE callback.
 * Persisted files and retained partial files reserve their number across boots. */
static int allocate_number(uint32_t *out){
 DIR dir;FILINFO info;uint32_t maximum=0;if(f_opendir(&dir,"0:/")!=FR_OK)return S9_E_IO;int r=0;
 for(;;){if(f_readdir(&dir,&info)!=FR_OK){r=S9_E_IO;break;}if(!info.fname[0])break;uint32_t n=numbered_name(info.fname);if(n>maximum)maximum=n;}
 if(f_closedir(&dir)!=FR_OK)r=S9_E_IO;
 if(r)return r;
 if(maximum>=9999999)return S9_E_RANGE;
 *out=maximum+1;return 0;
}
static void wav_header(uint8_t b[512],uint32_t pairs){
 memset(b,0,512);memcpy(b,"RIFF",4);s9_put32(b+4,504u+4u*pairs);memcpy(b+8,"WAVEfmt ",8);s9_put32(b+16,16);s9_put16(b+20,1);s9_put16(b+22,2);s9_put32(b+24,48000);s9_put32(b+28,192000);s9_put16(b+32,4);s9_put16(b+34,16);memcpy(b+36,"JUNK",4);s9_put32(b+40,460);memcpy(b+504,"data",4);s9_put32(b+508,4u*pairs);
}
static void evr_header(uint8_t b[512]){
 memset(b,0,512);memcpy(b,"EVR2",4);s9_put32(b+4,2);s9_put64(b+8,stats.recording_id);s9_put32(b+16,48000);s9_put32(b+20,25000000);s9_put32(b+24,stats.event_units);s9_put32(b+28,stats.event_pages);s9_put64(b+32,stats.first_frame);s9_put64(b+40,stats.last_frame);s9_put64(b+48,stats.missing_frame);b[56]=stats.state; b[57]=stats.kinds;s9_put16(b+58,(uint16_t)stats.error);s9_put32(b+508,s9_crc32(b,508));
}
static int written(FIL *f,const uint8_t *b,unsigned bytes){UINT n=0;write_scope=1;FRESULT r=f_write(f,b,bytes,&n);write_scope=0;return r==FR_OK&&n==bytes?0:S9_E_IO;}
/* FatFs may flush a dirty partial sector while seeking back to a header.
 * This is still a recorder-owned write, including during media playback. */
static int seek_owned(FIL *f,FSIZE_t offset){write_scope=1;FRESULT r=f_lseek(f,offset);write_scope=0;return r==FR_OK?0:S9_E_IO;}
static int sync_file(FIL *f){write_scope=1;FRESULT r=f_sync(f);DRESULT d=r==FR_OK?disk_ioctl(0,CTRL_SYNC,0):RES_ERROR;write_scope=0;return r==FR_OK&&d==RES_OK?0:S9_E_IO;}
static int close_handle(FIL *f,unsigned *opened){if(!*opened)return 0;write_scope=1;FRESULT r=f_close(f);write_scope=0;*opened=0;return r==FR_OK?0:S9_E_IO;}
static int error(int e){stats.error=e;stats.state=S11_STORE_ERROR;return e;}
int s11_storage_write_authorized(void){return write_scope;}
const s11_storage_stats *s11_storage_statistics(void){return &stats;}
void s11_storage_failure(int reason){if(!stats.error)stats.error=reason?reason:S11_E_STORAGE;}
static int save_catalogue(void);
int s11_storage_prepare(uint64_t id,unsigned kinds){
 if(!id||!kinds||(kinds&~3u))return S9_E_RANGE;
 if(pcm_open||event_open||stats.state==S11_STORE_CAPTURING||stats.state==S11_STORE_DRAINING||stats.state==S11_STORE_VERIFY_PENDING)return S9_E_BUSY;
 int exists=s11_storage_select(id);if(!exists)return S9_E_CONFLICT;if(exists!=S9_E_EXPIRED)return exists;
 int nr=allocate_number(&file_number);if(nr)return nr;
 memset(&stats,0,sizeof stats);stats.recording_id=id;stats.kinds=(uint8_t)kinds;stats.first_frame=stats.last_frame=stats.missing_frame=UINT64_MAX;event_used=0;pcm_running_crc=event_running_crc=~0u;
 name(pcm_tmp,'W',file_number,"TMP");name(pcm_final,'W',file_number,"WAV");name(event_tmp,'E',file_number,"TMP");name(event_final,'E',file_number,"EVR");
 FILINFO info;if(f_stat(pcm_final,&info)==FR_OK||f_stat(event_final,&info)==FR_OK)return error(S9_E_CONFLICT);
 if(kinds&S11_KIND_PCM){if(f_open(&pcm_file,pcm_tmp,FA_CREATE_NEW|FA_READ|FA_WRITE)!=FR_OK)return error(S9_E_IO);pcm_open=1;wav_header(page,0);if(written(&pcm_file,page,512))goto fail;}
 if(kinds&S11_KIND_EVENT){if(f_open(&event_file,event_tmp,FA_CREATE_NEW|FA_READ|FA_WRITE)!=FR_OK)goto fail;event_open=1;evr_header(page);if(written(&event_file,page,512))goto fail;memset(event_page,0,512);}
 if((pcm_open&&sync_file(&pcm_file))||(event_open&&sync_file(&event_file)))goto fail;
 stats.state=S11_STORE_CAPTURING;return 0;
 fail:close_handle(&pcm_file,&pcm_open);close_handle(&event_file,&event_open);return error(S9_E_IO);
}
int s11_storage_pcm(uint64_t id,uint64_t first,const uint8_t *data,unsigned pairs){
 if(id!=stats.recording_id)return S9_E_STALE;
 if(stats.state!=S11_STORE_CAPTURING||!pcm_open)return S9_E_STATE;
 if(!data||!pairs||pairs>128||stats.pcm_bytes>1073741824u-pairs*4u)return S9_E_RANGE;
 if(stats.captured_pairs&&first!=stats.last_frame+1)return error(S9_E_SEQUENCE);
 if(first>UINT64_MAX-(pairs-1))return error(S9_E_RANGE);
 if(written(&pcm_file,data,pairs*4))return error(S9_E_IO);
 if(!stats.captured_pairs)stats.first_frame=first;
 stats.last_frame=first+pairs-1;stats.captured_pairs+=pairs;stats.pcm_bytes+=pairs*4;stats.written_pcm+=pairs*4;pcm_running_crc=update_crc(pcm_running_crc,data,pairs*4);return 0;
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
  if(!(stats.kinds&S11_KIND_PCM)){if(!stats.event_units)stats.first_frame=frame;stats.last_frame=frame;}
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
static int verify_file(const char *name,unsigned kind){
 FIL f;UINT n;uint32_t bytes=kind==S11_KIND_PCM?stats.pcm_bytes:stats.event_pages*512u;uint32_t expected=kind==S11_KIND_PCM?stats.pcm_crc:stats.event_crc;
 if(f_open(&f,name,FA_READ)!=FR_OK)return S9_E_IO;
 int r=0;if(f_size(&f)!=(FSIZE_t)512+bytes)r=S9_E_LENGTH;
 if(!r&&(f_read(&f,page,512,&n)!=FR_OK||n!=512))r=S9_E_IO;
 if(!r&&kind==S11_KIND_PCM){uint8_t expected_header[512];wav_header(expected_header,stats.captured_pairs);if(memcmp(page,expected_header,512))r=S9_E_FORMAT;}
 if(!r&&kind==S11_KIND_EVENT){if((memcmp(page,"EVR1",4)&&memcmp(page,"EVR2",4))||s9_get64(page+8)!=stats.recording_id||s9_crc32(page,508)!=s9_get32(page+508))r=S9_E_CRC;}
 uint32_t c=~0u,full=update_crc(~0u,page,512),offset=0;
 while(!r&&offset<bytes){unsigned want=bytes-offset;if(want>512)want=512;if(f_read(&f,page,want,&n)!=FR_OK||n!=want){r=S9_E_IO;break;}if(kind==S11_KIND_EVENT&&(memcmp(page,"E11P",4)||s9_get16(page+4)!=1||s9_get16(page+6)>15||s9_get32(page+8)!=offset/512+1||s9_get64(page+12)!=stats.recording_id||s9_crc32(page,508)!=s9_get32(page+508))){r=S9_E_CRC;break;}c=update_crc(c,page,want);full=update_crc(full,page,want);offset+=want;}
 if(!r&&~c!=expected)r=S9_E_CRC;
 if(f_close(&f)!=FR_OK)r=S9_E_IO;
 if(!r){if(kind==S11_KIND_PCM){stats.verified_pcm=bytes;stats.pcm_file_crc=~full;}else{stats.verified_event=bytes;stats.event_file_crc=~full;}}return r;
}
static void catalogue(uint8_t b[512]){
 memset(b,0,512);memcpy(b,"S11M",4);s9_put32(b+4,1);s9_put64(b+8,stats.recording_id);b[16]=stats.kinds;b[17]=stats.state==S11_STORE_VERIFY_PENDING?S11_STORE_SAVED:stats.state;s9_put32(b+20,stats.captured_pairs);s9_put32(b+24,stats.event_units);s9_put32(b+28,stats.event_pages);s9_put32(b+32,stats.pcm_bytes);s9_put32(b+36,stats.pcm_file_crc);s9_put32(b+40,stats.event_file_crc);s9_put32(b+44,stats.pcm_crc);s9_put32(b+48,stats.event_crc);s9_put64(b+56,stats.first_frame);s9_put64(b+64,stats.last_frame);
 /* Normal SAVED catalog bytes remain compatible. Only partial files use
  * reserved error32@52 and first_missing_frame64@72; CRC covers0..507. */
 if(b[17]!=S11_STORE_SAVED){s9_put32(b+52,(uint32_t)stats.error);s9_put64(b+72,stats.missing_frame);}
 s9_put32(b+508,s9_crc32(b,508));
}
static int save_catalogue(void){
 char path[20];name(path,'M',file_number,"MET");catalogue(page);FIL f;
 if(f_open(&f,path,FA_WRITE|FA_READ|FA_CREATE_NEW)!=FR_OK)return S9_E_IO;
 int r=written(&f,page,512);if(!r)r=sync_file(&f);unsigned open=1;if(close_handle(&f,&open))r=S9_E_IO;
 if(r)return r;
 if(f_open(&f,path,FA_READ)!=FR_OK)return S9_E_IO;
 UINT n;uint8_t check[512];
 r=f_read(&f,check,512,&n)==FR_OK&&n==512&&f_size(&f)==512&&!memcmp(check,page,512)?0:S9_E_IO;if(f_close(&f)!=FR_OK)r=S9_E_IO;return r;
}
int s11_storage_select(uint64_t id){
 if(!id)return S9_E_RANGE;
 if(pcm_open||event_open||stats.state==S11_STORE_VERIFY_PENDING)return S9_E_BUSY;
 if(id==stats.recording_id&&stats.state==S11_STORE_SAVED)return 0;
 DIR dir;FILINFO info;int r=S9_E_EXPIRED;uint32_t found=0;if(f_opendir(&dir,"0:/")!=FR_OK)return S9_E_IO;
 for(;;){if(f_readdir(&dir,&info)!=FR_OK){r=S9_E_IO;break;}if(!info.fname[0])break;uint32_t number=numbered_name(info.fname);if(!number||info.fname[0]!='M'||strcmp(info.fname+9,"MET"))continue;
  char path[20];name(path,'M',number,"MET");FIL f;if(f_open(&f,path,FA_READ)!=FR_OK){r=S9_E_IO;break;}UINT n;int read=f_read(&f,page,512,&n)==FR_OK&&n==512&&f_size(&f)==512?0:S9_E_IO;if(f_close(&f)!=FR_OK)read=S9_E_IO;if(read){r=read;break;}
  if(!memcmp(page,"S11M",4)&&s9_get64(page+8)==id){found=number;r=0;break;}
 }
 if(f_closedir(&dir)!=FR_OK)r=S9_E_IO;
 if(r)return r;
 file_number=found;
 if(memcmp(page,"S11M",4)||s9_get32(page+4)!=1||s9_get64(page+8)!=id||(page[17]!=S11_STORE_SAVED&&page[17]!=S11_STORE_INCOMPLETE&&page[17]!=S11_STORE_ERROR)||s9_crc32(page,508)!=s9_get32(page+508))return S9_E_CRC;
 memset(&stats,0,sizeof stats);stats.recording_id=id;stats.kinds=page[16];stats.state=page[17];stats.captured_pairs=s9_get32(page+20);stats.event_units=s9_get32(page+24);stats.event_pages=s9_get32(page+28);stats.pcm_bytes=s9_get32(page+32);stats.pcm_file_crc=s9_get32(page+36);stats.event_file_crc=s9_get32(page+40);stats.pcm_crc=s9_get32(page+44);stats.event_crc=s9_get32(page+48);stats.first_frame=s9_get64(page+56);stats.last_frame=s9_get64(page+64);stats.written_pcm=stats.pcm_bytes;stats.written_event=stats.event_pages*512;
 if(stats.state==S11_STORE_SAVED){stats.verified_pcm=stats.pcm_bytes;stats.verified_event=stats.event_pages*512;stats.missing_frame=UINT64_MAX;}else{stats.error=(int32_t)s9_get32(page+52);stats.missing_frame=s9_get64(page+72);}
 name(pcm_final,'W',file_number,"WAV");name(event_final,'E',file_number,"EVR");return 0;
}
int s11_storage_verify(void){
 if(stats.state!=S11_STORE_VERIFY_PENDING||pcm_open||event_open)return S9_E_STATE;
 int r=0;if((stats.kinds&S11_KIND_PCM)&&(r=verify_file(pcm_tmp,S11_KIND_PCM)))return error(r);
 if((stats.kinds&S11_KIND_EVENT)&&(r=verify_file(event_tmp,S11_KIND_EVENT)))return error(r);
 /* No replacement: recording IDs and FA_CREATE_NEW protect previous files.
  * Rename failures leave TMP/prefix evidence and never advertise SAVED. */
 write_scope=1;
 if((stats.kinds&S11_KIND_PCM)&&f_rename(pcm_tmp,pcm_final)!=FR_OK)r=S9_E_IO;
 if(!r&&(stats.kinds&S11_KIND_EVENT)&&f_rename(event_tmp,event_final)!=FR_OK)r=S9_E_IO;
 if(!r&&disk_ioctl(0,CTRL_SYNC,0)!=RES_OK)r=S9_E_IO;
 write_scope=0;if(r)return error(r);
 if((stats.kinds&S11_KIND_PCM)&&(r=verify_file(pcm_final,S11_KIND_PCM)))return error(r);
 if((stats.kinds&S11_KIND_EVENT)&&(r=verify_file(event_final,S11_KIND_EVENT)))return error(r);
 if((r=save_catalogue()))return error(r);
 stats.state=S11_STORE_SAVED;return 0;
}
int s11_storage_download(uint64_t id,unsigned kind,uint32_t offset,uint8_t *out,unsigned cap,unsigned *count){
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
/* SCORE v1 is a note-layer export under the reset sound configuration:
 * ID0, no Glide, center Pan, unity settled Gain, closed external stream,
 * reset/bypassed Effects and the default physical-key map. It does not encode
 * arbitrary initial sound settings. Read-only versions/frame IDs may vary. */
static int export_initial(unsigned index,unsigned type,uint64_t payload,uint16_t subcycle){
 static const uint8_t types[16]={14,15,19,21,18,21,21,21,17,21,21,21,21,21,20,21};
 if(index>=16||type!=types[index])return 0;
 switch(index){
  case 0:case 1:return payload==subcycle;
  case 2:return payload==((uint64_t)72<<49|(uint64_t)71<<42|(uint64_t)69<<35|(uint64_t)67<<28|(uint64_t)65<<21|(uint64_t)64<<14|(uint64_t)62<<7|60u);
  case 3:return (payload>>48)==0&&(uint16_t)payload==subcycle;
  case 4:return payload==((uint64_t)4<<58|(uint64_t)32768<<32|(uint64_t)32768<<16|subcycle);
  case 5:return payload==UINT64_C(0x8000800080008000);
  case 6:return 1; /* accepted/frame-version observations only */
  case 7:return (uint32_t)payload==0; /* gain_frame32, reserved32 */
  case 8:return payload==((uint64_t)11520<<32|8u);
  case 9:return payload==((uint64_t)576<<32|12288u);
  case 10:return payload==((uint64_t)71583<<32|192u);
  case 11:return payload==((uint64_t)16384<<32|24576u);
  case 12:return payload==((uint64_t)4096<<32|6144u);
  case 13:return (uint32_t)payload==4096; /* FXversion metadata */
  case 14:return payload>>51==0&&((payload>>16)&7u)==0&&(uint16_t)payload==subcycle;
  case 15:return 1; /* identity of an already closed stream only */
  default:return 0;
 }
}
static int export_emit_page(void){
 if(export_page_sequence){s9_put32(export_page,export_page_sequence);s9_put16(export_page+4,(uint16_t)export_page_used);}
 s9_put32(export_page+508,s9_crc32(export_page,508));export_crc=update_crc(export_crc,export_page,512);
 if(export_write){int r=s9_storage_append(export_identity,export_offset,export_page,500);if(r)return r;r=s9_storage_append(export_identity,export_offset+500,export_page+500,12);if(r)return r;}
 export_offset+=512;export_page_sequence++;export_page_used=0;memset(export_page,0,512);return 0;
}
static int export_record(uint64_t time,unsigned op,unsigned key,unsigned note,unsigned pressure){
 if(export_count>=1000000)return S9_E_RANGE;
 if(export_count&&time<export_previous)return S9_E_SEQUENCE;
 if(export_count>=128&&time-export_density[export_count%128]<4800)return S9_E_RANGE;
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
 /* First pass counts only; second/third use the fixed counted header. */
 memcpy(export_page,"S7EV",4);s9_put32(export_page+4,1);s9_put32(export_page+8,48000);s9_put32(export_page+12,expected_records);s9_put64(export_page+16,end);
 int r=export_emit_page();if(r){f_close(&f);return r;}
 if(f_read(&f,page,512,&n)!=FR_OK||n!=512){f_close(&f);return S9_E_IO;}
 unsigned v2=!memcmp(page,"EVR2",4)&&s9_get32(page+4)==2;
 if(!v2&&(memcmp(page,"EVR1",4)||s9_get32(page+4)!=1)){f_close(&f);return S9_E_FORMAT;}
 uint32_t cell_sequence=0;unsigned initial_index=0,batch_pending=0;uint16_t initial_subcycle=0;
 for(uint32_t page_index=0;!r&&page_index<stats.event_pages;page_index++){
  if(f_read(&f,page,512,&n)!=FR_OK||n!=512){r=S9_E_IO;break;}
  if(memcmp(page,"E11P",4)||s9_get32(page+8)!=page_index+1||s9_crc32(page,508)!=s9_get32(page+508)){r=S9_E_CRC;break;}
  unsigned count=s9_get16(page+6);if(!count||count>15){r=S9_E_FORMAT;break;}
  for(unsigned i=0;!r&&i<count;i++){
   const uint8_t *c=page+28+i*32;unsigned type=c[0],flags=c[1];uint64_t frame=s9_get64(c+8),id=s9_get64(c+16),payload=s9_get64(c+24);
   if(s9_get32(c+4)!=cell_sequence++){r=S9_E_SEQUENCE;break;}
   if(type==S11_CELL_START){if(export_origin!=UINT64_MAX||id||payload>>16||flags!=3){r=S9_E_FORMAT;break;}export_origin=frame;initial_subcycle=(uint16_t)payload;continue;}
   if(export_origin==UINT64_MAX||frame<export_origin){r=S9_E_FORMAT;break;}uint64_t time=frame-export_origin;export_end=time;
   if((flags&S11_CELL_INITIAL)&&(type>=S11_CELL_TIMBRE&&type<=S11_CELL_CONFIG_EXTENSION)){
    if(frame!=export_origin||id||c[2]!=255||c[3]!=255||!export_initial(initial_index,type,payload,initial_subcycle)){r=S9_E_FORMAT;break;}initial_index++;continue;
   }
   if(initial_index!=16){r=S9_E_FORMAT;break;}
   if(type==S11_CELL_PUBLISH){if(flags!=(v2?1:5)||id||c[2]!=255||c[3]!=255||payload>>48){r=S9_E_FORMAT;break;}batch_pending=0;continue;}
   if(type==S11_CELL_BIND_ID||type==S11_CELL_BIND_TOKEN||type==S11_CELL_RECLAIM)continue;
   if(type==S11_CELL_END){if(batch_pending||flags!=1||id){r=S9_E_FORMAT;break;}
    if(v2)for(unsigned k=0;k<32;k++)if(export_notes[k].id){r=export_record(time,2,k,0,0);export_notes[k].id=0;if(r)break;}
    continue;}
   if(type!=S11_CELL_NOTE_ON&&type!=S11_CELL_NOTE_OFF&&type!=S11_CELL_EXPRESSION){r=S9_E_FORMAT;break;}
   unsigned note=(unsigned)((payload>>16)&127),pressure=(unsigned)((payload>>23)&255);int slot=-1;batch_pending=1;
   if(((payload>>31)&7u)!=0||((payload>>34)&511u)!=128){r=S9_E_FORMAT;break;}
   for(unsigned k=0;k<32;k++)if(export_notes[k].id==id&&id){slot=(int)k;break;}
   if(v2&&type==S11_CELL_NOTE_ON)for(unsigned k=0;k<32;k++)if(export_notes[k].id&&((export_notes[k].id&31)==(id&31))){
    r=export_record(time,2,k,0,0);export_notes[k].id=0;if((int)k==slot)slot=-1;if(r)break;
   }
   if(r)break;
   if(type==S11_CELL_NOTE_ON){if(slot>=0||!pressure){r=S9_E_FORMAT;break;}for(unsigned k=0;k<32;k++)if(!export_notes[k].id){slot=(int)k;break;}if(slot<0){r=S9_E_RANGE;break;}export_notes[slot].id=id;export_notes[slot].note=(uint8_t)note;export_notes[slot].pressure=(uint8_t)pressure;r=export_record(time,1,(unsigned)slot,note,pressure);}
   else {if(slot<0){r=S9_E_STALE;break;}r=export_record(time,type==S11_CELL_NOTE_OFF?2:3,(unsigned)slot,type==S11_CELL_NOTE_OFF?0:note,type==S11_CELL_NOTE_OFF?0:pressure);if(type==S11_CELL_NOTE_OFF)export_notes[slot].id=0;}
  }
 }
 for(unsigned i=0;!r&&i<32;i++)if(export_notes[i].id)r=S9_E_STATE;
 if(!r&&export_origin==UINT64_MAX)r=S9_E_FORMAT;
 if(!r)r=export_record(export_end,4,0,0,0);
 if(!r&&export_have_pending){s9_put32(export_pending+12,1);memcpy(export_page+16+export_page_used*16,export_pending,16);export_page_used++;export_have_pending=0;}
 if(!r&&export_page_used)r=export_emit_page();
 if(f_close(&f)!=FR_OK)r=S9_E_IO;
 return r;
}
int s11_storage_export(uint64_t id){
 if(id!=stats.recording_id)return S9_E_STALE;
 if(stats.state!=S11_STORE_SAVED||!(stats.kinds&S11_KIND_EVENT))return S9_E_STATE;
 int r=export_pass(0,0,0);if(r)return r;uint32_t count=export_count;uint64_t end=export_end;
 r=export_pass(0,count,end);if(r)return r;export_bytes=export_offset;uint32_t crc=~export_crc;
 s9_put64(export_identity,id);s9_put64(export_identity+8,id);r=s9_storage_begin(export_identity,export_bytes,crc,1);if(r)return r;
 r=export_pass(1,count,end);if(r){(void)s9_storage_cancel(export_identity);return r;}return s9_storage_commit(export_identity);
}
