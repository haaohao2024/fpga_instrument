module visual_spectrum_bars #(parameter BOUNDS_FILE="src/visual_band_bounds.mem")(
 input wire clk,rst,start,
 input wire spectrum_valid,output wire spectrum_ready,input wire [11:0] bin,
 input wire [36:0] left_power,right_power,
 output reg write_enable,output reg [7:0] write_column,output reg [15:0] write_data,
 output reg done,output reg [7:0] dc_left,dc_right
);
 reg [11:0] bounds[0:511];
 reg [8:0] address;
 reg [11:0] bound_data,low_bin,high_bin;
 reg [7:0] column,peak_l,peak_r;
 reg [3:0] state;
 initial $readmemh(BOUNDS_FILE,bounds);
 always @(posedge clk)bound_data<=bounds[address];
 function [7:0] height(input [36:0] p,input endpoint);
  reg [40:0] corrected;
  reg [3:0] fraction;
  integer exponent,log_fraction,log_q8,db_q8,h,i;
  begin
   corrected=endpoint ? ({4'd0,p}<<2) : ({4'd0,p}<<4);
   exponent=0;for(i=0;i<41;i=i+1)if(corrected[i])exponent=i;
   if(exponent>=4)fraction=(corrected>>(exponent-4));else fraction=(corrected<<(4-exponent));
   case(fraction)
    0:log_fraction=0;1:log_fraction=22;2:log_fraction=44;3:log_fraction=63;
    4:log_fraction=82;5:log_fraction=100;6:log_fraction=118;7:log_fraction=134;
    8:log_fraction=150;9:log_fraction=165;10:log_fraction=179;11:log_fraction=193;
    12:log_fraction=207;13:log_fraction=220;14:log_fraction=232;15:log_fraction=244;
   endcase
   log_q8=exponent*256+log_fraction;
   db_q8=((log_q8-30*256)*771)>>>8;
   h=((72*256+db_q8)*224)/(72*256);
   if(corrected==0||h<0)height=0;else if(h>224)height=224;else height=h;
  end
 endfunction
 wire [7:0] hl=height(left_power,bin==0||bin==2048);
 wire [7:0] hr=height(right_power,bin==0||bin==2048);
 assign spectrum_ready=state==6&&spectrum_valid&&bin<high_bin || state==9;
 always @(posedge clk)begin
  if(rst)begin state<=0;address<=0;low_bin<=1;high_bin<=1;column<=0;peak_l<=0;peak_r<=0;
   write_enable<=0;write_column<=0;write_data<=0;done<=0;dc_left<=0;dc_right<=0;
  end else begin
   write_enable<=0;done<=0;
   case(state)
    0:if(start)begin column<=0;peak_l<=0;peak_r<=0;address<=0;state<=1;end
    1:state<=2;
    2:begin low_bin<=bound_data;address<={column,1'b1};state<=3;end
    3:state<=4;
    4:begin high_bin<=bound_data;state<=6;end
    6:if(spectrum_valid)begin
     if(bin==0)begin dc_left<=hl;dc_right<=hr;end
     if(bin>=low_bin)begin
      if(hl>peak_l)peak_l<=hl;if(hr>peak_r)peak_r<=hr;
      if(bin==high_bin)begin
       write_enable<=1;write_column<=column;
       write_data<={(hl>peak_l?hl:peak_l),(hr>peak_r?hr:peak_r)};
       peak_l<=0;peak_r<=0;
       if(column==255)state<=9;
       else begin column<=column+1'b1;address<=({1'b0,column}+9'd1)<<1;state<=1;end
      end
     end
    end
    9:begin done<=1;state<=0;end
    default:state<=0;
   endcase
  end
 end
endmodule
