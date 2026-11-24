// Source1 scheduler. No direct Voice access; completion is a read-only fence.
module score_sequencer # (parameter integer RAW_ONLY=0,PARALLEL_PRESSURE_VIEW=1,SERIAL_CONTROL=0,SHARED_STORE=0,TOKEN_WIDTH=64, EARLY_DEADLINE=960)(
 input wire audio_published,
 input wire ctrl_raw,input wire [31:0] raw_frame,
 output reg raw_mode,output reg raw_fifo_clear,
 output reg [1:0] event_owner,output reg [2:0] event_timbre,
 output wire raw_cleanup_valid,input wire raw_cleanup_ready,raw_cleanup_done,
 output wire [1:0] raw_cleanup_sources,output wire raw_cleanup_all,output wire [15:0] raw_cleanup_revision,
 output wire [31:0] raw_last_audible,raw_completed_barrier,
 output reg raw_published_valid,output wire raw_barrier_busy,
 output reg event_write_valid,output reg[3:0] event_write_index,output reg[95:0] event_write_data,input wire event_write_ready,
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
 output reg [31:0] logical_held,output reg [223:0] logical_notes,output wire [255:0] logical_pressures,
 output reg [31:0] guide_held,output reg [223:0] guide_notes,
 output reg reload_request,output reg [31:0] records_consumed,events_offered,events_accepted,events_completed,
 output reg [31:0] deadline_count,token_exhaustions,stops,
 output reg [15:0] last_group_cycles,
 output wire observe_dispatch_active,
 output wire observe_teach,observe_loop
);
 wire r54_equal_0;
 wire r54_equal_1;

 localparam [63:0] TOKEN_MAX=(TOKEN_WIDTH==64)?64'hffffffffffffffff:((64'd1<<TOKEN_WIDTH)-1);
 reg wait_audible;
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
  assign event_packet[s*96+:96]=!SHARED_STORE&&offered_header[s]?build_items[s*96+:96]:96'd0;
 end endgenerate

 // Early-abort budget (EARLY_DEADLINE clocks after a sample edge) for the
 // banked event engine. Used only when SERIAL_CONTROL=0; the board build
 // sets SERIAL_CONTROL=1 and relies on the audible-publish handshake instead.
 reg [15:0] frame_age;
 reg [31:0] system_sample;
 wire [31:0] outstanding=events_accepted-events_completed;
 reg [31:0] raw_target;
 reg [3:0] raw_left;
 reg raw_last,raw_group_audio,raw_bank_seen;
 reg [1:0] raw_cleanup_phase;
 wire raw_head=raw_left==0;
 wire raw_barrier=raw_head&&record_data[110:107]==0;
 wire [31:0] raw_due_target=raw_head?record_data[31:0]:raw_target;
 wire [31:0] raw_delta=raw_due_target-raw_frame;
 // Classify a row on its own edge. A consumed row invalidates the
 // response before the next row can use it; frame changes also reclassify.
 reg raw_due_q,raw_due_valid;reg[31:0] raw_due_frame;
 wire raw_due=raw_due_valid&&raw_due_frame[0]==raw_frame[0]&&raw_due_q;
 always @(posedge clk)begin
  if(rst||!raw_mode||(state!=2&&state!=4))begin raw_due_q<=0;raw_due_valid<=0;raw_due_frame<=0;end
  else begin
   raw_due_q<=raw_delta==0||raw_delta[31];raw_due_frame<=raw_frame;
   raw_due_valid<=record_valid&&!(record_valid&&record_ready);
  end
 end
 // synthesis translate_off
 // Production raw_frame has one producer: the DAC-load counter/mux in
 // instrument_core. It holds or advances by one modulo2^32.
 // raw_due_frame is refreshed on every edge in both consuming states;
 // therefore its age at any valid response is at most one frame transition.
 reg frame_seen;reg[31:0] previous_raw_frame;
 always @(posedge clk)begin
  if(rst)begin frame_seen<=0;previous_raw_frame<=raw_frame;end
  else begin
   if(frame_seen&&raw_frame!=previous_raw_frame&&raw_frame!=previous_raw_frame+32'd1)
    $fatal(1,"RAW_FRAME_JUMP_OUTSIDE_PRODUCTION_CONTRACT");
   if(raw_due_valid&&raw_due_frame[0]==raw_frame[0]&&raw_due_frame!=raw_frame)
    $fatal(1,"RAW_DUE_FRAME_ALIAS");
   frame_seen<=1;previous_raw_frame<=raw_frame;
  end
 end
 // synthesis translate_on
 wire raw_drained=!event_valid&&!event_write_valid&&build_count==0&&outstanding==0&&!wait_audible;
 wire raw_close_end=state==4&&!record_valid&&visible_records==0&&raw_drained;
 wire raw_barrier_due=(state==2||state==4)&&record_valid&&raw_barrier&&raw_due&&raw_drained;
 assign raw_cleanup_sources=raw_close_end?2'b11:record_data[33:32];
 assign raw_cleanup_all=raw_close_end?1'b1:record_data[34];
 assign raw_cleanup_revision=raw_close_end?16'd0:record_data[50:35];
 assign raw_cleanup_valid=raw_mode&&raw_cleanup_phase==0&&
  (raw_close_end||(raw_barrier_due&&raw_cleanup_sources!=0));
 assign raw_barrier_busy=raw_mode&&(raw_cleanup_phase!=0||raw_barrier_due);
 // Reuse exclusive legacy diagnostic counters, without a second target/id bank.
 assign raw_last_audible=system_sample;
 assign raw_completed_barrier=stops;
 wire [63:0] rec_time=record_data[63:0];
 wire [7:0] op=raw_mode?{4'd0,record_data[27:24]}:record_data[71:64];
 wire [7:0] key=raw_mode?record_data[23:16]:record_data[79:72];
 wire [7:0] note=raw_mode?{1'b0,record_data[15:9]}:record_data[87:80];
 wire [7:0] value=raw_mode?record_data[8:1]:record_data[95:88];
 wire [7:0] pressure_read;
 wire pressure_write=!rst&&state==2&&record_ready&&record_valid&&(op==1||op==3)&&(!raw_mode||(!raw_head&&event_owner==1));
 generate if(PARALLEL_PRESSURE_VIEW)begin: observed_pressure
  reg [7:0] storage[0:31];reg [31:0] initialized;
  always @(posedge clk)begin
   if(rst)initialized<=0;else if(pressure_write)initialized[key[4:0]]<=1;
   if(pressure_write)storage[key[4:0]]<=value;
  end
  for(genvar k=0;k<32;k++)assign logical_pressures[k*8+:8]=initialized[k]?storage[k]:8'd0;
  assign pressure_read=storage[resume_key[4:0]];
 end else begin: indexed_pressure
  wire [7:0] bank_q[0:1];
  for(genvar b=0;b<2;b++)begin: banks
   for(genvar w=0;w<2;w++)begin: words
    RAM16SDP4 memory(.CLK(clk),.WRE(pressure_write&&key[4]==b),.WAD(key[3:0]),
      .RAD(resume_key[3:0]),.DI(value[w*4+:4]),.DO(bank_q[b][w*4+:4]));
   end
  end
  assign pressure_read=bank_q[resume_key[4]];
  assign logical_pressures=256'd0; // unconsumed parallel diagnostic port
 end endgenerate
 wire closed=record_data[96];
 // The two formats are exclusive producers of the same musical state.
 // Share the per-key decode and the current-item bypass into the guide.
 wire source1_accept=record_valid&&record_ready&&
  (raw_mode?(!raw_head&&event_owner==1):(state==2));
 wire source1_gate_write=source1_accept&&(op==1||op==2);
 wire source1_note_write=source1_accept&&(op==1||op==3);
 wire musical_target_close=record_valid&&record_ready&&closed&&(raw_mode?!raw_head:state==2);
 wire [31:0] source1_note_select;
 generate for(genvar g=0;g<32;g=g+1)begin: musical_key_decode
  assign source1_note_select[g]=source1_note_write&&key==g;
 end endgenerate
 // One regular carry chain serves exclusive legacy+1 and raw epoch+1.
 wire [63:0] music_step=music_time+(raw_mode?64'h0000000100000000:64'd1);
 wire raw_clock_wrap=!raw_frame[31]&&music_time[31];
 // Reserve dispatch for the due same-time score group, including gaps while
 // its next packet is built. Already accepted phone packets still finish.
 // No reservation for future-time records or an idle music frame.
 assign observe_dispatch_active=!rst && (raw_mode ?
   ((state==2||state==4)&&(group_active||build_count!=0||event_valid||outstanding!=0||
    (state==2&&record_valid&&!raw_barrier&&(!raw_due_valid||raw_due_frame[0]!=raw_frame[0]||raw_due)&&!wait_audible))) : (SERIAL_CONTROL ?
    ((state==2 && (resuming || group_active || build_count!=0 || event_valid || outstanding!=0 ||
       (record_valid && rec_time<=music_time&&!wait_audible))) ||
     (state==4 && (stop_phase!=2 || build_count!=0 || event_valid || outstanding!=0))) :
    (state==2 && window_open && (group_active || build_count!=0 || event_valid || outstanding!=0 ||
      (record_valid && r54_equal_0)))));
 wire append_ready=!SHARED_STORE||!event_write_valid;
 wire destructive_control=ctrl_valid&&ctrl_ready&&(ctrl_cmd==3||ctrl_cmd==6||ctrl_cmd==7);
 assign ctrl_ready=!rst;
 assign parser_enable=raw_mode?state==2:(state==1||state==2||state==3);
 assign record_ready=raw_mode?
   (!rst&&!sample_tick&&(state==2||state==4)&&append_ready&&!event_valid&&outstanding<2&&
    !local_backlog&&!wait_audible&&raw_due&&
    (!raw_barrier||((raw_cleanup_sources==0||raw_cleanup_phase==2)&&raw_drained))) :
   (append_ready&&!rst&&!sample_tick&&state==2&&window_open&&!resuming&&!event_valid&&
  outstanding<2&&!local_backlog&&(!SERIAL_CONTROL||!wait_audible)&&(SERIAL_CONTROL?rec_time<=music_time:r54_equal_0)&&!destructive_control&&!parser_error);
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
 wire token_write_record=!raw_mode&&!rst&&state==2&&record_ready&&record_valid&&op==1&&!teach&&token_counter!=TOKEN_MAX;
 wire token_write_resume=!raw_mode&&append_ready&&!rst&&state==2&&resuming&&window_open&&!sample_tick&&!event_valid&&
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
  if(event_write_valid&&event_write_ready)event_write_valid<=0;
  parser_clear<=0;raw_fifo_clear<=0;
  if(rst)begin
   raw_mode<=RAW_ONLY;raw_fifo_clear<=1;raw_target<=0;raw_left<=0;raw_last<=0;
   raw_group_audio<=0;raw_bank_seen<=0;raw_cleanup_phase<=0;raw_published_valid<=0;
   event_owner<=1;event_timbre<=0;
   wait_audible<=0;event_write_valid<=0;event_write_index<=0;event_write_data<=0;
   state<=0;error_code<=0;music_time<=0;epoch<=0;logical_held<=0;sound_held<=0;logical_notes<=0;guide_held<=0;guide_notes<=0;
   teach<=0;loop_mode<=0;window_open<=0;group_active<=0;window_used<=0;pause_requested<=0;resume_pending<=0;resuming<=0;natural_end<=0;
   stop_phase<=0;cleanup_key<=0;resume_key<=0;stop_destination<=0;build_items<=0;build_count<=0;event_valid<=0;offered_header<=0;
   token_counter<=0;records_consumed<=0;events_offered<=0;events_accepted<=0;events_completed<=0;
   deadline_count<=0;token_exhaustions<=0;stops<=0;last_group_cycles<=0;frame_age<=0;system_sample<=0;parser_clear<=1;reload_request<=0;

  end else begin
   if(sample_tick&&(!raw_mode||(wait_audible&&raw_bank_seen)))
    system_sample<=raw_mode?raw_target:system_sample+1'b1;
   if(source1_gate_write)logical_held[key[4:0]]<=op==1;
   if(musical_target_close)begin
    guide_held<=logical_held;
    if(source1_gate_write)guide_held[key[4:0]]<=op==1;
   end
   for(integer k=0;k<32;k=k+1)begin
    if(source1_note_select[k])logical_notes[k*7+:7]<=note[6:0];
    if(musical_target_close)guide_notes[k*7+:7]<=source1_note_select[k]?note[6:0]:logical_notes[k*7+:7];
   end
   if(raw_mode)begin
    // A bank swap is before mix/DAC load. Retire only on a later sample edge.
    if(wait_audible&&audio_published)raw_bank_seen<=1;
    if(wait_audible&&raw_bank_seen&&sample_tick)begin
     wait_audible<=0;raw_bank_seen<=0;raw_published_valid<=1;
    end
    music_time[31:0]<=raw_frame;
    if(raw_clock_wrap)music_time[63:32]<=music_step[63:32];
   end else begin
    if(SERIAL_CONTROL&&audio_published)wait_audible<=0;
    if(state!=2)wait_audible<=0;
   end
   if(sample_tick)begin
    frame_age<=0;window_open<=0;
    if(!raw_mode&&state==2)begin
     if(!SERIAL_CONTROL&&window_used&&(group_active||build_count!=0||event_valid||outstanding!=0))begin deadline_count<=deadline_count+1;begin_stop(0,8);end
     else music_time<=music_step;
    end
    window_used<=0;
   end else if(frame_age<65535)frame_age<=frame_age+1;
   if(event_valid&&event_ready)begin event_valid<=0;events_accepted<=events_accepted+1;end
   if(dispatch_done)events_completed<=events_completed+1;
   if(raw_mode)begin
    window_open<=stereo_locked;
    if(raw_cleanup_valid&&raw_cleanup_ready)raw_cleanup_phase<=1;
    if(raw_cleanup_phase==1&&raw_cleanup_done)begin
     if(state==4&&!record_valid)begin
      state<=0;raw_fifo_clear<=1;parser_clear<=1;raw_left<=0;group_active<=0;
      guide_held<=0;logical_held<=0;raw_cleanup_phase<=0;
     end else raw_cleanup_phase<=2;
    end
    if(record_valid&&record_ready)begin
     records_consumed<=records_consumed+1;
     if(raw_head)begin
      if(raw_barrier)begin
       stops<=record_data[95:64];raw_cleanup_phase<=0;
       if(record_data[51])begin guide_held<=0;logical_held<=0;end
      end else begin
       raw_target<=record_data[31:0];raw_left<=record_data[110:107];raw_last<=record_data[101];
       event_owner<=record_data[103:102];event_timbre<=record_data[106:104];teach<=record_data[100];
       group_active<=1;
      end
     end else begin
      raw_left<=raw_left-1'b1;
      if(!teach)begin append_item(record_data[95:0],raw_left==1);raw_group_audio<=1;end
      if(closed)begin
       group_active<=0;raw_group_audio<=0;
       if(raw_group_audio||!teach)begin wait_audible<=1;raw_bank_seen<=0;end

      end
     end
    end
    if(parser_error!=0&&state==2)begin
     if(error_code==0)error_code<=parser_error;
     state<=4;parser_clear<=1;
    end
    // Lateness is bounded in the actual S11 frame domain. A previously
    // admitted same-target row is allowed to finish before graceful close.
    if(state==2&&record_valid&&raw_head&&raw_due&&raw_delta<32'hffffffd0&&
       raw_delta[31]&&!group_active&&!wait_audible)begin
     if(error_code==0)error_code<=5;state<=4;parser_clear<=1;deadline_count<=deadline_count+1;
    end
   end else begin
   if(state==1&&header_valid&&(last_verified_time>=4800||eof_seen)&&stereo_locked)begin
    state<=2;music_time<=0;window_open<=1;window_used<=0;
   end
   if(state==2&&stereo_locked)begin window_open<=1;window_used<=0;end
   if(!SERIAL_CONTROL&&state==2&&window_open&&record_valid&&rec_time<music_time)begin deadline_count<=deadline_count+1;begin_stop(0,8);end
   if(state==2&&window_open&&!record_valid&&visible_records==0&&!eof_seen&&last_verified_time<music_time)begin deadline_count<=deadline_count+1;begin_stop(0,8);end
   if(!SERIAL_CONTROL&&state==2&&window_open&&frame_age>=EARLY_DEADLINE&&(group_active||event_valid||outstanding!=0)&&window_used)begin deadline_count<=deadline_count+1;begin_stop(0,8);end
   if(state==2&&record_ready&&record_valid)begin
    records_consumed<=records_consumed+1;window_used<=1;group_active<=!closed;
    if(closed)begin
     if(SERIAL_CONTROL&&!teach&&op!=4)wait_audible<=1;
     last_group_cycles<=frame_age;
    end
    if(op==1)begin
     if(!teach)begin
      if(token_counter==TOKEN_MAX)begin token_exhaustions<=token_exhaustions+1;begin_stop(0,9);end
      else begin token_counter<=next_token;sound_held[key[4:0]]<=1;
       append_item({next_token,4'd1,4'd1,key,note[6:0],value,1'b0},closed);
      end
     end
    end else if(op==2)begin
     if(!teach)begin sound_held[key[4:0]]<=0;append_item({selected_key_token,4'd1,4'd2,key,7'd0,8'd0,1'b0},closed);end
    end else if(op==3)begin
     if(!teach)append_item({selected_key_token,4'd1,4'd3,key,note[6:0],value,1'b0},closed);
    end else if(op==4)begin
     natural_end<=1;begin_stop(0,0);
    end
    if(pause_requested&&closed&&op!=4)begin pause_requested<=0;begin_stop(3,0);end
   end
   if(state==4&&!event_valid&&append_ready)case(stop_phase)
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
   if(state==2&&resuming&&append_ready&&window_open&&!sample_tick&&!event_valid&&outstanding<2&&!local_backlog)begin
    if(resume_key==32)begin
     if(build_count!=0)offer_build();else if(outstanding==0)begin resuming<=0;if(SERIAL_CONTROL&&logical_held!=0)wait_audible<=1;end
    end else if(logical_held[resume_key[4:0]])begin
     if(token_counter==TOKEN_MAX)begin token_exhaustions<=token_exhaustions+1;begin_stop(0,9);end
     else begin token_counter<=next_token;sound_held[resume_key[4:0]]<=1;
      append_item({next_token,4'd1,4'd1,{3'd0,resume_key[4:0]},resume_notes[resume_key],pressure_read,1'b0},1'b0);
      resume_key<=resume_key+1;
     end
    end else resume_key<=resume_key+1;
   end
   if(parser_error!=0&&(state==1||state==2||state==3))begin_stop(0,parser_error+16);
   end
   if(ctrl_valid&&ctrl_ready&&ctrl_cmd==1&&state==0&&ctrl_epoch!=0&&!r54_equal_1&&(!RAW_ONLY||ctrl_raw)&&
      ((ctrl_raw&&ctrl_arg==0)||(!ctrl_raw&&ctrl_arg<4)))begin
    raw_mode<=RAW_ONLY||ctrl_raw;epoch<=ctrl_epoch;error_code<=0;parser_clear<=1;raw_fifo_clear<=1;
    logical_held<=0;sound_held<=0;guide_held<=0;guide_notes<=0;
    group_active<=0;build_count<=0;event_valid<=0;event_write_valid<=0;wait_audible<=0;
    raw_left<=0;raw_last<=0;raw_group_audio<=0;raw_bank_seen<=0;raw_cleanup_phase<=0;
    raw_published_valid<=0;event_owner<=1;event_timbre<=0;
    if(RAW_ONLY||ctrl_raw)begin
     state<=2;teach<=0;loop_mode<=0;music_time<={32'd0,raw_frame};system_sample<=0;stops<=0;
    end else begin
     state<=1;teach<=ctrl_arg[0];loop_mode<=ctrl_arg[1];music_time<=0;
     reload_request<=0;natural_end<=0;resume_pending<=0;
    end
   end else if(raw_mode)begin
    if(ctrl_valid&&ctrl_ready&&(ctrl_cmd==3||ctrl_cmd==7)&&state!=0)begin
     state<=4;parser_clear<=1;
     if(ctrl_cmd==7&&error_code==0)error_code<=6;
    end
   end else if(ctrl_valid&&ctrl_ready)case(ctrl_cmd)
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
    if(SHARED_STORE)begin
     event_write_valid<=1;event_write_index<=build_count;event_write_data<=append_data;
    end else begin
     append_items=build_items;
     for(integer s=0;s<9;s=s+1)if(build_count==s)append_items[s*96+:96]=append_data;
    end
    append_count=build_count+1;
    if(append_flush || append_count==9)begin
     offered_header<={raw_mode?raw_target:system_sample,((9'd1<<append_count)-1'b1)};
     event_valid<=1;events_offered<=events_offered+1;build_count<=0;if(!SHARED_STORE)build_items<=append_items;
    end else begin if(!SHARED_STORE)build_items<=append_items;build_count<=append_count;end
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
 wide_equal #(.WIDTH(64)) r54_equal_0_tree(.a(rec_time),.b(music_time),.equal(r54_equal_0));
 wide_equal #(.WIDTH(64)) r54_equal_1_tree(.a(ctrl_epoch),.b(epoch),.equal(r54_equal_1));
endmodule
