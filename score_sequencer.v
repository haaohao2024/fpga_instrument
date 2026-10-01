// Source1 scheduler. No direct Voice access; completion is a read-only fence.
module score_sequencer # (parameter integer TOKEN_WIDTH=64)(
 input wire clk,rst,sample_tick,stereo_locked,
 input wire ctrl_valid,output wire ctrl_ready,input wire [7:0] ctrl_cmd,input wire [63:0] ctrl_epoch,ctrl_arg,
 input wire header_valid,eof_seen,input wire [63:0] last_verified_time,input wire [7:0] parser_error,
 output reg parser_clear,output wire parser_enable,
 input wire record_valid,output wire record_ready,input wire [127:0] record_data,
 input wire [8:0] visible_records,
 input wire local_backlog,
 output reg event_valid,input wire event_ready,output reg [904:0] event_packet,
 input wire dispatch_done,
 output reg [7:0] state,error_code,
 output reg [63:0] music_time,epoch,
 output reg [31:0] logical_held,output reg [223:0] logical_notes,output reg [255:0] logical_pressures,
 output reg [31:0] guide_held,output reg [223:0] guide_notes,
 output reg reload_request,output reg [31:0] records_consumed,events_offered,events_accepted,events_completed,
 output reg [31:0] deadline_count,token_exhaustions,stops,
 output reg [15:0] last_group_cycles
);
 localparam [63:0] TOKEN_MAX=(TOKEN_WIDTH==64)?64'hffffffffffffffff:((64'd1<<TOKEN_WIDTH)-1);
 reg [63:0] token_counter,key_tokens[0:31];reg [31:0] sound_held;
 reg teach,loop_mode,window_open,group_active,window_used,pause_requested,resume_pending,resuming,natural_end;
 reg [1:0] stop_phase;reg [5:0] cleanup_key,resume_key;
 reg [7:0] stop_destination;
 reg [863:0] build_items;reg [3:0] build_count;
 reg [15:0] frame_age;
 reg [31:0] system_sample;
 wire [31:0] outstanding=events_accepted-events_completed;
 wire [63:0] rec_time=record_data[63:0];
 wire [7:0] op=record_data[71:64],key=record_data[79:72],note=record_data[87:80],value=record_data[95:88];
 wire closed=record_data[96];
 wire destructive_control=ctrl_valid&&ctrl_ready&&(ctrl_cmd==3||ctrl_cmd==6||ctrl_cmd==7);
 assign ctrl_ready=!rst;
 assign parser_enable=state==1||state==2||state==3;
 assign record_ready=!rst&&!sample_tick&&state==2&&window_open&&!resuming&&!event_valid&&
  outstanding<2&&!local_backlog&&rec_time==music_time&&!destructive_control&&!parser_error;
 reg [95:0] item;integer i;
 task begin_stop(input [7:0] destination,input [7:0] cause);
  begin state<=4;stop_phase<=0;cleanup_key<=0;stop_destination<=destination;window_open<=0;resuming<=0;
   if(cause!=0)error_code<=cause;stops<=stops+1;
  end
 endtask
 task offer_build;
  begin
   event_packet<={system_sample,((9'd1<<build_count)-1'b1),build_items};
   event_valid<=1;events_offered<=events_offered+1;build_count<=0;build_items<=0;
  end
 endtask
 task append_item(input [95:0] x,input flush);
  reg [863:0] items;reg [3:0] count;
  begin
   items=build_items;items[build_count*96+:96]=x;count=build_count+1;
   if(flush||count==9)begin
    event_packet<={system_sample,((9'd1<<count)-1'b1),items};event_valid<=1;
    events_offered<=events_offered+1;build_count<=0;build_items<=0;
   end else begin build_items<=items;build_count<=count;end
  end
 endtask
 always @(posedge clk)begin
  parser_clear<=0;
  if(rst)begin
   state<=0;error_code<=0;music_time<=0;epoch<=0;logical_held<=0;sound_held<=0;logical_notes<=0;logical_pressures<=0;guide_held<=0;guide_notes<=0;
   teach<=0;loop_mode<=0;window_open<=0;group_active<=0;window_used<=0;pause_requested<=0;resume_pending<=0;resuming<=0;natural_end<=0;
   stop_phase<=0;cleanup_key<=0;resume_key<=0;stop_destination<=0;build_items<=0;build_count<=0;event_valid<=0;event_packet<=0;
   token_counter<=0;records_consumed<=0;events_offered<=0;events_accepted<=0;events_completed<=0;
   deadline_count<=0;token_exhaustions<=0;stops<=0;last_group_cycles<=0;frame_age<=0;system_sample<=0;parser_clear<=1;reload_request<=0;
   for(i=0;i<32;i=i+1)key_tokens[i]<=0;
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
   if(state==2&&window_open&&frame_age>=800&&(group_active||event_valid||outstanding!=0)&&window_used)begin deadline_count<=deadline_count+1;begin_stop(0,8);end
   if(state==2&&record_ready&&record_valid)begin
    records_consumed<=records_consumed+1;window_used<=1;group_active<=!closed;
    if(closed)begin
     last_group_cycles<=frame_age;
     // LED sees a complete chord state, never an intermediate partial group.
     guide_held<=logical_held;guide_notes<=logical_notes;
     if(op==1)begin guide_held[key[4:0]]<=1;guide_notes[key*7+:7]<=note[6:0];end
     else if(op==2)guide_held[key[4:0]]<=0;
     else if(op==3)guide_notes[key*7+:7]<=note[6:0];
    end
    if(op==1)begin
     logical_held[key[4:0]]<=1;logical_notes[key*7+:7]<=note[6:0];logical_pressures[key*8+:8]<=value;
     if(!teach)begin
      if(token_counter==TOKEN_MAX)begin token_exhaustions<=token_exhaustions+1;begin_stop(0,9);end
      else begin token_counter<=token_counter+1;key_tokens[key[4:0]]<=token_counter+1;sound_held[key[4:0]]<=1;
       append_item({token_counter+64'd1,4'd1,4'd1,key,note[6:0],value,1'b0},closed);
      end
     end
    end else if(op==2)begin
     logical_held[key[4:0]]<=0;
     if(!teach)begin sound_held[key[4:0]]<=0;append_item({key_tokens[key[4:0]],4'd1,4'd2,key,7'd0,8'd0,1'b0},closed);end
    end else if(op==3)begin
     logical_notes[key*7+:7]<=note[6:0];logical_pressures[key*8+:8]<=value;
     if(!teach)append_item({key_tokens[key[4:0]],4'd1,4'd3,key,note[6:0],value,1'b0},closed);
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
      append_item({key_tokens[cleanup_key[4:0]],4'd1,4'd2,{3'd0,cleanup_key[4:0]},7'd0,8'd0,1'b0},1'b0);
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
     else begin token_counter<=token_counter+1;key_tokens[resume_key[4:0]]<=token_counter+1;sound_held[resume_key[4:0]]<=1;
      append_item({token_counter+64'd1,4'd1,4'd1,{3'd0,resume_key[4:0]},logical_notes[resume_key*7+:7],logical_pressures[resume_key*8+:8],1'b0},1'b0);
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
  end
 end
 // synthesis translate_off
 initial if(TOKEN_WIDTH<2||TOKEN_WIDTH>64)$fatal(1,"SCORE_TOKEN_WIDTH");
 // synthesis translate_on
endmodule
