#ifndef SD_CAPTURE_BUDGET_H
#define SD_CAPTURE_BUDGET_H
#include <stdint.h>
#include "audio_timebase.h"
/* Actual RTL ring:3072 stereo pairs. Reserve6ms for following read/ACK,
 * software and producer phase; this is an admission guard, not a WCET claim.
 * Header captured count freezes at CS start; DMA started_us precedes CS.
 * Only a following new PCM block proves the preceding block was retired. */
typedef struct {uint64_t stamp;uint32_t captured,retired_floor;} sd_capture_budget;
static inline void sd_capture_observe(sd_capture_budget *b,uint64_t stamp,uint32_t captured,uint32_t old_received,uint32_t received){
 if(received>old_received)b->retired_floor=old_received;
 b->captured=captured;b->stamp=stamp;
}
/* Maximum admitted SD interval after preserving the same6ms follow-up
 * reserve. A no-credit writer must choose a fitting complete transaction,
 * rather than demand a receive that cannot run until this writer retires. */
static inline unsigned sd_capture_available_us(const sd_capture_budget *b,uint64_t now){
 if(!b->stamp||now<b->stamp||now-b->stamp>RECORD_PCM_BUFFER_US||b->captured<b->retired_floor)return 0;
 uint32_t queued=b->captured-b->retired_floor;if(queued>=RECORD_PCM_CAPACITY_PAIRS)return 0;
 uint64_t capacity=(uint64_t)(RECORD_PCM_CAPACITY_PAIRS-queued)*1000000u/RECORD_PCM_HZ;
 uint64_t used=now-b->stamp+6000u;
 return capacity>used?(unsigned)(capacity-used):0;
}
static inline int sd_capture_can_lease(const sd_capture_budget *b,uint64_t now,unsigned us){
 return us&&us<=sd_capture_available_us(b,now);
}
#endif
