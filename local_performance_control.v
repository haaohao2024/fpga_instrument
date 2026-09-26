// Local physical input events -> hardware-independent performance controls.
// All state uses clk; synchronous HIGH-active rst. No device primitives.
module local_performance_control #(
    parameter integer ADC_ZERO = 0,
    parameter integer ADC_FULL = 1023,
    parameter integer DEADZONE = 8,
    parameter integer PRESS_THRESHOLD = 16,
    parameter integer RELEASE_THRESHOLD = 8,
    parameter integer VIBRATO_STEP = 1,
    parameter integer OCTAVE_MIN = -2,
    parameter integer OCTAVE_MAX = 2
) (
    input wire clk,
    input wire rst,
    input wire [79:0] pressure_raw,
    input wire pressure_valid,
    input wire step_pulse,
    input wire step_dir,
    input wire octave_up_pulse,
    input wire octave_down_pulse,
    output reg [7:0] note_gate,
    output reg [7:0] note_trigger,
    output reg [63:0] pressure_value,
    output wire [55:0] note_code,
    output reg [7:0] vibrato_depth
);
    localparam integer ADC_SPAN = (ADC_FULL > ADC_ZERO) ?
        ADC_FULL-ADC_ZERO : ADC_ZERO-ADC_FULL;
    localparam integer ACTIVE_SPAN = ADC_SPAN-DEADZONE;
    // Avoid elaboration divide-by-zero; invalid configurations are rejected below.
    localparam integer SAFE_SPAN = (ACTIVE_SPAN > 0) ? ACTIVE_SPAN : 1;
    localparam [55:0] BASE_NOTES = {7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};

    // Shared compile-time calibration, applied independently to each channel.
    // Keep this channel-local function boundary for future per-pad calibration.
    function [7:0] normalize_pressure;
        input [9:0] raw;
        reg [9:0] distance;
        reg [9:0] active_distance;
        reg [17:0] numerator;
        begin
            if (ADC_FULL > ADC_ZERO) begin
                if (raw <= ADC_ZERO) distance = 0;
                else if (raw >= ADC_FULL) distance = ADC_SPAN;
                else distance = raw-ADC_ZERO;
            end else begin
                if (raw >= ADC_ZERO) distance = 0;
                else if (raw <= ADC_FULL) distance = ADC_SPAN;
                else distance = ADC_ZERO-raw;
            end
            active_distance = 0;
            numerator = 0;
            if (distance <= DEADZONE) normalize_pressure = 0;
            else begin
                active_distance = distance-DEADZONE;
                // Exact unsigned x*255 = x*256-x; maximum numerator is 260865.
                numerator = ({8'b0,active_distance} << 8) - {8'b0,active_distance};
                // Constant divisor: compile-time calibration, not run-time config.
                normalize_pressure = numerator / SAFE_SPAN;
            end
        end
    endfunction

    // Valid octave limits fit [-5,+4], since all eight note codes must be 0..127.
    reg signed [3:0] octave_shift;
    genvar pad;
    generate for (pad=0; pad<8; pad=pad+1) begin : pads
        localparam integer BASE_NOTE = BASE_NOTES[pad*7 +: 7];
        wire [7:0] normalized = normalize_pressure(pressure_raw[pad*10 +: 10]);
        wire signed [31:0] absolute_note = BASE_NOTE + $signed(octave_shift)*32'sd12;
        assign note_code[pad*7 +: 7] = absolute_note[6:0];

        always @(posedge clk) begin
            if (rst) begin
                note_gate[pad] <= 0;
                note_trigger[pad] <= 0;
                pressure_value[pad*8 +: 8] <= 0;
            end else begin
                // Events last one clk, even if the next ADC frame arrives later.
                note_trigger[pad] <= 0;
                if (pressure_valid) begin
                    pressure_value[pad*8 +: 8] <= normalized;
                    if (!note_gate[pad] && normalized >= PRESS_THRESHOLD) begin
                        note_gate[pad] <= 1;
                        note_trigger[pad] <= 1;
                    end else if (note_gate[pad] && normalized <= RELEASE_THRESHOLD)
                        note_gate[pad] <= 0;
                end
            end
        end
    end endgenerate

    always @(posedge clk) begin
        if (rst) begin
            octave_shift <= 0;
            vibrato_depth <= 0;
        end else begin
            // Simultaneous up/down cancels, including at a saturation boundary.
            if (octave_up_pulse && !octave_down_pulse) begin
                if ($signed(octave_shift) < OCTAVE_MAX)
                    octave_shift <= octave_shift + 1'b1;
            end else if (octave_down_pulse && !octave_up_pulse) begin
                if ($signed(octave_shift) > OCTAVE_MIN)
                    octave_shift <= octave_shift - 1'b1;
            end
            if (step_pulse) begin
                if (step_dir) begin
                    if (vibrato_depth >= 255-VIBRATO_STEP) vibrato_depth <= 255;
                    else vibrato_depth <= vibrato_depth+VIBRATO_STEP;
                end else begin
                    if (vibrato_depth <= VIBRATO_STEP) vibrato_depth <= 0;
                    else vibrato_depth <= vibrato_depth-VIBRATO_STEP;
                end
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (ADC_ZERO < 0 || ADC_ZERO > 1023 || ADC_FULL < 0 || ADC_FULL > 1023 ||
            ADC_ZERO == ADC_FULL || DEADZONE < 0 || DEADZONE >= ADC_SPAN)
            $fatal(1,"Invalid ADC calibration: require distinct 10-bit endpoints and 0<=deadzone<span");
        if (RELEASE_THRESHOLD < 0 || PRESS_THRESHOLD > 255 || RELEASE_THRESHOLD >= PRESS_THRESHOLD)
            $fatal(1,"Thresholds require 0<=RELEASE_THRESHOLD<PRESS_THRESHOLD<=255");
        if (VIBRATO_STEP < 1 || VIBRATO_STEP > 255)
            $fatal(1,"VIBRATO_STEP must be 1..255");
        if (OCTAVE_MIN < -5 || OCTAVE_MAX > 4 || OCTAVE_MIN > 0 || OCTAVE_MAX < 0)
            $fatal(1,"Octave range must contain zero and preserve all note codes within 0..127");
    end
    // synthesis translate_on
endmodule
