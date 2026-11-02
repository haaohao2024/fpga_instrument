// Stage11 passive recording control and shared outbound-prefix ownership.
// Recorder commands never feed performance source cleanup or audio ready.
module r18_recording_subsystem #(parameter integer PCM_BLOCK_PAIRS=128, SERIAL_EVENTS=0, RECORD48=0)(
 input wire pan_applied,input wire[5:0] pan_applied_slot,input wire[314:0] pan_applied_word,
 output wire snapshot_valid,input wire snapshot_ready,
 output wire snapshot_query_valid,input wire snapshot_query_ready,output wire[5:0] snapshot_query_slot,
 input wire snapshot_response_valid,input wire[5:0] snapshot_response_slot,input wire[314:0] snapshot_response_word,
 output wire[63:0] allocated_persistent_id,
 input wire clk,rst,audio_reset,
 input wire record_cmd_valid,
 output wire record_cmd_ready,
 input wire [7:0] record_cmd,
 input wire [63:0] command_record_id,
 input wire [1:0] command_mask,ack_kind,
 input wire [31:0] command_sequence,ack_block_sequence,
 output wire [2:0] record_state,wire_record_state,
 output wire wire_record_incomplete,record_drained,
 output wire [31:0] record_error,
 output reg [63:0] recording_id,
 output reg [1:0] record_mask,
 output reg [31:0] last_command_sequence,rejected_commands,
 output wire record_start_pulse,record_stop_pulse,
 input wire observe_load,
 input wire signed [15:0] observe_l,observe_r,
 input wire [63:0] observe_frame_id,event_frame_id,
 input wire [15:0] event_subcycle,
 input wire allocator_busy,batch_begin,publish_ok,batch_abort,
 input wire[31:0] batch_timestamp,
 input wire fact_valid,input wire[95:0] fact_item,input wire[7:0] fact_outcome,
 input wire[5:0] fact_slot,input wire fact_steal,input wire[314:0] fact_before,fact_after,
 input wire[63:0] fact_frame,input wire[15:0] fact_subcycle,input wire reclaim_batch_busy,
 input wire[63:0] slot_valid,slot_gate,
 input wire cfg_tx_valid,
 input wire [5:0] cfg_tx_count,
 input wire [255:0] cfg_tx_cell,
 output wire [5:0] cfg_tx_index,
 output wire cfg_tx_read_valid,output wire [15:0] cfg_tx_read_epoch,
 input wire cfg_tx_response_valid,input wire [5:0] cfg_tx_response_index,
 input wire [15:0] cfg_tx_response_epoch,
 output wire cfg_tx_ready,cfg_tx_done,
 input wire cfg_fault_valid,
 input wire [7:0] cfg_fault_code,
 input wire [63:0] cfg_first_missing_frame,
 input wire cfg_idle,cfg_quiet,
 output wire capture_caught_up,
 output wire cfg_capture_fault,
 input wire block_request,
 output wire block_valid,
 output reg [1:0] block_kind,
 output wire [31:0] block_sequence,
 output wire [63:0] block_first_frame,
 output wire [15:0] block_items,block_bytes,
 input wire [10:0] peek_byte_address,
 output wire [7:0] peek_byte_data,
 output wire [63:0] captured_pcm_pairs,retired_pcm_pairs,discarded_pcm_pairs,
 output wire [63:0] first_pcm_frame,last_pcm_frame,first_missing_pcm_frame,
 output wire [12:0] buffered_pcm_pairs,
 output wire [63:0] captured_event_cells,retired_event_cells,discarded_event_cells,
 output wire [63:0] first_missing_event_frame,
 output wire [8:0] buffered_event_cells,
 output wire [31:0] published_batches,aborted_batches,applied_items,initial_instances
);
 wire r54_equal_0;
 wire r54_equal_1;
 wire r54_equal_2;

 wire new_start,new_stop;
 wire rec_load,rec_stop,rec_source_fault,rec_owned;
 wire signed[15:0] rec_l,rec_r;wire[63:0] rec_index;
 generate if(RECORD48)begin: record48_branch
  rec48_downsample downsample(.clk(clk),.rst(rst),.audio_reset(audio_reset),
   .start_valid(new_start&&command_mask[0]),.stop_valid(new_stop),
   .observe_load(observe_load),.observe_l(observe_l),.observe_r(observe_r),.observe_frame_id(observe_frame_id),
   .result_valid(rec_load),.result_l(rec_l),.result_r(rec_r),.result_index(rec_index),
   .stop_retired(rec_stop),.source_fault(rec_source_fault),.owned_inflight(rec_owned));
 end else begin: native_recording_branch
  assign rec_load=observe_load;assign rec_l=observe_l;assign rec_r=observe_r;assign rec_index=observe_frame_id;
  assign rec_stop=new_stop;assign rec_source_fault=0;assign rec_owned=0;
 end endgenerate
 wire pcm_start_ready,event_start_ready,observer_idle,exec_pipeline_empty;
 wire pcm_active,pcm_incomplete,event_active,event_incomplete,exec_active,exec_arming,exec_incomplete;
 wire [7:0] pcm_error,event_error,exec_error;
 wire [63:0] pcm_id,event_id,exec_missing,persistent_id_next;
 // Normal observer state is not a missing-position candidate.  If two
 // passive producers fail, preserve the earliest known actual omitted frame.
 wire [63:0] exec_fault_missing=(record_mask[1]&&exec_incomplete)?exec_missing:64'hffffffffffffffff;
 wire [63:0] cfg_fault_missing=(record_mask[1]&&(cfg_fault_valid||event_incomplete||exec_incomplete))?
   cfg_first_missing_frame:64'hffffffffffffffff;
 assign first_missing_event_frame=(exec_fault_missing<cfg_fault_missing)?exec_fault_missing:cfg_fault_missing;
 wire pcm_block_valid,event_block_valid;
 wire [31:0] pcm_block_sequence,event_block_sequence;
 wire [63:0] pcm_block_first,event_block_first;
 wire [15:0] pcm_block_items,event_block_items;
 wire [7:0] pcm_peek,event_peek;
 wire [31:0] pcm_stale_ack,event_stale_ack,pcm_rejected_start,event_rejected_start,event_aborted_cells;
 wire [255:0] exec_tx_cell;
 wire [5:0] exec_count;
 wire exec_valid,exec_ready,exec_done,event_tx_ready,event_tx_done;
 reg [1:0] tx_owner;
 reg [31:0] previous_command;
 reg [7:0] previous_opcode;
 reg have_command;
 reg last_was_pcm;
 // Transport holds the entire command stable until ready. Validate the
 // immutable identity/sequence one cycle before the live commit conditions.
 // No other command can alter recording_id or its sequence while checked.
 reg command_checked,duplicate_q,start_identity_q,identity_q,ordered_q;
 always @(posedge clk)begin
  if(rst)begin command_checked<=0;duplicate_q<=0;start_identity_q<=0;identity_q<=0;ordered_q<=0;end
  else begin
   if(!record_cmd_valid||record_cmd_ready)command_checked<=0;
   else if(!command_checked)begin
    command_checked<=1;
    duplicate_q<=have_command&&r54_equal_0&&r54_equal_1&&record_cmd==previous_opcode&&
      (record_cmd!=1||command_mask==record_mask);
    start_identity_q<=command_record_id!=0&&command_record_id>recording_id;
    identity_q<=r54_equal_0&&recording_id!=0;
    ordered_q<=!have_command||command_sequence==last_command_sequence+1'b1||
      (record_cmd==1&&!r54_equal_0);
   end
  end
 end
 wire duplicate=duplicate_q;
 wire start_eligible=!audio_reset && !rec_source_fault && start_identity_q && command_mask!=0 &&
   pcm_start_ready && event_start_ready && observer_idle && tx_owner==0 && cfg_idle;
 // Evaluate START admission once, before requesting the snapshot. An
 // accepted idle reservation cannot acquire work until the atomic START.
 // QUERY/ACK/STOP retain their existing command path and latency.
 reg start_evaluated,start_admitted;
 always @(posedge clk)begin
  if(rst)begin start_evaluated<=0;start_admitted<=0;end
  else if(!record_cmd_valid||record_cmd_ready)begin start_evaluated<=0;start_admitted<=0;end
  else if(command_checked&&record_cmd==1&&!start_evaluated)begin
   start_evaluated<=1;start_admitted<=start_eligible;
  end
 end
 wire can_start=start_admitted && !audio_reset && (!command_mask[1] || snapshot_ready);
 wire valid_identity=identity_q;
 wire ordered=ordered_q;
 // QUERY/ACK use independent transport sequencing and do not advance START/
 // STOP command sequence. ACK still checks immutable block identity below.
 // A legal START waits for the shared-state freeze boundary. Invalid or
 // duplicate commands keep their original immediate handling. No command
 // is executed repeatedly while the transport holds valid under backpressure.
 wire needs_snapshot=record_cmd==1 && start_evaluated && !duplicate && ordered && start_admitted && !audio_reset && command_mask[1];
 assign snapshot_valid=record_cmd_valid && command_checked && needs_snapshot && !rst;
 assign record_cmd_ready=!rst && command_checked && (record_cmd!=1||start_evaluated) && (!needs_snapshot || snapshot_ready);
 wire command_accept=record_cmd_valid && record_cmd_ready;
 assign new_start=command_accept && !duplicate && record_cmd==1 && can_start && ordered;
 assign new_stop=command_accept && !duplicate && record_cmd==2 && valid_identity && ordered;
 // synthesis translate_off
 always @(posedge clk)if(!rst&&record_cmd_valid&&start_evaluated&&start_admitted&&!audio_reset)
  if(!start_eligible)$fatal(1,"TIMING_START_RESERVATION_LOST");
 // synthesis translate_on
 assign record_start_pulse=new_start;
 assign record_stop_pulse=new_stop;
 // Failure in the event recorder retires its passive CFG producer only.
 // PCM failure must not be mistaken for an event-producer cancellation.
 assign cfg_capture_fault=record_mask[1]&&(event_incomplete||exec_incomplete)&&!new_start;
 wire ack=command_accept && record_cmd==3 && valid_identity;
 wire pcm_ack=ack && ack_kind==1;
 wire event_ack=ack && ack_kind==2;
 wire matching_ack=ack && block_valid && ack_kind==block_kind &&
   r54_equal_2;
 wire pcm_available=record_mask[0] && buffered_pcm_pairs!=0 &&
   (buffered_pcm_pairs>=PCM_BLOCK_PAIRS || !pcm_active);
 wire event_available=record_mask[1] && buffered_event_cells!=0;
 wire choose_pcm=block_request && block_kind==0 && pcm_available &&
   (!event_available || buffered_pcm_pairs>=2048 || !last_was_pcm);
 wire choose_event=block_request && block_kind==0 && !choose_pcm &&
   event_available;
 assign block_valid=(block_kind==1)?pcm_block_valid:(block_kind==2)?event_block_valid:1'b0;
 assign block_sequence=(block_kind==1)?pcm_block_sequence:event_block_sequence;
 assign block_first_frame=(block_kind==1)?pcm_block_first:event_block_first;
 assign block_items=(block_kind==1)?pcm_block_items:event_block_items;
 assign block_bytes=(block_kind==1)?pcm_block_items*4:event_block_items*32;
 assign peek_byte_data=(block_kind==1)?pcm_peek:(block_kind==2)?event_peek:8'd0;
 wire incomplete=(record_mask[0] && pcm_incomplete) ||
   (record_mask[1] && (event_incomplete || exec_incomplete));
 // A capture fault is diagnostic immediately, but it is not a transport
 // EOF until both recorder prefixes and all accepted staging have drained.
 assign record_drained=buffered_pcm_pairs==0 && buffered_event_cells==0 &&
   observer_idle && tx_owner==0 && cfg_idle && block_kind==0 &&
   !(record_mask[0] && pcm_active);
 assign capture_caught_up=recording_id!=0&&record_mask[1]&&exec_active&&!incomplete&&
   exec_pipeline_empty&&cfg_quiet&&tx_owner==0&&buffered_event_cells==0&&block_kind==0&&
   !allocator_busy&&!batch_begin&&!publish_ok&&!fact_valid&&!pan_applied;
 assign wire_record_incomplete=incomplete;
 assign wire_record_state=incomplete && !record_drained ? 3'd3 : record_state;
 assign record_error=(record_mask[0] && pcm_incomplete)?{24'd0,pcm_error}:
   (record_mask[1] && event_incomplete)?{24'd0,event_error}:
   (record_mask[1] && exec_incomplete)?{24'd0,exec_error}:0;
 assign record_state=recording_id==0?3'd0:incomplete?3'd5:exec_arming?3'd1:
   ((record_mask[0] && pcm_active)||(record_mask[1] && exec_active))?3'd2:
   (buffered_pcm_pairs!=0 || buffered_event_cells!=0 || !observer_idle || tx_owner!=0 ||
    (record_mask[1] && !cfg_idle))?3'd3:3'd4;
 wire choose_exec=tx_owner==0 && exec_valid;
 wire choose_cfg=tx_owner==0 && !exec_valid && cfg_tx_valid && record_mask[1] && !incomplete && (!exec_arming || cfg_tx_count==16);
 wire event_tx_valid=choose_exec || choose_cfg;
 // Selection depends on ownership/priority, not CFG count eligibility.
 // When idle with no EXEC, an invalid CFG's count is don't-care: choose_cfg
 // still gates acceptance. This removes count -> eligibility -> count mux.
 wire selected_cfg=tx_owner==2 || (tx_owner==0 && !exec_valid);
 wire [5:0] event_tx_count=selected_cfg?cfg_tx_count:exec_count;
 wire [255:0] event_tx_cell=(tx_owner==2 || choose_cfg)?cfg_tx_cell:exec_tx_cell;
 wire [5:0] event_tx_index,event_prefetch_index;
 wire event_prefetch_valid,event_ram_write_enable;
 wire [15:0] prefetch_epoch;
 wire batch_accept=event_tx_valid&&event_tx_ready;
 wire [15:0] request_epoch;
 wire [1:0] request_owner=tx_owner!=0?tx_owner:exec_valid?2'd1:2'd2;
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(event_tx_valid && event_tx_count!==((tx_owner==2||choose_cfg)?cfg_tx_count:exec_count))
   $fatal(1,"MARGIN_BATCH_COUNT_EQ");
  if(event_prefetch_valid && request_owner!==(tx_owner!=0?tx_owner:choose_cfg?2'd2:2'd1))
   $fatal(1,"MARGIN_REQUEST_OWNER_EQ");
 end
 // synthesis translate_on
 wire exec_read_valid=event_prefetch_valid&&request_owner==1;
 wire exec_response_valid;wire [5:0] exec_response_index;wire [15:0] exec_response_epoch;
 assign cfg_tx_read_valid=event_prefetch_valid&&request_owner==2;
 assign cfg_tx_read_epoch=request_epoch;
 wire [1:0] response_owner=(tx_owner==2||choose_cfg)?2'd2:2'd1;
 wire response_pulse=response_owner==2?cfg_tx_response_valid:exec_response_valid;
 wire [5:0] response_index=response_owner==2?cfg_tx_response_index:exec_response_index;
 wire [15:0] response_epoch=response_owner==2?cfg_tx_response_epoch:exec_response_epoch;
 r18_cell_prefetch_control #(.VARIABLE_RESPONSE(SERIAL_EVENTS)) prefetch_control(.clk(clk),.rst(rst),.clear_valid(1'b0),
  .batch_accept(batch_accept),.request_valid(event_prefetch_valid),.request_owner(request_owner),.request_index(event_prefetch_index),
  .response_pulse(response_pulse),.response_owner(response_owner),.response_index(response_index),.response_epoch(response_epoch),
  .consume_valid(event_ram_write_enable),.consume_owner(tx_owner),.consume_index(event_tx_index),.consume_cell(event_tx_cell),
  .request_epoch(request_epoch),.active_epoch(prefetch_epoch));
 // Both passive producers expose the requested immutable cell.

 assign cfg_tx_index=event_prefetch_index;
 assign exec_ready=choose_exec && event_tx_ready;
 assign cfg_tx_ready=choose_cfg && event_tx_ready;
 assign exec_done=event_tx_done && tx_owner==1;
 assign cfg_tx_done=event_tx_done && tx_owner==2;
 always @(posedge clk)begin
  if(rst)begin recording_id<=0;record_mask<=0;last_command_sequence<=0;
   rejected_commands<=0;previous_command<=0;previous_opcode<=0;have_command<=0;
   block_kind<=0;tx_owner<=0;last_was_pcm<=0;end
  else begin
   if(new_start)begin
    recording_id<=command_record_id;record_mask<=command_mask;last_command_sequence<=command_sequence;
    previous_command<=command_sequence;previous_opcode<=record_cmd;have_command<=1;
   end else if(new_stop)begin
    last_command_sequence<=command_sequence;previous_command<=command_sequence;previous_opcode<=record_cmd;
   end else if(command_accept && record_cmd!=0 && record_cmd!=3 && !duplicate)
    rejected_commands<=rejected_commands+1;
   if(choose_pcm)block_kind<=1;
   else if(choose_event)block_kind<=2;
   if(matching_ack)begin block_kind<=0;last_was_pcm<=block_kind==1;end
   if(event_tx_valid && event_tx_ready)tx_owner<=choose_cfg?2'd2:2'd1;
   if(event_tx_done)tx_owner<=0;
  end
 end
 s11_pcm_recorder #(.TRUSTED_ACK(1),.BLOCK_PAIRS(PCM_BLOCK_PAIRS)) u_pcm(.clk(clk),.rst(rst),.audio_reset(audio_reset||rec_source_fault),
  .start_valid(new_start && command_mask[0]),.stop_valid(rec_stop),.clear_valid(1'b0),
  .start_record_id(command_record_id),.start_ready(pcm_start_ready),.observe_load(rec_load),
  .observe_l(rec_l),.observe_r(rec_r),.observe_frame_id(rec_index),
  .active(pcm_active),.incomplete(pcm_incomplete),.error_code(pcm_error),.record_id(pcm_id),
  .first_frame_id(first_pcm_frame),.last_frame_id(last_pcm_frame),
  .captured_pairs(captured_pcm_pairs),.retired_pairs(retired_pcm_pairs),.discarded_pairs(discarded_pcm_pairs),
  .first_missing_frame(first_missing_pcm_frame),.buffered_pairs(buffered_pcm_pairs),
  .block_request(choose_pcm),.block_valid(pcm_block_valid),.block_sequence(pcm_block_sequence),
  .block_first_frame(pcm_block_first),.block_pair_count(pcm_block_items),
  .peek_byte_address(peek_byte_address),.peek_byte_data(pcm_peek),.ack_accepted(matching_ack&&ack_kind==1),.ack_valid(pcm_ack),
  .ack_record_id(command_record_id),.ack_block_sequence(ack_block_sequence),
  .stale_ack_count(pcm_stale_ack),.rejected_start_count(pcm_rejected_start));
 r28_execution_observer u_exec(.pan_applied(pan_applied),.pan_applied_slot(pan_applied_slot),.pan_applied_word(pan_applied_word),.clk(clk),.rst(rst),.audio_reset(audio_reset),
  .capture_fault((event_incomplete || cfg_fault_valid) && !new_start),
  .capture_fault_code(cfg_fault_valid?cfg_fault_code:event_error),.stop_delivery_idle(cfg_idle && tx_owner!=2),
  .start_valid(new_start && command_mask[1]),.stop_valid(new_stop),.start_record_id(command_record_id),
  .frame_id(event_frame_id),.subcycle(event_subcycle),.allocator_busy(allocator_busy),
  .batch_begin(batch_begin),.publish_ok(publish_ok),.batch_abort(batch_abort),.batch_timestamp(batch_timestamp),
  .fact_valid(fact_valid),.fact_item(fact_item),.fact_outcome(fact_outcome),.fact_slot(fact_slot),.fact_steal(fact_steal),
  .fact_before(fact_before),.fact_after(fact_after),.fact_frame(fact_frame),.fact_subcycle(fact_subcycle),.reclaim_batch_busy(reclaim_batch_busy),
  .slot_valid(slot_valid),.slot_gate(slot_gate),.allocated_persistent_id(allocated_persistent_id),
  .snapshot_query_valid(snapshot_query_valid),.snapshot_query_ready(snapshot_query_ready),.snapshot_query_slot(snapshot_query_slot),
  .snapshot_response_valid(snapshot_response_valid),.snapshot_response_slot(snapshot_response_slot),.snapshot_response_word(snapshot_response_word),
  .active(exec_active),.arming(exec_arming),.incomplete(exec_incomplete),.error_code(exec_error),.first_missing_frame(exec_missing),
  .tx_valid(exec_valid),.tx_count(exec_count),.tx_index(event_prefetch_index),.tx_cell(exec_tx_cell),
  .tx_read_valid(exec_read_valid),.tx_read_epoch(request_epoch),.tx_response_valid(exec_response_valid),
  .tx_response_index(exec_response_index),.tx_response_epoch(exec_response_epoch),.tx_ready(exec_ready),.tx_done(exec_done),
  .published_batches(published_batches),.aborted_batches(aborted_batches),.applied_items(applied_items),.initial_instances(initial_instances),
  .persistent_id_next(persistent_id_next),.observer_idle(observer_idle),.pipeline_empty(exec_pipeline_empty));
 s11_event_recorder #(.TRUSTED_ACK(1),.VARIABLE_RESPONSE(SERIAL_EVENTS)) u_events(.tx_response_valid(response_pulse),.clk(clk),.rst(rst),
  .start_valid(new_start && command_mask[1]),.stop_valid(new_stop),.clear_valid(1'b0),
  .start_record_id(command_record_id),.start_ready(event_start_ready),.active(event_active),
  .incomplete(event_incomplete),.error_code(event_error),.record_id(event_id),
  .tx_valid(event_tx_valid),.tx_count(event_tx_count),.tx_cell(event_tx_cell),.tx_index(event_tx_index),
  .tx_ready(event_tx_ready),.tx_done(event_tx_done),
  .observe_write_enable(event_ram_write_enable),.prefetch_req_valid(event_prefetch_valid),.prefetch_req_index(event_prefetch_index),
  .fault_valid((exec_incomplete || cfg_fault_valid) && record_mask[1] && !new_start),
  .fault_code(cfg_fault_valid?cfg_fault_code:exec_error),
  .captured_cells(captured_event_cells),.retired_cells(retired_event_cells),
  .discarded_cells(discarded_event_cells),.buffered_cells(buffered_event_cells),
  .aborted_transaction_cells(event_aborted_cells),.block_request(choose_event),
  .block_valid(event_block_valid),.block_sequence(event_block_sequence),
  .block_first_frame(event_block_first),.block_cell_count(event_block_items),
  .peek_byte_address(peek_byte_address[8:0]),.peek_byte_data(event_peek),.ack_accepted(matching_ack&&ack_kind==2),.ack_valid(event_ack),
  .ack_record_id(command_record_id),.ack_block_sequence(ack_block_sequence),
  .stale_ack_count(event_stale_ack),.rejected_start_count(event_rejected_start));
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(pcm_block_valid&&(block_kind!=1||pcm_id!=recording_id))$fatal(1,"R54_PCM_PREFIX_OWNER");
  if(event_block_valid&&(block_kind!=2||event_id!=recording_id))$fatal(1,"R54_EVENT_PREFIX_OWNER");
 end
 always @(posedge clk)if(!rst)begin
  if($isunknown({record_cmd_valid,block_request,cfg_tx_valid,cfg_fault_valid}))
   $fatal(1,"S11_SUBSYSTEM_CONTROL_XZ");
  if(cfg_fault_valid && $isunknown({cfg_fault_code,cfg_first_missing_frame}))
   $fatal(1,"S11_SUBSYSTEM_CFG_FAULT_XZ");
  if(record_cmd_valid && $isunknown({record_cmd,command_record_id,command_mask,
      command_sequence,ack_kind,ack_block_sequence}))$fatal(1,"S11_SUBSYSTEM_COMMAND_XZ");
 end
 // synthesis translate_on
 r54_full_equal #(.WIDTH(64)) r54_equal_0_tree(.a(command_record_id),.b(recording_id),.equal(r54_equal_0));
 r54_full_equal #(.WIDTH(32)) r54_equal_1_tree(.a(command_sequence),.b(previous_command),.equal(r54_equal_1));
 r54_full_equal #(.WIDTH(32)) r54_equal_2_tree(.a(ack_block_sequence),.b(block_sequence),.equal(r54_equal_2));
 // synthesis translate_off
 reg command_waiting;reg[139:0] held_command;
 wire[139:0] command_bits={record_cmd,command_record_id,command_mask,ack_kind,command_sequence,ack_block_sequence};
 always @(posedge clk)begin
  if(rst)command_waiting<=0;
  else begin
   if(command_waiting&&(!record_cmd_valid||command_bits!==held_command))$fatal(1,"RECORD_COMMAND_CHANGED_UNDER_BACKPRESSURE");
   command_waiting<=record_cmd_valid&&!record_cmd_ready;
   held_command<=command_bits;
  end
 end
 // synthesis translate_on
endmodule
