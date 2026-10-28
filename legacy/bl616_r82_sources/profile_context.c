#include "profile_context.h"
#include <string.h>
static struct pc_rx *find(struct pc_core*c,uintptr_t task){unsigned i;for(i=0;i<PC_RX_CONTEXTS;i++)if(c->rx[i].active&&c->rx[i].task==task)return &c->rx[i];return 0;}
void pc_init(struct pc_core*c){memset(c,0,sizeof(*c));ig_init(&c->source);c->next_rx=1;}
uint32_t pc_begin(struct pc_core*c,uintptr_t task,struct ig_identity id,int kind,uint8_t before,const uint8_t*data,uint16_t len)
{unsigned i;struct pc_rx*r=0;if(!task||!c->next_rx||find(c,task)){c->context_faults++;ig_retire(&c->source,id,IG_CONTEXT);return 0;}for(i=0;i<PC_RX_CONTEXTS;i++)if(!c->rx[i].active){r=&c->rx[i];break;}if(!r){c->context_faults++;ig_retire(&c->source,id,IG_CONTEXT);return 0;}memset(r,0,sizeof(*r));r->active=1;r->kind=(uint8_t)kind;r->task=task;r->serial=c->next_rx++;r->e.identity=id;r->e.rx_task=task;r->e.rx_serial=r->serial;r->e.before_state=before;
 if(kind==PC_SIGNAL){if(len<2 || (data[0]&15)!=0){r->active=0;return 0;}r->e.request_label=data[0]>>4;r->e.request_signal=data[1]&63;}
 else if(kind==PC_MEDIA){struct ig_transport*t=&c->source.transports[0];uint64_t captured=t->pending_start?t->pending_epoch:t->epoch;r->captured_epoch=captured;c->source.rx_active_epoch=captured;c->media_before++;ig_copy(&c->source,id,captured,r->serial,data,len);}else {r->active=0;return 0;}
 return r->serial;
}
struct pc_send pc_send_before(struct pc_core*c,uintptr_t task,uintptr_t conn,const uint8_t*data,uint16_t len)
{struct pc_send s={0};struct pc_rx*r=find(c,task);if(!r||r->kind!=PC_SIGNAL||r->e.identity.conn!=conn||len<2)return s;s.task=task;s.identity=r->e.identity;s.serial=r->serial;s.label=data[0]>>4;s.type=data[0]&3;s.signal=data[1]&63;s.valid=1;return s;}
void pc_send_after(struct pc_core*c,const struct pc_send*s,int result)
{struct pc_rx*r;if(!s->valid)return;r=find(c,s->task);if(!r||r->serial!=s->serial||r->kind!=PC_SIGNAL)return;if(r->have_response){c->context_faults++;ig_retire(&c->source,r->e.identity,IG_CONTEXT);return;}r->have_response=1;r->e.send_task=s->task;r->e.response_label=s->label;r->e.response_signal=s->signal;r->e.response_type=s->type;r->e.send_result=result;}
void pc_callback(struct pc_core*c,uintptr_t task,uint8_t state)
{struct pc_rx*r=find(c,task);if(!r||r->kind!=PC_SIGNAL){c->late_callbacks++;return;}if(r->callback_seen){c->context_faults++;ig_retire(&c->source,r->e.identity,IG_CONTEXT);return;}r->callback_seen=1;r->e.callback_state=state;/* Callback is the actual accepted Profile effect, not a post-return object read. */r->e.after_state=state==3?3:state==4?2:255;}
int pc_end(struct pc_core*c,uintptr_t task,uint32_t serial)
{struct pc_rx*r=find(c,task);int accepted=0;if(!r||r->serial!=serial)return 0;if(r->kind==PC_SIGNAL){accepted=ig_accepted(&c->source,&r->e);if(!accepted&&r->have_response&&r->e.send_result<0&&(r->e.request_signal==IG_CLOSE||r->e.request_signal==IG_ABORT))ig_retire(&c->source,r->e.identity,IG_RESPONSE);}r->active=0;c->source.rx_active_epoch=0;{unsigned i;for(i=0;i<PC_RX_CONTEXTS;i++)if(c->rx[i].active&&c->rx[i].captured_epoch){c->source.rx_active_epoch=c->rx[i].captured_epoch;break;}}c->original_returned++;return accepted;}

int pc_fence(struct pc_core*c,struct ig_identity id)
{unsigned i;uint64_t old=c->source.transports[0].retiring_epoch;for(i=0;i<PC_RX_CONTEXTS;i++)if(c->rx[i].active&&old&&c->rx[i].captured_epoch==old)return 0;return ig_fence(&c->source,id);}
