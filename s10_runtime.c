#include "sd_spi.h"
/* Runtime connections: one media worker, one SPI owner, one Bluetooth stack.
 * Startup still requires the existing unqualified-board gate; no board action.
 */
#include "s10_runtime.h"
#include "s10_profile.h"
#include "s10_media_pipeline.h"
#include "s10_spi_dma.h"
#include "s10_sd_admission.h"
#include "score_hal.h"
#include "s9_tasks_bus.h"
#include "s11_service.h"
#include "s11_storage.h"
#include "s9_protocol.h"
#include "FreeRTOS.h"
#include "task.h"
#include <string.h>
static s10_media_pipeline media;
static s10_pcm_tx transport;
static s10_spi_dma dma;
static s10_sd_admission admission;
static s10_tx_job job;
static int record_job_ready,record_sd_waiting;
static int prepared,bus_ready,profile_enabled;
static int media_reserved,file_reserved;
static int record_preparing; /* protected by the existing short critical section */
static uint32_t runtime_faults,refill_cancelled;
static TaskHandle_t bus_task;
static uint64_t dma_ticket;
static uint8_t recorder_tx[608] __attribute__((aligned(32)));
static uint8_t recorder_rx[608] __attribute__((aligned(32)));
static int recorder_dma,recorder_media_job;
static unsigned recorder_wire_bytes;
static uint64_t recorder_due;
static unsigned recorder_fraction;
static uint64_t recorder_received;
static void media_task(void *unused){
 (void)unused;
 for(;;){
  s10_profile_step();
  for(unsigned i=0;i<8;i++){int r=s10_media_worker_step(&media);if(r<=0)break;}
  vTaskDelay(pdMS_TO_TICKS(1));
 }
}
int s10_runtime_prepare(void){
 if(prepared)return -1;
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
 taskENTER_CRITICAL();int ready=profile_enabled==1&&bus_ready;taskEXIT_CRITICAL();return ready;
}
int s10_runtime_media_claim(void){
 taskENTER_CRITICAL();
 int r=(!bus_ready||file_reserved)?-1:0;
 if(!r)media_reserved=1;
 taskEXIT_CRITICAL();return r;
}
void s10_runtime_media_release(void){taskENTER_CRITICAL();media_reserved=0;taskEXIT_CRITICAL();}
int s10_runtime_file_enter(void){
 taskENTER_CRITICAL();int r=media_reserved?-1:0;
 if(!r)file_reserved=1;
 taskEXIT_CRITICAL();return r;
}
void s10_runtime_file_leave(void){taskENTER_CRITICAL();file_reserved=0;taskEXIT_CRITICAL();}
int s10_runtime_start_task(void){return prepared&&xTaskCreate(media_task,"s10_media",1024,0,3,0)==pdPASS?0:-1;}
static int contains(const void *base,size_t capacity,const void *ptr,size_t n){
 uintptr_t a=(uintptr_t)base,b=(uintptr_t)ptr;
 return b>=a&&b-a<=capacity&&n<=capacity-(b-a);
}
static int dma_ram(void *unused,const void *p,size_t n){
 (void)unused;
 /* Explicit cache-line allocation whitelist; no arbitrary SRAM/PSRAM casts. */
 if(contains(transport.control_tx,sizeof transport.control_tx,p,n)||contains(transport.control_rx,sizeof transport.control_rx,p,n)||
    contains(dma.tx_lli,sizeof dma.tx_lli,p,n)||contains(dma.rx_lli,sizeof dma.rx_lli,p,n))return 1;
 if(contains(recorder_tx,sizeof recorder_tx,p,n)||contains(recorder_rx,sizeof recorder_rx,p,n))return 1;
 for(unsigned i=0;i<2;i++)if(contains(transport.bank[i].tx,sizeof transport.bank[i].tx,p,n)||contains(transport.bank[i].rx,sizeof transport.bank[i].rx,p,n))return 1;
 return 0;
}
static uint64_t dma_time(void *unused){(void)unused;return hal_time_us();}
static int dma_owner(void *unused){(void)unused;return hal_bus_owner();}
static int dma_select(void *unused,int target){(void)unused;return hal_select(target);}
static void dma_wake(void *owner){
 BaseType_t higher=pdFALSE;
 vTaskNotifyGiveFromISR((TaskHandle_t)owner,&higher);
 portYIELD_FROM_ISR(higher);
}
int s10_runtime_bus_initialize(void){
 s10_dma_binding binding={0,dma_time,dma_owner,dma_select,dma_ram};
 if(!prepared||bus_ready)return -1;
 bus_task=xTaskGetCurrentTaskHandle();
 if(hal_media_dma_bind(&dma,&binding)||s10_spi_dma_set_wakeup(&dma,dma_wake,bus_task)){++runtime_faults;return -1;}
 bus_ready=1;return 0;
}
static void transport_fault(int reason){
 uint64_t epoch=0;int error=0;
 ++runtime_faults;
 if(s10_media_state(&media,&epoch,&error)!=S10_MEDIA_CLOSED)(void)s10_media_stop(&media,epoch,reason);
}
int s10_runtime_bus_poll(void){
 if(!bus_ready)return 0;
 if(dma_ticket){
  int r=s10_spi_dma_poll(&dma,dma_ticket);
  /* Even an error/interrupt is not a memory/CS retirement fence. */
  if(!s10_spi_dma_is_retired(&dma,dma_ticket))return 1;
  int success=r==S10_DMA_DONE;
  if(s10_spi_dma_release(&dma,dma_ticket)){transport_fault(S10_MEDIA_TRANSPORT);return 1;}
  int completed=0;
  if(recorder_dma){
   if(success){int rr=s11_service_response_bytes(recorder_rx,recorder_wire_bytes);if(rr<0&&rr!=S9_E_BUSY&&rr!=S9_E_STALE){s11_service_fail(S11_E_CRC,UINT64_MAX);success=0;}}
   if(success){
    uint64_t received=s11_service_statistics()->received_pcm;
    if(received>recorder_received){
     uint64_t delta=received-recorder_received;
     if(!recorder_received)recorder_due=hal_time_us();
     uint64_t period=delta*1000000u+recorder_fraction;
     recorder_due+=period/48000u;recorder_fraction=(unsigned)(period%48000u);recorder_received=received;
    }
   }
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
 int moved=s10_media_bus_step(&media,&transport);
 if(moved<0&&moved!=S10_MEDIA_BUSY)transport_fault(S10_MEDIA_TRANSPORT);
 if(!s10_pcm_tx_conserved(&transport)||!s10_media_conserved(&media))transport_fault(S10_MEDIA_TRANSPORT);
 return 0;
}
int s10_runtime_bus_service(void){
 if(!bus_ready||s10_runtime_bus_poll())return bus_ready?1:0;
 int record=s11_service_active();
 /* Sole bus owner, after physical DMA retirement and before reserving a new
  * job. Finish any already-reserved job first; do not change its ownership. */
 taskENTER_CRITICAL();
 if(!record&&!record_preparing&&transport.record_feedback&&!record_job_ready&&!transport.dma_active){
  transport.service=(s10_tx_service_config){474,896,2560,32,64,2500};
  transport.record_feedback=transport.record_burst=0;record_sd_waiting=0;
 }
 taskEXIT_CRITICAL();
 if(transport.state==S10_TX_CLOSED&&!record)return 0;
 if(admission.epoch!=transport.epoch){
  if(admission.active||admission.need_refill){transport_fault(S10_MEDIA_TRANSPORT);return 0;}
  s10_sd_admission_init(&admission,transport.epoch);
 }
 int short_ack=record&&s11_service_statistics()->ack_pending&&!s11_service_statistics()->command;
 if(record_job_ready&&job.generation!=transport.generation){(void)s10_pcm_tx_complete(&transport,job.ticket,0,hal_time_us());record_job_ready=0;}
 int demand_status=record&&record_sd_waiting&&!transport.record_burst&&transport.state==S10_TX_PLAY&&transport.data_after_status&&hal_time_us()>=transport.telemetry_us&&hal_time_us()-transport.telemetry_us>=1000;
 int have_media=record_job_ready||(!short_ack&&(demand_status?s10_pcm_tx_status_next(&transport,hal_time_us(),&job):s10_pcm_tx_next(&transport,hal_time_us(),&job))==0);
 if(have_media)record_job_ready=1;
 if(!have_media){
  if(!record||(!short_ack&&hal_time_us()<recorder_due+5334))return 0;
  if(!transport.next_ticket){s11_service_fail(S11_E_GENERATION,UINT64_MAX);return 0;}
  memset(&job,0,sizeof job);
 }
 size_t capacity=job.operation==2?sizeof transport.bank[0].tx:sizeof transport.control_tx;
 int use_record=record&&(!have_media||job.operation==S11_MEDIA_DATA);
 int effective_short=short_ack&&!have_media;
 unsigned planned_bytes=use_record?(effective_short?68u:580u):job.length;
 if(record&&s11_service_wire_begin(hal_time_us(),fpga_wire_us(planned_bytes)))return 0;
 if(!have_media)job.ticket=transport.next_ticket++;
 record_job_ready=0;
 int r;
 if(use_record){
  recorder_wire_bytes=s11_service_request_mode(recorder_tx,have_media?job.tx:0,have_media?job.length:0,effective_short?0:512);memset(recorder_rx,0,sizeof recorder_rx);
  r=s10_spi_dma_begin(&dma,job.ticket,BUS_FPGA,FPGA_SPI_HZ,recorder_tx,sizeof recorder_tx,recorder_rx,sizeof recorder_rx,recorder_wire_bytes,4000);
  recorder_dma=1;recorder_media_job=have_media;

 }else r=s10_spi_dma_begin(&dma,job.ticket,BUS_FPGA,FPGA_SPI_HZ,job.tx,capacity,job.rx,capacity,job.length,4000);
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
 /* Reserve maintenance through real FatFs setup. The bus may run while
  * the file task blocks on RPC, but must not retire a PREPARING mode.
  * No SPI, filesystem operation or scheduler wait is inside this lock. */
 taskENTER_CRITICAL();
 if(record_preparing||file_reserved||media_reserved||s10_runtime_media_active()||transport.state!=S10_TX_CLOSED||dma_ticket||record_job_ready){taskEXIT_CRITICAL();return -1;}
 s10_tx_service_config c=transport.service;c.query_period_us=5000;c.steady_trigger=474;c.mcu_bias_divisor=16;c.mcu_bias_limit=96;
 int r=s10_pcm_tx_service_configure(&transport,&c);
 if(!r){record_preparing=1;file_reserved=1;transport.record_feedback=1;recorder_received=recorder_due=recorder_fraction=0;}
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
void s10_runtime_bus_wait(void){
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
int s10_runtime_sd_prepare(void *unused){
 (void)unused;
 uint64_t began=hal_time_us();
 if(s11_service_active()){
  uint32_t lease=sd_reservation_us();if(!lease||lease>2000)lease=2000;
  record_sd_waiting=1;
  for(;;){
   if(hal_time_us()-began>=20000){record_sd_waiting=0;s11_service_fail(S11_E_SERVICE,UINT64_MAX);return -1;}
   s9_tasks_bus_control_service();if(s10_runtime_bus_poll()){s10_runtime_bus_wait();continue;}
   uint64_t now=hal_time_us();int ready=!s10_runtime_media_active();
   if(!ready&&transport.state==S10_TX_PLAY&&transport.telemetry_valid&&now>=transport.telemetry_us&&transport.stream_state==2){
    uint64_t age=now-transport.telemetry_us;if(age<=UINT64_MAX/48048u){uint64_t product=age*48048u;uint64_t used=product/1000000+(product%1000000!=0)+2;
     ready=used<=transport.stream_buffered&&transport.stream_buffered-used>=256u+(lease*48048u+999999u)/1000000u&&s10_pcm_tx_unsent(&transport)>=512;}
   }
   /* Recording uses only the normal inventory feedback, never SD boost. */
   int r=s11_service_sd_reserve(now,ready,lease);if(!r){record_sd_waiting=0;s10_pcm_tx_sd_request(&transport,0);return 0;}
   if(s10_runtime_bus_service()){s10_runtime_bus_wait();continue;}
   hal_delay_us(25);
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
void s10_runtime_sd_retired(void *unused,uint64_t selected_us){
 (void)unused;
 if(s11_service_active()){
  (void)s11_service_sd_end(hal_time_us(),selected_us);
  /* The record lease is at most2ms and entered with a reserved-use deduction plus256 confirmed pairs.
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



