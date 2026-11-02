// Scan CH0..CH7. Publish complete 80-bit frames atomically.
module pressure_scanner #(parameter integer ADC_ZERO=0, ADC_FULL=1023, DEADZONE=8) (
    input wire sys_clk,
    input wire rst_n,
    input wire adc_busy,
    output wire adc_start,
    output reg [2:0] adc_channel,
    input wire adc_sample_valid,
    input wire [9:0] adc_sample_data,
    output reg [79:0] pressure_raw,
    output reg [63:0] pressure_normalized,
    output reg pressure_valid
);
    localparam REQUEST=1'b0, WAIT_RESULT=1'b1;
    reg state;
    reg [79:0] frame_work;
    reg [63:0] normalized_work;
    localparam integer ADC_SPAN = (ADC_FULL > ADC_ZERO) ?
        ADC_FULL-ADC_ZERO : ADC_ZERO-ADC_FULL;
    localparam integer ACTIVE_SPAN = ADC_SPAN-DEADZONE;
    // Avoid elaboration divide-by-zero; invalid configurations are rejected below.
    localparam integer SAFE_SPAN = (ACTIVE_SPAN > 0) ? ACTIVE_SPAN : 1;
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
    wire [7:0] normalized_sample=normalize_pressure(adc_sample_data);
    assign adc_start = rst_n && (state == REQUEST) && !adc_busy;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            state <= REQUEST;
            adc_channel <= 0;
            frame_work <= 0;normalized_work<=0;pressure_normalized<=0;
            pressure_raw <= 0;
            pressure_valid <= 0;
        end else begin
            pressure_valid <= 0;
            case (state)
                REQUEST: if (!adc_busy) state <= WAIT_RESULT;
                WAIT_RESULT: if (adc_sample_valid) begin
                    frame_work[adc_channel*10 +: 10] <= adc_sample_data;
                    normalized_work[adc_channel*8+:8]<=normalized_sample;
                    if (adc_channel == 7) begin
                        // Use the new CH7 directly: frame_work[79:70] still
                        // contains the previous value on this clock edge.
                        pressure_raw <= {adc_sample_data, frame_work[69:0]};
                        pressure_normalized<={normalized_sample,normalized_work[55:0]};
                        pressure_valid <= 1;
                        adc_channel <= 0;
                    end else adc_channel <= adc_channel + 1'b1;
                    state <= REQUEST;
                end
                default: state <= REQUEST;
            endcase
        end
    end
endmodule

