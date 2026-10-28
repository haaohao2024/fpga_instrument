#include "sd_wait_diag.h"
#include "record_hot.h"
#include <stdio.h>
#include <string.h>
#ifdef __riscv
#include "FreeRTOS.h"
#include "task.h"
#include "bflb_spi.h"
#include "bflb_core.h"
#include "hardware/spi_reg.h"
static uint32_t cycles(void){uint32_t n;__asm__ volatile("rdcycle %0":"=r"(n));return n;}
static const void *current(void){return xTaskGetCurrentTaskHandle();}
static uint32_t spi_base;
static uint32_t spi_reg(unsigned offset){return getreg32(spi_base+offset);}
static uint32_t lock(void){uint32_t n;__asm__ volatile("csrrci %0,mstatus,8":"=r"(n)::"memory");return n;}
static void unlock(uint32_t n){if(n&8)__asm__ volatile("csrsi mstatus,8":::"memory");}
#else
#ifdef SD_WAIT_DIAG_CUSTOM_CLOCK
extern uint32_t sd_wait_test_cycles(void),sd_wait_test_reg(unsigned);
extern const void *sd_wait_test_task(void);
#define cycles sd_wait_test_cycles
#define current sd_wait_test_task
#define spi_reg sd_wait_test_reg
#else
#include "score_hal.h"
static uint32_t cycles(void){return (uint32_t)(hal_time_us()*320u);}
static const void *current(void){return (void *)1;}
static uint32_t spi_reg(unsigned offset){(void)offset;return 0;}
#endif
#define SPI_BUS_BUSY_OFFSET 0x1c
#define SPI_FIFO_CONFIG_1_OFFSET 0x84
static uint32_t lock(void){return 0;}
static void unlock(uint32_t n){(void)n;}
#endif
volatile unsigned sd_wait_active;
static unsigned enabled,frozen,away,depth;
static const void *owner;
static sd_wait_sample live,first,longest;
static uint32_t began,accounted,call_start,call_excluded,last_return;
static int first_outcome;
RECORD_HOT static void account(uint32_t now){
 uint32_t n=now-accounted;accounted=now;
 if(away){live.away_cycles+=n;live.excluded+=n;}
 else if(depth){live.irq_cycles+=n;live.excluded+=n;}
}
void sd_wait_config(unsigned enable){
 uint32_t key=lock();enabled=enable;sd_wait_active=frozen=0;first_outcome=0;memset(&first,0,sizeof first);memset(&longest,0,sizeof longest);
#ifdef __riscv
 if(enable)spi_base=bflb_device_get_by_name("spi0")->reg_base;
#endif
 unlock(key);
}
RECORD_HOT void sd_wait_begin(unsigned kind,unsigned command,uint32_t sector){
 if(!enabled||frozen)return;
 uint32_t key=lock();
 memset(&live,0,sizeof live);live.kind=kind;live.command=command;live.sector=sector;
 owner=current();away=depth=0;began=accounted=last_return=cycles();sd_wait_active=1;unlock(key);
}
RECORD_HOT void sd_wait_before(void){
 uint32_t key=lock(),now=cycles();account(now);uint32_t gap=now-last_return;
 if(gap>live.max_gap)live.max_gap=gap;
 call_start=now;call_excluded=live.excluded;unlock(key);
}
RECORD_HOT void sd_wait_after(uint8_t value){
 uint32_t key=lock(),now=cycles();account(now);uint32_t span=now-call_start;
 uint32_t active=span-(live.excluded-call_excluded);
 if(span>live.max_call)live.max_call=span;
 if(active>live.max_unexplained){live.max_unexplained=active;live.spi=spi_reg(SPI_BUS_BUSY_OFFSET);live.fifo=spi_reg(SPI_FIFO_CONFIG_1_OFFSET);}
 live.calls++;if(value==0)live.zero++;else if(value==255)live.ff++;else live.other++;
 live.last=value;last_return=cycles();unlock(key);
}
RECORD_HOT void sd_wait_end(int outcome){
 if(!sd_wait_active)return;
 uint32_t key=lock(),now=cycles();account(now);live.elapsed=now-began;sd_wait_active=0;
 if(live.elapsed>longest.elapsed)longest=live;
 /* outcome0 means the bounded short probe ended busy, not an I/O failure. */
 if(outcome<0&&!frozen){first=live;first_outcome=outcome;frozen=1;}
 unlock(key);
}
RECORD_HOT void sd_wait_switch_out(const void *task){
 uint32_t key=lock();if(sd_wait_active&&task==owner){account(cycles());away=1;live.switches++;}unlock(key);
}
RECORD_HOT void sd_wait_switch_in(const void *task){
 uint32_t key=lock();if(sd_wait_active&&task==owner){account(cycles());away=0;}unlock(key);
}
RECORD_HOT void sd_wait_irq_enter(void){uint32_t key=lock();if(sd_wait_active){account(cycles());depth++;live.irqs++;}unlock(key);}
RECORD_HOT void sd_wait_irq_exit(void){uint32_t key=lock();if(sd_wait_active){account(cycles());if(depth)depth--;}unlock(key);}
const sd_wait_sample *sd_wait_failure(void){return &first;}
static void report(unsigned which,const sd_wait_sample *s){
 printf("SD_WAIT %u %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu %08lx %08lx\r\n",which,
 (unsigned long)s->kind,(unsigned long)s->command,(unsigned long)s->sector,(unsigned long)s->elapsed,
 (unsigned long)s->calls,(unsigned long)s->zero,(unsigned long)s->ff,(unsigned long)s->other,(unsigned long)s->last,
 (unsigned long)s->max_call,(unsigned long)s->max_gap,(unsigned long)s->excluded,(unsigned long)s->irq_cycles,
 (unsigned long)s->away_cycles,(unsigned long)s->switches,(unsigned long)s->irqs,(unsigned long)s->max_unexplained,
 (unsigned long)s->spi,(unsigned long)s->fifo);
}
void sd_wait_report(void){printf("SD_WAIT_META enabled=%u frozen=%u outcome=%d cycles=raw\r\n",enabled,frozen,first_outcome);report(0,&longest);if(frozen)report(1,&first);}
#ifdef __riscv
void __real_interrupt_entry(void);
void __wrap_interrupt_entry(void){sd_wait_irq_enter();__real_interrupt_entry();sd_wait_irq_exit();}
BaseType_t __real_xTaskIncrementTick(void);
BaseType_t __wrap_xTaskIncrementTick(void){sd_wait_irq_enter();BaseType_t r=__real_xTaskIncrementTick();sd_wait_irq_exit();return r;}
#endif
