#ifndef LOOP_EVR_H
#define LOOP_EVR_H
#include "live_loop_core.h"
#include "audio_timebase.h"
/* Captured loop events sit on a 5ms grid and layer boundaries on the same
 * absolute grid, so all layers share it: any 20ms window then holds at most
 * four target times per layer. Held-key pressure is kept once per 50ms bin. */
#define LOOP_GRID AUDIO_MS(5)
#define LOOP_EXPR_GRID AUDIO_MS(50)
typedef struct {uint64_t native_tag,token;uint32_t word,expr_bin;uint8_t valid,captured;} loop_native_slot;
typedef struct {
 loop_native_slot slot[48];uint64_t next_token,record_id,start_frame,seal;
 uint32_t next_sequence;uint8_t started;
} loop_evr;
void loop_evr_init(loop_evr *,uint64_t record_id);
/* Processes every cell, including playback ON replacements. Only live0/2
 * ON in the core's current capture interval creates a new recorded owner. */
int loop_evr_feed(loop_evr *,ll_core *,const uint8_t cell[32]);
void loop_evr_seal(loop_evr *,uint64_t frame);
#endif
