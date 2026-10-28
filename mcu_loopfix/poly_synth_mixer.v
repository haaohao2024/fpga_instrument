// Eight complete independent synth_voice instances plus a 3-level mixer.
// sample_tick E0 -> all voice outputs E10 -> mix output E13 (260ns at 50MHz).
// Uses the reviewed synth_voice unchanged, including Release pitch/pressure hold.
module poly_synth_mixer #(
    parameter integer VOICE_NUM = 8, // Fixed interface: this version accepts 8 only.
    parameter integer ATTACK_MS = 10,
    parameter integer DECAY_MS = 50,
    parameter integer SUSTAIN_LEVEL = 180,
    parameter integer RELEASE_MS = 100,
    parameter integer VIBRATO_RATE_HZ = 5,
    parameter integer VIBRATO_MAX_PPM = 10000
) (
    input wire clk,
    input wire rst,
    input wire sample_tick,
    input wire [55:0] note_code,
    input wire [7:0] note_gate,
    input wire [7:0] note_trigger,
    input wire [63:0] pressure_value,
    input wire [7:0] vibrato_depth,
    input wire [1:0] timbre_id,
    output wire signed [23:0] mix_sample,
    output wire mix_valid
);
    wire [143:0] voice_samples;
    wire [7:0] voice_valid;
    genvar i;
    generate for (i=0; i<8; i=i+1) begin : voices
        wire signed [17:0] voice_sample;
        synth_voice #(
            .ATTACK_MS(ATTACK_MS), .DECAY_MS(DECAY_MS),
            .SUSTAIN_LEVEL(SUSTAIN_LEVEL), .RELEASE_MS(RELEASE_MS),
            .VIBRATO_RATE_HZ(VIBRATO_RATE_HZ), .VIBRATO_MAX_PPM(VIBRATO_MAX_PPM)
        ) u_voice (
            .clk(clk), .rst(rst), .sample_tick(sample_tick),
            .note_code(note_code[i*7 +: 7]),
            .gate(note_gate[i]), .trigger(note_trigger[i]),
            .pressure(pressure_value[i*8 +: 8]),
            .vibrato_depth(vibrato_depth), .timbre_id(timbre_id),
            .voice_sample(voice_sample), .sample_valid(voice_valid[i])
        );
        // NEVER gate this sample with note_gate: released voices have tails.
        assign voice_samples[i*18 +: 18] = voice_sample;
    end endgenerate

    signed_mixer8 u_mixer (
        .clk(clk), .rst(rst), .voice_samples(voice_samples),
        .voice_valid(voice_valid), .mix_sample(mix_sample), .mix_valid(mix_valid)
    );

    // synthesis translate_off
    initial begin
        if (VOICE_NUM != 8)
            $fatal(1,"poly_synth_mixer has a fixed eight-voice interface; VOICE_NUM must be 8");
    end
    // synthesis translate_on
endmodule
