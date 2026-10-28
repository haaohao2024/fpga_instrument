// Integration module for Tang Mega 60K (Gowin GW5AT-LV60).
// rst_n and result bus connect to parent FPGA logic, not unassigned board IOs.
module pressure_input_top #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer SPI_CLK_HZ = 1_000_000,
    parameter integer ADC_ZERO=0, ADC_FULL=1023, DEADZONE=8
) (
    input wire sys_clk,
    input wire rst_n,
    output wire adc_cs_n,
    output wire adc_sclk,
    output wire adc_din,
    input wire adc_dout,
    output wire [79:0] pressure_raw,
    output wire [63:0] pressure_normalized,
    output wire pressure_valid
);
    wire busy, start, sample_valid;
    wire [2:0] channel;
    wire [9:0] sample_data;
    wire [2:0] sample_channel;

    mcp3008_spi #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .SPI_CLK_HZ(SPI_CLK_HZ)) u_spi (
        .sys_clk(sys_clk), .rst_n(rst_n), .start(start), .channel(channel),
        .busy(busy), .sample_valid(sample_valid),
        .sample_channel(sample_channel), .sample_data(sample_data),
        .adc_cs_n(adc_cs_n), .adc_sclk(adc_sclk), .adc_din(adc_din),
        .adc_dout(adc_dout)
    );
    pressure_scanner #(.ADC_ZERO(ADC_ZERO),.ADC_FULL(ADC_FULL),.DEADZONE(DEADZONE)) u_scanner (
        .sys_clk(sys_clk), .rst_n(rst_n), .adc_busy(busy),
        .adc_start(start), .adc_channel(channel),
        .adc_sample_valid(sample_valid), .adc_sample_data(sample_data),
        .pressure_raw(pressure_raw), .pressure_normalized(pressure_normalized), .pressure_valid(pressure_valid)
    );
endmodule
