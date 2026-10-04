/* Recording file service has a real deadline, not a drain-to-empty gate.
 * A pending PCM block is serviced first by the caller. Score gets a slot
 * every50ms even while recording backlog is nonzero. Existing100ms player
 * timeout and card service curve remain mandatory, independently checked. */
#ifndef S11_SCHEDULE_CANDIDATE_H
#define S11_SCHEDULE_CANDIDATE_H
#include <stdint.h>
/* Never insert a file-command timeout between already buffered record blocks.
 * Each iteration still polls commands and grants the independent score slot. */
static inline unsigned s11_file_wait_ms(int recording,unsigned pending){
 return recording&&pending>=512u?0u:1u;
}
static inline int s11_score_slot(uint32_t now,uint32_t last,int recording,unsigned pending,int urgent){
 (void)pending;
 return !recording||urgent||(uint32_t)(now-last)>=50;
}
static inline int s11_control_slot(uint32_t now,uint32_t last,int recording,unsigned state,unsigned queued){
 return !recording||state!=2||queued||(uint32_t)(now-last)>=20;
}
#endif
