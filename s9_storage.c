#include "s9_storage.h"
#include "s9_protocol.h"
#include "s9_score_check.h"
#include "ff.h"
#include "diskio.h"
#include <string.h>
static FATFS fs;
static FIL file;
static uint8_t owner_id[16],page[512];
static uint32_t expected_bytes,expected_crc;
static int opened;
static s9_storage_stats stats;
static s9_score_check checker;
static s9_storage_cancel_fn cancelled;
static s9_storage_progress_fn progress;
static void *context;
void s9_storage_hooks(s9_storage_cancel_fn c,s9_storage_progress_fn p,void *x){cancelled=c;progress=p;context=x;}
const s9_storage_stats *s9_storage_statistics(void){return &stats;}
static int aborted(void){return cancelled&&cancelled(context);}
static int owner(const uint8_t id[16]){return stats.active&&!memcmp(id,owner_id,16);}
static int sync_disk(void){return disk_ioctl(0,CTRL_SYNC,0)==RES_OK?0:S9_E_IO;}
static int close_file(void){if(!opened)return 0;opened=0;return f_close(&file)==FR_OK?0:S9_E_IO;}
static int fail(int code){close_file();stats.active=0;return code;}
static int exists(const char *name){FILINFO i;FRESULT r=f_stat(name,&i);return r==FR_OK?1:r==FR_NO_FILE?0:-1;}
static int remove_if_present(const char *name){int e=exists(name);if(e<0)return S9_E_IO;if(e&&f_unlink(name)!=FR_OK)return S9_E_IO;return sync_disk();}
/* Startup recovery runs in the sole file task before any score handle opens.
 * Validate complete file structure/page CRCs; existence alone is not validity.
 * I/O failures do not authorize deleting a current file. */
static int validate_saved(const char *name){
 FRESULT fr=f_open(&file,name,FA_READ);
 if(fr==FR_NO_FILE)return S9_E_EXPIRED;
 if(fr!=FR_OK)return S9_E_IO;
 opened=1;FSIZE_t bytes=f_size(&file);int result=0;
 if(bytes<1024||bytes>S9_MAX_SCORE_BYTES||bytes%512)result=S9_E_FORMAT;
 for(uint32_t offset=0;!result&&offset<bytes;offset+=512){
  UINT n;
  if(f_read(&file,page,512,&n)!=FR_OK||n!=512){result=S9_E_IO;break;}
  result=offset?s9_score_page(&checker,page):s9_score_header(&checker,page,(uint32_t)bytes);
 }
 if(!result)result=s9_score_finish(&checker);
 if(close_file())result=S9_E_IO;
 return result;
}
int s9_storage_recover(void){
 if(stats.active||opened)return S9_E_STATE;
 f_mount(0,"0:",0);
 if(f_mount(&fs,"0:",1)!=FR_OK||fs.fs_type!=FS_FAT32)return S9_E_IO;
 int current=validate_saved("0:/SCORE.EVT");
 if(!current)return 0;
 if(current==S9_E_IO)return current;
 int backup=validate_saved("0:/SCORE.BAK");
 if(backup)return backup;
 if(current!=S9_E_EXPIRED&&remove_if_present("0:/SCORE.EVT"))return S9_E_IO;
 if(f_rename("0:/SCORE.BAK","0:/SCORE.EVT")!=FR_OK||sync_disk())return S9_E_IO;
 return validate_saved("0:/SCORE.EVT");
}
int s9_storage_begin(const uint8_t id[16],uint32_t bytes,uint32_t crc,int stopped){
 if(!stopped||stats.active)return S9_E_STATE;
 if(!s9_get64(id)||!s9_get64(id+8)||bytes<1024||bytes>S9_MAX_SCORE_BYTES||bytes%512)return S9_E_RANGE;
 if(aborted())return S9_E_STATE;
 memset(&stats,0,sizeof stats);opened=0;memcpy(owner_id,id,16);expected_bytes=bytes;expected_crc=crc;
 f_mount(0,"0:",0);
 if(f_mount(&fs,"0:",1)!=FR_OK||fs.fs_type!=FS_FAT32)return S9_E_IO;
 /* Recover only the unambiguous missing-current / present-backup case.
  * Existing files are still validated by the score reader; no powerfail claim. */
 int current=exists("0:/SCORE.EVT"),backup=exists("0:/SCORE.BAK");
 if(current<0||backup<0)return S9_E_IO;
 if(!current&&backup){
  int recovery=validate_saved("0:/SCORE.BAK");if(recovery)return recovery;
  if(f_rename("0:/SCORE.BAK","0:/SCORE.EVT")!=FR_OK||sync_disk())return S9_E_IO;
 }
 if(f_open(&file,"0:/SCORE.TMP",FA_WRITE|FA_READ|FA_CREATE_ALWAYS)!=FR_OK)return S9_E_IO;
 opened=1;stats.active=1;return 0;
}
int s9_storage_append(const uint8_t id[16],uint32_t offset,const uint8_t *data,unsigned length){
 if(!owner(id))return S9_E_SESSION;
 if(aborted())return fail(S9_E_STATE);
 if(!data||!length||length>500||offset>expected_bytes||length>expected_bytes-offset)return S9_E_RANGE;
 UINT n;
 if(offset<stats.written){
  if(length>stats.written-offset)return S9_E_CONFLICT;
  if(f_lseek(&file,offset)!=FR_OK||f_read(&file,page,length,&n)!=FR_OK||n!=length)return fail(S9_E_IO);
  int different=memcmp(page,data,length)!=0;
  if(f_lseek(&file,stats.written)!=FR_OK)return fail(S9_E_IO);
  return different?S9_E_CONFLICT:0;
 }
 if(offset!=stats.written)return S9_E_SEQUENCE;
 stats.received+=length;
 if(f_write(&file,data,length,&n)!=FR_OK||n!=length)return fail(S9_E_IO);
 stats.written+=length;
 if(progress)progress(context,stats.written,1);
 return 0;
}
static uint32_t crc_update(uint32_t c,const uint8_t *p,unsigned n){while(n--){c^=*p++;for(unsigned j=0;j<8;j++)c=c&1?(c>>1)^0xedb88320u:c>>1;}return c;}
static int check_file(const char *name,unsigned phase){
 if(f_open(&file,name,FA_READ)!=FR_OK)return S9_E_IO;
 opened=1;
 if(f_size(&file)!=expected_bytes)return fail(S9_E_FORMAT);
 uint32_t crc=~0u;
 for(uint32_t offset=0;offset<expected_bytes;offset+=512){
  UINT n;if(aborted())return fail(S9_E_STATE);
  if(f_read(&file,page,512,&n)!=FR_OK||n!=512)return fail(S9_E_IO);
  int r=offset?s9_score_page(&checker,page):s9_score_header(&checker,page,expected_bytes);
  if(r)return fail(r);
  crc=crc_update(crc,page,512);stats.checked=offset+512;
  if(progress)progress(context,stats.checked,phase);
 }
 if(~crc!=expected_crc||s9_score_finish(&checker))return fail(S9_E_CRC);
 return close_file();
}
int s9_storage_commit(const uint8_t id[16]){
 if(!owner(id))return S9_E_SESSION;
 if(aborted())return fail(S9_E_STATE);
 if(stats.written!=expected_bytes)return S9_E_LENGTH;
 if(f_sync(&file)!=FR_OK||sync_disk())return fail(S9_E_IO);
 stats.synced=stats.written;
 if(close_file())return fail(S9_E_IO);
 int r=check_file("0:/SCORE.TMP",2);if(r)return r;
 if(aborted())return fail(S9_E_STATE);
 int current=exists("0:/SCORE.EVT");if(current<0)return fail(S9_E_IO);
 if(current){
  if(remove_if_present("0:/SCORE.BAK"))return fail(S9_E_IO);
  if(f_rename("0:/SCORE.EVT","0:/SCORE.BAK")!=FR_OK||sync_disk())return fail(S9_E_IO);
 }
 if(aborted())return fail(S9_E_STATE);
 if(f_rename("0:/SCORE.TMP","0:/SCORE.EVT")!=FR_OK||sync_disk())return fail(S9_E_IO);
 stats.replaced=expected_bytes;
 r=check_file("0:/SCORE.EVT",3);if(r)return r;
 if(sync_disk())return fail(S9_E_IO);
 stats.active=0;return 0; /* Only this complete path permits SAVED. */
}
int s9_storage_cancel(const uint8_t id[16]){
 if(memcmp(id,owner_id,16))return S9_E_SESSION;
 int r=close_file();stats.active=0;
 /* A failed/cancelled replacement may have left BAK as the only prior score.
  * Never delete BAK here, and never claim cancellation undid a rename. */
 if(r)return r;
 return remove_if_present("0:/SCORE.TMP");
}
