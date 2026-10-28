// Registered Q8 stereo mix -> one final shift/saturation -> paired sample hold.
// No combinational bypass. Empty + input at C0 is first handshakable at C1.
module mix_to_pcm_stream_stereo #(
    parameter integer MIX_SHIFT = 5
) (
    input wire clk,
    input wire rst,
    input wire signed [31:0] mix_l_q8,mix_r_q8,
    input wire mix_valid,
    output reg signed [15:0] sample_l,
    output reg signed [15:0] sample_r,
    output reg sample_valid,
    input wire sample_ready,
    output reg sample_overrun
);
    function signed [15:0] convert;
        input signed [31:0] x;
        reg signed [31:0] y;
        begin
            y=x >>> (8+MIX_SHIFT);
            if(y>32767)convert=16'sh7fff;
            else if(y< -32768)convert=16'sh8000;
            else convert=y[15:0];
        end
    endfunction
    always @(posedge clk) begin
        if (rst) begin
            sample_l<=0; sample_r<=0; sample_valid<=0; sample_overrun<=0;
        end else begin
            if (sample_valid && sample_ready) sample_valid<=0;
            if (mix_valid) begin
                if (!sample_valid || sample_ready) begin
                    // A same-edge pop consumes OLD data; these registers then
                    // replace it with NEW data, keeping valid high for next clk.
                    sample_l<=convert(mix_l_q8);
                    sample_r<=convert(mix_r_q8);
                    sample_valid<=1;
                end else begin
                    // Preserve OLD pending sample, explicitly discard NEW input.
                    // Sticky diagnostic: only reset clears the error.
                    sample_overrun<=1;
                end
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (MIX_SHIFT<0 || MIX_SHIFT>23)
            $fatal(1,"MIX_SHIFT must be 0..23 for stereo Q8 input");
    end
    // synthesis translate_on
endmodule
