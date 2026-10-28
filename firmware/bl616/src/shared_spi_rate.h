#ifndef SHARED_SPI_RATE_H
#define SHARED_SPI_RATE_H
#include "fpga_spi_waveform.h"
extern uint32_t shared_spi_peripheral_hz;
/* Fixed master/mode0/8-bit bus. Initial full SDK configuration is installed
 * at platform init and DMA bind. Every rate change occurs with all CS high
 * after actual SPI/DMA retirement, preserving the established data format. */
static inline void shared_spi_rate(struct bflb_device_s *spi,uint32_t hz){
 uint32_t clock=shared_spi_peripheral_hz;
 uint32_t div=(clock/2u*10u/hz+5u)/10u;div=div?div-1u:0u;if(div>255u)div=255u;
 uint32_t word=div*UINT32_C(0x01010101);
 if(fpga_spi_waveform_asymmetric&&(hz==10000000u||hz==8000000u)){
  uint32_t total=clock/hz,high=(total+1u)/3u,low=total-high;
  if(fpga_spi_waveform_asymmetric==2u){uint32_t swap=high;high=low;low=swap;}
  word=(word&0xffffu)|((high-1u)<<16)|((low-1u)<<24);
 }
 putreg32(word,spi->reg_base+SPI_PRD_0_OFFSET);
 word=getreg32(spi->reg_base+SPI_PRD_1_OFFSET);
 word=(word&~SPI_CR_SPI_PRD_I_MASK)|(div<<SPI_CR_SPI_PRD_I_SHIFT);
 putreg32(word,spi->reg_base+SPI_PRD_1_OFFSET);
 /* Software GPIO owns external CS. Continuous internal frames remove only
  * inter-byte idle clocks; bit frequency,phase and packet CS remain intact. */
 word=getreg32(spi->reg_base+SPI_CONFIG_OFFSET)|SPI_CR_SPI_M_CONT_EN;
 putreg32(word,spi->reg_base+SPI_CONFIG_OFFSET);
}
#endif
