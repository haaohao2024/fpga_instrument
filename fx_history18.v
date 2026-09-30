// One synchronous read port, one write port; RAM contents are NEVER reset.
// wr_ptr points to the next write. lag=1 is the preceding written sample.
module fx_history18 #(
    parameter integer DEPTH=2048, LENGTH=2048, AW=11
)(
    input wire clk,rst,clear,
    input wire read_en,
    input wire [14:0] read_lag,
    output reg signed [17:0] read_data,
    output reg read_valid,
    input wire write_en,
    input wire signed [17:0] write_data
);
    reg signed [17:0] mem[0:DEPTH-1];
    reg [AW-1:0] wr_ptr;
    reg [14:0] filled;
    reg signed [17:0] read_pipe;
    reg pipe_valid,pipe_known;
    wire [15:0] address_wide = ({1'b0,wr_ptr}>=read_lag) ?
        ({1'b0,wr_ptr}-read_lag) : ({1'b0,wr_ptr}+LENGTH-read_lag);
    always @(posedge clk) begin
        if(read_en) read_pipe<=mem[address_wide[AW-1:0]];
        if(write_en && !rst && !clear) mem[wr_ptr]<=write_data;
        if(rst || clear) begin
            wr_ptr<=0;filled<=0;pipe_valid<=0;pipe_known<=0;
            read_data<=0;read_valid<=0;
        end else begin
            pipe_valid<=read_en;
            pipe_known<=read_en && read_lag>=1 && read_lag<=filled && read_lag<=LENGTH;
            read_valid<=pipe_valid;
            read_data<=pipe_known ? read_pipe : 18'sd0;
            if(write_en) begin
                wr_ptr<=(wr_ptr==LENGTH-1)?0:wr_ptr+1'b1;
                if(filled<LENGTH)filled<=filled+1'b1;
            end
        end
    end
endmodule
