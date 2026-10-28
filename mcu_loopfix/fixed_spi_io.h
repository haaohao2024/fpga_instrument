#ifndef FIXED_SPI_IO_H
#define FIXED_SPI_IO_H
#include "hardware/spi_reg.h"
#include "hardware/dma_reg.h"
/* BL616 SDK-equivalent register operations after normal SDK initialization.
 * These only support this application's dedicated SPI0/DMA0 channels. */
static inline void fixed_spi_prepare(struct bflb_device_s *d){
 putreg32(getreg32(d->reg_base+SPI_CONFIG_OFFSET)|SPI_CR_SPI_S_3PIN_MODE,d->reg_base+SPI_CONFIG_OFFSET);
 /* The SDK sets these self-clearing FIFO bits in separate calls. Both
  * FIFOs are idle here, so one W1 clear has the same final state. */
 putreg32(getreg32(d->reg_base+SPI_FIFO_CONFIG_0_OFFSET)|SPI_TX_FIFO_CLR|SPI_RX_FIFO_CLR,d->reg_base+SPI_FIFO_CONFIG_0_OFFSET);
}
static inline int fixed_spi_busy(struct bflb_device_s *d){
 uint32_t v=getreg32(d->reg_base+SPI_FIFO_CONFIG_1_OFFSET);
 if(((v&SPI_TX_FIFO_CNT_MASK)>>SPI_TX_FIFO_CNT_SHIFT)<SPI_FIFO_BYTE_NUM_MAX)return 1;
 return getreg32(d->reg_base+SPI_BUS_BUSY_OFFSET)!=0;
}
static inline void fixed_dma_clear(struct bflb_device_s *d){
 putreg32(1u<<d->sub_idx,0x2000c000u+DMA_INTTCCLEAR_OFFSET);
}
static inline void fixed_dma_start(struct bflb_device_s *d){
 putreg32(getreg32(d->reg_base+DMA_CxCONFIG_OFFSET)|DMA_E,d->reg_base+DMA_CxCONFIG_OFFSET);
}
static inline void fixed_spi_dma_link(struct bflb_device_s *d,int enable){
 uint32_t v=getreg32(d->reg_base+SPI_FIFO_CONFIG_0_OFFSET),mask=SPI_DMA_RX_EN|SPI_DMA_TX_EN;
 putreg32(enable?v|mask:v&~mask,d->reg_base+SPI_FIFO_CONFIG_0_OFFSET);
}
static inline int fixed_spi_fifo_error(struct bflb_device_s *d){
 return (getreg32(d->reg_base+SPI_FIFO_CONFIG_0_OFFSET)>>4)&15u;
}
#endif
