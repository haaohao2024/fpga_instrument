#ifndef RECORD_HOT_H
#define RECORD_HOT_H
#if defined(__riscv)
#define RECORD_HOT __attribute__((section(".tcm_code.record"),optimize("O2")))
#include <stdint.h>
#include "bflb_l1c.h"
#define RECORD_DMA_PTR(p) (p)
#define RECORD_DMA_PREPARE(p) bflb_l1c_dcache_clean_invalidate_range((p),sizeof(p))
#define RECORD_CONST __attribute__((section(".tcm_const.record")))
#else
#define RECORD_HOT
#define RECORD_CONST
#define RECORD_DMA_PTR(p) (p)
#define RECORD_DMA_PREPARE(p) ((void)sizeof(p))
#endif
#endif
