// DVI TMDS, one pixel per clock. D0 is transmitted first.
module video_tmds_encoder(
 input wire clk,rst,de,input wire [7:0] data,input wire c0,c1,
 output reg [9:0] symbol
);
 reg signed [5:0] disparity;
 reg [8:0] q;
 reg [9:0] next_symbol;
 integer ones, balance, i;
 reg use_xnor;
 always @* begin
  ones=0;for(i=0;i<8;i=i+1)ones=ones+data[i];
  use_xnor=(ones>4)||((ones==4)&&!data[0]);
  q[0]=data[0];
  for(i=1;i<8;i=i+1)q[i]=use_xnor ? ~(q[i-1]^data[i]) : (q[i-1]^data[i]);
  q[8]=!use_xnor;
  ones=0;for(i=0;i<8;i=i+1)ones=ones+q[i];
  balance=2*ones-8;
  if(disparity==0||balance==0) next_symbol={~q[8],q[8],q[8]?q[7:0]:~q[7:0]};
  else if((disparity>0&&balance>0)||(disparity<0&&balance<0))next_symbol={1'b1,q[8],~q[7:0]};
  else next_symbol={1'b0,q[8],q[7:0]};
 end
 always @(posedge clk)begin
  if(rst)begin disparity<=0;symbol<=10'b1101010100;end
  else if(!de)begin
   disparity<=0;
   case({c1,c0})
    2'b00:symbol<=10'b1101010100;
    2'b01:symbol<=10'b0010101011;
    2'b10:symbol<=10'b0101010100;
    2'b11:symbol<=10'b1010101011;
   endcase
  end else begin
   symbol<=next_symbol;
   // Net imbalance of all ten transmitted bits, including the two flags.
   if(next_symbol[9]) disparity<=disparity-balance+2*q[8];
   else disparity<=disparity+balance-2*!q[8];
  end
 end
endmodule
