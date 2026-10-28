#ifndef S9_RUNTIME_H
#define S9_RUNTIME_H
#include <stdint.h>
/* Candidate application integration, not qualified debugger/Flash/RF startup. */
int s9_runtime_start(uint64_t boot_nonce,uint64_t score_epoch_seed);
#endif
