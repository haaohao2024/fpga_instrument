#include "ingress_core.h"
#include <string.h>
static int same(struct ig_identity a,struct ig_identity b)
{ return a.conn==b.conn && a.chan==b.chan && a.connection_serial==b.connection_serial && a.cid==b.cid; }
static int index_of(const struct ig_core *s,struct ig_identity id)
{ unsigned i;for(i=0;i<IG_CONNECTIONS;i++)if(s->transports[i].attached && same(s->transports[i].identity,id))return (int)i;return -1; }
static uint64_t alloc_epoch(struct ig_core *s)
{ unsigned i;uint64_t e=s->next_epoch;if(!e)return 0;for(i=0;i<IG_CONNECTIONS;i++)if(s->transports[i].epoch==e || s->transports[i].retiring_epoch==e || s->transports[i].pending_epoch==e)return 0;s->next_epoch=e+1u;return e; }
void ig_init(struct ig_core *s){memset(s,0,sizeof(*s));s->next_epoch=1;s->next_ticket=1;}
int ig_attach(struct ig_core *s,struct ig_identity id)
{unsigned i;if(!id.conn || !id.chan || !id.connection_serial || !id.cid)return 0;if(index_of(s,id)>=0)return 1;for(i=0;i<IG_CONNECTIONS;i++)if(!s->transports[i].attached){memset(&s->transports[i],0,sizeof(s->transports[i]));s->transports[i].attached=1;s->transports[i].identity=id;return 1;}return 0;}
static void drop_epoch(struct ig_core *s,struct ig_identity id,uint64_t epoch)
{unsigned i;for(i=0;i<IG_SLOTS;i++)if(s->slots[i].state==IG_READY && same(s->slots[i].identity,id) && s->slots[i].epoch==epoch){s->slots[i].state=IG_FREE;s->discarded++;}}
void ig_retire(struct ig_core *s,struct ig_identity id,enum ig_reason reason)
{int n=index_of(s,id);struct ig_transport *t;if(n<0)return;t=&s->transports[n];if(reason!=IG_NONE && !t->fault){t->fault=(uint8_t)reason;s->faults++;}if(t->pending_start){drop_epoch(s,id,t->pending_epoch);t->pending_start=0;t->pending_epoch=0;}if(t->playing){t->retiring_epoch=t->epoch;t->playing=0;t->external_retire_pending=1;t->retire_serial++;s->retired++;drop_epoch(s,id,t->epoch);}}
static int accept_proven(const struct ig_evidence *e)
{return e->rx_task && e->rx_task==e->send_task && e->rx_serial && e->response_type==2 && e->request_label==e->response_label && e->request_signal==e->response_signal && e->send_result>=0;}
int ig_accepted(struct ig_core *s,const struct ig_evidence *e)
{int n=index_of(s,e->identity);struct ig_transport *t;uint64_t epoch;if(n<0 || !accept_proven(e))return 0;t=&s->transports[n];
 if(e->request_signal==IG_START){
  if(e->after_state!=3 || e->callback_state!=3 || (e->before_state!=2 && e->before_state!=3))return 0;
  if(t->playing){s->duplicate_starts++;return 1;}
  if(t->fault || t->pending_start)return 0;
  epoch=alloc_epoch(s);if(!epoch){ig_retire(s,e->identity,IG_GENERATION);return 0;}
  s->accepted_starts++;
  if(t->retiring_epoch){t->pending_start=1;t->pending_epoch=epoch;}else{t->epoch=epoch;t->playing=1;}
  return 1;
 }
 if(e->request_signal==IG_SUSPEND){if(e->before_state!=3 || e->after_state!=2 || e->callback_state!=4)return 0;ig_retire(s,e->identity,IG_NONE);return 1;}
 if(e->request_signal==IG_CLOSE || e->request_signal==IG_ABORT){if(e->before_state!=2 && e->before_state!=3)return 0;ig_retire(s,e->identity,IG_NONE);return 1;}
 return 0;
}
static int raw_valid(const uint8_t *p,uint16_t n)
{uint16_t h;if(n<13 || (p[0]>>6)!=2 || (p[0]&0x30))return 0;h=(uint16_t)(12u+4u*(p[0]&15u));if(n<=h)return 0;if((p[h]&0x10) || !(p[h]&15))return 0;if(!(p[h]&0x80) && (p[h]&0x60))return 0;return 1;}
int ig_copy(struct ig_core *s,struct ig_identity id,uint64_t captured_epoch,uint32_t rx_serial,const uint8_t *sdu,uint16_t len)
{int n=index_of(s,id);struct ig_transport *t;unsigned i;uint64_t epoch;if(n<0)return 0;t=&s->transports[n];if(t->fault || (!t->playing && !t->pending_start)){s->old_rejected++;return 0;}epoch=t->pending_start?t->pending_epoch:t->epoch;if(!captured_epoch || captured_epoch!=epoch || !rx_serial || rx_serial<=t->last_rx_serial){s->old_rejected++;return 0;}t->last_rx_serial=rx_serial;if(len>IG_SDU_BYTES || !raw_valid(sdu,len)){ig_retire(s,id,IG_FORMAT);return 0;}if(!s->next_ticket){ig_retire(s,id,IG_GENERATION);return 0;}
 for(i=0;i<IG_SLOTS;i++)if(s->slots[i].state==IG_FREE){memcpy(s->slots[i].data,sdu,len);s->slots[i].identity=id;s->slots[i].epoch=epoch;s->slots[i].ticket=s->next_ticket++;s->slots[i].len=len;s->slots[i].state=IG_READY;s->copied++;return 1;}
 ig_retire(s,id,IG_FULL);return 0;
}
int ig_claim(struct ig_core *s,uint64_t *ticket,const struct ig_slot **slot)
{unsigned i;int best=-1;for(i=0;i<IG_SLOTS;i++)if(s->slots[i].state==IG_READY){int n=index_of(s,s->slots[i].identity);const struct ig_transport *t;if(n<0)continue;t=&s->transports[n];if(!t->playing || t->fault || t->epoch!=s->slots[i].epoch)continue;if(best<0 || s->slots[i].ticket<s->slots[best].ticket)best=(int)i;}if(best<0)return 0;s->slots[best].state=IG_CLAIMED;s->claimed++;*ticket=s->slots[best].ticket;*slot=&s->slots[best];return 1;}
int ig_active(const struct ig_core *s,uint64_t epoch)
{unsigned i;for(i=0;i<IG_CONNECTIONS;i++)if(s->transports[i].attached && s->transports[i].playing && !s->transports[i].fault && s->transports[i].epoch==epoch)return 1;return 0;}
int ig_task_valid(const struct ig_core *s,uint64_t ticket,uint64_t epoch)
{unsigned i;for(i=0;i<IG_SLOTS;i++)if(s->slots[i].state==IG_CLAIMED && s->slots[i].ticket==ticket && s->slots[i].epoch==epoch){int n=index_of(s,s->slots[i].identity);return n>=0 && s->transports[n].playing && !s->transports[n].fault && s->transports[n].epoch==epoch;}return 0;}
int ig_release(struct ig_core *s,uint64_t ticket,uint64_t epoch)
{unsigned i;for(i=0;i<IG_SLOTS;i++)if(s->slots[i].state==IG_CLAIMED && s->slots[i].ticket==ticket && s->slots[i].epoch==epoch){s->slots[i].state=IG_FREE;s->released++;return 1;}return 0;}
int ig_external_retire_done(struct ig_core *s,struct ig_identity id,uint64_t epoch,uint64_t serial)
{int n=index_of(s,id);struct ig_transport *t;if(n<0)return 0;t=&s->transports[n];if(!epoch || epoch!=t->retiring_epoch || serial!=t->retire_serial)return 0;t->external_retire_pending=0;return 1;}
int ig_fence(struct ig_core *s,struct ig_identity id)
{int n=index_of(s,id);struct ig_transport *t;unsigned i;if(n<0)return 0;t=&s->transports[n];if(!t->retiring_epoch)return 1;if(t->external_retire_pending || s->rx_active_epoch==t->retiring_epoch)return 0;for(i=0;i<IG_SLOTS;i++)if(s->slots[i].state!=IG_FREE && same(s->slots[i].identity,id) && s->slots[i].epoch==t->retiring_epoch)return 0;t->retiring_epoch=0;s->fences++;if(t->pending_start && !t->fault){t->epoch=t->pending_epoch;t->pending_epoch=0;t->pending_start=0;t->playing=1;}return 1;}
int ig_detach(struct ig_core *s,struct ig_identity id)
{int n=index_of(s,id);if(n<0)return 0;ig_retire(s,id,IG_NONE);if(!ig_fence(s,id))return 0;s->transports[n].attached=0;return 1;}
int ig_conserved(const struct ig_core *s)
{unsigned i;uint32_t ready=0,claimed=0;for(i=0;i<IG_SLOTS;i++){ready+=s->slots[i].state==IG_READY;claimed+=s->slots[i].state==IG_CLAIMED;}return s->copied==s->released+s->discarded+ready+claimed && s->claimed==s->released+claimed;}
