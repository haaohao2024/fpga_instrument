// Tang Mega 60K NEO Dock 31004 physical board interface.
// Select THIS module as the synthesis top. Existing instrument_io_top remains
// the reusable digital instrument. KEY2/KEY1/KEY0 are all active low.
module instrument_board_top #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer SPI_CLK_HZ = 1_000_000,
    parameter integer BUTTON_DEBOUNCE_US = 20_000,
    parameter integer EC11_DEBOUNCE_US = 1000,
    parameter integer EC11_TRANSITIONS_PER_STEP = 4,
    parameter integer EC11_DIR_INVERT = 0
) (
    input wire clk,
    input wire rst_n,
    input wire octave_up_key_n,
    input wire octave_down_key_n,
    input wire adc_dout,
    output wire adc_cs_n,
    output wire adc_sclk,
    output wire adc_din,
    input wire ec11_s1,
    input wire ec11_s2,
    output wire dac_bck,
    output wire dac_ws,
    output wire dac_din,
    output wire pa_en // board PA_EN: 1=mute, 0=enabled
);
    // Power-up value maps to FPGA FF INIT bits (portable Verilog, no IP).
    // A reset request asserts asynchronously; release takes two clk edges.
    // The instrument itself still samples its active-high reset on clk.
    reg [1:0] reset_release = 2'b11;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) reset_release <= 2'b11;
        else reset_release <= {reset_release[0], 1'b0};
    end
    wire rst = reset_release[1];
    assign pa_en = rst;

    wire octave_up_pulse, octave_down_pulse;
    button_debounce_onepulse #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_US(BUTTON_DEBOUNCE_US)
    ) u_octave_up (
        .clk(clk), .rst(rst), .key_n(octave_up_key_n), .press_pulse(octave_up_pulse)
    );
    button_debounce_onepulse #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_US(BUTTON_DEBOUNCE_US)
    ) u_octave_down (
        .clk(clk), .rst(rst), .key_n(octave_down_key_n), .press_pulse(octave_down_pulse)
    );

    // Internal diagnostics, not package pins. frame_pulse remains the sole
    // audio sample clock-enable inside u_instrument; it is not a new clock.
    wire frame_pulse, sample_overrun, underrun;
    instrument_io_top #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .SPI_CLK_HZ(SPI_CLK_HZ),
        .EC11_DEBOUNCE_US(EC11_DEBOUNCE_US),
        .EC11_TRANSITIONS_PER_STEP(EC11_TRANSITIONS_PER_STEP),
        .EC11_DIR_INVERT(EC11_DIR_INVERT)
    ) u_instrument (
        .clk(clk), .rst(rst), .adc_dout(adc_dout),
        .adc_cs_n(adc_cs_n), .adc_sclk(adc_sclk), .adc_din(adc_din),
        .ec11_s1(ec11_s1), .ec11_s2(ec11_s2),
        .octave_up_pulse(octave_up_pulse), .octave_down_pulse(octave_down_pulse),
        .dac_bck(dac_bck), .dac_ws(dac_ws), .dac_din(dac_din),
        .frame_pulse(frame_pulse), .sample_overrun(sample_overrun), .underrun(underrun)
    );
endmodule
