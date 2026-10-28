#include "audio_timebase.h"
#include "ensemble.h"
#include "s9_protocol.h"
#include <string.h>
ensemble ensemble_state;
_Static_assert(sizeof(ensemble)<=4096,"Bounded intelligent accompaniment storage");
int ens_decode_config(const uint8_t p[8],ens_config *c){
 if(!p||!c||p[0]!=1||p[1]>2||p[2]>11||p[3]>1||p[6]>2||p[7]||s9_get16(p+4)<50||s9_get16(p+4)>180)return S9_E_RANGE;
 *c=(ens_config){.level=p[1],.root=p[2],.minor=p[3],.bpm=s9_get16(p+4),.style=p[6]};return 0;
}
void ens_init(ensemble *e){memset(e,0,sizeof *e);e->last_note=60;}
int ens_begin(ensemble *e,const ens_config *c,uint64_t anchor,uint16_t rev){
 if(!e||!c||!rev||e->running||e->write!=e->read)return S9_E_BUSY;
 e->config=*c;e->anchor=e->next_tick=anchor;e->tick_index=e->token_counter=e->generated=e->skipped=e->peak_slots=0;
 e->last_generated=anchor;e->revision=rev;e->running=1;e->pending=e->reason=0;
 for(unsigned i=0;i<ENS_VOICES;i++){memset(&e->voice[i],0,sizeof e->voice[i]);e->voice[i].off=UINT64_MAX;}
 return 0;
}
void ens_capture(ensemble *e,const uint8_t p[32]){
 unsigned type=p[0],source=p[2];uint64_t payload=s9_get64(p+24),tag=s9_get64(p+16),frame=s9_get64(p+8);
 if(type==1){memset(e->native,0,sizeof e->native);e->human_held=0;return;}
 if(type!=4&&type!=5&&type!=6&&type!=8)return;
 unsigned slot=(unsigned)(payload>>59)|((p[1]&64u)?32u:0u);if(slot>=48)return;ens_native *v=&e->native[slot];
 if(type==4||type==8){v->tag=tag;v->source=(uint8_t)source;v->key=p[3];v->note=(uint8_t)(payload>>16)&127;v->gate=(uint8_t)(type==4||!(p[1]&16));}
 else if(v->tag==tag){if(type==5)v->gate=0;else v->note=(uint8_t)(payload>>16)&127;}
 e->human_held=0;for(unsigned i=0;i<48;i++)if((e->native[i].source==0||e->native[i].source==2)&&e->native[i].gate)e->human_held++;
 if((source==0||source==2)&&(type==4||type==6)){
  unsigned note=(unsigned)(payload>>16)&127,vel=(unsigned)(payload>>23)&255;
  if(type==4){unsigned pc=note%12,weight=1+vel/32;e->histogram[pc]=(uint16_t)(e->histogram[pc]>2048?2048:e->histogram[pc]+weight);e->observed++;}
  e->last_note=(uint8_t)note;e->last_input=frame;
 }
}
static unsigned slots(const ensemble *e,uint64_t at){
 unsigned n=0;for(unsigned i=0;i<ENS_VOICES;i++){const ens_voice *v=&e->voice[i];n+=v->on;n+=v->tail[0]>at;n+=v->tail[1]>at;}return n;
}
static int append(ensemble *e,uint64_t at,unsigned part,unsigned kind,unsigned note,unsigned vel,uint64_t token,unsigned timbre){
 if(e->write-e->read>=ENS_CAPACITY||at<e->last_generated||!token)return S9_E_BUSY;
 e->queue[e->write%ENS_CAPACITY]=(ens_event){at,token,(3u<<28)|(kind<<24)|((0x80u+part)<<16)|(note<<9)|(vel<<1),(uint8_t)timbre};
 e->write++;e->last_generated=at;e->generated++;return 0;
}
static int off(ensemble *e,unsigned p,uint64_t at){
 ens_voice *v=&e->voice[p];if(!v->on)return 0;
 int r=append(e,at,p,2,0,0,v->token,v->timbre);if(r)return r;
 uint64_t end=v->timbre==5?v->off+AUDIO_MS(300):at+AUDIO_MS(150);
 if(v->tail[0]<=at)v->tail[0]=end;else if(v->tail[1]<=at)v->tail[1]=end;else return S9_E_STATE;
 v->on=0;v->off=UINT64_MAX;return 0;
}
static int on(ensemble *e,unsigned p,unsigned note,unsigned timbre,unsigned vel,uint64_t at,uint64_t duration){
 ens_voice *v=&e->voice[p];if(v->on&&v->note==note&&v->timbre==timbre&&duration==UINT64_MAX)return 0;
 // Reserve sixteen contexts for this accompaniment, including release tails.
 // Optional future attacks may be thinned; already admitted OFFs are retained.
 if(slots(e,at)>=16||e->human_held>16){e->skipped++;return 0;}
 if(v->on){int r=off(e,p,at);if(r)return r;}
 if(e->token_counter==UINT32_MAX)return S9_E_SEQUENCE;
 uint64_t token=((uint64_t)e->revision<<48)|++e->token_counter;
 int r=append(e,at,p,1,note,vel,token,timbre);if(r)return r;
 v->on=1;v->note=(uint8_t)note;v->timbre=(uint8_t)timbre;v->velocity=(uint8_t)vel;v->token=token;
 v->off=duration==UINT64_MAX?UINT64_MAX:at+duration;
 unsigned n=slots(e,at);if(n>e->peak_slots)e->peak_slots=(uint8_t)n;return 0;
}
static unsigned harmony(ensemble *e){
 static const uint8_t major[7]={0,2,4,5,7,9,11},minor[7]={0,2,3,5,7,8,10};
 const uint8_t *scale=e->config.minor?minor:major;int best=-1;unsigned chosen=0;
 for(unsigned d=0;d<7;d++){
  int score=0;for(unsigned j=0;j<3;j++)score+=e->histogram[(e->config.root+scale[(d+j*2)%7])%12]*3;
  if(d==e->chord)score+=3;
  if(d==0)score+=2;
  if(score>best){best=score;chosen=d;}
 }
 for(unsigned i=0;i<12;i++)e->histogram[i]=(uint16_t)(e->histogram[i]*3u/4u);
 return chosen;
}
static int tick(ensemble *e,uint64_t at){
 static const uint8_t major[7]={0,2,4,5,7,9,11},minor[7]={0,2,3,5,7,8,10};
 const uint8_t *scale=e->config.minor?minor:major;unsigned step=e->tick_index%16,level=e->config.level;
 uint64_t quarter=((uint64_t)INSTRUMENT_AUDIO_HZ*60u)/e->config.bpm;int r;
 if(step==0){
  e->chord=(uint8_t)harmony(e);
  for(unsigned j=0;j<(level==2?4u:3u);j++){
   unsigned degree=e->chord+j*2,note=48+e->config.root+scale[degree%7]+12*(degree/7);
   r=on(e,j,note,e->config.style==1?0:2,level==2?82:100,at,UINT64_MAX);if(r)return r;
  }
  if(level==2)for(unsigned j=0;j<2;j++){
   unsigned degree=e->chord+j*4,note=60+e->config.root+scale[degree%7]+12*(degree/7);
   r=on(e,5+j,note,0,58,at,UINT64_MAX);if(r)return r;
  }
 }
 unsigned root=36+e->config.root+scale[e->chord];
 if(level&&step%4==0){r=on(e,4,root,level==2?1:0,112,at,quarter*3/5);if(r)return r;}
 if(level){
  if(step==0||step==8||(e->config.style==2&&step==6)){r=on(e,8,0,5,170,at,AUDIO_MS(1));if(r)return r;}
  if(step==4||step==12){r=on(e,9,1,5,145,at,AUDIO_MS(1));if(r)return r;}
  if(step%2==0){r=on(e,10,2,5,step%4?70:95,at,AUDIO_MS(1));if(r)return r;}
 }
 if(level==2&&!e->human_held&&at>e->last_input+quarter&&(step==10||step==14)){
  unsigned note=60+e->config.root+scale[(e->chord+(step==10?2:4))%7];
  if(e->last_note>=72)note+=12;
  r=on(e,7,note,3,95,at,quarter/3);if(r)return r;
 }
 e->tick_index++;e->next_tick=e->anchor+(uint64_t)e->tick_index*((uint64_t)INSTRUMENT_AUDIO_HZ*15u)/e->config.bpm;return 0;
}
int ens_generate(ensemble *e,uint64_t now,uint64_t through){
 if(!e->running)return 0;
 for(unsigned steps=0;steps<64;steps++){
  uint64_t at=e->next_tick;for(unsigned i=0;i<ENS_VOICES;i++)if(e->voice[i].on&&e->voice[i].off<at)at=e->voice[i].off;
  if(at>through)return 0;
  if(at+AUDIO_MS(1)<now||e->write-e->read>ENS_CAPACITY-24){e->reason=1;e->running=0;return S9_E_TIMEOUT;}
  for(unsigned i=0;i<ENS_VOICES;i++)if(e->voice[i].on&&e->voice[i].off==at){int r=off(e,i,at);if(r){e->reason=2;e->running=0;return r;}}
  if(e->next_tick==at){int r=tick(e,at);if(r){e->reason=2;e->running=0;return r;}}
 }
 e->reason=3;e->running=0;return S9_E_BUSY;
}
int ens_peek(const ensemble *e,uint32_t cursor,uint64_t through,ens_event *v){
 if(cursor<e->read||cursor>e->write)return S9_E_STATE;
 if(cursor==e->write||e->queue[cursor%ENS_CAPACITY].due>through)return 0;
 *v=e->queue[cursor%ENS_CAPACITY];return 1;
}
void ens_commit(ensemble *e,uint32_t cursor){if(cursor>=e->read&&cursor<=e->write)e->read=cursor;}
void ens_pause(ensemble *e){e->running=0;}
void ens_retired(ensemble *e){e->running=e->pending=0;e->read=e->write;memset(e->voice,0,sizeof e->voice);}
void ens_info(const ensemble *e,uint8_t p[64]){
 memset(p,0,64);p[0]=1;p[1]=e->running?2:e->pending?1:e->reason?3:0;p[2]=e->config.level;p[3]=e->config.root;
 p[4]=e->config.minor;p[5]=e->config.style;s9_put16(p+6,e->config.bpm);s9_put64(p+8,e->anchor);
 s9_put32(p+16,e->generated);s9_put32(p+20,e->observed);s9_put32(p+24,e->skipped);s9_put32(p+28,e->write-e->read);
 p[32]=e->human_held;p[33]=e->peak_slots;p[34]=16;p[35]=e->reason;p[36]=e->chord;p[37]=e->last_note;
 s9_put16(p+38,e->revision);s9_put32(p+40,sizeof *e);s9_put32(p+44,AUDIO_MS(80));s9_put32(p+48,AUDIO_MS(50));
}
