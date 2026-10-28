// Stage10 SPI PCM composition only; no change to the frozen audio/video algorithms.
// Stage8 composition only; the complete Stage7 implementation remains the audio owner.
module instrument_core_stage11 #(
    parameter integer RECORD48=1,
    parameter integer AUDIO_RATE_HZ=48000,
    parameter integer COMM_SEPARATE=0,
 parameter integer VERSIONED_TOKENS=1,
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer PRESSURE_PRENORMALIZED=0,
    parameter integer ADC_ZERO = 0,
    parameter integer ADC_FULL = 1023,
    parameter integer DEADZONE = 8,
    parameter integer PRESS_THRESHOLD = 16,
    parameter integer RELEASE_THRESHOLD = 8,
    parameter integer VIBRATO_STEP = 1,
    parameter integer OCTAVE_MIN = -2,
    parameter integer OCTAVE_MAX = 2,
    parameter integer ENABLE_S11 = 1,
    parameter integer MIX_SHIFT = 5
) (
    input wire spi_sck,score_cs_n,sd_cs_n,spi_mosi,
    output wire spi_miso,spi_miso_oe,guide_led_dout,
    input wire guide_cfg_valid,guide_cfg_prefix,
    input wire [23:0] guide_cfg_order,
    input wire [13:0] guide_cfg_lead,
    output wire [7:0] score_state,score_error,
    output wire [63:0] score_time,
    output wire [31:0] score_deadline_count,
    output wire gain_cfg_valid,
    output wire [15:0] gain_cfg_local,gain_cfg_external,
    output wire gain_cfg_local_mute,gain_cfg_external_mute,
    output wire stream_error,
    output wire [31:0] external_underflow_count,
    output wire fx_cfg_valid,
    output wire [351:0] fx_cfg_data,
    output wire fx_error,
    output wire pan_valid,
    output wire [5:0] pan_slot,
    output wire [63:0] pan_id,
    output wire [15:0] pan_generation,
    output wire [8:0] pan_value,
    input wire comm_clk, input wire clk,
    input wire rst,
    input wire [79:0] pressure_raw,
    input wire pressure_valid,
    input wire step_pulse,
    input wire step_dir,
    output wire [2:0] timbre_id,
    input wire [3:0] local_glide_code,
    input wire octave_up_pulse,
    input wire octave_down_pulse,
    output wire dac_bck,
    output wire dac_ws,
    output wire dac_din,
    output wire frame_pulse,
    output wire sample_overrun,
    output wire underrun,
    output wire observe_load,
    output wire signed [15:0] observe_l,observe_r,
 output wire [47:0] observe_full_slot_valid,observe_full_slot_gate,
    output wire [31:0] observe_slot_valid,observe_slot_gate,
    output wire [95:0] observe_slot_timbres,
    output wire [351:0] observe_fx_config,
    output wire [31:0] observe_fx_version,
    output wire observe_fx_bypass,observe_teach,observe_loop,
    output wire [2:0] observe_stream_state,
    output wire [11:0] observe_stream_buffered,
    output wire [31:0] observe_stream_generation,
    output wire [255:0] observe_score_status,
    input wire video_pixel_clk,video_serial_clk,video_pll_locked,
    input wire display_reset,input wire [1:0] display_scale,input wire display_test_pattern,
    output wire [3:0] video_p,video_n,
    output wire display_error,output wire [31:0] display_published,display_presented,
    output wire [18:0] display_processing_cycles,
 input wire control_cs_n,
 output wire [2:0] phone_link_state,
 output wire [31:0] phone_held_keys,phone_rejected_transactions,phone_cs_conflicts,phone_lease_expirations,phone_cleanup_offs,
 output wire [3:0] glide_code,
 output wire [63:0] media_accepted_pairs,media_delivered_pairs,media_discard_pairs,
 output wire [31:0] media_packets,media_duplicates,media_rejected,media_conflicts,media_timeouts,
    input wire field_valid,field_start,input wire [1:0] field_size,
    output wire field_ready,field_active,field_rejected,field_committed,field_running,
    output wire  observe_allocator_busy,
    output wire  observe_batch_begin,
    output wire  observe_publish_ok,
    output wire  observe_batch_abort,
    output wire  observe_apply_valid,
    output wire [31:0] observe_batch_timestamp,
    output wire [3:0] observe_apply_lane,
    output wire [95:0] observe_apply_item,
    output wire [7:0] observe_apply_outcome,
    output wire [5:0] observe_apply_slot,
    output wire [63:0] observe_apply_id,
    output wire [15:0] observe_apply_generation,
    output wire [2:0] observe_apply_timbre,
    output wire  observe_apply_steal,
    output wire [63:0] observe_retired_id,
    output wire [15:0] observe_retired_generation,
    output wire [31:0] observe_reclaim_mask,
    output wire [223:0] observe_slot_notes,
    output wire [255:0] observe_slot_pressures,
    output wire [287:0] observe_current_pan,
    output wire [7:0] observe_local_gate,
    output wire  observe_local_pending,
    output wire [55:0] observe_local_notes,
    output wire  observe_allocator_publish,
    output wire [31:0] observe_slot_cancel,
    output wire [31:0] observe_sample_time,
    output wire [31:0] observe_fx_accepted,
    output wire [31:0] observe_pan_accepted,
    output wire  observe_gain_sample,
    output wire [31:0] observe_gain_frame,
    output wire [31:0] observe_gain_version,
    output wire [31:0] observe_gain_accepted,
    output wire [15:0] observe_gain_l,
    output wire [15:0] observe_gain_e,
    output wire [6:0] observe_gain_remaining,
    output wire [55:0] observe_keymap,
    output wire [31:0] observe_keymap_version,
    output wire [2:0] record_state,
    output wire [31:0] record_error,
    output wire [63:0] recording_id,
    output wire [1:0] record_mask,
    output wire [31:0] record_last_command,record_rejected_commands,
    output wire [63:0] record_captured_pairs,record_retired_pairs,record_discarded_pairs,
    output wire [63:0] record_first_frame,record_last_frame,record_first_missing_frame,record_first_missing_event_frame,
    output wire [12:0] record_buffered_pairs,
    output wire [63:0] record_captured_cells,record_retired_cells,record_discarded_cells,
    output wire [8:0] record_buffered_cells,
    output wire [31:0] record_published_batches,record_aborted_batches,record_applied_items,record_initial_instances,
    output wire record_start_pulse,record_stop_pulse,
    output wire [63:0] observe_frame_id,observe_event_frame_id,
    output wire [15:0] observe_event_subcycle,
    output wire [103:0] observe_gain_state,
    output wire [63:0] observe_media_epoch
);
 wire  r18_snapshot_valid;
 wire  r18_snapshot_ready;
 wire  r18_query_valid;
 wire [5:0] r18_query_slot;
 wire  r18_query_ready;
 wire  r18_response_valid;
 wire [5:0] r18_response_slot;
 wire [314:0] r18_response_word;
 wire [63:0] r18_allocated_pid;
 wire [63:0] r18_clock_frame;
 wire [15:0] r18_clock_subcycle;
 wire  r18_fact_valid;
 wire [314:0] r18_fact_before;
 wire [314:0] r18_fact_after;
 wire [63:0] r18_fact_frame;
 wire [15:0] r18_fact_subcycle;
 wire  r18_reclaim_busy;
 wire  r18_pan_ready;
 wire  r18_pan_response_valid;
 wire [1:0] r18_pan_result;
 wire [5:0] r18_pan_response_slot;
 wire [314:0] r18_pan_before;
 wire [314:0] r18_pan_after;

 assign r18_clock_frame=observe_event_frame_id;assign r18_clock_subcycle=observe_event_subcycle;
 wire record_cmd_valid,record_cmd_ready;
 wire [1:0] record_cmd;wire [63:0] record_cmd_id;
 wire [7:0] record_cmd_mask,record_ack_kind;
 wire [31:0] record_cmd_sequence,record_ack_sequence;
 wire record_block_valid;wire [1:0] record_block_kind;
 wire [31:0] record_block_sequence;wire [63:0] record_block_first;
 wire [15:0] record_block_bytes,record_block_items;
 wire [10:0] record_peek_address;wire [7:0] record_peek_data;
 wire cfg_tx_valid,cfg_tx_ready,cfg_tx_done,cfg_fault_valid,cfg_idle,cfg_quiet,cfg_capture_fault;
 wire r18_capture_caught_up;
 wire [63:0] cfg_first_missing_frame;
 wire cfg_tx_read_valid,cfg_tx_response_valid;wire [15:0] cfg_tx_read_epoch,cfg_tx_response_epoch;wire [5:0] cfg_tx_response_index;
 wire [5:0] cfg_tx_count;wire [255:0] cfg_tx_cell;wire [5:0] cfg_tx_index;wire [7:0] cfg_fault_code;
 wire [63:0] recorder_first_missing=record_mask[0]&&record_first_missing_frame!=64'hffffffffffffffff ? record_first_missing_frame:record_first_missing_event_frame;
 wire [2:0] wire_record_state;
 wire wire_record_incomplete,record_drained;
 reg [63:0] previous_dac_frame;
 reg [63:0] dac_load_count;reg [15:0] since_load;
 assign observe_frame_id=dac_load_count;
 assign observe_event_frame_id=observe_load?dac_load_count:previous_dac_frame;
 // synthesis translate_off
 always @(posedge clk)if(!rst && observe_event_frame_id !==
   (observe_load?dac_load_count:(dac_load_count==0?64'd0:dac_load_count-1'b1)))
   $fatal(1,"MARGIN_EVENT_FRAME_EQ");
 // synthesis translate_on
 assign observe_event_subcycle=observe_load?16'd0:since_load+1'b1;
 always @(posedge clk)begin
  if(rst)begin dac_load_count<=0;previous_dac_frame<=0;since_load<=0;end
  else if(observe_load)begin dac_load_count<=dac_load_count+1'b1;previous_dac_frame<=(&dac_load_count)?64'd0:dac_load_count;since_load<=0;end
  else if(since_load!=65535)since_load<=since_load+1'b1;
 end
 instrument_core_stage10 #(.AUDIO_RATE_HZ(AUDIO_RATE_HZ),.PINNED_RECORD_PREFIX(1),.COMM_SEPARATE(COMM_SEPARATE),.VERSIONED_TOKENS(VERSIONED_TOKENS),
  .PRESSURE_PRENORMALIZED(PRESSURE_PRENORMALIZED),
  .CLK_FREQ_HZ(CLK_FREQ_HZ),
  .ADC_ZERO(ADC_ZERO),
  .ADC_FULL(ADC_FULL),
  .DEADZONE(DEADZONE),
  .PRESS_THRESHOLD(PRESS_THRESHOLD),
  .RELEASE_THRESHOLD(RELEASE_THRESHOLD),
  .VIBRATO_STEP(VIBRATO_STEP),
  .OCTAVE_MIN(OCTAVE_MIN),
  .OCTAVE_MAX(OCTAVE_MAX),
  .MIX_SHIFT(MIX_SHIFT),
  .S11_VERSION(RECORD48?2:1),.ENABLE_S11(1)) base(
  .r18_snapshot_valid(r18_snapshot_valid),
  .r18_snapshot_ready(r18_snapshot_ready),
  .r18_query_valid(r18_query_valid),
  .r18_query_slot(r18_query_slot),
  .r18_query_ready(r18_query_ready),
  .r18_response_valid(r18_response_valid),
  .r18_response_slot(r18_response_slot),
  .r18_response_word(r18_response_word),
  .r18_allocated_pid(r18_allocated_pid),
  .r18_capture_caught_up(r18_capture_caught_up),
  .r18_clock_frame(r18_clock_frame),
  .r18_clock_subcycle(r18_clock_subcycle),
  .r18_fact_valid(r18_fact_valid),
  .r18_fact_before(r18_fact_before),
  .r18_fact_after(r18_fact_after),
  .r18_fact_frame(r18_fact_frame),
  .r18_fact_subcycle(r18_fact_subcycle),
  .r18_reclaim_busy(r18_reclaim_busy),
  .r18_pan_ready(r18_pan_ready),
  .r18_pan_response_valid(r18_pan_response_valid),
  .r18_pan_result(r18_pan_result),
  .r18_pan_response_slot(r18_pan_response_slot),
  .r18_pan_before(r18_pan_before),
  .r18_pan_after(r18_pan_after),

 
  .spi_sck(spi_sck),
  .score_cs_n(score_cs_n),
  .sd_cs_n(sd_cs_n),
  .spi_mosi(spi_mosi),
  .spi_miso(spi_miso),
  .spi_miso_oe(spi_miso_oe),
  .guide_led_dout(guide_led_dout),
  .guide_cfg_valid(guide_cfg_valid),
  .guide_cfg_prefix(guide_cfg_prefix),
  .guide_cfg_order(guide_cfg_order),
  .guide_cfg_lead(guide_cfg_lead),
  .score_state(score_state),
  .score_error(score_error),
  .score_time(score_time),
  .score_deadline_count(score_deadline_count),
  .gain_cfg_valid(gain_cfg_valid),
  .gain_cfg_local(gain_cfg_local),
  .gain_cfg_external(gain_cfg_external),
  .gain_cfg_local_mute(gain_cfg_local_mute),
  .gain_cfg_external_mute(gain_cfg_external_mute),
  .stream_error(stream_error),
  .external_underflow_count(external_underflow_count),
  .fx_cfg_valid(fx_cfg_valid),
  .fx_cfg_data(fx_cfg_data),
  .fx_error(fx_error),
  .pan_valid(pan_valid),
  .pan_slot(pan_slot),
  .pan_id(pan_id),
  .pan_generation(pan_generation),
  .pan_value(pan_value),
  .comm_clk(comm_clk),.clk(clk),
  .rst(rst),
  .pressure_raw(pressure_raw),
  .pressure_valid(pressure_valid),
  .step_pulse(step_pulse),
  .step_dir(step_dir),
  .timbre_id(timbre_id),
  .local_glide_code(local_glide_code),
  .octave_up_pulse(octave_up_pulse),
  .octave_down_pulse(octave_down_pulse),
  .dac_bck(dac_bck),
  .dac_ws(dac_ws),
  .dac_din(dac_din),
  .frame_pulse(frame_pulse),
  .sample_overrun(sample_overrun),
  .underrun(underrun),
  .observe_load(observe_load),
  .observe_l(observe_l),
  .observe_r(observe_r),
  .observe_full_slot_valid(observe_full_slot_valid),.observe_full_slot_gate(observe_full_slot_gate),.observe_slot_valid(observe_slot_valid),
  .observe_slot_gate(observe_slot_gate),
  .observe_slot_timbres(observe_slot_timbres),
  .observe_fx_config(observe_fx_config),
  .observe_fx_version(observe_fx_version),
  .observe_fx_bypass(observe_fx_bypass),
  .observe_teach(observe_teach),
  .observe_loop(observe_loop),
  .observe_stream_state(observe_stream_state),
  .observe_stream_buffered(observe_stream_buffered),
  .observe_stream_generation(observe_stream_generation),
  .observe_score_status(observe_score_status),
  .video_pixel_clk(video_pixel_clk),
  .video_serial_clk(video_serial_clk),
  .video_pll_locked(video_pll_locked),
  .display_reset(display_reset),
  .display_scale(display_scale),
  .display_test_pattern(display_test_pattern),
  .video_p(video_p),
  .video_n(video_n),
  .display_error(display_error),
  .display_published(display_published),
  .display_presented(display_presented),
  .display_processing_cycles(display_processing_cycles),
  .control_cs_n(control_cs_n),
  .phone_link_state(phone_link_state),
  .phone_held_keys(phone_held_keys),
  .phone_rejected_transactions(phone_rejected_transactions),
  .phone_cs_conflicts(phone_cs_conflicts),
  .phone_lease_expirations(phone_lease_expirations),
  .phone_cleanup_offs(phone_cleanup_offs),
  .glide_code(glide_code),
  .media_accepted_pairs(media_accepted_pairs),
  .media_delivered_pairs(media_delivered_pairs),
  .media_discard_pairs(media_discard_pairs),
  .media_packets(media_packets),
  .media_duplicates(media_duplicates),
  .media_rejected(media_rejected),
  .media_conflicts(media_conflicts),
  .media_timeouts(media_timeouts),
  .field_valid(1'b0),
  .field_start(1'b0),
  .field_size(2'd0),
  .field_ready(field_ready),
  .field_active(field_active),
  .field_rejected(field_rejected),
  .field_committed(field_committed),
  .field_running(field_running),
  .observe_allocator_busy(observe_allocator_busy),
  .observe_batch_begin(observe_batch_begin),
  .observe_publish_ok(observe_publish_ok),
  .observe_batch_abort(observe_batch_abort),
  .observe_apply_valid(observe_apply_valid),
  .observe_batch_timestamp(observe_batch_timestamp),
  .observe_apply_lane(observe_apply_lane),
  .observe_apply_item(observe_apply_item),
  .observe_apply_outcome(observe_apply_outcome),
  .observe_apply_slot(observe_apply_slot),
  .observe_apply_id(observe_apply_id),
  .observe_apply_generation(observe_apply_generation),
  .observe_apply_timbre(observe_apply_timbre),
  .observe_apply_steal(observe_apply_steal),
  .observe_retired_id(observe_retired_id),
  .observe_retired_generation(observe_retired_generation),
  .observe_reclaim_mask(observe_reclaim_mask),
  
  
  .observe_slot_notes(observe_slot_notes),
  .observe_slot_pressures(observe_slot_pressures),
  .observe_current_pan(observe_current_pan),
  .observe_local_gate(observe_local_gate),
  .observe_local_pending(observe_local_pending),
  .observe_local_notes(observe_local_notes),
  .observe_allocator_publish(observe_allocator_publish),
  
  
  
  
  
  .observe_slot_cancel(observe_slot_cancel),
  .observe_sample_time(observe_sample_time),
  .observe_fx_accepted(observe_fx_accepted),
  .observe_pan_accepted(observe_pan_accepted),
  
  
  
  .observe_gain_sample(observe_gain_sample),
  .observe_gain_frame(observe_gain_frame),
  .observe_gain_version(observe_gain_version),
  .observe_gain_accepted(observe_gain_accepted),
  .observe_gain_l(observe_gain_l),
  .observe_gain_e(observe_gain_e),
  .observe_gain_state(observe_gain_state),.observe_gain_remaining(observe_gain_remaining),
  .observe_keymap(observe_keymap),
  .observe_keymap_version(observe_keymap_version),
  .record_cmd_valid(record_cmd_valid),
  .record_cmd_ready(record_cmd_ready),
  .record_cmd(record_cmd),
  .record_cmd_id(record_cmd_id),
  .record_cmd_mask(record_cmd_mask),
  .record_ack_kind(record_ack_kind),
  .record_cmd_sequence(record_cmd_sequence),
  .record_ack_sequence(record_ack_sequence),
  .record_state(wire_record_state),
  .record_incomplete(wire_record_incomplete),
  .record_mask({6'd0,record_mask}),
  .record_id(recording_id),
  .record_last_command(record_last_command),
  .record_error(record_error),
  .record_captured_pcm(record_captured_pairs[31:0]),
  .record_missing_is_event(!(record_mask[0]&&record_first_missing_frame!=64'hffffffffffffffff)),
  .record_first_missing_frame(recorder_first_missing),
  .record_block_valid(record_block_valid),
  .record_block_kind({6'd0,record_block_kind}),
  .record_block_sequence(record_block_sequence),
  .record_block_first(record_block_first),
  .record_block_bytes(record_block_bytes),
  .record_block_items(record_block_items),
  .record_peek_address(record_peek_address),
  .observe_media_epoch(observe_media_epoch),.record_peek_data(record_peek_data));
 r18_recording_subsystem #(.PCM_BLOCK_PAIRS(512),.SERIAL_EVENTS(1),.RECORD48(RECORD48)) recorder(
 .pan_applied(r18_pan_response_valid&&r18_pan_result==0),.pan_applied_slot(r18_pan_response_slot),.pan_applied_word(r18_pan_after),
  .snapshot_valid(r18_snapshot_valid),.snapshot_ready(r18_snapshot_ready),.allocated_persistent_id(r18_allocated_pid),
  .snapshot_query_valid(r18_query_valid),.snapshot_query_ready(r18_query_ready),.snapshot_query_slot(r18_query_slot),
  .snapshot_response_valid(r18_response_valid),.snapshot_response_slot(r18_response_slot),.snapshot_response_word(r18_response_word),
  .fact_valid(r18_fact_valid),.fact_item(observe_apply_item),.fact_outcome(observe_apply_outcome),.fact_slot(observe_apply_slot),.fact_steal(observe_apply_steal),
  .fact_before(r18_fact_before),.fact_after(r18_fact_after),.fact_frame(r18_fact_frame),.fact_subcycle(r18_fact_subcycle),.reclaim_batch_busy(r18_reclaim_busy),
.clk(clk),.rst(rst),.audio_reset(rst),
  .record_cmd_valid(record_cmd_valid),.record_cmd_ready(record_cmd_ready),.record_cmd({6'd0,record_cmd}),
  .command_record_id(record_cmd_id),.command_mask(record_cmd_mask[1:0]),.ack_kind(record_ack_kind[1:0]),
  .command_sequence(record_cmd_sequence),.ack_block_sequence(record_ack_sequence),
  .record_state(record_state),.record_error(record_error),.recording_id(recording_id),.record_mask(record_mask),
  .wire_record_state(wire_record_state),.wire_record_incomplete(wire_record_incomplete),.record_drained(record_drained),
  .last_command_sequence(record_last_command),.rejected_commands(record_rejected_commands),
  .record_start_pulse(record_start_pulse),.record_stop_pulse(record_stop_pulse),
  .observe_load(observe_load),.observe_l(observe_l),.observe_r(observe_r),.observe_frame_id(observe_frame_id),
  .event_frame_id(observe_event_frame_id),.event_subcycle(observe_event_subcycle),
  .allocator_busy(observe_allocator_busy),.batch_begin(observe_batch_begin),.publish_ok(observe_publish_ok),
  .batch_abort(observe_batch_abort),.batch_timestamp(observe_batch_timestamp),
  
  
  
  
  .slot_valid(observe_full_slot_valid),.slot_gate(observe_full_slot_gate),
  
  
  
  .cfg_tx_read_valid(cfg_tx_read_valid),.cfg_tx_read_epoch(cfg_tx_read_epoch),
  .cfg_tx_response_valid(cfg_tx_response_valid),.cfg_tx_response_index(cfg_tx_response_index),.cfg_tx_response_epoch(cfg_tx_response_epoch),
  .cfg_tx_valid(cfg_tx_valid),.cfg_tx_count(cfg_tx_count),.cfg_tx_cell(cfg_tx_cell),.cfg_tx_index(cfg_tx_index),.cfg_tx_ready(cfg_tx_ready),.cfg_tx_done(cfg_tx_done),
  .cfg_fault_valid(cfg_fault_valid),.cfg_fault_code(cfg_fault_code),.cfg_first_missing_frame(cfg_first_missing_frame),
  .cfg_capture_fault(cfg_capture_fault),.cfg_idle(cfg_idle),.cfg_quiet(cfg_quiet),.capture_caught_up(r18_capture_caught_up),.block_request(1'b1),
  .block_valid(record_block_valid),.block_kind(record_block_kind),.block_sequence(record_block_sequence),
  .block_first_frame(record_block_first),.block_items(record_block_items),.block_bytes(record_block_bytes),
  .peek_byte_address(record_peek_address),.peek_byte_data(record_peek_data),
  .captured_pcm_pairs(record_captured_pairs),.retired_pcm_pairs(record_retired_pairs),.discarded_pcm_pairs(record_discarded_pairs),
  .first_pcm_frame(record_first_frame),.last_pcm_frame(record_last_frame),.first_missing_pcm_frame(record_first_missing_frame),
  .buffered_pcm_pairs(record_buffered_pairs),.captured_event_cells(record_captured_cells),.retired_event_cells(record_retired_cells),.first_missing_event_frame(record_first_missing_event_frame),
  .discarded_event_cells(record_discarded_cells),.buffered_event_cells(record_buffered_cells),
  .published_batches(record_published_batches),.aborted_batches(record_aborted_batches),.applied_items(record_applied_items),
  .initial_instances(record_initial_instances));
 r18_config_observer configs(
  .pan_valid(1'b0),.pan_slot(r18_pan_response_slot),.pan_before(r18_pan_before),.pan_after(r18_pan_after),
.clk(clk),.rst(rst),.capture_fault(cfg_capture_fault),.start(record_start_pulse&&record_cmd_mask[1]),
  .stop(record_stop_pulse),.recording(record_mask[1]&&(record_state==1||record_state==2)),
  .frame_id(observe_event_frame_id),.subcycle(observe_event_subcycle),
  .timbre_id(timbre_id),.glide_code(glide_code),.keymap(observe_keymap),.keymap_version(observe_keymap_version),
  .fx_config(observe_fx_config),.fx_version(observe_fx_version),
  .gain_cfg_valid(gain_cfg_valid),.gain_local(gain_cfg_local),.gain_external(gain_cfg_external),
  .gain_local_mute(gain_cfg_local_mute),.gain_external_mute(gain_cfg_external_mute),
  .gain_accepted(observe_gain_accepted),.gain_sample(observe_gain_sample),.gain_frame(observe_gain_frame),
  .gain_version(observe_gain_version),.gain_current_l(observe_gain_l),.gain_current_e(observe_gain_e),
  .gain_state(observe_gain_state),.gain_remaining(observe_gain_remaining),
  
  
  
  .stream_state(observe_stream_state),.stream_generation(observe_stream_generation),.media_epoch(observe_media_epoch),
  .tx_read_valid(cfg_tx_read_valid),.tx_read_epoch(cfg_tx_read_epoch),
  .tx_response_valid(cfg_tx_response_valid),.tx_response_index(cfg_tx_response_index),.tx_response_epoch(cfg_tx_response_epoch),
  .tx_valid(cfg_tx_valid),.tx_count(cfg_tx_count),.tx_cell(cfg_tx_cell),.tx_index(cfg_tx_index),.tx_ready(cfg_tx_ready),.tx_done(cfg_tx_done),
  .fault_valid(cfg_fault_valid),.first_missing_frame(cfg_first_missing_frame),.fault_code(cfg_fault_code),.idle(cfg_idle),.capture_quiet(cfg_quiet));
endmodule
