#include "audio_timebase.h"
#include "shared_loop.h"
#include "s9_protocol.h"
#include <string.h>
#ifdef ENSEMBLE_CAPTURE_DIAG
#include "link_diag.h"
#define CAP_DIAG(k,a,b,c) link_diag_event(k,(uint32_t)(a),(uint32_t)(b),(uint32_t)(c))
#else
#define CAP_DIAG(k,a,b,c) ((void)0)
#endif

#define CONTROL_LEAD AUDIO_MS(80)
#define PREFETCH AUDIO_MS(50)
#define BARRIER_LEAD AUDIO_MS(10)
enum {ACT_NONE=0,ACT_UNDO=1,ACT_STOP=2,ACT_CLEAR=3,ACT_FAIL_NEW=4,ACT_SCORE_PAUSE=5,ACT_SCORE_STOP=6,ACT_AI_STOP=7};
static int mapped(int error){return error==LL_E_CAPACITY||error==LL_E_ADMISSION||error==LL_E_ID?S9_E_RANGE:error==LL_E_TIME?S9_E_TIMEOUT:error==LL_E_ARGUMENT?S9_E_RANGE:S9_E_STATE;}
static void result(shared_loop_controller *m,unsigned phase,int error){
 if(m->user_sequence){m->result_valid=1;m->result_sequence=m->user_sequence;m->result_phase=(uint8_t)phase;m->result_error=error;}
 m->user_sequence=0;m->user_opcode=0;m->user_actioned=0;m->notice_dirty=1;
}
static uint64_t boundary(const shared_loop_controller *m){uint64_t d=m->now+BARRIER_LEAD;return d<=m->last_queued?m->last_queued+1:d;}
static void control(shared_loop_controller *m,unsigned action,unsigned sources,int all,uint16_t revision,int guide){
 m->control_action=(uint8_t)action;m->control_sources=(uint8_t)sources;m->control_all=(uint8_t)all;m->control_revision=revision;m->control_guide=(uint8_t)guide;m->control_target=boundary(m);m->control_barrier=0;m->control_packed=m->control_applied=0;
}
static int source1_active(const shared_loop_controller *m){return m->score.running&&!m->score.paused;}
static void budget_for_mix(shared_loop_controller *m){
 m->core.budget=m->base_budget;
 if(!source1_active(m))return;
 const ss_profile *p=&shared_score_stream.profile;ll_budget *b=&m->core.budget;
 b->max_window_events-=p->events48;b->max_events_same_sample=b->max_window_events;b->max_window_groups-=p->groups48;b->max_window_rows-=p->rows48;b->max_wire_window_rows-=p->rows960;b->max_rows_per_second-=p->rows4800*10u;
}
static int combination(shared_loop_controller *m,int add_score){
 if(!m->core.used||!m->core.length)return 0;
 m->scout=m->core;m->scout.budget=m->base_budget;ll_analysis a;int r=ll_analyze(&m->scout,&a);if(r)return S9_E_RANGE;
 if(!add_score&&!source1_active(m))return 0;
 const ss_profile *p=&shared_score_stream.profile;ll_budget *b=&m->base_budget;
 return a.peak_window_events+p->events48>b->max_window_events||a.peak_window_groups+p->groups48>b->max_window_groups||
  a.peak_window_rows+p->rows48>b->max_window_rows||a.peak_wire_window_rows+p->rows960>b->max_wire_window_rows||
  a.rows_per_second+p->rows4800*10u>b->max_rows_per_second?S9_E_BUSY:0;
}
void sl_init(shared_loop_controller *m,ll_record *arena,uint32_t *phase,uint16_t capacity,uint32_t seed,ll_budget budget){
 ens_init(&ensemble_state);memset(m,0,sizeof *m);m->base_budget=budget;ll_init(&m->core,arena,capacity,budget);(void)ll_attach_phase_cache(&m->core,phase,capacity);m->epoch_cursor=seed?seed:1;m->page_sequence=0;m->notice_dirty=1;m->control_layer=UINT8_MAX;
}
int sl_request(shared_loop_controller *m,unsigned op,uint32_t sequence,unsigned timbre){
 if(!m||!sequence||op<SL_BEGIN||op>SL_PLAY)return S9_E_FORMAT;
 if(m->result_valid||m->user_sequence)return S9_E_BUSY;
 if(op==SL_STATUS){m->user_sequence=sequence;result(m,3,0);return 0;}
 if(m->control_action||m->fault_closing)return S9_E_BUSY;
 if((op==SL_BEGIN||op==SL_PLAY)&&(ensemble_state.running||ensemble_state.pending||ensemble_state.write!=ensemble_state.read))return S9_E_BUSY;
 if(op==SL_BEGIN){
  if(timbre>5||m->core.recording!=UINT8_MAX)return S9_E_STATE;
  unsigned n=0;while(n<4&&m->core.layer[n].state!=LL_EMPTY&&m->core.layer[n].state!=LL_FAILED)n++;
  if(n==4)return S9_E_RANGE;
  if(m->core.length&&m->core.length<=CONTROL_LEAD+PREFETCH)return S9_E_RANGE;
  if(source1_active(m)){const ss_profile *p=&shared_score_stream.profile;ll_budget *b=&m->base_budget;
   if(p->events48>=b->max_window_events||p->groups48>=b->max_window_groups||p->rows48>=b->max_window_rows||p->rows960>=b->max_wire_window_rows||p->rows4800*10u>=b->max_rows_per_second)return S9_E_BUSY;
  }
 }
 if(op==SL_END&&(m->core.recording==UINT8_MAX||m->core.layer[m->core.recording].state!=LL_CAPTURE))return S9_E_STATE;
 if(op==SL_END&&!m->core.length&&m->now+CONTROL_LEAD-m->core.layer[m->core.recording].start<CONTROL_LEAD+PREFETCH+AUDIO_MS(2))return S9_E_RANGE;
 if(op==SL_PLAY&&(!m->core.length||m->core.running||m->core.recording!=UINT8_MAX))return S9_E_STATE;
 if(op==SL_UNDO&&!m->core.used)return S9_E_STATE;
 m->user_sequence=sequence;m->user_opcode=(uint8_t)op;m->user_timbre=(uint8_t)timbre;m->user_actioned=0;m->last_error=0;m->reason=0;m->notice_dirty=1;return 0;
}
int sl_ensemble_request(shared_loop_controller *m,unsigned op,uint32_t sequence,const ens_config *config){
 if(!sequence||op<ENS_START||op>ENS_STATUS)return S9_E_FORMAT;
 if(m->user_sequence||m->result_valid||m->control_action)return S9_E_BUSY;
 if(op==ENS_STATUS){m->user_sequence=sequence;result(m,3,0);return 0;}
 if(op==ENS_STOP&&!ensemble_state.revision)return S9_E_STATE;
 if(op==ENS_START){
  if(!config||ensemble_state.running||ensemble_state.pending||ensemble_state.write!=ensemble_state.read||m->core.used||m->core.recording!=UINT8_MAX||m->score.running||m->score.paused||shared_score_stream.command)return S9_E_BUSY;
  if(!m->core.next_revision)return S9_E_SEQUENCE;
  m->ai_config=*config;ensemble_state.pending=1;
 }
 m->user_sequence=sequence;m->user_opcode=(uint8_t)op;m->user_actioned=0;m->last_error=0;m->notice_dirty=1;return 0;
}
void sl_capture_begin(shared_loop_controller *m,uint64_t id){loop_evr_init(&m->evr,id);m->ram_started=1;m->capture_error_latched=0;}
static void fail_new(shared_loop_controller *m,int error){
 uint16_t rev=m->core.last_failed_revision;
 if(m->core.recording!=UINT8_MAX){uint16_t r=0;(void)ll_disconnect(&m->core,&r);if(r)rev=r;}
 m->prefix_active=m->prefix_saved=m->close_wait=0;m->planned_end=0;m->last_error=mapped(error);m->reason=error==LL_E_CAPACITY?1:2;m->notice_dirty=1;
 if(rev&&!m->control_action)control(m,ACT_FAIL_NEW,2,0,rev,0);
 else if(rev&&!((m->control_sources&2)&&(m->control_all||m->control_revision==rev)))m->pending_failed_revision=rev;
 else if(m->user_sequence)result(m,7,m->last_error);
}
void sl_capture_fault(shared_loop_controller *m,int error){
 if(m->capture_error_latched)return;
 m->capture_error_latched=1;
 CAP_DIAG(15,error,m->evr.next_sequence,m->now);
 if(ensemble_state.running||ensemble_state.pending){
  ens_pause(&ensemble_state);ensemble_state.reason=4;m->last_error=mapped(error);
  if(m->opened&&ensemble_state.revision&&!m->control_action)control(m,ACT_AI_STOP,2,0,ensemble_state.revision,0);
  else{ensemble_state.pending=0;if(m->user_opcode==ENS_START)result(m,7,m->last_error);}
 }
 if(m->core.recording!=UINT8_MAX||m->user_opcode==SL_BEGIN)fail_new(m,error);
}
int sl_capture_flush(shared_loop_controller *m){
 int r=ll_capture_batch_end(&m->core);if(r<0)fail_new(m,r);return r;
}
static void shift_score(ss_cursor *s,uint64_t shift){if(s->running||s->paused){s->origin+=shift;if(s->resume_at)s->resume_at+=shift;}}
static void align_clock(shared_loop_controller *m,uint64_t aligned){
 uint64_t shift=aligned-m->now;m->now=aligned;m->last_queued+=shift;m->page_last_target+=shift;
 shift_score(&m->score,shift);shift_score(&m->compose_score,shift);shift_score(&m->scout_score,shift);
 if(m->score_starting)m->start_target+=shift;
 if(m->control_action)m->control_target+=shift;
 if(m->end_barrier)m->end_target+=shift;
 for(unsigned i=0;i<m->row_count;i++)if(m->row[i].is_score)m->row[i].score.target+=shift;
 m->clock_seeded=1;
}
int sl_capture_cell(shared_loop_controller *m,const uint8_t p[32]){
 int r=loop_evr_feed(&m->evr,&m->core,p);
 if(r>=0)ens_capture(&ensemble_state,p);
 if(r<0){
  if(!m->capture_error_latched){
   CAP_DIAG(16,r,s9_get32(p),s9_get32(p+4));
   CAP_DIAG(17,s9_get32(p+16),s9_get32(p+20),s9_get32(p+28));
  }
  sl_capture_fault(m,r);return r;}
 if(p[0]==1){
  uint64_t seed=s9_get64(p+8);m->clock_seed=seed;
  if(m->clock_valid){uint32_t delta=(uint32_t)m->now-(uint32_t)seed;
   if(delta<0x80000000u){uint64_t aligned=seed+delta;
    if(aligned>=m->now)align_clock(m,aligned);
   }
  }
 }
 return 0;
}
static int project(shared_loop_controller *m){
 m->projection=m->core;
 if(!m->prefix_active||m->core.recording==UINT8_MAX)return 0;
 ll_layer *l=&m->core.layer[m->core.recording],*p=&m->projection.layer[m->core.recording];if(!l->count)return 0;
 if(!m->projection.length){m->projection.length=m->planned_end-l->start;m->projection.anchor=m->planned_end;}
 p->state=LL_TAIL;p->play_start=m->planned_end;p->phase_base=(uint32_t)(p->play_start%m->projection.length);p->end=m->planned_end;p->scheduled=1;m->projection.running=1;
 if(m->prefix_saved){p->cursor=m->prefix.cursor;p->cycle=m->prefix.cycle;p->next_due=m->prefix.next_due;p->last_due=m->prefix.last_due;p->emitted=m->prefix.emitted;}
 else{p->cursor=p->first;p->cycle=0;p->next_due=p->play_start+m->projection.records[p->first].offset;p->emitted=0;}
 if(m->planned_end>m->now+PREFETCH)return 0;
 if(m->analyzed_revision==l->revision&&m->analyzed_end==m->planned_end){if(m->projection.capture_watermark>m->analyzed_watermark)m->projection.capture_watermark=m->analyzed_watermark;return 0;}
 ll_analysis a;int r=ll_analyze(&m->projection,&a);if(r)return r;
 m->analyzed_revision=l->revision;m->analyzed_end=m->planned_end;m->analyzed_watermark=m->core.capture_watermark;return 0;
}
static void cutoff(shared_loop_controller *m,ll_core *c,ss_cursor *s){
 if(!m->control_action)return;
 for(unsigned i=0;i<4;i++)if(c->layer[i].next_due>m->control_target&&
  ((m->control_sources&2)&&(m->control_all||c->layer[i].revision==m->control_revision)))c->layer[i].scheduled=0;
 if((m->control_sources&1)&&m->control_packed)s->running=0;
}
static int next_music(shared_loop_controller *m,ll_core *c,ss_cursor *s,uint32_t *ai,uint64_t through,sl_item *out){
 cutoff(m,c,s);ll_delivery d;ss_event e;ens_event v;
 int a=ll_peek(c,through,&d),b=ss_peek(s,through,&e),z=ens_peek(&ensemble_state,*ai,through,&v);
 if(a<0)return a;
 if(b<0)return b;
 if(z<0)return z;
 if(z&&m->control_action&&(m->control_sources&2)&&v.due>m->control_target)z=0;
 if(b&&e.kind==4){
  uint64_t fence=m->end_target?m->end_target:e.target;
  if(z&&v.due<=fence&&(a!=0||v.due<d.due)){
   *out=(sl_item){.item={v.word,v.token},.loop={.due=v.due,.token=v.token,.word=v.word,.timbre=v.timbre},.is_score=2};return 1;
  }
  if(a==0&&d.due<=fence){*out=(sl_item){.item={d.word,d.token},.loop=d,.is_score=0};return 1;}
  return 2;
 }
 if(b&&(a!=0||e.target<=d.due)&&(!z||e.target<=v.due)){*out=(sl_item){.item=e.item,.score=e,.is_score=1};return 1;}
 if(z&&(a!=0||v.due<d.due)){*out=(sl_item){.item={v.word,v.token},.loop={.due=v.due,.token=v.token,.word=v.word,.timbre=v.timbre},.is_score=2};return 1;}
 if(a==0){*out=(sl_item){.item={d.word,d.token},.loop=d,.is_score=0};return 1;}
 return 0;
}
static uint64_t item_time(const sl_item *x){return x->is_score==1?x->score.target:x->loop.due;}
static void take(ll_core *c,ss_cursor *s,uint32_t *ai,const sl_item *x){if(x->is_score==2)(*ai)++;else if(x->is_score==1)ss_take(s,&x->score);else if(c->layer[x->loop.layer].revision==x->loop.revision)ll_pop(c,&x->loop);}
static int build_row(shared_loop_controller *m,uint64_t through){
 m->scout=m->compose;m->scout_score=m->compose_score;m->scout_ai=m->compose_ai;sl_item x;int r=next_music(m,&m->scout,&m->scout_score,&m->scout_ai,through,&x);if(r!=1)return r;
 uint64_t t=item_time(&x);unsigned owner=x.is_score==1?1:3,timbre=x.is_score==1?0:x.loop.timbre,teach=x.is_score==1?(m->scout_score.mode&1):0;
 m->row_count=0;
 do{
  m->row[m->row_count++]=x;take(&m->scout,&m->scout_score,&m->scout_ai,&x);
  r=next_music(m,&m->scout,&m->scout_score,&m->scout_ai,through,&x);
  if(r<0)return r;
 }while(m->row_count<9&&r==1&&item_time(&x)==t&&(x.is_score==1?1u:3u)==owner&&(x.is_score==1?0u:x.loop.timbre)==timbre);
 m->row_last=(uint8_t)(r!=1||item_time(&x)!=t);m->row_index=m->row_head_sent=0;
 raw_head(m->row_head,(uint32_t)t,owner,timbre,teach,m->row_count,m->row_last);return 1;
}
static void apply_control_queued(shared_loop_controller *m){
 if(!m->control_packed||m->control_applied)return;
 m->control_applied=1;
 switch(m->control_action){
 case ACT_UNDO:{uint16_t r=0;(void)ll_undo(&m->core,&r);break;}
 case ACT_STOP:case ACT_CLEAR:ll_stop(&m->core);m->core.budget=m->base_budget;m->prefix_active=m->close_wait=0;break;
 case ACT_SCORE_PAUSE:m->score.running=0;m->score.paused=1;m->score.paused_elapsed=m->control_target-m->score.origin;break;
 case ACT_SCORE_STOP:m->score.running=m->score.paused=0;m->score.held=0;break;
 default:break;
 }
}
static void accept_page(shared_loop_controller *m){
 for(unsigned i=0;i<4;i++){
  ll_layer *l=&m->core.layer[i],*p=&m->compose.layer[i];
  if(l->revision!=p->revision)continue;
  if(m->prefix_active&&m->core.recording==i){m->prefix=*p;m->prefix_saved=1;}
  else{int r=ll_commit_cursor(&m->core,i,p);if(r<0)fail_new(m,r);}
 }
 ll_cursor_watch(&m->core,0);
 m->score=m->compose_score;ss_commit(&m->score);ens_commit(&ensemble_state,m->compose_ai);m->last_queued=m->page_last_target;m->page_pending=m->page_confirm=0;m->page_sequence++;
 apply_control_queued(m);
}
static int pack(shared_loop_controller *m){
 int r=project(m);if(r<0){fail_new(m,r);m->projection=m->core;}
 m->compose=m->projection;m->compose_score=m->score;m->compose_ai=ensemble_state.read;m->page_last_target=m->last_queued;raw_page_begin(m->page,m->page_sequence);
 uint64_t through=m->now+PREFETCH;
 for(unsigned step=0;step<64&&s9_get16(m->page+4)<30;step++){
  if(m->row_count){
   uint8_t cell[16];if(!m->row_head_sent){raw_page_cell(m->page,m->row_head);m->row_head_sent=1;m->group_open=1;m->page_last_target=item_time(&m->row[0]);}
   else{sl_item *x=&m->row[m->row_index];raw_event(cell,&x->item,m->row_last&&m->row_index+1==m->row_count);raw_page_cell(m->page,cell);take(&m->compose,&m->compose_score,&m->compose_ai,x);m->row_index++;
    if(m->row_index==m->row_count){if(m->row_last)m->group_open=0;m->row_count=0;}
   }
   continue;
  }
  sl_item x;int next=next_music(m,&m->compose,&m->compose_score,&m->compose_ai,through,&x);if(next<0)return next;
  ss_event end;int has_end=ss_peek(&m->compose_score,through,&end)>0&&end.kind==4;
  uint64_t first=next==1?item_time(&x):UINT64_MAX;
  if(m->control_action&&!m->control_packed&&m->control_target==first){m->control_target++;m->effective=m->control_target;continue;}
  if(has_end&&!m->score_end_packed){
   if(!m->end_target)m->end_target=end.target;
   if(m->end_target==first||(m->control_action&&m->end_target==m->control_target)){m->end_target++;continue;}
  }
  int user_bar=m->control_action&&!m->control_packed&&m->control_target<=through&&m->control_target<first;
  int end_bar=has_end&&!m->score_end_packed&&m->end_target<=through&&m->end_target<first;
  if(user_bar||end_bar){
   if(end_bar&&(!user_bar||m->end_target<m->control_target)){
    uint32_t id=++m->barrier_counter;if(!id)return S9_E_SEQUENCE;
    if(raw_page_barrier(m->page,(uint32_t)m->end_target,id,1,0,0,1))return S9_E_FORMAT;
    m->end_barrier=id;m->score_end_packed=1;ss_take(&m->compose_score,&end);m->page_last_target=m->end_target;
   }else{
    uint32_t id=++m->barrier_counter;if(!id)return S9_E_SEQUENCE;
    if(raw_page_barrier(m->page,(uint32_t)m->control_target,id,m->control_sources,m->control_all,m->control_revision,m->control_guide))return S9_E_FORMAT;
    m->control_barrier=id;m->control_packed=1;m->page_last_target=m->control_target;cutoff(m,&m->compose,&m->compose_score);
   }
   continue;
  }
  if(next!=1)break;
  r=build_row(m,through);if(r!=1)return r<0?r:S9_E_FORMAT;
 }
 if(!s9_get16(m->page+4)){m->score.page=m->compose_score.page;m->score.index=m->compose_score.index;ss_commit(&m->score);return 0;}
 raw_page_finish(m->page);m->page_pending=1;m->page_confirm=0;ll_cursor_watch(&m->core,1);return 1;
}
static void wire_fault(shared_loop_controller *m,int error){
 ens_pause(&ensemble_state);ll_stop(&m->core);m->score.running=m->score.paused=0;m->prefix_active=m->close_wait=0;m->last_error=error;m->reason=7;m->fault_closing=1;m->notice_dirty=1;
 shared_score_stream.file_error=error;shared_score_stream.state=0;
 if(shared_score_stream.command)ss_complete(error);
 if(m->user_sequence)result(m,7,error);
}
static int score_admission(shared_loop_controller *m,int resume){
 if(ensemble_state.running||ensemble_state.pending||ensemble_state.write!=ensemble_state.read)return S9_E_BUSY;
 if(m->core.recording!=UINT8_MAX)return S9_E_BUSY;
 if(!m->core.running)return 0;
 int r=combination(m,1);if(r||!resume||!m->score.held)return r;
 unsigned held=0;for(unsigned k=0;k<32;k++)held+=(m->score.held>>k)&1u;
 m->scout=m->core;m->scout.budget=m->base_budget;ll_analysis a;r=ll_analyze(&m->scout,&a);if(r)return S9_E_BUSY;
 const ss_profile *p=&shared_score_stream.profile;const ll_budget *b=&m->base_budget;unsigned rows=(held+8u)/9u;
 return a.peak_window_events+p->events48+held>b->max_window_events||a.peak_window_groups+p->groups48+1u>b->max_window_groups||
  a.peak_window_rows+p->rows48+rows>b->max_window_rows||a.peak_wire_window_rows+p->rows960+rows>b->max_wire_window_rows||
  a.rows_per_second+(p->rows4800+rows)*10u>b->max_rows_per_second?S9_E_BUSY:0;
}
static void commands(shared_loop_controller *m){
 if(!m->opened||!m->clock_valid)return;
 if(m->page_pending||m->row_count||m->group_open)return;
 if(!m->control_action&&m->pending_failed_revision){
  uint16_t revision=m->pending_failed_revision;m->pending_failed_revision=0;control(m,ACT_FAIL_NEW,2,0,revision,0);
 }
 if(!m->control_action&&shared_score_stream.file_error&&m->score.running)control(m,ACT_SCORE_STOP,1,0,0,1);
 unsigned sc=shared_score_stream.command;
 if(sc&&!m->control_action){
  if(sc==1){
   if(m->score_starting)return;
   if(!__atomic_load_n(&shared_score_stream.ready,__ATOMIC_ACQUIRE))return;
   int r=score_admission(m,0);if(r){ss_complete(r);return;}
   uint64_t counter=m->score.token_counter;memset(&m->score,0,sizeof m->score);m->end_target=m->end_barrier=m->score_end_packed=0;m->score.token_counter=counter;m->score.origin=m->now+CONTROL_LEAD;m->start_target=m->score.origin;m->score.running=1;m->score.mode=shared_score_stream.mode;m->score_starting=1;shared_score_stream.state=1;
   if(m->core.running)budget_for_mix(m);
  }else if(sc==3||sc==6){
   if(!m->score.running&&!m->score.paused&&!m->score.held){shared_score_stream.state=0;ss_complete(0);}
   else control(m,ACT_SCORE_STOP,1,0,0,1);
  }else if(sc==4){
   if(!m->score.running||m->score.paused)ss_complete(S9_E_STATE);else control(m,ACT_SCORE_PAUSE,1,0,0,0);
  }else if(sc==5){
   if(m->score_starting)return;
   if(!m->score.paused){ss_complete(S9_E_STATE);return;}
   int r=score_admission(m,1);if(r){ss_complete(r);return;}
   uint64_t at=m->now+CONTROL_LEAD;m->start_target=at;m->score.origin=at-m->score.paused_elapsed;m->score.resume_at=at;m->score.resume_mask=m->score.held;m->score.running=1;m->score.paused=0;m->score_starting=1;shared_score_stream.state=1;
   if(m->core.running)budget_for_mix(m);
  }
 }
 if(m->control_action||!m->user_opcode||m->user_actioned)return;
 switch(m->user_opcode){
 case ENS_START:{
  if(!m->ram_started||!m->evr.started||!m->clock_seeded)return;
  uint16_t revision=m->core.next_revision++;
  int r=ens_begin(&ensemble_state,&m->ai_config,m->now+CONTROL_LEAD,revision);
  if(r){ensemble_state.pending=0;result(m,7,r);break;}
  m->effective=ensemble_state.anchor;m->user_actioned=1;break;
 }
 case ENS_STOP:
  ens_pause(&ensemble_state);control(m,ACT_AI_STOP,2,0,ensemble_state.revision,0);m->effective=m->control_target;m->user_actioned=1;break;

 case SL_BEGIN:{
  if(!m->ram_started||!m->evr.started||!m->clock_seeded)return;
  budget_for_mix(m);m->core.last_failed_revision=0;uint8_t n;int r=ll_begin(&m->core,m->now+CONTROL_LEAD,m->user_timbre,&n);if(r){result(m,7,mapped(r));break;}
  m->effective=m->core.layer[n].start;m->planned_end=m->core.length?m->effective+m->core.length:0;
  m->prefix_active=m->planned_end!=0;m->prefix_saved=0;m->analyzed_revision=0;m->capture_error_latched=0;loop_evr_seal(&m->evr,m->planned_end?m->planned_end:UINT64_MAX);m->user_actioned=1;break;
 }
 case SL_END:
  if(!m->core.length){
   m->planned_end=m->now+CONTROL_LEAD;int r=ll_prepare_phase_cache(&m->core,m->planned_end-m->core.layer[m->core.recording].start);
   if(r){fail_new(m,r);break;}m->prefix_active=1;m->prefix_saved=0;loop_evr_seal(&m->evr,m->planned_end);
  }
  m->effective=m->planned_end;m->user_actioned=1;break;
 case SL_PLAY:{
  int r=combination(m,0);if(r){result(m,7,r);break;}
  budget_for_mix(m);m->effective=m->now+CONTROL_LEAD;r=ll_resume(&m->core,m->effective);if(r)result(m,7,mapped(r));else m->user_actioned=1;break;
 }
 case SL_UNDO:{
  unsigned n=4;while(n&&(m->core.layer[n-1].state==LL_EMPTY||m->core.layer[n-1].state==LL_FAILED))n--;
  if(!n){result(m,7,S9_E_STATE);break;}m->control_layer=(uint8_t)(n-1);control(m,ACT_UNDO,2,0,m->core.layer[n-1].revision,0);m->effective=m->control_target;m->user_actioned=1;break;
 }
 case SL_STOP:case SL_CLEAR:
  control(m,m->user_opcode==SL_CLEAR?ACT_CLEAR:ACT_STOP,2,1,0,0);m->effective=m->control_target;m->user_actioned=1;break;
 default:break;
 }
}
static void close_capture(shared_loop_controller *m){
 if(!m->prefix_active||!m->planned_end||m->core.recording==UINT8_MAX||m->core.capture_watermark<m->planned_end||m->core.layer[m->core.recording].state!=LL_CAPTURE)return;
 unsigned n=m->core.recording;int r=ll_close(&m->core,m->planned_end,m->planned_end);
 if(r){fail_new(m,r);return;}
 if(!m->page_pending&&m->prefix_saved&&m->prefix.revision==m->core.layer[n].revision){
  r=ll_refresh_cursor(&m->core,n,&m->prefix);if(r){fail_new(m,r);return;}
  r=ll_commit_cursor(&m->core,n,&m->prefix);if(r){fail_new(m,r);return;}
 }
 if(m->page_pending&&m->compose.layer[n].revision==m->core.layer[n].revision){
  r=ll_refresh_cursor(&m->core,n,&m->compose.layer[n]);if(r){fail_new(m,r);return;}
 }
 m->prefix_active=m->prefix_saved=0;m->notice_dirty=1;
 if(m->user_opcode==SL_END)result(m,4,0);
}
int sl_next(shared_loop_controller *m,uint64_t now_us,uint8_t out[548]){
 if(m->wire_kind)return 0;
 close_capture(m);commands(m);
 if(m->clock_valid&&ensemble_state.running){
  int r=ens_generate(&ensemble_state,m->now,m->now+CONTROL_LEAD);
  if(r&&!m->control_action){m->last_error=r;control(m,ACT_AI_STOP,2,0,ensemble_state.revision,0);}
 }

 if(!m->fault_closing&&!m->opened&&!m->opening){
  if(!m->user_opcode&&!m->core.running&&!shared_score_stream.command&&!m->score.running)return 0;
  if(m->epoch_cursor==UINT32_MAX){if(m->user_sequence)result(m,7,S9_E_SEQUENCE);return 0;}
  m->epoch=++m->epoch_cursor;m->opening=1;m->last_keep_us=0;m->page_sequence=m->barrier_counter=0;
 }
 if(m->fault_closing){m->wire_kind=RAW_CLOSE;return raw_request(out,RAW_CLOSE,m->epoch,0,0);}
 if(m->opening){unsigned cmd=!m->last_keep_us||(now_us>=m->last_keep_us&&now_us-m->last_keep_us>=20000)?RAW_OPEN:RAW_POLL;m->last_poll_us=now_us;if(cmd==RAW_OPEN)m->last_keep_us=now_us?now_us:1;m->wire_kind=(uint8_t)cmd;return raw_request(out,cmd,m->epoch,0,0);}
 if(!m->opened)return 0;
 if(m->page_pending){
  unsigned cmd=m->page_confirm?RAW_POLL:RAW_PAGE;m->page_confirm=1;m->wire_kind=(uint8_t)cmd;m->last_poll_us=now_us;
  return raw_request(out,cmd,m->epoch,cmd==RAW_PAGE?m->page_sequence:0,cmd==RAW_PAGE?m->page:0);
 }
 if(m->status.flags&RAW_CREDIT){int r=pack(m);if(r<0){wire_fault(m,S9_E_TIMEOUT);return 0;}if(r>0){m->wire_kind=RAW_PAGE;m->page_confirm=1;m->last_poll_us=now_us;return raw_request(out,RAW_PAGE,m->epoch,m->page_sequence,m->page);}}
 unsigned fast=m->user_sequence||m->control_action||m->score_starting||m->core.recording!=UINT8_MAX||m->score.running||ensemble_state.running;
 if(now_us-m->last_poll_us<(fast?2000u:20000u))return 0;
 m->last_poll_us=now_us;m->wire_kind=RAW_POLL;return raw_request(out,RAW_POLL,m->epoch,0,0);
}
int sl_response(shared_loop_controller *m,uint64_t now_us,const uint8_t bytes[32],int empty){
 (void)now_us;unsigned request=m->wire_kind;m->wire_kind=0;raw_status s;int r=raw_decode(bytes,&s);if(r)return r;
 if(s.epoch!=m->epoch)return 0;
 if(m->fault_closing){if(s.state==0&&!(s.flags&RAW_IS_OPEN)){m->fault_closing=m->opened=m->opening=0;m->page_pending=m->row_count=m->group_open=0;m->control_action=0;ens_retired(&ensemble_state);}return 0;}
 if(m->opening){
  if(!(s.flags&RAW_IS_OPEN)||s.state==0)return 0;
  if(s.accepted!=UINT32_MAX||s.barrier){if(s.epoch==UINT32_MAX)return S9_E_SEQUENCE;m->epoch_cursor=m->epoch=s.epoch+1;m->last_keep_us=0;return 0;}
  m->opening=0;m->opened=1;m->page_sequence=0;m->last_queued=0;
 }
 if(m->clock_valid){uint64_t extended;if(ll_extend_sample(m->now,s.now,&extended))return S9_E_STALE;m->now=extended;}
 else{m->now=s.now;m->clock_valid=1;}
 if(m->ram_started&&m->evr.started&&!m->clock_seeded){uint32_t delta=s.now-(uint32_t)m->clock_seed;if(delta<0x80000000u){uint64_t aligned=m->clock_seed+delta;if(aligned<m->now)return S9_E_STALE;align_clock(m,aligned);}}
 m->status=s;
 if(s.error||s.state==4||!(s.flags&RAW_IS_OPEN)||s.state==0){wire_fault(m,S9_E_TIMEOUT);return 0;}
 if(m->ram_started&&m->clock_seeded&&(s.flags&RAW_CAUGHT_UP)&&empty&&m->now)ll_watermark(&m->core,m->now-1);
 if(m->page_pending){
  if(s.accepted==m->page_sequence)accept_page(m);
  else if(request==RAW_POLL&&(s.flags&RAW_CREDIT))m->page_confirm=0;
 }
 if(m->control_barrier&&s.barrier>=m->control_barrier){
  unsigned action=m->control_action;m->effective=m->control_target;
  if(action==ACT_AI_STOP){ens_retired(&ensemble_state);if(m->user_sequence&&m->last_error)result(m,7,m->last_error);}
  if(action==ACT_CLEAR)ll_clear(&m->core);
  if(action==ACT_SCORE_PAUSE){m->core.budget=m->base_budget;shared_score_stream.state=3;if(shared_score_stream.command)ss_complete(0);}
  else if(action==ACT_SCORE_STOP){m->core.budget=m->base_budget;m->end_target=m->end_barrier=m->score_end_packed=0;shared_score_stream.state=0;if(shared_score_stream.command)ss_complete(shared_score_stream.file_error);}
  else if(action==ACT_FAIL_NEW){if(m->user_sequence)result(m,7,m->last_error);}
  else if(m->user_sequence)result(m,4,0);
  m->control_action=m->control_packed=m->control_applied=0;m->control_barrier=0;m->notice_dirty=1;
 }
 if(m->score_starting&&m->now>=m->start_target){m->score_starting=0;shared_score_stream.state=2;if(shared_score_stream.command)ss_complete(0);}
 if(m->end_barrier&&s.barrier>=m->end_barrier){m->core.budget=m->base_budget;shared_score_stream.state=0;shared_score_stream.reload=(m->score.mode&2)!=0;m->score.held=0;m->score_end_packed=0;m->end_barrier=0;m->end_target=0;}
 if((m->user_opcode==SL_BEGIN||m->user_opcode==SL_PLAY||m->user_opcode==ENS_START)&&m->user_actioned&&m->now>=m->effective)result(m,4,0);
 close_capture(m);return 0;
}
void sl_transport_failed(shared_loop_controller *m){m->wire_kind=0;}
void sl_disconnect(shared_loop_controller *m){
 if(m->user_opcode==ENS_START&&!m->user_actioned)ensemble_state.pending=0;
 m->user_sequence=0;m->user_opcode=0;m->result_valid=0;
 if(m->core.recording!=UINT8_MAX)fail_new(m,LL_E_STATE);
}
int sl_active(const shared_loop_controller *m){return m->opened||m->opening||m->fault_closing||m->user_sequence||m->core.running||m->score.running||m->score.paused||shared_score_stream.command;}
void sl_info(const shared_loop_controller *m,uint8_t p[64]){
 memset(p,0,64);p[0]=INSTRUMENT_AUDIO_HZ==128000u?3:INSTRUMENT_AUDIO_HZ==96000u?2:1;p[3]=UINT8_MAX;uint32_t flags=m->core.running?1u:0u;
 for(unsigned i=0;i<4;i++){const ll_layer *l=&m->core.layer[i];if(l->state!=LL_EMPTY&&l->state!=LL_FAILED)p[2]++;s9_put16(p+40+i*2,(uint16_t)l->count);p[48+i]=l->timbre;p[52+i]=l->state;}
 if(m->core.recording!=UINT8_MAX){const ll_layer *l=&m->core.layer[m->core.recording];p[3]=m->core.recording;p[1]=l->state==LL_TAIL?4:m->core.length?3:1;if(l->state==LL_TAIL)flags|=6;}
 else p[1]=m->core.running?2:m->core.used?5:0;
 if(m->control_action){p[1]=6;flags|=32;}
 if(m->last_error&&m->reason==7&&!m->core.running&&!m->control_action)p[1]=7;
 if(m->reason==1)flags|=8;
 if(m->reason==2||m->reason==3)flags|=16;
 s9_put32(p+4,flags);s9_put32(p+8,(uint32_t)m->last_error);s9_put32(p+12,m->user_sequence?m->user_sequence:m->result_sequence);s9_put64(p+16,m->effective);s9_put64(p+24,m->core.length);s9_put32(p+32,m->core.used);s9_put32(p+36,m->core.capacity);
 p[56]=4;p[57]=24;p[58]=32;p[59]=m->reason;s9_put32(p+60,m->core.budget.max_length_samples);
}
