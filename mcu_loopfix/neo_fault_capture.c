#include "diag_trace.h"
#include "FreeRTOS.h"
#include "task.h"
void __wrap_btble_assert_err(uintptr_t a,uintptr_t b,uintptr_t c){diag_fatal("CONTROLLER_ASSERT",(uintptr_t)__builtin_return_address(0),a,b,c);}
void __wrap___assert_func(const char *file,int line,const char *func,const char *expr){(void)func;diag_fatal("C_ASSERT",(uintptr_t)__builtin_return_address(0),(uintptr_t)file,line,(uintptr_t)expr);}
void __real_exception_entry(uintptr_t *regs);
void __wrap_exception_entry(uintptr_t *regs){
 uintptr_t cause,pc,tval;__asm__ volatile("csrr %0,mcause":"=r"(cause));
 __asm__ volatile("csrr %0,mepc":"=r"(pc));__asm__ volatile("csrr %0,mtval":"=r"(tval));
 if((cause&0x3ff)==8 || (cause&0x3ff)==11){__real_exception_entry(regs);return;}
 diag_fatal("CPU_EXCEPTION",pc,cause,tval,(uintptr_t)regs);
}
void vAssertCalled(void){diag_fatal("RTOS_ASSERT",(uintptr_t)__builtin_return_address(0),0,0,0);}
void vApplicationStackOverflowHook(TaskHandle_t t,char *n){diag_fatal("STACK_OVERFLOW",(uintptr_t)__builtin_return_address(0),(uintptr_t)t,(uintptr_t)n,0);}
void vApplicationMallocFailedHook(void){diag_fatal("OUT_OF_MEMORY",(uintptr_t)__builtin_return_address(0),0,0,0);}
