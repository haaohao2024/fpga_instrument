#ifndef SD_WAIT_DIAG_H
#define SD_WAIT_DIAG_H
#include <stdint.h>
/* Cycles are raw CPU cycles, not microseconds. No output in selected windows. */
typedef struct {
 uint32_t kind,command,sector,elapsed,calls,zero,ff,other,last,max_call,max_gap;
 uint32_t excluded,irq_cycles,away_cycles,switches,irqs,max_unexplained,spi,fifo;
} sd_wait_sample;
extern volatile unsigned sd_wait_active;
void sd_wait_config(unsigned enable);
void sd_wait_begin(unsigned kind,unsigned command,uint32_t sector);
void sd_wait_end(int outcome);
void sd_wait_before(void);
void sd_wait_after(uint8_t value);
void sd_wait_switch_out(const void *task);
void sd_wait_switch_in(const void *task);
void sd_wait_irq_enter(void);
void sd_wait_irq_exit(void);
void sd_wait_report(void);
const sd_wait_sample *sd_wait_failure(void);
#endif
