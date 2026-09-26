// Fixed eight-input signed adder tree. No gain, clipping, quantization or FIFO.
// A producer's registered valid at E0 is consumed by level 1 at E1;
// level 2 follows at E2 and mix_sample/mix_valid are published at E3.
module signed_mixer8 (
    input wire clk,
    input wire rst,
    input wire [143:0] voice_samples, // Eight packed signed 18-bit samples.
    input wire [7:0] voice_valid,
    output reg signed [23:0] mix_sample,
    output reg mix_valid
);
    wire signed [23:0] extended_sample [0:7];
    genvar i;
    generate for (i=0; i<8; i=i+1) begin : extend
        assign extended_sample[i] =
            {{6{voice_samples[i*18+17]}},voice_samples[i*18 +: 18]};
    end endgenerate

    wire all_valid = &voice_valid;
    reg stage1_valid, stage2_valid;
    reg signed [23:0] sum01, sum23, sum45, sum67;
    reg signed [23:0] sum03, sum47;

    always @(posedge clk) begin
        if (rst) begin
            sum01<=0; sum23<=0; sum45<=0; sum67<=0;
            sum03<=0; sum47<=0; mix_sample<=0;
            stage1_valid<=0; stage2_valid<=0; mix_valid<=0;
        end else begin
            stage1_valid<=all_valid;
            stage2_valid<=stage1_valid;
            mix_valid<=stage2_valid;
            if (all_valid) begin
                sum01<=extended_sample[0]+extended_sample[1];
                sum23<=extended_sample[2]+extended_sample[3];
                sum45<=extended_sample[4]+extended_sample[5];
                sum67<=extended_sample[6]+extended_sample[7];
            end
            if (stage1_valid) begin
                sum03<=sum01+sum23;
                sum47<=sum45+sum67;
            end
            if (stage2_valid) mix_sample<=sum03+sum47;
        end
    end

    // The common sample_tick makes alignment an invariant, including silent
    // voices. Stop simulation on a violation; do not hide it with queues.
    // synthesis translate_off
    always @(posedge clk) begin
        if (!rst && voice_valid !== 8'h00 && voice_valid !== 8'hff)
            $fatal(1,"signed_mixer8: voice_valid must be aligned (00 or ff), got %h",voice_valid);
    end
    // synthesis translate_on
endmodule
