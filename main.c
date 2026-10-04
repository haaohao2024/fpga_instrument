/* Candidate entry. Boot/debugger ABI, Flash partition and RF calibration are
 * unqualified for this Dock. The board gate awaits board-integration approval.
 * Volatile preserves the complete linked application for map auditing. */
#include "score_hal.h"
#include "s9_runtime.h"
#include "bflb_sec_trng.h"
#include "bflb_mtd.h"
#include "rfparam_adapter.h"
#include "FreeRTOS.h"
#include "task.h"
volatile const unsigned s9_board_startup_confirmed=0;
volatile int s9_startup_error;
int main(void){
 if(!s9_board_startup_confirmed){s9_startup_error=-100;for(;;){}}
 if(hal_platform_init()){s9_startup_error=-1;for(;;){}}
 bflb_mtd_init();
 /* Persistent pairing is disabled. Do not initialize a guessed KV region. */
 if(rfparam_init(0,0,0)){s9_startup_error=-2;for(;;){}}
 uint64_t identity[2]={0};
 if(bflb_trng_readlen((uint8_t *)identity,sizeof identity)||!identity[0]||!identity[1]){s9_startup_error=-3;for(;;){}}
 if(s9_runtime_start(identity[0],identity[1])){s9_startup_error=-4;for(;;){}}
 vTaskStartScheduler();s9_startup_error=-5;for(;;){}
}
