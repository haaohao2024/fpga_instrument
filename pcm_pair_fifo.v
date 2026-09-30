// Synchronous 2048 stereo-pair FIFO. RAM is deliberately not reset.
// A pop at C0 produces out_valid/data after C1. No empty fall-through.
// Full + pop does not accept a push until the next clock.
module pcm_pair_fifo (
    input wire clk,rst,clear,
    input wire in_valid,
    input wire [31:0] in_data,
    output wire in_ready,
    input wire pop,
    output wire pop_ready,
    output reg out_valid,
    output reg [31:0] out_data,
    output reg [11:0] occupancy
);
    reg [31:0] memory [0:2047];
    reg [10:0] wp,rp;
    reg [31:0] ram_q;
    reg read_pending;
    assign in_ready=!rst && !clear && occupancy<2048;
    assign pop_ready=!rst && !clear && occupancy!=0;
    wire push=in_valid && in_ready;
    wire take=pop && pop_ready;
    always @(posedge clk) begin
        if(rst || clear)begin
            wp<=0;rp<=0;occupancy<=0;read_pending<=0;out_valid<=0;
            ram_q<=0;out_data<=0;
        end else begin
            read_pending<=take;
            out_valid<=read_pending;
            if(read_pending)out_data<=ram_q;
            if(push)begin memory[wp]<=in_data;wp<=wp+1'b1;end
            if(take)begin ram_q<=memory[rp];rp<=rp+1'b1;end
            case({push,take})
                2'b10:occupancy<=occupancy+1'b1;
                2'b01:occupancy<=occupancy-1'b1;
                default:occupancy<=occupancy;
            endcase
        end
    end
endmodule
