// Four pixel clocks of matched RGB/DE/HS/VS latency. No full-frame RAM.
module visual_pixel_renderer #(parameter FONT_FILE="src/visual_font.mem", LABEL_FILE="src/visual_labels.mem")(
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
 wire [7:0] font0;
 reg [2:0] fontbit0,fontbit1;reg text0,text1,text2,text3;
 reg [6:0] character;reg [2:0] glyph_x,glyph_y;reg text_enable;
 reg [6:0] col;reg [4:0] row;reg [10:0] local_x;reg [9:0] local_y;integer i;
 reg [5:0] text_line_id;
 // Text ROM uses the original font0 stage; the glyph ROM uses the former
 // font1 stage. RGB and DE/HS/VS keep exactly their original four-clock path.

 wire [6:0] label_q;reg [6:0] character_q;reg [2:0] glyph_y_q;
 reg use_label,use_label_q;

 reg [7:0] dynamic_char;
 generate if(FONT_FILE=="src/visual_font.mem" && LABEL_FILE=="src/visual_labels.mem")begin: packed_text
  // 42 rows x 24 bytes fit below 1024; all 128 glyphs occupy the upper half.
  wire [9:0] label_address=({4'd0,text_line_id}<<4)+({4'd0,text_line_id}<<3)+{5'd0,col[4:0]};
  wire [15:0] label_word,glyph_word;
  DPB #(.READ_MODE0(1'b0),.READ_MODE1(1'b0),
   .WRITE_MODE0(2'b00),.WRITE_MODE1(2'b00),.BIT_WIDTH_0(8),.BIT_WIDTH_1(8),
   .BLK_SEL_0(3'b000),.BLK_SEL_1(3'b000),.RESET_MODE("SYNC"),
`include "r30_text_init.vh"
  ) rom(.CLKA(pixel_clk),.CLKB(pixel_clk),.CEA(1'b1),.CEB(1'b1),.OCEA(1'b1),.OCEB(1'b1),
   .RESETA(1'b0),.RESETB(1'b0),.WREA(1'b0),.WREB(1'b0),
   .BLKSELA(3'b000),.BLKSELB(3'b000),.ADA({1'b0,label_address,3'b000}),
   .ADB({1'b1,(use_label_q?label_q:character_q),glyph_y_q,3'b000}),
   .DIA(16'd0),.DIB(16'd0),.DOA(label_word),.DOB(glyph_word));
  assign label_q=label_word[6:0];assign font0=glyph_word[7:0];
 end else begin: custom_text
  reg [7:0] font[0:1023];reg [6:0] labels[0:2047];
  reg [7:0] f;reg [6:0] l;
  initial begin $readmemh(FONT_FILE,font);$readmemh(LABEL_FILE,labels);end
  always @(posedge pixel_clk)begin
   l<=labels[{text_line_id,col[4:0]}];f<=font[{(use_label_q?label_q:character_q),glyph_y_q}];
  end
  assign label_q=l;assign font0=f;
 end endgenerate
 function [7:0] digit(input [5:0] v);begin digit="0"+(v%6'd10);end endfunction
 function [7:0] hex_digit(input [3:0] v);begin hex_digit=v<10?"0"+v:"A"+v-10;end endfunction
 // Prepare decimal statistics once per immutable front snapshot. The
 // bank exchange switches only in vertical blank. Eight preparation clocks
 // finish before any statistic text pixel (first one is x=720,y=316).
 reg [31:0] statistics_sequence;reg statistics_valid;reg [3:0] statistics_phase;
 reg [5:0] statistics_counts[0:7];reg [15:0] statistics_digits[0:7];
 reg [5:0] current_counts[0:7];integer count_slot,count_timbre;
 function [15:0] decimal_pair(input [5:0] count);
  begin case(count)
   6'd0:decimal_pair=16'h3030;
   6'd1:decimal_pair=16'h3031;
   6'd2:decimal_pair=16'h3032;
   6'd3:decimal_pair=16'h3033;
   6'd4:decimal_pair=16'h3034;
   6'd5:decimal_pair=16'h3035;
   6'd6:decimal_pair=16'h3036;
   6'd7:decimal_pair=16'h3037;
   6'd8:decimal_pair=16'h3038;
   6'd9:decimal_pair=16'h3039;
   6'd10:decimal_pair=16'h3130;
   6'd11:decimal_pair=16'h3131;
   6'd12:decimal_pair=16'h3132;
   6'd13:decimal_pair=16'h3133;
   6'd14:decimal_pair=16'h3134;
   6'd15:decimal_pair=16'h3135;
   6'd16:decimal_pair=16'h3136;
   6'd17:decimal_pair=16'h3137;
   6'd18:decimal_pair=16'h3138;
   6'd19:decimal_pair=16'h3139;
   6'd20:decimal_pair=16'h3230;
   6'd21:decimal_pair=16'h3231;
   6'd22:decimal_pair=16'h3232;
   6'd23:decimal_pair=16'h3233;
   6'd24:decimal_pair=16'h3234;
   6'd25:decimal_pair=16'h3235;
   6'd26:decimal_pair=16'h3236;
   6'd27:decimal_pair=16'h3237;
   6'd28:decimal_pair=16'h3238;
   6'd29:decimal_pair=16'h3239;
   6'd30:decimal_pair=16'h3330;
   6'd31:decimal_pair=16'h3331;
   6'd32:decimal_pair=16'h3332;
   default:decimal_pair=16'h3030;
  endcase end
 endfunction
 always @*begin
  for(integer c=0;c<8;c=c+1)current_counts[c]=0;
  for(count_slot=0;count_slot<32;count_slot=count_slot+1)begin
   current_counts[0]=current_counts[0]+metadata[256+count_slot];
   current_counts[1]=current_counts[1]+(metadata[256+count_slot]&&metadata[288+count_slot]);
   for(count_timbre=0;count_timbre<5;count_timbre=count_timbre+1)
    if(metadata[256+count_slot] && metadata[320+count_slot*3+:3]==count_timbre)
     current_counts[3+count_timbre]=current_counts[3+count_timbre]+1'b1;
  end
  current_counts[2]=current_counts[0]-current_counts[1];
 end
 wire statistics_changed=front_valid&&(!statistics_valid||metadata[159:128]!=statistics_sequence);
 always @(posedge pixel_clk)begin
  if(rst)begin
   statistics_valid<=0;statistics_sequence<=0;statistics_phase<=0;
   for(integer c=0;c<8;c=c+1)begin statistics_counts[c]<=0;statistics_digits[c]<=16'h3030;end
  end else if(statistics_changed)begin
   statistics_valid<=1;statistics_sequence<=metadata[159:128];statistics_phase<=1;
   for(integer c=0;c<8;c=c+1)statistics_counts[c]<=current_counts[c];
  end else if(statistics_phase!=0)begin
   for(integer c=0;c<8;c=c+1)if(statistics_phase==c+1)statistics_digits[c]<=decimal_pair(statistics_counts[c]);
   statistics_phase<=statistics_phase==8?0:statistics_phase+1'b1;
  end
 end
 reg [4:0] panel_row;reg [3:0] panel_y;reg fx_text_rows,statistics_text_rows;
 always @*begin
  panel_row=0;panel_y=0;fx_text_rows=0;statistics_text_rows=0;
  for(integer r=0;r<6;r=r+1)if(y>=216+r*12 && y<224+r*12)begin
   panel_row=r;panel_y=y-(216+r*12);fx_text_rows=1;
  end
  for(integer r=0;r<24;r=r+1)if(y>=304+r*12 && y<312+r*12)begin
   panel_row=r;panel_y=y-(304+r*12);statistics_text_rows=1;
  end
 end
 wire [2:0] hex_index=3'd7-col[2:0];wire [1:0] age_index=2'd3-col[1:0];
 wire [3:0] hex_fx[0:7],hex_hi[0:7],hex_lo[0:7],hex_under[0:7],hex_deadline[0:7],hex_skip[0:7],hex_cancel[0:7],hex_dac[0:7],hex_age[0:3];
 generate for(genvar c=0;c<8;c=c+1)begin: metadata_hex_word
  assign hex_fx[c]=metadata[540+c*4+:4];assign hex_hi[c]=metadata[473+c*4+:4];
  assign hex_lo[c]=metadata[441+c*4+:4];assign hex_under[c]=metadata[508+c*4+:4];
  assign hex_deadline[c]=metadata[572+c*4+:4];assign hex_skip[c]=metadata[192+c*4+:4];
  assign hex_cancel[c]=metadata[768+c*4+:4];assign hex_dac[c]=metadata[64+c*4+:4];
 end
 for(genvar c=0;c<4;c=c+1)begin: age_hex_word
  assign hex_age[c]=age_frames[c*4+:4];
 end endgenerate
 // synthesis translate_off
 always @(posedge pixel_clk)if(!rst && front_valid && statistics_phase!=0 &&
  x>=720 && x<736 && statistics_text_rows &&
  (panel_row==1||panel_row==2||panel_row==3||(panel_row>=17&&panel_row<=21)))
  $fatal(1,"S8_STATISTICS_NOT_READY");
 // synthesis translate_on
 always @* begin
  local_x=x-32;local_y=y-16;col=0;row=0;text_line_id=0;dynamic_char=0;
  text_enable=0;glyph_x=0;glyph_y=0;character=32;use_label=0;
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
   if(x>=32&&x<224&&y>=48&&y<56)begin local_x=x-32;local_y=y-48;text_line_id=6'd1;text_enable=1;end
   if(x>=32&&x<224&&y>=160&&y<168)begin local_x=x-32;local_y=y-160;text_line_id=6'd2;text_enable=1;end
   if(x>=624&&x<752&&y>=56&&y<64)begin local_x=x-624;local_y=y-56;text_line_id=6'd3;text_enable=1;end
   if(x>=32&&x<224&&y>=296&&y<304)begin local_x=x-32;local_y=y-296;text_line_id=6'd4;text_enable=1;end
   if(x>=32&&x<96&&y>=264&&y<272)begin local_x=x-32;local_y=y-264;text_line_id=6'd5;text_enable=1;end
   if(x>=32&&x<96&&y>=280&&y<288)begin local_x=x-32;local_y=y-280;text_line_id=6'd6;text_enable=1;end
   if(x>=344&&x<536&&y>=272&&y<280)begin local_x=x-344;local_y=y-272;text_line_id=6'd7;text_enable=1;end
   if(x>=32&&x<544&&y>=552&&y<560)begin
    local_x=x-32;local_y=y-552;text_enable=1;
    if(x<64)text_line_id=6'd8;
    else if(x>=176&&x<224)begin local_x=x-176;text_line_id=6'd9;end
    else if(x>=328&&x<368)begin local_x=x-328;text_line_id=6'd10;end
    else if(x>=480&&x<528)begin local_x=x-480;text_line_id=6'd11;end
    else text_enable=0;
   end
   if(x>=592&&x<784&&fx_text_rows)begin
    local_x=x-592;local_y=panel_y;row=panel_row;text_enable=1;col=local_x/8;
    case(row)
     0:text_line_id=6'd12;
     1:text_line_id=6'd13;
     2:text_line_id=6'd14;
     3:text_line_id=6'd15;
     4:text_line_id=6'd16;
     5:text_line_id=6'd17;
    endcase
    if(col>=16&&col<24)begin
     case(row)
      0:dynamic_char=hex_digit(hex_fx[hex_index]);
      1:dynamic_char=hex_digit(hex_hi[hex_index]);
      2:dynamic_char=hex_digit(hex_lo[hex_index]);
      3:dynamic_char=hex_digit(hex_under[hex_index]);
      4:if(col==16)dynamic_char=digit(metadata[604]);
      5:dynamic_char=hex_digit(hex_deadline[hex_index]);
     endcase
    end
   end
   if(x>=592&&x<784&&statistics_text_rows)begin
    local_x=x-592;local_y=panel_y;row=panel_row;text_enable=1;
    case(row)
     0:text_line_id=6'd18;
     1:text_line_id=6'd19;
     2:text_line_id=6'd20;
     3:text_line_id=6'd21;
     4:text_line_id=6'd22;
     5:text_line_id=6'd23;
     6:text_line_id=6'd24;
     7:text_line_id=6'd25;
     8:text_line_id=6'd26;
     9:text_line_id=6'd27;
     10:text_line_id=6'd28;
     11:text_line_id=6'd29;
     12:text_line_id=6'd30;
     13:text_line_id=6'd31;
     14:text_line_id=6'd32;
     15:text_line_id=6'd33;
     16:text_line_id=6'd34;
     17:text_line_id=6'd35;
     18:text_line_id=6'd36;
     19:text_line_id=6'd37;
     20:text_line_id=6'd38;
     21:text_line_id=6'd39;
     22:text_line_id=6'd40;
     23:text_line_id=6'd41;
     default:text_line_id=0;
    endcase
    col=local_x/8;
    if(col==16||col==17)begin
     case(row)
      1:dynamic_char=col==16?statistics_digits[0][15:8]:statistics_digits[0][7:0];
      2:dynamic_char=col==16?statistics_digits[1][15:8]:statistics_digits[1][7:0];
      3:dynamic_char=col==16?statistics_digits[2][15:8]:statistics_digits[2][7:0];
      4:dynamic_char=col==16?"0":digit(metadata[418:416]);
      8:dynamic_char=col==16?hex_digit(metadata[432:429]):hex_digit(metadata[428:425]);
      9:dynamic_char=col==16?hex_digit(metadata[440:437]):hex_digit(metadata[436:433]);
      10:dynamic_char=col==16?"0":digit(metadata[507:505]);
      11:dynamic_char=col==16?hex_digit(metadata[135:132]):hex_digit(metadata[131:128]);
      17,18,19,20,21:dynamic_char=col==16?statistics_digits[row-14][15:8]:statistics_digits[row-14][7:0];
     endcase
    end
    if(row==5&&col>=16&&col<=20&&!(col%2))dynamic_char=digit(metadata[419+(col-16)/2]);
    if(row==6&&col==16)dynamic_char=digit(metadata[422]);
    if(row==7&&col==16)dynamic_char=digit(metadata[423]);
    if(row==7&&col==18)dynamic_char=digit(metadata[424]);
    if(row==12&&col>=16&&col<24)dynamic_char=hex_digit(hex_skip[hex_index]);
    if(row==13&&col>=16&&col<24)dynamic_char=hex_digit(hex_cancel[hex_index]);
    if(row==22&&col>=16&&col<20)dynamic_char=hex_digit(hex_age[age_index]);
    if(row==23&&col>=16&&col<24)dynamic_char=hex_digit(hex_dac[hex_index]);
   end
   if(text_enable)begin
    col=local_x/8;glyph_x=local_x%8;glyph_y=local_y%8;
    if(col<24)use_label=1;
    if(dynamic_char!=0)begin character=dynamic_char;use_label=0;end
   end
  end
 end
 integer y_min,y_max,center,offset,scale,amplitude;
 reg [23:0] color;
 always @* begin
  color=24'h101823;center=0;offset=0;scale=1<<metadata[177:176];y_min=0;y_max=0;amplitude=0;
  if(test_pipe[3])begin
   if(x3<11'd100)color=24'hffffff;
   else if(x3<11'd200)color=24'hffff00;
   else if(x3<11'd300)color=24'h00ffff;
   else if(x3<11'd400)color=24'h00ff00;
   else if(x3<11'd500)color=24'hff00ff;
   else if(x3<11'd600)color=24'hff0000;
   else if(x3<11'd700)color=24'h0000ff;
   else color=24'h000000;
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
    color=((y3==543||y3==487||y3==431||y3==375)||((x3-32)%64)==0)?24'h34404f:24'h08111b;
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

  character_q<=character;glyph_y_q<=glyph_y;use_label_q<=use_label;

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
   text2<=text1&&font0[7-fontbit1];text3<=text2;
   rgb<=de_pipe[3]?color:24'd0;out_de<=de_pipe[3];out_hs<=hs_pipe[3];out_vs<=vs_pipe[3];
  end
 end
endmodule
