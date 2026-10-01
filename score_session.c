#include "score_service.h"
#include "score_hal.h"
static uint32_t rd32(const uint8_t *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static uint64_t rd64(const uint8_t *p){return rd32(p)|((uint64_t)rd32(p+4)<<32);}
static int stop_fence(uint64_t epoch,uint8_t status[32]){
 if(score_send(3,epoch,0,0,0,0,status))return -20;
 for(unsigned i=0;i<1000;i++){hal_delay_us(1000);if(!score_send(8,epoch,0,0,0,0,status)&&status[7]==0)return 0;}
 return -21;
}
// 0=EOF,1=reload requested,<0=error. Every active session exits via STOP fence.
int score_run_file(uint64_t epoch,uint8_t status[32]){
 uint8_t page[512];uint32_t seq=0;int have=0,finished=0,bad_status=0,started=0,result=-10;
 uint64_t pending_since=0,start_since=hal_time_us();
 if(score_send(8,0,0,0,0,0,status))return -10;
 if(status[7]!=0&&stop_fence(rd64(status+8),status))return -11;
 if(score_open(epoch)){score_cancel();return -12;}
 if(score_send(1,epoch,0,score_default_mode(),0,0,status)){score_cancel();return -13;}
 start_since=hal_time_us();
 for(;;){
  hal_delay_us(5000);
  if(score_send(8,epoch,0,0,0,0,status)){if(++bad_status>=20){result=-14;break;}continue;}
  bad_status=0;
  if(rd64(status+8)!=epoch){if(hal_time_us()-start_since>100000){result=-15;break;}continue;}
  if(status[5]){result=-16;break;}
  if(!started){if(!status[7]){if(hal_time_us()-start_since>100000){result=-15;break;}continue;}started=1;}
  if(have&&rd32(status+16)==seq)have=0;
  if(!have&&!finished){int r=score_next(page,&seq,epoch);if(r<0){score_send(7,epoch,0,0,0,0,status);result=-18;break;}if(r==1)finished=1;else{have=1;pending_since=hal_time_us();}}
  // The last-page ACK and natural EOF may be returned in the same snapshot.
  // Resolve that ACK and local EOF first. STOPPED without all pages ACKed
  // remains an error; never send a pending page into a stopped generation.
  if(!status[7]){result=finished?((status[6]&2)?1:0):-17;break;}
  if(have){
   // Healthy receiver credit=0 includes page parsing stalled on a future-time
   // full record FIFO. Long rests/PAUSE may make this wait arbitrarily long.
   // Only count no-ACK time while the receiver advertises a free page slot.
   // Bad/missing status is still bounded independently by bad_status above.
   if(!(status[6]&1))pending_since=hal_time_us();
   if(hal_time_us()-pending_since>100000){result=-19;break;}
   if(status[6]&1)score_send(2,epoch,seq,0,page,512,status);
  }
 }
 score_cancel();int stopped=stop_fence(epoch,status);return stopped?stopped:result;
}
