/* R59 NEO Dock secondary application. Flash at 0x40000, using the
 * Sipeed debugger >=2025030317 as loader. No boot2/MTD/KV/efuse writes.
 * Offline build verified; physical boot/radio/SPI still require board test. */
#include <stdio.h>
#include "score_hal.h"
#include "s9_runtime.h"
#include "bflb_sec_trng.h"
#include "rfparam_adapter.h"
#include "FreeRTOS.h"
#include "task.h"
#ifndef INSTRUMENT_NEO_SECOND_STAGE
#error Build with the reviewed NEO secondary-application configuration
#endif
volatile int s9_startup_error;
static void application_status(void *unused){
 (void)unused;
 for(;;){
  printf("R59 NEO startup_status=%d (0=tasks created, not link/RF qualification)\r\n",s9_startup_error);
  vTaskDelay(pdMS_TO_TICKS(10000));
 }
}
int main(void){
 if(hal_platform_init()){s9_startup_error=-1;for(;;){}}
 if(rfparam_init(0,0,0)){s9_startup_error=-2;for(;;){}}
 uint64_t identity[2]={0};
 if(bflb_trng_readlen((uint8_t *)identity,sizeof identity)||!identity[0]||!identity[1]){s9_startup_error=-3;for(;;){}}
 /* Keep all original service creation before the scheduler starts. */
 if(s9_runtime_start(identity[0],identity[1])){s9_startup_error=-4;for(;;){}}
 if(xTaskCreate(application_status,"instrument_log",512,0,1,0)!=pdPASS){s9_startup_error=-6;for(;;){}}
 vTaskStartScheduler();s9_startup_error=-5;for(;;){}
}
