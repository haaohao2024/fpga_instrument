#ifndef LIVE_LOOP_WIRE_H
#define LIVE_LOOP_WIRE_H
#include "live_loop_core.h"
#define LL_WIRE_BYTES 204u
#define LL_WIRE_VERSION 4u
#define LL_WIRE_EVENTS 7u
#define LL_WIRE_CONTROL 8u
#define LL_WIRE_POLL 9u
enum {LL_CTL_OPEN=1,LL_CTL_KEEP=2,LL_CTL_STOP=3,LL_CTL_RELEASE_REV=4,
      LL_CTL_CAPTURE_ON=5,LL_CTL_CAPTURE_SEAL=6,LL_CTL_CAPTURE_OFF=7};
enum {LL_APP_BEGIN=0x60,LL_APP_END=0x61,LL_APP_UNDO=0x62,
      LL_APP_STOP=0x63,LL_APP_CLEAR=0x64,LL_APP_STATUS=0x65,LL_APP_PLAY=0x66,
      LL_APP_INFO=0x83};
typedef struct {uint64_t frame,token;uint32_t word;uint8_t timbre,flags;} ll_capture_cell;
typedef struct {
    uint64_t now,watermark,effective_sample,first_missing;
    uint32_t epoch,accepted_serial,effective_control_serial,capture_sequence;
    int16_t error;
    uint8_t state,credit,flags,count;
    ll_capture_cell cell[2];
} ll_wire_status;
typedef struct {ll_delivery item[9];uint32_t serial;uint8_t count,group_end,active;} ll_wire_batch;
int ll_wire_control(uint8_t tx[LL_WIRE_BYTES],uint32_t epoch,uint32_t serial,uint8_t subop,uint16_t revision,uint32_t target);
/* max_count affects only the next new block. An offered seq/count/payload
 * stays frozen until exact ACK; epoch0 discovery never changes its limit. */
int ll_wire_poll(uint8_t tx[LL_WIRE_BYTES],uint32_t epoch,uint32_t ack_capture,unsigned max_count);
int ll_wire_decode(const uint8_t rx[LL_WIRE_BYTES],ll_wire_status *);
/* Scratch contains only cursors/owners; the 96 KiB arena is never copied.
 * Do not mutate the batch/core until an exact accepted_serial ACK arrives.
 * Poll more often than the bounded prefetch deadline; retries reuse tx. */
int ll_wire_prepare(ll_core *,ll_core *scratch,uint64_t through,uint32_t epoch,uint32_t serial,
                    uint8_t tx[LL_WIRE_BYTES],ll_wire_batch *);
int ll_wire_accept(ll_core *,ll_wire_batch *,uint32_t accepted_serial);
#endif
