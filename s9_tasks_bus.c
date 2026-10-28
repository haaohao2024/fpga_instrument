/* Only this task calls hardware SPI or sd_bus_* operations. File-task disk
 * calls are synchronous pointer RPCs; buffers remain owned until completion. */
#include "s9_tasks_bus.h"
#include "s9_bus_service.h"
#include "s9_protocol.h"
#include "score_hal.h"
#include "score_service.h"
#include "sd_spi.h"
#include "s11_service.h"
#include "s11_storage.h"
#include "s11_schedule.h"
#include "live_loop_runtime.h"
#include "queue.h"
#ifdef S10_MEDIA_RUNTIME
#include "s10_runtime.h"
#endif
#include <string.h>
#include "link_diag.h"
typedef struct {uint16_t length;uint8_t bytes[192];} command;
typedef struct {
 TaskHandle_t waiter;uint8_t kind,drive,op;void *buffer;const void *payload;
 LBA_t sector;UINT count;uint64_t epoch,argument;uint32_t sequence;int result;
} rpc;
static QueueHandle_t commands,statuses,requests;
static s9_bus_service service;
static volatile int close_requested,open_requested,initialized,disk_abort;
static uint8_t opening_id[16];
static volatile uint32_t peer_deadline;
static int disk_initializing;
extern int score_bus_send(uint8_t,uint64_t,uint32_t,uint64_t,const uint8_t *,unsigned,uint8_t[32]);
int s9_tasks_bus_initialized(void){return initialized;}
void s9_tasks_bus_abort_disk(int value){disk_abort=value;}
int s9_disk_cancelled(void){return disk_abort;}
void s9_tasks_bus_peer_deadline(uint32_t deadline){peer_deadline=deadline;}
static int publish(void *unused,const uint8_t status[64]){(void)unused;return xQueueSend(statuses,status,0)==pdTRUE?0:S9_E_BUSY;}
int s9_tasks_bus_init(void){
 commands=xQueueCreate(4,sizeof(command));statuses=xQueueCreate(8,64);requests=xQueueCreate(2,sizeof(rpc *));
 s9_bus_init(&service,publish,0);return commands&&statuses&&requests?0:-1;
}
int s9_tasks_bus_open(const uint8_t id[16]){
 int r=0;taskENTER_CRITICAL();
 if(open_requested||close_requested)r=S9_E_BUSY;else{memcpy(opening_id,id,16);open_requested=1;}
 taskEXIT_CRITICAL();return r;
}
void s9_tasks_bus_close(void){taskENTER_CRITICAL();close_requested=1;open_requested=0;taskEXIT_CRITICAL();}
int s9_tasks_bus_command(const uint8_t *p,unsigned n){
 if(n>192)return S9_E_LENGTH;
 command c;c.length=(uint16_t)n;memcpy(c.bytes,p,n);
 return xQueueSend(commands,&c,0)==pdTRUE?0:S9_E_BUSY;
}
int s9_tasks_bus_status(uint8_t out[64]){return xQueueReceive(statuses,out,0)==pdTRUE;}
static int loop_exchange(rpc *r){
 if(r->count!=36&&r->count!=548)return S9_E_LENGTH;
 if(s11_service_wire_begin(hal_time_us(),fpga_wire_us(r->count)))return S9_E_BUSY;
 uint64_t began=hal_time_us();hal_frequency(FPGA_SPI_HZ);
 if(hal_select(BUS_FPGA))return S9_E_IO;
 hal_delay_us(1);
 for(unsigned i=0;i<r->count;i++){uint8_t v=hal_exchange(((const uint8_t*)r->payload)[i]);if(i<32)((uint8_t*)r->buffer)[i]=v;}
 hal_delay_us(1);hal_select(BUS_NONE);hal_exchange(255);
 s11_service_wire(hal_time_us(),(uint32_t)(hal_time_us()-began),0);return 0;
}
static void loop_yield_protocol(void){
 UBaseType_t saved=uxTaskPriorityGet(NULL);
 vTaskPrioritySet(NULL,4);taskYIELD();vTaskPrioritySet(NULL,saved);
}
static void loop_window(void){
 /* Only the bus owner calls this with SD released. The active file RPC is
  * outside requests; its sole file-task owner cannot enqueue another FS or
  * score RPC until it completes. Only protocol's kind6 can be pending here. */
 if(disk_initializing||!initialized)return;
#ifdef S10_MEDIA_RUNTIME
 if(s10_runtime_bus_poll())return; /* Never select over an existing DMA. */
#endif
 for(unsigned i=0;i<4;i++){
  rpc *r=0;
  if(xQueuePeek(requests,&r,0)!=pdTRUE){
   /* Also yield when protocol's 1ms delay has just expired during an SD
    * programming-busy loop; otherwise it cannot enqueue its next RPC. */
   if(!ll_runtime_active())return;
   loop_yield_protocol();
   if(xQueuePeek(requests,&r,0)!=pdTRUE)return;
  }
  if(!r||r->kind!=6)return;
  if(xQueueReceive(requests,&r,0)!=pdTRUE)return;
  r->result=loop_exchange(r);
  /* CS and caller's buffer are physically retired before notification.
   * At a long SD RPC the priority5 bus would otherwise starve protocol4.
   * A temporary same-priority yield lets that one owner process its ACK
   * and enqueue the next bounded exchange, with no extra task or sleep. */
  xTaskNotifyGive(r->waiter);loop_yield_protocol();
 }
}
static void control_window(void *unused){
 (void)unused;
 uint64_t began=hal_time_us();
 if(disk_initializing)return; /* Initial/recovery SD entry is maintenance. */
#ifdef S10_MEDIA_RUNTIME
 if(s10_runtime_bus_poll())return; /* Never deassert an in-flight PCM DMA. */
#endif
 if(service.state==2&&(int32_t)((uint32_t)(hal_time_us()/1000)-peer_deadline)>=0){link_diag_event(LD_BUS_TIMEOUT,service.state,(uint32_t)(hal_time_us()/1000),peer_deadline);s9_bus_close(&service);}
 if(close_requested){s9_bus_close(&service);xQueueReset(commands);close_requested=0;}
 if(open_requested&&service.state==0){
  if(!s9_bus_open(&service,opening_id))open_requested=0;
 }
 if(service.state==2&&service.count<S9_BUS_COMMAND_SLOTS){
  command c;if(xQueueReceive(commands,&c,0)==pdTRUE){
   if(s9_bus_enqueue(&service,c.bytes,c.length))s9_bus_close(&service);
  }
 }
 /* Publish an already captured result without adding an idle SPI poll. */
 if((s11_service_active()||ll_runtime_active())&&service.status_pending)s9_bus_step(&service,service.last_step_ms);
 if(!s11_control_slot((uint32_t)(hal_time_us()/1000),service.last_step_ms,s11_service_active()||ll_runtime_active(),service.state,service.count))return;
 unsigned planned=s9_bus_next_bytes(&service,(uint32_t)(hal_time_us()/1000));
 if(planned&&s11_service_wire_begin(hal_time_us(),fpga_wire_us(planned)))return;
 uint32_t transactions=service.transactions;s9_bus_step(&service,(uint32_t)(hal_time_us()/1000));
 if(s11_service_active()&&service.transactions!=transactions&&hal_time_us()>began)s11_service_wire(hal_time_us(),(uint32_t)(hal_time_us()-began),0);
}
#ifdef S10_MEDIA_RUNTIME
int s9_tasks_bus_control_pending(void){
 return close_requested||open_requested||service.count||uxQueueMessagesWaiting(commands)||service.state==1||service.state==3;
}
void s9_tasks_bus_control_service(void){control_window(0);loop_window();}
#endif
static void shared_window(void *unused){
 control_window(unused);loop_window();
#ifdef S10_MEDIA_RUNTIME
 (void)s10_runtime_bus_service();
#endif
}
static int call(rpc *r){
 r->waiter=xTaskGetCurrentTaskHandle();
 if(xQueueSend(requests,&r,portMAX_DELAY)!=pdTRUE)return -1;
 /* No timeout may release the caller's buffer before bus completion. */
 ulTaskNotifyTake(pdTRUE,portMAX_DELAY);return r->result;
}
DSTATUS disk_initialize(BYTE p){rpc r={.kind=0,.drive=p};return (DSTATUS)call(&r);}
DSTATUS disk_status(BYTE p){rpc r={.kind=1,.drive=p};return (DSTATUS)call(&r);}
DRESULT disk_read(BYTE p,BYTE *b,LBA_t s,UINT n){rpc r={.kind=2,.drive=p,.buffer=b,.sector=s,.count=n};return (DRESULT)call(&r);}
DRESULT disk_write(BYTE p,const BYTE *b,LBA_t s,UINT n){rpc r={.kind=3,.drive=p,.payload=b,.sector=s,.count=n};return (DRESULT)call(&r);}
DRESULT disk_ioctl(BYTE p,BYTE cmd,void *b){rpc r={.kind=4,.drive=p,.op=cmd,.buffer=b};return (DRESULT)call(&r);}
int score_send(uint8_t cmd,uint64_t epoch,uint32_t seq,uint64_t arg,const uint8_t *data,unsigned n,uint8_t out[32]){
 rpc r={.kind=5,.op=cmd,.epoch=epoch,.sequence=seq,.argument=arg,.payload=data,.count=n,.buffer=out};return call(&r);
}
int s9_tasks_bus_raw_exchange(const uint8_t *tx,unsigned length,uint8_t rx[32]){
 rpc r={.kind=6,.payload=tx,.buffer=rx,.count=length};return call(&r);
}
void s9_tasks_bus_run(void *unused){
 (void)unused;
#ifdef S10_MEDIA_RUNTIME
 /* DMA bind precedes all polling SPI. If it fails, do not enable media.
  * Local FPGA audio still runs; startup status reports bus_ready=false. */
 /* Bind failure keeps the original control/file service alive. The media
  * runtime records the fault and refuses source admission. */
 (void)s10_runtime_bus_initialize();
 sd_set_service(shared_window,0);
 sd_set_admission(s10_runtime_sd_prepare,s10_runtime_sd_retired,0);
#else
 sd_set_service(shared_window,0);
#endif
 disk_initializing=1;sd_bus_initialize(0);disk_initializing=0;initialized=1;
 for(;;){
  (void)sd_set_recording_mode(s11_service_active()||ll_runtime_active());
  control_window(0);
#ifdef S10_MEDIA_RUNTIME
  /* Retire an existing DMA first. A pending file RPC gets admission before
   * starting another optional media/readback DMA; SD admission itself still
   * services control/PCM while the reservation-based stock gate is not ready. */
  if(s10_runtime_bus_poll()){s10_runtime_bus_wait();continue;}
  if(((!s11_service_active()&&!ll_runtime_active())||!uxQueueMessagesWaiting(requests))&&s10_runtime_bus_service()){s10_runtime_bus_wait();continue;}
#endif
  rpc *r=0;
  if(xQueueReceive(requests,&r,s11_service_active()?0:pdMS_TO_TICKS(1))!=pdTRUE){if(s11_service_active())hal_delay_us(25);continue;}
  switch(r->kind){
   case 0:
    /* FatFs remounts call disk_initialize even when the card is ready.
     * Only an actual card initialization is forbidden during media. */
    if(!(sd_bus_status(r->drive)&STA_NOINIT)){r->result=0;break;}
#ifdef S10_MEDIA_RUNTIME
    if(s10_runtime_media_active()){r->result=STA_NOINIT;break;}
#endif
    if(service.state||open_requested)r->result=STA_NOINIT;
    else {disk_initializing=1;r->result=sd_bus_initialize(r->drive);disk_initializing=0;}
    break;
   case 1:r->result=sd_bus_status(r->drive);break;
   case 2:r->result=sd_bus_read(r->drive,r->buffer,r->sector,r->count);break;
   case 3:
#ifdef S10_MEDIA_RUNTIME
    if(s10_runtime_media_active()&&!s11_storage_write_authorized()){r->result=RES_NOTRDY;break;}
#endif
    r->result=sd_bus_write(r->drive,r->payload,r->sector,r->count);break;
   case 4:
#ifdef S10_MEDIA_RUNTIME
    if(s10_runtime_media_active()&&r->op==CTRL_SYNC&&!s11_storage_write_authorized()){r->result=RES_NOTRDY;break;}
#endif
    r->result=sd_bus_ioctl(r->drive,r->op,r->buffer);break;
   case 5:{
    uint64_t waited=hal_time_us();
    while(s11_service_active()&&s11_service_wire_begin(hal_time_us(),fpga_wire_us(36+r->count))){
     if(hal_time_us()-waited>=20000){s11_service_fail(S11_E_SERVICE,UINT64_MAX);r->result=-1;break;}
#ifdef S10_MEDIA_RUNTIME
     shared_window(0);
#else
     control_window(0);
#endif
     hal_delay_us(25);
    }
    if(hal_time_us()-waited>=20000)break;
    uint64_t began=hal_time_us();hal_frequency(FPGA_SPI_HZ);r->result=score_bus_send(r->op,r->epoch,r->sequence,r->argument,r->payload,r->count,r->buffer);if(s11_service_active())s11_service_wire(hal_time_us(),(uint32_t)(hal_time_us()-began),0);break;
   }
   case 6:r->result=loop_exchange(r);break;
   default:r->result=-1;break;
  }
  xTaskNotifyGive(r->waiter);
 }
}
