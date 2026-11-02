// Native Gowin 10:1 DDR serializers. No ideal simulation replacement.
// pixel_clk and serial_clk MUST be synchronous, serial=5*pixel.
module video_tmds_phy #(parameter GATE_CLOCK=0)(
 input wire pixel_clk,serial_clk,rst,
 input wire clock_disable,
 input wire [9:0] blue,green,red,
 output wire [3:0] tmds_p,tmds_n
);
 wire phy_serial_clk;
 generate if(GATE_CLOCK)begin: clock_gate
  DHCE gate(.CLKIN(serial_clk),.CEN(clock_disable),.CLKOUT(phy_serial_clk));
 end else begin: clock_direct
  assign phy_serial_clk=serial_clk;
 end endgenerate
 wire [39:0] words={10'b0000011111,red,green,blue};
 wire [3:0] serial;
 genvar k;
 generate for(k=0;k<4;k=k+1)begin: lane
  OSER10 tx(.Q(serial[k]),.D0(words[k*10]),.D1(words[k*10+1]),.D2(words[k*10+2]),
   .D3(words[k*10+3]),.D4(words[k*10+4]),.D5(words[k*10+5]),.D6(words[k*10+6]),
   .D7(words[k*10+7]),.D8(words[k*10+8]),.D9(words[k*10+9]),
   .PCLK(pixel_clk),.FCLK(phy_serial_clk),.RESET(rst));
  TLVDS_OBUF outbuf(.O(tmds_p[k]),.OB(tmds_n[k]),.I(serial[k]));
 end endgenerate
endmodule
