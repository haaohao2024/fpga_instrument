#ifndef STAGE7_BOARD_OVERLAY_H
#define STAGE7_BOARD_OVERLAY_H
// Uses SDK BL616 startup/flash support with known NEO 26MHz crystal.
// Entry address/secondary boot/debugger coexistence intentionally unqualified.
#include "bflb_rtc.h"
#include "board_gpio.h"
#include "board_flash_psram.h"
void board_init(void);
enum bflb_rtc_32k_clk_type board_get_rtc_32k_clk_type(void);
void board_acomp_init(void);
#define DEFAULT_ACOMP_VREF_1V65 33
#endif
