module video_dvi_tx #(parameter SEPARATE_PHY_RESET=0, GATE_PHY_CLOCK=0)(
 input wire pixel_clk,serial_clk,rst,
 input wire phy_rst,phy_clock_disable,
 input wire [23:0] rgb,input wire de,hs,vs,
 output wire [3:0] tmds_p,tmds_n
);
 wire [9:0] blue,green,red;
 video_tmds_encoder b(.clk(pixel_clk),.rst(rst),.de(de),.data(rgb[7:0]),.c0(hs),.c1(vs),.symbol(blue));
 video_tmds_encoder g(.clk(pixel_clk),.rst(rst),.de(de),.data(rgb[15:8]),.c0(1'b0),.c1(1'b0),.symbol(green));
 video_tmds_encoder r(.clk(pixel_clk),.rst(rst),.de(de),.data(rgb[23:16]),.c0(1'b0),.c1(1'b0),.symbol(red));
 // Standalone users keep the common reset by default. The formal display
 // selects the independent synchronized release; this constant mux is erased.
 video_tmds_phy #(.GATE_CLOCK(GATE_PHY_CLOCK)) phy(.clock_disable(phy_clock_disable),.pixel_clk(pixel_clk),.serial_clk(serial_clk),.rst(SEPARATE_PHY_RESET?phy_rst:rst),
  .blue(blue),.green(green),.red(red),.tmds_p(tmds_p),.tmds_n(tmds_n));
endmodule
