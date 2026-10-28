module visual_spectrum_bars #(parameter BOUNDS_FILE="src/visual_band_bounds.mem")(
 input wire clk,rst,start,
 input wire spectrum_valid,output wire spectrum_ready,input wire [11:0] bin,
 input wire [36:0] left_power,right_power,
 output wire write_enable,output wire [7:0] write_column,output wire [15:0] write_data,
 output wire done,output wire [7:0] dc_left,dc_right
);
 // One owned bin. The producer may advance only after capture; the core
 // can reuse this bin across adjacent columns before acknowledging it.
 reg [1:0] token_stage;
 reg [11:0] held_bin;
 wire [10:0] code_l,code_r;
 reg [10:0] held_l,held_r;
 wire [7:0] decoded_l,decoded_r;
 reg [7:0] height_l,height_r;
 wire core_ready;
 margin_spectrum_code nl(.power(left_power),.endpoint(bin==0||bin==2048),.code(code_l));
 margin_spectrum_code nr(.power(right_power),.endpoint(bin==0||bin==2048),.code(code_r));
 margin_spectrum_decode dl(.code(held_l),.value(decoded_l));
 margin_spectrum_decode dr(.code(held_r),.value(decoded_r));
 assign spectrum_ready=!rst&&!start&&token_stage==0;
 always @(posedge clk)begin
  if(rst||start)begin token_stage<=0;held_bin<=0;held_l<=0;held_r<=0;height_l<=0;height_r<=0;end
  else case(token_stage)
   0:if(spectrum_valid)begin held_bin<=bin;held_l<=code_l;held_r<=code_r;token_stage<=1;end
   1:begin height_l<=decoded_l;height_r<=decoded_r;token_stage<=2;end
   2:if(core_ready)token_stage<=0;
   default:token_stage<=0;
  endcase
 end
 margin_spectrum_bars_core #(.BOUNDS_FILE(BOUNDS_FILE)) bars(
  .clk(clk),.rst(rst),.start(start),.spectrum_valid(token_stage==2),.spectrum_ready(core_ready),
  .bin(held_bin),.hl(height_l),.hr(height_r),.write_enable(write_enable),.write_column(write_column),
  .write_data(write_data),.done(done),.dc_left(dc_left),.dc_right(dc_right));
endmodule
module margin_spectrum_code(input wire [36:0] power,input wire endpoint,output wire [10:0] code);
 wire [63:0] s0={power,27'd0};
 wire z32=!(|s0[63:32]);wire [63:0] s1=z32?s0<<32:s0;
 wire z16=!(|s1[63:48]);wire [63:0] s2=z16?s1<<16:s1;
 wire z8=!(|s2[63:56]);wire [63:0] s3=z8?s2<<8:s2;
 wire z4=!(|s3[63:60]);wire [63:0] s4=z4?s3<<4:s3;
 wire z2=!(|s4[63:62]);wire [63:0] s5=z2?s4<<2:s4;
 wire z1=!s5[63];wire [63:0] normalized=z1?s5<<1:s5;
 wire [3:0] fraction=normalized[62:59];
 wire [5:0] corrected_exponent=(endpoint?6'd38:6'd40)-{z32,z16,z8,z4,z2,z1};
 assign code={|power,corrected_exponent,fraction};
endmodule
module margin_spectrum_decode(input wire [10:0] code,output wire [7:0] value);
 wire nonzero=code[10];wire [5:0] corrected_exponent=code[9:4];wire [3:0] fraction=code[3:0];
 reg [7:0] base;reg [63:0] increments;
 always @*begin
 case(corrected_exponent)
 6'd0:begin base=8'd0;increments=64'h0000000000000000;end
 6'd1:begin base=8'd0;increments=64'h0000000000000000;end
 6'd2:begin base=8'd0;increments=64'h0000000000000000;end
 6'd3:begin base=8'd0;increments=64'h0000000000000000;end
 6'd4:begin base=8'd0;increments=64'h0000000000000000;end
 6'd5:begin base=8'd0;increments=64'h0000000000000000;end
 6'd6:begin base=8'd0;increments=64'h8776655443221000;end
 6'd7:begin base=8'd8;increments=64'h9888776554432210;end
 6'd8:begin base=8'd17;increments=64'h9988776655433210;end
 6'd9:begin base=8'd27;increments=64'h9887766554332110;end
 6'd10:begin base=8'd36;increments=64'h9988776654432210;end
 6'd11:begin base=8'd45;increments=64'h9998877655433210;end
 6'd12:begin base=8'd55;increments=64'h9887766554432110;end
 6'd13:begin base=8'd64;increments=64'h9988776655433210;end
 6'd14:begin base=8'd74;increments=64'h9887766544332100;end
 6'd15:begin base=8'd83;increments=64'h9888776554432210;end
 6'd16:begin base=8'd92;increments=64'h9988776655433210;end
 6'd17:begin base=8'd102;increments=64'h9887766554332100;end
 6'd18:begin base=8'd111;increments=64'h9988776654432210;end
 6'd19:begin base=8'd120;increments=64'h9988776655433210;end
 6'd20:begin base=8'd130;increments=64'h9887766554332110;end
 6'd21:begin base=8'd139;increments=64'h9988776654432210;end
 6'd22:begin base=8'd149;increments=64'h8887766544332100;end
 6'd23:begin base=8'd158;increments=64'h9887766554432210;end
 6'd24:begin base=8'd167;increments=64'h9988776655433210;end
 6'd25:begin base=8'd177;increments=64'h9887766554332100;end
 6'd26:begin base=8'd186;increments=64'h9988776654432210;end
 6'd27:begin base=8'd195;increments=64'h9988776655433210;end
 6'd28:begin base=8'd205;increments=64'h9887766554332110;end
 6'd29:begin base=8'd214;increments=64'h9988776654432210;end
 default:begin base=224;increments=0;end
 endcase
 end
 assign value=nonzero?base+{4'd0,increments[fraction*4+:4]}:8'd0;
endmodule
module margin_spectrum_bars_core #(parameter BOUNDS_FILE="src/visual_band_bounds.mem")(
 input wire clk,rst,start,
 input wire spectrum_valid,output wire spectrum_ready,input wire [11:0] bin,
 input wire [7:0] hl,hr,
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

module r22_exact_spectrum_height(input wire [36:0] power,input wire endpoint,output wire [7:0] value);
 wire [63:0] s0={power,27'd0};
 wire z32=!(|s0[63:32]);wire [63:0] s1=z32?s0<<32:s0;
 wire z16=!(|s1[63:48]);wire [63:0] s2=z16?s1<<16:s1;
 wire z8=!(|s2[63:56]);wire [63:0] s3=z8?s2<<8:s2;
 wire z4=!(|s3[63:60]);wire [63:0] s4=z4?s3<<4:s3;
 wire z2=!(|s4[63:62]);wire [63:0] s5=z2?s4<<2:s4;
 wire z1=!s5[63];wire [63:0] normalized=z1?s5<<1:s5;
 wire [3:0] fraction=normalized[62:59];
 wire [5:0] corrected_exponent=(endpoint?6'd38:6'd40)-{z32,z16,z8,z4,z2,z1};
 reg [7:0] base;reg [63:0] increments;
 always @*begin
 case(corrected_exponent)
 6'd0:begin base=8'd0;increments=64'h0000000000000000;end
 6'd1:begin base=8'd0;increments=64'h0000000000000000;end
 6'd2:begin base=8'd0;increments=64'h0000000000000000;end
 6'd3:begin base=8'd0;increments=64'h0000000000000000;end
 6'd4:begin base=8'd0;increments=64'h0000000000000000;end
 6'd5:begin base=8'd0;increments=64'h0000000000000000;end
 6'd6:begin base=8'd0;increments=64'h8776655443221000;end
 6'd7:begin base=8'd8;increments=64'h9888776554432210;end
 6'd8:begin base=8'd17;increments=64'h9988776655433210;end
 6'd9:begin base=8'd27;increments=64'h9887766554332110;end
 6'd10:begin base=8'd36;increments=64'h9988776654432210;end
 6'd11:begin base=8'd45;increments=64'h9998877655433210;end
 6'd12:begin base=8'd55;increments=64'h9887766554432110;end
 6'd13:begin base=8'd64;increments=64'h9988776655433210;end
 6'd14:begin base=8'd74;increments=64'h9887766544332100;end
 6'd15:begin base=8'd83;increments=64'h9888776554432210;end
 6'd16:begin base=8'd92;increments=64'h9988776655433210;end
 6'd17:begin base=8'd102;increments=64'h9887766554332100;end
 6'd18:begin base=8'd111;increments=64'h9988776654432210;end
 6'd19:begin base=8'd120;increments=64'h9988776655433210;end
 6'd20:begin base=8'd130;increments=64'h9887766554332110;end
 6'd21:begin base=8'd139;increments=64'h9988776654432210;end
 6'd22:begin base=8'd149;increments=64'h8887766544332100;end
 6'd23:begin base=8'd158;increments=64'h9887766554432210;end
 6'd24:begin base=8'd167;increments=64'h9988776655433210;end
 6'd25:begin base=8'd177;increments=64'h9887766554332100;end
 6'd26:begin base=8'd186;increments=64'h9988776654432210;end
 6'd27:begin base=8'd195;increments=64'h9988776655433210;end
 6'd28:begin base=8'd205;increments=64'h9887766554332110;end
 6'd29:begin base=8'd214;increments=64'h9988776654432210;end
 default:begin base=224;increments=0;end
 endcase
 end
 assign value=(|power)?base+{4'd0,increments[fraction*4+:4]}:8'd0;
endmodule
