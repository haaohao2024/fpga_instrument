#ifndef SCORE_HAL_H
#define SCORE_HAL_H
#include <stdint.h>
#define FPGA_SPI_HZ 5000000u
/* Ceil wire duration plus the existing CS/setup allowance. */
static inline uint32_t fpga_wire_us(uint32_t bytes){return (uint32_t)(((uint64_t)bytes*8u*1000000u+FPGA_SPI_HZ-1)/FPGA_SPI_HZ+4u);}
// One bus, software selects; implementation must release both before switching.
enum {BUS_NONE=0,BUS_SD=1,BUS_FPGA=2,BUS_CONTROL=3};
int hal_select(int target);
uint8_t hal_exchange(uint8_t value);
void hal_frequency(uint32_t hz);
uint64_t hal_time_us(void);
int hal_cancelled(void);
void hal_delay_us(uint32_t us);
int hal_platform_init(void);
#ifdef S10_MEDIA_RUNTIME
#include "s10_spi_dma.h"
int hal_bus_owner(void);
int hal_media_dma_bind(s10_spi_dma *,const s10_dma_binding *);
#endif
#endif
