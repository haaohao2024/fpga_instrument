// Digital instrument core: already-digitized controls to PT8211 serial pins.
// All logic uses clk; rst is synchronous and HIGH active. No vendor IP.
// Voice tables and ADSR use 48 kHz, so the system audio rate is fixed at 48 kHz.
module instrument_core_stage5 #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer ADC_ZERO = 0,
    parameter integer ADC_FULL = 1023,
    parameter integer DEADZONE = 8,
    parameter integer PRESS_THRESHOLD = 16,
    parameter integer RELEASE_THRESHOLD = 8,
    parameter integer VIBRATO_STEP = 1,
    parameter integer OCTAVE_MIN = -2,
    parameter integer OCTAVE_MAX = 2,
    parameter integer MIX_SHIFT = 5
) (
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
    output wire underrun
);
    wire [7:0] vibrato_depth;
    wire [31:0] slot_valid,slot_gate,slot_trigger;
    wire [31:0] slot_cancel;
    wire [223:0] slot_notes;
    wire [255:0] slot_pressures;
    wire [2047:0] slot_ids,done_ids;
    wire [511:0] slot_generations;
    wire [95:0] slot_timbres;
    wire [543:0] envelope_levels;
    wire [95:0] envelope_states;
    wire [31:0] done_mask;
    wire [575:0] voice_samples;
    wire [3:0] lane_deadline_error;
    wire signed [23:0] mix_sample;
    wire mix_valid,mono_mix_valid;
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
    wire [55:0] local_notes;
    wire local_event_valid, local_event_ready, arb_valid, arb_ready;
    wire event_valid, event_ready, event_overflow, event_protocol_error;
    wire [904:0] local_event_packet, arb_packet, event_packet;
    wire [2:0] event_queue_occupancy;
    wire event_fault = event_overflow | event_protocol_error;
    reg [31:0] sample_time;
    // Timestamp metadata only. Events are NEVER gated by this audio tick.
    always @(posedge clk) begin
        if (rst) sample_time<=0;
        else if (frame_pulse) sample_time<=sample_time+1'b1;
    end

    local_performance_control #(
        .ADC_ZERO(ADC_ZERO), .ADC_FULL(ADC_FULL), .DEADZONE(DEADZONE),
        .PRESS_THRESHOLD(PRESS_THRESHOLD), .RELEASE_THRESHOLD(RELEASE_THRESHOLD),
        .VIBRATO_STEP(VIBRATO_STEP), .OCTAVE_MIN(OCTAVE_MIN), .OCTAVE_MAX(OCTAVE_MAX)
    ) u_control (
        .clk(clk), .rst(rst), .pressure_raw(pressure_raw), .pressure_valid(pressure_valid),
        .step_pulse(step_pulse), .step_dir(step_dir),
        .octave_up_pulse(octave_up_pulse), .octave_down_pulse(octave_down_pulse),
        .note_gate(local_gate), .note_trigger(local_trigger),
        .pressure_value(local_pressure), .note_code(local_notes), .vibrato_depth(local_vibrato)
    );
    local_performance_event_adapter u_event_adapter (
        .clk(clk), .rst(rst), .sample_time(sample_time),
        .note_gate(local_gate), .note_trigger(local_trigger), .vibrato_depth(local_vibrato),
        .pressure_value(local_pressure), .note_code(local_notes),
        .event_valid(local_event_valid), .event_ready(local_event_ready),
        .event_packet(local_event_packet), .overflow(event_overflow)
    );
    performance_event_arbiter #(.WIDTH(905)) u_event_arbiter (
        .clk(clk), .rst(rst), .s0_valid(local_event_valid), .s0_data(local_event_packet),
        .s0_ready(local_event_ready), .s1_valid(1'b0), .s1_data(905'd0), .s1_ready(),
        .m_valid(arb_valid), .m_ready(arb_ready), .m_data(arb_packet)
    );
    performance_event_queue #(.WIDTH(905)) u_event_queue (
        .clk(clk), .rst(rst), .s_valid(arb_valid), .s_ready(arb_ready), .s_data(arb_packet),
        .m_valid(event_valid), .m_ready(event_ready), .m_data(event_packet),
        .occupancy(event_queue_occupancy)
    );
    voice_allocator32 u_event_dispatch (
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
        .id_collision_skip_count(),.id_wrap_count()
    );
    poly_synth_mixer32_stage3 u_poly (
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
    voice_pan_config u_pan (
        .clk(clk),.rst(rst),.sample_tick(frame_pulse),
        .slot_valid(slot_valid),.slot_cancel(slot_cancel),.slot_ids(slot_ids),
        .slot_generations(slot_generations),
        .pan_valid(pan_valid),.pan_slot(pan_slot),.pan_id(pan_id),
        .pan_generation(pan_generation),.pan_value(pan_value),
        .snapshot_pan(snapshot_pan),.snapshot_ids(snapshot_ids),.snapshot_generations(snapshot_generations),
        .accepted_count(pan_accepted_count),.stale_count(pan_stale_count),.invalid_count(pan_invalid_count));
    stereo_voice_mixer32 u_stereo (
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
    wire [31:0] fx_frames,fx_cfg_accepted,fx_cfg_rejected;
    stereo_effects #(.MIX_SHIFT(MIX_SHIFT)) u_effects(
        .clk(clk),.rst(rst),.sample_tick(frame_pulse),
        .in_l_q8(mix_l_q8),.in_r_q8(mix_r_q8),.in_valid(mix_valid),
        .cfg_valid(fx_cfg_valid),.cfg_data(fx_cfg_data),
        .out_l_q8(fx_l_q8),.out_r_q8(fx_r_q8),.out_valid(fx_valid),
        .protocol_error(fx_error),.frame_count(fx_frames),
        .cfg_accepted(fx_cfg_accepted),.cfg_rejected(fx_cfg_rejected),.effective_bypass(fx_bypass));
    digital_audio_output_stereo #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .SAMPLE_RATE_HZ(48_000), .MIX_SHIFT(MIX_SHIFT)
    ) u_output (
        .clk(clk), .rst(rst), .mix_l_q8(fx_l_q8),.mix_r_q8(fx_r_q8), .mix_valid(fx_valid),
        .sample_tick(frame_pulse), .dac_bck(dac_bck), .dac_ws(dac_ws), .dac_din(dac_din),
        .sample_overrun(sample_overrun), .dac_underrun(underrun)
    );
endmodule
