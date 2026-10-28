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
static const uint8_t major_scale[7]={0,2,4,5,7,9,11};
static const uint8_t minor_scale[7]={0,2,3,5,7,8,10};
static unsigned pc_at(const ensemble *e,unsigned d){
 const uint8_t *s=e->config.minor?minor_scale:major_scale;
 return (e->config.root+s[d%7])%12;
}
static void add_evidence(ensemble *e,unsigned pc,unsigned amount){
 unsigned sum=e->histogram[pc]+amount;e->histogram[pc]=(uint16_t)(sum>8191?8191:sum);
}
/* Integrate only elapsed, observed time, never the 80 ms scheduling horizon.
   The exponential window is about two bars; no future NoteOff is consulted. */
static void observe_until(ensemble *e,uint64_t now){
#ifdef ENS_LEGACY_HARMONY
 (void)e;(void)now;
#else
 if(!e->running||now<=e->evidence_at)return;
 uint64_t quarter=((uint64_t)INSTRUMENT_AUDIO_HZ*60u)/e->config.bpm;
 if(now-e->evidence_at>quarter*8){memset(e->histogram,0,sizeof e->histogram);e->evidence_at=now-quarter*8;e->decay_at=e->evidence_at+quarter;}
 while(e->evidence_at<now){
  uint64_t end=now<e->decay_at?now:e->decay_at;
  unsigned ms=(unsigned)((end-e->evidence_at)/AUDIO_MS(1));
  for(unsigned i=0;i<ENS_NATIVE_SLOTS;i++){
   const ens_native *v=&e->native[i];
   if(v->gate&&(v->source==0||v->source==2))add_evidence(e,v->note%12,ms*(1+v->velocity/96)*v->weight);
  }
  e->evidence_at=end;
  if(end==e->decay_at){
   for(unsigned i=0;i<12;i++)e->histogram[i]=(uint16_t)(e->histogram[i]*3u/4u);
   e->decay_at+=quarter;
  }
 }
#endif
}
int ens_begin(ensemble *e,const ens_config *c,uint64_t anchor,uint16_t rev){
 if(!e||!c||!rev||e->running||e->write!=e->read)return S9_E_BUSY;
 if(c->level>2||c->style>2||c->root>11||c->minor>1||c->bpm<50||c->bpm>180)return S9_E_RANGE;
 /* Native slots survive restart, but musical history and response plans do not. */
 memset(e->histogram,0,sizeof e->histogram);memset(e->motif,0,sizeof e->motif);
 e->motif_count=e->motif_head=e->response_count=e->response_index=0;
 e->chord=e->proposed_chord=e->dense=e->variant=e->voicing_valid=0;
 e->skipped_budget=e->skipped_tail=e->skipped_optional=e->observed=0;
 e->evidence_at=e->analysis_now=e->last_input=e->last_release=anchor;
 e->decay_at=anchor+((uint64_t)INSTRUMENT_AUDIO_HZ*60u)/c->bpm;e->response_at=e->response_cooldown=0;
 e->config=*c;e->anchor=e->next_tick=anchor;e->tick_index=e->token_counter=e->generated=e->skipped=e->peak_slots=0;
 e->last_generated=anchor;e->revision=rev;e->running=1;e->pending=e->reason=0;
 for(unsigned i=0;i<ENS_VOICES;i++){memset(&e->voice[i],0,sizeof e->voice[i]);e->voice[i].off=UINT64_MAX;}
 return 0;
}
void ens_capture(ensemble *e,const uint8_t p[32]){
 if(!e||!p)return;
 unsigned type=p[0],source=p[2];uint64_t payload=s9_get64(p+24),tag=s9_get64(p+16),frame=s9_get64(p+8);
 if(type==1){observe_until(e,frame);memset(e->native,0,sizeof e->native);e->human_held=0;e->response_count=0;e->last_release=frame;return;}
 if(type!=4&&type!=5&&type!=6&&type!=8)return;
 unsigned slot=(unsigned)(payload>>59)|((p[1]&64u)?32u:0u);
 if(slot>=ENS_NATIVE_SLOTS)return;
 ens_native *v=&e->native[slot];
 if(type!=4&&type!=8&&(v->tag!=tag||v->source!=source||v->key!=p[3]))return;
 observe_until(e,frame);
 if(type==4||type==8){
  v->tag=tag;v->source=(uint8_t)source;v->key=p[3];v->note=(uint8_t)(payload>>16)&127;v->gate=(uint8_t)(type==4||!(p[1]&16));
  v->velocity=(uint8_t)(payload>>23);v->weight=1;
  if(e->running&&frame>=e->anchor){
   unsigned phase=(unsigned)(((frame-e->anchor)*e->config.bpm/((uint64_t)INSTRUMENT_AUDIO_HZ*15u))%16);
   v->weight=(uint8_t)(phase%4==0?2:1);
  }
 }else if(type==5)v->gate=0;else v->note=(uint8_t)(payload>>16)&127;
 e->human_held=0;for(unsigned i=0;i<ENS_NATIVE_SLOTS;i++)if((e->native[i].source==0||e->native[i].source==2)&&e->native[i].gate)e->human_held++;
 if((source==0||source==2)&&(type==4||type==6)){
  unsigned note=(unsigned)(payload>>16)&127,vel=(unsigned)(payload>>23)&255;
  if(type==4){
#ifdef ENS_LEGACY_HARMONY
   add_evidence(e,note%12,1+vel/32);
#else
   add_evidence(e,note%12,(24+vel/8)*v->weight);
#endif
   e->observed++;
   /* Simultaneous chord attacks contribute all notes to harmony, but only
      the highest note to the response motif. Distinct identities stay intact. */
   unsigned last=(e->motif_head+7)%8;
   if(e->motif_count&&e->motif[last].at==frame){
    if(note>e->motif[last].note)e->motif[last]=(ens_motif){frame,(uint8_t)note,(uint8_t)vel};
   }else{
    e->motif[e->motif_head]=(ens_motif){frame,(uint8_t)note,(uint8_t)vel};
    e->motif_head=(e->motif_head+1)%8;if(e->motif_count<8)e->motif_count++;
   }
   e->response_count=0;
  }
  e->last_note=type==4?e->motif[(e->motif_head+7)%8].note:(uint8_t)note;e->last_input=frame;
 }
 if((source==0||source==2)&&type==5&&!e->human_held)e->last_release=frame;
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
 if(v->tail[0]>at&&v->tail[1]>at)return S9_E_STATE;
 int r=append(e,at,p,2,0,0,v->token,v->timbre);if(r)return r;
 uint64_t end=v->timbre==5?v->off+AUDIO_MS(300):at+AUDIO_MS(150);
 if(v->tail[0]<=at)v->tail[0]=end;else if(v->tail[1]<=at)v->tail[1]=end;else return S9_E_STATE;
 v->on=0;v->off=UINT64_MAX;return 0;
}
static int on(ensemble *e,unsigned p,unsigned note,unsigned timbre,unsigned vel,uint64_t at,uint64_t duration){
 ens_voice *v=&e->voice[p];if(v->on&&v->note==note&&v->timbre==timbre&&duration==UINT64_MAX)return 0;
 // Reserve sixteen contexts for accompaniment, including release tails.
 // The remaining32 of the48 native slots are reserved for live human input.
 // Optional future attacks may be thinned; already admitted OFFs are retained.
 if(slots(e,at)>=ENS_CONTEXT_BUDGET||e->human_held>ENS_NATIVE_SLOTS-ENS_CONTEXT_BUDGET){e->skipped++;e->skipped_budget++;return 0;}
 /* Admission reserves room for this note's eventual release. Never append
    an OFF and only then discover that its release cannot be accounted for. */
 if((v->tail[0]>at&&v->tail[1]>at)||(v->on&&(v->tail[0]>at||v->tail[1]>at))){e->skipped++;e->skipped_tail++;return 0;}
 if(e->write-e->read>ENS_CAPACITY-2)return S9_E_BUSY;
 if(v->on){int r=off(e,p,at);if(r)return r;}
 if(e->token_counter==UINT32_MAX)return S9_E_SEQUENCE;
 uint64_t token=((uint64_t)e->revision<<48)|++e->token_counter;
 int r=append(e,at,p,1,note,vel,token,timbre);if(r)return r;
 v->on=1;v->note=(uint8_t)note;v->timbre=(uint8_t)timbre;v->velocity=(uint8_t)vel;v->token=token;
 v->off=duration==UINT64_MAX?UINT64_MAX:at+duration;
 unsigned n=slots(e,at);if(n>e->peak_slots)e->peak_slots=(uint8_t)n;return 0;
}
/* Diatonic scoring is deliberately separate from event arrangement. */
void ens_harmony_scores(const ensemble *e,int16_t scores[7]){
 static const int8_t connection[7][7]={
  {3,2,0,5,4,3,-3},{1,2,0,1,8,0,-2},{1,0,2,4,1,6,-2},
  {5,3,0,2,7,1,-2},{9,0,0,2,2,5,-2},{3,5,1,5,3,2,-2},{8,0,1,0,3,0,0}};
 unsigned total=0;for(unsigned p=0;p<12;p++)total+=e->histogram[p];
 for(unsigned d=0;d<7;d++){
  int fit=0;unsigned chord_mask=0;
  for(unsigned j=0;j<3;j++)chord_mask|=1u<<pc_at(e,d+j*2);
  for(unsigned p=0;p<12;p++){
   int weight=(chord_mask&(1u<<p))?100:0;
   if(!weight&&((chord_mask&(1u<<((p+1)%12)))||(chord_mask&(1u<<((p+11)%12)))))weight=-20;
   fit+=(int)e->histogram[p]*weight;
  }
  int score=(total?fit/(int)total:0)+connection[e->chord][d];
  if(d==6)score-=7; /* diminished triad requires stronger evidence */
  if(d==0&&!e->human_held&&e->motif_count&&e->last_note%12==e->config.root)score+=4;
  scores[d]=(int16_t)score;
 }
}
static unsigned harmony(ensemble *e){
#ifdef ENS_LEGACY_HARMONY
 int best=-1;unsigned chosen=0;
 for(unsigned d=0;d<7;d++){
  int score=0;for(unsigned j=0;j<3;j++)score+=e->histogram[pc_at(e,d+j*2)]*3;
  if(d==e->chord)score+=3;
  if(d==0)score+=2;
  if(score>best){best=score;chosen=d;}
 }
 for(unsigned i=0;i<12;i++)e->histogram[i]=(uint16_t)(e->histogram[i]*3u/4u);
 return chosen;
#else
 ens_harmony_scores(e,e->harmony_scores);
 unsigned chosen=e->chord,total=0;
 for(unsigned p=0;p<12;p++)total+=e->histogram[p];
 uint64_t activity=e->last_release>e->last_input?e->last_release:e->last_input;
 if(total<100||(!e->human_held&&e->analysis_now>activity+((uint64_t)INSTRUMENT_AUDIO_HZ*120u)/e->config.bpm))return chosen;
 for(unsigned d=0;d<7;d++)if(e->harmony_scores[d]>e->harmony_scores[chosen])chosen=d;
 unsigned threshold=e->tick_index%16?10:6;
 return e->harmony_scores[chosen]>=e->harmony_scores[e->chord]+(int)threshold?chosen:e->chord;
#endif
}

#ifdef ENS_LEGACY_ARRANGEMENT
/* Original R83 arrangement, retained only in the offline harmony ablation. */
static int tick(ensemble *e,uint64_t at){
 const uint8_t *scale=e->config.minor?minor_scale:major_scale;
 unsigned step=e->tick_index%16,level=e->config.level;uint64_t quarter=((uint64_t)INSTRUMENT_AUDIO_HZ*60u)/e->config.bpm;int r;
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
  unsigned note=60+e->config.root+scale[(e->chord+(step==10?2:4))%7];if(e->last_note>=72)note+=12;
  r=on(e,7,note,3,95,at,quarter/3);if(r)return r;
 }
 e->tick_index++;e->next_tick=e->anchor+(uint64_t)e->tick_index*((uint64_t)INSTRUMENT_AUDIO_HZ*15u)/e->config.bpm;return 0;
}
#else
static unsigned distance(unsigned a,unsigned b){return a>b?a-b:b-a;}
static unsigned nearest_pc(unsigned target,unsigned pc,unsigned low,unsigned high){
 unsigned chosen=low,best=255;
 for(unsigned n=low;n<=high;n++)if(n%12==pc&&distance(n,target)<best){chosen=n;best=distance(n,target);}
 return chosen;
}
/* Search only the three close triad inversions in a fixed accompaniment range.
   Ordered voices keep common tones and avoid crossings. No heap/search tree. */
static void voice_chord(ensemble *e){
 unsigned best=65535;uint8_t result[3]={48,52,55};
 unsigned upper=e->last_note<60?60:67;
 for(unsigned inv=0;inv<3;inv++)for(unsigned base=43;base<=58;base++){
  if(base%12!=pc_at(e,e->chord+inv*2))continue;
  uint8_t notes[3];notes[0]=(uint8_t)base;
  for(unsigned j=1;j<3;j++){
   unsigned n=notes[j-1]+1,pc=pc_at(e,e->chord+((inv+j)%3)*2);
   while(n%12!=pc)n++;
   notes[j]=(uint8_t)n;
  }
  if(notes[2]>upper)continue;
  unsigned cost=0;
  for(unsigned j=0;j<3;j++)cost+=distance(notes[j],e->voicing_valid?e->voicing[j]:50+j*4);
  if(cost<best){best=cost;memcpy(result,notes,3);}
 }
 memcpy(e->voicing,result,3);e->voicing_valid=1;
}
static int optional_on(ensemble *e,unsigned p,unsigned note,unsigned timbre,unsigned vel,uint64_t at,uint64_t duration){
 /* Leave four contexts for the bass/drum skeleton and imminent releases. */
 if(slots(e,at)>=12||e->dense){e->skipped++;e->skipped_optional++;return 0;}
 return on(e,p,note,timbre,vel,at,duration);
}
static unsigned snap_note(const ensemble *e,int target,int chord_only){
 if(target<60)target=60;
 if(target>84)target=84;
 unsigned best=255,chosen=60;
 for(unsigned d=0;d<(chord_only?3u:7u);d++){
  unsigned n=nearest_pc((unsigned)target,pc_at(e,chord_only?e->chord+d*2:d),60,84),cost=distance(n,(unsigned)target);
  if(cost<best){best=cost;chosen=n;}
 }
 return chosen;
}
static void prepare_response(ensemble *e,uint64_t at,uint64_t quarter){
 unsigned count=e->motif_count<4?e->motif_count:4,start=(e->motif_head+8-count)%8;
 unsigned last=(e->motif_head+7)%8;
 /* Only quote one recent phrase, never an onset from a previous long rest. */
 while(count>1&&e->motif[last].at-e->motif[start].at>quarter*4){start=(start+1)%8;count--;}
 if(count<2)return;
 int end=(int)snap_note(e,e->motif[last].note,1),shift=end-e->motif[last].note;
 for(unsigned i=0;i<count;i++){
  ens_motif m=e->motif[(start+i)%8];
  e->response_note[i]=(uint8_t)snap_note(e,m.note+shift,i==count-1);
  e->response_vel[i]=(uint8_t)(48+m.velocity/6);
  unsigned gap=i+1<count?(unsigned)((e->motif[(start+i+1)%8].at-m.at+quarter/8)/(quarter/4)):2;
  e->response_gap[i]=(uint8_t)(gap<2?2:gap>4?4:gap);
 }
 e->response_count=(uint8_t)count;e->response_index=0;e->response_at=at;e->response_cooldown=at+quarter*8;
}
static int tick(ensemble *e,uint64_t at){
 /* style IDs remain 0=pop, 1=calm, 2=groove (existing phone contract). */
 static const uint16_t kicks[3][2]={{0x0101,0x0141},{0x0001,0x0101},{0x0141,0x0501}};
 static const uint16_t bass[3][2]={{0x0111,0x0501},{0x0101,0x0001},{0x0541,0x1141}};
 static const uint16_t comps[3][2]={{0x0101,0x0411},{0x0001,0x0101},{0x0441,0x1041}};
 unsigned step=e->tick_index%16,bar=e->tick_index/16,level=e->config.level,style=e->config.style;
 uint64_t quarter=((uint64_t)INSTRUMENT_AUDIO_HZ*60u)/e->config.bpm;int r;unsigned old=e->chord;
 unsigned recent=0;
 for(unsigned i=0;i<e->motif_count;i++)if(e->analysis_now>=e->motif[i].at&&e->analysis_now-e->motif[i].at<quarter*2)recent++;
 e->dense=recent>=5;
 uint64_t activity=e->last_release>e->last_input?e->last_release:e->last_input;
 int idle=!e->human_held&&e->analysis_now>=activity&&e->analysis_now-activity>=quarter*8;
 int quiet=!e->human_held&&e->analysis_now>=e->last_release&&e->analysis_now-e->last_release>=quarter/2;
#ifdef ENS_LEGACY_HARMONY
 if(step==0)e->proposed_chord=(uint8_t)harmony(e);
#else
 if(step%4==0)e->proposed_chord=(uint8_t)harmony(e);
#endif
 if(step%8==0)e->chord=e->proposed_chord;
 if(step==0)e->variant=(uint8_t)((bar/2)%2); /* bounded two-bar variants */
 if(!e->voicing_valid||old!=e->chord)voice_chord(e);
 /* Retirement precedes attacks. Dense playing removes the third pad voice. */
 if(step%8==0&&(idle||e->dense))for(unsigned j=idle?1:2;j<3;j++){r=off(e,j,at);if(r)return r;}
 unsigned root=nearest_pc(e->last_note<60?31:38,pc_at(e,e->chord),28,47);
 unsigned bit=1u<<step,variant=e->variant;
 if(level&&(bass[style][variant]&bit)&&(!idle||step==0)){
  unsigned note=root;
  if(step!=0&&step!=8&&!e->dense){
   note=nearest_pc(root+7,pc_at(e,e->chord+4),28,52);
   if(step==12&&variant)note=root+12;
  }
  r=on(e,4,note,0,style==1?86:108,at,quarter*(style==2?2:3)/5);if(r)return r;
 }
 if(level&&!idle){
  if(kicks[style][variant]&bit){r=on(e,8,0,5,step==0?160:132,at,AUDIO_MS(1));if(r)return r;}
  if((style!=1&&(step==4||step==12))||(style==1&&variant&&step==12)){
   r=on(e,9,1,5,style==1?76:128,at,AUDIO_MS(1));if(r)return r;
  }
  if(step%(style==1?4:2)==0){r=on(e,10,2,5,style==1?44:step%4==0?78:52,at,AUDIO_MS(1));if(r)return r;}
  /* One short fill variant, only at a phrase gap, never over dense input. */
  if(level==2&&quiet&&!e->dense&&bar%4==3&&(step==14||step==15)){
   r=optional_on(e,11,step==14?4:5,5,style==1?60:88,at,AUDIO_MS(1));if(r)return r;
  }
 }
 unsigned voices=idle?1:e->dense?2:3;
 if(!level){
  if(step%8==0)for(unsigned j=0;j<voices;j++){r=on(e,j,e->voicing[j],style==1?0:2,68,at,UINT64_MAX);if(r)return r;}
 }else if((comps[style][variant]&bit)||old!=e->chord){
  if(!idle||step==0)for(unsigned j=0;j<voices;j++){
   uint64_t duration=style==1?quarter*3:quarter*(style==2?2:3)/5;
   r=on(e,j,e->voicing[j],style==1?0:style==2?1:2,style==1?62:68,at,duration);if(r)return r;
  }
 }
 /* Quoting a motif occupies the same musical space as the arpeggio. */
 if(level==2&&!idle&&!e->dense&&quiet&&!e->response_count&&e->motif_count>=2&&at>=e->response_cooldown&&
    e->analysis_now>=e->last_input+quarter&&(step%2==0))prepare_response(e,at,quarter);
 if(e->response_count&&at>=e->response_at){
  unsigned i=e->response_index;
  if(!e->human_held&&!e->dense){
   r=optional_on(e,7,e->response_note[i],3,e->response_vel[i],at,quarter/3);if(r)return r;
  }
  e->response_at=at+quarter*e->response_gap[i]/4;
  if(++e->response_index>=e->response_count)e->response_count=0;
 }else if(level==2&&!idle&&!e->dense&&!e->response_count&&step%4==2&&recent<=3){
  unsigned note=e->voicing[(step/4+variant)%3]+12;
  r=optional_on(e,5,note,style==1?3:1,54,at,quarter/3);if(r)return r;
 }
 e->tick_index++;e->next_tick=e->anchor+(uint64_t)e->tick_index*((uint64_t)INSTRUMENT_AUDIO_HZ*15u)/e->config.bpm;return 0;
}
#endif

int ens_generate(ensemble *e,uint64_t now,uint64_t through){
 if(!e->running)return 0;
 e->analysis_now=now;observe_until(e,now);
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
 p[32]=e->human_held;p[33]=e->peak_slots;p[34]=ENS_CONTEXT_BUDGET;p[35]=e->reason;p[36]=e->chord;p[37]=e->last_note;
 s9_put16(p+38,e->revision);s9_put32(p+40,sizeof *e);s9_put32(p+44,AUDIO_MS(80));s9_put32(p+48,AUDIO_MS(50));
}
