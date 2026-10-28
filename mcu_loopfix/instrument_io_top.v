// Complete digital instrument including original ADC and EC11 input drivers.
// One system clock. rst is synchronous, active high. No vendor primitives.
// Octave inputs must already be debounced one-clock events.
module instrument_io_top #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer SPI_CLK_HZ = 1_000_000,
    parameter integer EC11_DEBOUNCE_US = 1000,
    parameter integer EC11_TRANSITIONS_PER_STEP = 4,
    parameter integer EC11_DIR_INVERT = 0
) (
    input wire clk,
    input wire rst,
    input wire adc_dout,
    output wire adc_cs_n,
    output wire adc_sclk,
    output wire adc_din,
    input wire ec11_s1,
    input wire ec11_s2,
    input wire glide_ec11_s1,
    input wire glide_ec11_s2,
    input wire octave_up_pulse,
    input wire octave_down_pulse,
    output wire dac_bck,
    output wire dac_ws,
    output wire dac_din,
    output wire frame_pulse,
    output wire sample_overrun,
    output wire underrun
);
    wire [79:0] pressure_raw;
    wire pressure_valid, step_pulse, step_dir;
    wire ec11_ready, ec11_invalid;
    wire signed [31:0] ec11_position;
    wire glide_step_pulse,glide_step_dir;
    wire [3:0] glide_code;
    pressure_input_top #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .SPI_CLK_HZ(SPI_CLK_HZ)) u_adc (
        .sys_clk(clk), .rst_n(~rst), .adc_cs_n(adc_cs_n),
        .adc_sclk(adc_sclk), .adc_din(adc_din), .adc_dout(adc_dout),
        .pressure_raw(pressure_raw), .pressure_valid(pressure_valid)
    );
    ec11_encoder #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_US(EC11_DEBOUNCE_US),
        .TRANSITIONS_PER_STEP(EC11_TRANSITIONS_PER_STEP), .DIR_INVERT(EC11_DIR_INVERT)) u_ec11 (
        .sys_clk(clk), .rst_n(~rst), .s1(ec11_s1), .s2(ec11_s2),
        .ready(ec11_ready), .step_pulse(step_pulse), .step_dir(step_dir),
        .position(ec11_position), .invalid_pulse(ec11_invalid)
    );
    ec11_encoder #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_US(EC11_DEBOUNCE_US),
        .TRANSITIONS_PER_STEP(EC11_TRANSITIONS_PER_STEP), .DIR_INVERT(EC11_DIR_INVERT)) u_glide_ec11 (
        .sys_clk(clk),.rst_n(~rst),.s1(glide_ec11_s1),.s2(glide_ec11_s2),
        .ready(),.step_pulse(glide_step_pulse),.step_dir(glide_step_dir),
        .position(),.invalid_pulse()
    );
    glide_parameter_control u_glide_parameter (
        .clk(clk),.rst(rst),.step_pulse(glide_step_pulse),
        .step_dir(glide_step_dir),.glide_code(glide_code)
    );
`ifdef STAGE2_COMPAT
    // Verification-only mode: keep the frozen stage-2 hierarchy and samples.
    instrument_core #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_core (
`else
    instrument_core_stage6 #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_core (
        .stream_ctrl_valid(1'b0),.stream_ctrl_ready(),.stream_ctrl_cmd(2'd0),
        .stream_ctrl_epoch(64'd0),.stream_ctrl_rate(32'd48000),.stream_ctrl_track(1'b1),
        .external_valid(1'b0),.external_ready(),.external_l(16'sd0),.external_r(16'sd0),.external_epoch(64'd0),
        .gain_cfg_valid(1'b0),.gain_cfg_local(16'd32768),.gain_cfg_external(16'd32768),
        .gain_cfg_local_mute(1'b0),.gain_cfg_external_mute(1'b0),.stream_error(),.external_underflow_count(),
        .fx_cfg_valid(1'b0),.fx_cfg_data(352'd0),.fx_error(),
        .pan_valid(1'b0),.pan_slot(5'd0),.pan_id(64'd0),.pan_generation(16'd0),.pan_value(9'd128),
        .timbre_id(3'd1), .glide_code(glide_code),
`endif
        .clk(clk), .rst(rst), .pressure_raw(pressure_raw), .pressure_valid(pressure_valid),
        .step_pulse(step_pulse), .step_dir(step_dir),
        .octave_up_pulse(octave_up_pulse), .octave_down_pulse(octave_down_pulse),
        .dac_bck(dac_bck), .dac_ws(dac_ws), .dac_din(dac_din),
        .frame_pulse(frame_pulse), .sample_overrun(sample_overrun), .underrun(underrun)
    );
endmodule
