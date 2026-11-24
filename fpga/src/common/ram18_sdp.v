// Native 1024 x 18 banks. Select follows the synchronous read, not its request.
module ram18_sdp #(parameter AW=11)(
 input wire clk,we,re,input wire[AW-1:0] wa,ra,
 input wire[17:0] di,output wire[17:0] q);
 localparam BANKS=1<<(AW-10);
 reg[AW-11:0] selected;
 wire[17:0] bank_q[0:BANKS-1];
 always @(posedge clk)if(re)selected<=ra[AW-1:10];
 assign q=bank_q[selected];
 for(genvar b=0;b<BANKS;b=b+1)begin: banks
  wire[35:0] data_out;
  assign bank_q[b]=data_out[17:0];
  SDPX9B #(.BIT_WIDTH_0(18),.BIT_WIDTH_1(18),.READ_MODE(0)) ram(
   .CLKA(clk),.CLKB(clk),.CEA(we && wa[AW-1:10]==b),.CEB(re && ra[AW-1:10]==b),
   .ADA({wa[9:0],4'b0011}),.ADB({ra[9:0],4'b0000}),.DI({18'd0,di}),.DO(data_out),
   .BLKSELA(3'd0),.BLKSELB(3'd0),.OCE(1'b1),.RESET(1'b0));
 end
endmodule
