// Pure mapping. Multiple logical score keys at one pitch remain OR-combined.
module score_guide(
 input wire clk,rst,cfg_valid,cfg_prefix,input wire [23:0] cfg_order,input wire [13:0] cfg_lead,
 input wire [55:0] local_notes,input wire [31:0] held,input wire [223:0] notes,
 input wire preview_valid,input wire [63:0] preview_time,music_time,input wire [127:0] preview_notes,
 input wire [7:0] player_state,error_code,
 output reg prefix,output reg [215:0] colors,output reg [5:0] unmapped_count,
 output reg [31:0] invalid_config_count
);
 reg [23:0] order;reg [13:0] lead;
 reg [7:0] current,upcoming;reg [7:0] used;reg permutation_ok;
 reg found;integer i,j,n,offset;
 function note_equal(input [6:0] a,b);
  reg [3:0] matched /* synthesis syn_keep=1 */;
  begin
   matched[0]=(a[1:0]==b[1:0]);matched[1]=(a[3:2]==b[3:2]);
   matched[2]=(a[5:4]==b[5:4]);matched[3]=(a[6]==b[6]);
   note_equal=&matched;
  end
 endfunction
 reg [23:0] key_color[0:7];
 wire [3:0] lamp_position[0:7];
 generate for(genvar k=0;k<8;k=k+1)begin: fixed_position
  assign lamp_position[k]={1'b0,order[k*3+:3]}+{3'd0,prefix};
 end endgenerate
 always @(*)begin
  used=0;permutation_ok=cfg_lead<=9600;
  for(i=0;i<8;i=i+1)begin if(used[cfg_order[i*3+:3]])permutation_ok=0;used[cfg_order[i*3+:3]]=1;end
  current=0;upcoming=0;unmapped_count=0;found=0;
  for(i=0;i<32;i=i+1)if(held[i])begin
   found=0;for(j=0;j<8;j=j+1)if(note_equal(notes[i*7+:7],local_notes[j*7+:7]))begin current[j]=1;found=1;end
   if(!found)unmapped_count=unmapped_count+1;
  end
  if(preview_valid&&preview_time>=music_time&&preview_time-music_time<=lead)
   for(j=0;j<8;j=j+1)upcoming[j]=preview_notes[local_notes[j*7+:7]];
  colors=0;offset=prefix?1:0;
  if(prefix)begin
   if(error_code!=0)colors[23:0]=24'h001800;
   else if(player_state==3||unmapped_count!=0)colors[23:0]=24'h101000;
   else if(player_state==2)colors[23:0]=24'h080000;
  end
  for(j=0;j<8;j=j+1)begin
   key_color[j]=0;
   if(player_state==3)key_color[j]=24'h080800;
   else if(current[j])key_color[j]=24'h180000;
   else if(upcoming[j])key_color[j]=24'h000010;
  end
  // Fixed output slices avoid integer multiply and a variable 216-bit write.
  // Order remains an accepted permutation, and ascending-key overwrite wins.
  for(n=0;n<9;n=n+1)for(j=0;j<8;j=j+1)
   if(lamp_position[j]==n)begin
    colors[n*24+:24]=colors[n*24+:24]|key_color[j];
   end
 end
 always @(posedge clk)begin
  if(rst)begin prefix<=1;order<=24'hfac688;lead<=4800;invalid_config_count<=0;end
  else if(cfg_valid)begin
   if(permutation_ok)begin prefix<=cfg_prefix;order<=cfg_order;lead<=cfg_lead;end
   else invalid_config_count<=invalid_config_count+1;
  end
 end
endmodule

// Scan one logical score key per cycle; retain each complete input version.
// A result is available every 42 clocks (1.68us at 25MHz).
module r28_serial_guide(
 input wire clk,rst,cfg_valid,cfg_prefix,input wire[23:0] cfg_order,input wire[13:0] cfg_lead,
 input wire[55:0] local_notes,input wire[31:0] held,input wire[223:0] notes,
 input wire preview_valid,input wire[63:0] preview_time,music_time,input wire[127:0] preview_notes,
 input wire[7:0] player_state,error_code,
 output reg prefix,output wire[215:0] colors,output reg[5:0] unmapped_count,
 output reg[31:0] invalid_config_count,output reg[26:0] palette,output reg palette_valid
);
 reg config_prefix;reg[23:0] order;reg[13:0] lead;
 reg[7:0] used;reg permutation_ok;
 always @*begin
  used=0;permutation_ok=cfg_lead<=9600;
  for(integer i=0;i<8;i++)begin
   if(used[cfg_order[i*3+:3]])permutation_ok=0;
   used[cfg_order[i*3+:3]]=1;
  end
 end
 reg[5:0] phase;
 reg[31:0] held_q;reg[223:0] notes_q;reg[55:0] local_q;
 reg[127:0] preview_q;reg preview_enabled,prefix_q;
 reg[23:0] order_q;reg[7:0] state_q;reg error_q;
 reg[7:0] current;reg[5:0] unmapped_q;reg[26:0] building;
 wire[7:0] match_bits;
 for(genvar k=0;k<8;k++)begin: match_key
  assign match_bits[k]=notes_q[6:0]==local_q[k*7+:7];
 end
 wire[2:0] key_index=phase-33;
 wire[6:0] next_note=local_q[key_index*7+:7];
 wire[3:0] position={1'b0,order_q[key_index*3+:3]}+prefix_q;
 wire[2:0] key_code=state_q==3?3'd4:current[key_index]?3'd1:
   preview_enabled&&preview_q[next_note]?3'd5:3'd0;
 function automatic[23:0] color(input[2:0] code);
  case(code)
   1:color=24'h180000;2:color=24'h001800;3:color=24'h101000;
   4:color=24'h080800;5:color=24'h000010;6:color=24'h080000;default:color=0;
  endcase
 endfunction
 for(genvar p=0;p<9;p++)assign colors[p*24+:24]=color(palette[p*3+:3]);
 always @(posedge clk)begin
  palette_valid<=0;
  if(rst)begin
   config_prefix<=1;order<=24'hfac688;lead<=4800;invalid_config_count<=0;
   phase<=0;prefix<=1;palette<=0;unmapped_count<=0;held_q<=0;notes_q<=0;local_q<=0;
   preview_q<=0;preview_enabled<=0;prefix_q<=1;order_q<=0;state_q<=0;error_q<=0;
   current<=0;unmapped_q<=0;building<=0;
  end else begin
   if(cfg_valid)begin
    if(permutation_ok)begin config_prefix<=cfg_prefix;order<=cfg_order;lead<=cfg_lead;end
    else invalid_config_count<=invalid_config_count+1;
   end
   if(phase==0)begin
    held_q<=held;notes_q<=notes;local_q<=local_notes;preview_q<=preview_notes;
    preview_enabled<=preview_valid&&preview_time>=music_time&&preview_time-music_time<=lead;
    prefix_q<=config_prefix;order_q<=order;state_q<=player_state;error_q<=error_code!=0;
    current<=0;unmapped_q<=0;building<=0;phase<=1;
   end else if(phase<=32)begin
    if(held_q[0])begin current<=current|match_bits;if(match_bits==0)unmapped_q<=unmapped_q+1'b1;end
    held_q<=held_q>>1;notes_q<=notes_q>>7;phase<=phase+1'b1;
   end else if(phase<=40)begin
    for(integer k=0;k<9;k++)if(position==k)building[k*3+:3]<=key_code;
    if(phase==33&&prefix_q)building[2:0]<=error_q?3'd2:
      state_q==3||unmapped_q!=0?3'd3:state_q==2?3'd6:3'd0;
    phase<=phase+1'b1;
   end else begin
    prefix<=prefix_q;palette<=building;unmapped_count<=unmapped_q;palette_valid<=1;phase<=0;
   end
  end
 end
endmodule

// Only a 27-bit palette snapshot and the current 24-bit lamp word are shifted.
module r28_palette_serializer #(
 parameter integer T0H=16,T0L=48,T1H=34,T1L=30,RESET_CLOCKS=16000,REFRESH_CLOCKS=250000
)(input wire clk,rst,prefix,input wire[26:0] palette,
 output reg led_dout,output reg busy,output reg[31:0] completed_frames);
 reg[26:0] snapshot;reg[23:0] word_q;reg[17:0] refresh_count;reg[15:0] count;
 reg[3:0] lamp,lamps;reg[4:0] bit_index;reg[1:0] state;reg first_blank;
 wire[15:0] high_clocks=word_q[23]?T1H:T0H;
 wire[15:0] total_clocks=word_q[23]?T1H+T1L:T0H+T0L;
 function automatic[23:0] color(input[2:0] code);
  case(code)
   1:color=24'h180000;2:color=24'h001800;3:color=24'h101000;
   4:color=24'h080800;5:color=24'h000010;6:color=24'h080000;default:color=0;
  endcase
 endfunction
 always @(posedge clk)begin
  if(rst)begin state<=0;count<=0;led_dout<=0;busy<=1;first_blank<=1;
   refresh_count<=0;snapshot<=0;word_q<=0;lamp<=0;bit_index<=23;lamps<=9;completed_frames<=0;
  end else begin
   if(refresh_count<REFRESH_CLOCKS)refresh_count<=refresh_count+1;
   case(state)
    0:begin
     led_dout<=0;busy<=1;
     if(count+1>=RESET_CLOCKS)begin count<=0;
      if(first_blank)begin first_blank<=0;snapshot<=0;word_q<=0;lamps<=prefix?9:8;lamp<=0;bit_index<=23;state<=2;end
      else begin state<=1;busy<=0;end
     end else count<=count+1;
    end
    1:if(refresh_count>=REFRESH_CLOCKS)begin
     snapshot<=palette;word_q<=color(palette[2:0]);lamps<=prefix?9:8;lamp<=0;bit_index<=23;count<=0;state<=2;busy<=1;refresh_count<=0;
    end
    2:begin
     led_dout<=count<high_clocks;
     if(count+1>=total_clocks)begin count<=0;
      if(bit_index==0)begin bit_index<=23;
       if(lamp+1>=lamps)begin state<=0;lamp<=0;completed_frames<=completed_frames+1;end
       else begin lamp<=lamp+1;word_q<=color(snapshot[(lamp+1)*3+:3]);end
      end else begin bit_index<=bit_index-1;word_q<=word_q<<1;end
     end else count<=count+1;
    end
   endcase
  end
 end
endmodule

module r28_guide_old_probe(
 input wire clk,rst,cfg_valid,cfg_prefix,input wire[23:0] cfg_order,input wire[13:0] cfg_lead,
 input wire[55:0] local_notes,input wire[31:0] held,input wire[223:0] notes,
 input wire preview_valid,input wire[63:0] preview_time,music_time,input wire[127:0] preview_notes,
 input wire[7:0] player_state,error_code,
 output wire led_dout,output wire[5:0] unmapped_count,output wire[31:0] invalid_config_count
);
wire prefix;wire[215:0] colors;wire[26:0] palette;
score_guide guide(.*);
ws2812_guide_serializer #(.T0H(8),.T0L(24),.T1H(17),.T1L(15),.RESET_CLOCKS(8000),.REFRESH_CLOCKS(125000)) leds(.busy(),.completed_frames(),.*);
endmodule

module r28_guide_serial_probe(
 input wire clk,rst,cfg_valid,cfg_prefix,input wire[23:0] cfg_order,input wire[13:0] cfg_lead,
 input wire[55:0] local_notes,input wire[31:0] held,input wire[223:0] notes,
 input wire preview_valid,input wire[63:0] preview_time,music_time,input wire[127:0] preview_notes,
 input wire[7:0] player_state,error_code,
 output wire led_dout,output wire[5:0] unmapped_count,output wire[31:0] invalid_config_count
);
wire prefix;wire[215:0] colors;wire[26:0] palette;
r28_serial_guide guide(.palette_valid(),.*);
r28_palette_serializer #(.T0H(8),.T0L(24),.T1H(17),.T1L(15),.RESET_CLOCKS(8000),.REFRESH_CLOCKS(125000)) leds(.busy(),.completed_frames(),.*);
endmodule
