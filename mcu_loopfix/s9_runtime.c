#include "record_observer.h"
#include "bus_fault.h"
#include "sd_proof.h"
#include "record_trace.h"
#include "sd_wait_diag.h"
#include "s11_schedule.h"
/* Three owners: protocol owns session/router, file owns every FatFs call,
 * bus owns every SPI operation. BLE callbacks only touch bounded mailboxes. */
#include "s9_runtime.h"
#include "live_loop_runtime.h"
#include "ensemble.h"
#include "live_loop_wire.h"
#include "s9_protocol.h"
#include "link_diag.h"
#include "sd_spi.h"
#include "s9_router.h"
#include "s9_ble_queue.h"
#include "s9_gatt.h"
#include "s9_storage.h"
#include "s9_player.h"
#include "s9_tasks_bus.h"
#include "score_hal.h"
#include "score_service.h"
#include "s11_service.h"
#include "s11_storage.h"
#include "queue.h"
#include "bluetooth.h"
#include "hci_driver.h"
#include "btble_lib_api.h"
#ifdef S10_MEDIA_RUNTIME
#include "s10_runtime.h"
#endif
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "shell.h"
#include "record_bench.h"
#include "record_hot.h"
#include "record_profile.h"
#include "diag_trace.h"
#include "link_diag.h"
#include "link_startup.h"
volatile int r76_bt_phase,r76_clock_result=9999,r76_gatt_result=9999,r76_adv_result=9999,r76_media_result=9999;
typedef struct {uint32_t generation;uint16_t length;uint8_t bytes[548];} file_command;
typedef struct {uint32_t generation;uint8_t session[16],result[36];} file_result;
typedef struct {uint32_t generation;uint16_t length;uint8_t bytes[548];} record_notice;
static s9_router router;
static s9_ble_queue received;
static s9_player player;
static QueueHandle_t file_commands,file_results,record_notices;
static volatile uint32_t connected_generation,retired_generation;
static volatile int callback_ready,advertise_allowed,stack_ready,file_busy,upload_abort;
static uint32_t connection_counter;
static uint64_t boot_identity;
static uint8_t info[64];
static file_command current_file;
static file_result pending_play;
static int play_waiting;
static uint32_t progress_ms;
static uint32_t info_fx_version,info_map_version;
static uint16_t info_gain_l,info_gain_e;
static uint32_t file_quota_at,file_quota=500000;
static uint8_t record_session[16];static uint32_t record_generation,record_request_sequence,last_record_info_crc;
typedef struct {uint32_t generation,sequence,target;uint8_t session[16],pending;} record_result_pending;
static record_result_pending record_results[2];
/* Phone GATT permits up to 3s for an operation. This peer grace is separate
 * from the FPGA 500ms lease, which the bus task continues to refresh at100ms.
 * A real LE disconnect still invokes immediate session/source cleanup. */
#define PHONE_PEER_GRACE_MS 3000u
static uint32_t now_ms(void){return (uint32_t)(hal_time_us()/1000);}
static uint32_t connected(void){
 uint32_t gen=0;taskENTER_CRITICAL();
 if(advertise_allowed&&connection_counter!=UINT32_MAX){gen=++connection_counter;connected_generation=gen;advertise_allowed=0;callback_ready=0;}
 taskEXIT_CRITICAL();return gen;
}
static void disconnected(uint32_t gen){
 taskENTER_CRITICAL();if(gen==connected_generation){connected_generation=0;retired_generation=gen;callback_ready=0;upload_abort=1;s9_ble_queue_discard(&received,gen);}taskEXIT_CRITICAL();
 if(file_busy)s9_tasks_bus_abort_disk(1);
 if(s11_service_active()&&!s11_service_ram_owned())(void)s11_service_stop(s11_service_statistics()->recording_id);
}
static int receive(uint32_t gen,uint8_t ch,const uint8_t *data,unsigned n){
 int r;taskENTER_CRITICAL();
 r=(!callback_ready||gen!=connected_generation)?S9_E_STATE:s9_ble_queue_push(&received,gen,ch,data,n);
 taskEXIT_CRITICAL();return r;
}
static void snapshot(uint8_t out[64]){taskENTER_CRITICAL();memcpy(out,info,64);taskEXIT_CRITICAL();}
static const s9_gatt_hooks hooks={connected,disconnected,receive,snapshot};
static void bluetooth_ready(int error){
 r76_gatt_result=error?error:s9_gatt_init(&hooks);
 stack_ready=r76_gatt_result?-1:1;
#ifdef S10_MEDIA_RUNTIME
 /* Same successful bt_enable, no second controller/Host initialization.
  * A media setup error does not tear down the existing BLE controls. */
 /* BR/EDR activation is owned by protocol_task after BLE advertising. */
#endif
}
static int storage_cancelled(void *unused){(void)unused;return upload_abort||current_file.generation!=connected_generation;}
static void storage_progress(void *unused,uint32_t bytes,unsigned phase){
 (void)unused;
 if(current_file.bytes[6]!=S9_OP_UPLOAD_COMMIT||(uint32_t)(now_ms()-progress_ms)<1000)return;
 file_result r;r.generation=current_file.generation;memcpy(r.session,current_file.bytes+8,16);
 s9_make_result(r.result,2,s9_get32(current_file.bytes+24),2,0);
 s9_put32(r.result+28,((phase-2)<<25)|bytes); /* Monotonic two-pass checked-byte cursor. */
 if(xQueueSend(file_results,&r,0)==pdTRUE)progress_ms=now_ms();
}
static void file_reply(const file_command *c,unsigned phase,int error,int saved){
 file_result r;r.generation=c->generation;memcpy(r.session,c->bytes+8,16);
 s9_make_result(r.result,c->bytes[5],s9_get32(c->bytes+24),phase,error);
 if(saved)s9_put32(r.result+32,4);
 xQueueSend(file_results,&r,portMAX_DELAY);
}
static int record_notice_send(uint32_t generation,const uint8_t sid[16],uint32_t sequence,unsigned opcode,const uint8_t *payload,unsigned size){
 record_notice n;n.generation=generation;int length=s9_encode(n.bytes,sizeof n.bytes,S9_CH_STATUS,(uint8_t)opcode,sid,sequence,payload,(uint16_t)size);if(length<0)return length;n.length=(uint16_t)length;
 return xQueueSend(record_notices,&n,0)==pdTRUE?0:S9_E_BUSY;
}
volatile unsigned record_bench_stress,record_bench_stage,record_bench_request;
volatile unsigned record_bench_multi;
volatile uint64_t record_bench_id,record_bench_paused_us;
static uint64_t record_bench_requested_id;
static uint32_t record_bench_duration_ms=5000,record_bench_started_ms;
static unsigned record_bench_requested_hz=20000000,record_bench_mode=2,record_bench_quantum=8192,record_bench_lease_ms=6,record_bench_policy=3,record_bench_wait_diag=1;
RECORD_HOT void record_bench_bus_pause(void){}
static int record_bench_command(int argc,char **argv){
 if(argc<3||argc>9){printf("recbench id MHz [sec mode KiB ms policy(0|3) diag(0|1)]\r\n");return -1;}
 uint64_t id=strtoull(argv[1],0,10);
 unsigned mhz=(unsigned)strtoul(argv[2],0,10),seconds=argc>=4?(unsigned)strtoul(argv[3],0,10):5;
 unsigned mode=argc>=5?(unsigned)strtoul(argv[4],0,10):2u,kib=argc>=6?(unsigned)strtoul(argv[5],0,10):8u;
 unsigned lease_ms=argc>=7?(unsigned)strtoul(argv[6],0,10):6u;
 unsigned policy=argc>=8?(unsigned)strtoul(argv[7],0,10):3u,diag=argc>=9?(unsigned)strtoul(argv[8],0,10):1u;
 if((lease_ms!=2&&lease_ms!=3&&lease_ms!=4&&lease_ms!=6&&lease_ms!=8)||!id||(mhz!=20&&mhz!=40)||!seconds||seconds>120||mode>2||(kib!=2&&kib!=8)||(policy!=0&&policy!=3)||diag>1)return -1;
 taskENTER_CRITICAL();int busy=record_bench_request||record_bench_stage==1||record_bench_stage==2||record_bench_stage==4;
 if(!busy){record_bench_requested_id=id;record_bench_requested_hz=mhz*1000000u;record_bench_duration_ms=seconds*1000u;record_bench_mode=mode;record_bench_quantum=kib*1024u;record_bench_lease_ms=lease_ms;record_bench_policy=policy;record_bench_wait_diag=diag;record_bench_request=1;}
 taskEXIT_CRITICAL();printf("REC_BENCH requested=%u\r\n",!busy);return busy?-1:0;
}
SHELL_CMD_EXPORT_ALIAS(record_bench_command,recbench,SD20/40 comparison);
static int busfault_command(int argc,char **argv){(void)argc;(void)argv;bus_fault_report();return 0;}
SHELL_CMD_EXPORT_ALIAS(busfault_command,busfault,read-only frozen bus fault);
unsigned long cpu_stat_us(void){return (unsigned long)hal_time_us();}
/* Read-only: CPU share of every task since the previous cpustat call. */
static int cpu_stat_command(int argc,char **argv){
 (void)argc;(void)argv;
 static TaskStatus_t tasks[20];static struct {TaskHandle_t handle;uint32_t used;} last[20];static uint32_t last_total;
 uint32_t total=0;UBaseType_t n=uxTaskGetSystemState(tasks,20,&total);
 uint32_t span=total-last_total;last_total=total;if(!span)span=1;
 printf("CPUSTAT span_us=%lu tasks=%u\r\n",(unsigned long)span,(unsigned)n);
 for(UBaseType_t i=0;i<n;i++){
  uint32_t previous=0;for(unsigned k=0;k<20;k++)if(last[k].handle==tasks[i].xHandle){previous=last[k].used;break;}
  uint32_t used=(uint32_t)tasks[i].ulRunTimeCounter-previous;
  printf("CPUSTAT %s prio=%lu permille=%lu\r\n",tasks[i].pcTaskName,(unsigned long)tasks[i].uxCurrentPriority,(unsigned long)((uint64_t)used*1000u/span));
 }
 memset(last,0,sizeof last);for(UBaseType_t i=0;i<n;i++){last[i].handle=tasks[i].xHandle;last[i].used=(uint32_t)tasks[i].ulRunTimeCounter;}
 return 0;
}
SHELL_CMD_EXPORT_ALIAS(cpu_stat_command,cpustat,read-only per-task CPU share);
/* Diagnostic: busy cycles per loop section, read and cleared by the 2 s status line. */
volatile uint32_t prof_cycles[12];
static inline uint32_t prof_now(void){uint32_t c;__asm__ volatile("rdcycle %0":"=r"(c));return c;}
#define PROF(i) do{uint32_t _n=prof_now();prof_cycles[i]+=_n-prof_mark;prof_mark=_n;}while(0)
static void record_bench_step(void){
 if(record_bench_request){
  record_bench_request=0;int r=S9_E_BUSY;
  if(!s11_service_active()&&!s9_storage_statistics()->active&&!ll_runtime_active()&&!player.active&&!player.pending&&!s10_runtime_media_active()){
   record_bench_id=record_bench_requested_id;uint64_t next=s11_service_next_id();if(record_bench_id<next)record_bench_id=next;
   sd_clear_first_failure();order_trace_config(record_bench_mode?1:2);sd_wait_config(record_bench_wait_diag);
   if(sd_lease_config(record_bench_lease_ms*1000u)||s11_service_set_file_quantum(record_bench_quantum)||sd_resume_config(16)||sd_data_config(record_bench_mode==2)||sd_proof_config(record_bench_requested_hz,1,record_bench_mode==0)){record_bench_stage=3;printf("REC_BENCH rate_unavailable\r\n");return;}
   record_bench_multi=record_bench_policy;r=s10_runtime_record_start(record_bench_id,3);
  }
  if(r){record_bench_multi=0;record_bench_stage=3;printf("REC_BENCH refused=%d\r\n",r);}
  else{record_bench_stage=1;record_bench_started_ms=now_ms();record_bench_paused_us=0;record_bench_stress=0;printf("REC_BENCH started hz=%lu mode=%u quantum=%u lease_ms=%u policy=%u diag=%u\r\n",(unsigned long)record_bench_requested_hz,record_bench_mode,record_bench_quantum,record_bench_lease_ms,record_bench_policy,record_bench_wait_diag);}
 }
 if(record_bench_stage==1&&((uint32_t)(now_ms()-record_bench_started_ms)>=record_bench_duration_ms||s11_service_statistics()->error)){
  record_observer_phase(OBS_FILE,OBS_STOP);(void)s11_service_stop(record_bench_id);record_bench_stage=2;
 }
 const s11_storage_stats *st=s11_storage_statistics();
 if(record_bench_stage==2&&!s11_service_active()&&st->state!=S11_STORE_VERIFY_PENDING){
  order_trace_dump();sd_speed_report();sd_proof_report();sd_wait_report();sd_wait_config(0);const sd_first_failure *f=sd_get_first_failure();
  printf("SD_FIRST cmd=%lu r1=%lu phase=%lu sector=%lu index=%lu response=%lu failed=%lu\r\n",(unsigned long)f->command,(unsigned long)f->r1,(unsigned long)f->phase,(unsigned long)f->sector,(unsigned long)f->index,(unsigned long)f->response,(unsigned long)f->transfer_failed);
  record_bench_multi=0;record_bench_stage=3;printf("REC_BENCH done state=%u error=%d pairs=%lu verified=%lu paused_us=%lu\r\n",st->state,st->error,(unsigned long)st->captured_pairs,(unsigned long)st->verified_pcm,(unsigned long)record_bench_paused_us);
 }
}

static void record_file_step(void){
 if(s11_service_ram_owned())return;
 const s11_storage_stats *before=s11_storage_statistics();uint32_t old_written=before->written_pcm+before->written_event;
 const s11_service_stats *pending=s11_service_statistics();
 (void)s11_service_card_progress(hal_time_us(),0,pending->pcm_buffered+pending->event_buffered);
#ifdef S10_MEDIA_RUNTIME
 int media=s10_runtime_media_active();
#else
 int media=0;
#endif
 (void)s11_service_file_step(media);const s11_storage_stats *after=s11_storage_statistics();
 const s11_service_stats *service_stats=s11_service_statistics();
 (void)s11_service_card_progress(hal_time_us(),after->written_pcm+after->written_event-old_written,service_stats->pcm_buffered+service_stats->event_buffered);
 if(record_generation&&record_generation==connected_generation){
  static uint32_t last_notice_ms;static unsigned last_state=255,last_wire=255,last_capture_error=255;static int last_error;
  uint32_t ms=now_ms();
  if(after->state!=last_state||after->error!=last_error||service_stats->wire_state!=last_wire||service_stats->error!=last_capture_error||(uint32_t)(ms-last_notice_ms)>=100){
   uint8_t payload[72];s11_service_info(payload);uint32_t crc=s9_crc32(payload,sizeof payload);last_notice_ms=ms;
   if(crc!=last_record_info_crc&&!record_notice_send(record_generation,record_session,record_request_sequence,S11_APP_RECORD_INFO,payload,sizeof payload)){last_record_info_crc=crc;last_state=after->state;last_error=after->error;last_wire=service_stats->wire_state;last_capture_error=service_stats->error;}
  }
  for(unsigned i=0;i<2;i++){record_result_pending *p=&record_results[i];
   if(p->pending&&p->generation!=connected_generation)p->pending=0;
   if(p->pending&&service_stats->last_command>=p->target){
    file_result r;r.generation=p->generation;memcpy(r.session,p->session,16);s9_make_result(r.result,2,p->sequence,3,0);
    if(xQueueSend(file_results,&r,0)==pdTRUE)p->pending=0;
   }
  }
 }
}
static void recorder_command(const file_command *c){
 const uint8_t *p=c->bytes+32;unsigned op=c->bytes[6];uint64_t id=s9_get64(p);int r=0;
 unsigned result_slot=0;
 if(op==S11_APP_START||op==S11_APP_STOP){
  for(;result_slot<2;result_slot++)if(!record_results[result_slot].pending||record_results[result_slot].generation!=connected_generation)break;
  if(result_slot==2){file_reply(c,7,S9_E_BUSY,0);return;}
 }
 if(op==S11_APP_START){
  int loop_claim=ll_runtime_shared_enter(LL_SHARED_RECORD);
  if(loop_claim)r=loop_claim;
  else if(s9_storage_statistics()->active||s11_service_active())r=S9_E_BUSY;
  else if((r=s11_service_can_start(id,p[8]))!=0){}
#ifdef S10_MEDIA_RUNTIME
  else r=s10_runtime_record_start(id,p[8]);
#else
  else if((r=s11_storage_prepare(id,p[8]))==0){taskENTER_CRITICAL();r=s11_service_start(id,p[8]);taskEXIT_CRITICAL();}
#endif
  if(!loop_claim)ll_runtime_shared_leave(LL_SHARED_RECORD);
 }else if(op==S11_APP_STOP){taskENTER_CRITICAL();r=s11_service_stop(id);taskEXIT_CRITICAL();}
 else if(op==S11_APP_STATUS){if(id!=s11_storage_statistics()->recording_id)r=s11_storage_select(id);}
 else if(op==S11_APP_DOWNLOAD_CANCEL){if(id!=s11_storage_statistics()->recording_id)r=S9_E_STALE;}
 else if(op==S11_APP_DOWNLOAD){
  if(s11_service_active()||player.active||player.pending||s9_storage_statistics()->active)r=S9_E_BUSY;
#ifdef S10_MEDIA_RUNTIME
  else if(s10_runtime_media_active())r=S9_E_BUSY;
#endif
  else{
   uint8_t payload[512]={0};unsigned n=0;uint64_t offset=s9_get64(p+8);
   r=offset>UINT32_MAX?S9_E_RANGE:s11_storage_download(id,p[18],(uint32_t)offset,payload+32,s9_get16(p+16),&n);
   if(!r){const s11_storage_stats *s=s11_storage_statistics();s9_put64(payload,id);s9_put64(payload+8,offset);s9_put64(payload+16,p[18]==1?512ull+s->pcm_bytes:512ull+s->event_pages*512);s9_put32(payload+24,s9_crc32(payload+32,n));payload[28]=p[18];payload[29]=(uint8_t)(offset+n==s9_get64(payload+16));r=record_notice_send(c->generation,c->bytes+8,s9_get32(c->bytes+24),S11_APP_DOWNLOAD_DATA,payload,n+32);}
  }
 }else if(op==S11_APP_EXPORT){
  if(s11_service_active()||player.active||player.pending||s9_storage_statistics()->active)r=S9_E_BUSY;
#ifdef S10_MEDIA_RUNTIME
  else if(s10_runtime_media_active())r=S9_E_BUSY;
#endif
  else r=s11_storage_export(id);
 }else r=S9_E_FORMAT;
 if(r){
#ifdef ENSEMBLE_CAPTURE_DIAG
  const sd_diagnostics *d=sd_get_diagnostics();
  link_diag_event(22,op,(uint32_t)r,d->io_errors);
  link_diag_event(23,d->deadline_errors,d->max_selected_us,d->reads);
#endif
  file_reply(c,7,r,0);return;}
 if(op==S11_APP_START||op==S11_APP_STOP){memcpy(record_session,c->bytes+8,16);record_generation=c->generation;record_request_sequence=s9_get32(c->bytes+24);record_result_pending *q=&record_results[result_slot];q->generation=record_generation;q->sequence=record_request_sequence;q->target=s11_service_command_target();memcpy(q->session,record_session,16);q->pending=1;last_record_info_crc=0;file_reply(c,2,0,0);}
 else{file_reply(c,3,0,0);uint8_t payload[72];s11_service_info(payload);(void)record_notice_send(c->generation,c->bytes+8,s9_get32(c->bytes+24),S11_APP_RECORD_INFO,payload,sizeof payload);}
}
static void file_task(void *unused){
 (void)unused;uint32_t last_record_score=0;file_busy=1;
 while(!s9_tasks_bus_initialized())vTaskDelay(pdMS_TO_TICKS(1));
 int recovered=s9_storage_recover();
#ifdef S10_MEDIA_RUNTIME
 s10_runtime_file_leave();
#endif
 s9_storage_hooks(storage_cancelled,storage_progress,0);
 if(!recovered)s9_player_autostart(&player,now_ms());
 file_busy=0;
 for(;;){
  uint32_t prof_mark=prof_now();
  record_observer_phase(OBS_FILE,OBS_LOOP);record_observer_phase(OBS_FILE,OBS_BENCH);record_bench_step();PROF(6);record_observer_phase(OBS_FILE,OBS_FILE_STEP);record_file_step();PROF(7);
  if(upload_abort&&s9_storage_statistics()->active){
   file_busy=1;s9_tasks_bus_abort_disk(0);(void)s9_storage_cancel(current_file.bytes+8);
#ifdef S10_MEDIA_RUNTIME
   if(!s9_storage_statistics()->active)s10_runtime_file_leave();
#endif
   file_busy=0;
  }
  const s11_service_stats *record_stats=s11_service_statistics();
  int urgent=player.pending&&player.command!=1;
  if(s11_score_slot(now_ms(),last_record_score,s11_service_active()&&!s11_service_ram_owned(),record_stats->pcm_buffered+record_stats->event_buffered,urgent)){
   s9_player_step(&player,now_ms());last_record_score=now_ms();
  }
  int done;
  if(s9_player_completion(&player,&done)&&play_waiting){
   pending_play.result[5]=done?7:3;s9_put16(pending_play.result+6,(uint16_t)done);
   xQueueSend(file_results,&pending_play,portMAX_DELAY);play_waiting=0;
  }
  record_stats=s11_service_statistics();
  /* Idle file service (no recording, upload, bench or score player) polls every
   * 5 ms instead of 1 ms; commands still wake this task at once via the queue.
   * Measured on board: the 1 ms polling loops left the CPU no idle time, so the
   * Bluetooth host could not receive A2DP media. */
  int file_idle=!s11_service_active()&&!s9_storage_statistics()->active&&!player.active&&!player.pending&&!play_waiting&&!record_bench_request&&!upload_abort;
  unsigned file_wait=s11_service_file_ready(s10_runtime_media_active())?0u:file_idle?5u:1u;
  PROF(8);
  record_observer_phase(OBS_FILE,OBS_FILE_WAIT);
  if(xQueueReceive(file_commands,&current_file,pdMS_TO_TICKS(file_wait))!=pdTRUE)continue;
  if(current_file.generation!=connected_generation)continue;
  file_busy=1;upload_abort=0;s9_tasks_bus_abort_disk(0);
  const uint8_t *p=current_file.bytes+32;unsigned op=current_file.bytes[6];int r=0;
  if(op>=S11_APP_START&&op<=S11_APP_EXPORT){recorder_command(&current_file);file_busy=0;continue;}
  if(op==S9_OP_PLAY){
   if(s9_storage_statistics()->active||play_waiting)r=S9_E_STATE;
   else r=s9_player_command(&player,p[0],p[1],now_ms());
   if(!r){
    pending_play.generation=current_file.generation;memcpy(pending_play.session,current_file.bytes+8,16);
    s9_make_result(pending_play.result,1,s9_get32(current_file.bytes+24),2,0);play_waiting=1;
    xQueueSend(file_results,&pending_play,portMAX_DELAY);
   }else file_reply(&current_file,7,r,0);
  }else {
#ifdef S10_MEDIA_RUNTIME
   /* Reject maintenance before FatFs/TMP/BAK mutations, not at disk_write.
    * File task owns every FatFs operation; BLE callback only queued this. */
   if(s11_service_active()||s10_runtime_file_enter()){
    file_reply(&current_file,7,S9_E_BUSY,0);file_busy=0;continue;
   }
#endif
   file_reply(&current_file,2,0,0);
   switch(op){
    case S9_OP_UPLOAD_BEGIN:
     if(player.active||player.pending||!player.stop_confirmed)r=S9_E_STATE;
     else {score_close();r=s9_storage_begin(current_file.bytes+8,s9_get32(p),s9_get32(p+4),1);}break;
    case S9_OP_UPLOAD_DATA:r=s9_storage_append(current_file.bytes+8,(uint32_t)s9_get64(p),p+12,s9_get16(current_file.bytes+28)-12);break;
    case S9_OP_UPLOAD_COMMIT:progress_ms=now_ms();r=s9_storage_commit(current_file.bytes+8);break;
    case S9_OP_UPLOAD_CANCEL:r=s9_storage_cancel(current_file.bytes+8);break;
    default:r=S9_E_FORMAT;break;
   }
   file_reply(&current_file,r?7:op==S9_OP_UPLOAD_COMMIT?4:3,r,!r&&op==S9_OP_UPLOAD_COMMIT);
#ifdef S10_MEDIA_RUNTIME
   /* Keep reservation for the complete multi-command upload and both
    * verification passes; release only after actual close/cancel/failure. */
   if(!s9_storage_statistics()->active)s10_runtime_file_leave();
#endif
  }
  s9_tasks_bus_abort_disk(0);file_busy=0;
 }
}
static void update_info(const uint8_t session[16],unsigned state){
 uint8_t b[64]={0};memcpy(b,"S9IN",4);b[4]=1;b[5]=(uint8_t)state;
 memcpy(b+8,session,16);s9_put16(b+24,548);s9_put16(b+26,192);s9_put16(b+28,247);b[31]=4;s9_put32(b+44,15);
 s9_put32(b+32,info_fx_version);s9_put32(b+36,info_map_version);s9_put16(b+40,info_gain_l);s9_put16(b+42,info_gain_e);
#ifdef S10_MEDIA_RUNTIME
 s9_put32(b+44,s10_runtime_media_available()?31:15);s10_runtime_snapshot(b+48);
#endif
 taskENTER_CRITICAL();b[6]=(uint8_t)s9_ble_queue_credit(&received,0);b[7]=(uint8_t)s9_ble_queue_credit(&received,1);
 b[30]=(uint8_t)s9_ble_queue_credit(&received,2);
 s9_put32(b+60,s9_crc32(b,60));memcpy(info,b,64);taskEXIT_CRITICAL();
}
/* The App sends one fixed effects preset (only the enable/bypass bits vary), and
 * its wet levels (-14..-18 dB) are hard to hear. Replace exactly that preset with
 * a stronger one ("enhanced-1"): delay feedback 16384, delay/chorus wet 16384,
 * reverb wet 32768 (unity), chorus depth 480, reverb feedback 28672. Any other preset
 * passes unchanged. Requires the r3c FPGA (wet cap 32768, unattenuated reverb input);
 * the frame CRC is recomputed. */
static void fx_preset_boost(uint8_t f[S9_HEADER_BYTES+44u+S9_CRC_BYTES]){
 static const uint32_t app_preset[10]={11520,12288,576,192,71583,24576,16384,6144,4096,4096};
 uint8_t *p=f+S9_HEADER_BYTES;
 for(unsigned i=0;i<10;i++)if(s9_get32(p+4+4*i)!=app_preset[i])return;
 s9_put32(p+8,16384);s9_put32(p+16,480);s9_put32(p+24,28672);s9_put32(p+32,16384);s9_put32(p+36,16384);s9_put32(p+40,32768);
 s9_put32(f+S9_HEADER_BYTES+44u,s9_crc32(f,S9_HEADER_BYTES+44u));
}
static int local_result(const s9_message *m,unsigned phase,int error){
 uint8_t b[36];s9_make_result(b,m->channel,m->sequence,phase,error);
 return s9_router_result(&router,router.generation,router.session,b);
}
static int dispatch(void){
 unsigned slot,n;s9_message m;const uint8_t *raw;
 if(!s9_router_peek(&router,&slot,&m,&raw,&n))return 0;
 if(m.channel==1&&((m.opcode>=LL_APP_BEGIN&&m.opcode<=LL_APP_PLAY)||(m.opcode>=ENS_START&&m.opcode<=ENS_STATUS))){
  int r=ll_runtime_request(&m);s9_router_sent(&router,slot);if(r)local_result(&m,7,r);return 1;
 }
 if(m.channel==1&&m.opcode==S9_OP_KEEPALIVE){
  s9_router_sent(&router,slot);local_result(&m,3,0);return 1;
 }
 if(m.channel==1&&m.opcode==S9_OP_DISCONNECT){
  s9_router_sent(&router,slot);s9_tasks_bus_close();s9_gatt_disconnect();return 1;
 }
 if(s9_router_control_dispatch(&router,slot))return 1;
 if(m.channel==2||m.opcode==S9_OP_PLAY){
  if(m.opcode==S9_OP_UPLOAD_DATA){
   uint32_t cost=(m.length-12)*1000u;
   if(file_quota<cost){router.dispatch_cursor=(m.channel+1)%3;return 0;}
  }
  file_command c;c.generation=router.generation;c.length=(uint16_t)n;memcpy(c.bytes,raw,n);
  if(xQueueSend(file_commands,&c,0)!=pdTRUE){router.dispatch_cursor=(m.channel+1)%3;return 0;}
  if(m.opcode==S9_OP_UPLOAD_DATA)file_quota-=(m.length-12)*1000u;
  s9_router_sent(&router,slot);return 1;
 }
 const uint8_t *out=raw;uint8_t fx[S9_HEADER_BYTES+44u+S9_CRC_BYTES];
 if(m.opcode==S9_OP_EFFECTS&&n==sizeof fx){memcpy(fx,raw,n);fx_preset_boost(fx);out=fx;}
 if(s9_tasks_bus_command(out,n)){router.dispatch_cursor=(m.channel+1)%3;return 0;}
 s9_router_sent(&router,slot);return 1;
}
static void protocol_task(void *unused){
 (void)unused;
 r76_bt_phase=1;btble_controller_init(configMAX_PRIORITIES-1);r76_bt_phase=2;
 r76_clock_result=diag_fix_26m_clock();r76_bt_phase=3;
 if(r76_clock_result<0){stack_ready=-1;vTaskDelete(NULL);return;}
 r76_bt_phase=4;hci_driver_init();r76_bt_phase=5;bt_enable(bluetooth_ready);r76_bt_phase=6;
 uint32_t active=0,last_peer=0;unsigned link_state=0,advertising=0;
 link_startup_gate startup={0};
 uint8_t session[16]={0},status[64],last_result[36]={0},notice[548],fragment[244];unsigned notice_size=0,notice_offset=0;
 for(;;){
  uint32_t prof_mark=prof_now();
  uint32_t now=now_ms();
#ifdef S10_MEDIA_RUNTIME
  if(stack_ready==1 && r76_adv_result==0)r76_media_result=s10_runtime_bluetooth_ready();
#endif
  uint32_t elapsed=now-file_quota_at;file_quota_at=now;
  if(elapsed>=1000)file_quota=500000;
  else {file_quota+=elapsed*16384u;if(file_quota>500000)file_quota=500000;}
  if(retired_generation){
   taskENTER_CRITICAL();retired_generation=0;taskEXIT_CRITICAL();
   ll_runtime_disconnect();s9_router_disconnect(&router);s9_tasks_bus_close();notice_size=0;active=0;advertising=0;callback_ready=0;link_startup_reset(&startup,0,now);
  }
  if(connected_generation&&connected_generation!=active){
   active=connected_generation;s9_put64(session,boot_identity);s9_put64(session+8,active);
   s9_router_reset(&router,session,active);memset(last_result,0,36);notice_size=0;last_peer=now;
   link_state=0;link_startup_reset(&startup,active,now);
  }
  if(active && !startup.opened){
   int gate=link_startup_poll(&startup,active,now,s9_gatt_transport_ready(active));
   if(gate<0){link_diag_event(LD_INIT_TIMEOUT,active,now,startup.started);s9_gatt_disconnect();}
   else if(gate>0){
    s9_tasks_bus_peer_deadline(now+5000);
    if(!s9_tasks_bus_open(session)){
     startup.opened=1;last_peer=now;link_state=1;
     link_diag_event(LD_OPEN,active,now,now+5000);
    }
   }
  }
  while(s9_tasks_bus_status(status)){
   if(memcmp(status+8,session,16))continue;
   if(link_state!=status[5])link_diag_event(LD_BUS_STATE,active,link_state,status[5]);
   link_state=status[5];
   if(active&&link_state==2){s9_router_ready(&router,1);callback_ready=1;}
   else if(active&&router.ready){callback_ready=0;s9_gatt_disconnect();}
   if(router.ready&&status[29]&&s9_get32(status+24)){
    uint8_t r[36]={0};memcpy(r,status+24,32);s9_put32(r+32,status[7]);
    if(memcmp(r,last_result,36)){
     if(!s9_router_result(&router,active,session,r)&&r[4]==1&&r[5]>=3&&r[5]<6){
      for(unsigned i=0;i<S9_ROUTER_SLOTS;i++)if(router.entry[i].used&&router.entry[i].request[5]==1&&s9_get32(router.entry[i].request+24)==s9_get32(r)){
       const uint8_t *q=router.entry[i].request;
       if(q[6]==S9_OP_HELLO){info_fx_version=s9_get32(r+12);info_map_version=s9_get32(r+16);info_gain_l=s9_get16(r+24);info_gain_e=s9_get16(r+26);}
       if(q[6]==S9_OP_EFFECTS&&r[5]==4)info_fx_version=s9_get32(r+12);
       if(q[6]==S9_OP_KEYMAP&&r[5]==4)info_map_version=s9_get32(r+12);
       if(q[6]==S9_OP_GAIN&&r[5]==5){info_gain_l=(q[36]&1)?0:s9_get16(q+32);info_gain_e=(q[36]&2)?0:s9_get16(q+34);}
      }
     }
     memcpy(last_result,r,36);
    }
   }
  }
  if(stack_ready==1&&s9_tasks_bus_initialized()&&!s9_gatt_connected()&&!active&&!file_busy&&!link_state&&!advertising){
   advertise_allowed=1;r76_adv_result=s9_gatt_advertise();if(!r76_adv_result)advertising=1;
  }
  /* The router cannot consume a fragment while its transient error awaits
   * notification. Leave that fragment in the bounded callback queue; GATT
   * credits/backpressure remain truthful. Only this task changes the router. */
  PROF(0);
  s9_ble_rx_slot rx;int got=S9_MORE;
  if(!router.error_dirty){taskENTER_CRITICAL();got=s9_ble_queue_pop(&received,&rx);taskEXIT_CRITICAL();}
  if(got==S9_COMPLETE){
   int r=s9_router_fragment(&router,rx.generation,rx.channel,rx.bytes,rx.length,now);
   if(r>=0){last_peer=now;s9_tasks_bus_peer_deadline(now+PHONE_PEER_GRACE_MS);}
  }
  /* A phone awaiting the reply to its own file/record request is silent by
   * design; that wait is not a lost peer. Link loss is still detected by the
   * BLE supervision timeout. */
  if(active&&file_busy){last_peer=now;s9_tasks_bus_peer_deadline(now+PHONE_PEER_GRACE_MS);}
  if(active&&router.ready&&(uint32_t)(now-last_peer)>5000){link_diag_event(LD_PEER_TIMEOUT,active,now,last_peer);s9_tasks_bus_close();s9_gatt_disconnect();}
  file_result fr;
  while(xQueueReceive(file_results,&fr,0)==pdTRUE)(void)s9_router_result(&router,fr.generation,fr.session,fr.result);
  PROF(1);
  for(unsigned i=0;i<4;i++)if(!ll_runtime_step())break;
  uint8_t loop_result[36];while(ll_runtime_result(loop_result))if(active)(void)s9_router_result(&router,active,session,loop_result);
  PROF(2);
  s9_router_control_step(&router);
  for(unsigned i=0;i<3;i++)dispatch();
  PROF(3);
  if(!notice_size){int n=s9_router_notice(&router,notice,sizeof notice);if(n>0){notice_size=(unsigned)n;notice_offset=0;}else{record_notice rn;if(xQueueReceive(record_notices,&rn,0)==pdTRUE&&rn.generation==active&&router.notification_sequence){memcpy(notice,rn.bytes,rn.length);s9_put32(notice+24,router.notification_sequence++);s9_put32(notice+rn.length-4,s9_crc32(notice,rn.length-4));notice_size=rn.length;notice_offset=0;}}}
  if(!notice_size&&active&&router.ready&&router.notification_sequence){
   uint8_t loop_info[64];if(ll_runtime_notice(loop_info)){
    int n=s9_encode(notice,sizeof notice,3,LL_APP_INFO,session,router.notification_sequence++,loop_info,64);
    if(n>0){notice_size=(unsigned)n;notice_offset=0;}
   }
  }
  if(!notice_size&&active&&router.ready&&router.notification_sequence){
   uint8_t ensemble_info[64];if(ll_runtime_ensemble_notice(ensemble_info)){
    int n=s9_encode(notice,sizeof notice,3,ENS_INFO,session,router.notification_sequence++,ensemble_info,64);
    if(n>0){notice_size=(unsigned)n;notice_offset=0;}
   }
  }
  if(notice_size&&active){
   unsigned mtu=s9_gatt_mtu(),n=notice_size-notice_offset;if(n>mtu-11)n=mtu-11;
   s9_put32(fragment,s9_get32(notice+24));s9_put16(fragment+4,(uint16_t)notice_offset);s9_put16(fragment+6,(uint16_t)n);memcpy(fragment+8,notice+notice_offset,n);
   if(!s9_gatt_notify_fragment(active,fragment,n+8)){notice_offset+=n;if(notice_offset==notice_size)notice_size=0;}
  }
  PROF(4);
  update_info(session,active?link_state:0);
  PROF(5);
  /* During A2DP media without a live loop/ensemble, BLE control can run at 3 ms. */
  vTaskDelay(pdMS_TO_TICKS(s10_runtime_media_active()&&!ll_runtime_active()?3:1));
 }
}
int s9_runtime_start(uint64_t nonce,uint64_t epoch){
 if(!nonce||!epoch)return -1;
#ifdef S10_MEDIA_RUNTIME
 if(s10_runtime_prepare())return -1;
#endif
 ll_runtime_init();
 boot_identity=nonce;s9_ble_queue_init(&received);s9_player_init(&player,epoch);
 file_commands=xQueueCreate(2,sizeof(file_command));file_results=xQueueCreate(8,sizeof(file_result));record_notices=xQueueCreate(2,sizeof(record_notice));
 if(!file_commands||!file_results||!record_notices||s9_tasks_bus_init())return -1;
 TaskHandle_t bus_handle=0,file_handle=0;
 if(xTaskCreate(s9_tasks_bus_run,"s9_bus",768,0,5,&bus_handle)!=pdPASS)return -1;
 record_observer_bind(OBS_BUS,bus_handle,768);
 if(xTaskCreate(file_task,"s9_file",1280,0,4,&file_handle)!=pdPASS)return -1;
 record_observer_bind(OBS_FILE,file_handle,1280);
 if(xTaskCreate(protocol_task,"s9_protocol",1024,0,4,0)!=pdPASS)return -1;
#ifdef S10_MEDIA_RUNTIME
 if(s10_runtime_start_task())return -1;
#endif
 return 0;
}
