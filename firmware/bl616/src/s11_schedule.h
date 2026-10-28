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
 return recording&&pending>=4096u?0u:1u;
}
static inline int s11_score_slot(uint32_t now,uint32_t last,int recording,unsigned pending,int urgent){
 (void)pending;
 return !recording||urgent||(uint32_t)(now-last)>=50;
}
/* An idle open phone link polls the FPGA every 5 ms (20 ms while recording):
 * a 204-byte PIO step every 1 ms took two thirds of the CPU. Queued phone
 * commands and link open/close still step immediately. */
static inline int s11_control_slot(uint32_t now,uint32_t last,int recording,unsigned state,unsigned queued){
 /* While recording, an idle link only needs result polls and the 100 ms
  * keepalive; 50 ms keeps keepalives on time and frees bus time for SD. */
 return state!=2||queued||(uint32_t)(now-last)>=(recording?50u:5u);
}
#endif
