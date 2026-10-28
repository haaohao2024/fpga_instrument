#include <stdint.h>
#ifndef CLOCK_FIX_HOST_TEST
#include "bflb_core.h"
#include "bflb_irq.h"
#include "bl616_hbn.h"
#else
#define ATTR_CLOCK_SECTION
extern int HBN_Get_Xtal_Value(uint32_t *value);
extern uintptr_t bflb_irq_save(void);
extern void bflb_irq_restore(uintptr_t state);
extern uint32_t getreg32(uintptr_t address);
extern void putreg32(uint32_t value,uintptr_t address);
#endif
/* Match SDK wifiPllBasicCfg_26M and wifiPllCfg_960M[GLB_XTAL_26M].
 * This function does not alter PLL power, dividers, voltage, RF package type,
 * USB reset state or MCU clock selection. Default startup never calls it.
 * Explicit F is a controlled causal test after baseline has been recorded. */
int ATTR_CLOCK_SECTION diag_fix_26m_clock(void){
 uint32_t xtal=0;
 if(HBN_Get_Xtal_Value(&xtal)!=0 || xtal!=26000000u)return -1;
 uintptr_t f=bflb_irq_save();
 const uintptr_t address=0x20000828u;
 uint32_t old=getreg32(address);
 if((old&0x03ffffffu)!=0x01276276u){bflb_irq_restore(f);return -2;}
 uint32_t next=old&~((1u<<31)|(1u<<26));
 if(next!=old)putreg32(next,address);
 bflb_irq_restore(f);
 return next==old?1:0;
}
