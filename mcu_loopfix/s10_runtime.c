#include "bus_fault.h"
#include "sd_capture_budget.h"
#include "sd_lease.h"
#include "record_hot.h"
#include "record_profile.h"
#include "audio_timebase.h"
#include "sd_spi.h"
#include "record_timing.h"
#include "record_trace.h"
/* Runtime connections: one media worker, one SPI owner, one Bluetooth stack.
 * Startup still requires the existing unqualified-board gate; no board action.
 */
#include "s10_runtime.h"
#include "wire_probe.h"
#include "live_loop_runtime.h"
#include "s10_profile.h"
#include "s10_media_pipeline.h"
#include "s10_spi_dma.h"
#include "s10_sd_admission.h"
#include "score_hal.h"
#include "s9_tasks_bus.h"
#include "s11_service.h"
#include "s11_storage.h"
#include "s9_protocol.h"
#ifdef ENSEMBLE_CAPTURE_DIAG
#include "link_diag.h"
#endif
#include "FreeRTOS.h"
#include "task.h"
#include <string.h>
#include <stdio.h>
static s10_media_pipeline media;
static s10_pcm_tx transport;
static s10_spi_dma dma;
/* Same ordinary DMA-visible SRAM bank as the existing recorder buffers. */
static uint8_t sd_dma_buffers[2][512] __attribute__((aligned(32)));
static s10_sd_admission admission;
static s10_tx_job job;
static int record_job_ready,record_sd_waiting;
static int prepared,bus_ready,profile_enabled;
static int media_reserved,file_reserved;
static int record_preparing; /* protected by the existing short critical section */
static uint32_t runtime_faults,refill_cancelled;
static TaskHandle_t bus_task;
static uint64_t dma_ticket;
static uint8_t recorder_tx_backing[2144] __attribute__((aligned(32)));
#define recorder_tx (*(uint8_t (*)[2144])RECORD_DMA_PTR(recorder_tx_backing))
static uint8_t recorder_rx_backing[2144] __attribute__((aligned(32)));
#define recorder_rx (*(uint8_t (*)[2144])RECORD_DMA_PTR(recorder_rx_backing))
static int recorder_dma,recorder_media_job;
static unsigned recorder_wire_bytes;
static uint64_t recorder_due,recorder_event_due;
static uint16_t recorder_payload_hint;
static sd_capture_budget capture_budget;
static unsigned recorder_fraction;
static uint64_t recorder_received;
/* The5120B packet timeline was diagnostic-only; raw traces are archived. */
volatile unsigned record_timing_count,record_timing_frozen,record_timing_truncated;

RECORD_HOT void record_timing(unsigned kind,uint32_t a,uint32_t b,uint32_t c){
 (void)kind;(void)a;(void)b;(void)c;
 /* Keep first-error cycle-counter freezing without a per-packet trace. */
 if(!record_preparing&&s11_service_active()&&s11_service_statistics()->error)record_timing_frozen=1;
}

/* Busy cycles of the decode/resample worker, read and cleared by the 2 s diag. */
static volatile uint32_t media_cycles;
static void media_task(void *unused){
 (void)unused;
 for(;;){
  uint32_t c0,c1;__asm__ volatile("rdcycle %0":"=r"(c0));
  s10_profile_step();
  for(unsigned i=0;i<8;i++){int r=s10_media_worker_step(&media);if(r<=0)break;}
  __asm__ volatile("rdcycle %0":"=r"(c1));media_cycles+=c1-c0;
  vTaskDelay(pdMS_TO_TICKS(1));
 }
}
int s10_runtime_prepare(void){
 if(prepared)return -1;
 RECORD_DMA_PREPARE(recorder_tx_backing);RECORD_DMA_PREPARE(recorder_rx_backing);
 memset(&dma,0,sizeof dma);
 s10_pcm_tx_init(&transport);s10_sd_admission_init(&admission,0);s11_service_init();
 if(s10_profile_prepare(&media))return -1;
 /* Startup recovery is reserved before any Bluetooth endpoint can start. */
 file_reserved=1;prepared=1;return 0;
}
int s10_runtime_bluetooth_ready(void){
 taskENTER_CRITICAL();
 if(!prepared||!bus_ready){taskEXIT_CRITICAL();return -1;}
 if(profile_enabled){int r=profile_enabled==1?0:-1;taskEXIT_CRITICAL();return r;}
 profile_enabled=2;taskEXIT_CRITICAL();
 int r=s10_profile_enable();
 taskENTER_CRITICAL();profile_enabled=r?-1:1;if(r)++runtime_faults;taskEXIT_CRITICAL();
 return r;
}
int s10_runtime_media_available(void){
 if(bus_fault_active())return 0;
 taskENTER_CRITICAL();int ready=profile_enabled==1&&bus_ready;taskEXIT_CRITICAL();return ready;
}
int s10_runtime_media_claim(void){
 if(bus_fault_active())return -1;
 taskENTER_CRITICAL();
 int r=(!bus_ready||file_reserved||ll_runtime_shared_enter(LL_SHARED_MEDIA))?-1:0;
 if(!r)media_reserved=1;
 taskEXIT_CRITICAL();return r;
}
void s10_runtime_media_release(void){taskENTER_CRITICAL();media_reserved=0;ll_runtime_shared_leave(LL_SHARED_MEDIA);taskEXIT_CRITICAL();}
int s10_runtime_file_enter(void){
 if(bus_fault_active())return -1;
 taskENTER_CRITICAL();int r=media_reserved?-1:0;
 if(!r)file_reserved=1;
 taskEXIT_CRITICAL();return r;
}
void s10_runtime_file_leave(void){taskENTER_CRITICAL();file_reserved=0;taskEXIT_CRITICAL();}
int s10_runtime_start_task(void){return prepared&&xTaskCreate(media_task,"s10_media",1024,0,4,0)==pdPASS?0:-1;}
RECORD_HOT static int contains(const void *base,size_t capacity,const void *ptr,size_t n){
 uintptr_t a=(uintptr_t)base,b=(uintptr_t)ptr;
 return b>=a&&b-a<=capacity&&n<=capacity-(b-a);
}
RECORD_HOT static int dma_ram(void *unused,const void *p,size_t n){
 (void)unused;
 if(contains(sd_dma_buffers,sizeof sd_dma_buffers,p,n))return 1;
 /* Explicit cache-line allocation whitelist; no arbitrary SRAM/PSRAM casts. */
 if(contains(transport.control_tx,sizeof transport.control_tx,p,n)||contains(transport.control_rx,sizeof transport.control_rx,p,n)||
    contains(dma.tx_lli,sizeof dma.tx_lli,p,n)||contains(dma.rx_lli,sizeof dma.rx_lli,p,n))return 1;
 if(contains(recorder_tx,sizeof recorder_tx,p,n)||contains(recorder_rx,sizeof recorder_rx,p,n))return 1;
 for(unsigned i=0;i<2;i++)if(contains(transport.bank[i].tx,sizeof transport.bank[i].tx,p,n)||contains(transport.bank[i].rx,sizeof transport.bank[i].rx,p,n))return 1;
 return 0;
}
RECORD_HOT static uint64_t dma_time(void *unused){(void)unused;return hal_time_us();}
RECORD_HOT static int dma_owner(void *unused){(void)unused;return hal_bus_owner();}
RECORD_HOT static int dma_select(void *unused,int target){(void)unused;return hal_select(target);}
static void dma_wake(void *owner){
 BaseType_t higher=pdFALSE;
 vTaskNotifyGiveFromISR((TaskHandle_t)owner,&higher);
 portYIELD_FROM_ISR(higher);
}
int s10_runtime_bus_initialize(void){
 s10_dma_binding binding={0,dma_time,dma_owner,dma_select,dma_ram};
 if(!prepared||bus_ready)return -1;
 /* Diagnostic only, one bus owner before normal DMA binding and SD work. */
 if(wire_probe_run()){for(;;)vTaskDelay(pdMS_TO_TICKS(1000));}
 bus_task=xTaskGetCurrentTaskHandle();
 if(hal_media_dma_bind(&dma,&binding)||s10_spi_dma_set_wakeup(&dma,dma_wake,bus_task)){++runtime_faults;return -1;}
 bus_ready=1;return 0;
}
RECORD_HOT int s10_runtime_sd_exchange(const uint8_t *tx,unsigned bytes,uint32_t frequency){
 if(bus_fault_active()||!tx||bytes!=512||!frequency||!bus_ready||dma_ticket||dma.state!=S10_DMA_IDLE||hal_bus_owner()!=BUS_SD){
  printf("SD_DMA_FAIL pre ticket=%lu state=%d owner=%d\r\n",(unsigned long)dma_ticket,(int)dma.state,hal_bus_owner());return -1;
 }
 /* A separate RX sink drains every full-duplex byte. Caller payload and
  * the PCM ring are never DMA RX destinations or invalidated here. */
 record_copy(sd_dma_buffers[0],tx,512);
 /* File preparation still uses 2 MHz: 512 bytes need 2048 us there.
  * The enclosing SD grant remains responsible for its stricter total limit. */
 /* 2.5ms slack absorbs IRQ/task latency in the completion stamps; the SD
  * grant still bounds the selected interval. */
 uint32_t timeout=(UINT32_C(4096000000)+frequency-1u)/frequency+2500u;
 int result=s10_spi_dma_begin_selected(&dma,sd_dma_buffers[0],sd_dma_buffers[1],512,timeout);
 if(dma.state==S10_DMA_IDLE)return -1;
 uint64_t wait_began=hal_time_us();
 do{
  result=s10_spi_dma_poll(&dma,0);
  if(bus_fault_active()){
   record_trace_measure(RP_SD_DMA_WAIT,(uint32_t)(hal_time_us()-wait_began));
   return -1;
  }
 }while(!s10_spi_dma_is_retired(&dma,0));
 record_trace_measure(RP_SD_DMA_WAIT,(uint32_t)(hal_time_us()-wait_began));
 if(result!=S10_DMA_DONE)printf("SD_DMA_FAIL result=%d elapsed=%lu tx_us=%lu rx_us=%lu timeout=%lu\r\n",result,(unsigned long)(hal_time_us()-dma.started_us),(unsigned long)dma.tx_completed_us,(unsigned long)dma.rx_completed_us,(unsigned long)timeout);
 if(s10_spi_dma_release(&dma,0))return -1;
 return result==S10_DMA_DONE?0:-1;
}
static void transport_fault(int reason){
 uint64_t epoch=0;int error=0;
 ++runtime_faults;
 if(s10_media_state(&media,&epoch,&error)!=S10_MEDIA_CLOSED)(void)s10_media_stop(&media,epoch,reason);
}
/* A closed media pipeline and closed TX have no PCM source work. Keep
 * ordinary media maintenance whenever a source is reserved/open/closing.
 * Snapshot lifecycle fields under the same existing source lock. */
RECORD_HOT static int recorder_only_closed(void){
 taskENTER_CRITICAL();
 int closed=media.initialized&&!media_reserved&&media.state==S10_MEDIA_CLOSED&&transport.state==S10_TX_CLOSED;
 taskEXIT_CRITICAL();return closed;
}
/* Header is frozen before CS: an ACK response can describe its old pinned
 * block. Hints only select next packet length, never prove retirement. */
static void recorder_payload_status(const uint8_t *p){
 unsigned kind=p[22],bytes=(p[7]&1)?s9_get16(p+48):0;
 recorder_payload_hint=bytes&&((kind==1&&bytes<=S11_BULK_PAYLOAD_BYTES)||(kind==2&&bytes<=512u))?(bytes>512u?S11_BULK_PAYLOAD_BYTES:512u):0;
 if(recorder_tx[40]==S11_REC_ACK&&kind==recorder_tx[42]&&s9_get32(p+36)==s9_get32(recorder_tx+48))recorder_payload_hint=0;
}
/* Active includes the sole file owner's drain/finish/verification lifetime.
 * A terminal wire snapshot with no command, ACK or pinned-payload hint has
 * no recorder transaction left. Media jobs remain independently eligible. */
static int recorder_terminal_quiet(void){
 const s11_service_stats *s=s11_service_statistics();
 return (s->wire_state==S11_CLOSED||s->wire_state==S11_INCOMPLETE||s->wire_state==S11_ERROR)&&!s->command&&!s->ack_pending&&!recorder_payload_hint&&!record_job_ready&&!dma_ticket&&recorder_only_closed();
}
RECORD_HOT int s10_runtime_bus_poll(void){
 if(bus_fault_active())return 0;
 if(!bus_ready)return 0;
 if(dma_ticket){
  int r=s10_spi_dma_poll(&dma,dma_ticket);
  /* Even an error/interrupt is not a memory/CS retirement fence. */
  if(!s10_spi_dma_is_retired(&dma,dma_ticket))return 1;
  uint64_t retired_us=hal_time_us();
  int success=r==S10_DMA_DONE;
  if(s10_spi_dma_release(&dma,dma_ticket)){transport_fault(S10_MEDIA_TRANSPORT);return 1;}
  int completed=0;
  
  if(recorder_dma){record_phase_fpga(dma.started_us,retired_us);
   if(success){int rr=s11_service_response_bytes(recorder_rx,recorder_wire_bytes);if(rr<0&&rr!=S9_E_BUSY&&rr!=S9_E_STALE){
#ifdef ENSEMBLE_CAPTURE_DIAG
    link_diag_bad_response(rr,recorder_wire_bytes,recorder_tx,recorder_rx);
    link_diag_event(24,(uint32_t)rr,recorder_wire_bytes,s11_service_statistics()->received_cells);
#endif
    s11_service_fail(S11_E_CRC,UINT64_MAX);success=0;}}
   if(success&&s9_get64(recorder_rx+24)==s11_service_statistics()->recording_id){
    recorder_payload_status(recorder_rx);
    uint64_t received=s11_service_statistics()->received_pcm;
    sd_capture_observe(&capture_budget,dma.started_us,s9_get32(recorder_rx+56),(uint32_t)recorder_received,(uint32_t)received);
    if(received>recorder_received){
     uint64_t delta=received-recorder_received;
     if(!recorder_received)recorder_due=hal_time_us();
     uint64_t period=delta*1000000u+recorder_fraction;
     recorder_due+=period/RECORD_PCM_HZ;recorder_fraction=(unsigned)(period%RECORD_PCM_HZ);recorder_received=received;
    }
   }
   
   uint32_t parse_us=(uint32_t)(hal_time_us()-retired_us);
   if(recorder_wire_bytes>68){
    const s11_service_stats *st=s11_service_statistics();
    record_trace_retire((uint32_t)(retired_us-dma.started_us),parse_us,
     success&&s9_get64(recorder_rx+24)==st->recording_id?s9_get32(recorder_rx+56):UINT32_MAX,
     (uint32_t)st->received_pcm,(uint32_t)st->stored_pcm,st->pcm_buffered,
     recorder_rx[6]|((uint32_t)recorder_rx[7]<<8)|((uint32_t)recorder_rx[22]<<16)|((uint32_t)st->error<<24),
     !success||st->error);
   }
   record_timing(2,recorder_wire_bytes,(uint32_t)(retired_us-dma.started_us),parse_us);
   if(recorder_media_job){
    uint8_t *p=job.rx+32;memset(p,0,32);memcpy(p,"S10S",4);p[4]=1;p[5]=recorder_rx[5];
    p[6]=recorder_rx[20];p[7]=recorder_rx[21];memcpy(p+8,recorder_rx+8,8);memcpy(p+16,recorder_rx+16,4);uint32_t crc=s10_pcm_crc32(p,28);memcpy(p+28,&crc,4);
    completed=s10_pcm_tx_complete(&transport,dma_ticket,success,hal_time_us());
   }
   recorder_dma=recorder_media_job=0;
  }else completed=s10_pcm_tx_complete(&transport,dma_ticket,success,hal_time_us());
  /* Include full DATA, short ACK and every legacy telemetry/control DMA. */
  s11_service_wire(hal_time_us(),(uint32_t)(hal_time_us()-dma.started_us)+1u,0);
  dma_ticket=0;
  if(!success||(completed<0&&completed!=S10_TX_STALE))transport_fault(S10_MEDIA_TRANSPORT);
 }
 /* An explicit old STOP/CLOSED fence retires its no-longer-useful refill
  * promise. Preserve historical interval/fault diagnostics, not a DATA from
  * an obsolete epoch. Do this before a new pipeline can open TX. */
 if(transport.state==S10_TX_CLOSED&&!transport.dma_active&&!admission.active&&admission.need_refill){admission.need_refill=0;++refill_cancelled;}
 if(s11_service_active()&&recorder_only_closed())return 0;
 int moved=s10_media_bus_step(&media,&transport);
 if(moved<0&&moved!=S10_MEDIA_BUSY)transport_fault(S10_MEDIA_TRANSPORT);
 if(!s10_pcm_tx_conserved(&transport)||!s10_media_conserved(&media))transport_fault(S10_MEDIA_TRANSPORT);
 return 0;
}
RECORD_HOT int s10_runtime_bus_service(void){
 if(bus_fault_active())return 0;
 if(!bus_ready||s10_runtime_bus_poll())return bus_ready?1:0;
 int record=s11_service_active();
 if(record)s11_service_set_media_guard(s10_runtime_media_active());
 /* Sole bus owner, after physical DMA retirement and before reserving a new
  * job. Finish any already-reserved job first; do not change its ownership. */
 taskENTER_CRITICAL();
 if(!record&&!record_preparing&&transport.record_feedback&&!record_job_ready&&!transport.dma_active){
  transport.service=(s10_tx_service_config){474,896,2560,32,64,5000};
  transport.record_feedback=transport.record_burst=0;record_sd_waiting=0;
 }
 taskEXIT_CRITICAL();
 if(transport.state==S10_TX_CLOSED&&!record)return 0;
 if(admission.epoch!=transport.epoch){
  if(admission.active||admission.need_refill){transport_fault(S10_MEDIA_TRANSPORT);return 0;}
  s10_sd_admission_init(&admission,transport.epoch);
 }
 int event_file=record&&!s11_service_ram_owned()&&(s11_service_statistics()->mask&S11_KIND_EVENT);
 int short_ack=record&&s11_service_statistics()->ack_pending&&!s11_service_statistics()->command;
 if(record_job_ready&&job.generation!=transport.generation){(void)s10_pcm_tx_complete(&transport,job.ticket,0,hal_time_us());record_job_ready=0;}
 int demand_status=record&&record_sd_waiting&&!transport.record_burst&&transport.state==S10_TX_PLAY&&transport.data_after_status&&hal_time_us()>=transport.telemetry_us&&hal_time_us()-transport.telemetry_us>=1000;
 int have_media=record_job_ready||(!short_ack&&transport.state!=S10_TX_CLOSED&&(demand_status?s10_pcm_tx_status_next(&transport,hal_time_us(),&job):s10_pcm_tx_next(&transport,hal_time_us(),&job))==0);
 if(have_media)record_job_ready=1;
 if(!have_media){
  if(record&&recorder_terminal_quiet())return 0;
  uint64_t due=s11_service_ram_owned()?recorder_due:recorder_due+(256000000u+RECORD_PCM_HZ-1u)/RECORD_PCM_HZ;
  if(event_file&&(recorder_payload_hint||recorder_event_due<due))due=recorder_payload_hint?0:recorder_event_due;
  /* Before a local3ms grant, pull due capture up by the extra1ms.
   * Commands/ACKs already bypass this timer. No change to mixed media. */
  if(record_sd_waiting&&!s10_runtime_media_active()&&!s11_service_ram_owned()){
   unsigned lease=sd_reservation_us();unsigned advance=lease>SD_MIXED_LEASE_US&&lease<=3000u?lease-SD_MIXED_LEASE_US:0;
   due=due>advance?due-advance:0;
  }
  if(!record||(!short_ack&&!s11_service_statistics()->command&&(!s11_service_receive_credit()||(record_sd_waiting!=2&&hal_time_us()<due))))return 0;
  if(!transport.next_ticket){s11_service_fail(S11_E_GENERATION,UINT64_MAX);return 0;}
  memset(&job,0,sizeof job);
 }
 size_t capacity=job.operation==2?sizeof transport.bank[0].tx:sizeof transport.control_tx;
 int use_record=record&&(!have_media||job.operation==S11_MEDIA_DATA);
 int effective_short=short_ack&&!have_media;
 unsigned credit=s11_service_receive_credit();
 unsigned reverse_capacity=effective_short?0:(have_media?(recorder_payload_hint>512&&credit>=recorder_payload_hint?recorder_payload_hint:512):event_file?(s11_service_statistics()->command?512:credit>=recorder_payload_hint?recorder_payload_hint:0):credit);
 if(!effective_short&&!event_file&&!reverse_capacity)reverse_capacity=512;
 unsigned planned_bytes=use_record?68u+reverse_capacity:job.length;
 if(record&&s11_service_wire_begin(hal_time_us(),use_record?fpga_record_wire_us(planned_bytes):fpga_wire_us(planned_bytes)))return 0;
 if(!have_media)job.ticket=transport.next_ticket++;
 record_job_ready=0;
 int r;
 if(use_record){
  uint64_t prepare_us=hal_time_us();
  
  recorder_wire_bytes=s11_service_request_mode(recorder_tx,have_media?job.tx:0,have_media?job.length:0,reverse_capacity);
  
  /* A changing physical key emits an expression plus publication marker
   * per ~205us ADC frame. 5ms/16 cells cannot sustain even one key.
   * 1ms admits <=648us of full DATA+short ACK at 8MHz; the existing
   * rolling 80% bus budget and ownership checks still apply. This bounds
   * the polling floor, not a promise of arbitrary eight-key change rate. */
  if(s11_service_ram_owned()&&!effective_short)recorder_due=hal_time_us()+1000;
  if(event_file&&!effective_short)recorder_event_due=hal_time_us()+1000;
  r=s10_spi_dma_begin(&dma,job.ticket,BUS_FPGA,FPGA_RECORD_SPI_HZ,recorder_tx,sizeof recorder_tx,recorder_rx,sizeof recorder_rx,recorder_wire_bytes,4000);
  uint32_t launch_us=(uint32_t)(hal_time_us()-prepare_us);
  if(recorder_wire_bytes>68)record_trace_start((uint32_t)prepare_us,launch_us);
  record_timing(1,recorder_wire_bytes,launch_us,(uint32_t)s11_service_statistics()->received_pcm);
  recorder_dma=1;recorder_media_job=have_media;

 }else{
  /* A2DP PCM uses the recorder's proven 20 MHz FPGA link: at 5 MHz the 548-byte
   * DATA packets kept the wire (and this bus task) ~1/3 busy, starving decode. */
  r=s10_spi_dma_begin(&dma,job.ticket,BUS_FPGA,FPGA_RECORD_SPI_HZ,job.tx,capacity,job.rx,capacity,job.length,4000);
 }
 if(r==S10_DMA_PENDING||dma.state!=S10_DMA_IDLE){
  dma_ticket=job.ticket;
  if(r!=S10_DMA_PENDING)transport_fault(S10_MEDIA_TRANSPORT);
  else if(job.pairs&&admission.need_refill&&s10_sd_admission_pcm_started(&admission,hal_time_us(),job.pairs))transport_fault(S10_MEDIA_TRANSPORT);
  return 1;
 }
 if(have_media)(void)s10_pcm_tx_complete(&transport,job.ticket,0,hal_time_us());
 recorder_dma=recorder_media_job=0;transport_fault(S10_MEDIA_TRANSPORT);return 0;
}
int s10_runtime_record_prepare(void){
 if(bus_fault_active())return -1;
 /* Reserve maintenance through real FatFs setup. The bus may run while
  * the file task blocks on RPC, but must not retire a PREPARING mode.
  * No SPI, filesystem operation or scheduler wait is inside this lock. */
 taskENTER_CRITICAL();
 if(record_preparing||file_reserved||media_reserved||s10_runtime_media_active()||transport.state!=S10_TX_CLOSED||dma_ticket||record_job_ready){taskEXIT_CRITICAL();return -1;}
 s10_tx_service_config c=transport.service;c.query_period_us=5000;c.steady_trigger=474;c.mcu_bias_divisor=16;c.mcu_bias_limit=96;
 int r=s10_pcm_tx_service_configure(&transport,&c);
 if(!r){record_preparing=1;file_reserved=1;transport.record_feedback=1;recorder_received=recorder_due=recorder_event_due=recorder_fraction=recorder_payload_hint=0;memset(&capture_budget,0,sizeof capture_budget);record_timing_count=record_timing_frozen=record_timing_truncated=0;record_profile_reset();record_trace_reset();}
 taskEXIT_CRITICAL();return r;
}
void s10_runtime_record_prepared(void){
 /* Caller publishes START first, or reports preparation failure. Restoration
  * stays with the bus owner and only follows physical job retirement. */
 taskENTER_CRITICAL();
 if(record_preparing){record_preparing=0;file_reserved=0;}
 taskEXIT_CRITICAL();
}
int s10_runtime_record_start(uint64_t id,unsigned mask){
 /* Shared production entry, called by the sole file task and host tests.
  * Storage setup deliberately runs with bus callbacks already installed. */
 int r=s11_service_can_start(id,mask);if(r)return r;
 if(s10_runtime_record_prepare())return S9_E_BUSY;
 r=s11_storage_prepare(id,mask);
 if(!r){taskENTER_CRITICAL();r=s11_service_start(id,mask);taskEXIT_CRITICAL();}
 s10_runtime_record_prepared();return r;
}
int s10_runtime_media_active(void){
 if(!prepared)return 0;
 return s10_media_state(&media,0,0)!=S10_MEDIA_CLOSED||s10_profile_busy();
}
RECORD_HOT void s10_runtime_bus_wait(void){
 if(!dma_ticket){vTaskDelay(pdMS_TO_TICKS(1));return;}
 /* Notifications only wake scheduling. They never authorize cache/CS reuse.
  * A DMA ISR can precede the last SPI bit, so poll the actual fence for a
  * short bounded tail before waiting again for the remaining terminal IRQ. */
 (void)ulTaskNotifyTake(pdTRUE,pdMS_TO_TICKS(1));
 uint64_t began=hal_time_us();
 while(dma_ticket&&(dma.tx_terminal||dma.rx_terminal)&&hal_time_us()-began<50){
  if(!s10_runtime_bus_poll())break;
  hal_delay_us(2);
 }
}
/* Native capture has a producer deadline as well as a file writer.
 * An SD lease must not repeatedly bypass an outstanding ACK or overdue
 * readback merely because external phone-audio playback is closed. */
RECORD_HOT static int recorder_urgent_for_sd(uint64_t now){
 const s11_service_stats *st=s11_service_statistics();
 if(st->ack_pending||st->command)return 1;
 if(recorder_terminal_quiet())return 0;
 if(!s11_service_ram_owned()&&(st->mask&S11_KIND_EVENT)&&s11_service_receive_credit()&&(recorder_payload_hint||now>=recorder_event_due))return 1;
 if(st->wire_state!=S11_CAPTURING||!(st->mask&S11_KIND_PCM))return 0;
 if(!s11_service_receive_credit())return 0;
 uint64_t due=recorder_due+(256000000u+RECORD_PCM_HZ-1u)/RECORD_PCM_HZ;
 return now>=due;
}
#define SD_ADMIT_POLL_DELAY_US 25u

RECORD_HOT static void sd_admission_pause(void)
{
 uint64_t began=hal_time_us();
 /* Keep the original polling policy for an undisturbed timing comparison. */
 hal_delay_us(SD_ADMIT_POLL_DELAY_US);
 record_trace_measure(RP_ADMIT_DELAY_US,(uint32_t)(hal_time_us()-began));
}

int s10_runtime_sd_prepare(void *unused){
 if(bus_fault_active())return -1;
 (void)unused;
 uint64_t began=hal_time_us();
 if(s11_service_active()){
  int mixed=s10_runtime_media_active();s11_service_set_media_guard(mixed);
  if(sd_set_recording_guard(mixed))return -1;
  uint32_t lease=sd_reservation_us();unsigned ceiling=sd_lease_ceiling(mixed);if(!lease||lease>ceiling)lease=ceiling;
  /* Keep stock checks active even after this original long DATA grant is
   * shortened below3ms. Short card-ready probes retain their old policy. */
  int budgeted=!mixed&&lease>3000u;
  uint32_t lookahead=lease>SD_MIXED_LEASE_US&&lease<=3000u?lease-SD_MIXED_LEASE_US:0;
  record_sd_waiting=1;
  for(;;){
   if(bus_fault_active())return -1;
   if(hal_time_us()-began>=20000){record_sd_waiting=0;s11_service_fail(S11_E_SERVICE,UINT64_MAX);return -1;}
   s9_tasks_bus_control_service();if(s10_runtime_bus_poll()){s10_runtime_bus_wait();continue;}
   uint64_t now=hal_time_us();int ready=!s10_runtime_media_active();
   const s11_service_stats *capture=s11_service_statistics();
   int low=ready&&budgeted&&capture->wire_state==S11_CAPTURING&&(capture->mask&S11_KIND_PCM)&&!sd_capture_can_lease(&capture_budget,now,lease);
   if(low){
    /* Fit DATA before the receive ring fills. The old policy only fitted
     * after receive credit was exhausted, needlessly preferring more RX. */
    unsigned fit=sd_capture_available_us(&capture_budget,now);
    if(fit>=SD_MIXED_LEASE_US){
     if(fit<lease){if(sd_shorten_reservation(fit))return -1;lease=fit;}
     low=0;
    }else if(!s11_service_receive_credit()){
     order_trace_data(OT_CAPTURE_LEASE,lease,fit);order_trace_data(OT_CAPTURE_REFUSE,fit,0);
     /* Which ring withheld receive credit: PCM (2 KiB) or events (512 B). */
     printf("SD_CAPTURE_REFUSE fit_us=%u pcm_buffered=%lu event_buffered=%u\r\n",fit,
            (unsigned long)capture->pcm_buffered,(unsigned)capture->event_buffered);
     record_sd_waiting=0;s11_service_fail(S11_E_SERVICE,UINT64_MAX);return -1;
    }
   }
   record_sd_waiting=low?2:1;
   if(low)order_trace_data(OT_CAPTURE_REFILL,capture_budget.captured-capture_budget.retired_floor,(uint32_t)(now-capture_budget.stamp));
   /* A stock-checked DATA grant already leaves6ms for the next RX. Do not
    * refill solely because its periodic timer is due; ACK/START/STOP fences
    * still run before SD, and low stock still forces RX regardless of timer. */
   if(ready&&(low||capture->ack_pending||capture->command||(!budgeted&&recorder_urgent_for_sd(now+lookahead)))){
    if(s10_runtime_bus_service()){s10_runtime_bus_wait();continue;}
    /* A service error is still handled by its existing owner. Do not
     * invent successful data/ACK completion to grant a card lease. */
    if(low||capture->ack_pending||capture->command||
       (!budgeted&&recorder_urgent_for_sd(hal_time_us()+lookahead))){
     sd_admission_pause();
     continue;
    }
   }
   if(!ready&&transport.state==S10_TX_PLAY&&transport.telemetry_valid&&now>=transport.telemetry_us&&transport.stream_state==2){
    uint64_t age=now-transport.telemetry_us;if(age<=UINT64_MAX/48048u){uint64_t product=age*48048u;uint64_t used=product/1000000+(product%1000000!=0)+2;
     ready=used<=transport.stream_buffered&&transport.stream_buffered-used>=256u+(lease*48048u+999999u)/1000000u&&s10_pcm_tx_unsent(&transport)>=512;}
   }
   /* Recording uses only the normal inventory feedback, never SD boost. */
   int r=s11_service_sd_reserve(now,ready,lease);if(!r){if(budgeted&&capture->wire_state==S11_CAPTURING){order_trace_data(OT_CAPTURE_GRANT,capture_budget.captured-capture_budget.retired_floor,(uint32_t)(now-capture_budget.stamp));order_trace_data(OT_CAPTURE_LEASE,lease,sd_capture_available_us(&capture_budget,now));}record_sd_waiting=0;s10_pcm_tx_sd_request(&transport,0);return 0;}
   if(s10_runtime_bus_service()){s10_runtime_bus_wait();continue;}
   sd_admission_pause();
  }
 }
 if(!s10_runtime_media_active())return 0;
 /* Denial is bounded and source-scoped. No endless card starvation wait. */
 for(;;){
  if(hal_time_us()-began>=100000)return -1;
  s9_tasks_bus_control_service();
  if(s10_runtime_bus_service()){s10_runtime_bus_wait();continue;}
  if(!s10_runtime_media_active())return 0;
  int r=s10_sd_admission_begin(&admission,&transport,hal_time_us(),s9_tasks_bus_control_pending());
  if(!r)return 0;
  if(r==S10_SD_FAULT){transport_fault(S10_MEDIA_TRANSPORT);return -1;}
  if(hal_time_us()-began>=100000)return -1;
  /* Refill uses its existing absolute 1ms deadline, not a scheduler tick.
   * At admission start there were at least 512 actual MCU unsent pairs. */
  if(admission.need_refill){
   if(s10_sd_admission_check(&admission,hal_time_us())){transport_fault(S10_MEDIA_TRANSPORT);return -1;}
   hal_delay_us(2);
  }else vTaskDelay(pdMS_TO_TICKS(1));
 }
}
RECORD_HOT void s10_runtime_sd_retired(void *unused,uint64_t selected_us){
 (void)unused;
 if(s11_service_active()){
  record_trace_sd((uint32_t)selected_us);
  record_timing(3,(uint32_t)selected_us,sd_reservation_us(),(uint32_t)s11_service_statistics()->received_pcm);
  (void)s11_service_sd_end(hal_time_us(),selected_us);
  /* The mixed-media record lease is at most2ms and entered with a reserved-use deduction plus256 confirmed pairs.
   * Normal finite-inventory TX scheduling refills when needed. Forcing a
   * packet after every512-byte write overfeeds TRACK and consumes quota. */
  return;
 }
 if(admission.active&&s10_sd_admission_end(&admission,&transport,hal_time_us()))transport_fault(S10_MEDIA_TRANSPORT);
 /* The next SD-free service window or prepare() starts the first refill.
  * Do not arm DMA from inside release(): callers may still perform SD-free
  * idle clocks or start another service window. */
}
void s10_runtime_snapshot(uint8_t out[12]){
 taskENTER_CRITICAL();
 uint64_t epoch=0;int error=0;
 int state=prepared?s10_media_state(&media,&epoch,&error):S10_MEDIA_CLOSED;
 if(!error)error=s10_profile_last_error();
 memset(out,0,12);out[0]=(uint8_t)state;out[1]=(uint8_t)(error<0?-error:error);
 out[2]=(uint8_t)(media.rate==44100?1:media.rate==48000?2:0);out[3]=(uint8_t)bus_ready;
 for(unsigned i=0;i<4;i++){out[4+i]=(uint8_t)(epoch>>(8*i));out[8+i]=(uint8_t)(runtime_faults>>(8*i));}
 taskEXIT_CRITICAL();
}



int s10_runtime_media_diag(char *text,unsigned size){
 taskENTER_CRITICAL();
 unsigned long v[16]={media.state,media.rate,(unsigned long)media.claimed_sdus,(unsigned long)media.decoded_pairs,(unsigned long)media.published_pairs,(unsigned long)media.bus_pairs,(unsigned long)media.discarded_pairs,media.errors,media.resyncs,media.stops,
  (unsigned long)transport.state,(unsigned long)transport.committed,(unsigned long)transport.failures,(unsigned long)transport.discarded,(unsigned long)transport.bad_status,(unsigned long)transport.source_rejections};
 long e=media.last_error;int b=bus_ready,mr=media_reserved,fr=file_reserved;unsigned long sr=transport.stale_recoveries,wo=(unsigned long)transport.wire_offset,rp=transport.reprimes,ue=(unsigned long)transport.unexpected_stream_ends,mc=media_cycles/1000000u;media_cycles=0;
 extern volatile uint32_t s10_decode_cycles,s10_resample_cycles;unsigned long dc=s10_decode_cycles/1000000u,rc=s10_resample_cycles/1000000u;s10_decode_cycles=s10_resample_cycles=0;
 taskEXIT_CRITICAL();
 return snprintf(text,size,"A2DP_PIPE st=%lu rate=%lu sdu=%lu dec=%lu pub=%lu bus=%lu disc=%lu errs=%lu resync=%lu stops=%lu last=%ld bus_ready=%d mres=%d fres=%d TX st=%lu commit=%lu fail=%lu disc=%lu bad=%lu rej=%lu stale=%lu woff=%lu reprime=%lu ends=%lu media_mcyc=%lu dec_mcyc=%lu rs_mcyc=%lu",
  v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8],v[9],e,b,mr,fr,v[10],v[11],v[12],v[13],v[14],v[15],sr,wo,rp,ue,mc,dc,rc);
}
