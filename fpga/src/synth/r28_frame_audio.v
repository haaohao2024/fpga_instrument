module r28_frame_audio #(parameter integer BACKENDS=1,parameter integer SHARE_FX=0, SAMPLE_RATE_HZ=48000, LANES=6, EXTERNAL_FRONTEND=0,PITCH_ROM_ROLE=0,EXTERNAL_MIX=0,PUBLISH_AGE=305,
  FE_EPW=37+4*(SAMPLE_RATE_HZ>=128000?15:SAMPLE_RATE_HZ>=72000?14:13))(
 // EXTERNAL_FRONTEND: envelope and timbre/LFO steps come from shared units outside.
 output wire[FE_EPW+7:0] fe_envelope_request,output wire[69:0] fe_timbre_request,output wire[6:0] fe_release,
 input wire[FE_EPW-1:0] fe_envelope_response,input wire[81:0] fe_timbre_response,
 output wire fe_pitch_issue,output wire[6:0] fe_pitch_note,output wire[31:0] fe_pitch_data,
 input wire fe_alt_issue,input wire[6:0] fe_alt_note,input wire[31:0] fe_pitch_data_in,
 output wire [127:0] ensemble_metrics,
 input wire fx_mac_use,input wire signed[35:0] fx_mac_a,input wire signed[17:0] fx_mac_b,
 output wire signed[53:0] fx_mac_q,
 input wire clk,rst,start,test_linear,
 input wire[4*8*LANES-1:0] flags,
 // Audio directory of this engine's slots, written by the controller.
 input wire dir_we,dir_bank,dir_read_bank,dir_published,input wire[(LANES>8?7:6)-1:0] dir_slot,input wire[26:0] dir_data,
 output wire[9*LANES-1:0] completion_pan,
 input wire[7:0] vibrato_depth,input wire[3:0] glide_code,
 input wire[(LANES>8?7:6)-1:0] level_read_slot,output wire[16:0] level_read_value,
 output reg busy,output wire mix_valid,output reg control_retire,
 output wire signed[31:0] mix_l_q8,mix_r_q8,
 output wire[17*8*LANES-1:0] envelope_levels,output wire[3*8*LANES-1:0] envelope_states,
 output reg[8*LANES-1:0] reclaim_pending,output reg[18*8*LANES-1:0] voice_samples,
 output reg[LANES-1:0] completion_valid,completion_accept,
 output reg[3*LANES-1:0] completion_slot,output reg[18*LANES-1:0] completion_sample,
 output wire protocol_error,output reg deadline_error,output wire[8:0] last_complete_cycle,
 // EXTERNAL_MIX: completions go to a stereo sum shared with the other engine.
 input wire ext_mix_valid,ext_protocol_error,ext_deadline,input wire[8:0] ext_last_complete_cycle
);
 localparam integer EW=(SAMPLE_RATE_HZ>=128000?15:SAMPLE_RATE_HZ>=72000?14:13),CW=240+4*EW,EPW=37+4*EW;
 // Slot = {Lane, index within Lane}. Each slot takes four issue cycles, so
 // the work window, prefetch end and per-group retire edges scale with LANES.
 localparam integer V=8*LANES,LW=(LANES>8?4:3),SW=LW+3,GROUP=4*LANES,
   ISSUE_END=4*V,WORK_END=4+4*V,RETIRE_AGE=4+9*GROUP+5;
 reg[8:0] age;
 reg[4*V-1:0] frame_flags;
 reg[11:0] expression_q;
 reg[V-1:0] initialized,visible_initialized;
 wire early_read=1'b0;
 wire early_commit=1'b0;
 wire[1:0] early_lane=age[1:0],commit_lane=age[1:0]-2'd2;
 wire[4:0] early_slot={early_lane,age[6:4]},commit_slot={commit_lane,age[6:4]};
 wire work_active=busy&&age>=4&&age<=WORK_END;
 wire[8:0] work_age=age-9'd4;
 wire[1:0] work_step=work_age[1:0];
 reg[SW-1:0] work_slot;
 always @(posedge clk)begin
  if(rst||start)work_slot<=0;
  else if(work_active&&work_step==0&&age<=ISSUE_END)
   work_slot<=work_slot[SW-1:3]==LANES-1 ? {{LW{1'b0}},3'(work_slot[2:0]+1'b1)} : work_slot+SW'(8);
 end
 wire[SW-1:0] read_slot=early_read?SW'(early_slot):work_slot;
 wire[LW-1:0] read_lane=read_slot[SW-1:3];
 // work_slot is reset by start, so the age-0 read is always slot 0.
 wire[3:0] read_flags=age==0?flags[3:0]:frame_flags[read_slot*4+:4];
 // Directory: control words of both banks. The word of read_slot is read
 // every clock and consumed at capture, three clocks after read_slot settles;
 // the controller writes only the bank audio is not reading.
 reg[26:0] directory[0:2*(1<<SW)-1] /* synthesis syn_ramstyle="block_ram" */;
 reg[26:0] directory_q;
 always @(posedge clk)begin
  if(dir_we)directory[{dir_bank,dir_slot}]<=dir_data;
  directory_q<=directory[{dir_read_bank,read_slot}];
 end
 wire[26:0] selected_control=dir_published?directory_q:27'd128;
 wire[30:0] read_control={selected_control,read_flags};
 reg[SW-1:0] captured_slot;
 reg captured_valid,captured_gate,captured_trigger,new_owner;
 reg[6:0] captured_note;reg[7:0] captured_pressure;reg[2:0] captured_timbre;
 // Pan of each launched job, in launch order; jobs complete in launch order.
 reg[8:0] captured_pan;reg[8:0] pan_queue[0:15];reg[3:0] pan_head,pan_tail;
 assign completion_pan={LANES{pan_queue[pan_head]}};
 reg[31:0] phase_q;reg[CW-1:0] state_q;
 wire[CW-1:0] state_read;
 reg[CW-1:0] captured_state;
 always @*begin
  captured_state=initialized[read_slot]?state_read:{CW{1'b0}};
  if(read_control[0]||!initialized[read_slot])captured_state[153+:EPW]={3'd0,17'd0,17'd0,EW'(0),EW'(1),EW'(0),EW'(0)};
 end
 wire[EPW+7:0] envelope_request;wire[EPW-1:0] envelope_response;
 wire[113:0] glide_request;wire[124:0] glide_response;
 wire[124:0] advance_request;wire[101:0] advance_response;
 wire[72:0] pressure_request;
 wire[16:0] pressure_gain_response;
 wire[69:0] timbre_request;wire[81:0] timbre_response;
  wire [31:0] old_lfo;
 wire [6:0] old_note,old_target;
 wire [7:0] old_pressure;
 wire [2:0] old_timbre,old_env_state;
 wire [16:0] old_level,old_quotient,old_glide_remaining,old_glide_base,old_glide_error;
 wire [EW-1:0] old_remaining,old_duration,old_remainder,old_error;
 wire [22:0] old_pitch;
 wire [15:0] old_glide_remainder;
 wire old_up;wire [3:0] old_code;
 wire [16:0] old_gain,old_transient,old_body;
 assign {old_lfo,old_note,old_pressure,old_timbre,old_env_state,old_level,old_quotient,
 old_remaining,old_duration,old_remainder,old_error,old_pitch,old_target,
 old_glide_remaining,old_glide_base,old_glide_remainder,old_glide_error,old_up,old_code,
 old_gain,old_transient,old_body}=state_q;
 wire [2:0] env_state_result;
 wire [16:0] env_level_result,env_quotient_result;
 wire [31:0] env_remaining_result,env_duration_result,env_remainder_result,env_error_result;
 // Field tests: plain sine, no vibrato, so each oscillator is a single bin.
 wire [2:0] timbre=test_linear?3'd0:new_owner?captured_timbre:old_timbre;
 assign envelope_request={timbre,captured_note[2:0],old_env_state,old_level,old_quotient,old_remaining,old_duration,old_remainder,old_error,captured_gate,captured_trigger};
 reg [EPW-1:0] env_q;
 wire [2:0] next_state;wire [16:0] next_level,next_quotient;
 wire [EW-1:0] next_remaining,next_duration,next_remainder,next_error;
 assign {next_state,next_level,next_quotient,next_remaining,next_duration,next_remainder,next_error}=env_q;
 // The private drum note is a key role, independent of octave/keymap.
 function [6:0] drum_note(input[2:0] role);
  case(role)
   0:drum_note=33; 1:drum_note=50; 2:drum_note=90; 3:drum_note=90;
   4:drum_note=43; 5:drum_note=50; 6:drum_note=74; 7:drum_note=86;
  endcase
 endfunction
 wire [6:0] effective_note=timbre==5?drum_note(captured_note[2:0]):
  next_state==4?(new_owner?7'd0:old_note):captured_note;
 wire [124:0] prepared;
 reg [124:0] prepared_q;
 assign glide_request={new_owner,effective_note,expression_q[3:0],old_pitch,old_target,old_glide_remaining,
   old_glide_base,old_glide_remainder,old_glide_error,old_up,old_code};
 assign prepared=glide_response;
 wire [22:0] next_pitch;wire [6:0] next_target;
 wire [16:0] next_glide_remaining,next_glide_base,next_glide_error;
 wire [15:0] next_glide_remainder;wire next_up;wire [3:0] next_code;
 assign advance_request=prepared_q;
 assign {next_pitch,next_target,next_glide_remaining,next_glide_base,next_glide_remainder,next_glide_error,next_up,next_code}=
  {effective_note,16'd0,effective_note,17'd0,17'd0,16'd0,17'd0,1'b1,4'd0};
 // Fixed preparation edges break target -> difference -> rounded step -> add.
 // Release holds the gain; a new instance takes its exact initial pressure.
 wire [7:0] effective_pressure=next_state==4?(new_owner?8'd0:old_pressure):captured_pressure;
 reg [16:0] pressure_target,pressure_difference,pressure_step;
 reg pressure_up;
 assign pressure_request={new_owner,next_state,pressure_up,pressure_target,old_gain,pressure_difference,pressure_step};
 // A drum hit latches velocity. Pressure updates never restart its one-shot.
 wire [16:0] next_gain=(timbre==5&&!new_owner)?old_gain:pressure_gain_response;
 wire[16:0] next_transient,next_body;wire[31:0] next_lfo;wire signed[15:0] lfo_sine;
 assign timbre_request={new_owner,timbre,old_transient,old_body,(new_owner?32'd0:old_lfo)};
 assign {next_lfo,lfo_sine,next_transient,next_body}=timbre_response;
 wire [16:0] depth=expression_q[11:4]==255?17'd65536:{1'b0,expression_q[11:4],expression_q[11:4]};
 wire [CW-1:0] state_next={next_lfo,
  7'((captured_trigger||captured_gate)?captured_note:(next_state==0?7'd0:old_note)),
  8'((captured_trigger||captured_gate)?captured_pressure:(next_state==0?8'd0:old_pressure)),
  timbre,next_state,next_level,next_quotient,next_remaining,next_duration,next_remainder,next_error,
  next_pitch,next_target,next_glide_remaining,next_glide_base,next_glide_remainder,next_glide_error,next_up,next_code,
  next_gain,next_transient,next_body};

 wire context_write=!rst&&work_active&&work_step==0&&age>=8&&captured_valid;
 // Each slot's context is three 108-bit words in three 36-bit-wide BSRAMs.
 // Word 0 holds bits 216..323 (it includes the envelope level, which the
 // release estimate needs two edges before capture); word 1 bits 0..107;
 // word 2 bits 108..215. Reads for the next slot issue on the three edges
 // before its capture edge; words 0 and 1 are held, word 2 is read directly.
 // A completed slot's new context is buffered and written on the following
 // three edges, so the read and write ports never address the same slot.
 wire context_read_issue=!rst&&!start&&busy&&age>=1&&age<=ISSUE_END-1&&age[1:0]!=0;
 wire[1:0] context_read_word=age[1:0]-2'd1;
 // Word 3 of each slot holds its oscillator phase. It is read on the capture
 // age (the read port's idle age) and loaded one clock later; a completed
 // phase waits in a one-entry buffer for the write port's idle age.
 wire phase_read_issue=!rst&&!start&&busy&&work_active&&work_step==0&&age<=ISSUE_END;
 reg phase_load_q,phase_init_q,phase_pending;reg[SW-1:0] phase_pending_slot;reg[31:0] phase_pending_value;
 reg[323:0] context_buffer;reg[SW-1:0] context_write_slot;reg[1:0] context_writes_left;
 wire context_write_issue=!rst&&context_writes_left!=0;
 wire phase_write_issue=!rst&&phase_pending&&!context_write_issue;
 wire[1:0] context_write_word=2'd3-context_writes_left;
 always @(posedge clk)begin
  if(rst||start)context_writes_left<=0;
  else if(context_write)begin
   context_buffer<={{(324-CW){1'b0}},state_next};context_write_slot<=captured_slot;context_writes_left<=3;
  end else if(context_writes_left!=0)context_writes_left<=context_writes_left-1'b1;
 end
 wire[107:0] context_di=context_write_word==0?context_buffer[216+:108]:
   context_write_word==1?context_buffer[0+:108]:context_buffer[108+:108];
 wire[107:0] context_do;
 for(genvar word=0;word<3;word++)begin: context_wide
  SDPX9B #(.BIT_WIDTH_0(36),.BIT_WIDTH_1(36),.READ_MODE(0),.RESET_MODE("SYNC")) memory(
   .CLKA(clk),.CLKB(clk),.CEA(context_write_issue||phase_write_issue),.CEB(context_read_issue||phase_read_issue),
   .ADA(phase_write_issue?{(7-SW)'(0),phase_pending_slot,2'd3,5'b01111}:{(7-SW)'(0),context_write_slot,context_write_word,5'b01111}),
   .ADB({(7-SW)'(0),work_slot,phase_read_issue?2'd3:context_read_word,5'b00000}),
   .DI(phase_write_issue?(word==0?{4'd0,phase_pending_value}:36'd0):context_di[word*36+:36]),.DO(context_do[word*36+:36]),
   .BLKSELA(3'd0),.BLKSELB(3'd0),.OCE(1'b1),.RESET(1'b0));
 end
 reg[107:0] context_word0,context_word1;
 always @(posedge clk)begin
  if(busy&&age[1:0]==2)context_word0<=context_do;
  if(busy&&age[1:0]==3)context_word1<=context_do;
 end
 wire[323:0] context_full={context_word0,context_do,context_word1};
 assign state_read=context_full[CW-1:0];
 // synthesis translate_off
 reg[SW-1:0] context_read_slot_q[0:2];
 always @(posedge clk)begin
  if(context_read_issue)context_read_slot_q[context_read_word]<=work_slot;
  if(!rst&&!start&&busy&&(work_active&&work_step==0&&age<=ISSUE_END))
   if(context_read_slot_q[0]!==read_slot||context_read_slot_q[1]!==read_slot||context_read_slot_q[2]!==read_slot)
    $fatal(1,"R45_CONTEXT_WRONG_PREFETCH");
  if(context_read_issue&&context_write_issue&&work_slot==context_write_slot&&context_read_word==context_write_word)
   $fatal(1,"R45_CONTEXT_READ_WRITE_COLLISION");
  if(context_write&&context_writes_left!=0)$fatal(1,"R45_CONTEXT_WRITE_OVERLAP");
 end
 // synthesis translate_on
 reg[EPW+7:0] observe_request;reg observe_valid;reg[1:0] observe_lane;
 reg[19:0] observe_result[0:3];
 wire main_envelope=work_active&&work_step==1;
 // This schedule has no observer jobs (early_read/early_commit are zero).
 // Its sole envelope consumer is work_step1. Do not gate combinational
 // arithmetic with busy/age; the existing consumer edge still gates capture.
 wire[EPW+7:0] selected_envelope=envelope_request;
 // Same private context and release code, prepared in existing idle slots.
 // Context read moved from capture-1 to capture-3; no extra RAM port.
 wire[16:0] prepare_level=(read_control[0]||!initialized[read_slot])?17'd0:context_do[153+4*EW+17-216+:17];
 wire[18:0] prepare_three={2'b0,prepare_level}+({2'b0,prepare_level}<<1);
 reg[6:0] release_high_q,release_estimate_q;
 wire[2:0] prepare_code=expression_q[3:0]>7?3'd7:expression_q[2:0];
 function[6:0] release_estimate(input[6:0] h,input[2:0] c);
  case(c)
   1:release_estimate=h;2:release_estimate=h>>1;3:release_estimate=h/7'd3;
   4:release_estimate=h>>2;5:release_estimate=h/7'd5;6:release_estimate=h/7'd6;
   7:release_estimate=h/7'd7;default:release_estimate=0;
  endcase
 endfunction
 always @(posedge clk)begin
  if(rst||start)begin release_high_q<=0;release_estimate_q<=0;end
  else if(busy)begin
   if(age>=2&&age<=ISSUE_END-2&&age[1:0]==2)release_high_q<={1'b0,prepare_three[18:13]};
   if(age>=3&&age<=ISSUE_END-1&&age[1:0]==3)release_estimate_q<=release_estimate(release_high_q,prepare_code);
  end
 end
 // synthesis translate_off
 wire[18:0] check_three={2'b0,old_level}+({2'b0,old_level}<<1);
 always @(posedge clk)if(!rst&&SAMPLE_RATE_HZ==128000&&main_envelope)
  if(release_estimate_q!==release_estimate({1'b0,check_three[18:13]},prepare_code))
   $fatal(1,"ENVELOPE_PREPARE_WRONG_CONTEXT");
 // synthesis translate_on

 assign fe_envelope_request=selected_envelope;assign fe_timbre_request=timbre_request;assign fe_release=release_estimate_q;
 if(EXTERNAL_FRONTEND!=0)begin: shared_frontend
  // Glide and advance results are not consumed: pitch changes are direct.
  assign envelope_response=fe_envelope_response;assign timbre_response=fe_timbre_response;
  assign glide_response=0;assign advance_response=0;
 end else begin: own_frontend
 r28_shared_envelope_glide #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),.PREPARED_RELEASE(SAMPLE_RATE_HZ==128000)) frontend(.prepared_release_q(release_estimate_q),.prepared_release_alt(release_estimate_q),.clk(clk),.rst(rst),.start(start),.busy(busy),
  .envelope_requests({4{selected_envelope}}),.envelope_response(envelope_response),
  .glide_requests({4{glide_request}}),.glide_response(glide_response),
  .advance_requests({4{advance_request}}),.advance_response(advance_response));
 r28_shared_timbre_lfo #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)) timbre_prepare(.clk(clk),.rst(rst),.start(start),.busy(busy),.requests({4{timbre_request}}),.response(timbre_response));
 end
 wire signed[17:0] pressure_delta=$signed({1'b0,pressure_request[67:51]})-$signed({1'b0,pressure_request[50:34]});
 wire[16:0] pressure_magnitude=pressure_delta[17]?-pressure_delta:pressure_delta;
 wire[17:0] pressure_difference_response={!pressure_delta[17]&&pressure_delta!=0,pressure_magnitude};
 wire[16:0] gain_target=pressure_request[67:51],gain_old=pressure_request[50:34],gain_difference=pressure_request[33:17],gain_step=pressure_request[16:0];
 wire[16:0] gain_adjusted=gain_old+(gain_step^{17{!pressure_request[68]}})+!pressure_request[68];
 assign pressure_gain_response=pressure_request[72]?gain_target:
  (pressure_request[71:69]==4||gain_target==gain_old)?gain_old:gain_step>=gain_difference?gain_target:gain_adjusted;
 reg[193:0] pending_job;reg[5:0] pending_tag;reg pending;
 wire[63:0] prepared_steps;wire[16:0] prepared_taper;
 // The existing transient state supplies a short pitch drop for tonal drums.
 wire[22:0] drum_sweep=captured_note[2:0]==0?{2'd0,next_transient,4'd0}:
  (captured_note[2:0]==4||captured_note[2:0]==5)?{4'd0,next_transient,2'd0}:23'd0;
 wire[22:0] backend_pitch=timbre==5?next_pitch+drum_sweep:next_pitch;
 // These 17 bits formerly carry FM taper; the drum path carries role+noise.
 wire[16:0] drum_payload={captured_note[2:0],lfo_sine[15:2]};
 osc_ii4_pitch_prepare #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),.ISSUE_END(ISSUE_END),.ROM_ROLE(PITCH_ROM_ROLE)) pitch_prepare(
  .alt_issue(fe_alt_issue),.alt_note(fe_alt_note),.rom_data_in(fe_pitch_data_in),
  .issue_out(fe_pitch_issue),.note_out(fe_pitch_note),.rom_data_out(fe_pitch_data),.clk(clk),.rst(rst),.start(start),.busy(busy),.test_linear(test_linear),.pitch(pending_job[160:138]),.steps(prepared_steps),.taper_out(prepared_taper));
 wire[BACKENDS-1:0] backend_ready,backend_valid;
 wire[BACKENDS*6-1:0] backend_tags;wire[BACKENDS*18-1:0] backend_samples;wire[BACKENDS*32-1:0] backend_phases;
 wire[1:0] selected_backend=BACKENDS==1?2'd0:BACKENDS==4?pending_tag[4:3]:{1'b0,pending_tag[3]};
 wire launch=pending&&backend_ready[selected_backend];
 for(genvar b=0;b<BACKENDS;b++)begin: engines
  osc_ii4_backend backend(.clk(clk),.rst(rst||start),
   .prepared_lo(prepared_steps[31:0]),.prepared_hi(prepared_steps[63:32]),.prepared_taper(prepared_taper),
   .in_valid(launch&&selected_backend==b),.in_ready(backend_ready[b]),.in_tag(pending_tag),.job_in(pending_job),
   .out_valid(backend_valid[b]),.out_tag(backend_tags[b*6+:6]),.out_sample(backend_samples[b*18+:18]),.out_phase(backend_phases[b*32+:32]));
 end
 assign fx_mac_q=54'd0;
 reg result_valid;reg[5:0] result_slot;
 wire[LW-1:0] result_lane=result_slot[SW-1:3];reg[31:0] result_phase;reg[17:0] result_sample;
 always @*begin
  result_valid=0;result_slot=0;result_phase=0;result_sample=0;
  for(integer b=0;b<BACKENDS;b++)if(backend_valid[b])begin
   result_valid=1;result_slot=backend_tags[b*6+:6];result_phase=backend_phases[b*32+:32];result_sample=backend_samples[b*18+:18];
  end
  completion_valid=0;completion_accept=0;completion_slot=0;completion_sample=0;
  if(result_valid)begin
   completion_valid[result_lane]=1;completion_accept[result_lane]=frame_flags[result_slot*4+1];
   completion_slot[result_lane*3+:3]=result_slot[2:0];completion_sample[result_lane*18+:18]=result_sample;
  end
 end
 always @(posedge clk)begin
  if(rst)begin phase_pending<=0;phase_load_q<=0;phase_init_q<=0;end
  else begin
   phase_load_q<=phase_read_issue;
   if(phase_read_issue)phase_init_q<=initialized[read_slot];
   if(result_valid&&frame_flags[result_slot*4+1])begin
    phase_pending<=1;phase_pending_slot<=SW'(result_slot);phase_pending_value<=result_phase;
   end else if(phase_write_issue)phase_pending<=0;
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst&&result_valid&&frame_flags[result_slot*4+1]&&phase_pending&&!phase_write_issue)
  $fatal(1,"PHASE_WRITE_BUFFER_OVERRUN");
 // synthesis translate_on
 // The whole-pool level/state buses have no consumer; levels are read
 // through level_read_value only.
 assign envelope_levels='0;
 assign envelope_states='0;
 wire mixer_deadline,computed_mix_valid;
 reg mix_prepared,published_mix_valid;
 assign mix_valid=published_mix_valid;
 always @(posedge clk)begin
  if(rst||start)begin mix_prepared<=0;published_mix_valid<=0;end
  else begin
   published_mix_valid<=0;
   if(computed_mix_valid)mix_prepared<=1;
   if(busy&&age==PUBLISH_AGE)begin published_mix_valid<=mix_prepared;mix_prepared<=0;end
  end
 end
 if(EXTERNAL_MIX!=0)begin: shared_mix
  assign mix_l_q8=0;assign mix_r_q8=0;assign computed_mix_valid=ext_mix_valid;
  assign protocol_error=ext_protocol_error;assign mixer_deadline=ext_deadline;assign last_complete_cycle=ext_last_complete_cycle;
 end else begin: own_mix
 osc_stereo_sum #(.LANES(LANES)) stereo(.clk(clk),.rst(rst),.sample_tick(start),.completion_valid(completion_valid),.completion_accept(completion_accept),
  .completion_slot(completion_slot),.completion_sample(completion_sample),.completion_pan(completion_pan),.mix_l_q8(mix_l_q8),.mix_r_q8(mix_r_q8),
  .mix_valid(computed_mix_valid),.protocol_error(protocol_error),.deadline_error(mixer_deadline),.last_complete_cycle(last_complete_cycle));
 end
 osc48_voice_metrics #(.CAPACITY(V)) monitor(.clk(clk),.rst(rst),.start(start),.done(mix_valid),
  .result_valid(result_valid),.result_accepted(frame_flags[result_slot*4+1]),
  .result_gate(frame_flags[result_slot*4+2]),.result_sample(result_sample),
  .complete_cycle(last_complete_cycle),.protocol_error(protocol_error),.deadline_error(deadline_error),.metrics(ensemble_metrics));
 // Group g (index g of every Lane) has retired GROUP*(g+2) cycles after issue start.
 reg original_completion;
 always @*begin original_completion=0;for(integer g=0;g<8;g++)if(busy&&age==4+GROUP*(g+2))original_completion=1;end
 reg[2:0] retire_group;
 // Per-slot envelope level and state live in distributed RAM: one write per
 // slot per frame, one random read for the controller's victim scan, and
 // one read per Lane bank for the retire-time reclaim check.
 reg[16:0] levels[0:V-1] /* synthesis syn_ramstyle="distributed_ram" */;
 wire level_we=!rst&&!start&&work_active&&work_step==1&&captured_valid;
 wire[19:0] level_write=envelope_response[EPW-1-:20];
 always @(posedge clk)if(level_we)levels[captured_slot]<=level_write[16:0];
 wire[2:0] lane_state[0:LANES-1];
 for(genvar l=0;l<LANES;l++)begin: state_banks
  reg[2:0] bank[0:7] /* synthesis syn_ramstyle="distributed_ram" */;
  always @(posedge clk)if(level_we&&captured_slot[SW-1:3]==l)bank[captured_slot[2:0]]<=level_write[19:17];
  assign lane_state[l]=bank[retire_group];
 end
 // synthesis translate_off
 reg[2:0] states_shadow[0:V-1];
 always @(posedge clk)if(level_we)states_shadow[captured_slot]<=level_write[19:17];
 // synthesis translate_on
 assign level_read_value=(visible_initialized[level_read_slot]&&flags[level_read_slot*4+1])?levels[level_read_slot]:17'd0;
 always @(posedge clk)if(rst||start)retire_group<=0;else if(original_completion)retire_group<=retire_group+1'b1;
 always @(posedge clk)begin
  if(rst)begin
   busy<=0;age<=0;frame_flags<=0;expression_q<=0;initialized<=0;visible_initialized<=0;
   captured_slot<=0;captured_valid<=0;captured_gate<=0;captured_trigger<=0;new_owner<=0;captured_note<=0;captured_pressure<=0;captured_timbre<=0;
   phase_q<=0;state_q<=0;env_q<=0;prepared_q<=0;pressure_target<=0;pressure_difference<=0;pressure_step<=0;pressure_up<=0;
   pending_job<=0;pending_tag<=0;pending<=0;observe_request<=0;observe_valid<=0;observe_lane<=0;
   reclaim_pending<=0;voice_samples<=0;control_retire<=0;deadline_error<=0;
   pan_head<=0;pan_tail<=0;captured_pan<=0;
  end else begin
   control_retire<=busy&&age==RETIRE_AGE;
   observe_valid<=early_read;
   if(start)begin
    if(busy)deadline_error<=1;
    busy<=1;age<=0;pending<=0;pan_head<=0;pan_tail<=0;observe_valid<=0;reclaim_pending<=0;control_retire<=0;expression_q<={vibrato_depth,glide_code};
   end else if(busy)begin
    age<=age+1'b1;
    if(phase_load_q)phase_q<=phase_init_q?context_do[31:0]:32'd0;
    if(age==0)frame_flags<=flags;
    if(early_read)begin observe_request<={read_control[30:28],read_control[15:13],captured_state[153+:EPW],read_control[2],read_control[3]&&read_control[1]};observe_lane<=early_lane;end
    if(observe_valid)observe_result[observe_lane]<=envelope_response[EPW-1-:20];
    if(original_completion)for(integer l=0;l<LANES;l++)begin
     if(frame_flags[(l*8+retire_group)*4+1]&&!frame_flags[(l*8+retire_group)*4+2]&&lane_state[l]==0)
      reclaim_pending[l*8+retire_group]<=1;
    end
    if(launch)pending<=0;
    if(work_active)case(work_step)
     0:begin
      if(age>=8)begin
      pending_job<={32'(new_owner?0:phase_q),captured_trigger,backend_pitch,lfo_sine,
       (timbre==5||test_linear?17'd0:depth),next_level,next_gain,next_transient,next_body,17'd0,
       (timbre==5?drum_payload:17'd0),timbre};
      pending_tag<=6'(captured_slot);pending<=1;pan_queue[pan_tail]<=captured_pan;pan_tail<=pan_tail+1'b1;if(captured_valid)initialized[captured_slot]<=1;
     end
      if(age<=ISSUE_END)begin
      captured_slot<=read_slot;captured_valid<=read_control[1];captured_gate<=read_control[2];captured_trigger<=read_control[3]&&read_control[1];
      new_owner<=read_control[0]||!initialized[read_slot];captured_note<=read_control[19:13];captured_pressure<=read_control[27:20];captured_timbre<=read_control[30:28];captured_pan<=read_control[12:4];
      state_q<=captured_state;
      end
     end
     1:begin
      env_q<=envelope_response;
      pressure_target<=envelope_response[EPW-1-:3]==4 ?
       (new_owner?8'd0:old_pressure)==255?17'd65536:{1'b0,(new_owner?8'd0:old_pressure),(new_owner?8'd0:old_pressure)}:
       captured_pressure==255?17'd65536:{1'b0,captured_pressure,captured_pressure};
      if(captured_valid)visible_initialized[captured_slot]<=1;
     end
     2:begin pressure_up<=pressure_difference_response[17];pressure_difference<=pressure_difference_response[16:0];end
     3:pressure_step<=pressure_difference==0?17'd1:(SAMPLE_RATE_HZ==128000 ? (({2'b0,pressure_difference}+({2'b0,pressure_difference}<<1)+19'd31)>>5) : SAMPLE_RATE_HZ==96000 ? ((pressure_difference+17'd7)>>3) : SAMPLE_RATE_HZ==72000 ? (pressure_difference+17'd5)/17'd6 : ((pressure_difference+17'd3)>>2));

     default:begin end
    endcase
    if(age>=399)deadline_error<=1;
   end
   if(result_valid&&frame_flags[result_slot*4+1])voice_samples[result_slot*18+:18]<=result_sample;
   if(result_valid)pan_head<=pan_head+1'b1;
   if(mix_valid)busy<=0;
   if(mixer_deadline)deadline_error<=1;
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(SHARE_FX!=0||BACKENDS!=1)$fatal(1,"II4_UNSUPPORTED_CONFIGURATION");
  if(busy&&age==PUBLISH_AGE&&!mix_prepared)$fatal(1,"II4_MISSED_FX_HANDOFF");
  if(start&&busy)$fatal(1,"R40_OVERLAPPING_FRAME");
  if(start&&pan_head!=pan_tail)$fatal(1,"PAN_QUEUE_NOT_DRAINED");
  if(work_active&&work_step==0&&age>=8&&pending&&!launch)$fatal(1,"R40_PENDING_OVERWRITE");
  if(observe_valid&&main_envelope)$fatal(1,"R40_ADSR_COLLISION");
  if(work_active&&work_step==1&&(old_glide_remaining!=0||old_glide_base!=0||old_glide_remainder!=0||old_glide_error!=0||old_code!=0))$fatal(1,"II4_DIRECT_PITCH_INVARIANT");
  if((backend_valid&(backend_valid-1'b1))!=0)$fatal(1,"R40_BACKEND_COLLISION");
  if(result_valid&&frame_flags[result_slot*4+1]&&states_shadow[result_slot]==0&&result_sample!=0)$fatal(1,"R40_RECLAIM_PROOF_BROKEN");
 end
 // synthesis translate_on
endmodule
