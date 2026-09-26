// Active-low mechanical key -> one clk pulse per debounced press.
// Both press and release must be stable for DEBOUNCE_US. Holding a key
// through reset counts as one new press after the full debounce interval.
module button_debounce_onepulse #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer DEBOUNCE_US = 20_000
) (
    input wire clk,
    input wire rst, // synchronous, active high
    input wire key_n,
    output reg press_pulse
);
    localparam [63:0] CYCLES_CALC =
        (64'd1 * CLK_FREQ_HZ * DEBOUNCE_US + 64'd999999) / 64'd1000000;
    localparam [63:0] CYCLES = (CYCLES_CALC < 1) ? 64'd1 : CYCLES_CALC;
    localparam integer COUNT_WIDTH = (CYCLES <= 1) ? 1 : $clog2(CYCLES);
    localparam [COUNT_WIDTH-1:0] LAST_COUNT = CYCLES - 64'd1;

    reg key_meta, key_sync;
    reg debounced_n;
    reg [COUNT_WIDTH-1:0] stable_count;
    always @(posedge clk) begin
        if (rst) begin
            key_meta <= 1'b1;
            key_sync <= 1'b1;
        end else begin
            key_meta <= key_n;
            key_sync <= key_meta;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            debounced_n <= 1'b1;
            stable_count <= 0;
            press_pulse <= 1'b0;
        end else begin
            press_pulse <= 1'b0;
            if (key_sync == debounced_n) begin
                stable_count <= 0;
            end else if (stable_count == LAST_COUNT) begin
                debounced_n <= key_sync;
                stable_count <= 0;
                press_pulse <= !key_sync;
            end else begin
                stable_count <= stable_count + 1'b1;
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (CLK_FREQ_HZ <= 0 || DEBOUNCE_US < 0)
            $fatal(1,"Invalid button clock/debounce parameters");
    end
    // synthesis translate_on
endmodule
