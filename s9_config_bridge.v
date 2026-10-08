// Stage9 parameter adapter. Frozen parameter engines retain their arithmetic.
// COMMITTED follows the real configuration edge; EFFECTIVE names an observed
// snapshot frame. It never asserts that a muted/cancelled sound was audible.
module s9_config_bridge #(parameter integer ENABLE_FIELD=0, DEFER_RESULT_CRC=0)(
 input wire clk,rst,session_flush,session_ready,input wire[127:0] session_id,
 input wire config_valid,output wire config_ready,input wire[2:0] config_slot,input wire[1535:0] config_bytes,
 input wire sample_tick,input wire[31:0] sample_time,now_ms,
 input wire[3:0] local_glide_code,output reg[3:0] glide_code,output reg[2:0] timbre_id,
 output wire fx_cfg_valid,output wire[351:0] fx_cfg_data,
 input wire[31:0] fx_accepted,fx_frame_version,
 output wire gain_cfg_valid,output wire[15:0] gain_local,gain_external,
 output wire gain_local_mute,gain_external_mute,
 input wire gain_sample,input wire[31:0] gain_frame,gain_frame_version,gain_accepted,
 input wire[15:0] gain_l,gain_e,input wire[6:0] gain_remaining,
 output wire pan_valid,output wire[4:0] pan_slot,output wire[63:0] pan_id,
 output wire[15:0] pan_generation,output wire[8:0] pan_value,
 input wire identity_stable,query_found,input wire[63:0] query_id,input wire[15:0] query_generation,
 output wire[7:0] query_key,output wire[63:0] query_press,
 input wire pan_found,input wire[4:0] pan_found_slot,
 output wire[63:0] identity_pan_id,output wire[15:0] identity_pan_generation,
 input wire[287:0] snapshot_pan,input wire[2047:0] snapshot_ids,input wire[511:0] snapshot_generations,
 input wire[7:0] local_gate,input wire local_pending,output wire[55:0] keymap,
 output wire[31:0] keymap_version,
 output wire field_valid,field_start,output wire[1:0] field_size,
 input wire field_ready,field_active,field_rejected,field_committed,field_running,
 output wire lookup_valid,input wire lookup_ready,output wire lookup_channel,lookup_echo,
 output wire[31:0] lookup_sequence,input wire lookup_done,input wire signed[15:0] lookup_error,input wire[511:0] lookup_result,
 output reg result_valid,input wire result_ready,output reg[2:0] result_slot,
 output wire[31:0] result_sequence,output wire[511:0] result_bytes,output reg result_final
);
 // 0 immediate,1 Glide,2 Pan,3 Effects,4 Gain,5 keymap,6 query/barrier.
 reg[6:0] valid,dirty;
 reg[31:0] seq[0:6],frame[0:6],version[0:6];reg[2:0] slot[0:6],phase[0:6];
 reg signed[15:0] error[0:6];
 reg[63:0] held_pan_id,reply_id;reg[15:0] held_pan_generation,reply_generation;
 reg[4:0] held_pan_slot;reg[8:0] held_pan_value;
 reg[15:0] target_l,target_e;reg[3:0] previous_local_glide;
 reg tick_d,pan_defer_snapshot;reg[31:0] tick_frame;
 reg lookup_busy,lookup_is_query,lookup_is_instance,lookup_ch;
 reg[2:0] lookup_required;reg[31:0] lookup_seq,lookup_polled_ms;
 reg[2:0] result_index,cursor;
 reg[255:0] result_fields;reg[7:0] result_flags;
 reg hello_pending,field_pending,field_target_start;reg[70:0] hello_snapshot;
 wire[7:0] opcode=config_bytes[55:48];wire[31:0] command_sequence=config_bytes[223:192];
 reg[2:0] index;integer i;
 always @*begin
  case(opcode)33:index=1;34:index=2;35:index=3;36:index=4;37:index=5;4,39,40:index=6;default:index=0;endcase
 end
 wire map_accepted,map_rejected,map_applied,map_cancelled,map_pending;
 wire[31:0] map_applied_sequence,map_cancelled_sequence;wire[2:0] map_applied_slot,map_cancelled_slot;
 wire local_idle=local_gate==0&&!local_pending;
 wire replace_gain=index==4&&valid[4]&&phase[4]<5;
 wire replace_map=index==5&&valid[5]&&phase[5]==3&&map_pending&&!local_idle;
 wire replaceable=config_valid&&(replace_gain||replace_map)&&!result_valid;
 wire identity_needed=opcode==34||opcode==39;
 assign config_ready=!rst&&!session_flush&&session_ready&&(!valid[index]||replaceable)&&
                     (!identity_needed||identity_stable)&&(opcode!=86||!ENABLE_FIELD||field_ready);
 wire accept=config_valid&&config_ready;
 assign field_valid=accept&&opcode==86&&ENABLE_FIELD;
 assign field_start=config_bytes[263:256]==1;
 assign field_size=config_bytes[271:264]==1?0:config_bytes[271:264]==8?1:config_bytes[271:264]==16?2:3;
 assign fx_cfg_valid=accept&&opcode==35;assign fx_cfg_data=config_bytes[607:256];
 assign gain_cfg_valid=accept&&opcode==36;
 assign gain_local=config_bytes[271:256];assign gain_external=config_bytes[287:272];
 assign gain_local_mute=config_bytes[288];assign gain_external_mute=config_bytes[289];
 assign identity_pan_id=(valid[2])?held_pan_id:config_bytes[319:256];
 assign identity_pan_generation=(valid[2])?held_pan_generation:config_bytes[335:320];
 assign pan_valid=accept&&opcode==34&&pan_found;
 assign pan_slot=pan_found_slot;assign pan_id=config_bytes[319:256];
 assign pan_generation=config_bytes[335:320];assign pan_value=config_bytes[344:336];
 assign query_key=config_bytes[263:256];assign query_press=config_bytes[327:264];
 s9_keymap_config u_map(.clk(clk),.rst(rst),.disconnect(session_flush),
  .cfg_valid(accept&&opcode==37),.cfg_notes(config_bytes[319:256]),.cfg_sequence(command_sequence),.cfg_slot(config_slot),
  .local_gate(local_gate),.local_pending(local_pending),.active_notes(keymap),.version(keymap_version),
  .accepted(map_accepted),.rejected(map_rejected),.applied(map_applied),.applied_sequence(map_applied_sequence),.applied_slot(map_applied_slot),
  .cancelled(map_cancelled),.cancelled_sequence(map_cancelled_sequence),.cancelled_slot(map_cancelled_slot),.pending(map_pending));
 assign lookup_valid=valid[6]&&!lookup_is_instance&&phase[6]<3&&!lookup_busy&&lookup_polled_ms!=now_ms;
 assign lookup_channel=lookup_ch;assign lookup_sequence=lookup_seq;assign lookup_echo=lookup_is_query;
 assign result_sequence=result_fields[31:0];
 reg[511:0] packed_result;reg[31:0] crc;integer j;
 function[31:0] crcbyte(input[31:0] c,input[7:0] b);
  reg[31:0] v;integer k;begin v=c^b;for(k=0;k<8;k=k+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
 always @*begin
  packed_result=0;packed_result[31:0]=32'h54533953;packed_result[39:32]=1;packed_result[47:40]=2;
  packed_result[63:56]=result_flags;packed_result[191:64]=session_id;packed_result[447:192]=result_fields;
  crc=32'hffffffff;if(!DEFER_RESULT_CRC)begin for(j=0;j<60;j=j+1)crc=crcbyte(crc,packed_result[j*8+:8]);packed_result[511:480]=~crc;end
 end
 assign result_bytes=packed_result;
 reg found_dirty;reg[2:0] selected;integer n;
 always @*begin
  found_dirty=0;selected=0;
  for(integer k=0;k<7;k=k+1)begin
   n=cursor+k;if(n>=7)n=n-7;
   if(valid[n]&&dirty[n]&&!found_dirty)begin found_dirty=1;selected=n;end
  end
 end
 task prepare_result(input[2:0] which,input[2:0] p);
  begin
   result_valid<=1;result_index<=which;result_slot<=slot[which];result_fields<=0;result_flags<=0;
   result_fields[31:0]<=seq[which];result_fields[39:32]<=1;result_fields[47:40]<={5'd0,p};
   result_fields[63:48]<=error[which];result_fields[95:64]<=frame[which];result_fields[127:96]<=version[which];
   if(p==4||p==5)result_flags<=1;
   if(which==6&&lookup_is_instance&&p==3)begin result_flags<=2;result_fields[191:128]<=reply_id;result_fields[207:192]<=reply_generation;end
   if(which==0&&hello_pending&&p==3)begin
    result_flags<=1;result_fields[159:128]<=hello_snapshot[31:0];
    result_fields[207:192]<=hello_snapshot[47:32];result_fields[223:208]<=hello_snapshot[63:48];
    result_fields[230:224]<=hello_snapshot[70:64];
   end
   result_final<=p>=6||(which==4?p==5:(p==4||((which==0&&!field_pending||which==6)&&p==3)));
  end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   valid<=0;dirty<=0;glide_code<=0;timbre_id<=0;previous_local_glide<=0;tick_d<=0;tick_frame<=0;pan_defer_snapshot<=0;
   hello_pending<=0;field_pending<=0;field_target_start<=0;hello_snapshot<=0;
   held_pan_id<=0;held_pan_generation<=0;held_pan_slot<=0;held_pan_value<=128;reply_id<=0;reply_generation<=0;
   target_l<=32768;target_e<=32768;lookup_busy<=0;lookup_is_query<=0;lookup_is_instance<=0;lookup_ch<=0;
   lookup_required<=3;lookup_seq<=0;lookup_polled_ms<=0;result_valid<=0;result_final<=0;result_slot<=0;result_index<=0;
   cursor<=0;result_fields<=0;result_flags<=0;
   for(i=0;i<7;i=i+1)begin seq[i]<=0;slot[i]<=0;phase[i]<=0;frame[i]<=0;version[i]<=0;error[i]<=0;end
  end else begin
   tick_d<=sample_tick;if(sample_tick)tick_frame<=sample_time;
   previous_local_glide<=local_glide_code;
   if(result_valid&&result_ready)begin
    result_valid<=0;
    if(result_final&&seq[result_index]==result_sequence)begin valid[result_index]<=0;dirty[result_index]<=0;if(result_index==0)field_pending<=0;end
   end
   if(!result_valid&&found_dirty&&!replaceable)begin
    prepare_result(selected,phase[selected]);dirty[selected]<=0;cursor<=selected==6?0:selected+1'b1;
   end
   if(field_pending&&valid[0])begin
    if(field_rejected)begin phase[0]<=7;error[0]<=-3;dirty[0]<=1;end
    else if(field_committed&&phase[0]==2)begin phase[0]<=3;frame[0]<=sample_time;dirty[0]<=1;end
    else if(phase[0]==3&&((field_target_start&&field_running)||(!field_target_start&&!field_active)))begin phase[0]<=4;frame[0]<=sample_time;dirty[0]<=1;end
   end
   // Record real snapshot edges even while an older result is backpressured.
   if(valid[0]&&hello_pending&&phase[0]==2&&gain_sample)begin
    phase[0]<=3;frame[0]<=gain_frame;version[0]<=fx_frame_version;dirty[0]<=1;
    hello_snapshot<={glide_code,timbre_id,gain_e,gain_l,keymap_version};
   end
   if(valid[1]&&phase[1]==3&&sample_tick)begin phase[1]<=4;frame[1]<=sample_time;dirty[1]<=1;end
   if(valid[2]&&phase[2]==3&&tick_d)begin
    if(pan_defer_snapshot)pan_defer_snapshot<=0;
    else if(snapshot_ids[held_pan_slot*64+:64]==held_pan_id&&snapshot_generations[held_pan_slot*16+:16]==held_pan_generation&&
       snapshot_pan[held_pan_slot*9+:9]==held_pan_value)begin phase[2]<=4;frame[2]<=tick_frame;dirty[2]<=1;end
    else if(identity_stable&&!pan_found)begin phase[2]<=7;error[2]<=-11;dirty[2]<=1;end
   end
   if(valid[3]&&phase[3]==3&&tick_d&&fx_frame_version==version[3])begin phase[3]<=4;frame[3]<=tick_frame;dirty[3]<=1;end
   if(valid[4]&&phase[4]>=3&&phase[4]<5&&gain_sample&&gain_frame_version==version[4])begin
    if(phase[4]==3)begin phase[4]<=4;frame[4]<=gain_frame;dirty[4]<=1;end
    if(gain_remaining==0&&gain_l==target_l&&gain_e==target_e)begin phase[4]<=5;frame[4]<=gain_frame;dirty[4]<=1;end
   end
   if(valid[5]&&phase[5]==3&&sample_tick&&!map_pending&&keymap_version==version[5])begin phase[5]<=4;frame[5]<=sample_time;dirty[5]<=1;end
   if(local_glide_code!=previous_local_glide&&local_glide_code<=11)begin
    glide_code<=local_glide_code;
    if(valid[1]&&phase[1]==3)begin phase[1]<=6;dirty[1]<=1;end
   end
   if(lookup_valid&&lookup_ready)begin lookup_busy<=1;lookup_polled_ms<=now_ms;end
   if(lookup_done&&lookup_busy)begin
    lookup_busy<=0;
    if(lookup_error!=0)begin phase[6]<=7;error[6]<=lookup_error;dirty[6]<=1;end
    else if(lookup_is_query)begin phase[6]<=3;dirty[6]<=1;end
    else if(lookup_result[239:232]>=6)begin phase[6]<=7;error[6]<=-10;dirty[6]<=1;end
    else if(lookup_result[239:232]>=lookup_required)begin phase[6]<=3;dirty[6]<=1;end
   end
   if(accept)begin
    if(replaceable)prepare_result(index,3'd6);
    valid[index]<=1;dirty[index]<=1;seq[index]<=command_sequence;slot[index]<=config_slot;
    phase[index]<=3;error[index]<=0;frame[index]<=0;version[index]<=0;
    case(opcode)
     1:begin hello_pending<=1;phase[0]<=2;dirty[0]<=0;end
     86:begin hello_pending<=0;if(ENABLE_FIELD)begin field_pending<=1;field_target_start<=field_start;phase[0]<=2;dirty[0]<=0;end else begin phase[0]<=7;error[0]<=-2;end end
     32:begin field_pending<=0;timbre_id<=config_bytes[258:256];hello_pending<=0;end
     33:begin
      if(local_glide_code!=previous_local_glide)begin phase[1]<=7;error[1]<=-10;end
      else glide_code<=config_bytes[259:256];
     end
     34:begin
      pan_defer_snapshot<=sample_tick;
      if(!pan_found)begin phase[2]<=7;error[2]<=-11;end
      held_pan_id<=pan_id;held_pan_generation<=pan_generation;held_pan_slot<=pan_slot;held_pan_value<=pan_value;
     end
     35:version[3]<=fx_accepted+1'b1;
     36:begin version[4]<=gain_accepted+1'b1;target_l<=gain_local_mute?0:gain_local;target_e<=gain_external_mute?0:gain_external;end
     37:version[5]<=keymap_version+1'b1;
     39:begin lookup_is_instance<=1;reply_id<=query_id;reply_generation<=query_generation;if(!query_found)begin phase[6]<=7;error[6]<=-11;end end
     4,40:begin
      lookup_is_instance<=0;lookup_is_query<=opcode==4;lookup_ch<=config_bytes[256];
      lookup_seq<=opcode==4?config_bytes[295:264]:config_bytes[319:288];
      lookup_required<=opcode==4?3:config_bytes[266:264];lookup_busy<=0;lookup_polled_ms<=now_ms-1'b1;
      phase[6]<=2;dirty[6]<=0;
     end
     // MCU consumes HELLO/KEEP/CLOSE and PLAY, never fabricates their FPGA ACK.
     default:begin phase[0]<=7;error[0]<=-10;end
    endcase
   end
   if(session_flush)begin field_pending<=0;valid<=0;dirty<=0;result_valid<=0;lookup_busy<=0;end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if((^{session_flush,session_ready,config_valid,sample_tick,gain_sample,identity_stable,local_pending,result_ready,lookup_ready,lookup_done,local_glide_code})===1'bx)$fatal(1,"S9_CONFIG_CONTROL_XZ");
  if(config_valid&&(^({config_bytes,config_slot}))===1'bx)$fatal(1,"S9_CONFIG_INPUT_XZ");
  if(gain_sample&&(^({gain_frame,gain_frame_version,gain_l,gain_e,gain_remaining}))===1'bx)$fatal(1,"S9_CONFIG_GAIN_XZ");
 end
 // synthesis translate_on
endmodule
