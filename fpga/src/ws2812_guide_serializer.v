// Worldsemi WS2812B-2020 V1.3 candidate, 50MHz. No derived clock.
module ws2812_guide_serializer #(
 parameter integer T0H=16,T0L=48,T1H=34,T1L=30,RESET_CLOCKS=16000,REFRESH_CLOCKS=250000
)(input wire clk,rst,prefix,input wire [215:0] colors,
 output reg led_dout,output reg busy,output reg [31:0] completed_frames);
 reg [215:0] snapshot;reg [17:0] refresh_count;reg [15:0] count;
 reg [3:0] lamp;reg [4:0] bit_index;reg [1:0] state;reg first_blank;reg [3:0] lamps;
 wire value=snapshot[lamp*24+bit_index];
 wire [15:0] high_clocks=value?T1H:T0H;
 wire [15:0] total_clocks=value?T1H+T1L:T0H+T0L;
 always @(posedge clk)begin
  if(rst)begin state<=0;count<=0;led_dout<=0;busy<=1;first_blank<=1;
   refresh_count<=0;snapshot<=0;lamp<=0;bit_index<=23;lamps<=9;completed_frames<=0;
  end else begin
   if(refresh_count<REFRESH_CLOCKS)refresh_count<=refresh_count+1;
   case(state)
    0:begin // mandatory complete low reset, including after interrupted bits
     led_dout<=0;busy<=1;
     if(count+1>=RESET_CLOCKS)begin count<=0;
      if(first_blank)begin first_blank<=0;snapshot<=0;lamps<=prefix?9:8;lamp<=0;bit_index<=23;state<=2;end
      else begin state<=1;busy<=0;end
     end else count<=count+1;
    end
    1:if(refresh_count>=REFRESH_CLOCKS)begin
     snapshot<=colors;lamps<=prefix?9:8;lamp<=0;bit_index<=23;count<=0;state<=2;busy<=1;refresh_count<=0;
    end
    2:begin
     led_dout<=count<high_clocks;
     if(count+1>=total_clocks)begin count<=0;
      if(bit_index==0)begin bit_index<=23;
       if(lamp+1>=lamps)begin state<=0;lamp<=0;completed_frames<=completed_frames+1;end
       else lamp<=lamp+1;
      end else bit_index<=bit_index-1;
     end else count<=count+1;
    end
   endcase
  end
 end
endmodule
