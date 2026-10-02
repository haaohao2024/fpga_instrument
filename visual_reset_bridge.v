// All DISPLAY domains share asynchronous assertion, independent synchronous release.
// None of these resets may feed the audio reset or audio ready signals.
module visual_reset_bridge(input wire audio_clk,pixel_clk,reset_request,pll_locked,
 output wire process_rst,pixel_rst);
 wire ar=reset_request||!pll_locked;
 (* ASYNC_REG="TRUE" *) reg [2:0] a,p;
 always @(posedge audio_clk or posedge ar)if(ar)a<=3'b111;else a<={a[1:0],1'b0};
 always @(posedge pixel_clk or posedge ar)if(ar)p<=3'b111;else p<={p[1:0],1'b0};
 assign process_rst=a[2];assign pixel_rst=p[2];
endmodule
