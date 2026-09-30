// Single final conversion of a signed64 Master numerator. Preserve the old
// pending pair on overrun; simultaneous pop/push replaces both channels.
module master_pcm_stream #(
    parameter integer MIX_SHIFT=5
) (
    input wire clk,rst,in_valid,
    input wire signed [63:0] in_l,in_r,
    input wire [31:0] in_frame,
    output reg signed [15:0] sample_l,sample_r,
    output reg sample_valid,
    input wire sample_ready,
    output reg [31:0] sample_frame,
    output reg overrun,
    output reg [31:0] clip_l_count,clip_r_count
);
    localparam integer SCALE=23+MIX_SHIFT;
    wire signed [63:0] scaled_l=in_l>>>SCALE;
    wire signed [63:0] scaled_r=in_r>>>SCALE;
    function signed [15:0] saturate;
        input signed [63:0] x;
        begin
            if(x>32767)saturate=16'sh7fff;
            else if(x< -32768)saturate=16'sh8000;
            else saturate=x[15:0];
        end
    endfunction
    always @(posedge clk)begin
        if(rst)begin sample_l<=0;sample_r<=0;sample_valid<=0;sample_frame<=0;overrun<=0;clip_l_count<=0;clip_r_count<=0;end
        else begin
            if(sample_valid && sample_ready)sample_valid<=0;
            if(in_valid)begin
                if(!sample_valid || sample_ready)begin
                    sample_l<=saturate(scaled_l);sample_r<=saturate(scaled_r);
                    sample_frame<=in_frame;sample_valid<=1;
                    if(scaled_l>32767 || scaled_l< -32768)clip_l_count<=clip_l_count+1;
                    if(scaled_r>32767 || scaled_r< -32768)clip_r_count<=clip_r_count+1;
                end else overrun<=1;
            end
        end
    end
    // synthesis translate_off
    initial if(MIX_SHIFT<0 || MIX_SHIFT>23)$fatal(1,"Master PCM MIX_SHIFT range");
    // synthesis translate_on
endmodule
