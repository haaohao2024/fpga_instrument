module r22_config_bridge #(parameter integer ENABLE_FIELD=0, DEFER_RESULT_CRC=0)(
 input wire [127:0] ensemble_metrics,
 input wire config_payload_changed,
 output wire id_req_valid,id_req_pan,input wire id_req_ready,
 output wire[7:0] id_req_key,output wire[63:0] id_req_identity,
 output wire[15:0] id_req_generation,id_req_tag,
 input wire id_response_valid,id_response_found,input wire[5:0] id_response_slot,
 input wire[314:0] id_response_word,input wire[15:0] id_response_tag,
 input wire pan_ready,pan_response_valid,input wire[1:0] pan_result,
 input wire[5:0] pan_response_slot,input wire[314:0] pan_response_before,pan_response_after,
 input wire fact_valid,input wire[7:0] fact_outcome,input wire[5:0] fact_slot,
 input wire clk,rst,session_flush,session_ready,input wire[127:0] session_id,
 input wire config_valid,output wire config_ready,input wire[2:0] config_slot,input wire[1535:0] config_bytes,
 input wire sample_tick,input wire[31:0] sample_time,now_ms,
 input wire[3:0] local_glide_code,output reg[3:0] glide_code,output reg[2:0] timbre_id,
 output reg fx_cfg_valid,output reg[351:0] fx_cfg_data,
 input wire[31:0] fx_accepted,fx_frame_version,
 output wire gain_cfg_valid,output wire[15:0] gain_local,gain_external,
 output wire gain_local_mute,gain_external_mute,
 input wire gain_sample,input wire[31:0] gain_frame,gain_frame_version,gain_accepted,
 input wire[15:0] gain_l,gain_e,input wire[6:0] gain_remaining,
 output wire pan_valid,output wire[5:0] pan_slot,output wire[63:0] pan_id,
 output wire[15:0] pan_generation,output wire[8:0] pan_value,
 input wire identity_stable,
 input wire[7:0] local_gate,input wire local_pending,output wire[55:0] keymap,
 output wire[31:0] keymap_version,
 output wire field_valid,field_start,output wire[2:0] field_size,
 input wire field_ready,field_active,field_rejected,field_committed,field_running,
 output wire lookup_valid,input wire lookup_ready,output wire lookup_channel,lookup_echo,
 output wire[31:0] lookup_sequence,input wire lookup_done,input wire signed[15:0] lookup_error,input wire[511:0] lookup_result,
 output reg result_valid,input wire result_ready,output reg[2:0] result_slot,
 output wire[31:0] result_sequence,output wire[511:0] result_bytes,output reg result_final
);
 wire r54_equal_0;
 wire r54_equal_1;
 wire r54_equal_2;

 // 0 immediate,1 Glide,2 Pan,3 Effects,4 Gain,5 keymap,6 query/barrier.
 reg[6:0] valid,dirty;
 reg[31:0] frame[0:6],version[0:6];reg[2:0] slot[0:6],phase[0:6];
 reg signed[4:0] error[0:6];
 reg[63:0] held_pan_id,reply_id;reg[15:0] held_pan_generation,reply_generation;
 reg[5:0] held_pan_slot;reg[8:0] held_pan_value;
 reg[15:0] target_l,target_e;reg[3:0] previous_local_glide;
 reg tick_d,pan_defer_snapshot;reg[31:0] tick_frame;
 wire lookup_is_instance=1'b1;
 
 reg[2:0] result_index,cursor;
 reg[255:0] result_fields;reg[7:0] result_flags;
 reg metrics_pending;reg[127:0] metrics_snapshot;
 reg hello_pending,field_pending,field_target_start;reg[70:0] hello_snapshot;
 // Opcode decode is registered; a command is ready only once the registered
 // opcode matches the port, so index always belongs to the current bytes.
 wire[7:0] port_opcode=config_bytes[39:32];
 reg[7:0] opcode;reg[2:0] index;integer i;
 wire decoded=port_opcode==opcode;
 always @(posedge clk)begin
  opcode<=port_opcode;
  case(port_opcode)33:index<=1;34:index<=2;35:index<=3;36:index<=4;37:index<=5;39:index<=6;default:index<=0;endcase
 end
 wire map_accepted,map_rejected,map_applied,map_cancelled,map_pending;
 wire[31:0] map_applied_sequence,map_cancelled_sequence;wire[2:0] map_applied_slot,map_cancelled_slot;
 wire local_idle=local_gate==0&&!local_pending;
 wire replace_gain=index==4&&valid[4]&&phase[4]<5;
 wire replace_map=index==5&&valid[5]&&phase[5]==3&&map_pending&&!local_idle;
 wire replaceable=config_valid&&decoded&&(replace_gain||replace_map)&&!result_valid;
 wire identity_needed=opcode==34||opcode==39;
 wire command_available=!rst&&!session_flush&&session_ready&&decoded&&(!valid[index]||replaceable);
 reg pan_request_pending;
 reg id_wait,id_prepared,id_found;reg[5:0] id_slot;reg[314:0] id_word;
 reg[15:0] id_serial,id_active_tag;reg pan_watch_valid;
 assign id_req_valid=config_valid&&!config_payload_changed&&command_available&&identity_needed&&!id_wait&&!id_prepared;
 assign id_req_pan=opcode==34;assign id_req_key=config_bytes[151:144];
 assign id_req_identity=config_bytes[127:64];
 assign id_req_generation=config_bytes[143:128];assign id_req_tag=id_serial;
 assign config_ready=command_available&&(!identity_needed||(identity_stable&&id_prepared))&&
  (opcode!=34||!pan_request_pending)&&(opcode!=86||!ENABLE_FIELD||field_ready);
 wire[63:0] query_id=id_found?id_word[122:59]:64'd0;
 wire[15:0] query_generation=id_found?id_word[58:43]:16'd0;
 wire query_found=id_found,commit_pan_found=id_found;
 always @(posedge clk)begin
  if(rst)begin id_wait<=0;id_prepared<=0;id_found<=0;id_slot<=0;id_word<=0;id_serial<=0;id_active_tag<=0;end
  else begin
   if(!identity_stable)id_prepared<=0;
   if(id_req_valid&&id_req_ready)begin id_wait<=1;id_active_tag<=id_serial;id_serial<=id_serial+16'd1;end
   if(id_response_valid&&id_wait&&id_response_tag==id_active_tag)begin
    id_wait<=0;id_prepared<=1;id_found<=id_response_found;id_slot<=id_response_slot;id_word<=id_response_word;
   end
   if(config_valid&&config_ready)id_prepared<=0;
   if(session_flush||config_payload_changed)begin id_wait<=0;id_prepared<=0;end
  end
 end
 wire accept=config_valid&&config_ready;
 assign field_valid=accept&&opcode==86&&ENABLE_FIELD;
 assign field_start=config_bytes[71:64]==1;
 assign field_size=config_bytes[79:72]==1?0:config_bytes[79:72]==8?1:config_bytes[79:72]==16?2:config_bytes[79:72]==32?3:config_bytes[79:72]==64?5:4;
 always @(posedge clk)begin fx_cfg_valid<=!rst&&accept&&opcode==35;fx_cfg_data<=config_bytes[415:64];end
 assign gain_cfg_valid=accept&&opcode==36;
 assign gain_local=config_bytes[79:64];assign gain_external=config_bytes[95:80];
 assign gain_local_mute=config_bytes[96];assign gain_external_mute=config_bytes[97];
 // Resolve identity once, then own the complete Pan request until the
 // Allocator accepts it. No ready -> command accept -> valid return path.
 assign pan_valid=!rst&&!session_flush&&pan_request_pending;
 assign pan_slot=held_pan_slot;assign pan_id=held_pan_id;
 assign pan_generation=held_pan_generation;assign pan_value=held_pan_value;
 always @(posedge clk)begin
  if(rst||session_flush)pan_request_pending<=0;
  else begin
   if(pan_valid&&pan_ready)pan_request_pending<=0;
   if(accept&&opcode==34)pan_request_pending<=commit_pan_found;
  end
 end
 s9_keymap_config u_map(.clk(clk),.rst(rst),.disconnect(session_flush),
  .cfg_valid(accept&&opcode==37),.cfg_notes(config_bytes[127:64]),.cfg_sequence(32'd0),.cfg_slot(config_slot),
  .local_gate(local_gate),.local_pending(local_pending),.active_notes(keymap),.version(keymap_version),
  .accepted(map_accepted),.rejected(map_rejected),.applied(map_applied),.applied_sequence(map_applied_sequence),.applied_slot(map_applied_slot),
  .cancelled(map_cancelled),.cancelled_sequence(map_cancelled_sequence),.cancelled_slot(map_cancelled_slot),.pending(map_pending));
 assign lookup_valid=0;assign lookup_channel=0;assign lookup_sequence=0;assign lookup_echo=0;
 assign result_sequence=result_fields[31:0];
 assign result_bytes={64'd0,result_fields,session_id,result_flags,8'd0,8'd0,8'd0,32'd0};
 // Round-robin choice is registered; issue re-checks the chosen entry.
 reg found_dirty;reg[2:0] search;integer n;
 always @*begin
  found_dirty=0;search=0;
  for(integer k=0;k<7;k=k+1)begin
   n=cursor+k;if(n>=7)n=n-7;
   if(valid[n]&&dirty[n]&&!found_dirty)begin found_dirty=1;search=n;end
  end
 end
 reg[2:0] selected;
 always @(posedge clk)selected<=search;
 wire issue_ready=valid[selected]&&dirty[selected];
 task prepare_result(input[2:0] which,input[2:0] p);
  begin
   result_valid<=1;result_index<=which;result_slot<=slot[which];result_fields<=0;result_flags<=0;
   result_fields[31:0]<=0;result_fields[39:32]<=1;result_fields[47:40]<=8'h80|{5'd0,p};
   result_fields[63:48]<={{11{error[which][4]}},error[which]};result_fields[95:64]<=frame[which];result_fields[127:96]<=version[which];
   if(p==4||p==5)result_flags<=1;
   if(which==6&&lookup_is_instance&&p==3)begin result_flags<=2;result_fields[191:128]<=reply_id;result_fields[207:192]<=reply_generation;end
   if(which==0&&hello_pending&&p==3)begin
    result_flags<=1;result_fields[159:128]<=hello_snapshot[31:0];
    result_fields[207:192]<=hello_snapshot[47:32];result_fields[223:208]<=hello_snapshot[63:48];
    result_fields[230:224]<=hello_snapshot[70:64];
   end
   if(which==0&&metrics_pending&&p==3)begin result_flags<=8;result_fields[255:128]<=metrics_snapshot;end
   result_final<=p>=6||(which==4?p==5:(p==4||((which==0&&!field_pending||which==6)&&p==3)));
  end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   valid<=0;dirty<=0;glide_code<=0;timbre_id<=0;previous_local_glide<=0;tick_d<=0;tick_frame<=0;pan_defer_snapshot<=0;
   metrics_pending<=0;metrics_snapshot<=0;hello_pending<=0;field_pending<=0;field_target_start<=0;hello_snapshot<=0;
   pan_watch_valid<=0;
   held_pan_id<=0;held_pan_generation<=0;held_pan_slot<=0;held_pan_value<=128;reply_id<=0;reply_generation<=0;
   target_l<=32768;target_e<=32768;
   result_valid<=0;result_final<=0;result_slot<=0;result_index<=0;
   cursor<=0;result_fields<=0;result_flags<=0;
   for(i=0;i<7;i=i+1)begin slot[i]<=0;phase[i]<=0;frame[i]<=0;version[i]<=0;error[i]<=0;end
  end else begin
   tick_d<=sample_tick;if(sample_tick)tick_frame<=sample_time;
   previous_local_glide<=local_glide_code;
   if(result_valid&&result_ready)begin
    result_valid<=0;
    if(result_final&&slot[result_index]==result_slot)begin valid[result_index]<=0;dirty[result_index]<=0;if(result_index==0)field_pending<=0;end
   end
   if(!result_valid&&issue_ready&&!replaceable)begin
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
   // COMMITTED is produced only by the actual Pan write response. Audio
   // ownership prevents a write on sample_tick; the next frame consumes it.
   if(valid[2]&&phase[2]==2&&pan_response_valid)begin
    dirty[2]<=1;
    if(pan_result==0)begin phase[2]<=3;pan_watch_valid<=1;end
    else begin phase[2]<=7;error[2]<=-11;pan_watch_valid<=0;end
   end
   if(valid[2]&&phase[2]==3&&sample_tick&&pan_watch_valid)begin
    phase[2]<=4;frame[2]<=sample_time;dirty[2]<=1;pan_watch_valid<=0;
   end
   // This compact lifetime watch replaces 32 full snapshot identities.
   // OFF/pressure preserve ownership; only allocation or reclaim ends it.
   if(valid[2]&&phase[2]==3&&fact_valid&&(fact_outcome==1||fact_outcome==10)&&fact_slot=={1'b0,held_pan_slot})begin
    phase[2]<=7;error[2]<=-11;dirty[2]<=1;pan_watch_valid<=0;
   end
   if(valid[3]&&phase[3]==3&&tick_d&&r54_equal_0)begin phase[3]<=4;frame[3]<=tick_frame;dirty[3]<=1;end
   if(valid[4]&&phase[4]>=3&&phase[4]<5&&gain_sample&&r54_equal_1)begin
    if(phase[4]==3)begin phase[4]<=4;frame[4]<=gain_frame;dirty[4]<=1;end
    if(gain_remaining==0&&gain_l==target_l&&gain_e==target_e)begin phase[4]<=5;frame[4]<=gain_frame;dirty[4]<=1;end
   end
   if(valid[5]&&phase[5]==3&&sample_tick&&!map_pending&&r54_equal_2)begin phase[5]<=4;frame[5]<=sample_time;dirty[5]<=1;end
   if(local_glide_code!=previous_local_glide&&local_glide_code<=11)begin
    glide_code<=local_glide_code;
    if(valid[1]&&phase[1]==3)begin phase[1]<=6;dirty[1]<=1;end
   end
   if(accept)begin
    if(replaceable)prepare_result(index,3'd6);
    valid[index]<=1;dirty[index]<=1;slot[index]<=config_slot;
    phase[index]<=3;error[index]<=0;frame[index]<=0;version[index]<=0;
    if(index==0)metrics_pending<=0;
    case(opcode)
     1:begin hello_pending<=1;phase[0]<=2;dirty[0]<=0;end
     86:begin hello_pending<=0;if(ENABLE_FIELD)begin field_pending<=1;field_target_start<=field_start;phase[0]<=2;dirty[0]<=0;end else begin phase[0]<=7;error[0]<=-2;end end
     41:begin metrics_pending<=1;metrics_snapshot<=ensemble_metrics;hello_pending<=0;field_pending<=0;frame[0]<=sample_time;end
     32:begin field_pending<=0;timbre_id<=config_bytes[66:64];hello_pending<=0;end
     33:begin
      if(local_glide_code!=previous_local_glide)begin phase[1]<=7;error[1]<=-10;end
      else glide_code<=config_bytes[67:64];
     end
     34:begin
      pan_watch_valid<=0;
      if(!commit_pan_found)begin phase[2]<=7;error[2]<=-11;end
      else begin phase[2]<=2;dirty[2]<=0;end
      held_pan_id<=query_id;held_pan_generation<=query_generation;held_pan_slot<=id_slot;held_pan_value<=config_bytes[160:152];
     end
     35:version[3]<=fx_accepted+1'b1;
     36:begin version[4]<=gain_accepted+1'b1;target_l<=gain_local_mute?0:gain_local;target_e<=gain_external_mute?0:gain_external;end
     37:version[5]<=keymap_version+1'b1;
     39:begin reply_id<=query_id;reply_generation<=query_generation;if(!query_found)begin phase[6]<=7;error[6]<=-11;end end
     // MCU consumes HELLO/KEEP/CLOSE and PLAY, never fabricates their FPGA ACK.
     default:begin phase[0]<=7;error[0]<=-10;end
    endcase
   end
   if(session_flush)begin pan_watch_valid<=0;field_pending<=0;valid<=0;dirty<=0;result_valid<=0;end
  end
 end
 // synthesis translate_off
 reg[1538:0] identity_command_reference;
 always @(posedge clk)if(!rst&&!session_flush)begin
  if(id_req_valid&&id_req_ready)identity_command_reference<={config_slot,config_bytes};
  if((id_wait||id_prepared)&&!config_payload_changed&&{config_slot,config_bytes}!==identity_command_reference)
   $fatal(1,"R18_CONFIG_QUERY_COMMAND_BINDING");
  if(id_response_valid&&id_wait&&id_response_tag!==id_active_tag)$fatal(1,"R18_CONFIG_QUERY_RESPONSE_TAG");
  if(valid[2]&&phase[2]==2&&pan_response_valid&&pan_result==0)
   if(pan_response_slot!==held_pan_slot || pan_response_before[122:59]!==held_pan_id ||
    pan_response_before[58:43]!==held_pan_generation || pan_response_after[12:4]!==held_pan_value)
     $fatal(1,"R18_CONFIG_PAN_RESPONSE_BINDING");
 end
 // synthesis translate_on
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if((^{session_flush,session_ready,config_valid,sample_tick,gain_sample,identity_stable,local_pending,result_ready,lookup_ready,lookup_done,local_glide_code})===1'bx)$fatal(1,"S9_CONFIG_CONTROL_XZ");
  if(config_valid&&(^({config_bytes,config_slot}))===1'bx)$fatal(1,"S9_CONFIG_INPUT_XZ");
  if(gain_sample&&(^({gain_frame,gain_frame_version,gain_l,gain_e,gain_remaining}))===1'bx)$fatal(1,"S9_CONFIG_GAIN_XZ");
 end
 // synthesis translate_on
 r54_full_equal #(.WIDTH(32)) r54_equal_0_tree(.a(fx_frame_version),.b(version[3]),.equal(r54_equal_0));
 r54_full_equal #(.WIDTH(32)) r54_equal_1_tree(.a(gain_frame_version),.b(version[4]),.equal(r54_equal_1));
 r54_full_equal #(.WIDTH(32)) r54_equal_2_tree(.a(keymap_version),.b(version[5]),.equal(r54_equal_2));
endmodule
