// Stage8 composition only; the complete Stage7 implementation remains the audio owner.
module instrument_core_stage9 #(
    parameter integer AUDIO_RATE_HZ=48000,
    parameter integer EXTERNAL_SCORE_RX=0,COMM_SEPARATE=0,
 parameter integer VERSIONED_TOKENS=0,
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
    parameter integer ENABLE_S10_ROUTE = 0,
    parameter integer ENABLE_S11 = 0,
    parameter integer MIX_SHIFT = 5
) (
 input wire  r18_snapshot_valid,
 output wire  r18_snapshot_ready,
 input wire  r18_query_valid,
 input wire [5:0] r18_query_slot,
 output wire  r18_query_ready,
 output wire  r18_response_valid,
 output wire [5:0] r18_response_slot,
 output wire [314:0] r18_response_word,
 input wire [63:0] r18_allocated_pid,
 input wire r18_capture_caught_up,
 input wire [63:0] r18_clock_frame,
 input wire [15:0] r18_clock_subcycle,
 output wire  r18_fact_valid,
 output wire [314:0] r18_fact_before,
 output wire [314:0] r18_fact_after,
 output wire [63:0] r18_fact_frame,
 output wire [15:0] r18_fact_subcycle,
 output wire  r18_reclaim_busy,
 output wire  r18_pan_ready,
 output wire  r18_pan_response_valid,
 output wire [1:0] r18_pan_result,
 output wire [5:0] r18_pan_response_slot,
 output wire [314:0] r18_pan_before,
 output wire [314:0] r18_pan_after,


    input wire spi_sck,score_cs_n,sd_cs_n,spi_mosi,
    output wire spi_miso,spi_miso_oe,guide_led_dout,
    input wire guide_cfg_valid,guide_cfg_prefix,
    input wire [23:0] guide_cfg_order,
    input wire [13:0] guide_cfg_lead,
    output wire [7:0] score_state,score_error,
    output wire [63:0] score_time,
    output wire [31:0] score_deadline_count,
    input wire stream_ctrl_valid,
    output wire stream_ctrl_ready,
    input wire [1:0] stream_ctrl_cmd,
    input wire [63:0] stream_ctrl_epoch,
    input wire [31:0] stream_ctrl_rate,
    input wire stream_ctrl_track,
    input wire external_valid,
    output wire external_ready,
    input wire signed [15:0] external_l,external_r,
    input wire [63:0] external_epoch,
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
 output wire [63:0] observe_full_slot_valid,observe_full_slot_gate,
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
    input wire field_valid,field_start,input wire [2:0] field_size,
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
    output wire [103:0] observe_gain_state,input wire [540:0] shared_score_rx
);
 wire [127:0] ensemble_metrics;
 wire  phone_session_flush;
 wire  phone_session_ready;
 wire [575:0] phone_presses;
 wire  phone_lookup_valid;
 wire  phone_lookup_pan;
 wire [7:0] phone_lookup_key;
 wire [63:0] phone_lookup_identity;
 wire [15:0] phone_lookup_generation;
 wire [15:0] phone_lookup_tag;
 wire  phone_lookup_ready;
 wire  phone_response_valid;
 wire  phone_found;
 wire [5:0] phone_response_slot;
 wire [314:0] phone_response_word;
 wire [15:0] phone_response_tag;

 wire remote_event_valid,remote_event_ready,remote_dispatch_done;
 wire [904:0] remote_event_packet;wire [575:0] remote_press_ids;
 wire field_cfg_valid,field_cfg_start;wire [2:0] field_cfg_size;
 wire merged_field_valid=field_cfg_valid||field_valid;
 wire merged_field_start=field_cfg_valid?field_cfg_start:field_start;
 wire [2:0] merged_field_size=field_cfg_valid?field_cfg_size:field_size;
 wire [55:0] remote_keymap;
 assign observe_keymap=remote_keymap;
 wire score_miso,score_oe,control_miso,control_oe;
 wire score_isolated=sd_cs_n&&control_cs_n;
 assign spi_miso=(!score_cs_n&&control_cs_n&&sd_cs_n)?score_miso:control_miso;
 assign spi_miso_oe=sd_cs_n&&((!score_cs_n&&control_cs_n&&score_oe)||(!control_cs_n&&score_cs_n&&control_oe));
 reg [15:0] millisecond_divider;reg [31:0] now_ms;
 always @(posedge clk)begin
  if(rst)begin millisecond_divider<=0;now_ms<=0;end
  else if(millisecond_divider==CLK_FREQ_HZ/1000-1)begin millisecond_divider<=0;now_ms<=now_ms+1'b1;end
  else millisecond_divider<=millisecond_divider+1'b1;
 end
 wire [31:0] session_now_ms_next=now_ms+32'(millisecond_divider==CLK_FREQ_HZ/1000-1);
 wire [5:0] pan_commit_slot;wire pan_commit_slot_live;
 wire pan_lookup_ready,config_payload_changed,pan_query_changed;
 wire phone_open,phone_close,phone_open_ready,phone_active,phone_close_done,session_flush,session_ready;
 wire [127:0] session_id;
 wire identity_query_prepare;wire [63:0] identity_prepare_press;wire identity_query_prepared;
 wire cleanup_write_valid,cleanup_write_ready;wire[95:0] cleanup_write_data;
 wire shared_write_ready,phone_write_ready;
 assign phone_write_ready=shared_write_ready&&!cleanup_write_valid;
 assign cleanup_write_ready=shared_write_ready;
 wire phone_write_valid,phone_write_abort;wire[3:0] phone_write_index;wire[95:0] phone_write_data;
 wire command_valid,command_ready,command_event,command_buffer_busy,phone_token_exhausted;wire[63:0] phone_next_token;wire [2:0] command_slot;wire [1535:0] command_bytes;wire [7:0] command_length;
 wire config_valid,config_ready;wire [2:0] config_slot;wire [1535:0] config_bytes;
 wire rt_result_valid,rt_result_ready,cfg_result_valid,cfg_result_ready,cfg_result_final;
 wire [2:0] rt_result_slot,cfg_result_slot;wire [31:0] rt_result_sequence,cfg_result_sequence;
 wire [511:0] rt_result_bytes,cfg_result_bytes;
 wire result_valid,result_ready,result_final,result_channel;wire [2:0] result_slot;wire [31:0] result_sequence;wire [511:0] result_bytes;
 reg result_locked,result_select,result_turn;
 wire select_cfg=result_locked?result_select:((rt_result_valid&&cfg_result_valid)?result_turn:cfg_result_valid);
 assign result_valid=select_cfg?cfg_result_valid:rt_result_valid;
 assign result_slot=select_cfg?cfg_result_slot:rt_result_slot;
 assign result_sequence=select_cfg?cfg_result_sequence:rt_result_sequence;
 assign result_bytes=select_cfg?cfg_result_bytes:rt_result_bytes;
 assign result_final=select_cfg?cfg_result_final:1'b1;assign result_channel=select_cfg;
 assign cfg_result_ready=result_ready&&select_cfg;assign rt_result_ready=result_ready&&!select_cfg;
 always @(posedge clk)begin
  if(rst||session_flush)begin result_locked<=0;result_select<=0;result_turn<=0;end
  else if(result_valid)begin
   if(result_ready)begin result_locked<=0;result_turn<=!select_cfg;end
   else begin result_locked<=1;result_select<=select_cfg;end
  end
 end
 wire lookup_valid,lookup_ready,lookup_channel,lookup_echo,lookup_done;
 wire [31:0] lookup_sequence;wire signed[15:0] lookup_error;wire [511:0] lookup_result;
 wire[3:0] phone_map_address;wire[95:0] phone_map_data;wire[8:0] phone_map_mask;wire phone_maps_release;
 r22_control_link #(.COMM_SEPARATE(COMM_SEPARATE),.CLK_FREQ_HZ(CLK_FREQ_HZ)) control(.event_write_valid(phone_write_valid),.event_write_ready(phone_write_ready),.event_write_abort(phone_write_abort),.event_write_index(phone_write_index),.event_write_data(phone_write_data),.comm_clk(comm_clk),.map_address(phone_map_address),.map_data(phone_map_data),.map_mask(phone_map_mask),.maps_release(phone_maps_release),.command_buffer_busy(command_buffer_busy),.phone_next_token(phone_next_token),.phone_token_exhausted(phone_token_exhausted),.config_payload_changed(config_payload_changed),.now_ms_next(session_now_ms_next),.clk(clk),.rst(rst),.now_ms(now_ms),.spi_sck(spi_sck),.control_cs_n(control_cs_n),.score_cs_n(score_cs_n),.sd_cs_n(sd_cs_n),.spi_mosi(spi_mosi),
  .spi_miso(control_miso),.spi_miso_oe(control_oe),.phone_open_ready(phone_open_ready),.phone_active(phone_active),.phone_close_done(phone_close_done),
  .phone_open(phone_open),.phone_close(phone_close),.session_flush(session_flush),.session_ready(session_ready),.session_id(session_id),.link_state(phone_link_state),
  .identity_query_prepare(identity_query_prepare),.identity_prepare_press(identity_prepare_press),
  .command_event(command_event),.command_valid(command_valid),.command_ready(command_ready),.command_slot(command_slot),.command_bytes(command_bytes),.command_length(command_length),
  .result_valid(result_valid),.result_ready(result_ready),.result_slot(result_slot),.result_channel(result_channel),.result_sequence(result_sequence),.result_bytes(result_bytes),.result_final(result_final),
  .lookup_valid(lookup_valid),.lookup_ready(lookup_ready),.lookup_channel(lookup_channel),.lookup_echo(lookup_echo),.lookup_sequence(lookup_sequence),.lookup_done(lookup_done),.lookup_error(lookup_error),.lookup_result(lookup_result),
  .rejected_transactions(phone_rejected_transactions),.cs_conflicts(phone_cs_conflicts),.lease_expirations(phone_lease_expirations),.stale_result_updates());
 r22_event_endpoint #(.SHARED_STORE(1),.STREAM_CLEAN(1)) events(
  .cleanup_write_valid(cleanup_write_valid),.cleanup_write_ready(cleanup_write_ready),.cleanup_write_data(cleanup_write_data),
  .map_address(phone_map_address),.map_data(phone_map_data),.map_mask(phone_map_mask),.maps_release(phone_maps_release),
  .fact_valid(r18_fact_valid),.fact_index(observe_apply_lane),.fact_item(observe_apply_item),
  .fact_outcome(observe_apply_outcome),.fact_slot(observe_apply_slot),.fact_after(r18_fact_after),.buffer_busy(command_buffer_busy),.next_token(phone_next_token),.clk(clk),.rst(rst),.session_flush(session_flush),.session_ready(session_ready),.session_id(session_id),
  .phone_open(phone_open),.phone_close(phone_close),.phone_open_ready(phone_open_ready),.phone_active(phone_active),.phone_close_done(phone_close_done),
  .command_event(command_event),.command_valid(command_valid),.command_ready(command_ready),.command_slot(command_slot),.command_bytes(command_bytes),.command_length(command_length),
  .config_valid(config_valid),.config_ready(config_ready),.config_slot(config_slot),.config_bytes(config_bytes),
  .result_valid(rt_result_valid),.result_ready(rt_result_ready),.result_slot(rt_result_slot),.result_sequence(rt_result_sequence),.result_bytes(rt_result_bytes),
  .sample_time(observe_sample_time),.event_valid(remote_event_valid),.event_ready(remote_event_ready),.event_packet(remote_event_packet),.event_press_ids(remote_press_ids),.dispatch_done(remote_dispatch_done),
  .held_keys(phone_held_keys),.cleanup_offs(phone_cleanup_offs),.token_exhausted(phone_token_exhausted));
 assign phone_session_flush=session_flush;assign phone_session_ready=session_ready;assign phone_presses=remote_press_ids;
 wire identity_stable=!observe_allocator_busy;
 r22_config_bridge #(.ENABLE_FIELD(ENABLE_S11),.DEFER_RESULT_CRC(1)) parameters(
  .ensemble_metrics(ensemble_metrics),.id_req_valid(phone_lookup_valid),.id_req_pan(phone_lookup_pan),.id_req_ready(phone_lookup_ready),.id_req_key(phone_lookup_key),
  .id_req_identity(phone_lookup_identity),.id_req_generation(phone_lookup_generation),.id_req_tag(phone_lookup_tag),
  .id_response_valid(phone_response_valid),.id_response_found(phone_found),.id_response_slot(phone_response_slot),.id_response_word(phone_response_word),.id_response_tag(phone_response_tag),
  .pan_ready(r18_pan_ready),.pan_response_valid(r18_pan_response_valid),.pan_result(r18_pan_result),.pan_response_slot(r18_pan_response_slot),
  .pan_response_before(r18_pan_before),.pan_response_after(r18_pan_after),
  .fact_valid(r18_fact_valid),.fact_outcome(observe_apply_outcome),.fact_slot(observe_apply_slot),
.config_payload_changed(config_payload_changed),.clk(clk),.rst(rst),.session_flush(session_flush),.session_ready(session_ready),.session_id(session_id),
  .config_valid(config_valid),.config_ready(config_ready),.config_slot(config_slot),.config_bytes(config_bytes),
  .sample_tick(frame_pulse),.sample_time(observe_sample_time),.now_ms(now_ms),.local_glide_code(local_glide_code),.glide_code(glide_code),.timbre_id(timbre_id),
  .fx_cfg_valid(fx_cfg_valid),.fx_cfg_data(fx_cfg_data),.fx_accepted(observe_fx_accepted),.fx_frame_version(observe_fx_version),
  .gain_cfg_valid(gain_cfg_valid),.gain_local(gain_cfg_local),.gain_external(gain_cfg_external),.gain_local_mute(gain_cfg_local_mute),.gain_external_mute(gain_cfg_external_mute),
  .gain_sample(observe_gain_sample),.gain_frame(observe_gain_frame),.gain_frame_version(observe_gain_version),.gain_accepted(observe_gain_accepted),.gain_l(observe_gain_l),.gain_e(observe_gain_e),.gain_remaining(observe_gain_remaining),
  .pan_valid(pan_valid),.pan_slot(pan_slot),.pan_id(pan_id),.pan_generation(pan_generation),.pan_value(pan_value),
  .identity_stable(identity_stable),
  
  
  .local_gate(observe_local_gate),.local_pending(observe_local_pending),.keymap(remote_keymap),.keymap_version(observe_keymap_version),
  .field_valid(field_cfg_valid),.field_start(field_cfg_start),.field_size(field_cfg_size),.field_ready(ENABLE_S11?field_ready:1'b1),.field_active(field_active),.field_rejected(field_rejected),.field_committed(field_committed),.field_running(field_running),
  .lookup_valid(lookup_valid),.lookup_ready(lookup_ready),.lookup_channel(lookup_channel),.lookup_echo(lookup_echo),.lookup_sequence(lookup_sequence),.lookup_done(lookup_done),.lookup_error(lookup_error),.lookup_result(lookup_result),
  .result_valid(cfg_result_valid),.result_ready(cfg_result_ready),.result_slot(cfg_result_slot),.result_sequence(cfg_result_sequence),.result_bytes(cfg_result_bytes),.result_final(cfg_result_final));
 instrument_core_stage8 #(.AUDIO_RATE_HZ(AUDIO_RATE_HZ),.EXTERNAL_SCORE_RX(EXTERNAL_SCORE_RX),.STREAM_PHONE(1),.COMM_SEPARATE(COMM_SEPARATE),.VERSIONED_TOKENS(VERSIONED_TOKENS),
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
  .MIX_SHIFT(MIX_SHIFT),.ENABLE_S10_ROUTE(ENABLE_S10_ROUTE),.ENABLE_S11(ENABLE_S11),
  .ENABLE_REMOTE(1)) core(.shared_score_rx(shared_score_rx),
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
  .phone_session_flush(phone_session_flush),
  .phone_session_ready(phone_session_ready),
  .phone_presses(phone_presses),
  .phone_lookup_valid(phone_lookup_valid),
  .phone_lookup_pan(phone_lookup_pan),
  .phone_lookup_key(phone_lookup_key),
  .phone_lookup_identity(phone_lookup_identity),
  .phone_lookup_generation(phone_lookup_generation),
  .phone_lookup_tag(phone_lookup_tag),
  .phone_lookup_ready(phone_lookup_ready),
  .phone_response_valid(phone_response_valid),
  .phone_found(phone_found),
  .phone_response_slot(phone_response_slot),
  .phone_response_word(phone_response_word),
  .phone_response_tag(phone_response_tag),

 
  .field_valid(merged_field_valid),.field_start(merged_field_start),.field_size(merged_field_size),.field_ready(field_ready),.field_active(field_active),.field_rejected(field_rejected),.field_committed(field_committed),.field_running(field_running),
   .observe_audio_metrics(ensemble_metrics),.observe_allocator_busy(observe_allocator_busy),
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
  .score_spi_sck(spi_sck),
  .score_cs_n(score_cs_n),
  .score_sd_cs_n(score_isolated),
  .score_spi_mosi(spi_mosi),
  .score_spi_miso(score_miso),
  .score_spi_miso_oe(score_oe),
  .guide_led_dout(guide_led_dout),
  .guide_cfg_valid(guide_cfg_valid),
  .guide_cfg_prefix(guide_cfg_prefix),
  .guide_cfg_order(guide_cfg_order),
  .guide_cfg_lead(guide_cfg_lead),
  .score_state(score_state),
  .score_error(score_error),
  .score_time(score_time),
  .score_deadline_count(score_deadline_count),
  .stream_ctrl_valid(stream_ctrl_valid),
  .stream_ctrl_ready(stream_ctrl_ready),
  .stream_ctrl_cmd(stream_ctrl_cmd),
  .stream_ctrl_epoch(stream_ctrl_epoch),
  .stream_ctrl_rate(stream_ctrl_rate),
  .stream_ctrl_track(stream_ctrl_track),
  .external_valid(external_valid),
  .external_ready(external_ready),
  .external_l(external_l),
  .external_r(external_r),
  .external_epoch(external_epoch),
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
  .glide_code(glide_code),
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
  .observe_stream_state(observe_stream_state),.observe_stream_buffered(observe_stream_buffered),.observe_stream_generation(observe_stream_generation),.observe_score_status(observe_score_status),
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
  .remote_write_valid(cleanup_write_valid||phone_write_valid),.remote_write_index(cleanup_write_valid?4'd0:phone_write_index),.remote_write_data(cleanup_write_valid?cleanup_write_data:phone_write_data),.remote_write_ready(shared_write_ready),.remote_write_abort(phone_write_abort),
  .remote_event_valid(remote_event_valid),
  .remote_event_packet(remote_event_packet),
  .remote_event_ready(remote_event_ready),
  .remote_dispatch_done(remote_dispatch_done),
  .remote_keymap(remote_keymap),
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
  .observe_gain_state(observe_gain_state),.observe_gain_remaining(observe_gain_remaining));
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if((^{control_cs_n,score_cs_n,sd_cs_n,result_ready})===1'bx)$fatal(1,"S9_SYSTEM_CONTROL_XZ");
  if(spi_miso_oe&&((!control_cs_n&&!score_cs_n)||!sd_cs_n))$fatal(1,"S9_SHARED_MISO_CONTENTION");
 end
 // synthesis translate_on
endmodule
