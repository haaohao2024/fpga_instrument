#ifndef RECORD_TIMING_H
#define RECORD_TIMING_H
#include <stdint.h>
/* Diagnostic-only. Sole SPI owner; no printing or application state changes. */
void record_timing(unsigned kind,uint32_t a,uint32_t b,uint32_t c);
#endif
