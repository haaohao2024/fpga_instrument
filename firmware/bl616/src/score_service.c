#include "audio_timebase.h"
#include "score_service.h"
#include "score_hal.h"
#include "ff.h"
#include "s11_service.h"
#include <string.h>
static FATFS fs;static FIL file;static uint8_t header[512];static int file_opened;
static volatile int cancelled=1;static uint64_t stream_epoch;static uint32_t next_sequence,pages;
static uint32_t rd32(const uint8_t *b){return (uint32_t)b[0]|(uint32_t)b[1]<<8|(uint32_t)b[2]<<16|(uint32_t)b[3]<<24;}
static void wr32(uint8_t *b,uint32_t x){for(int i=0;i<4;i++)b[i]=x>>(i*8);}
static void wr64(uint8_t *b,uint64_t x){for(int i=0;i<8;i++)b[i]=x>>(i*8);}
uint32_t score_crc(const uint8_t *b,unsigned n){uint32_t c=~0u;while(n--){c^=*b++;for(int i=0;i<8;i++)c=c&1?(c>>1)^0xedb88320u:c>>1;}return ~c;}
void score_cancel(void){cancelled=1;}
int score_is_cancelled(void){return cancelled;}
int score_close(void){cancelled=1;if(!file_opened)return 0;file_opened=0;return f_close(&file)==FR_OK?0:-1;}
static int open_failed(int error){score_close();return error;}
unsigned score_default_mode(void){return rd32(header+24);}
int score_open(uint64_t epoch){
 if(!epoch)return -1;
 if(score_close())return -2;
 cancelled=0;stream_epoch=epoch;next_sequence=0;
 if(!s11_service_active()){
  f_mount(0,"0:",0);
  if(f_mount(&fs,"0:",1)!=FR_OK||fs.fs_type!=FS_FAT32)return -2;
 }
 if(f_open(&file,"0:/SCORE.EVT",FA_READ)!=FR_OK)return -3;
 file_opened=1;
 UINT n;if(f_read(&file,header,512,&n)!=FR_OK||n!=512||cancelled)return open_failed(-4);
 uint32_t records=rd32(header+12);
 if(memcmp(header,"S7EV",4)||rd32(header+4)!=1||!audio_file_rate(rd32(header+8))||!records||records>1000000||rd32(header+24)>1||score_crc(header,508)!=rd32(header+508))return open_failed(-5);
 for(int i=28;i<508;i++)if(header[i])return open_failed(-5);
 pages=1+(records+29)/30;
 if(f_size(&file)!=(FSIZE_t)pages*512)return open_failed(-6);
 return 0;
}
int score_next(uint8_t page[512],uint32_t *sequence,uint64_t epoch){
 if(cancelled||epoch!=stream_epoch)return -7;
 if(next_sequence==pages)return 1;
 if(!next_sequence)memcpy(page,header,512);
 else{UINT n;FRESULT r=f_read(&file,page,512,&n);if(r!=FR_OK||n!=512||cancelled||epoch!=stream_epoch)return -8;
  if(score_crc(page,508)!=rd32(page+508)||rd32(page)!=next_sequence)return -9;
 }
 *sequence=next_sequence++;return 0;
}
#ifdef S9_RUNTIME
#define score_send score_bus_send
#endif
int score_send(uint8_t cmd,uint64_t epoch,uint32_t seq,uint64_t arg,const uint8_t *payload,unsigned len,uint8_t response[32]){
 uint8_t message[548]={0};if(len>512||(cmd==2?len!=512:len!=0))return -1;
 memcpy(message,"S7PK",4);message[4]=1;message[5]=cmd;wr64(message+8,epoch);wr32(message+16,seq);
 message[20]=len;message[21]=len>>8;wr64(message+24,arg);if(len)memcpy(message+32,payload,len);wr32(message+32+len,score_crc(message,32+len));
 if(hal_select(BUS_FPGA))return -2;
 hal_delay_us(1);
 for(unsigned i=0;i<36+len;i++){uint8_t x=hal_exchange(message[i]);if(i<32)response[i]=x;}
 int bad=hal_io_failed();hal_delay_us(1);bad|=hal_select(BUS_NONE)!=0;hal_exchange(255);bad|=hal_io_failed();if(bad)return -2;
 if(memcmp(response,"S7ST",4)||response[4]!=1||score_crc(response,28)!=rd32(response+28))return -3;
 return 0;
}
