// MCP3008 single-ended, 24-clock SPI Mode 0,0.
// Reference: Microchip DS21295D, Figure 6-1 and timing table, pages 4, 21.
// All sequential logic uses sys_clk. adc_sclk is an output, never an RTL clock.
module mcp3008_spi #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer SPI_CLK_HZ = 1_000_000
) (
    input wire sys_clk,
    input wire rst_n,             // synchronous low-active reset
    input wire start,             // accepted only when busy=0
    input wire [2:0] channel,
    output wire busy,
    output reg sample_valid,      // one sys_clk pulse after CS rises
    output reg [2:0] sample_channel,
    output reg [9:0] sample_data,
    output reg adc_cs_n,
    output reg adc_sclk,
    output reg adc_din,           // FPGA -> MCP3008 DIN (MOSI)
    input wire adc_dout           // MCP3008 DOUT -> FPGA (MISO)
);
    // Ceiling divider: actual SCLK never exceeds requested SPI_CLK_HZ.
    localparam [63:0] SAFE_SPI_HZ = (SPI_CLK_HZ > 0) ? SPI_CLK_HZ : 1;
    localparam [63:0] HALF_CALC =
        (64'd1 * CLK_FREQ_HZ + 2*SAFE_SPI_HZ - 1) / (2*SAFE_SPI_HZ);
    localparam [63:0] HALF_CYCLES = (HALF_CALC < 1) ? 1 : HALF_CALC;
    // At least 1 us high between conversions; datasheet minimum is 270 ns.
    localparam [63:0] GAP_CALC = (64'd1 * CLK_FREQ_HZ + 999999) / 1000000;
    localparam [63:0] GAP_CYCLES = (GAP_CALC < 1) ? 1 : GAP_CALC;
    localparam [63:0] MAX_COUNT = (HALF_CYCLES > GAP_CYCLES) ? HALF_CYCLES : GAP_CYCLES;
    localparam integer COUNT_WIDTH = (MAX_COUNT < 2) ? 1 : $clog2(MAX_COUNT);

    localparam [1:0] IDLE=0, TRANSFER=1, HOLD_CS=2, GAP=3;
    reg [1:0] state;
    reg [COUNT_WIDTH-1:0] timer;
    reg [4:0] bit_index;          // 0..23, rising edges 1..24
    reg [23:0] tx_shift;
    reg [9:0] rx_shift;
    reg dout_meta, dout_sync;
    assign busy = (state != IDLE);

    // Synchronizer latency is included in the supported timing envelope below.
    always @(posedge sys_clk) begin
        if (!rst_n) begin
            dout_meta <= 1'b0;
            dout_sync <= 1'b0;
        end else begin
            dout_meta <= adc_dout;
            dout_sync <= dout_meta;
        end
    end

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            state <= GAP;        // guarantee initial CS-high interval
            timer <= 0;
            bit_index <= 0;
            tx_shift <= 0;
            rx_shift <= 0;
            sample_valid <= 0;
            sample_channel <= 0;
            sample_data <= 0;
            adc_cs_n <= 1;
            adc_sclk <= 0;
            adc_din <= 0;
        end else begin
            sample_valid <= 0;
            case (state)
                IDLE: begin
                    timer <= 0;
                    if (start) begin
                        // 7 leading zeroes, start=1, single-ended=1,
                        // D2/D1/D0, then 12 don't-care zeroes.
                        tx_shift <= {7'b0, 1'b1, 1'b1, channel, 12'b0};
                        rx_shift <= 0;
                        sample_channel <= channel;
                        bit_index <= 0;
                        adc_cs_n <= 0;
                        adc_sclk <= 0;
                        adc_din <= 0;
                        state <= TRANSFER;
                    end
                end
                TRANSFER: begin
                    if (timer == HALF_CYCLES-1) begin
                        timer <= 0;
                        if (!adc_sclk) begin
                            adc_sclk <= 1;
                            // Null is on rising edge 14; data are edges 15..24.
                            if (bit_index >= 14)
                                rx_shift <= {rx_shift[8:0], dout_sync};
                        end else begin
                            adc_sclk <= 0;
                            if (bit_index == 23) begin
                                adc_din <= 0;
                                state <= HOLD_CS;
                            end else begin
                                bit_index <= bit_index + 1'b1;
                                tx_shift <= {tx_shift[22:0], 1'b0};
                                adc_din <= tx_shift[22];
                            end
                        end
                    end else timer <= timer + 1'b1;
                end
                HOLD_CS: begin
                    // Complete last high phase, then hold CS for one low half.
                    if (timer == HALF_CYCLES-1) begin
                        timer <= 0;
                        adc_cs_n <= 1;
                        sample_data <= rx_shift;
                        sample_valid <= 1;
                        state <= GAP;
                    end else timer <= timer + 1'b1;
                end
                GAP: begin
                    if (timer == GAP_CYCLES-1) begin
                        timer <= 0;
                        state <= IDLE;
                    end else timer <= timer + 1'b1;
                end
                default: begin
                    state <= GAP;
                    timer <= 0;
                    adc_cs_n <= 1;
                    adc_sclk <= 0;
                    adc_din <= 0;
                end
            endcase
        end
    end

    // Simulation-only configuration guard; no run-time divider or delay logic.
    // 1.35 MHz uses the datasheet's lower-voltage rating conservatively.
    // Allow 200 ns ADC output delay + 3 sys_clk periods + 50 ns margin.
    // synthesis translate_off
    initial begin
        if (CLK_FREQ_HZ <= 0 || SPI_CLK_HZ < 10000 || SPI_CLK_HZ > 1350000)
            $fatal(1, "Use positive sys_clk and SPI_CLK_HZ in 10 kHz..1.35 MHz");
        if (64'd1 * CLK_FREQ_HZ < 64'd20000 * HALF_CYCLES)
            $fatal(1, "Rounded actual SPI clock is below 10 kHz");
        if (HALF_CYCLES * 64'd1000000000 < 64'd250 * CLK_FREQ_HZ + 64'd3000000000)
            $fatal(1, "Not enough MISO half-cycle margin for synchronizer");
    end
    // synthesis translate_on
endmodule
