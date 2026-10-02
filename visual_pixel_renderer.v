// Four pixel clocks of matched RGB/DE/HS/VS latency. No full-frame RAM.
module visual_pixel_renderer #(parameter FONT_FILE="src/visual_font.mem")(
 input wire pixel_clk,rst,input wire [10:0] x,input wire [9:0] y,input wire de,hs,vs,
 input wire test_pattern,front_valid,input wire [1023:0] metadata,input wire [15:0] age_frames,
 output wire wave_re,xy_re,spectrum_re,
 output wire [9:0] wave_addr,xy_addr,output wire [7:0] spectrum_addr,
 input wire [15:0] wave_data,xy_data,spectrum_data,
 output reg [23:0] rgb,output reg out_de,out_hs,out_vs
);
 wire wave_region=x>=32&&x<544&&((y>=64&&y<144)||(y>=176&&y<256));
 wire xy_region=x>=624&&x<752&&y>=80&&y<208;
 wire spectrum_region=x>=32&&x<544&&y>=320&&y<544;
 assign wave_re=front_valid&&wave_region;
 assign xy_re=front_valid&&xy_region;
 assign spectrum_re=front_valid&&spectrum_region;
 wire [10:0] wave_x=x-11'd32,xy_x=x-11'd624;
 wire [9:0] xy_y=y-10'd80;
 assign wave_addr={wave_x[8:1],(y>=10'd176),wave_x[0]};
 assign xy_addr={xy_y[6:0],xy_x[6:4]};
 assign spectrum_addr=(x-32)>>1;
 reg [10:0] x0,x1,x2,x3;reg [9:0] y0,y1,y2,y3;
 reg [3:0] de_pipe,hs_pipe,vs_pipe,valid_pipe,test_pipe;
 reg signed [15:0] minimum,held_minimum,held_maximum;
 reg [15:0] spec2,spec3;reg xy2,xy3;
 reg [7:0] font[0:1023];reg [7:0] font0,font1;
 reg [2:0] fontbit0,fontbit1;reg text0,text1,text2,text3;
 reg [6:0] character;reg [2:0] glyph_x,glyph_y;reg text_enable;
 integer col,row,local_x,local_y,voices,held,i,hist_count;
 reg [191:0] text_line;
 reg [7:0] dynamic_char;
 initial $readmemh(FONT_FILE,font);
 function [7:0] digit(input integer v);begin digit="0"+(v%10);end endfunction
 function [7:0] hex_digit(input [3:0] v);begin hex_digit=v<10?"0"+v:"A"+v-10;end endfunction
 always @* begin
  voices=0;held=0;hist_count=0;for(i=0;i<32;i=i+1)begin voices=voices+metadata[256+i];held=held+(metadata[256+i]&&metadata[288+i]);end
  local_x=x-32;local_y=y-16;col=0;row=0;text_line=0;dynamic_char=0;
  text_enable=0;glyph_x=0;glyph_y=0;character=32;
  if(x>=32&&x<736&&y>=16&&y<32)begin
   col=(x-32)>>4;glyph_x=((x-32)>>1)&7;glyph_y=(y-16)>>1;text_enable=1;
   case(col)
    0:character="F";1:character="P";2:character="G";3:character="A";
    5:character="S";6:character="T";7:character="E";8:character="R";9:character="E";10:character="O";
    13:character="W";14:character="A";15:character="V";16:character="E";
    19:character="F";20:character="F";21:character="T";
    24:character="X";25:character="Y";
    default:character=32;
   endcase
  end else begin
   if(x>=32&&x<224&&y>=48&&y<56)begin local_x=x-32;local_y=y-48;text_line="LEFT WAVE - 512 SAMPLES ";text_enable=1;end
   if(x>=32&&x<224&&y>=160&&y<168)begin local_x=x-32;local_y=y-160;text_line="RIGHT WAVE              ";text_enable=1;end
   if(x>=624&&x<752&&y>=56&&y<64)begin local_x=x-624;local_y=y-56;text_line="L / R XY                ";text_enable=1;end
   if(x>=32&&x<224&&y>=296&&y<304)begin local_x=x-32;local_y=y-296;text_line="SPECTRUM -72 TO 0 DBFS  ";text_enable=1;end
   if(x>=32&&x<96&&y>=264&&y<272)begin local_x=x-32;local_y=y-264;text_line="DC L                    ";text_enable=1;end
   if(x>=32&&x<96&&y>=280&&y<288)begin local_x=x-32;local_y=y-280;text_line="DC R                    ";text_enable=1;end
   if(x>=344&&x<536&&y>=272&&y<280)begin local_x=x-344;local_y=y-272;text_line="DC -72 TO 0 DBFS        ";text_enable=1;end
   if(x>=32&&x<544&&y>=552&&y<560)begin
    local_x=x-32;local_y=y-552;text_enable=1;
    if(x<64)text_line="12HZ                    ";
    else if(x>=176&&x<224)begin local_x=x-176;text_line="100HZ                   ";end
    else if(x>=328&&x<368)begin local_x=x-328;text_line="1KHZ                    ";end
    else if(x>=480&&x<528)begin local_x=x-480;text_line="10KHZ                   ";end
    else text_enable=0;
   end
   if(x>=592&&x<784&&y>=216&&y<288&&((y-216)%12)<8)begin
    local_x=x-592;local_y=(y-216)%12;row=(y-216)/12;text_enable=1;col=local_x/8;
    case(row)
     0:text_line="FX VERSION HEX:         ";
     1:text_line="TIME HI HEX:            ";
     2:text_line="TIME LO HEX:            ";
     3:text_line="EXT UNDER HEX:          ";
     4:text_line="EXT ERROR:              ";
     5:text_line="DEADLINE HEX:           ";
    endcase
    if(col>=16&&col<24)begin
     case(row)
      0:dynamic_char=hex_digit(metadata[540+(23-col)*4+:4]);
      1:dynamic_char=hex_digit(metadata[473+(23-col)*4+:4]);
      2:dynamic_char=hex_digit(metadata[441+(23-col)*4+:4]);
      3:dynamic_char=hex_digit(metadata[508+(23-col)*4+:4]);
      4:if(col==16)dynamic_char=digit(metadata[604]);
      5:dynamic_char=hex_digit(metadata[572+(23-col)*4+:4]);
     endcase
    end
   end
   if(x>=592&&x<784&&y>=304&&y<592&&((y-304)%12)<8)begin
    local_x=x-592;local_y=(y-304)%12;row=(y-304)/12;text_enable=1;
    case(row)
     0:text_line="SNAPSHOT STATUS         ";
     1:text_line="VOICES:                 ";
     2:text_line="HELD:                   ";
     3:text_line="RELEASE:                ";
     4:text_line="NEW TIMBRE:             ";
     5:text_line="FX D C R:               ";
     6:text_line="BYPASS:                 ";
     7:text_line="TEACH / LOOP:           ";
     8:text_line="SCORE STATE:            ";
     9:text_line="SCORE ERROR:            ";
     10:text_line="EXT STATE:              ";
     11:text_line="WINDOW ID:              ";
     12:text_line="SKIP32 HEX:             ";
     13:text_line="CANCEL32 HEX:           ";
     14:text_line="FX OFF MAY RETAIN TAILS ";
     15:text_line="4096 POINT HANN FFT     ";
     16:text_line="11.71875 HZ / BIN       ";
     17:text_line="TIMBRE 0:               ";
     18:text_line="TIMBRE 1:               ";
     19:text_line="TIMBRE 2:               ";
     20:text_line="TIMBRE 3:               ";
     21:text_line="TIMBRE 4:               ";
     22:text_line="AGE FRAMES HEX:         ";
     23:text_line="DAC FRAME32 HEX:        ";
     default:text_line=0;
    endcase
    col=local_x/8;
    if(row>=17&&row<=21)for(i=0;i<32;i=i+1)if(metadata[256+i]&&metadata[320+i*3+:3]==row-17)hist_count=hist_count+1;
    if(col==16||col==17)begin
     case(row)
      1:dynamic_char=col==16?digit(voices/10):digit(voices);
      2:dynamic_char=col==16?digit(held/10):digit(held);
      3:dynamic_char=col==16?digit((voices-held)/10):digit(voices-held);
      4:dynamic_char=col==16?"0":digit(metadata[418:416]);
      8:dynamic_char=col==16?hex_digit(metadata[432:429]):hex_digit(metadata[428:425]);
      9:dynamic_char=col==16?hex_digit(metadata[440:437]):hex_digit(metadata[436:433]);
      10:dynamic_char=col==16?"0":digit(metadata[507:505]);
      11:dynamic_char=col==16?hex_digit(metadata[135:132]):hex_digit(metadata[131:128]);
      17,18,19,20,21:dynamic_char=col==16?digit(hist_count/10):digit(hist_count);
     endcase
    end
    if(row==5&&col>=16&&col<=20&&!(col%2))dynamic_char=digit(metadata[419+(col-16)/2]);
    if(row==6&&col==16)dynamic_char=digit(metadata[422]);
    if(row==7&&col==16)dynamic_char=digit(metadata[423]);
    if(row==7&&col==18)dynamic_char=digit(metadata[424]);
    if(row==12&&col>=16&&col<24)dynamic_char=hex_digit(metadata[192+(23-col)*4+:4]);
    if(row==13&&col>=16&&col<24)dynamic_char=hex_digit(metadata[768+(23-col)*4+:4]);
    if(row==22&&col>=16&&col<20)dynamic_char=hex_digit(age_frames[(19-col)*4+:4]);
    if(row==23&&col>=16&&col<24)dynamic_char=hex_digit(metadata[64+(23-col)*4+:4]);
   end
   if(text_enable)begin
    col=local_x/8;glyph_x=local_x%8;glyph_y=local_y%8;
    if(col<24)character=text_line[(23-col)*8+:8];
    if(dynamic_char!=0)character=dynamic_char;
   end
  end
 end
 integer y_min,y_max,center,offset,scale,amplitude;
 reg [23:0] color;
 always @* begin
  color=24'h101823;center=0;offset=0;scale=1<<metadata[177:176];y_min=0;y_max=0;amplitude=0;
  if(test_pipe[3])begin
   case(x3/100)
    0:color=24'hffffff;1:color=24'hffff00;2:color=24'h00ffff;3:color=24'h00ff00;
    4:color=24'hff00ff;5:color=24'hff0000;6:color=24'h0000ff;default:color=24'h000000;
   endcase
  end else begin
   if(x3>=32&&x3<544&&((y3>=64&&y3<144)||(y3>=176&&y3<256)))begin
    center=y3>=176?216:104;offset=y3>=176?176:64;
    color=(y3==center||((x3-32)%64)==0)?24'h34404f:24'h08111b;
    y_min=40-(($signed(held_maximum)*scale*40)>>>15);
    y_max=40-(($signed(held_minimum)*scale*40)>>>15);
    if(y_min<0)y_min=0;if(y_min>79)y_min=79;if(y_max<0)y_max=0;if(y_max>79)y_max=79;
    if(valid_pipe[3]&&y3-offset>=y_min&&y3-offset<=y_max)color=y3>=176?24'hffaf40:24'h40dcff;
   end
   if(x3>=624&&x3<752&&y3>=80&&y3<208)begin
    color=(x3==688||y3==144)?24'h34404f:24'h08111b;
    if(valid_pipe[3]&&xy3)color=24'hb0ef60;
   end
   // DC is a separate pair of meters, not an extra logarithmic-frequency bin.
   // Snapshot values already use the same 0..224 / -72..0 dBFS scale.
   if(x3>=96&&x3<320&&((y3>=264&&y3<272)||(y3>=280&&y3<288)))begin
    color=24'h08111b;
    if(valid_pipe[3]&&x3-96<(y3>=280?metadata[167:160]:metadata[175:168]))
     color=y3>=280?24'hffaf40:24'h40dcff;
   end
   if(x3>=32&&x3<544&&y3>=320&&y3<544)begin
    color=((543-y3)%56==0||((x3-32)%64)==0)?24'h34404f:24'h08111b;
    if(valid_pipe[3])begin
     if(543-y3<spec3[15:8])color=24'h40dcff;
     if(543-y3<spec3[7:0])color=color==24'h40dcff ? 24'hfff0be : 24'hffaf40;
    end
   end
   if(text3)color=24'hdce8f2;
  end
 end
 always @(posedge pixel_clk)begin
  // 1024-byte synchronous font ROM; no display-sized pixel buffer.
  font0<=font[{character,glyph_y}];font1<=font0;
  if(rst)begin
   x0<=0;x1<=0;x2<=0;x3<=0;y0<=0;y1<=0;y2<=0;y3<=0;
   de_pipe<=0;hs_pipe<=0;vs_pipe<=0;valid_pipe<=0;test_pipe<=0;
   minimum<=0;held_minimum<=0;held_maximum<=0;spec2<=0;spec3<=0;xy2<=0;xy3<=0;
   text0<=0;text1<=0;text2<=0;text3<=0;fontbit0<=0;fontbit1<=0;
   rgb<=0;out_de<=0;out_hs<=0;out_vs<=0;
  end else begin
   x0<=x;x1<=x0;x2<=x1;x3<=x2;y0<=y;y1<=y0;y2<=y1;y3<=y2;
   de_pipe<={de_pipe[2:0],de};hs_pipe<={hs_pipe[2:0],hs};vs_pipe<={vs_pipe[2:0],vs};
   valid_pipe<={valid_pipe[2:0],front_valid};test_pipe<={test_pipe[2:0],test_pattern};
   if(x1>=32&&x1<544&&((y1>=64&&y1<144)||(y1>=176&&y1<256)))begin
    if(!x1[0])minimum<=wave_data;else begin held_minimum<=minimum;held_maximum<=wave_data;end
   end
   spec2<=spectrum_data;spec3<=spec2;
   xy2<=xy_data[(x1-624)&15];xy3<=xy2;
   text0<=text_enable;text1<=text0;fontbit0<=glyph_x;fontbit1<=fontbit0;
   text2<=text1&&font1[7-fontbit1];text3<=text2;
   rgb<=de_pipe[3]?color:24'd0;out_de<=de_pipe[3];out_hs<=hs_pipe[3];out_vs<=vs_pipe[3];
  end
 end
endmodule
