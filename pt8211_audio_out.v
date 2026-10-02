// 16-bit signed stereo PCM -> PT8211 Japanese/LSBJ interface.
// Producer holds sample_valid and both samples until sample_ready is high.
// No synthesis, volume processing, format conversion or Xilinx primitives.
module pt8211_audio_out #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer SAMPLE_RATE_HZ = 48_000
) (
    input wire sys_clk,
    input wire rst_n, // synchronous, low-active
    input wire signed [15:0] sample_l,
    input wire signed [15:0] sample_r,
    input wire sample_valid,
    output wire sample_ready,
    output wire dac_bck,
    output wire dac_ws,
    output wire dac_din,
    output reg frame_pulse, // frame launch, not transmission completion
    output reg underrun,   // one sys_clk pulse: launched a silent frame
    output wire observe_load,
    output wire signed [15:0] observe_l,observe_r
);
    reg pending_full;
    reg [15:0] pending_l, pending_r;
    wire frame_load;
    wire accept_sample = sample_valid && sample_ready;
    assign sample_ready = rst_n && (!pending_full || frame_load);

    // Fall-through: a sample accepted exactly on a frame boundary can be sent
    // immediately when the buffer is empty. Otherwise the oldest sample wins.
    wire [15:0] next_l = pending_full ? pending_l : (sample_valid ? sample_l : 16'd0);
    wire [15:0] next_r = pending_full ? pending_r : (sample_valid ? sample_r : 16'd0);
    // Read-only: values sampled by serializer on THIS frame_load edge.
    assign observe_load=frame_load;
    assign observe_l=next_l;
    assign observe_r=next_r;
    pt8211_serializer #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)) u_serializer (
        .sys_clk(sys_clk), .rst_n(rst_n), .frame_l(next_l), .frame_r(next_r),
        .frame_load(frame_load), .dac_bck(dac_bck), .dac_ws(dac_ws), .dac_din(dac_din)
    );

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            pending_full <= 0;
            pending_l <= 0;
            pending_r <= 0;
            frame_pulse <= 0;
            underrun <= 0;
        end else begin
            frame_pulse <= frame_load;
            underrun <= frame_load && !pending_full && !sample_valid;
            if (frame_load) begin
                if (pending_full && accept_sample) begin
                    // Send buffered pair and refill with the newly accepted pair.
                    pending_l <= sample_l;
                    pending_r <= sample_r;
                    pending_full <= 1;
                end else begin
                    // Empty + accept uses direct bypass; nothing left pending.
                    pending_full <= 0;
                end
            end else if (accept_sample) begin
                pending_l <= sample_l;
                pending_r <= sample_r;
                pending_full <= 1;
            end
        end
    end
endmodule
