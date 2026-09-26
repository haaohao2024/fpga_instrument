// Scan CH0..CH7. Publish complete 80-bit frames atomically.
module pressure_scanner (
    input wire sys_clk,
    input wire rst_n,
    input wire adc_busy,
    output wire adc_start,
    output reg [2:0] adc_channel,
    input wire adc_sample_valid,
    input wire [9:0] adc_sample_data,
    output reg [79:0] pressure_raw,
    output reg pressure_valid
);
    localparam REQUEST=1'b0, WAIT_RESULT=1'b1;
    reg state;
    reg [79:0] frame_work;
    assign adc_start = rst_n && (state == REQUEST) && !adc_busy;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            state <= REQUEST;
            adc_channel <= 0;
            frame_work <= 0;
            pressure_raw <= 0;
            pressure_valid <= 0;
        end else begin
            pressure_valid <= 0;
            case (state)
                REQUEST: if (!adc_busy) state <= WAIT_RESULT;
                WAIT_RESULT: if (adc_sample_valid) begin
                    frame_work[adc_channel*10 +: 10] <= adc_sample_data;
                    if (adc_channel == 7) begin
                        // Use the new CH7 directly: frame_work[79:70] still
                        // contains the previous value on this clock edge.
                        pressure_raw <= {adc_sample_data, frame_work[69:0]};
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
