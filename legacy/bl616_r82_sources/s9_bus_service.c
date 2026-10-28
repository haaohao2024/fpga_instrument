#include "s9_bus_service.h"
#include "s9_protocol.h"
#include "score_hal.h"
#include <string.h>
enum {CLOSED,OPENING,PLAY,CLOSING};
void s9_bus_init(s9_bus_service *s,s9_bus_status_fn f,void *p){memset(s,0,sizeof *s);s->publish=f;s->context=p;}
int s9_bus_open(s9_bus_service *s,const uint8_t id[16]){
 if(s->state!=CLOSED||s->status_pending)return S9_E_BUSY;
 if(!s9_get64(id)||!s9_get64(id+8))return S9_E_SESSION;
 if(s->epoch==UINT32_MAX)return S9_E_SEQUENCE;
 s->ticket_known=0;memset(s->instances,0,sizeof s->instances);s->query_active=0;s->query_retry=0;
 s->epoch++;memcpy(s->session,id,16);s->state=OPENING;s->credit=0;
 s->next_serial=1;s->pending_is_result=0;s->ack_serial=0;s->ack_pending=0;s->have_result=0;
 s->last_step_ms=0;s->last_good_ms=0;s->head=0;s->count=0;s->offset=0;s->awaiting_event=0;s->head_prepared=0;s->head_sent=0;s->cleanup_command=0;s9_phone_cancel(&s->batch);return 0;
}
void s9_bus_close(s9_bus_service *s){
 if(s->state!=CLOSED){
  /* The FPGA owns the complete accepted-token release table, including
   * voices already stolen. CLOSE drains any accepted offer before emitting
   * the same ascending-key OFF sequence. No per-key SPI round trips. */
  s->state=CLOSING;s->count=0;s->offset=0;s->awaiting_event=0;s->query_active=0;
  s->head_prepared=0;s->head_sent=0;s9_phone_cancel(&s->batch);
 }
}
int s9_bus_enqueue(s9_bus_service *s,const uint8_t *raw,unsigned length){
 s9_message m;
 if(s->state!=PLAY)return S9_E_STATE;
 if(length>192||s9_decode(raw,length,&m)||m.channel>1||memcmp(m.session,s->session,16)||s9_validate_request(&m))return S9_E_FORMAT;
 if(m.opcode==S9_OP_QUERY_RESULT||m.opcode==S9_OP_BARRIER)return S9_E_STATE; /* software-owned */
 if(s->count==S9_BUS_COMMAND_SLOTS)return S9_E_BUSY;
 unsigned n=(s->head+s->count)%S9_BUS_COMMAND_SLOTS;
 memcpy(s->request[n],raw,length);s->length[n]=(uint16_t)length;s->count++;return 0;
}
static int transfer(s9_bus_service *s,unsigned op,const uint8_t *data,unsigned length,uint32_t serial){
 uint8_t tx[212]={0},rx[204];
 memcpy(tx,"R20C",4);tx[4]=3;tx[5]=(uint8_t)op;s9_put16(tx+6,(uint16_t)length);
 s9_put32(tx+8,s->epoch);s9_put32(tx+12,serial);
 if(length)memcpy(tx+16,data,length);
 s9_put32(tx+16+length,s9_crc32(tx,16+length));
 unsigned n=length+20;if(n<204)n=204;
 hal_frequency(FPGA_SPI_HZ);if(hal_select(BUS_CONTROL))return S9_E_IO;
 hal_delay_us(1);
 for(unsigned i=0;i<n;i++){uint8_t b=hal_exchange(tx[i]);if(i<204)rx[i]=b;}
 hal_delay_us(1);hal_select(BUS_NONE);hal_exchange(255);s->transactions++;
 if(memcmp(rx,"R20S",4)||rx[4]!=3||s9_get32(rx+200)!=s9_crc32(rx,200)){s->crc_errors++;return S9_E_CRC;}
 /* OPEN sees the previous epoch in its full-duplex response. It must poll
  * until the receiver has committed this OPEN before exposing READY. */
 if(s9_get32(rx+8)!=s->epoch||memcmp(rx+56,s->session,16)){
  if(s->state==OPENING||rx[5]!=0)return S9_MORE;
  /* FPGA reset/closed: publish DOWN, retire transport state, and let the
   * existing protocol owner reconnect. Never invent command completions. */
  memset(s->status,0,64);memcpy(s->status,"S9ST",4);s->status[4]=1;
  memcpy(s->status+8,s->session,16);s9_put32(s->status+60,s9_crc32(s->status,60));
  memcpy(s->pending_status,s->status,64);s->status_pending=1;s->pending_is_result=0;
  s->state=CLOSED;s->count=0;s->offset=0;s->credit=0;s->ack_pending=0;s->awaiting_event=0;s9_phone_cancel(&s->batch);return 0;
 }
 s->credit=rx[6];s->accepted_serial=s9_get32(rx+12);
 if(s->count){
  if(s->head_sent&&s->accepted_serial==s->next_serial){
   unsigned ticket=rx[83];if(ticket>=8)return S9_E_FORMAT;
   s->ticket_sequence[ticket]=s9_get32(s->request[s->head]);
   s->ticket_channel[ticket]=(uint8_t)(s->head_prepared==1?0:1);s->ticket_known|=(uint8_t)(1u<<ticket);
   s->completed++;
   if(s->head_prepared==3)s->offset=2;
   else {s->head=(s->head+1)%S9_BUS_COMMAND_SLOTS;s->count--;s->offset=0;s->head_prepared=0;s->head_sent=0;}
   if(s->next_serial==UINT32_MAX){
    /* No ticket remains for software OFF commands. The hardware accepted
     * token table drains the final offer and performs the same OFF cleanup. */
    s->state=CLOSING;s->count=0;s->awaiting_event=0;s9_phone_cancel(&s->batch);
   }else s->next_serial++;
  }else if(s->offset==1&&(uint32_t)(s->last_step_ms-s->started_ms)>=20){s->offset=0;s->retries++;}
 }
 if(rx[5]==0&&(s->state==PLAY)){
  s->state=CLOSED;s->count=0;s->offset=0;s->awaiting_event=0;s9_phone_cancel(&s->batch);
 }
 if(s->state==OPENING&&rx[5]==2)s9_phone_ledger_open(&s->ledger,s9_get64(rx+72),rx[80]&1);
 memset(s->status,0,64);memcpy(s->status,"S9ST",4);s->status[4]=1;
 s->status[5]=rx[5];s->status[6]=rx[6];memcpy(s->status+8,s->session,16);
 uint32_t rs=s9_get32(rx+16);
 if((rx[7]&1)&&s->state==PLAY){
  /* Receiving is not ACKing. The next wire ACK is enabled only after the
   * protocol-task queue has accepted the entire identity/result pair. */
  if(!s->have_result||rs!=s->last_result_serial){
   unsigned ticket=s9_get32(rx+20);
   if(ticket>=8||!(s->ticket_known&(1u<<ticket))||s->ticket_channel[ticket]!=rx[24])return S9_E_FORMAT;
   uint32_t sequence=s->ticket_sequence[ticket];
   memcpy(s->status+24,rx+20,32);s9_put32(s->status+24,sequence);s->status[7]=rx[52];
   /* FPGA reports physical facts; the application phase format belongs here. */
   if(rx[24]==1)s->status[29]=rx[25]&7;
   if(s->query_active&&rx[24]==1&&sequence==s->query_sequence){
    if((int16_t)s9_get16(rx+26)==S9_E_STALE){
     s->instances[s->query_slot].known=0;s->query_retry=1;
     memset(s->status+24,0,32); /* ACK the failed candidate, then try next. */
    }else{
     s->query_active=0;s->head=(s->head+1)%S9_BUS_COMMAND_SLOTS;s->count--;
     s->head_prepared=0;s->head_sent=0;s->offset=0;
    }
   }
   if(s->awaiting_event&&rx[24]==0&&sequence==s->event_sequence&&rx[25]>=3){
    if(rx[25]==3&&!(int16_t)s9_get16(rx+26)){
     uint16_t mask=s9_get16(rx+81);
     for(unsigned i=0;i<s->batch.count;i++)if(mask&(1u<<i)){
      const uint8_t *m=rx+92+12*i;
      if(m[11]!=1||s9_phone_instance_commit(s->instances,&s->batch,i,m[10],s9_get64(m),s9_get16(m+8)))return S9_E_FORMAT;
     }
     s9_phone_accept(&s->ledger,&s->batch,s->batch.ticket);
    }
    else s9_phone_cancel(&s->batch);
    s->awaiting_event=0;
    if(s->cleanup_command)memset(s->status+24,0,32);
   }
   s->pending_result_serial=rs;s->pending_is_result=1;
  }else {s->ack_serial=rs;s->ack_pending=1;}
 }
 s9_put32(s->status+60,s9_crc32(s->status,60));
 if(s->pending_is_result||memcmp(s->status,s->pending_status,60)){
  memcpy(s->pending_status,s->status,64);s->status_pending=1;
 }
 return 0;
}
static int local_reject(s9_bus_service *s,uint32_t sequence,unsigned channel,int e){
 memset(s->pending_status,0,64);memcpy(s->pending_status,"S9ST",4);s->pending_status[4]=1;s->pending_status[5]=2;
 memcpy(s->pending_status+8,s->session,16);s9_put32(s->pending_status+24,sequence);
 s->pending_status[28]=(uint8_t)channel;s->pending_status[29]=7;
 s9_put16(s->pending_status+30,(uint16_t)e);s9_put32(s->pending_status+60,s9_crc32(s->pending_status,60));
 s->status_pending=1;s->pending_is_result=0;s->query_active=0;s->query_retry=0;
 s->head_prepared=0;s->head_sent=0;s->offset=0;
 s->head=(s->head+1)%S9_BUS_COMMAND_SLOTS;s->count--;return S9_MORE;
}
static int query_candidate(s9_bus_service *s){
 int candidate=-1;
 if(s->query_opcode==S9_OP_INSTANCE)
  candidate=s9_phone_candidate(s->instances,s->query_key,s->query_identity,s->query_from);
 else for(int i=(int)s->query_from-1;i>=0;i--)
  if(s->instances[i].known&&s->instances[i].identity==s->query_identity&&s->instances[i].generation==s->query_generation){candidate=i;break;}
 if(candidate<0)return local_reject(s,s->query_sequence,1,S9_E_STALE);
 s->query_slot=(uint8_t)candidate;
 s->query_from=(uint8_t)(s->query_opcode==S9_OP_INSTANCE?candidate+1:candidate);
 uint8_t *raw=s->request[s->head];memset(raw,0,192);s9_put32(raw,s->query_sequence);raw[4]=s->query_opcode;
 s9_put64(raw+8,s->instances[candidate].token);s9_put16(raw+16,s->instances[candidate].generation);
 raw[18]=(uint8_t)candidate;s9_put16(raw+19,s->query_pan);
 s->length[s->head]=21;s->head_prepared=3;s->query_retry=0;return 0;
}
/* Prepare exactly once. Retries retain tokens and wire bytes. Only identity
 * operations wait for previous ON facts; a gain/keymap watch never blocks RT. */
static int prepare_head(s9_bus_service *s){
 if(!s->count)return S9_MORE;
 if(s->query_retry)return query_candidate(s);
 if(s->head_prepared)return 0;
 uint8_t *raw=s->request[s->head];uint32_t sequence=s9_get32(raw+24);
 if(raw[5]==1){
  unsigned op=raw[6],length=s9_get16(raw+28);
  if(op==S9_OP_INSTANCE||op==S9_OP_PAN){
   if(s->awaiting_event)return S9_MORE;
   s->query_active=1;s->query_opcode=(uint8_t)op;s->query_sequence=sequence;
   s->query_key=raw[32];s->query_identity=s9_get64(raw+(op==S9_OP_INSTANCE?33:32));
   s->query_generation=s9_get16(raw+40);s->query_pan=s9_get16(raw+42);
   s->query_from=(uint8_t)(op==S9_OP_INSTANCE?0:32);return query_candidate(s);
  }
  memmove(raw+8,raw+32,length);memset(raw,0,8);s9_put32(raw,sequence);raw[4]=(uint8_t)op;
  s->length[s->head]=(uint16_t)(8+length);s->head_prepared=2;return 0;
 }
 if(s->awaiting_event)return S9_MORE;
 unsigned count=s9_get16(raw+28)/16;
 int e=s9_phone_prepare(&s->ledger,&s->batch,s->next_serial,raw+32,count);
 if(e)return local_reject(s,sequence,0,e);
 memset(raw,0,192);s9_put32(raw,sequence);raw[4]=(uint8_t)count;
 for(unsigned i=0;i<count;i++)memcpy(raw+8+12*i,s->batch.items[i],12);
 s->length[s->head]=(uint16_t)(8+12*count);s->head_prepared=1;s->event_sequence=sequence;return 0;
}
unsigned s9_bus_next_bytes(const s9_bus_service *s,uint32_t now){
 return s->state==CLOSED||now==s->last_step_ms?0:204;
}
void s9_bus_step(s9_bus_service *s,uint32_t now){
 if(s->status_pending){
  if(s->publish&&s->publish(s->context,s->pending_status))return;
  s->status_pending=0;
  if(s->pending_is_result){
   s->last_result_serial=s->pending_result_serial;s->have_result=1;
   s->ack_serial=s->pending_result_serial;s->ack_pending=1;s->pending_is_result=0;
  }
 }
 if(s->state==CLOSED||now==s->last_step_ms)return;
 s->last_step_ms=now;
 unsigned op=0,len=0;uint32_t serial=0;const uint8_t *p=0;
 if(s->state==OPENING){op=1;p=s->session;len=16;}
 else if(s->state==CLOSING)op=3;
 else if((uint32_t)(now-s->last_keep_ms)>=100){op=2;s->last_keep_ms=now;}
 else if(s->ack_pending){op=5;serial=s->ack_serial;}
 else if(s->count&&s->credit&&!s->offset){
  if(prepare_head(s)==S9_MORE){if(s->status_pending)return;}
  else {op=s->head_prepared==1?6:4;p=s->request[s->head];len=s->length[s->head];serial=s->next_serial;}
 }
 if(op==4||op==6){s->head_sent=1;if(op==6)s->awaiting_event=1;}
 int r=transfer(s,op,p,len,serial);
 if(r<0){
  if(s->last_good_ms&&(uint32_t)(now-s->last_good_ms)>100){
   s->timeouts++;s->state=CLOSING;s->count=0;s->offset=0;s->awaiting_event=0;s->query_active=0;s9_phone_cancel(&s->batch);
  }
  return;
 }
 if(r==S9_MORE)return;
 s->last_good_ms=now;
 if(op==5){s->ack_pending=0;if(s->query_retry)s->offset=0;}
 if(s->state==OPENING&&s->status[5]==2){s->state=PLAY;s->last_keep_ms=now;}
 if(s->state==CLOSING&&s->status[5]==0){
  s->state=CLOSED;s->ledger.held=0;s->ack_pending=0;return;
 }
 if(s->state!=PLAY)return;
 if(len&&(op==4||op==6)&&serial==s->next_serial){s->started_ms=now;s->offset=1;}

}

#include <string.h>
void s9_phone_ledger_open(s9_phone_ledger *s,uint64_t next,int exhausted){
 memset(s,0,sizeof *s);s->next_token=next;s->exhausted=(uint8_t)(exhausted!=0);
}
int s9_phone_prepare(const s9_phone_ledger *s,s9_phone_batch *b,uint32_t ticket,const uint8_t *records,unsigned count){
 if(!ticket||!records||count==0||count>9)return S9_E_RANGE;
 if(b->prepared)return S9_E_BUSY;
 b->next=*s;b->ticket=ticket;b->count=(uint8_t)count;
 for(unsigned i=0;i<count;i++){
  const uint8_t *r=records+16*i;uint64_t press=s9_get64(r),token=0;
  unsigned kind=r[8],key=r[9],note=r[10],value=r[11];
  if(s9_get32(r+12)||kind<1||kind>4||note>127)return S9_E_RANGE;
  if(kind==4){if(press||key!=255||note)return S9_E_RANGE;}
  else{
   if(!press||key>=32||(kind==1&&!value)||(kind==2&&(note||value)))return S9_E_RANGE;
   uint32_t bit=1u<<key;int held=(b->next.held&bit)!=0;
   if((kind==1&&held)||((kind==2||kind==3)&&(!held||b->next.key[key].press!=press)))return S9_E_STALE;
   if(kind==1){
    if(b->next.exhausted||!b->next.next_token)return S9_E_SEQUENCE;
    token=b->next.next_token;
    if(token==UINT64_MAX)b->next.exhausted=1;else b->next.next_token++;
    b->next.key[key].press=press;b->next.key[key].token=token;b->next.held|=bit;
   }else {token=b->next.key[key].token;if(kind==2)b->next.held&=~bit;}
  }
  s9_put32(b->items[i],(2u<<28)|(kind<<24)|(key<<16)|(note<<9)|(value<<1));
  s9_put64(b->items[i]+4,token);s9_put64(b->presses[i],press);
 }
 b->prepared=1;return 0;
}
int s9_phone_accept(s9_phone_ledger *s,s9_phone_batch *b,uint32_t ticket){
 if(!b->prepared||b->ticket!=ticket)return S9_E_STALE;
 *s=b->next;b->prepared=0;return 0;
}
void s9_phone_cancel(s9_phone_batch *b){b->prepared=0;}
int s9_phone_next_off(const s9_phone_ledger *s,uint8_t record[16]){
 for(unsigned i=0;i<32;i++)if(s->held&(1u<<i)){
  memset(record,0,16);s9_put64(record,s->key[i].press);record[8]=2;record[9]=(uint8_t)i;return 1;
 }
 return 0;
}
int s9_phone_instance_commit(s9_phone_instance slots[32],const s9_phone_batch *b,unsigned i,unsigned slot,uint64_t id,uint16_t generation){
 if(i>=b->count||slot>=32||!id||((s9_get32(b->items[i])>>24)&15)!=1)return S9_E_RANGE;
 s9_phone_instance *s=&slots[slot];s->press=s9_get64(b->presses[i]);s->token=s9_get64(b->items[i]+4);
 s->identity=id;s->generation=generation;s->key=b->items[i][2];s->known=1;return 0;
}
int s9_phone_candidate(const s9_phone_instance slots[32],uint8_t key,uint64_t press,unsigned from){
 for(unsigned i=from;i<32;i++)if(slots[i].known&&slots[i].key==key&&slots[i].press==press)return (int)i;
 return -1;
}
