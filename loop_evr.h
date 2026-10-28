#ifndef LOOP_EVR_H
#define LOOP_EVR_H
#include "live_loop_core.h"
typedef struct {uint64_t native_tag,token;uint32_t word;uint8_t valid,captured;} loop_native_slot;
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
