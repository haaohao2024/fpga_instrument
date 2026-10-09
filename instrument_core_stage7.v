// Digital instrument core: already-digitized controls to PT8211 serial pins.
// All logic uses clk; rst is synchronous and HIGH active. No vendor IP.
// Voice tables and ADSR use 48 kHz, so the system audio rate is fixed at 48 kHz.
module instrument_core_stage7 #(
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
    parameter integer MIX_SHIFT = 5,
    parameter integer ENABLE_REMOTE = 0
) (
    input wire token_snapshot_capture,token_snapshot_read,
    input wire [4:0] token_snapshot_slot,
    output wire [63:0] token_snapshot_data,

    input wire score_spi_sck,score_cs_n,score_sd_cs_n,score_spi_mosi,
    output wire score_spi_miso,score_spi_miso_oe,guide_led_dout,
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
    input wire gain_cfg_valid,
    input wire [15:0] gain_cfg_local,gain_cfg_external,
    input wire gain_cfg_local_mute,gain_cfg_external_mute,
    output wire stream_error,
    output wire [31:0] external_underflow_count,
    input wire fx_cfg_valid,
    input wire [351:0] fx_cfg_data,
    output wire fx_error,
    input wire pan_valid,
    input wire [4:0] pan_slot,
    input wire [63:0] pan_id,
    input wire [15:0] pan_generation,
    input wire [8:0] pan_value,
    input wire clk,
    input wire rst,
    input wire [79:0] pressure_raw,
    input wire pressure_valid,
    input wire step_pulse,
    input wire step_dir,
    input wire [2:0] timbre_id,
    input wire [3:0] glide_code,
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
    output wire [31:0] observe_slot_valid,observe_slot_gate,
    output wire [95:0] observe_slot_timbres,
    output wire [351:0] observe_fx_config,
    output wire [31:0] observe_fx_version,
    output wire observe_fx_bypass,observe_teach,observe_loop,
    output wire [2:0] observe_stream_state,
    output wire [11:0] observe_stream_buffered,
    output wire [31:0] observe_stream_generation,
    output wire [255:0] observe_score_status,
    // Stage9 optional composition ports; default-zero parameter preserves all
    // existing instantiations without requiring a value on new input ports.
    input wire remote_event_valid,
    input wire [904:0] remote_event_packet,
    output wire remote_event_ready,remote_dispatch_done,
    input wire [55:0] remote_keymap,
    output wire [7:0] observe_local_gate,
    output wire observe_local_pending,
    output wire [55:0] observe_local_notes,
    output wire observe_allocator_publish,
    output wire [127:0] observe_slot_sources,
    output wire [255:0] observe_slot_keys,
    output wire [2047:0] observe_slot_tokens,observe_slot_ids,
    output wire [511:0] observe_slot_generations,
    output wire [31:0] observe_slot_cancel,
    output wire [31:0] observe_sample_time,observe_fx_accepted,
    output wire [31:0] observe_pan_accepted,
    output wire [287:0] observe_snapshot_pan,
    output wire [2047:0] observe_snapshot_ids,
    output wire [511:0] observe_snapshot_generations,
    output wire observe_gain_sample,
    output wire [31:0] observe_gain_frame,observe_gain_version,observe_gain_accepted,
    output wire [15:0] observe_gain_l,observe_gain_e,
    output wire [6:0] observe_gain_remaining,
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
    output wire [511:0] observe_reclaim_generations,
    output wire [2047:0] observe_reclaim_ids,
    output wire [223:0] observe_slot_notes,
    output wire [255:0] observe_slot_pressures,
    output wire [287:0] observe_current_pan,
    output wire [103:0] observe_gain_state
);
    wire [7:0] vibrato_depth;
    wire [31:0] slot_valid,slot_gate,slot_trigger;
    wire [31:0] slot_cancel,working_public_equal;
    wire [223:0] slot_notes;
    wire [255:0] slot_pressures;
    wire [2047:0] slot_ids,done_ids;
    wire [511:0] slot_generations;
    wire [95:0] slot_timbres;
    assign observe_slot_valid=slot_valid;
    assign observe_slot_gate=slot_gate;
    assign observe_slot_timbres=slot_timbres;
    wire [543:0] envelope_levels;
    wire [95:0] envelope_states;
    wire [31:0] done_mask;
    wire [575:0] voice_samples;
    wire [3:0] lane_deadline_error;
    wire signed [23:0] mix_sample;
    wire mix_valid,mono_mix_valid;
    // The score window is a frame-control boundary, independent of when
    // the deeper arithmetic pipeline delivers PCM. Original stereo lock
    // becomes high after C25 and is consumed on C26, including cold reset.
    reg [5:0] control_frame_age;
    wire stereo_control_locked=control_frame_age==25;
    always @(posedge clk)begin
        if(rst)control_frame_age<=63;
        else if(frame_pulse)control_frame_age<=0;
        else if(control_frame_age<63)control_frame_age<=control_frame_age+1'b1;
    end
    // synthesis translate_off
    reg [2:0] control_lock_delay;
    always @(posedge clk)begin
        if(rst)control_lock_delay<=0;
        else begin
            control_lock_delay<={control_lock_delay[1:0],stereo_control_locked};
            if(mix_valid!==control_lock_delay[2])$fatal(1,"AUDIO_CONTROL_RESULT_ALIGNMENT");
        end
    end
    // synthesis translate_on
    wire [3:0] completion_valid,completion_accept;
    wire [11:0] completion_slot;
    wire [71:0] completion_sample;
    wire [255:0] completion_id;
    wire [63:0] completion_generation;
    wire [287:0] snapshot_pan;
    wire [2047:0] snapshot_ids;
    wire [511:0] snapshot_generations;
    wire signed [31:0] mix_l_q8,mix_r_q8;
    wire [31:0] pan_accepted_count,pan_stale_count,pan_invalid_count;
    wire stereo_protocol_error,stereo_deadline_error;
    wire [5:0] stereo_complete_cycle;

    wire [7:0] local_gate, local_trigger, local_vibrato;
    wire [63:0] local_pressure;
    wire [55:0] local_notes,unmapped_local_notes;
    assign observe_local_gate=local_gate;
    assign observe_local_notes=local_notes;
    assign observe_slot_notes=slot_notes;
    assign observe_slot_pressures=slot_pressures;
    assign observe_reclaim_ids=done_ids;
    assign observe_slot_ids=slot_ids;
    assign observe_slot_generations=slot_generations;
    assign observe_slot_cancel=slot_cancel;
    wire signed [8:0] octave_offset=$signed({2'b0,unmapped_local_notes[6:0]})-9'sd60;
    genvar mapped_key;
    generate for(mapped_key=0;mapped_key<8;mapped_key=mapped_key+1)begin: remote_mapping
        if(ENABLE_REMOTE)begin
            wire signed [8:0] mapped_note=$signed({2'b0,remote_keymap[mapped_key*7+:7]})+octave_offset;
            assign local_notes[mapped_key*7+:7]=mapped_note[6:0];
        end else assign local_notes[mapped_key*7+:7]=unmapped_local_notes[mapped_key*7+:7];
    end endgenerate
    wire local_event_valid, local_event_ready, arb_valid, arb_ready;
    wire event_valid, event_ready, event_overflow, event_protocol_error;
    wire [904:0] local_event_packet, arb_packet, event_packet;
    wire [2:0] event_queue_occupancy;
    wire event_fault = event_overflow | event_protocol_error;
    reg [31:0] sample_time;
    assign observe_sample_time=sample_time;
    assign observe_pan_accepted=pan_accepted_count;
    assign observe_snapshot_pan=snapshot_pan;
    assign observe_snapshot_ids=snapshot_ids;
    assign observe_snapshot_generations=snapshot_generations;
    // Timestamp metadata only. Events are NEVER gated by this audio tick.
    always @(posedge clk) begin
        if (rst) sample_time<=0;
        else if (frame_pulse) sample_time<=sample_time+1'b1;
    end

    local_performance_control #(
        .PRESSURE_PRENORMALIZED(PRESSURE_PRENORMALIZED), .ADC_ZERO(ADC_ZERO), .ADC_FULL(ADC_FULL), .DEADZONE(DEADZONE),
        .PRESS_THRESHOLD(PRESS_THRESHOLD), .RELEASE_THRESHOLD(RELEASE_THRESHOLD),
        .VIBRATO_STEP(VIBRATO_STEP), .OCTAVE_MIN(OCTAVE_MIN), .OCTAVE_MAX(OCTAVE_MAX)
    ) u_control (
        .clk(clk), .rst(rst), .pressure_raw(pressure_raw), .pressure_valid(pressure_valid),
        .step_pulse(step_pulse), .step_dir(step_dir),
        .octave_up_pulse(octave_up_pulse), .octave_down_pulse(octave_down_pulse),
        .note_gate(local_gate), .note_trigger(local_trigger),
        .pressure_value(local_pressure), .note_code(unmapped_local_notes), .vibrato_depth(local_vibrato)
    );
    local_performance_event_adapter u_event_adapter (
        .clk(clk), .rst(rst), .sample_time(sample_time),
        .note_gate(local_gate), .note_trigger(local_trigger), .vibrato_depth(local_vibrato),
        .pressure_value(local_pressure), .note_code(local_notes),
        .event_valid(local_event_valid), .event_ready(local_event_ready),
        .event_packet(local_event_packet), .overflow(event_overflow)
    );
    // Stage7 connection only: existing arbiter/queue/allocator algorithms unchanged.
    wire buffered_local_valid,buffered_local_ready,score_event_valid,score_event_ready;
    wire [904:0] buffered_local_packet,score_event_packet;
    wire [3:0] local_buffer_occupancy;
    performance_local_packet_queue u_local_elastic (
        .clk(clk),.rst(rst),.s_valid(local_event_valid),.s_ready(local_event_ready),.s_data(local_event_packet),
        .m_valid(buffered_local_valid),.m_ready(buffered_local_ready),.m_data(buffered_local_packet),.occupancy(local_buffer_occupancy));
    wire score_dispatch_active;
    reg allocator_inflight_score,allocator_was_busy,score_dispatch_done;
    always @(posedge clk)begin
        if(rst)begin allocator_inflight_score<=0;allocator_was_busy<=0;score_dispatch_done<=0;end
        else begin
            score_dispatch_done<=0;allocator_was_busy<=!event_ready;
            if(allocator_was_busy&&event_ready&&allocator_inflight_score)score_dispatch_done<=1;
            if(event_valid&&event_ready)allocator_inflight_score<=event_packet[31:28]==1;
        end
    end
    score_subsystem #(.ENABLE_S10_ROUTE(ENABLE_S10_ROUTE),.ENABLE_S11(ENABLE_S11),.STREAM_STATUS_CRC(1)) u_score (
        .field_valid(field_valid),.field_start(field_start),.field_size(field_size),.field_ready(field_ready),.field_active(field_active),.field_rejected(field_rejected),.field_committed(field_committed),.field_running(field_running),
        .clk(clk),.rst(rst),.sample_tick(frame_pulse),.stereo_locked(stereo_control_locked),
        .spi_sck(score_spi_sck),.fpga_cs_n(score_cs_n),.sd_cs_n(score_sd_cs_n),.spi_mosi(score_spi_mosi),
        .spi_miso(score_spi_miso),.spi_miso_oe(score_spi_miso_oe),.local_backlog(local_buffer_occupancy!=0),
        .event_valid(score_event_valid),.event_ready(score_event_ready),.event_packet(score_event_packet),
        .dispatch_done(score_dispatch_done),.local_notes(local_notes),
        .guide_cfg_valid(guide_cfg_valid),.guide_cfg_prefix(guide_cfg_prefix),.guide_cfg_order(guide_cfg_order),.guide_cfg_lead(guide_cfg_lead),
        .led_dout(guide_led_dout),.score_state(score_state),.score_error(score_error),.score_time(score_time),.deadline_count(score_deadline_count),.observe_teach(observe_teach),.observe_loop(observe_loop),.observe_score_status(observe_score_status),.observe_dispatch_active(score_dispatch_active));
    performance_event_arbiter #(.WIDTH(905)) u_event_arbiter (
        .clk(clk), .rst(rst), .s0_valid(buffered_local_valid), .s0_data(buffered_local_packet),
        .s0_ready(buffered_local_ready), .s1_valid(score_event_valid), .s1_data(score_event_packet), .s1_ready(score_event_ready),
        .m_valid(arb_valid), .m_ready(arb_ready), .m_data(arb_packet)
    );
    wire queue_source_valid,queue_source_ready;
    wire [904:0] queue_source_packet;
    reg allocator_inflight_phone,allocator_inflight_local;
    reg [4:0] local_uncommitted;
    assign remote_dispatch_done=observe_allocator_publish&&allocator_inflight_phone;
    assign observe_local_pending=local_event_valid||local_uncommitted!=0;
    always @(posedge clk)begin
        if(rst)begin allocator_inflight_phone<=0;allocator_inflight_local<=0;local_uncommitted<=0;end
        else begin
            if(event_valid&&event_ready)begin
                allocator_inflight_phone<=event_packet[31:28]==2;
                allocator_inflight_local<=event_packet[31:28]==0;
            end
            case({local_event_valid&&local_event_ready,observe_allocator_publish&&allocator_inflight_local})
                2'b10:local_uncommitted<=local_uncommitted+1'b1;
                2'b01:local_uncommitted<=local_uncommitted-1'b1;
                default:local_uncommitted<=local_uncommitted;
            endcase
        end
    end
    generate if(ENABLE_REMOTE)begin: phone_arbitration
        s9_event_arbiter #(.GUARDED_ADMISSION(1)) u_remote_arbiter(.legacy_urgent(score_dispatch_active),.clk(clk),.rst(rst),
            .legacy_valid(arb_valid),.legacy_packet(arb_packet),.legacy_ready(arb_ready),
            .phone_valid(remote_event_valid),.phone_packet(remote_event_packet),.phone_ready(remote_event_ready),
            .out_valid(queue_source_valid),.out_packet(queue_source_packet),.out_ready(queue_source_ready));
    end else begin: original_arbitration
        assign queue_source_valid=arb_valid;
        assign queue_source_packet=arb_packet;
        assign arb_ready=queue_source_ready;
        assign remote_event_ready=1'b0;
    end endgenerate
    wire [3:0] allocator_item_index;
    wire [95:0] allocator_item_data;
    performance_indexed_event_queue u_event_queue (
        .clk(clk),.rst(rst),.s_valid(queue_source_valid),.s_ready(queue_source_ready),.s_data(queue_source_packet),
        .m_valid(event_valid),.m_ready(event_ready && !event_fault),.m_data(event_packet),
        .retire(observe_allocator_publish || observe_batch_abort),
        .item_index(allocator_item_index),.item_data(allocator_item_data),.occupancy(event_queue_occupancy));
    voice_allocator32 #(.ONE_RECLAIM_PER_LANE(1),.INDEXED_INPUT(1),.VERSIONED_TOKENS(VERSIONED_TOKENS)) u_event_dispatch (
        .token_snapshot_capture(token_snapshot_capture),.token_snapshot_read(token_snapshot_read),.token_snapshot_slot(token_snapshot_slot),.token_snapshot_data(token_snapshot_data),
        .event_item(allocator_item_data),.event_item_index(allocator_item_index),
        .observe_working_public_equal(working_public_equal),
        .clk(clk), .rst(rst), .panic(event_fault),
        .event_valid(event_valid), .event_ready(event_ready), .event_packet(event_packet),
        .timbre_id(timbre_id),
        .sample_tick(frame_pulse),.envelope_levels(envelope_levels),
        .done_mask(done_mask),.done_ids(done_ids),
        .slot_valid(slot_valid),.slot_gate(slot_gate),.slot_trigger(slot_trigger),
        .slot_cancel(slot_cancel),
        .slot_notes(slot_notes),.slot_pressures(slot_pressures),
        .slot_ids(slot_ids),.slot_generations(slot_generations),
        .slot_timbres(slot_timbres),
        .vibrato_depth(vibrato_depth),.protocol_error(event_protocol_error),
        .steal_count(),.stale_count(),.allocation_count(),.reclaim_count(),
        .id_collision_skip_count(),.id_wrap_count(),
          .observe_busy(observe_allocator_busy),
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
  .observe_reclaim_mask(observe_reclaim_mask),.observe_reclaim_generations(observe_reclaim_generations),
        .observe_publish(observe_allocator_publish),.observe_sources(observe_slot_sources),
        .observe_keys(observe_slot_keys),.observe_tokens(observe_slot_tokens)
    );
    poly_synth_mixer32_owner_directory #(.COMPACT_RECLAIM(1),.SHARED_BACKEND(1)) u_poly (
        .owner_allocate(observe_apply_valid&&observe_apply_outcome==1),.owner_publish(observe_allocator_publish),
        .owner_allocate_slot(observe_apply_slot[4:0]),.owner_allocate_id(observe_apply_id),
        .owner_allocate_generation(observe_apply_generation),.working_public_equal(working_public_equal),
        .clk(clk), .rst(rst), .sample_tick(frame_pulse),
        .slot_valid(slot_valid),.slot_gate(slot_gate),.slot_trigger(slot_trigger),
        .slot_cancel(slot_cancel),
        .slot_notes(slot_notes),.slot_pressures(slot_pressures),
        .slot_ids(slot_ids),.slot_generations(slot_generations),
        .slot_timbres(slot_timbres),.glide_code(glide_code),
        .vibrato_depth(vibrato_depth),
        .mix_sample(mix_sample), .mix_valid(mono_mix_valid),
        .completion_valid(completion_valid),.completion_accept(completion_accept),
        .completion_slot(completion_slot),.completion_sample(completion_sample),
        .completion_id(completion_id),.completion_generation(completion_generation),
        .envelope_levels(envelope_levels),.envelope_states(envelope_states),
        .done_mask(done_mask),.done_ids(done_ids),.voice_samples(voice_samples),
        .lane_deadline_error(lane_deadline_error)
    );
    voice_pan_config #(.ALLOCATOR_OWNERSHIP(1)) u_pan (
        .clk(clk),.rst(rst),.sample_tick(frame_pulse),
        .slot_valid(slot_valid),.slot_cancel(slot_cancel),.slot_ids(slot_ids),
        .slot_generations(slot_generations),
        .pan_valid(pan_valid),.pan_slot(pan_slot),.pan_id(pan_id),
        .pan_generation(pan_generation),.pan_value(pan_value),
        .snapshot_pan(snapshot_pan),.snapshot_ids(snapshot_ids),.snapshot_generations(snapshot_generations),
        .observe_current_pan(observe_current_pan),
        .accepted_count(pan_accepted_count),.stale_count(pan_stale_count),.invalid_count(pan_invalid_count));
    stereo_voice_mixer32 #(.COMPLETION_LIMIT(28)) u_stereo (
        .clk(clk),.rst(rst),.sample_tick(frame_pulse),
        .completion_valid(completion_valid),.completion_accept(completion_accept),
        .completion_slot(completion_slot),.completion_sample(completion_sample),
        .completion_id(completion_id),.completion_generation(completion_generation),
        .snapshot_pan(snapshot_pan),.snapshot_ids(snapshot_ids),.snapshot_generations(snapshot_generations),
        .mix_l_q8(mix_l_q8),.mix_r_q8(mix_r_q8),.mix_valid(mix_valid),
        .protocol_error(stereo_protocol_error),.deadline_error(stereo_deadline_error),
        .last_complete_cycle(stereo_complete_cycle));
    wire signed [31:0] fx_l_q8,fx_r_q8;
    wire fx_valid,fx_bypass;
    assign observe_fx_bypass=fx_bypass;
    wire [31:0] fx_frames,fx_cfg_accepted,fx_cfg_rejected;
    assign observe_fx_accepted=fx_cfg_accepted;
    stereo_effects #(.MIX_SHIFT(MIX_SHIFT),.SCHEDULED_CONTROL(1)) u_effects(
        .clk(clk),.rst(rst),.sample_tick(frame_pulse),
        .in_l_q8(mix_l_q8),.in_r_q8(mix_r_q8),.in_valid(mix_valid),
        .cfg_valid(fx_cfg_valid),.cfg_data(fx_cfg_data),
        .out_l_q8(fx_l_q8),.out_r_q8(fx_r_q8),.out_valid(fx_valid),
        .protocol_error(fx_error),.frame_count(fx_frames),
        .cfg_accepted(fx_cfg_accepted),.cfg_rejected(fx_cfg_rejected),.effective_bypass(fx_bypass),.observe_config(observe_fx_config),.observe_version(observe_fx_version));
    digital_audio_output_master #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .SAMPLE_RATE_HZ(48_000), .MIX_SHIFT(MIX_SHIFT)
    ) u_output (
        .stream_ctrl_valid(stream_ctrl_valid),.stream_ctrl_ready(stream_ctrl_ready),
        .stream_ctrl_cmd(stream_ctrl_cmd),.stream_ctrl_epoch(stream_ctrl_epoch),.stream_ctrl_rate(stream_ctrl_rate),.stream_ctrl_track(stream_ctrl_track),
        .external_valid(external_valid),.external_ready(external_ready),.external_l(external_l),.external_r(external_r),.external_epoch(external_epoch),
        .gain_cfg_valid(gain_cfg_valid),.gain_cfg_local(gain_cfg_local),.gain_cfg_external(gain_cfg_external),
        .gain_cfg_local_mute(gain_cfg_local_mute),.gain_cfg_external_mute(gain_cfg_external_mute),
        .stream_error(stream_error),.external_underflow_count(external_underflow_count),.deadline_error(),
        .clk(clk), .rst(rst), .mix_l_q8(fx_l_q8),.mix_r_q8(fx_r_q8), .mix_valid(fx_valid),
        .sample_tick(frame_pulse), .dac_bck(dac_bck), .dac_ws(dac_ws), .dac_din(dac_din),
        .sample_overrun(sample_overrun), .dac_underrun(underrun),
        .observe_load(observe_load),.observe_l(observe_l),.observe_r(observe_r),.observe_stream_state(observe_stream_state),.observe_stream_buffered(observe_stream_buffered),.observe_stream_generation(observe_stream_generation),
        .observe_gain_state(observe_gain_state),.observe_gain_sample(observe_gain_sample),.observe_gain_frame(observe_gain_frame),
        .observe_gain_version(observe_gain_version),.observe_gain_accepted(observe_gain_accepted),
        .observe_gain_l(observe_gain_l),.observe_gain_e(observe_gain_e),.observe_gain_remaining(observe_gain_remaining)
    );
    // synthesis translate_off
    generate for(genvar contract_lane=0;contract_lane<4;contract_lane=contract_lane+1)begin: reclaim_contract
        always @(posedge clk)if(!rst)begin
            if($isunknown({done_mask[contract_lane*8+:8],observe_reclaim_mask[contract_lane*8+:8]}))
                $fatal(1,"CORE7_RECLAIM_XZ");
            if(!$onehot0(done_mask[contract_lane*8+:8]) || !$onehot0(observe_reclaim_mask[contract_lane*8+:8]))
                $fatal(1,"CORE7_RECLAIM_MULTI");
            if((observe_reclaim_mask[contract_lane*8+:8] & ~done_mask[contract_lane*8+:8])!=0)
                $fatal(1,"CORE7_RECLAIM_NOT_SUBSET");
        end
    end endgenerate
    // synthesis translate_on
endmodule

// One system-clock event per cycle from a latched nine-lane batch.
// NOTE_OFF and expression match source/key/press_token, never pitch.
// Instance zero is invalid. ID_WIDTH can be reduced in TB to exercise wrap.
module r12_owner_audio_probe #(parameter integer ID_WIDTH=64, ONE_RECLAIM_PER_LANE=1, OWNER_DIRECTORY=1) (
    input wire clk, rst, panic, sample_tick,
    input wire event_valid,
    output wire event_ready,
    input wire [904:0] event_packet,
    // Configuration is sampled only when a NOTE_ON actually allocates a slot.
    input wire [2:0] timbre_id,
    output wire [543:0] envelope_levels,
    output wire [31:0] done_mask,
    output wire [2047:0] done_ids,
    output wire [31:0] slot_valid, slot_gate, slot_trigger,
    output wire [31:0] slot_cancel,
    output wire [223:0] slot_notes,
    output wire [255:0] slot_pressures,
    output wire [2047:0] slot_ids,
    output wire [511:0] slot_generations,
    output wire [95:0] slot_timbres,
    output reg [7:0] vibrato_depth,
    output reg protocol_error,
    output reg [31:0] steal_count, stale_count, allocation_count,
    output reg [31:0] reclaim_count, id_collision_skip_count, id_wrap_count,
    // Read-only publication/identity export. No observer feeds allocator state.
    output wire [31:0] observe_working_public_equal,
    output wire observe_publish,
    output wire [127:0] observe_sources,
    output wire [255:0] observe_keys,
    output wire [2047:0] observe_tokens,
    // Stage11: passive decision taps, sampled on the ORIGINAL apply edge.
    // outcome: 1 allocate, 2 off, 3 pitch/pressure, 4 vibrato, 5 stale,
    // 6 invalid item. A working batch is durable only after publish_ok.
    output wire observe_busy, observe_batch_begin, observe_publish_ok,
    output wire observe_batch_abort, observe_apply_valid,
    output wire [31:0] observe_batch_timestamp,
    output wire [3:0] observe_apply_lane,
    output wire [95:0] observe_apply_item,
    output wire [7:0] observe_apply_outcome,
    output wire [5:0] observe_apply_slot,
    output wire [63:0] observe_apply_id,
    output wire [15:0] observe_apply_generation,
    output wire [2:0] observe_apply_timbre,
    output wire observe_apply_steal,
    output wire [63:0] observe_retired_id,
    output wire [15:0] observe_retired_generation,
    output wire [31:0] observe_reclaim_mask,
    output wire [511:0] observe_reclaim_generations,
    output wire [23:0] mix_sample,output wire mix_valid,
    output wire [95:0] envelope_states,output wire [575:0] voice_samples,
    output wire [3:0] completion_valid,completion_accept,lane_deadline_error,
    output wire [11:0] completion_slot,output wire [71:0] completion_sample,
    output wire [255:0] completion_id,output wire [63:0] completion_generation
);
voice_allocator32 #(.ID_WIDTH(ID_WIDTH),.ONE_RECLAIM_PER_LANE(1)) allocator(.clk(clk),.rst(rst),.panic(panic),.sample_tick(sample_tick),.event_valid(event_valid),.event_ready(event_ready),.event_packet(event_packet),.timbre_id(timbre_id),.envelope_levels(envelope_levels),.done_mask(done_mask),.done_ids(done_ids),.slot_valid(slot_valid),.slot_gate(slot_gate),.slot_trigger(slot_trigger),.slot_cancel(slot_cancel),.slot_notes(slot_notes),.slot_pressures(slot_pressures),.slot_ids(slot_ids),.slot_generations(slot_generations),.slot_timbres(slot_timbres),.vibrato_depth(vibrato_depth),.protocol_error(protocol_error),.steal_count(steal_count),.stale_count(stale_count),.allocation_count(allocation_count),.reclaim_count(reclaim_count),.id_collision_skip_count(id_collision_skip_count),.id_wrap_count(id_wrap_count),.observe_working_public_equal(observe_working_public_equal),.observe_publish(observe_publish),.observe_sources(observe_sources),.observe_keys(observe_keys),.observe_tokens(observe_tokens),.observe_busy(observe_busy),.observe_batch_begin(observe_batch_begin),.observe_publish_ok(observe_publish_ok),.observe_batch_abort(observe_batch_abort),.observe_apply_valid(observe_apply_valid),.observe_batch_timestamp(observe_batch_timestamp),.observe_apply_lane(observe_apply_lane),.observe_apply_item(observe_apply_item),.observe_apply_outcome(observe_apply_outcome),.observe_apply_slot(observe_apply_slot),.observe_apply_id(observe_apply_id),.observe_apply_generation(observe_apply_generation),.observe_apply_timbre(observe_apply_timbre),.observe_apply_steal(observe_apply_steal),.observe_retired_id(observe_retired_id),.observe_retired_generation(observe_retired_generation),.observe_reclaim_mask(observe_reclaim_mask),.observe_reclaim_generations(observe_reclaim_generations));
generate if(OWNER_DIRECTORY)begin: optimized
poly_synth_mixer32_owner_directory #(.COMPACT_RECLAIM(1),.SHARED_BACKEND(1)) poly(.owner_allocate(observe_apply_valid&&observe_apply_outcome==1),.owner_publish(observe_publish),
 .owner_allocate_slot(observe_apply_slot[4:0]),.owner_allocate_id(observe_apply_id),.owner_allocate_generation(observe_apply_generation),
 .working_public_equal(observe_working_public_equal),.clk(clk),.rst(rst),.sample_tick(sample_tick),.slot_valid(slot_valid),.slot_gate(slot_gate),.slot_trigger(slot_trigger),.slot_cancel(slot_cancel),.slot_notes(slot_notes),.slot_pressures(slot_pressures),.slot_ids(slot_ids),.slot_generations(slot_generations),.slot_timbres(slot_timbres),.vibrato_depth(vibrato_depth),.mix_sample(mix_sample),.mix_valid(mix_valid),.envelope_levels(envelope_levels),.envelope_states(envelope_states),.done_mask(done_mask),.done_ids(done_ids),.voice_samples(voice_samples),.completion_valid(completion_valid),.completion_accept(completion_accept),.completion_slot(completion_slot),.completion_sample(completion_sample),.completion_id(completion_id),.completion_generation(completion_generation),.lane_deadline_error(lane_deadline_error),.glide_code(4'd7));
end else begin: baseline
poly_synth_mixer32_stage3 #(.COMPACT_RECLAIM(1),.SHARED_BACKEND(1)) poly(.clk(clk),.rst(rst),.sample_tick(sample_tick),.slot_valid(slot_valid),.slot_gate(slot_gate),.slot_trigger(slot_trigger),.slot_cancel(slot_cancel),.slot_notes(slot_notes),.slot_pressures(slot_pressures),.slot_ids(slot_ids),.slot_generations(slot_generations),.slot_timbres(slot_timbres),.vibrato_depth(vibrato_depth),.mix_sample(mix_sample),.mix_valid(mix_valid),.envelope_levels(envelope_levels),.envelope_states(envelope_states),.done_mask(done_mask),.done_ids(done_ids),.voice_samples(voice_samples),.completion_valid(completion_valid),.completion_accept(completion_accept),.completion_slot(completion_slot),.completion_sample(completion_sample),.completion_id(completion_id),.completion_generation(completion_generation),.lane_deadline_error(lane_deadline_error),.glide_code(4'd7));
end endgenerate
endmodule

module allocator_indexed_probe (
    input wire clk, rst, panic, sample_tick,
    input wire event_valid,
    output wire event_ready,
    input wire [904:0] event_packet,
    input wire [95:0] event_item,
    output wire [3:0] event_item_index,
    // Configuration is sampled only when a NOTE_ON actually allocates a slot.
    input wire [2:0] timbre_id,
    input wire [543:0] envelope_levels,
    input wire [31:0] done_mask,
    input wire [2047:0] done_ids,
    output wire [31:0] slot_valid, slot_gate, slot_trigger,
    output wire [31:0] slot_cancel,
    output wire [223:0] slot_notes,
    output wire [255:0] slot_pressures,
    output wire [2047:0] slot_ids,
    output wire [511:0] slot_generations,
    output wire [95:0] slot_timbres,
    output wire [7:0] vibrato_depth,
    output wire protocol_error,
    output wire [31:0] steal_count, stale_count, allocation_count,
    output wire [31:0] reclaim_count, id_collision_skip_count, id_wrap_count,
    // Read-only publication/identity export. No observer feeds allocator state.
    output wire [31:0] observe_working_public_equal,
    output wire observe_publish,
    output wire [127:0] observe_sources,
    output wire [255:0] observe_keys,
    output wire [2047:0] observe_tokens,
    // Stage11: passive decision taps, sampled on the ORIGINAL apply edge.
    // outcome: 1 allocate, 2 off, 3 pitch/pressure, 4 vibrato, 5 stale,
    // 6 invalid item. A working batch is durable only after publish_ok.
    output wire observe_busy, observe_batch_begin, observe_publish_ok,
    output wire observe_batch_abort, observe_apply_valid,
    output wire [31:0] observe_batch_timestamp,
    output wire [3:0] observe_apply_lane,
    output wire [95:0] observe_apply_item,
    output wire [7:0] observe_apply_outcome,
    output wire [5:0] observe_apply_slot,
    output wire [63:0] observe_apply_id,
    output wire [15:0] observe_apply_generation,
    output wire [2:0] observe_apply_timbre,
    output wire observe_apply_steal,
    output wire [63:0] observe_retired_id,
    output wire [15:0] observe_retired_generation,
    output wire [31:0] observe_reclaim_mask,
    output wire [511:0] observe_reclaim_generations
);
voice_allocator32 #(.ID_WIDTH(64),.ONE_RECLAIM_PER_LANE(1),.INDEXED_INPUT(1)) dut(.clk(clk),.rst(rst),.panic(panic),.sample_tick(sample_tick),.event_valid(event_valid),.event_ready(event_ready),.event_packet(event_packet),.event_item(event_item),.event_item_index(event_item_index),.timbre_id(timbre_id),.envelope_levels(envelope_levels),.done_mask(done_mask),.done_ids(done_ids),.slot_valid(slot_valid),.slot_gate(slot_gate),.slot_trigger(slot_trigger),.slot_cancel(slot_cancel),.slot_notes(slot_notes),.slot_pressures(slot_pressures),.slot_ids(slot_ids),.slot_generations(slot_generations),.slot_timbres(slot_timbres),.vibrato_depth(vibrato_depth),.protocol_error(protocol_error),.steal_count(steal_count),.stale_count(stale_count),.allocation_count(allocation_count),.reclaim_count(reclaim_count),.id_collision_skip_count(id_collision_skip_count),.id_wrap_count(id_wrap_count),.observe_working_public_equal(observe_working_public_equal),.observe_publish(observe_publish),.observe_sources(observe_sources),.observe_keys(observe_keys),.observe_tokens(observe_tokens),.observe_busy(observe_busy),.observe_batch_begin(observe_batch_begin),.observe_publish_ok(observe_publish_ok),.observe_batch_abort(observe_batch_abort),.observe_apply_valid(observe_apply_valid),.observe_batch_timestamp(observe_batch_timestamp),.observe_apply_lane(observe_apply_lane),.observe_apply_item(observe_apply_item),.observe_apply_outcome(observe_apply_outcome),.observe_apply_slot(observe_apply_slot),.observe_apply_id(observe_apply_id),.observe_apply_generation(observe_apply_generation),.observe_apply_timbre(observe_apply_timbre),.observe_apply_steal(observe_apply_steal),.observe_retired_id(observe_retired_id),.observe_retired_generation(observe_retired_generation),.observe_reclaim_mask(observe_reclaim_mask),.observe_reclaim_generations(observe_reclaim_generations));
endmodule

module allocator_event_queue_probe (
    input wire clk, rst, panic, sample_tick,
    input wire event_valid,
    output wire event_ready,
    input wire [904:0] event_packet,
    input wire [95:0] event_item,
    output wire [3:0] event_item_index,
    // Configuration is sampled only when a NOTE_ON actually allocates a slot.
    input wire [2:0] timbre_id,
    input wire [543:0] envelope_levels,
    input wire [31:0] done_mask,
    input wire [2047:0] done_ids,
    output wire [31:0] slot_valid, slot_gate, slot_trigger,
    output wire [31:0] slot_cancel,
    output wire [223:0] slot_notes,
    output wire [255:0] slot_pressures,
    output wire [2047:0] slot_ids,
    output wire [511:0] slot_generations,
    output wire [95:0] slot_timbres,
    output wire [7:0] vibrato_depth,
    output wire protocol_error,
    output wire [31:0] steal_count, stale_count, allocation_count,
    output wire [31:0] reclaim_count, id_collision_skip_count, id_wrap_count,
    // Read-only publication/identity export. No observer feeds allocator state.
    output wire [31:0] observe_working_public_equal,
    output wire observe_publish,
    output wire [127:0] observe_sources,
    output wire [255:0] observe_keys,
    output wire [2047:0] observe_tokens,
    // Stage11: passive decision taps, sampled on the ORIGINAL apply edge.
    // outcome: 1 allocate, 2 off, 3 pitch/pressure, 4 vibrato, 5 stale,
    // 6 invalid item. A working batch is durable only after publish_ok.
    output wire observe_busy, observe_batch_begin, observe_publish_ok,
    output wire observe_batch_abort, observe_apply_valid,
    output wire [31:0] observe_batch_timestamp,
    output wire [3:0] observe_apply_lane,
    output wire [95:0] observe_apply_item,
    output wire [7:0] observe_apply_outcome,
    output wire [5:0] observe_apply_slot,
    output wire [63:0] observe_apply_id,
    output wire [15:0] observe_apply_generation,
    output wire [2:0] observe_apply_timbre,
    output wire observe_apply_steal,
    output wire [63:0] observe_retired_id,
    output wire [15:0] observe_retired_generation,
    output wire [31:0] observe_reclaim_mask,
    output wire [511:0] observe_reclaim_generations
);
wire q_valid,a_ready;wire [904:0] q_header;wire [95:0] q_item;wire [2:0] q_count;
performance_indexed_event_queue queue(.clk(clk),.rst(rst),.s_valid(event_valid),.s_ready(event_ready),.s_data(event_packet),
 .m_valid(q_valid),.m_ready(a_ready && !panic),.m_data(q_header),
 .retire(observe_publish_ok || observe_batch_abort),.item_index(event_item_index),.item_data(q_item),.occupancy(q_count));
voice_allocator32 #(.ID_WIDTH(64),.ONE_RECLAIM_PER_LANE(1),.INDEXED_INPUT(1)) dut(.clk(clk),.rst(rst),.panic(panic),.sample_tick(sample_tick),.event_valid(q_valid),.event_ready(a_ready),.event_packet(q_header),.event_item(q_item),.event_item_index(event_item_index),.timbre_id(timbre_id),.envelope_levels(envelope_levels),.done_mask(done_mask),.done_ids(done_ids),.slot_valid(slot_valid),.slot_gate(slot_gate),.slot_trigger(slot_trigger),.slot_cancel(slot_cancel),.slot_notes(slot_notes),.slot_pressures(slot_pressures),.slot_ids(slot_ids),.slot_generations(slot_generations),.slot_timbres(slot_timbres),.vibrato_depth(vibrato_depth),.protocol_error(protocol_error),.steal_count(steal_count),.stale_count(stale_count),.allocation_count(allocation_count),.reclaim_count(reclaim_count),.id_collision_skip_count(id_collision_skip_count),.id_wrap_count(id_wrap_count),.observe_working_public_equal(observe_working_public_equal),.observe_publish(observe_publish),.observe_sources(observe_sources),.observe_keys(observe_keys),.observe_tokens(observe_tokens),.observe_busy(observe_busy),.observe_batch_begin(observe_batch_begin),.observe_publish_ok(observe_publish_ok),.observe_batch_abort(observe_batch_abort),.observe_apply_valid(observe_apply_valid),.observe_batch_timestamp(observe_batch_timestamp),.observe_apply_lane(observe_apply_lane),.observe_apply_item(observe_apply_item),.observe_apply_outcome(observe_apply_outcome),.observe_apply_slot(observe_apply_slot),.observe_apply_id(observe_apply_id),.observe_apply_generation(observe_apply_generation),.observe_apply_timbre(observe_apply_timbre),.observe_apply_steal(observe_apply_steal),.observe_retired_id(observe_retired_id),.observe_retired_generation(observe_retired_generation),.observe_reclaim_mask(observe_reclaim_mask),.observe_reclaim_generations(observe_reclaim_generations));
endmodule
