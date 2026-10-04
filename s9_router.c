#include "s9_router.h"
#include <string.h>
void s9_make_result(uint8_t out[36],uint8_t channel,uint32_t sequence,unsigned phase,int error){
 memset(out,0,36);s9_put32(out,sequence);out[4]=channel;out[5]=(uint8_t)phase;s9_put16(out+6,(uint16_t)error);
}
void s9_router_reset(s9_router *s,const uint8_t session[16],uint32_t generation){
 memset(s,0,sizeof *s);memcpy(s->session,session,16);s->generation=generation;s->notification_sequence=1;
}
void s9_router_ready(s9_router *s,int value){s->ready=value!=0;}
void s9_router_disconnect(s9_router *s){
 s->ready=0;
 for(unsigned i=0;i<3;i++)s9_reassembly_reset(&s->assembly[i]);
 for(unsigned i=0;i<S9_ROUTER_SLOTS;i++)if(s->entry[i].used&&!s->entry[i].terminal){
  s9_router_entry *e=&s->entry[i];s9_make_result(e->result,e->request[5],s9_get32(e->request+24),6,0);
  e->terminal=1;e->dirty=0;s->cancelled++;
 }
 s->error_dirty=0;
}
static int transient(s9_router *s,unsigned channel,uint32_t sequence,int error){
 if(sequence){s9_make_result(s->error_result,(uint8_t)channel,sequence,7,error);s->error_dirty=1;}
 s->rejected++;return error;
}
static int find(const s9_router *s,unsigned ch,uint32_t sequence){
 for(unsigned i=0;i<S9_ROUTER_SLOTS;i++)if(s->entry[i].used&&s->entry[i].request[5]==ch&&s9_get32(s->entry[i].request+24)==sequence)return (int)i;
 return -1;
}
int s9_router_fragment(s9_router *s,uint32_t generation,uint8_t channel,const uint8_t *data,unsigned length,uint32_t now){
 if(generation!=s->generation||!s->ready)return S9_E_SESSION;
 if(channel>2||!data||length<8)return S9_E_FORMAT;
 if(s->error_dirty)return S9_E_BUSY; /* Caller retains this queue item. */
 s9_reassembly *a=&s->assembly[channel];
 /* Keep a completed prefix for an ACK-lost final fragment retry. Offset zero
  * starts a complete application retry/new message, but never replaces an
  * incomplete different command. Fragment counts are not command counts. */
 if(a->active&&a->used>=32&&a->used==36u+s9_get16(a->bytes+28)&&
    !s9_get16(data+4))s9_reassembly_reset(a);
 uint16_t count=0;int r=s9_fragment_push(&s->assembly[channel],channel,data,length,now,&count);
 if(r<0)return transient(s,channel,s9_get32(data),r);
 if(r!=S9_COMPLETE)return r;
 s9_message message;const uint8_t *raw=s->assembly[channel].bytes;
 r=s9_decode(raw,count,&message);
 if(r)return transient(s,channel,s9_get32(data),r);
 if(memcmp(message.session,s->session,16))return transient(s,channel,message.sequence,S9_E_SESSION);
 int old=find(s,channel,message.sequence);
 if(old>=0){
  s9_router_entry *e=&s->entry[old];
  if(e->length!=count||memcmp(e->request,raw,count))return transient(s,channel,message.sequence,S9_E_CONFLICT);
  e->dirty=1;s->retries++;return 0;
 }
 if(message.sequence<=s->highwater[channel])return transient(s,channel,message.sequence,S9_E_EXPIRED);
 if(s->order==0xffffffffu)return transient(s,channel,message.sequence,S9_E_SEQUENCE);
 int slot=-1;uint32_t age=0xffffffff;
 for(unsigned i=0;i<S9_ROUTER_SLOTS;i++){
  s9_router_entry *e=&s->entry[i];
  if(!e->used){slot=(int)i;break;}
  if(e->terminal&&!e->dirty&&e->order<age){slot=(int)i;age=e->order;}
 }
 if(slot<0)return transient(s,channel,message.sequence,S9_E_BUSY);
 s9_router_entry *e=&s->entry[slot];memset(e,0,sizeof *e);memcpy(e->request,raw,count);
 e->used=1;e->length=count;e->order=++s->order;e->dirty=1;
 s->highwater[channel]=message.sequence;s->unique++;
 r=s9_validate_request(&message);
 s9_make_result(e->result,channel,message.sequence,r?7:1,r);
 if(r){e->terminal=1;s->rejected++;s->finished++;}
 return r;
}
int s9_router_peek(s9_router *s,unsigned *slot,s9_message *m,const uint8_t **raw,unsigned *length){
 if(!s->ready)return 0;
 /* Round-robin channel service; oldest per-channel preserves RT order. */
 for(unsigned offset=0;offset<3;offset++){
  unsigned channel=(s->dispatch_cursor+offset)%3;int chosen=-1;uint32_t age=0xffffffff;
  for(unsigned i=0;i<S9_ROUTER_SLOTS;i++){
   s9_router_entry *e=&s->entry[i];
   if(e->used&&!e->sent&&!e->terminal&&e->request[5]==channel&&e->order<age){chosen=(int)i;age=e->order;}
  }
  if(chosen>=0){
   s9_router_entry *e=&s->entry[chosen];*slot=(unsigned)chosen;*raw=e->request;*length=e->length;
   if(s9_decode(e->request,e->length,m))return 0;
   return 1;
  }
 }
 return 0;
}
void s9_router_sent(s9_router *s,unsigned slot){
 if(slot>=S9_ROUTER_SLOTS)return;
 s9_router_entry *e=&s->entry[slot];if(!e->used||e->sent||e->terminal)return;
 e->sent=1;s->dispatched++;s->dispatch_cursor=(e->request[5]+1)%3;
}
static unsigned goal(const s9_router_entry *e){
 unsigned op=e->request[6];
 if(e->request[5]==0)return 3;
 if(e->request[5]==2)return op==S9_OP_UPLOAD_COMMIT?4:3;
 if(op==S9_OP_GAIN)return 5;
 if(op==S9_OP_GLIDE||op==S9_OP_PAN||op==S9_OP_EFFECTS||op==S9_OP_KEYMAP)return 4;
 return 3;
}
int s9_router_result(s9_router *s,uint32_t generation,const uint8_t session[16],const uint8_t r[36]){
 if(!s->ready||generation!=s->generation||memcmp(session,s->session,16)){s->stale_updates++;return S9_E_STALE;}
 unsigned channel=r[4],phase=r[5];int error=(int16_t)s9_get16(r+6);uint32_t flags=s9_get32(r+32);
 if(channel>2||!s9_get32(r)||phase<1||phase>7||error>0||error< -13||(flags&~7u)||
    (phase==7&&error>=0)||(phase==4&&!(flags&5))||((flags&4)&&(channel!=2||phase!=4||error)))return S9_E_FORMAT;
 int n=find(s,channel,s9_get32(r));if(n<0){s->stale_updates++;return S9_E_EXPIRED;}
 s9_router_entry *e=&s->entry[n];
 if(!e->sent||e->terminal||phase<e->result[5]){s->stale_updates++;return S9_E_STALE;}
 if(e->request[5]==2&&e->request[6]==S9_OP_UPLOAD_COMMIT&&phase==4&&!(flags&4))return S9_E_FORMAT;
 memcpy(e->result,r,36);e->dirty=1;
 if(phase>=6||phase>=goal(e)){e->terminal=1;s->finished++;}
 return 0;
}
int s9_router_notice(s9_router *s,uint8_t *out,unsigned capacity){
 if(!s->ready||!s->notification_sequence)return 0;
 uint8_t *p=0;int chosen=-1;
 if(s->error_dirty)p=s->error_result;
 else for(unsigned i=0;i<S9_ROUTER_SLOTS;i++){
  unsigned k=(s->notification_cursor+i)%S9_ROUTER_SLOTS;
  if(s->entry[k].used&&s->entry[k].dirty){p=s->entry[k].result;chosen=(int)k;break;}
 }
 if(!p)return 0;
 int n=s9_encode(out,capacity,3,128,s->session,s->notification_sequence,p,36);if(n<0)return n;
 s->notification_sequence++;
 if(chosen<0)s->error_dirty=0;
 else{s->entry[chosen].dirty=0;s->notification_cursor=(chosen+1)%S9_ROUTER_SLOTS;}
 return n;
}
