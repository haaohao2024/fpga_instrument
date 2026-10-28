`timescale 1ns / 1ps
// Portable RTL for Gowin GW5AT-LV60; no vendor primitives.
module ec11_encoder #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer DEBOUNCE_US = 1000,
    parameter integer TRANSITIONS_PER_STEP = 4,
    parameter integer DIR_INVERT = 0,
    parameter integer POSITION_WIDTH = 32
) (
    input  wire sys_clk,
    input  wire rst_n,       // synchronous active-low reset, supplied by parent
    input  wire s1,
    input  wire s2,
    output reg  ready,
    output reg  step_pulse,
    output reg  step_dir,    // meaningful on step_pulse; retained between steps
    output reg signed [POSITION_WIDTH-1:0] position,
    output reg  invalid_pulse // one clock for an accepted two-bit AB jump
);
    // Ceiling division; 64-bit arithmetic prevents frequency*time overflow.
    localparam [63:0] DEBOUNCE_CALC =
        (64'd1 * CLK_FREQ_HZ * DEBOUNCE_US + 64'd999999) / 64'd1000000;
    localparam [63:0] DEBOUNCE_CYCLES =
        (DEBOUNCE_CALC < 1) ? 64'd1 : DEBOUNCE_CALC;
    localparam integer DB_WIDTH = (DEBOUNCE_CYCLES < 2) ? 1 :
        $clog2(DEBOUNCE_CYCLES + 1);
    localparam integer ACC_WIDTH = (TRANSITIONS_PER_STEP < 2) ? 2 :
        $clog2(TRANSITIONS_PER_STEP + 1) + 1;

    // AB is always {S1,S2}. Neither external signal is used as a clock.
    reg [1:0] ab_meta, ab_sync;
    reg [2:0] sync_valid;
    always @(posedge sys_clk) begin
        if (!rst_n) begin
            ab_meta <= 2'b00;
            ab_sync <= 2'b00;
            sync_valid <= 3'b000;
        end else begin
            ab_meta <= {s1, s2};
            ab_sync <= ab_meta;
            sync_valid <= {sync_valid[1:0], 1'b1};
        end
    end

    // Debounce the complete AB pair so independently delayed bits cannot
    // invent intermediate states. Require N consecutive identical samples.
    reg [1:0] candidate, ab_filtered;
    reg [DB_WIDTH-1:0] stable_count;
    reg filter_ready;
    always @(posedge sys_clk) begin
        if (!rst_n) begin
            candidate <= 2'b00;
            ab_filtered <= 2'b00;
            stable_count <= 0;
            filter_ready <= 1'b0;
        end else if (!sync_valid[2]) begin
            candidate <= ab_sync;
            stable_count <= 0;
        end else if (ab_sync != candidate) begin
            candidate <= ab_sync;
            stable_count <= 1;
            if (DEBOUNCE_CYCLES == 1) begin
                ab_filtered <= ab_sync;
                filter_ready <= 1'b1;
            end
        end else if (stable_count < DEBOUNCE_CYCLES) begin
            stable_count <= stable_count + 1'b1;
            if (stable_count == DEBOUNCE_CYCLES - 1) begin
                ab_filtered <= ab_sync;
                filter_ready <= 1'b1;
            end
        end
    end

    reg [1:0] previous_ab;
    reg signed [ACC_WIDTH-1:0] residual;
    reg signed [1:0] delta;
    always @* begin
        case ({previous_ab, ab_filtered})
            // Reference positive direction: 00 -> 01 -> 11 -> 10 -> 00.
            4'b0001, 4'b0111, 4'b1110, 4'b1000: delta = 2'sd1;
            4'b0010, 4'b1011, 4'b1101, 4'b0100: delta = -2'sd1;
            default: delta = 2'sd0;
        endcase
    end

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            ready <= 1'b0;
            previous_ab <= 2'b00;
            residual <= 0;
            position <= 0;
            step_dir <= 1'b0;
            step_pulse <= 1'b0;
            invalid_pulse <= 1'b0;
        end else begin
            step_pulse <= 1'b0;
            invalid_pulse <= 1'b0;
            if (filter_ready) begin
                if (!ready) begin
                    // Seed from actual stable inputs; startup is not motion.
                    previous_ab <= ab_filtered;
                    residual <= 0;
                    ready <= 1'b1;
                end else if (ab_filtered != previous_ab) begin
                    previous_ab <= ab_filtered;
                    if (delta == 0) begin
                        // Direction cannot be recovered from a two-bit jump.
                        // Drop unfinished motion and resynchronize here.
                        residual <= 0;
                        invalid_pulse <= 1'b1;
                    end else if ((delta == 1 && residual == TRANSITIONS_PER_STEP-1) ||
                                 (delta == -1 && residual == -(TRANSITIONS_PER_STEP-1))) begin
                        residual <= 0;
                        step_pulse <= 1'b1;
                        step_dir <= (delta == 1) ^ (DIR_INVERT != 0);
                        if ((delta == 1) ^ (DIR_INVERT != 0))
                            position <= position + 1'b1;
                        else
                            position <= position - 1'b1;
                    end else begin
                        // Opposite edges cancel unfinished motion, including
                        // contact bounce that passes the time filter.
                        residual <= residual + delta;
                    end
                end
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (CLK_FREQ_HZ <= 0 || DEBOUNCE_US < 0 ||
            TRANSITIONS_PER_STEP <= 0 || POSITION_WIDTH < 2 ||
            (DIR_INVERT != 0 && DIR_INVERT != 1))
            $fatal(1, "Invalid ec11_encoder parameters");
    end
    // synthesis translate_on
endmodule
