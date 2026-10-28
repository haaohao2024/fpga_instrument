#include <stdint.h>
#include <stdio.h>
#include "board.h"
#include "score_hal.h"
#include "s9_runtime.h"
#include "bflb_sec_trng.h"
#include "rfparam_adapter.h"
#include "FreeRTOS.h"
#include "task.h"
#include "usb_console.h"
#include "diag_trace.h"
#include "link_diag.h"
#include "wire_probe.h"
extern int r61_board_step(unsigned);
extern volatile unsigned neo_pds_reset_count;
extern volatile int r76_bt_phase,r76_clock_result,r76_gatt_result,r76_adv_result,r76_media_result;
volatile int s9_startup_error;
static volatile unsigned boot_stage;
static volatile uint32_t idle_count;
uint8_t diag_boot_reset_event;
void vApplicationIdleHook(void){++idle_count;}
static void status_task(void *arg){
 (void)arg;TickType_t previous=xTaskGetTickCount();uint32_t old_cycle=0;
 for(;;){
  diag_uart_pump();link_diag_pump();TickType_t now=xTaskGetTickCount();
  if(now-previous>=pdMS_TO_TICKS(2000)){
   uint32_t cycle;__asm__ volatile("rdcycle %0":"=r"(cycle));
   char text[300];
   snprintf(text,sizeof text,"O48FIX128 status tick=%lu boot=%u err=%d bt=%d clock=%d gatt=%d adv=%d media=%d pds=%u idle=%lu cycles=%lu period_ms=%lu stack=%lu\r\n",
    (unsigned long)now,boot_stage,s9_startup_error,r76_bt_phase,r76_clock_result,r76_gatt_result,r76_adv_result,r76_media_result,neo_pds_reset_count,
    (unsigned long)idle_count,(unsigned long)(cycle-old_cycle),(unsigned long)(now-previous),(unsigned long)uxTaskGetStackHighWaterMark(NULL));
   old_cycle=cycle;previous=now;diag_puts(text);printf("%s",text);wire_probe_report();
  }
  vTaskDelay(pdMS_TO_TICKS(5));
 }
}
static void boot_task(void *arg){
 (void)arg;usb_console_init();
 for(unsigned n=11;n<=15;n++){
  boot_stage=n;int rc=r61_board_step(n);
  if(rc){s9_startup_error=rc;goto done;}
 }
 boot_stage=16;s9_startup_error=hal_platform_init();if(s9_startup_error)goto done;
 boot_stage=20;s9_startup_error=rfparam_init(0,0,0);if(s9_startup_error)goto done;
 boot_stage=21;uint64_t identity[2]={0};
 s9_startup_error=bflb_trng_readlen((uint8_t*)identity,sizeof identity);
 if(s9_startup_error||!identity[0]||!identity[1]){if(!s9_startup_error)s9_startup_error=-3;goto done;}
 boot_stage=22;vTaskSuspendAll();
 s9_startup_error=s9_runtime_start(identity[0],identity[1]);
 xTaskResumeAll();boot_stage=s9_startup_error?122:30;
done:
 vTaskDelete(NULL);
}
int main(void){
 boot_stage=1;board_init();boot_stage=10;
 if(xTaskCreate(status_task,"r76_status",1024,0,1,0)!=pdPASS){s9_startup_error=-6;for(;;){}}
 if(xTaskCreate(boot_task,"r76_boot",2048,0,2,0)!=pdPASS){s9_startup_error=-7;for(;;){}}
 vTaskStartScheduler();s9_startup_error=-5;for(;;){}
}
