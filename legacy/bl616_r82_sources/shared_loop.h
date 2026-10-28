#ifndef SHARED_LOOP_H
#define SHARED_LOOP_H
#include "live_loop_core.h"
#include "loop_evr.h"
#include "shared_raw.h"
#include "shared_score.h"
#include "ensemble.h"
enum {SL_BEGIN=0x60,SL_END=0x61,SL_UNDO=0x62,SL_STOP=0x63,SL_CLEAR=0x64,SL_STATUS=0x65,SL_PLAY=0x66};
typedef struct {raw_item item;ll_delivery loop;ss_event score;uint8_t is_score;} sl_item;
typedef struct {
 ll_core core,projection,compose,scout;
 ll_budget base_budget;
 ss_cursor score,compose_score,scout_score;
 uint32_t compose_ai,scout_ai;ens_config ai_config;
 loop_evr evr;raw_status status;
 sl_item row[9];ll_layer prefix;
 uint8_t page[512],pending_wire[548],row_head[16];
 uint64_t now,last_queued,page_last_target,planned_end,effective,start_target,control_target,end_target;
 uint64_t last_poll_us,last_keep_us,analyzed_end,analyzed_watermark,clock_seed;
 uint32_t epoch,epoch_cursor,page_sequence,barrier_counter,control_barrier,end_barrier,user_sequence,result_sequence;
 uint16_t control_revision,analyzed_revision,pending_failed_revision;
 uint8_t row_count,row_index,row_head_sent,row_last,group_open,page_pending,page_confirm,wire_kind,opened,clock_valid,clock_seeded;
 uint8_t control_action,control_layer,control_sources,control_all,control_guide,control_packed,control_applied;
 uint8_t user_opcode,user_timbre,user_actioned,result_valid,result_phase,notice_dirty,reason;
 uint8_t prefix_active,prefix_saved,close_wait,ram_started,capture_error_latched,fault_closing,opening,score_starting,score_end_packed;
 int result_error,last_error;
} shared_loop_controller;
void sl_init(shared_loop_controller *,ll_record *,uint32_t *phase,uint16_t capacity,uint32_t epoch_seed,ll_budget);
int sl_ensemble_request(shared_loop_controller *,unsigned opcode,uint32_t sequence,const ens_config *);
int sl_request(shared_loop_controller *,unsigned opcode,uint32_t sequence,unsigned timbre);
int sl_next(shared_loop_controller *,uint64_t now_us,uint8_t out[548]);
int sl_response(shared_loop_controller *,uint64_t now_us,const uint8_t status[32],int capture_local_empty);
void sl_transport_failed(shared_loop_controller *);
void sl_capture_begin(shared_loop_controller *,uint64_t record_id);
int sl_capture_cell(shared_loop_controller *,const uint8_t cell[32]);
void sl_capture_fault(shared_loop_controller *,int error);
int sl_capture_flush(shared_loop_controller *);
void sl_disconnect(shared_loop_controller *);
int sl_active(const shared_loop_controller *);
void sl_info(const shared_loop_controller *,uint8_t payload[64]);
#endif
