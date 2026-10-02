module video_timing_800x600(
 input wire pixel_clk,rst,
 output reg [10:0] x,output reg [9:0] y,
 output wire de,hs,vs,vblank,frame_start
);
 assign de=x<800&&y<600;
 assign hs=x>=840&&x<968;
 assign vs=y>=601&&y<605;
 assign vblank=y>=600;
 assign frame_start=x==0&&y==0;
 always @(posedge pixel_clk)begin
  if(rst)begin x<=0;y<=0;end
  else if(x==1055)begin x<=0;if(y==627)y<=0;else y<=y+1'b1;end
  else x<=x+1'b1;
 end
endmodule
