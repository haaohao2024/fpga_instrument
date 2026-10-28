// Digital instrument core: already-digitized controls to PT8211 serial pins.
// All logic uses clk; rst is synchronous and HIGH active. No vendor IP.
// Voice tables and ADSR use 48 kHz, so the system audio rate is fixed at 48 kHz.
module instrument_core_stage3 #(
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
    wire mix_valid;
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
        .mix_sample(mix_sample), .mix_valid(mix_valid),
        .envelope_levels(envelope_levels),.envelope_states(envelope_states),
        .done_mask(done_mask),.done_ids(done_ids),.voice_samples(voice_samples),
        .lane_deadline_error(lane_deadline_error)
    );
    digital_audio_output #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .SAMPLE_RATE_HZ(48_000), .MIX_SHIFT(MIX_SHIFT)
    ) u_output (
        .clk(clk), .rst(rst), .mix_sample(mix_sample), .mix_valid(mix_valid),
        .sample_tick(frame_pulse), .dac_bck(dac_bck), .dac_ws(dac_ws), .dac_din(dac_din),
        .sample_overrun(sample_overrun), .dac_underrun(underrun)
    );
endmodule
