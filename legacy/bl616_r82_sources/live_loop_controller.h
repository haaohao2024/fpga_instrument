#ifndef LIVE_LOOP_CONTROLLER_H
#define LIVE_LOOP_CONTROLLER_H
#include "live_loop_wire.h"
/* Owned by ONE protocol task. The hardware bus adapter is synchronous and
 * serialized by the existing bus task; no BLE callback accesses this state. */
typedef struct {
 ll_core core,projection,scratch;
 ll_layer prefix;
 ll_wire_status status;
 ll_wire_batch batch;
 uint64_t target,planned_end,last_exchange_us,last_keep_us,analyzed_end,effective_sample,analyzed_watermark;
 uint32_t analyzed_count;
 uint16_t analyzed_revision;
 uint32_t epoch,next_serial,control_serial,wire_serial,capture_ack,capture_ack_sent,capture_seen,user_sequence;
 uint16_t revision;
 uint8_t user_opcode,user_timbre,control,wire_kind,wire_confirm,opened,discovered;
 uint8_t prefix_active,prefix_saved,sealed,close_wait,auto_seal,notice_dirty;
 uint8_t stop_for_error,result_valid,result_phase,reason;
 uint8_t capture_unknown,capture_incomplete_seen,capture_draining,capture_empty,close_when_drained,late_seen;
 int result_error,last_error;
 uint32_t result_sequence;
 uint8_t pending_wire[LL_WIRE_BYTES];
} ll_controller;
void ll_controller_init(ll_controller *,ll_record *,uint16_t capacity,ll_budget);
int ll_controller_request(ll_controller *,unsigned opcode,uint32_t sequence,unsigned timbre);
/* Return one immutable 204B request, or 0 when idle. Calls producing a
 * request must be paired with response() or transport_failed(). */
int ll_controller_next(ll_controller *,uint64_t now_us,uint8_t tx[LL_WIRE_BYTES]);
int ll_controller_response(ll_controller *,uint64_t now_us,const uint8_t rx[LL_WIRE_BYTES]);
void ll_controller_transport_failed(ll_controller *);
void ll_controller_disconnect(ll_controller *);
void ll_controller_info(const ll_controller *,uint8_t payload[64]);
int ll_controller_active(const ll_controller *);
#endif
