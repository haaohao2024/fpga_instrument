// Digital instrument core: already-digitized controls to PT8211 serial pins.
// All logic uses clk; rst is synchronous and HIGH active. No vendor IP.
// Voice tables and ADSR use 48 kHz, so the system audio rate is fixed at 48 kHz.
module instrument_core #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer ADC_ZERO = 0,
    parameter integer ADC_FULL = 1023,
    parameter integer DEADZONE = 8,
    parameter integer PRESS_THRESHOLD = 16,
    parameter integer RELEASE_THRESHOLD = 8,
    parameter integer VIBRATO_STEP = 1,
    parameter integer OCTAVE_MIN = -2,
    parameter integer OCTAVE_MAX = 2,
    parameter integer MIX_SHIFT = 3
) (
    input wire clk,
    input wire rst,
    input wire [79:0] pressure_raw,
    input wire pressure_valid,
    input wire step_pulse,
    input wire step_dir,
    input wire octave_up_pulse,
    input wire octave_down_pulse,
    output wire dac_bck,
    output wire dac_ws,
    output wire dac_din,
    output wire frame_pulse,
    output wire sample_overrun,
    output wire underrun
);
    wire [7:0] note_gate, note_trigger, vibrato_depth;
    wire [63:0] pressure_value;
    wire [55:0] note_code;
    wire signed [23:0] mix_sample;
    wire mix_valid;

    local_performance_control #(
        .ADC_ZERO(ADC_ZERO), .ADC_FULL(ADC_FULL), .DEADZONE(DEADZONE),
        .PRESS_THRESHOLD(PRESS_THRESHOLD), .RELEASE_THRESHOLD(RELEASE_THRESHOLD),
        .VIBRATO_STEP(VIBRATO_STEP), .OCTAVE_MIN(OCTAVE_MIN), .OCTAVE_MAX(OCTAVE_MAX)
    ) u_control (
        .clk(clk), .rst(rst), .pressure_raw(pressure_raw), .pressure_valid(pressure_valid),
        .step_pulse(step_pulse), .step_dir(step_dir),
        .octave_up_pulse(octave_up_pulse), .octave_down_pulse(octave_down_pulse),
        .note_gate(note_gate), .note_trigger(note_trigger),
        .pressure_value(pressure_value), .note_code(note_code), .vibrato_depth(vibrato_depth)
    );
    poly_synth_mixer u_poly (
        .clk(clk), .rst(rst), .sample_tick(frame_pulse),
        .note_code(note_code), .note_gate(note_gate), .note_trigger(note_trigger),
        .pressure_value(pressure_value), .vibrato_depth(vibrato_depth), .timbre_id(2'd0),
        .mix_sample(mix_sample), .mix_valid(mix_valid)
    );
    digital_audio_output #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .SAMPLE_RATE_HZ(48_000), .MIX_SHIFT(MIX_SHIFT)
    ) u_output (
        .clk(clk), .rst(rst), .mix_sample(mix_sample), .mix_valid(mix_valid),
        .sample_tick(frame_pulse), .dac_bck(dac_bck), .dac_ws(dac_ws), .dac_din(dac_din),
        .sample_overrun(sample_overrun), .dac_underrun(underrun)
    );
endmodule
