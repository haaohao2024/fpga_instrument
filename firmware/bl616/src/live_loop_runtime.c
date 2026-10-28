#include "audio_timebase.h"
#include "live_loop_runtime.h"
#include "shared_loop.h"
#include "s9_tasks_bus.h"
#include "s9_router.h"
#include "s11_service.h"
#include "score_hal.h"
#ifdef S10_MEDIA_RUNTIME
#include "s10_runtime.h"
#endif
#include <string.h>
#if defined(__riscv)
#define LOOP_WRAM __attribute__((section(".wifi_ram.loop"),aligned(16)))
#else
#define LOOP_WRAM
#endif
static ll_record arena[4096];
static uint8_t phases[4096*3] LOOP_WRAM;
static shared_loop_controller loop LOOP_WRAM;
static uint8_t tx[548],rx[32],last_info[64];static uint64_t last_notice;
static uint8_t ensemble_notice_force;
static volatile uint8_t active_snapshot,load_snapshot,capture_snapshot,shared_pending;static uint8_t force_notice;
volatile ll_runtime_profile ll_runtime_high_water;
static void peak(volatile uint32_t *v,uint64_t t){uint32_t n=t>UINT32_MAX?UINT32_MAX:(uint32_t)t;if(n>*v)*v=n;}
static void sync_load(void){
 taskENTER_CRITICAL();active_snapshot=(uint8_t)sl_active(&loop);
 capture_snapshot=loop.core.recording!=UINT8_MAX||loop.user_opcode==SL_BEGIN||ensemble_state.running||ensemble_state.pending;
 load_snapshot=capture_snapshot||(loop.core.running&&loop.core.used)||loop.control_action;
 taskEXIT_CRITICAL();
}
int ll_runtime_shared_enter(unsigned kind){
 if(kind!=LL_SHARED_RECORD&&kind!=LL_SHARED_MEDIA)return S9_E_FORMAT;
 taskENTER_CRITICAL();int r=load_snapshot||s11_service_ram_owned()?S9_E_BUSY:0;if(!r)shared_pending|=(uint8_t)kind;taskEXIT_CRITICAL();return r;
}
void ll_runtime_shared_leave(unsigned kind){taskENTER_CRITICAL();shared_pending&=(uint8_t)~kind;taskEXIT_CRITICAL();}
void ll_runtime_init(void){
 ss_init();sl_init(&loop,arena,phases,4096,0x8200,(ll_budget){.max_events_same_sample=12,.max_rows_per_second=LL_QUALIFIED_ROWS_PER_SECOND,.max_length_samples=LL_QUALIFIED_MAX_LENGTH_SAMPLES,.window_samples=AUDIO_MS(1),.max_window_events=LL_QUALIFIED_WINDOW_EVENTS,.max_window_groups=LL_QUALIFIED_WINDOW_GROUPS,.max_window_rows=LL_QUALIFIED_WINDOW_ROWS,.wire_window_samples=LL_QUALIFIED_WIRE_WINDOW_SAMPLES,.max_wire_window_rows=LL_QUALIFIED_WIRE_WINDOW_ROWS});
 active_snapshot=load_snapshot=capture_snapshot=shared_pending=force_notice=0;last_notice=0;memset(last_info,0,64);memset((void*)&ll_runtime_high_water,0,sizeof ll_runtime_high_water);
}
int ll_runtime_request(const s9_message *m){
 if(!m||m->channel!=1)return S9_E_FORMAT;
 if(m->opcode>=ENS_START&&m->opcode<=ENS_STATUS){
  ens_config config={0};int r=0;
  if(m->opcode==ENS_START&&(m->length!=8||(r=ens_decode_config(m->payload,&config))))return r?r:S9_E_LENGTH;
  taskENTER_CRITICAL();int busy=0;
  if(m->opcode==ENS_START){
   busy=shared_pending||(s11_service_active()&&!s11_service_ram_owned());
   if(s11_service_ram_owned()){
    const s11_service_stats *s=s11_service_statistics();busy|=s->error||s->command==S11_REC_STOP||s->wire_state==S11_DRAINING||s->wire_state==S11_CLOSED||s->wire_state==S11_INCOMPLETE||s->wire_state==S11_ERROR;
   }
#ifdef S10_MEDIA_RUNTIME
   busy|=s10_runtime_media_active();
#endif
  }
  r=busy?S9_E_BUSY:sl_ensemble_request(&loop,m->opcode,m->sequence,&config);
  if(!r&&m->opcode==ENS_START&&!s11_service_ram_owned()){
   uint64_t id=s11_service_next_id();r=id?s11_service_ram_start(id):S9_E_RANGE;
   if(!r)sl_capture_begin(&loop,id);else{loop.user_sequence=loop.user_opcode=0;ensemble_state.pending=0;}
  }
  if(!r)ensemble_notice_force=1;
  if(!r&&m->opcode==ENS_START)active_snapshot=load_snapshot=capture_snapshot=1;
  taskEXIT_CRITICAL();return r;
 }
 if(m->opcode<SL_BEGIN||m->opcode>SL_PLAY)return S9_E_FORMAT;
 if(m->opcode==SL_BEGIN&&(!LL_QUALIFIED_ROWS_PER_SECOND||!LL_QUALIFIED_WINDOW_EVENTS||!LL_QUALIFIED_WINDOW_GROUPS||!LL_QUALIFIED_WINDOW_ROWS||!LL_QUALIFIED_WIRE_WINDOW_ROWS))return S9_E_BUSY;
 taskENTER_CRITICAL();int busy=0;
 if(m->opcode==SL_BEGIN||m->opcode==SL_PLAY){busy=shared_pending||(s11_service_active()&&!s11_service_ram_owned());
#ifdef S10_MEDIA_RUNTIME
  busy|=s10_runtime_media_active();
#endif
 }
 if(m->opcode==SL_BEGIN&&s11_service_ram_owned()){
  const s11_service_stats *s=s11_service_statistics();busy|=s->error||s->command==S11_REC_STOP||s->wire_state==S11_DRAINING||s->wire_state==S11_CLOSED||s->wire_state==S11_INCOMPLETE||s->wire_state==S11_ERROR;
 }
 int r=busy?S9_E_BUSY:sl_request(&loop,m->opcode,m->sequence,m->length?m->payload[0]:0);
 if(!r&&m->opcode==SL_BEGIN&&!s11_service_ram_owned()){
  uint64_t id=s11_service_next_id();r=id?s11_service_ram_start(id):S9_E_RANGE;
  if(!r)sl_capture_begin(&loop,id);else{loop.user_sequence=0;loop.user_opcode=0;}
 }
 if(!r&&(m->opcode==SL_BEGIN||m->opcode==SL_PLAY)){active_snapshot=load_snapshot=1;capture_snapshot=m->opcode==SL_BEGIN;}
 taskEXIT_CRITICAL();return r;
}
static void capture_step(void){
 if(!s11_service_ram_owned())return;
 (void)ll_capture_batch_begin(&loop.core);
 uint8_t cell[32];for(unsigned i=0;i<128&&s11_service_ram_pop(cell,1);i++)sl_capture_cell(&loop,cell);
 (void)sl_capture_flush(&loop);
 const s11_service_stats *s=s11_service_statistics();
 if(s->error)sl_capture_fault(&loop,LL_E_CAPACITY);
 if((s->error||(!loop.core.running&&loop.core.recording==UINT8_MAX&&loop.user_opcode!=SL_BEGIN&&!ensemble_state.running&&!ensemble_state.pending))&&s->command!=S11_REC_STOP)s11_service_stop(s->recording_id);
 if((s->error||(!loop.core.running&&loop.core.recording==UINT8_MAX&&loop.user_opcode!=SL_BEGIN&&!ensemble_state.running&&!ensemble_state.pending))&&!s11_service_ram_release()){loop.ram_started=0;loop.evr.started=0;}
}
int ll_runtime_step(void){
 uint64_t began=hal_time_us();capture_step();int n=sl_next(&loop,began,tx),exchanged=0;
 uint64_t prepare=hal_time_us()-began,response=0;peak(&ll_runtime_high_water.max_prepare_us,prepare);
 if(n>0){
  began=hal_time_us();int r=s9_tasks_bus_raw_exchange(tx,(unsigned)n,rx);peak(&ll_runtime_high_water.max_exchange_us,hal_time_us()-began);
  if(!r){exchanged=1;began=hal_time_us();r=sl_response(&loop,began,rx,s11_service_ram_caught_up());response=hal_time_us()-began;if(r<0)sl_transport_failed(&loop);}
  else sl_transport_failed(&loop);
 }
 began=hal_time_us();sync_load();response+=hal_time_us()-began;peak(&ll_runtime_high_water.max_response_us,response);
 if(prepare>16000||response>16000)ll_runtime_high_water.software_over_budget++;
 return exchanged;
}
void ll_runtime_disconnect(void){sl_disconnect(&loop);sync_load();}
int ll_runtime_result(uint8_t p[36]){
 if(!loop.result_valid)return 0;
 s9_make_result(p,1,loop.result_sequence,loop.result_phase,loop.result_error);if(loop.result_phase==4)s9_put32(p+32,1);loop.result_valid=0;force_notice=1;return 1;
}
int ll_runtime_notice(uint8_t p[64]){
 if(!loop.notice_dirty)return 0;
 uint64_t now=hal_time_us();if(now-last_notice<100000&&!force_notice)return 0;
 sl_info(&loop,p);loop.notice_dirty=0;if(!memcmp(p,last_info,64))return 0;memcpy(last_info,p,64);last_notice=now;force_notice=0;return 1;
}
int ll_runtime_active(void){return active_snapshot;}

int ll_runtime_ensemble_notice(uint8_t p[64]){
 static uint64_t previous;static uint8_t last[64];uint64_t now=hal_time_us();
 if(now-previous<250000&&!ensemble_notice_force)return 0;
 previous=now;ens_info(&ensemble_state,p);if(!memcmp(p,last,64)&&!ensemble_notice_force)return 0;
 ensemble_notice_force=0;memcpy(last,p,64);return 1;
}
