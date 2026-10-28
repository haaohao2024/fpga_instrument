// Audio-only reset. Display reset cannot restart the DAC frame identity.
module visual_dac_observer(
 input wire clk,audio_rst,observe_load,input wire signed [15:0] observe_l,observe_r,
 output wire sample_valid,output wire signed [15:0] sample_l,sample_r,
 output wire [63:0] sample_id,output reg [63:0] observed_count
);
 assign sample_valid=observe_load&&!audio_rst;
 assign sample_l=observe_l;assign sample_r=observe_r;
 assign sample_id=observed_count;
 always @(posedge clk)if(audio_rst)observed_count<=0;else if(observe_load)observed_count<=observed_count+1'b1;
endmodule
