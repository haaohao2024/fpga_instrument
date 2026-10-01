#include "score_hal.h"
#include "ff.h"
#include "diskio.h"
#include <string.h>
static DSTATUS status=STA_NOINIT;
static uint32_t sectors;
static uint16_t crc16(const uint8_t *b,unsigned n){uint16_t c=0;while(n--){c^=(uint16_t)*b++<<8;for(int i=0;i<8;i++)c=c&0x8000?(c<<1)^0x1021:c<<1;}return c;}
static void release(void){hal_select(BUS_NONE);hal_exchange(255);}
static int wait_ready(uint64_t timeout){uint64_t start=hal_time_us();do{if(hal_cancelled())return -1;if(hal_exchange(255)==255)return 0;}while(hal_time_us()-start<timeout);return -1;}
static int command(uint8_t cmd,uint32_t arg){
 if(hal_select(BUS_SD)||wait_ready(300000))return -1;
 uint8_t b[6]={0x40|cmd,arg>>24,arg>>16,arg>>8,arg,(cmd==0)?0x95:(cmd==8)?0x87:1};
 for(unsigned i=0;i<6;i++)hal_exchange(b[i]);
 for(unsigned i=0;i<16;i++){uint8_t r=hal_exchange(255);if(!(r&128))return r;if(hal_cancelled())return -1;}
 return -1;
}
static int read_block(uint8_t *b,unsigned n){
 uint64_t start=hal_time_us();uint8_t token;
 do{if(hal_cancelled())return -1;token=hal_exchange(255);if(token==0xfe)break;if(token!=255)return -1;}while(hal_time_us()-start<300000);
 if(token!=0xfe)return -1;
 for(unsigned i=0;i<n;i++){if(hal_cancelled())return -1;b[i]=hal_exchange(255);}
 uint16_t crc=(uint16_t)hal_exchange(255)<<8;crc|=hal_exchange(255);
 return crc==crc16(b,n)?0:-1;
}
DSTATUS disk_initialize(BYTE drive){
 if(drive)return STA_NOINIT;
 status=STA_NOINIT;sectors=0;hal_frequency(400000);release();for(int i=0;i<10;i++)hal_exchange(255);
 if(command(0,0)!=1)goto fail;
 release();
 if(command(8,0x1aa)!=1)goto fail;
 uint8_t r7[4];for(int i=0;i<4;i++)r7[i]=hal_exchange(255);release();
 if(r7[2]!=1||r7[3]!=0xaa)goto fail;
 uint64_t start=hal_time_us();int r;
 do{if(command(55,0)!=1)goto fail;release();r=command(41,0x40000000);release();if(r<0||hal_cancelled())goto fail;}while(r==1&&hal_time_us()-start<1000000);
 if(r!=0||command(58,0)!=0)goto fail;
 uint32_t ocr=0;for(int i=0;i<4;i++)ocr=(ocr<<8)|hal_exchange(255);release();if((ocr&0xc0000000)!=0xc0000000)goto fail;
 if(command(9,0)!=0)goto fail;
 uint8_t csd[16];if(read_block(csd,16)||csd[0]>>6!=1)goto fail;release();
 uint32_t size=((uint32_t)(csd[7]&63)<<16)|((uint32_t)csd[8]<<8)|csd[9];
 if(size==0x3fffff)goto fail;
 sectors=(size+1)*1024;
 hal_frequency(2000000);status=0;return status;
 fail: release();return status;
}
DSTATUS disk_status(BYTE drive){return drive?STA_NOINIT:status;}
DRESULT disk_read(BYTE drive,BYTE *buffer,LBA_t sector,UINT count){
 if(drive||!count||sector>=sectors||count>sectors-sector)return RES_PARERR;
 if(status||hal_cancelled())return RES_NOTRDY;
 for(UINT i=0;i<count;i++){
  if(command(17,(uint32_t)(sector+i))!=0||read_block(buffer+512*i,512)){release();return RES_ERROR;}
  release();
 }
 return RES_OK;
}
DRESULT disk_write(BYTE drive,const BYTE *buffer,LBA_t sector,UINT count){(void)drive;(void)buffer;(void)sector;(void)count;return RES_WRPRT;}
DRESULT disk_ioctl(BYTE drive,BYTE cmd,void *buffer){
 if(drive||status)return RES_NOTRDY;
 switch(cmd){case CTRL_SYNC:return RES_OK;case GET_SECTOR_COUNT:*(LBA_t*)buffer=sectors;return RES_OK;case GET_SECTOR_SIZE:*(WORD*)buffer=512;return RES_OK;case GET_BLOCK_SIZE:*(DWORD*)buffer=128;return RES_OK;default:return RES_PARERR;}
}
