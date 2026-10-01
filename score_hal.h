#ifndef SCORE_HAL_H
#define SCORE_HAL_H
#include <stdint.h>
// One bus, software selects; implementation must release both before switching.
enum {BUS_NONE=0,BUS_SD=1,BUS_FPGA=2};
int hal_select(int target);
uint8_t hal_exchange(uint8_t value);
void hal_frequency(uint32_t hz);
uint64_t hal_time_us(void);
int hal_cancelled(void);
void hal_delay_us(uint32_t us);
int hal_platform_init(void);
#endif
