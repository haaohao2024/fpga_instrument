/* Product recording build: retain the diagnostic ABI, without per-byte and
 * interrupt instrumentation. The full implementation remains in the128k
 * root-cause candidate. Transaction ordering/SD errors/CRC are still logged. */
#include "sd_wait_diag.h"
#include <stdio.h>
volatile unsigned sd_wait_active;
void sd_wait_config(unsigned enabled){(void)enabled;sd_wait_active=0;}
void sd_wait_begin(unsigned kind,unsigned command,uint32_t sector){(void)kind;(void)command;(void)sector;}
void sd_wait_end(int outcome){(void)outcome;}
void sd_wait_before(void){}
void sd_wait_after(uint8_t value){(void)value;}
void sd_wait_switch_out(const void *task){(void)task;}
void sd_wait_switch_in(const void *task){(void)task;}
void sd_wait_irq_enter(void){}
void sd_wait_irq_exit(void){}
void sd_wait_report(void){puts("SD_WAIT_META available=0 product_build=1");}
const sd_wait_sample *sd_wait_failure(void){return 0;}
