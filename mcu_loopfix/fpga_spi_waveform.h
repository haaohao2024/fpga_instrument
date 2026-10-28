#ifndef FPGA_SPI_WAVEFORM_H
#define FPGA_SPI_WAVEFORM_H
#include "bflb_spi.h"
#include "bflb_clock.h"
#include "hardware/spi_reg.h"
extern unsigned fpga_spi_waveform_asymmetric;
/* Diagnostic phase register orientations. Earlier diagram-based mapping
 * did not improve physical CRC results; test BOTH orientations and sample
 * the actual SCK input pad. No field-to-pad polarity is assumed here.
 * Keep their total clock count, extend LOW for FPGA MISO preparation.
 * 160MHz/10MHz: HIGH5 clocks, LOW11 clocks;8MHz:HIGH7,LOW13.
 * Apply only while idle, immediately following SDK initialization.
 */
static inline void fpga_spi_apply_waveform(struct bflb_device_s *spi,uint32_t hz){
 if(fpga_spi_waveform_asymmetric&&(hz==10000000u||hz==8000000u||hz==20000000u)){
  uint32_t total=bflb_clk_get_peripheral_clock(BFLB_DEVICE_TYPE_SPI,spi->idx)/hz;
  uint32_t high=(total+1u)/3u,low=total-high;
  uint32_t word=getreg32(spi->reg_base+SPI_PRD_0_OFFSET);
  if(fpga_spi_waveform_asymmetric==2u){uint32_t swap=high;high=low;low=swap;}
  word=(word&0x0000ffffu)|((high-1u)<<16)|((low-1u)<<24);
  putreg32(word,spi->reg_base+SPI_PRD_0_OFFSET);
 }
}
#endif
