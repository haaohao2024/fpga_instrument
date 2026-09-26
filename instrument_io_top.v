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
    instrument_core #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_core (
        .clk(clk), .rst(rst), .pressure_raw(pressure_raw), .pressure_valid(pressure_valid),
        .step_pulse(step_pulse), .step_dir(step_dir),
        .octave_up_pulse(octave_up_pulse), .octave_down_pulse(octave_down_pulse),
        .dac_bck(dac_bck), .dac_ws(dac_ws), .dac_din(dac_din),
        .frame_pulse(frame_pulse), .sample_overrun(sample_overrun), .underrun(underrun)
    );
endmodule
