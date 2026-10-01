#include "score_service.h"
#include "score_hal.h"
#include "ff.h"
#include <string.h>
static FATFS fs;static FIL file;static uint8_t header[512];
static volatile int cancelled=1;static uint64_t stream_epoch;static uint32_t next_sequence,pages;
static uint32_t rd32(const uint8_t *b){return (uint32_t)b[0]|(uint32_t)b[1]<<8|(uint32_t)b[2]<<16|(uint32_t)b[3]<<24;}
static void wr32(uint8_t *b,uint32_t x){for(int i=0;i<4;i++)b[i]=x>>(i*8);}
static void wr64(uint8_t *b,uint64_t x){for(int i=0;i<8;i++)b[i]=x>>(i*8);}
uint32_t score_crc(const uint8_t *b,unsigned n){uint32_t c=~0u;while(n--){c^=*b++;for(int i=0;i<8;i++)c=c&1?(c>>1)^0xedb88320u:c>>1;}return ~c;}
void score_cancel(void){cancelled=1;}
int score_is_cancelled(void){return cancelled;}
unsigned score_default_mode(void){return rd32(header+24);}
int score_open(uint64_t epoch){
 if(!epoch)return -1;
 cancelled=0;stream_epoch=epoch;next_sequence=0;
 f_mount(0,"0:",0);
 if(f_mount(&fs,"0:",1)!=FR_OK||fs.fs_type!=FS_FAT32)return -2;
 if(f_open(&file,"0:/SCORE.EVT",FA_READ)!=FR_OK)return -3;
 UINT n;if(f_read(&file,header,512,&n)!=FR_OK||n!=512||cancelled)return -4;
 uint32_t records=rd32(header+12);
 if(memcmp(header,"S7EV",4)||rd32(header+4)!=1||rd32(header+8)!=48000||!records||records>1000000||rd32(header+24)>1||score_crc(header,508)!=rd32(header+508))return -5;
 for(int i=28;i<508;i++)if(header[i])return -5;
 pages=1+(records+29)/30;
 if(f_size(&file)!=(FSIZE_t)pages*512)return -6;
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
int score_send(uint8_t cmd,uint64_t epoch,uint32_t seq,uint64_t arg,const uint8_t *payload,unsigned len,uint8_t response[32]){
 uint8_t message[548]={0};if(len>512||(cmd==2?len!=512:len!=0))return -1;
 memcpy(message,"S7PK",4);message[4]=1;message[5]=cmd;wr64(message+8,epoch);wr32(message+16,seq);
 message[20]=len;message[21]=len>>8;wr64(message+24,arg);if(len)memcpy(message+32,payload,len);wr32(message+32+len,score_crc(message,32+len));
 if(hal_select(BUS_FPGA))return -2;
 hal_delay_us(1);
 for(unsigned i=0;i<36+len;i++){uint8_t x=hal_exchange(message[i]);if(i<32)response[i]=x;}
 hal_delay_us(1);hal_select(BUS_NONE);hal_exchange(255);
 if(memcmp(response,"S7ST",4)||response[4]!=1||score_crc(response,28)!=rd32(response+28))return -3;
 return 0;
}
