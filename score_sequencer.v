// Source1 scheduler. No direct Voice access; completion is a read-only fence.
module score_sequencer # (parameter integer TOKEN_WIDTH=64)(
 input wire clk,rst,sample_tick,stereo_locked,
 input wire ctrl_valid,output wire ctrl_ready,input wire [7:0] ctrl_cmd,input wire [63:0] ctrl_epoch,ctrl_arg,
 input wire header_valid,eof_seen,input wire [63:0] last_verified_time,input wire [7:0] parser_error,
 output reg parser_clear,output wire parser_enable,
 input wire record_valid,output wire record_ready,input wire [127:0] record_data,
 input wire [8:0] visible_records,
 input wire local_backlog,
 output reg event_valid,input wire event_ready,output wire [904:0] event_packet,
 input wire dispatch_done,
 output reg [7:0] state,error_code,
 output reg [63:0] music_time,epoch,
 output reg [31:0] logical_held,output reg [223:0] logical_notes,output reg [255:0] logical_pressures,
 output reg [31:0] guide_held,output reg [223:0] guide_notes,
 output reg reload_request,output reg [31:0] records_consumed,events_offered,events_accepted,events_completed,
 output reg [31:0] deadline_count,token_exhaustions,stops,
 output reg [15:0] last_group_cycles,
 output wire observe_dispatch_active,
 output wire observe_teach,observe_loop
);
 localparam [63:0] TOKEN_MAX=(TOKEN_WIDTH==64)?64'hffffffffffffffff:((64'd1<<TOKEN_WIDTH)-1);
 reg [63:0] token_counter;
 reg [63:0] key_tokens[0:31] /* synthesis syn_ramstyle="distributed_ram" */;
 reg [31:0] tokens_initialized;
 reg [31:0] sound_held;
 reg teach,loop_mode,window_open,group_active,window_used,pause_requested,resume_pending,resuming,natural_end;
 assign observe_teach=teach;
 assign observe_loop=loop_mode;
 reg [1:0] stop_phase;reg [5:0] cleanup_key,resume_key;
 reg [7:0] stop_destination;
 reg [863:0] build_items;reg [3:0] build_count;
 // The builder and offered packet are mutually exclusive owners of these
 // nine words. All append/offer sites require !event_valid; a handshake
 // cannot append on its own edge. Retain the original offered header and
 // mask unused words to the original zero values for every valid packet.
 reg [40:0] offered_header;
 assign event_packet[904:864]=offered_header;
 generate for(genvar s=0;s<9;s=s+1)begin: offered_word
  assign event_packet[s*96+:96]=offered_header[s]?build_items[s*96+:96]:96'd0;
 end endgenerate

 // At the fixed 50 MHz / 48 kHz interface, the next sample edge is
 // at least1041 clocks away. Permit the banked event engine to use960
 // clocks, leaving at least81 clocks before that immutable sample edge.
 // The sample_tick unfinished-group guard below is retained unchanged.
 // This changes only the internal early-abort budget, not sample cadence.
 reg [15:0] frame_age;
 reg [31:0] system_sample;
 wire [31:0] outstanding=events_accepted-events_completed;
 wire [63:0] rec_time=record_data[63:0];
 wire [7:0] op=record_data[71:64],key=record_data[79:72],note=record_data[87:80],value=record_data[95:88];
 wire closed=record_data[96];
 // Reserve dispatch for the due same-time score group, including gaps while
 // its next packet is built. Already accepted phone packets still finish.
 // No reservation for future-time records or an idle music frame.
 assign observe_dispatch_active=!rst && state==2 && window_open &&
    (group_active || build_count!=0 || event_valid || outstanding!=0 ||
     (record_valid && rec_time==music_time));
 wire destructive_control=ctrl_valid&&ctrl_ready&&(ctrl_cmd==3||ctrl_cmd==6||ctrl_cmd==7);
 assign ctrl_ready=!rst;
 assign parser_enable=state==1||state==2||state==3;
 assign record_ready=!rst&&!sample_tick&&state==2&&window_open&&!resuming&&!event_valid&&
  outstanding<2&&!local_backlog&&rec_time==music_time&&!destructive_control&&!parser_error;
 wire [6:0] resume_notes[0:31];wire [7:0] resume_pressures[0:31];
 wire [63:0] next_token=token_counter+64'd1;
 generate for(genvar s=0;s<32;s=s+1)begin: resume_word
  assign resume_notes[s]=logical_notes[s*7+:7];assign resume_pressures[s]=logical_pressures[s*8+:8];
 end endgenerate
 reg [95:0] item;integer i;
 task begin_stop(input [7:0] destination,input [7:0] cause);
  begin state<=4;stop_phase<=0;cleanup_key<=0;stop_destination<=destination;window_open<=0;resuming<=0;
   if(cause!=0)error_code<=cause;stops<=stops+1;
  end
 endtask
 task offer_build;
  begin
   offered_header<={system_sample,((9'd1<<build_count)-1'b1)};
   event_valid<=1;events_offered<=events_offered+1;build_count<=0;
  end
 endtask
 // All five append sites use old state and are mutually exclusive:
 // normal record requires !resuming, resume requires resuming, cleanup state4.
 // Capture the original request in source order, then encode it once below.
 reg append_valid,append_flush;reg [95:0] append_data;
 reg [863:0] append_items;reg [3:0] append_count;
 // synthesis translate_off
 integer append_calls;
 // synthesis translate_on
 task append_item(input [95:0] x,input flush);
  begin
   append_valid=1;append_data=x;append_flush=flush;
   // synthesis translate_off
   append_calls=append_calls+1;
   // synthesis translate_on
  end
 endtask
 wire [4:0] token_read_slot=state==4?cleanup_key[4:0]:key[4:0];
 wire [63:0] selected_key_token=tokens_initialized[token_read_slot]?key_tokens[token_read_slot]:64'd0;
 // Normal records require !resuming through record_ready. A resume write
 // requires resuming, so these original write sites are mutually exclusive.
 // Keep stale full tokens until the original reset; clearing logical held
 // state must not clear token ownership or change later OFF/expression data.
 wire token_write_record=!rst&&state==2&&record_ready&&record_valid&&op==1&&!teach&&token_counter!=TOKEN_MAX;
 wire token_write_resume=!rst&&state==2&&resuming&&window_open&&!sample_tick&&!event_valid&&
  outstanding<2&&!local_backlog&&resume_key!=32&&logical_held[resume_key[4:0]]&&token_counter!=TOKEN_MAX;
 wire token_write=token_write_record||token_write_resume;
 wire [4:0] token_write_slot=token_write_resume?resume_key[4:0]:key[4:0];
 always @(posedge clk)begin
  if(rst)tokens_initialized<=0;
  else if(token_write)tokens_initialized[token_write_slot]<=1;
  if(token_write)key_tokens[token_write_slot]<=next_token;
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst&&token_write_record&&token_write_resume)$fatal(1,"SCORE_TOKEN_TWO_WRITERS");
 // synthesis translate_on
 always @(posedge clk)begin
  append_valid=0;append_flush=0;append_data=0;
  // synthesis translate_off
  append_calls=0;
  // synthesis translate_on
  parser_clear<=0;
  if(rst)begin
   state<=0;error_code<=0;music_time<=0;epoch<=0;logical_held<=0;sound_held<=0;logical_notes<=0;logical_pressures<=0;guide_held<=0;guide_notes<=0;
   teach<=0;loop_mode<=0;window_open<=0;group_active<=0;window_used<=0;pause_requested<=0;resume_pending<=0;resuming<=0;natural_end<=0;
   stop_phase<=0;cleanup_key<=0;resume_key<=0;stop_destination<=0;build_items<=0;build_count<=0;event_valid<=0;offered_header<=0;
   token_counter<=0;records_consumed<=0;events_offered<=0;events_accepted<=0;events_completed<=0;
   deadline_count<=0;token_exhaustions<=0;stops<=0;last_group_cycles<=0;frame_age<=0;system_sample<=0;parser_clear<=1;reload_request<=0;

  end else begin
   if(sample_tick)begin
    system_sample<=system_sample+1;frame_age<=0;window_open<=0;
    if(state==2)begin
     if(window_used&&(group_active||build_count!=0||event_valid||outstanding!=0))begin deadline_count<=deadline_count+1;begin_stop(0,8);end
     else music_time<=music_time+1;
    end
    window_used<=0;
   end else if(frame_age<65535)frame_age<=frame_age+1;
   if(event_valid&&event_ready)begin event_valid<=0;events_accepted<=events_accepted+1;end
   if(dispatch_done)events_completed<=events_completed+1;
   if(state==1&&header_valid&&(last_verified_time>=4800||eof_seen)&&stereo_locked)begin
    state<=2;music_time<=0;window_open<=1;window_used<=0;
   end
   if(state==2&&stereo_locked)begin window_open<=1;window_used<=0;end
   if(state==2&&window_open&&record_valid&&rec_time<music_time)begin deadline_count<=deadline_count+1;begin_stop(0,8);end
   if(state==2&&window_open&&!record_valid&&visible_records==0&&!eof_seen&&last_verified_time<music_time)begin deadline_count<=deadline_count+1;begin_stop(0,8);end
   if(state==2&&window_open&&frame_age>=960&&(group_active||event_valid||outstanding!=0)&&window_used)begin deadline_count<=deadline_count+1;begin_stop(0,8);end
   if(state==2&&record_ready&&record_valid)begin
    records_consumed<=records_consumed+1;window_used<=1;group_active<=!closed;
    if(closed)begin
     last_group_cycles<=frame_age;
     // LED sees a complete chord state, never an intermediate partial group.
     guide_held<=logical_held;guide_notes<=logical_notes;
     if(op==1)begin guide_held[key[4:0]]<=1;for(integer s=0;s<32;s=s+1)if(key==s)guide_notes[s*7+:7]<=note[6:0];end
     else if(op==2)guide_held[key[4:0]]<=0;
     else if(op==3)for(integer s=0;s<32;s=s+1)if(key==s)guide_notes[s*7+:7]<=note[6:0];
    end
    if(op==1)begin
     logical_held[key[4:0]]<=1;for(integer s=0;s<32;s=s+1)if(key==s)logical_notes[s*7+:7]<=note[6:0];for(integer s=0;s<32;s=s+1)if(key==s)logical_pressures[s*8+:8]<=value;
     if(!teach)begin
      if(token_counter==TOKEN_MAX)begin token_exhaustions<=token_exhaustions+1;begin_stop(0,9);end
      else begin token_counter<=next_token;sound_held[key[4:0]]<=1;
       append_item({next_token,4'd1,4'd1,key,note[6:0],value,1'b0},closed);
      end
     end
    end else if(op==2)begin
     logical_held[key[4:0]]<=0;
     if(!teach)begin sound_held[key[4:0]]<=0;append_item({selected_key_token,4'd1,4'd2,key,7'd0,8'd0,1'b0},closed);end
    end else if(op==3)begin
     for(integer s=0;s<32;s=s+1)if(key==s)logical_notes[s*7+:7]<=note[6:0];for(integer s=0;s<32;s=s+1)if(key==s)logical_pressures[s*8+:8]<=value;
     if(!teach)append_item({selected_key_token,4'd1,4'd3,key,note[6:0],value,1'b0},closed);
    end else if(op==4)begin
     natural_end<=1;begin_stop(0,0);
    end
    if(pause_requested&&closed&&op!=4)begin pause_requested<=0;begin_stop(3,0);end
   end
   if(state==4&&!event_valid)case(stop_phase)
    0:begin if(build_count!=0)offer_build();else begin stop_phase<=1;cleanup_key<=0;end end
    1:begin
     if(cleanup_key==32)begin if(build_count!=0)offer_build();else stop_phase<=2;end
     else if(sound_held[cleanup_key[4:0]])begin
      append_item({selected_key_token,4'd1,4'd2,{3'd0,cleanup_key[4:0]},7'd0,8'd0,1'b0},1'b0);
      sound_held[cleanup_key[4:0]]<=0;cleanup_key<=cleanup_key+1;
     end else cleanup_key<=cleanup_key+1;
    end
    2:if(outstanding==0&&build_count==0)begin
     state<=stop_destination;group_active<=0;pause_requested<=0;
     if(stop_destination==0)begin parser_clear<=1;logical_held<=0;guide_held<=0;reload_request<=natural_end&&loop_mode;end
     natural_end<=0;
    end
   endcase
   if(state==3&&resume_pending&&stereo_locked)begin
    state<=2;resuming<=!teach;resume_key<=0;resume_pending<=0;window_open<=1;window_used<=!teach;
   end
   if(state==2&&resuming&&window_open&&!sample_tick&&!event_valid&&outstanding<2&&!local_backlog)begin
    if(resume_key==32)begin
     if(build_count!=0)offer_build();else if(outstanding==0)resuming<=0;
    end else if(logical_held[resume_key[4:0]])begin
     if(token_counter==TOKEN_MAX)begin token_exhaustions<=token_exhaustions+1;begin_stop(0,9);end
     else begin token_counter<=next_token;sound_held[resume_key[4:0]]<=1;
      append_item({next_token,4'd1,4'd1,{3'd0,resume_key[4:0]},resume_notes[resume_key],resume_pressures[resume_key],1'b0},1'b0);
      resume_key<=resume_key+1;
     end
    end else resume_key<=resume_key+1;
   end
   if(parser_error!=0&&(state==1||state==2||state==3))begin_stop(0,parser_error+16);
   if(ctrl_valid&&ctrl_ready)case(ctrl_cmd)
    1:if(state==0&&ctrl_epoch!=0&&ctrl_epoch!=epoch&&ctrl_arg<4)begin
     state<=1;epoch<=ctrl_epoch;teach<=ctrl_arg[0];loop_mode<=ctrl_arg[1];music_time<=0;error_code<=0;
     logical_held<=0;sound_held<=0;guide_held<=0;guide_notes<=0;parser_clear<=1;reload_request<=0;natural_end<=0;resume_pending<=0;
    end
    3,6,7:if(state!=0&&state!=4)begin_stop(0,(ctrl_cmd==7)?7:0);
    4:if(state==2)begin
     // Resolve the boundary accepted ON THIS edge, not last edge's group flag.
     // END owns natural completion even if PAUSE arrives on the same edge.
     if(record_valid&&record_ready)begin
      if(op!=4)begin
       if(closed)begin pause_requested<=0;begin_stop(3,0);end
       else pause_requested<=1;
      end
     end else if(group_active)pause_requested<=1;
     else begin_stop(3,0);
    end
    5:if(state==3)resume_pending<=1;
   endcase
   if(append_valid)begin
    append_items=build_items;
    for(integer s=0;s<9;s=s+1)if(build_count==s)append_items[s*96+:96]=append_data;
    append_count=build_count+1;
    if(append_flush || append_count==9)begin
     offered_header<={system_sample,((9'd1<<append_count)-1'b1)};
     event_valid<=1;events_offered<=events_offered+1;build_count<=0;build_items<=append_items;
    end else begin build_items<=append_items;build_count<=append_count;end
   end
   // synthesis translate_off
   if(append_calls>1)$fatal(1,"SCORE_APPEND_MULTIPLE_REQUESTS");
   if(append_valid&&event_valid)$fatal(1,"SCORE_OFFERED_BANK_OVERWRITE");
   // synthesis translate_on
  end
 end
 // synthesis translate_off
 initial if(TOKEN_WIDTH<2||TOKEN_WIDTH>64)$fatal(1,"SCORE_TOKEN_WIDTH");
 // synthesis translate_on
endmodule
