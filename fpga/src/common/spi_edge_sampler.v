module spi_edge_sampler #(parameter integer COMM_SEPARATE=0)(
 input wire clk,comm_clk,rst,sck,cs_n,mosi,
 output wire rise,fall,start,finish,selected,bit_data,
 output wire fast_start,fast_fall,fast_selected);
 wire fclk=COMM_SEPARATE?comm_clk:clk;
 (* syn_preserve=1 *) reg [2:0] ss,cs; reg [1:0] ms;
 wire fr=ss[2:1]==2'b01, ff=ss[2:1]==2'b10;
 wire fs=cs[2:1]==2'b10, fe=cs[2:1]==2'b01;
 reg [3:0] toggles,seen; reg captured_bit;
 always @(posedge fclk)begin
  ss<={ss[1:0],sck};cs<={cs[1:0],cs_n};ms<={ms[0],mosi};
  if(rst)begin ss<=0;cs<=7;ms<=0;toggles<=0;captured_bit<=0;end
  else begin
   if(fr)begin toggles[0]<=~toggles[0];captured_bit<=ms[1];end
   if(ff)toggles[1]<=~toggles[1];
   if(fs)toggles[2]<=~toggles[2];
   if(fe)toggles[3]<=~toggles[3];
  end
 end
 wire [5:0] crossing;
 generate if(COMM_SEPARATE)begin: related_handoff
  // Opposite-edge capture provides a half-cycle on both sides of this
  // related-clock crossing. No new clock net or frequency is introduced.
  // This stage needs no reset: while rst is asserted, the source PHY is
  // cleared and the resettable system stage below suppresses all events.
  reg [5:0] half_cycle;
  reg [5:0] system_copy;
  always @(negedge comm_clk)half_cycle<={cs[2],captured_bit,toggles};
  always @(posedge clk)if(rst)system_copy<=6'b100000;else system_copy<=half_cycle;
  assign crossing=system_copy;
 end else begin: direct_crossing
  assign crossing={cs[2],captured_bit,toggles};
 end endgenerate
 always @(posedge clk)if(rst)seen<=0;else seen<=crossing[3:0];
 assign rise=COMM_SEPARATE?(crossing[0]^seen[0]):fr;
 assign fall=COMM_SEPARATE?(crossing[1]^seen[1]):ff;
 assign start=COMM_SEPARATE?(crossing[2]^seen[2]):fs;
 assign finish=COMM_SEPARATE?(crossing[3]^seen[3]):fe;
 assign selected=!crossing[5];assign bit_data=COMM_SEPARATE?crossing[4]:ms[1];
 assign fast_start=fs;assign fast_fall=ff;assign fast_selected=!cs[2];
endmodule
