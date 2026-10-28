// Two shared signed multipliers. A command on edge N is consumed at N+2.
module fx_mac_pair(
    input wire clk,rst,
    input wire signed [23:0] a0,a1,
    input wire signed [17:0] b0,b1,
    output reg signed [47:0] q0,q1
);
    reg signed [41:0] p0,p1;
    always @(posedge clk) begin
        if(rst)begin p0<=0;p1<=0;q0<=0;q1<=0;end
        else begin p0<=a0*b0;p1<=a1*b1;q0<=p0;q1<=p1;end
    end
endmodule
