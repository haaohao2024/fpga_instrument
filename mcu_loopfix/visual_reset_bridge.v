// All DISPLAY domains share asynchronous assertion, independent synchronous release.
// None of these resets may feed the audio reset or audio ready signals.
module visual_reset_bridge(input wire audio_clk,pixel_clk,reset_request,pll_locked,
 output wire process_rst,pixel_rst,serializer_rst,serial_clock_disable);
 wire ar=reset_request||!pll_locked;
 (* ASYNC_REG="TRUE" *) reg [2:0] a,p;
 reg [1:0] gate_release;
 always @(posedge audio_clk or posedge ar)if(ar)a<=3'b111;else a<={a[1:0],1'b0};
 always @(posedge pixel_clk or posedge ar)if(ar)p<=3'b111;else p<={p[1:0],1'b0};
 assign process_rst=a[2];assign pixel_rst=p[2];
 // Keep the original pixel-domain reset edge. The dedicated HCLK gate
 // remains disabled for two additional pixel periods after reset releases.
 // During assertion the reset is held for at least two full pixel periods,
 // allowing the gate's internal synchronizer to stop FCLK before release.
 always @(posedge pixel_clk or posedge ar)
  if(ar)gate_release<=2'b11;else gate_release<={gate_release[0],p[2]};
 assign serializer_rst=p[2];
 assign serial_clock_disable=gate_release[1];
endmodule
