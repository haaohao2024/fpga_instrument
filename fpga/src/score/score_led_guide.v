
// Scan one logical score key per cycle; retain each complete input version.
// A result is available every 42 clocks (1.05us at 40MHz).
module score_led_guide(
 input wire clk,rst,cfg_valid,cfg_prefix,input wire raw_mode,input wire[23:0] cfg_order,input wire[13:0] cfg_lead,
 input wire[55:0] local_notes,input wire[31:0] held,input wire[223:0] notes,
 input wire preview_valid,input wire[63:0] preview_time,music_time,input wire[127:0] preview_notes,
 input wire[7:0] player_state,error_code,
 output reg prefix,output wire[215:0] colors,output reg[5:0] unmapped_count,
 output reg[31:0] invalid_config_count,output reg[26:0] palette,output reg palette_valid
);
 reg config_prefix;reg[23:0] order;reg[13:0] lead;
 // One subtractor serves both legacy absolute64 and raw modulo32 preview.
 // lead<=9600. Upper-zero tests exclude past and distant targets; raw uses
 // only low32, so 0xfffffff0 -> 0x10 remains a future32-sample preview.
 wire raw_enabled=(raw_mode===1'b1);
 wire [64:0] preview_distance={1'b0,preview_time}-{1'b0,music_time};
 wire preview_near=preview_distance[31:14]==0&&preview_distance[13:0]<=lead;
 wire preview_in_window=preview_near&&(raw_enabled||preview_distance[64:32]==0);
 reg[7:0] used;reg permutation_ok;
 always @*begin
  used=0;permutation_ok=cfg_lead<=9600;
  for(integer i=0;i<8;i++)begin
   if(used[cfg_order[i*3+:3]])permutation_ok=0;
   used[cfg_order[i*3+:3]]=1;
  end
 end
 reg[5:0] phase;
 // Only score slots 0..7 drive lamps (8 physical keys; export fills slots from 0).
 // Scanning all 32 kept the sequencer's 224-bit guide note state (~1.5k LUT) and
 // the full build no longer routed.
 reg[7:0] held_q;reg[55:0] notes_q;reg[55:0] local_q;
 reg[127:0] preview_q;reg preview_enabled,prefix_q;
 reg[23:0] order_q;reg[7:0] state_q;reg error_q;
 reg[7:0] current;reg[5:0] unmapped_q;reg[26:0] building;
 wire[7:0] match_bits;
 for(genvar k=0;k<8;k++)begin: match_key
  assign match_bits[k]=notes_q[6:0]==local_q[k*7+:7];
 end
 // Explicit key counter and constant-index selects: Gowin synthesis mapped the
 // former phase-derived variable part-selects wrongly (gate-level: only keys 6/7
 // produced codes, key 6 at lamp 0). Same behaviour as the RTL intent.
 reg[2:0] kidx;reg[2:0] order_sel;reg[6:0] next_note;reg current_sel;
 always @*begin
  case(kidx)
   3'd0:begin order_sel=order_q[2:0];  next_note=local_q[6:0];  current_sel=current[0];end
   3'd1:begin order_sel=order_q[5:3];  next_note=local_q[13:7]; current_sel=current[1];end
   3'd2:begin order_sel=order_q[8:6];  next_note=local_q[20:14];current_sel=current[2];end
   3'd3:begin order_sel=order_q[11:9]; next_note=local_q[27:21];current_sel=current[3];end
   3'd4:begin order_sel=order_q[14:12];next_note=local_q[34:28];current_sel=current[4];end
   3'd5:begin order_sel=order_q[17:15];next_note=local_q[41:35];current_sel=current[5];end
   3'd6:begin order_sel=order_q[20:18];next_note=local_q[48:42];current_sel=current[6];end
   default:begin order_sel=order_q[23:21];next_note=local_q[55:49];current_sel=current[7];end
  endcase
 end
 wire[3:0] position={1'b0,order_sel}+{3'd0,prefix_q};
 // r3b: no 'upcoming note' (blue) preview. With the guide fixed, the FIFO peek
 // state machine, 128-bit note map and 64-bit preview compare all became live
 // and the full design stopped routing; the current-key lamp is what teaches.
 wire[2:0] key_code=state_q==8'd3 ? 3'd4 : current_sel ? 3'd1 : 3'd0;
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
   current<=0;unmapped_q<=0;building<=0;kidx<=0;
  end else begin
   if(cfg_valid)begin
    if(permutation_ok)begin config_prefix<=cfg_prefix;order<=cfg_order;lead<=cfg_lead;end
    else invalid_config_count<=invalid_config_count+1;
   end
   if(phase==0)begin
    held_q<=held[7:0];notes_q<=notes[55:0];local_q<=local_notes;preview_q<=preview_notes;
    preview_enabled<=preview_valid&&preview_in_window;
    prefix_q<=config_prefix;order_q<=order;state_q<=player_state;error_q<=error_code!=0;
    current<=0;unmapped_q<=0;building<=0;kidx<=0;phase<=1;
   end else if(phase<=6'd8)begin
    if(held_q[0])begin current<=current|match_bits;if(match_bits==0)unmapped_q<=unmapped_q+1'b1;end
    held_q<=held_q>>1;notes_q<=notes_q>>7;phase<=phase+1'b1;
   end else if(phase<=6'd16)begin
    case(position)
     4'd0:building[2:0]<=key_code;4'd1:building[5:3]<=key_code;4'd2:building[8:6]<=key_code;
     4'd3:building[11:9]<=key_code;4'd4:building[14:12]<=key_code;4'd5:building[17:15]<=key_code;
     4'd6:building[20:18]<=key_code;4'd7:building[23:21]<=key_code;4'd8:building[26:24]<=key_code;default:;
    endcase
    if(phase==6'd9&&prefix_q)building[2:0]<=error_q?3'd2:
      state_q==8'd3||unmapped_q!=0 ? 3'd3 : state_q==8'd2 ? 3'd6 : 3'd0;
    kidx<=kidx+1'b1;phase<=phase+1'b1;
   end else begin
    prefix<=prefix_q;palette<=building;unmapped_count<=unmapped_q;palette_valid<=1;phase<=0;
   end
  end
 end
endmodule

// Only a 27-bit palette snapshot and the current 24-bit lamp word are shifted.
module ws2812_serializer #(
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

