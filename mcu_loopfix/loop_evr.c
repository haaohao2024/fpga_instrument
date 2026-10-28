#include "loop_evr.h"
#include "s9_protocol.h"
#include <string.h>
void loop_evr_init(loop_evr *e,uint64_t id){memset(e,0,sizeof *e);e->next_token=1;e->record_id=id;e->seal=UINT64_MAX;}
void loop_evr_seal(loop_evr *e,uint64_t frame){e->seal=frame;}
static uint64_t grid(uint64_t frame,uint64_t step){return frame/step*step;}
static int retire(loop_evr *e,ll_core *c,unsigned slot,uint64_t frame){
 loop_native_slot *s=&e->slot[slot];if(!s->captured)return 0;s->captured=0;
 return ll_capture_owner(c,slot,grid(frame,LOOP_GRID),s->token,(s->word&0xf0ff0000u)|0x02000000u);
}
int loop_evr_feed(loop_evr *e,ll_core *c,const uint8_t p[32]){
 unsigned type=p[0],source=p[2],key=p[3];uint32_t seq=s9_get32(p+4);uint64_t frame=s9_get64(p+8),tag=s9_get64(p+16),payload=s9_get64(p+24);
 if(seq!=e->next_sequence)return LL_E_ID;
 e->next_sequence++;
 if(type==1){if(e->started)return LL_E_STATE;e->started=1;e->start_frame=frame;return 0;}
 if(!e->started)return LL_E_STATE;
 if(type==23||type==24)return LL_E_TIME;
 if(type!=4&&type!=5&&type!=6&&type!=8)return 0;
 unsigned slot=(unsigned)(payload>>59)|((p[1]&64u)?32u:0u),gen=(unsigned)(payload>>43)&65535u,timbre=(unsigned)(payload>>31)&7u;
 if(slot>=48||tag!=(0x200000u|((uint64_t)gen<<5)|(slot&31u)|((uint64_t)(slot>>5)<<22))||source>15||timbre>5)return LL_E_ID;
 loop_native_slot *s=&e->slot[slot];
 uint32_t word=source<<28|key<<16|((uint32_t)(payload>>16)&127u)<<9|((uint32_t)(payload>>23)&255u)<<1;
 if(type==8){s->native_tag=tag;s->word=word;s->valid=1;s->captured=0;return 0;}
 if(type==4){
  int r=retire(e,c,slot,frame);if(r<0)return r;
  s->native_tag=tag;s->word=word;s->valid=1;s->captured=0;
  if(!((source==0&&key<8)||(source==2&&key<32))||c->recording==UINT8_MAX)return 0;
  const ll_layer *l=&c->layer[c->recording];
  if(l->state!=LL_CAPTURE||frame<l->start||frame>=e->seal||(c->length&&frame-l->start>=c->length))return 0;
  if(timbre!=l->timbre)return 0; /* other-timbre note is played live, not recorded */
  if(!e->next_token)return LL_E_ID;
  s->token=e->next_token++;s->expr_bin=(uint32_t)(frame/LOOP_EXPR_GRID);
  r=ll_capture_owner(c,slot,grid(frame,LOOP_GRID),s->token,word|0x01000000u);if(r==0)s->captured=1;return r;
 }
 if(!s->valid||s->native_tag!=tag||(s->word&0xf0ff0000u)!=(word&0xf0ff0000u)||!s->captured)return 0;
 if(type==5)return retire(e,c,slot,frame);
 if(timbre==5)return 0; /* proved one-shot EXPR audio-bit-equivalent */
 uint32_t bin=(uint32_t)(frame/LOOP_EXPR_GRID);if(bin==s->expr_bin)return 0;
 s->expr_bin=bin;
 return ll_capture_owner(c,slot,(uint64_t)bin*LOOP_EXPR_GRID,s->token,word|0x03000000u);
}
