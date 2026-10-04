#include "s9_bus_service.h"
#include "s9_protocol.h"
#include "score_hal.h"
#include <string.h>
enum {CLOSED,OPENING,PLAY,CLOSING};
void s9_bus_init(s9_bus_service *s,s9_bus_status_fn f,void *p){memset(s,0,sizeof *s);s->publish=f;s->context=p;}
int s9_bus_open(s9_bus_service *s,const uint8_t id[16]){
 if(s->state!=CLOSED||s->status_pending)return S9_E_BUSY;
 if(!s9_get64(id)||!s9_get64(id+8))return S9_E_SESSION;
 memcpy(s->session,id,16);s->state=OPENING;s->credit=0;s->last_step_ms=0;s->last_good_ms=0;return 0;
}
void s9_bus_close(s9_bus_service *s){if(s->state!=CLOSED)s->state=CLOSING;s->count=0;s->offset=0;}
int s9_bus_enqueue(s9_bus_service *s,const uint8_t *raw,unsigned length){
 s9_message m;
 if(s->state!=PLAY)return S9_E_STATE;
 if(length>192||s9_decode(raw,length,&m)||m.channel>1||memcmp(m.session,s->session,16))return S9_E_FORMAT;
 if(s->count==S9_BUS_COMMAND_SLOTS)return S9_E_BUSY;
 unsigned n=(s->head+s->count)%S9_BUS_COMMAND_SLOTS;
 memcpy(s->request[n],raw,length);s->length[n]=(uint16_t)length;s->count++;return 0;
}
static int transfer(s9_bus_service *s,unsigned op,const uint8_t *data,unsigned length,unsigned offset,uint32_t seq){
 uint8_t tx[164]={0},rx[64];
 memcpy(tx,"S9PK",4);tx[4]=1;tx[5]=(uint8_t)op;s9_put16(tx+6,(uint16_t)length);
 memcpy(tx+8,s->session,16);s9_put32(tx+24,seq);s9_put16(tx+28,(uint16_t)offset);
 if(length)memcpy(tx+32,data,length);
 s9_put32(tx+32+length,s9_crc32(tx,32+length));
 unsigned n=length+36;if(n<80)n=80;
 hal_frequency(FPGA_SPI_HZ);if(hal_select(BUS_CONTROL))return S9_E_IO;
 hal_delay_us(1);
 for(unsigned i=0;i<n;i++){uint8_t b=hal_exchange(tx[i]);if(i<64)rx[i]=b;}
 hal_delay_us(1);hal_select(BUS_NONE);hal_exchange(255);s->transactions++;
 if(memcmp(rx,"S9ST",4)||rx[4]!=1||s9_get32(rx+60)!=s9_crc32(rx,60)){s->crc_errors++;return S9_E_CRC;}
 if(memcmp(rx+8,s->session,16)&&rx[5]!=0)return S9_E_SESSION;
 memcpy(s->status,rx,64);s->credit=rx[6];
 /* Retain a result until the protocol task accepted the complete pair of
  * identity and payload. No follow-up wire read can overwrite this slot. */
 if(memcmp(rx,s->pending_status,60)){
  memcpy(s->pending_status,rx,64);s->status_pending=1;
 }
 return 0;
}
unsigned s9_bus_next_bytes(const s9_bus_service *s,uint32_t now){
 if(s->state==CLOSED||now==s->last_step_ms)return 0;
 unsigned n=0;
 if(s->state==PLAY&&(uint32_t)(now-s->last_keep_ms)<100&&s->count&&s->credit&&s->offset<s->length[s->head]){n=s->length[s->head]-s->offset;if(n>128)n=128;}
 unsigned bytes=36+n;return bytes<80?80:bytes;
}
void s9_bus_step(s9_bus_service *s,uint32_t now){
 if(s->status_pending){
  if(s->publish&&s->publish(s->context,s->pending_status))return;
  s->status_pending=0;
 }
 if(s->state==CLOSED||now==s->last_step_ms)return;
 s->last_step_ms=now;
 unsigned op=0x80,len=0,off=0;uint32_t seq=0;const uint8_t *p=0;
 if(s->state==OPENING)op=0x90;
 else if(s->state==CLOSING)op=0x92;
 else if((uint32_t)(now-s->last_keep_ms)>=100){op=0x91;s->last_keep_ms=now;}
 else if(s->count&&s->credit&&s->offset<s->length[s->head]){
  p=s->request[s->head];seq=s9_get32(p+24);op=p[5];off=s->offset;
  len=s->length[s->head]-off;if(len>128)len=128;p+=off;
 }
 int r=transfer(s,op,p,len,off,seq);
 if(r){
  if(s->last_good_ms&&(uint32_t)(now-s->last_good_ms)>100){s->timeouts++;s9_bus_close(s);}
  return;
 }
 s->last_good_ms=now;
 if(s->state==OPENING&&s->status[5]==2){s->state=PLAY;s->last_keep_ms=now;}
 if(s->state==CLOSING&&s->status[5]==0){s->state=CLOSED;return;}
 if(s->state!=PLAY)return;
 if(len){
  if(!s->offset)s->started_ms=now;
  s->offset=(uint8_t)(off+len);
 }
 if(s->count){
  const uint8_t *q=s->request[s->head];
  if(s->status[28]==q[5]&&s9_get32(s->status+24)==s9_get32(q+24)&&s->status[29]>=2){
   s->head=(s->head+1)%S9_BUS_COMMAND_SLOTS;s->count--;s->offset=0;s->completed++;
  }else if(s->offset==s->length[s->head]){
   /* Whole-message retry uses the identical session/sequence/body. */
   if((uint32_t)(now-s->started_ms)>=20){s->offset=0;s->retries++;}
  }
 }
}
