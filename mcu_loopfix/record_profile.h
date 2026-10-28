#ifndef RECORD_PROFILE_H
#define RECORD_PROFILE_H
#include <stdint.h>
static inline uint32_t record_profile_cycles(void){
#if defined(__riscv)
 uint32_t n;__asm__ volatile("rdcycle %0":"=r"(n));return n;
#else
 return 0;
#endif
}
#define record_profile_add(...) ((void)0)
#define record_profile_reset() ((void)0)
#define record_profile_report() ((void)0)
#endif
