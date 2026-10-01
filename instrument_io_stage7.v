// Complete digital instrument including original ADC and EC11 input drivers.
// One system clock. rst is synchronous, active high. No vendor primitives.
// Octave inputs must already be debounced one-clock events.
module instrument_io_stage7 #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer SPI_CLK_HZ = 1_000_000,
    parameter integer EC11_DEBOUNCE_US = 1000,
    parameter integer EC11_TRANSITIONS_PER_STEP = 4,
    parameter integer EC11_DIR_INVERT = 0
) (

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
    input wire [2:0] timbre_id,
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
    instrument_core_stage7 #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_core (
        .score_spi_sck(score_spi_sck),
        .score_cs_n(score_cs_n),
        .score_sd_cs_n(score_sd_cs_n),
        .score_spi_mosi(score_spi_mosi),
        .score_spi_miso(score_spi_miso),
        .score_spi_miso_oe(score_spi_miso_oe),
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
        .timbre_id(timbre_id),.glide_code(glide_code),

        .clk(clk), .rst(rst), .pressure_raw(pressure_raw), .pressure_valid(pressure_valid),
        .step_pulse(step_pulse), .step_dir(step_dir),
        .octave_up_pulse(octave_up_pulse), .octave_down_pulse(octave_down_pulse),
        .dac_bck(dac_bck), .dac_ws(dac_ws), .dac_din(dac_din),
        .frame_pulse(frame_pulse), .sample_overrun(sample_overrun), .underrun(underrun)
    );
endmodule
