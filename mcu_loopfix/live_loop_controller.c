#include "live_loop_controller.h"
#include "s9_protocol.h"
#include <string.h>
#define CONTROL_LEAD 3840u
#define PREFETCH 1920u
enum {WIRE_NONE=0,WIRE_DISCOVER=1,WIRE_CONTROL=2,WIRE_EVENTS=3,WIRE_POLL=4,WIRE_KEEP=5};
static void result(ll_controller *m,unsigned phase,int error){
 if(phase==4&&m->user_sequence)m->effective_sample=m->status.effective_sample;
 if(m->user_sequence){m->result_valid=1;m->result_sequence=m->user_sequence;m->result_phase=(uint8_t)phase;m->result_error=error;}
 m->user_sequence=0;m->user_opcode=0;m->notice_dirty=1;
}
static int mapped(int error){return error==LL_E_CAPACITY||error==LL_E_ADMISSION||error==LL_E_ID?S9_E_RANGE:error==LL_E_TIME?S9_E_TIMEOUT:S9_E_STATE;}
static void set_control(ll_controller *m,unsigned control,uint16_t revision,uint64_t target){
 m->control=(uint8_t)control;m->revision=revision;m->target=target;m->control_serial=0;
}
static void failed_new(ll_controller *m,int error,unsigned reason){
 uint16_t revision=m->core.last_failed_revision;
 if(m->core.recording!=UINT8_MAX){uint16_t r=0;ll_disconnect(&m->core,&r);if(r)revision=r;}
 m->prefix_active=m->prefix_saved=m->close_wait=m->auto_seal=0;m->planned_end=0;m->capture_draining=1;m->capture_empty=0;
 m->last_error=mapped(error);m->reason=(uint8_t)reason;m->notice_dirty=1;
 if(revision)set_control(m,LL_CTL_RELEASE_REV,revision,0);
 else if(m->user_sequence)result(m,7,m->last_error);
}
static void stop_error(ll_controller *m){
 ll_stop(&m->core);m->prefix_active=m->prefix_saved=m->close_wait=m->auto_seal=0;
 m->last_error=S9_E_TIMEOUT;m->reason=7;m->stop_for_error=1;m->capture_draining=1;
 set_control(m,LL_CTL_STOP,0,0);m->notice_dirty=1;
}
void ll_controller_init(ll_controller *m,ll_record *arena,uint16_t capacity,ll_budget budget){
 memset(m,0,sizeof *m);ll_init(&m->core,arena,capacity,budget);m->next_serial=1;m->capture_unknown=1;m->status.first_missing=UINT64_MAX;m->notice_dirty=1;
}
int ll_controller_request(ll_controller *m,unsigned opcode,uint32_t sequence,unsigned timbre){
 if(!m||!sequence||opcode<LL_APP_BEGIN||opcode>LL_APP_PLAY)return S9_E_FORMAT;
 if(opcode==LL_APP_STATUS){if(m->result_valid||m->user_sequence)return S9_E_BUSY;m->user_sequence=sequence;result(m,3,0);return 0;}
 if(m->user_sequence||m->result_valid)return S9_E_BUSY;
 if((m->control==LL_CTL_STOP||m->control==LL_CTL_RELEASE_REV)&&opcode!=LL_APP_STOP&&opcode!=LL_APP_CLEAR)return S9_E_BUSY;
 if(opcode==LL_APP_BEGIN&&(timbre>5||m->core.recording!=UINT8_MAX))return S9_E_STATE;
 if(opcode==LL_APP_BEGIN&&m->core.length&&m->core.length<=PREFETCH+CONTROL_LEAD)return S9_E_RANGE;
 if(opcode==LL_APP_END&&(m->core.recording==UINT8_MAX||m->core.layer[m->core.recording].state!=LL_CAPTURE))return S9_E_STATE;
 if(opcode==LL_APP_END&&!m->core.length&&m->status.now+CONTROL_LEAD-m->core.layer[m->core.recording].start<5856u)return S9_E_RANGE;
 if(opcode==LL_APP_PLAY&&(!m->core.length||m->core.running||m->core.recording!=UINT8_MAX))return S9_E_STATE;
 m->user_opcode=(uint8_t)opcode;m->user_sequence=sequence;m->user_timbre=(uint8_t)timbre;
 m->last_error=0;m->reason=0;m->notice_dirty=1;
 /* STOP and CLEAR can preempt the one future AUTO_SEAL action. */
 if(opcode==LL_APP_STOP||opcode==LL_APP_CLEAR){m->core.running=0;m->prefix_active=0;set_control(m,LL_CTL_STOP,0,0);}
 else if(opcode==LL_APP_UNDO){
  unsigned n=LL_LAYERS;while(n&&(m->core.layer[n-1].state==LL_EMPTY||m->core.layer[n-1].state==LL_FAILED))n--;
  if(!n){m->user_sequence=0;m->user_opcode=0;return S9_E_STATE;}
  m->core.layer[n-1].scheduled=0;m->prefix_active=m->prefix_saved=m->close_wait=m->auto_seal=0;m->capture_draining=1;m->capture_empty=0;
  set_control(m,LL_CTL_RELEASE_REV,m->core.layer[n-1].revision,0);
 }
 else if(opcode==LL_APP_END&&m->auto_seal){/* Existing target is exactly start+L. */}
 return 0;
}
static int project(ll_controller *m){
 m->projection=m->core;
 if(!m->prefix_active||m->core.recording==UINT8_MAX)return 0;
 unsigned n=m->core.recording;ll_layer *p=&m->projection.layer[n],*l=&m->core.layer[n];
 if(!l->count)return 0;
 if(!m->projection.length){m->projection.length=m->planned_end-l->start;m->projection.anchor=m->planned_end;}
 if(!m->projection.length)return LL_E_TIME;
 p->state=LL_TAIL;p->play_start=m->planned_end;p->phase_base=(uint32_t)(p->play_start%m->projection.length);p->end=m->planned_end;p->scheduled=1;m->projection.running=1;
 if(m->prefix_saved){p->cursor=m->prefix.cursor;p->cycle=m->prefix.cycle;p->next_due=m->prefix.next_due;p->last_due=m->prefix.last_due;p->emitted=m->prefix.emitted;}
 else{p->cursor=p->first;p->cycle=0;p->next_due=p->play_start+m->projection.records[p->first].offset;p->emitted=0;}
 /* Admit the captured prefix once per seal. Later capture cannot extend
  * its playback watermark until close rechecks the complete layer. */
 if(m->planned_end>m->status.now+PREFETCH)return 0;
 if(m->analyzed_revision==l->revision&&m->analyzed_end==m->planned_end){
  if(m->projection.capture_watermark>m->analyzed_watermark)m->projection.capture_watermark=m->analyzed_watermark;
  return 0;
 }
 ll_analysis a;int r=ll_analyze(&m->projection,&a);
 if(!r){m->analyzed_revision=l->revision;m->analyzed_end=m->planned_end;m->analyzed_count=l->count;m->analyzed_watermark=m->core.capture_watermark;}
 return r;
}
static void start_user(ll_controller *m){
 if(!m->user_opcode||m->control||m->close_wait)return;
 switch(m->user_opcode){
 case LL_APP_BEGIN:{
  if(!m->capture_empty)return; /* Exact ACK retirement and inactive capture. */
  unsigned n=0;while(n<LL_LAYERS&&m->core.layer[n].state!=LL_EMPTY&&m->core.layer[n].state!=LL_FAILED)n++;
  if(n==LL_LAYERS||!m->core.next_revision){result(m,7,S9_E_RANGE);return;}
  set_control(m,LL_CTL_CAPTURE_ON,m->core.next_revision,m->status.now+CONTROL_LEAD);break;
 }
 case LL_APP_END:
  if(!m->auto_seal){
   m->planned_end=m->status.now+CONTROL_LEAD;
   int r=ll_prepare_phase_cache(&m->core,m->planned_end-m->core.layer[m->core.recording].start);
   if(r){failed_new(m,r,2);return;}
   m->prefix_active=1;set_control(m,LL_CTL_CAPTURE_SEAL,m->core.layer[m->core.recording].revision,m->planned_end);}break;
 case LL_APP_UNDO:{
  unsigned n=LL_LAYERS;while(n&&(m->core.layer[n-1].state==LL_EMPTY||m->core.layer[n-1].state==LL_FAILED))n--;
  if(!n){result(m,7,S9_E_STATE);return;}
  m->core.layer[n-1].scheduled=0;set_control(m,LL_CTL_RELEASE_REV,m->core.layer[n-1].revision,0);break;
 }
 case LL_APP_STOP:case LL_APP_CLEAR:set_control(m,LL_CTL_STOP,0,0);break;
 case LL_APP_PLAY:{
  uint64_t start=m->status.now+CONTROL_LEAD;int r=ll_resume(&m->core,start);
  if(r){result(m,7,mapped(r));return;}
  set_control(m,LL_CTL_KEEP,0,start);break;
 }
 default:break;
 }
}
int ll_controller_next(ll_controller *m,uint64_t now_us,uint8_t tx[LL_WIRE_BYTES]){
 if(!m||!tx)return LL_E_ARGUMENT;
 if(m->wire_kind){
  if((m->wire_kind==WIRE_EVENTS||m->wire_kind==WIRE_CONTROL)&&m->wire_confirm){
   /* MISO snapshots at CS start. Confirm with op9, retiring capture in the
    * same transaction, instead of wasting that CS on a duplicate command. */
   ll_wire_poll(tx,m->epoch,m->capture_ack,2);m->capture_ack_sent=m->capture_ack;m->wire_confirm=0;
  }else{memcpy(tx,m->pending_wire,LL_WIRE_BYTES);m->wire_confirm=1;}
  return 1;
 }
 int work=m->user_opcode||m->core.running||m->core.recording!=UINT8_MAX||m->control||m->close_wait||m->capture_draining||m->status.count||m->capture_ack!=m->capture_ack_sent;
 if(!work)return 0;
 if(!m->discovered){ll_wire_poll(tx,0,0,2);m->wire_kind=WIRE_DISCOVER;}
 else if(!m->opened){
  if(m->user_opcode==LL_APP_STOP||m->user_opcode==LL_APP_CLEAR){
   if(m->status.state!=0){m->epoch=m->status.epoch;m->next_serial=m->status.accepted_serial+1;m->opened=1;return ll_controller_next(m,now_us,tx);}
   if(m->user_opcode==LL_APP_CLEAR)ll_clear(&m->core);else ll_stop(&m->core);
   m->control=0;result(m,4,0);return 0;
  }
  if(!m->control){if(m->status.epoch==UINT32_MAX){result(m,7,S9_E_RANGE);return 0;}m->epoch=m->status.epoch+1;m->next_serial=1;set_control(m,LL_CTL_OPEN,0,0);}
  if(!m->control_serial){m->wire_serial=m->control_serial=m->next_serial;ll_wire_control(tx,m->epoch,m->control_serial,m->control,m->revision,(uint32_t)m->target);m->wire_kind=WIRE_CONTROL;}
  else{ll_wire_poll(tx,m->epoch,m->capture_ack,2);m->wire_kind=WIRE_POLL;}
 }else{
  start_user(m);
  if(m->control&&!m->control_serial){
   if(!m->next_serial){failed_new(m,LL_E_ID,5);return 0;}
   m->wire_serial=m->control_serial=m->next_serial;ll_wire_control(tx,m->epoch,m->control_serial,m->control,m->revision,(uint32_t)m->target);m->wire_kind=WIRE_CONTROL;
  }else if(m->capture_ack!=m->capture_ack_sent){ll_wire_poll(tx,m->epoch,m->capture_ack,2);m->capture_ack_sent=m->capture_ack;m->wire_kind=WIRE_POLL;}
  else if(now_us-m->last_keep_us>=100000){ll_wire_control(tx,m->epoch,0,LL_CTL_KEEP,0,0);m->wire_kind=WIRE_KEEP;m->last_keep_us=now_us;}
  else{
   int r=project(m);if(r){failed_new(m,r,2);return 0;}
   if(m->status.credit&&m->next_serial){
    r=ll_wire_prepare(&m->projection,&m->scratch,m->status.now+PREFETCH,m->epoch,m->next_serial,tx,&m->batch);
    if(r==0)m->wire_kind=WIRE_EVENTS;
    else if(r<0){failed_new(m,r,7);return 0;}
   }
   if(!m->wire_kind){
    int urgent=(m->control&&!m->auto_seal)||m->close_wait||m->status.count||m->capture_draining||
     (m->user_opcode==LL_APP_BEGIN&&!m->capture_empty);
    uint64_t interval=m->core.recording!=UINT8_MAX||m->prefix_active||!m->status.credit?5000u:20000u;
    if(!urgent&&now_us-m->last_exchange_us<interval)return 0;
    ll_wire_poll(tx,m->epoch,m->capture_ack,2);m->wire_kind=WIRE_POLL;
   }
  }
 }
 memcpy(m->pending_wire,tx,LL_WIRE_BYTES);m->wire_confirm=1;return 1;
}
static int accept_batch(ll_controller *m){
 for(unsigned i=0;i<m->batch.count;i++){
  ll_delivery *d=&m->batch.item[i];int r;
  if(m->prefix_active&&m->core.recording==d->layer&&m->core.layer[d->layer].state==LL_CAPTURE){r=ll_pop(&m->projection,d);if(!r){m->prefix=m->projection.layer[d->layer];m->prefix_saved=1;}}
  else r=ll_pop(&m->core,d);
  if(r)return r;
 }
 m->batch.active=0;return 0;
}
static void control_effective(ll_controller *m){
 unsigned ctl=m->control;m->control=0;m->control_serial=0;
 if(ctl==LL_CTL_OPEN){m->opened=1;m->late_seen=0;m->last_keep_us=m->last_exchange_us;return;}
 if(ctl==LL_CTL_CAPTURE_ON){
  uint8_t n;int r=ll_begin(&m->core,m->status.effective_sample,m->user_timbre,&n);
  if(r){failed_new(m,r,1);return;}
  /* FPGA sequence is global across ARM/OPEN. Empty-before-ARM proves the
   * first newly offered block belongs here, so learn its nonzero baseline;
   * never transmit an old ACK that could alias a reset FPGA sequence. */
  m->capture_seen=m->capture_ack=m->capture_ack_sent=0;m->capture_unknown=1;m->capture_incomplete_seen=0;
  m->capture_empty=m->capture_draining=0;m->sealed=0;m->prefix_active=m->prefix_saved=0;
  if(m->core.length){m->planned_end=m->status.effective_sample+m->core.length;m->auto_seal=1;m->prefix_active=1;set_control(m,LL_CTL_CAPTURE_SEAL,m->core.layer[n].revision,m->planned_end);}
  result(m,4,0);return;
 }
 if(ctl==LL_CTL_CAPTURE_SEAL){m->planned_end=m->status.effective_sample;m->sealed=1;m->close_wait=1;m->auto_seal=0;return;}
 if(ctl==LL_CTL_CAPTURE_OFF){m->capture_draining=1;return;}
 if(ctl==LL_CTL_STOP){
  ll_stop(&m->core);if(m->user_opcode==LL_APP_CLEAR)ll_clear(&m->core);
  m->opened=0;m->discovered=0;m->prefix_active=m->prefix_saved=m->close_wait=0;
  result(m,m->stop_for_error?7:4,m->stop_for_error?m->last_error:0);m->stop_for_error=0;return;
 }
 if(ctl==LL_CTL_RELEASE_REV){
  if(m->user_opcode==LL_APP_UNDO){uint16_t ignored;ll_undo(&m->core,&ignored);}
  if(!m->core.used&&m->core.recording==UINT8_MAX)m->close_when_drained=1;
  if(m->user_sequence)result(m,m->last_error?7:4,m->last_error);
  return;
 }
 if(ctl==LL_CTL_KEEP&&m->user_opcode==LL_APP_PLAY)result(m,4,0);
}
int ll_controller_response(ll_controller *m,uint64_t now_us,const uint8_t rx[LL_WIRE_BYTES]){
 if(!m||!m->wire_kind)return LL_E_STATE;
 ll_wire_status status;int r=ll_wire_decode(rx,&status);if(r)return r;
 unsigned wire=m->wire_kind;m->status=status;m->last_exchange_us=now_us;
 if(wire==WIRE_DISCOVER){m->discovered=1;m->wire_kind=0;return 0;}
 if(status.epoch!=m->epoch)return LL_IGNORED;
 if(status.state==0&&m->opened&&m->control!=LL_CTL_STOP&&m->control!=LL_CTL_OPEN){
  ll_stop(&m->core);m->wire_kind=0;m->batch.active=0;m->control=m->control_serial=0;
  m->opened=0;m->prefix_active=m->prefix_saved=m->close_wait=m->auto_seal=0;
  m->capture_draining=1;m->close_when_drained=1;m->last_error=S9_E_TIMEOUT;m->reason=7;
  if(m->user_sequence)result(m,7,m->last_error);
  wire=WIRE_POLL;
 }
 int accepted=0,confirmed=(wire==WIRE_EVENTS||wire==WIRE_CONTROL)&&!m->wire_confirm;
 /* A valid follow-up CS is later than the receiver's commit opportunity.
  * The error field is sticky, so it alone never rejects the current row.
  * Unaccepted absolute targets already reached cannot become valid later. */
 uint64_t deadline=wire==WIRE_EVENTS?m->batch.item[0].due:m->target;
 uint32_t wanted=wire==WIRE_EVENTS?m->batch.serial:m->wire_serial;
 if(confirmed&&status.accepted_serial!=wanted&&deadline&&status.now>=deadline){
  unsigned ctl=m->control;uint16_t revision=m->revision;
  int new_layer=wire==WIRE_EVENTS&&m->core.recording!=UINT8_MAX&&m->batch.item[0].revision==m->core.layer[m->core.recording].revision;
  m->wire_kind=0;m->batch.active=0;m->control_serial=0;m->next_serial=status.accepted_serial+1;
  if(new_layer||(wire==WIRE_CONTROL&&(ctl==LL_CTL_CAPTURE_ON||ctl==LL_CTL_CAPTURE_SEAL))){
   if(ctl==LL_CTL_CAPTURE_ON)m->core.last_failed_revision=revision;
   failed_new(m,LL_E_TIME,7);
  }else stop_error(m);
  wire=WIRE_POLL;
 }
 if(wire==WIRE_CONTROL&&status.accepted_serial==m->wire_serial){accepted=1;m->next_serial=m->wire_serial+1;}
 else if(wire==WIRE_EVENTS&&status.accepted_serial==m->batch.serial){accepted=1;m->next_serial=m->batch.serial+1;r=accept_batch(m);if(r){failed_new(m,r,7);return r;}}
 else if(wire==WIRE_POLL||wire==WIRE_KEEP)accepted=1;
 if(accepted)m->wire_kind=0;
 if(m->control_serial&&status.effective_control_serial==m->control_serial)control_effective(m);
 if(((status.flags&8)||status.state==3)&&!m->late_seen){m->late_seen=1;stop_error(m);}
 else if((status.flags&2)&&!m->capture_incomplete_seen&&m->core.recording!=UINT8_MAX){m->capture_incomplete_seen=1;failed_new(m,LL_E_CAPACITY,1);}
 if(status.count&&status.capture_sequence!=m->capture_seen){
  if(!m->capture_unknown&&status.capture_sequence!=m->capture_seen+1&&m->core.recording!=UINT8_MAX)failed_new(m,LL_E_TIME,6);
  m->capture_unknown=0;
  for(unsigned i=0;i<status.count;i++){
   ll_capture_cell *v=&status.cell[i];
   if(((v->word>>24)&15u)==1&&m->core.recording!=UINT8_MAX){
    const ll_layer *l=&m->core.layer[m->core.recording];
    /* Only an ON actually inside this capture owns the fixed-layer timbre.
     * Uncaptured pre-existing gestures' OFF/EXPR cannot reject a new layer. */
    if(l->state==LL_CAPTURE&&v->frame>=l->start&&(!m->core.length||v->frame-l->start<m->core.length)&&v->timbre!=l->timbre){failed_new(m,LL_E_ADMISSION,2);break;}
   }
   r=ll_capture(&m->core,v->frame,v->token,v->word);
   if(r<0){failed_new(m,r,r==LL_E_CAPACITY?1:2);break;}
  }
  m->capture_seen=m->capture_ack=status.capture_sequence;
 }
 if(!(status.flags&1)&&!status.count&&m->capture_ack==m->capture_ack_sent){
  m->capture_empty=1;m->capture_draining=0;
  if(m->close_when_drained){m->opened=0;m->discovered=0;m->close_when_drained=0;}
 }else m->capture_empty=0;
 if(status.watermark>=m->core.capture_watermark)ll_watermark(&m->core,status.watermark);
 if(m->close_wait&&m->core.recording!=UINT8_MAX&&m->core.capture_watermark>=m->planned_end){
  unsigned n=m->core.recording;r=ll_close(&m->core,m->planned_end,m->planned_end);
  if(r){failed_new(m,r,2);return r;}
  if(m->prefix_saved){ll_layer *l=&m->core.layer[n];l->cursor=m->prefix.cursor;l->cycle=m->prefix.cycle;l->next_due=m->prefix.next_due;l->last_due=m->prefix.last_due;l->emitted=m->prefix.emitted;}
  m->prefix_active=m->prefix_saved=m->close_wait=0;
  if(m->user_opcode==LL_APP_END)result(m,4,0);
  m->notice_dirty=1;
 }
 if(m->sealed&&m->core.recording==UINT8_MAX&&!m->control){set_control(m,LL_CTL_CAPTURE_OFF,0,status.now+480u);m->sealed=0;}
 m->notice_dirty=1;return 0;
}
void ll_controller_transport_failed(ll_controller *m){
 if(!m)return;
 /* Immutable wire packet is retained for retry; accepted identities/cursors
  * are advanced only by a validated exact serial ACK. */
 m->last_error=S9_E_IO;m->reason=6;m->notice_dirty=1;
}
void ll_controller_disconnect(ll_controller *m){
 if(!m)return;
 m->user_sequence=0;m->user_opcode=0;m->result_valid=0;
 uint16_t revision=m->control==LL_CTL_CAPTURE_ON?m->revision:0;
 if(m->core.recording!=UINT8_MAX){uint16_t active;ll_disconnect(&m->core,&active);if(active)revision=active;}
 if(revision){
  /* CAPTURE_ON may already be accepted but not yet effective. Its explicit
   * revision cancels that future action as well as any active capture. */
  if(m->control==LL_CTL_CAPTURE_ON){m->capture_seen=m->capture_ack=m->capture_ack_sent=0;m->capture_unknown=1;}
  m->prefix_active=m->prefix_saved=m->close_wait=m->auto_seal=0;m->capture_draining=1;m->capture_empty=0;
  set_control(m,LL_CTL_RELEASE_REV,revision,0);
 }
}
int ll_controller_active(const ll_controller *m){return m&&(m->core.running||m->core.recording!=UINT8_MAX||m->control||m->opened);}
void ll_controller_info(const ll_controller *m,uint8_t p[64]){
 memset(p,0,64);p[0]=1;p[3]=UINT8_MAX;uint32_t flags=m->core.running?1u:0u;
 for(unsigned i=0;i<LL_LAYERS;i++){
  const ll_layer *l=&m->core.layer[i];if(l->state!=LL_EMPTY&&l->state!=LL_FAILED)p[2]++;
  s9_put16(p+40+i*2,(uint16_t)l->count);p[48+i]=l->timbre;p[52+i]=l->state;
 }
 if(m->core.recording!=UINT8_MAX){const ll_layer *l=&m->core.layer[m->core.recording];p[3]=m->core.recording;p[1]=l->state==LL_TAIL?4:m->core.length?3:1;if(l->state==LL_TAIL)flags|=6;}
 else p[1]=m->core.running?2:m->core.used?5:0;
 if(m->control==LL_CTL_STOP||m->control==LL_CTL_RELEASE_REV){p[1]=6;flags|=32;}
 if(m->last_error&&m->reason==7&&!m->core.running&&!m->control)p[1]=7;
 if(m->reason==1)flags|=8;
 if(m->reason==2||m->reason==3)flags|=16;
 s9_put32(p+4,flags);s9_put32(p+8,(uint32_t)m->last_error);s9_put32(p+12,m->user_sequence?m->user_sequence:m->result_sequence);
 s9_put64(p+16,m->effective_sample);s9_put64(p+24,m->core.length);s9_put32(p+32,m->core.used);s9_put32(p+36,m->core.capacity);
 p[56]=LL_LAYERS;p[57]=24;p[58]=48;p[59]=m->reason;s9_put32(p+60,m->core.budget.max_length_samples);
}
