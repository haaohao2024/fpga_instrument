// Digital output chain only. Existing PT8211 is the SOLE audio-rate master.
// Connect sample_tick directly to upstream poly_synth_mixer.sample_tick.
// Both blocks use the same clk and synchronous high-active rst.
module digital_audio_output #(
    parameter integer MIX_SHIFT = 3,
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer SAMPLE_RATE_HZ = 48_000
) (
    input wire clk,
    input wire rst,
    input wire signed [23:0] mix_sample,
    input wire mix_valid,
    output wire sample_tick,
    output wire dac_bck,
    output wire dac_ws,
    output wire dac_din,
    output wire sample_overrun,
    output wire dac_underrun
);
    wire signed [15:0] pcm_l, pcm_r;
    wire pcm_valid, pcm_ready;
    mix_to_pcm_stream #(.MIX_SHIFT(MIX_SHIFT)) u_pcm (
        .clk(clk), .rst(rst), .mix_sample(mix_sample), .mix_valid(mix_valid),
        .sample_l(pcm_l), .sample_r(pcm_r), .sample_valid(pcm_valid),
        .sample_ready(pcm_ready), .sample_overrun(sample_overrun)
    );
    pt8211_audio_out #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)) u_pt8211 (
        .sys_clk(clk), .rst_n(~rst),
        .sample_l(pcm_l), .sample_r(pcm_r),
        .sample_valid(pcm_valid), .sample_ready(pcm_ready),
        .dac_bck(dac_bck), .dac_ws(dac_ws), .dac_din(dac_din),
        .frame_pulse(sample_tick), .underrun(dac_underrun)
    );
endmodule
