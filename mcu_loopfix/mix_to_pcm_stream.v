// Registered 24-bit mix -> signed shift -> 16-bit saturation -> one sample hold.
// No combinational bypass. Empty + input at C0 is first handshakable at C1.
module mix_to_pcm_stream #(
    parameter integer MIX_SHIFT = 3
) (
    input wire clk,
    input wire rst,
    input wire signed [23:0] mix_sample,
    input wire mix_valid,
    output reg signed [15:0] sample_l,
    output reg signed [15:0] sample_r,
    output reg sample_valid,
    input wire sample_ready,
    output reg sample_overrun
);
    wire signed [23:0] scaled_sample = mix_sample >>> MIX_SHIFT;
    reg signed [15:0] pcm_mono;
    always @* begin
        if (scaled_sample > 24'sd32767) pcm_mono=16'sh7fff;
        else if (scaled_sample < -24'sd32768) pcm_mono=16'sh8000;
        else pcm_mono=scaled_sample[15:0]; // Only narrow AFTER range checking.
    end

    always @(posedge clk) begin
        if (rst) begin
            sample_l<=0; sample_r<=0; sample_valid<=0; sample_overrun<=0;
        end else begin
            if (sample_valid && sample_ready) sample_valid<=0;
            if (mix_valid) begin
                if (!sample_valid || sample_ready) begin
                    // A same-edge pop consumes OLD data; these registers then
                    // replace it with NEW data, keeping valid high for next clk.
                    sample_l<=pcm_mono;
                    sample_r<=pcm_mono;
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
            $fatal(1,"MIX_SHIFT must be 0..23 for signed 24-bit input");
    end
    // synthesis translate_on
endmodule
