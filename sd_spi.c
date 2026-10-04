/* SDHC/SDXC SPI, fixed 512-byte blocks. Normal transfers have an 8 ms CS
 * occupancy deadline. Write programming busy is polled with CS released
 * between polls, allowing the single bus task to service control traffic.
 * CMD13 and CTRL_SYNC are real card operations, not unconditional success.
 */
#include "score_hal.h"
#include "sd_spi.h"
#include <string.h>
#ifdef S9_RUNTIME
#define disk_initialize sd_bus_initialize
#define disk_status sd_bus_status
#define disk_read sd_bus_read
#define disk_write sd_bus_write
#define disk_ioctl sd_bus_ioctl
#endif
static DSTATUS status=STA_NOINIT;
static uint32_t sectors,frequency=400000;
static unsigned recording_mode;
static uint32_t reservation_us=8000;
uint32_t sd_reservation_us(void){return reservation_us;}
static uint64_t selected_since,lease_since;
static unsigned selected,transfer_failed;
static sd_service_fn service;
static void *service_context;
static sd_diagnostics diag;
static sd_admission_fn admission;
static sd_retired_fn retired;
static void *admission_context;
static unsigned admission_denied;
void sd_set_admission(sd_admission_fn before,sd_retired_fn after,void *context){admission=before;retired=after;admission_context=context;}
void sd_set_service(sd_service_fn f,void *context){service=f;service_context=context;}
const sd_diagnostics *sd_get_diagnostics(void){return &diag;}
int sd_set_recording_mode(int enabled){if(selected)return -1;recording_mode=enabled!=0;if(!status)frequency=recording_mode?8000000:2000000;return 0;}
static uint32_t selected_limit(void){return recording_mode&&!status?reservation_us-2u:8000u;}
static uint16_t crc16(const uint8_t *b,unsigned n){uint16_t c=0;while(n--){c^=(uint16_t)*b++<<8;for(int i=0;i<8;i++)c=c&0x8000?(c<<1)^0x1021:c<<1;}return c;}
static int failed(void){
 if(hal_cancelled()){transfer_failed=1;return 1;}
 if(selected&&hal_time_us()-(recording_mode&&!status?lease_since:selected_since)>selected_limit()){
  if(!transfer_failed)diag.deadline_errors++;
  transfer_failed=1;
 }
 return transfer_failed;
}
static uint8_t exchange(uint8_t value){
 if(failed())return 255;
 /* Do not start a byte whose wire time already exceeds the remaining budget. */
 if(selected&&hal_time_us()-(recording_mode&&!status?lease_since:selected_since)+(8000000u+frequency-1)/frequency>selected_limit()){
  diag.deadline_errors++;transfer_failed=1;return 255;
 }
 uint8_t r=hal_exchange(value);failed();return r;
}
static void release(void){
 unsigned was_selected=selected;
 uint64_t duration=was_selected?hal_time_us()-selected_since:0;
 if(was_selected&&duration>diag.max_selected_us)diag.max_selected_us=(uint32_t)duration;
 /* With admission enabled a prior service window may own FPGA DMA.
  * An already-released SD interval must not deassert that unrelated CS. */
 if(was_selected||!admission){hal_select(BUS_NONE);selected=0;hal_exchange(255);}
 if(was_selected&&retired)retired(admission_context,recording_mode&&!status?hal_time_us()-lease_since:duration);
}
static int select_card(uint32_t lease){
 reservation_us=recording_mode&&!status?lease:8000u;
 transfer_failed=0;admission_denied=0;
 if(admission&&admission(admission_context)){admission_denied=1;return -1;}
 /* Admission callbacks may configure SPI for FPGA traffic. Restore SD speed
  * only after a grant, while every shared CS is high. */
 lease_since=hal_time_us();hal_frequency(frequency);
 selected_since=hal_time_us();
 if(hal_select(BUS_SD)){transfer_failed=1;return -1;}selected=1;return 0;
}
static void service_window(void){
 release();diag.service_windows++;
 if(service)service(service_context);
 /* The callback may have changed SPI speed while serving control. */
 if(!admission)hal_frequency(frequency);
}
static int wait_ready(void){
 do{if(failed())return -1;if(exchange(255)==255&&!failed())return 0;}while(!failed());return -1;
}
static int command(uint8_t cmd,uint32_t arg){
 release();if(select_card(cmd==13?40u:2000u)||wait_ready())return -1;
 uint8_t b[6]={0x40|cmd,arg>>24,arg>>16,arg>>8,arg,(cmd==0)?0x95:(cmd==8)?0x87:1};
 for(unsigned i=0;i<6;i++)exchange(b[i]);
 for(unsigned i=0;i<16&&!failed();i++){uint8_t r=exchange(255);if(!(r&128))return r;}
 return -1;
}
static int read_block(uint8_t *b,unsigned n){
 uint8_t token=255;
 do{if(failed())return -1;token=exchange(255);if(token==0xfe)break;if(token!=255)return -1;}while(!failed());
 if(token!=0xfe||failed())return -1;
 for(unsigned i=0;i<n;i++){b[i]=exchange(255);if(failed())return -1;}
 uint16_t crc=(uint16_t)exchange(255)<<8;crc|=exchange(255);
 return !failed()&&crc==crc16(b,n)?0:-1;
}
/* Programming may take much longer than 8 ms, but NEVER owns the bus while
 * waiting. Up to 500 ms overall is allowed; cancellation still takes effect. */
static int programming_done(void){
 uint64_t start=hal_time_us();
 do{
  if(hal_cancelled()||select_card(16u))return -1;
  /* First byte supplies clocks after reselect; the second reads busy status. */
  exchange(255);uint8_t ready=exchange(255);int bad=failed();release();
  if(bad)return -1;
  if(ready==255)return 0;
  service_window();hal_delay_us(100);
 }while(hal_time_us()-start<500000);
 return -1;
}
static int card_status(void){
 if(command(13,0)!=0){release();return -1;}
 uint8_t r2=exchange(255);int bad=failed();release();return (bad||r2)?-1:0;
}
static DRESULT io_error(void){release();
 /* No SD wire operation took place for an admission denial. Do not claim
  * card damage or invalidate an initialized card; the caller safely stops
  * the score source if its bounded service window could not be met. */
 if(admission_denied)return RES_NOTRDY;
 diag.io_errors++;status=STA_NOINIT;return RES_ERROR;}
DSTATUS disk_initialize(BYTE drive){
 if(drive)return STA_NOINIT;
 status=STA_NOINIT;sectors=0;frequency=400000;transfer_failed=0;selected=0;
 hal_frequency(frequency);release();for(int i=0;i<10;i++)hal_exchange(255);
 if(command(0,0)!=1)goto fail;
 service_window();
 if(command(8,0x1aa)!=1)goto fail;
 uint8_t r7[4];for(int i=0;i<4;i++)r7[i]=exchange(255);
 if(failed()||r7[2]!=1||r7[3]!=0xaa)goto fail;
 service_window();
 uint64_t start=hal_time_us();int r;
 do{
  if(command(55,0)!=1)goto fail;
  release();r=command(41,0x40000000);
  if(r<0||failed())goto fail;
  service_window();
 }while(r==1&&hal_time_us()-start<1000000);
 if(r!=0||command(58,0)!=0)goto fail;
 uint32_t ocr=0;for(int i=0;i<4;i++)ocr=(ocr<<8)|exchange(255);
 if(failed()||(ocr&0xc0000000)!=0xc0000000)goto fail;
 service_window();
 if(command(9,0)!=0)goto fail;
 uint8_t csd[16];if(read_block(csd,16)||csd[0]>>6!=1)goto fail;release();
 uint32_t size=((uint32_t)(csd[7]&63)<<16)|((uint32_t)csd[8]<<8)|csd[9];
 if(size==0x3fffff)goto fail;
 sectors=(size+1)*1024;frequency=recording_mode?8000000:2000000;hal_frequency(frequency);status=0;return status;
 fail:release();diag.io_errors++;return status;
}
DSTATUS disk_status(BYTE drive){return drive?STA_NOINIT:status;}
DRESULT disk_read(BYTE drive,BYTE *buffer,LBA_t sector,UINT count){
 if(drive||!buffer||!count)return RES_PARERR;
 if(status||hal_cancelled())return RES_NOTRDY;
 if(sector>=sectors||count>sectors-sector)return RES_PARERR;
 for(UINT i=0;i<count;i++){
  if(command(17,(uint32_t)(sector+i))!=0||read_block(buffer+512*i,512))return io_error();
  release();diag.reads++;service_window();
 }
 return RES_OK;
}
DRESULT disk_write(BYTE drive,const BYTE *buffer,LBA_t sector,UINT count){
 if(drive||!buffer||!count)return RES_PARERR;
 if(status||hal_cancelled())return RES_NOTRDY;
 if(sector>=sectors||count>sectors-sector)return RES_PARERR;
 for(UINT i=0;i<count;i++){
  if(command(24,(uint32_t)(sector+i))!=0)return io_error();
  const uint8_t *p=buffer+i*512;uint16_t crc=crc16(p,512);
  exchange(255);exchange(0xfe);
  for(unsigned j=0;j<512&&!failed();j++)exchange(p[j]);
  exchange(crc>>8);exchange(crc);uint8_t response=exchange(255);
  if(failed()||(response&31)!=5)return io_error();
  /* Supply an additional byte after data-response, then release CS while busy. */
  exchange(255);if(failed())return io_error();release();
  if(programming_done()||card_status())return io_error();
  diag.writes++;service_window();
 }
 return RES_OK;
}
DRESULT disk_ioctl(BYTE drive,BYTE cmd,void *buffer){
 if(drive||status||hal_cancelled())return RES_NOTRDY;
 switch(cmd){
 case CTRL_SYNC:if(programming_done()||card_status())return io_error();diag.syncs++;return RES_OK;
 case GET_SECTOR_COUNT:if(!buffer)return RES_PARERR;*(LBA_t*)buffer=sectors;return RES_OK;
 case GET_SECTOR_SIZE:if(!buffer)return RES_PARERR;*(WORD*)buffer=512;return RES_OK;
 case GET_BLOCK_SIZE:if(!buffer)return RES_PARERR;*(DWORD*)buffer=128;return RES_OK;
 default:return RES_PARERR;
 }
}
