// Stage11 passive recording control and shared outbound-prefix ownership.
// Recorder commands never feed performance source cleanup or audio ready.
module s11_recording_subsystem(
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
 input wire allocator_busy,batch_begin,publish_ok,batch_abort,apply_valid,
 input wire [31:0] batch_timestamp,
 input wire [3:0] apply_lane,
 input wire [95:0] apply_item,
 input wire [7:0] apply_outcome,
 input wire [5:0] apply_slot,
 input wire [63:0] apply_id,
 input wire [15:0] apply_generation,
 input wire [2:0] apply_timbre,
 input wire apply_steal,
 input wire [63:0] retired_id,
 input wire [15:0] retired_generation,
 input wire [31:0] reclaim_mask,
 input wire [2047:0] reclaim_ids,
 input wire [511:0] reclaim_generations,
 input wire [31:0] slot_valid,slot_gate,
 input wire [223:0] slot_notes,
 input wire [255:0] slot_pressures,slot_keys,
 input wire [127:0] slot_sources,
 input wire [2047:0] slot_ids,slot_tokens,
 input wire [511:0] slot_generations,
 input wire [95:0] slot_timbres,
 input wire [287:0] slot_pans,
 input wire cfg_tx_valid,
 input wire [5:0] cfg_tx_count,
 input wire [10239:0] cfg_tx_cells,
 output wire cfg_tx_ready,cfg_tx_done,
 input wire cfg_fault_valid,
 input wire [7:0] cfg_fault_code,
 input wire [63:0] cfg_first_missing_frame,
 input wire cfg_idle,
 output wire cfg_capture_fault,
 input wire block_request,
 output wire block_valid,
 output reg [1:0] block_kind,
 output wire [31:0] block_sequence,
 output wire [63:0] block_first_frame,
 output wire [15:0] block_items,block_bytes,
 input wire [8:0] peek_byte_address,
 output wire [7:0] peek_byte_data,
 output wire [63:0] captured_pcm_pairs,retired_pcm_pairs,discarded_pcm_pairs,
 output wire [63:0] first_pcm_frame,last_pcm_frame,first_missing_pcm_frame,
 output wire [12:0] buffered_pcm_pairs,
 output wire [63:0] captured_event_cells,retired_event_cells,discarded_event_cells,
 output wire [63:0] first_missing_event_frame,
 output wire [8:0] buffered_event_cells,
 output wire [31:0] published_batches,aborted_batches,applied_items,initial_instances,
 output wire [2047:0] mapped_runtime_ids,mapped_persistent_ids,
 output wire [511:0] mapped_generations
);
 wire pcm_start_ready,event_start_ready,observer_idle;
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
 wire [10239:0] exec_cells;
 wire [5:0] exec_count;
 wire exec_valid,exec_ready,exec_done,event_tx_ready,event_tx_done;
 reg [1:0] tx_owner;
 reg [31:0] previous_command;
 reg [7:0] previous_opcode;
 reg have_command;
 reg last_was_pcm;
 wire duplicate=have_command && command_record_id==recording_id &&
   command_sequence==previous_command && record_cmd==previous_opcode &&
   (record_cmd!=1 || command_mask==record_mask);
 wire can_start=!audio_reset && command_record_id!=0 && command_record_id>recording_id && command_mask!=0 &&
   pcm_start_ready && event_start_ready && observer_idle && !allocator_busy && tx_owner==0 && cfg_idle;
 wire valid_identity=command_record_id==recording_id && recording_id!=0;
 wire ordered=!have_command || command_sequence==last_command_sequence+1'b1 ||
   (record_cmd==1 && command_record_id!=recording_id);
 // QUERY/ACK use independent transport sequencing and do not advance START/
 // STOP command sequence. ACK still checks immutable block identity below.
 assign record_cmd_ready=!rst;
 wire new_start=record_cmd_valid && !duplicate && record_cmd==1 && can_start && ordered;
 wire new_stop=record_cmd_valid && !duplicate && record_cmd==2 && valid_identity && ordered;
 assign record_start_pulse=new_start;
 assign record_stop_pulse=new_stop;
 // Failure in the event recorder retires its passive CFG producer only.
 // PCM failure must not be mistaken for an event-producer cancellation.
 assign cfg_capture_fault=record_mask[1]&&(event_incomplete||exec_incomplete)&&!new_start;
 wire ack=record_cmd_valid && record_cmd==3 && valid_identity;
 wire pcm_ack=ack && ack_kind==1;
 wire event_ack=ack && ack_kind==2;
 wire matching_ack=ack && block_valid && ack_kind==block_kind &&
   ack_block_sequence==block_sequence;
 wire pcm_available=record_mask[0] && buffered_pcm_pairs!=0 &&
   (buffered_pcm_pairs>=128 || !pcm_active);
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
 wire choose_cfg=tx_owner==0 && !exec_valid && cfg_tx_valid && record_mask[1] && !incomplete;
 wire event_tx_valid=choose_exec || choose_cfg;
 wire [5:0] event_tx_count=(tx_owner==2 || choose_cfg)?cfg_tx_count:exec_count;
 wire [10239:0] event_tx_cells=(tx_owner==2 || choose_cfg)?cfg_tx_cells:exec_cells;
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
   end else if(record_cmd_valid && record_cmd!=0 && record_cmd!=3 && !duplicate)
    rejected_commands<=rejected_commands+1;
   if(choose_pcm)block_kind<=1;
   else if(choose_event)block_kind<=2;
   if(matching_ack)begin block_kind<=0;last_was_pcm<=block_kind==1;end
   if(event_tx_valid && event_tx_ready)tx_owner<=choose_cfg?2'd2:2'd1;
   if(event_tx_done)tx_owner<=0;
  end
 end
 s11_pcm_recorder u_pcm(.clk(clk),.rst(rst),.audio_reset(audio_reset),
  .start_valid(new_start && command_mask[0]),.stop_valid(new_stop),.clear_valid(1'b0),
  .start_record_id(command_record_id),.start_ready(pcm_start_ready),.observe_load(observe_load),
  .observe_l(observe_l),.observe_r(observe_r),.observe_frame_id(observe_frame_id),
  .active(pcm_active),.incomplete(pcm_incomplete),.error_code(pcm_error),.record_id(pcm_id),
  .first_frame_id(first_pcm_frame),.last_frame_id(last_pcm_frame),
  .captured_pairs(captured_pcm_pairs),.retired_pairs(retired_pcm_pairs),.discarded_pairs(discarded_pcm_pairs),
  .first_missing_frame(first_missing_pcm_frame),.buffered_pairs(buffered_pcm_pairs),
  .block_request(choose_pcm),.block_valid(pcm_block_valid),.block_sequence(pcm_block_sequence),
  .block_first_frame(pcm_block_first),.block_pair_count(pcm_block_items),
  .peek_byte_address(peek_byte_address),.peek_byte_data(pcm_peek),.ack_valid(pcm_ack),
  .ack_record_id(command_record_id),.ack_block_sequence(ack_block_sequence),
  .stale_ack_count(pcm_stale_ack),.rejected_start_count(pcm_rejected_start));
 s11_execution_observer u_exec(.clk(clk),.rst(rst),.audio_reset(audio_reset),
  .capture_fault((event_incomplete || cfg_fault_valid) && !new_start),
  .capture_fault_code(cfg_fault_valid?cfg_fault_code:event_error),
  .stop_delivery_idle(cfg_idle && tx_owner!=2),
  .start_valid(new_start && command_mask[1]),.stop_valid(new_stop),
  .start_record_id(command_record_id),.frame_id(event_frame_id),.subcycle(event_subcycle),
  .allocator_busy(allocator_busy),.batch_begin(batch_begin),.publish_ok(publish_ok),
  .batch_abort(batch_abort),.apply_valid(apply_valid),.batch_timestamp(batch_timestamp),
  .apply_lane(apply_lane),.apply_item(apply_item),.apply_outcome(apply_outcome),
  .apply_slot(apply_slot),.apply_id(apply_id),.apply_generation(apply_generation),
  .apply_timbre(apply_timbre),.apply_steal(apply_steal),.retired_id(retired_id),
  .retired_generation(retired_generation),.reclaim_mask(reclaim_mask),.reclaim_ids(reclaim_ids),
  .reclaim_generations(reclaim_generations),.slot_valid(slot_valid),.slot_gate(slot_gate),
  .slot_notes(slot_notes),.slot_pressures(slot_pressures),.slot_keys(slot_keys),
  .slot_sources(slot_sources),.slot_ids(slot_ids),.slot_tokens(slot_tokens),
  .slot_generations(slot_generations),.slot_timbres(slot_timbres),.slot_pans(slot_pans),
  .active(exec_active),.arming(exec_arming),.incomplete(exec_incomplete),.error_code(exec_error),
  .first_missing_frame(exec_missing),.tx_valid(exec_valid),.tx_count(exec_count),.tx_cells(exec_cells),
  .tx_ready(exec_ready),.tx_done(exec_done),.published_batches(published_batches),
  .aborted_batches(aborted_batches),.applied_items(applied_items),.initial_instances(initial_instances),
  .persistent_id_next(persistent_id_next),.observer_idle(observer_idle),
  .mapped_runtime_ids(mapped_runtime_ids),.mapped_persistent_ids(mapped_persistent_ids),
  .mapped_generations(mapped_generations));
 s11_event_recorder u_events(.clk(clk),.rst(rst),
  .start_valid(new_start && command_mask[1]),.stop_valid(new_stop),.clear_valid(1'b0),
  .start_record_id(command_record_id),.start_ready(event_start_ready),.active(event_active),
  .incomplete(event_incomplete),.error_code(event_error),.record_id(event_id),
  .tx_valid(event_tx_valid),.tx_count(event_tx_count),.tx_cells(event_tx_cells),
  .tx_ready(event_tx_ready),.tx_done(event_tx_done),
  .fault_valid((exec_incomplete || cfg_fault_valid) && record_mask[1] && !new_start),
  .fault_code(cfg_fault_valid?cfg_fault_code:exec_error),
  .captured_cells(captured_event_cells),.retired_cells(retired_event_cells),
  .discarded_cells(discarded_event_cells),.buffered_cells(buffered_event_cells),
  .aborted_transaction_cells(event_aborted_cells),.block_request(choose_event),
  .block_valid(event_block_valid),.block_sequence(event_block_sequence),
  .block_first_frame(event_block_first),.block_cell_count(event_block_items),
  .peek_byte_address(peek_byte_address),.peek_byte_data(event_peek),.ack_valid(event_ack),
  .ack_record_id(command_record_id),.ack_block_sequence(ack_block_sequence),
  .stale_ack_count(event_stale_ack),.rejected_start_count(event_rejected_start));
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if($isunknown({record_cmd_valid,block_request,cfg_tx_valid,cfg_fault_valid}))
   $fatal(1,"S11_SUBSYSTEM_CONTROL_XZ");
  if(cfg_fault_valid && $isunknown({cfg_fault_code,cfg_first_missing_frame}))
   $fatal(1,"S11_SUBSYSTEM_CFG_FAULT_XZ");
  if(record_cmd_valid && $isunknown({record_cmd,command_record_id,command_mask,
      command_sequence,ack_kind,ack_block_sequence}))$fatal(1,"S11_SUBSYSTEM_COMMAND_XZ");
 end
 // synthesis translate_on
endmodule
