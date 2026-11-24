module ram18_dp #(parameter AW=12)(
 input wire clk,ea,eb,wea,web,input wire[AW-1:0] aa,ab,
 input wire[17:0] da,db,output wire[17:0] qa,qb);
 localparam BANKS=1<<(AW-10);
 reg[AW-11:0] selected_a,selected_b;
 wire[17:0] bank_a[0:BANKS-1],bank_b[0:BANKS-1];
 always @(posedge clk)begin
  if(ea && !wea)selected_a<=aa[AW-1:10];
  if(eb && !web)selected_b<=ab[AW-1:10];
 end
 assign qa=bank_a[selected_a];assign qb=bank_b[selected_b];
 for(genvar b=0;b<BANKS;b=b+1)begin: banks
  DPX9B #(.BIT_WIDTH_0(18),.BIT_WIDTH_1(18),.READ_MODE0(0),.READ_MODE1(0),
   .WRITE_MODE0(0),.WRITE_MODE1(0)) ram(
   .CLKA(clk),.CLKB(clk),.CEA(ea && aa[AW-1:10]==b),.CEB(eb && ab[AW-1:10]==b),
   .WREA(wea),.WREB(web),.ADA({aa[9:0],4'b0011}),.ADB({ab[9:0],4'b0011}),
   .DIA(da),.DIB(db),.DOA(bank_a[b]),.DOB(bank_b[b]),.BLKSELA(3'd0),.BLKSELB(3'd0),
   .OCEA(1'b1),.OCEB(1'b1),.RESETA(1'b0),.RESETB(1'b0));
 end
endmodule
