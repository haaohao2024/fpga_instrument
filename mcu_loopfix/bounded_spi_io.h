#ifndef BOUNDED_SPI_IO_H
#define BOUNDED_SPI_IO_H
#include <stdint.h>
#include "bflb_core.h"
/* Dedicated 8-bit SPI0 path; same FIFO streaming as the SDK, bounded by an
 * absolute caller deadline. A timeout quarantines the bus without clearing
 * FIFO, changing CS, or pretending that outstanding traffic retired. */
int bounded_spi_byte(struct bflb_device_s *,uint8_t,uint64_t,uint8_t *);
int bounded_spi_block(struct bflb_device_s *,const uint8_t *,uint8_t *,unsigned,uint64_t);
int bounded_spi_idle(struct bflb_device_s *,uint64_t);
#endif
