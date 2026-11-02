// VOICES <= 64: one engine with VOICES/8 Lanes. VOICES > 64: two engines of
// VOICES/16 Lanes each (an even Lane count is required); engine e owns slots
// e*EV..e*EV+EV-1 and the stereo mixes are added.
module r28_control_audio_probe #(parameter integer SAMPLE_RATE_HZ=48000,parameter integer ID_WIDTH=64,parameter integer SHARE_FX=0,LOOP_ENABLE=0,VOICES=48,
  SW=(VOICES==(1<<$clog2(VOICES)))?$clog2(VOICES)+1:$clog2(VOICES))(
 output wire [127:0] ensemble_metrics,
 input wire fx_mac_use,input wire signed[35:0] fx_mac_a,input wire signed[17:0] fx_mac_b,
 output wire signed[53:0] fx_mac_q,
 input wire loop_cleanup_valid,loop_cleanup_all,loop_abort_batch,input wire[1:0] loop_cleanup_sources,input wire[15:0] loop_cleanup_revision,
 output wire loop_cleanup_ready,loop_cleanup_done,
 input wire clk,rst,frame_tick,hold_publication,panic,test_linear,
 input wire session_flush,session_ready,
 input wire lookup_valid,input wire[7:0] lookup_key,input wire[63:0] lookup_identity,
 input wire[15:0] lookup_generation,lookup_tag,
 output wire lookup_ready,lookup_response_valid,lookup_found,
 output wire[SW-1:0] lookup_response_slot,output wire[314:0] lookup_response_word,
 output wire[15:0] lookup_response_tag,
 input wire pan_valid,input wire[SW-1:0] pan_slot,input wire[63:0] pan_id,
 input wire[15:0] pan_generation,input wire[8:0] pan_value,
 output wire pan_ready,pan_response_valid,output wire[1:0] pan_result,
 output wire[SW-1:0] pan_response_slot,output wire[314:0] pan_before,pan_after,
 output wire[VOICES-1:0] audio_reclaim,output wire[17*VOICES-1:0] envelope_levels,
 input wire[3:0] glide_code,output wire mix_valid,output wire signed[31:0] mix_l_q8,mix_r_q8,
 output wire audio_busy,audio_protocol_error,audio_deadline_error,
 output wire[18*VOICES-1:0] voice_samples,output wire[3*VOICES-1:0] envelope_states,
 input wire event_valid,output wire event_ready,input wire[95:0] event_item,
 input wire event_last,input wire[2:0] timbre,
 output wire fact_valid,output wire[95:0] fact_item,
 output wire[7:0] fact_outcome,output wire[SW-1:0] fact_slot,
 output wire fact_steal,output wire[314:0] fact_before,fact_after,
 output wire batch_done,batch_abort,published,

 output wire[4*VOICES-1:0] audio_flags,output wire[7:0] audio_vibrato,
 output wire[31*VOICES-1:0] control_state,
 output wire busy,output wire protocol_error,
 input wire snapshot_valid,output wire snapshot_ready,output wire snapshot_done,
 input wire query_valid,output wire query_ready,input wire[1:0] query_view,
 input wire[SW-1:0] query_slot,output wire query_response_valid,
 output wire[314:0] query_response,
 output wire[31:0] accepted_events,output wire[31:0] max_event_cycles
);
 localparam integer LANES=VOICES/8,ENGINES=VOICES>64?2:1,EL=LANES/ENGINES,EV=8*EL,ESW=(EL>8?7:6),
   EPW=37+4*(SAMPLE_RATE_HZ>=128000?15:SAMPLE_RATE_HZ>=72000?14:13);
 // Two engines: engine 1 runs the same schedule two clocks after engine 0.
 // Engine 0 uses the shared envelope in lane slot 0 and the shared timbre/LFO
 // unit in slot 2; engine 1 lands in slots 2 and 0, so neither collides.
 reg[1:0] start_delay;
 always @(posedge clk)start_delay<=rst?2'd0:{start_delay[0],frame_tick};
 wire[EPW+7:0] fe_envelope_request[0:1];wire[69:0] fe_timbre_request[0:1];wire[6:0] fe_release[0:1];
 wire[EPW-1:0] fe_envelope_response;wire[81:0] fe_timbre_response;
 // Engine 0 owns the pitch pROM; engine 1 reads it on engine 0's idle ages.
 wire pitch_issue[0:1];wire[6:0] pitch_note[0:1];wire[31:0] pitch_data[0:1];
 wire dir_we,dir_bank,dir_read_bank,dir_published;wire[SW-1:0] dir_slot;wire[26:0] dir_data;
 wire[9*LANES-1:0] mix_cp;
 wire audio_retire;
 wire[SW-1:0] level_read_slot;wire[16:0] level_read_value;
 // Controller level reads: slot -> (engine, slot within that engine).
 localparam[SW-1:0] ENGINE_SLOTS=EV;
 wire level_engine=ENGINES==2&&level_read_slot>=ENGINE_SLOTS;
 wire[SW-1:0] level_local_slot=level_engine?level_read_slot-ENGINE_SLOTS:level_read_slot;
 r28_serial_control #(.ID_WIDTH(ID_WIDTH),.LOOP_ENABLE(LOOP_ENABLE),.VOICES(VOICES)) controller(.*);
 wire[ENGINES-1:0] e_busy,e_mix_valid,e_retire,e_protocol,e_deadline;
 wire signed[31:0] e_mix_l[0:ENGINES-1],e_mix_r[0:ENGINES-1];
 wire[127:0] e_metrics[0:ENGINES-1];
 wire[16:0] e_level[0:ENGINES-1];
 // Shared stereo sum (two engines): engine e drives Lanes e*EL..e*EL+EL-1.
 wire[LANES-1:0] mix_cv,mix_ca;wire[3*LANES-1:0] mix_cs;wire[18*LANES-1:0] mix_cd;
 wire signed[31:0] shared_l,shared_r;wire shared_mix_valid,shared_protocol,shared_deadline;wire[8:0] shared_cycle;
 for(genvar e=0;e<ENGINES;e++)begin: engines
  r28_frame_audio #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),.SHARE_FX(SHARE_FX),.LANES(EL),.EXTERNAL_FRONTEND(ENGINES==2),
   .PITCH_ROM_ROLE(ENGINES==2?(e==0?1:2):0),.EXTERNAL_MIX(ENGINES==2),.PUBLISH_AGE(ENGINES==2&&e==0?307:305)) audio(
   .ext_mix_valid(shared_mix_valid),.ext_protocol_error(shared_protocol),.ext_deadline(shared_deadline),.ext_last_complete_cycle(shared_cycle),
   .fe_pitch_issue(pitch_issue[e]),.fe_pitch_note(pitch_note[e]),.fe_pitch_data(pitch_data[e]),
   .fe_alt_issue(ENGINES==2&&e==0?pitch_issue[ENGINES-1]:1'b0),.fe_alt_note(pitch_note[ENGINES-1]),.fe_pitch_data_in(pitch_data[0]),.ensemble_metrics(e_metrics[e]),
   .fx_mac_use(e==0?fx_mac_use:1'b0),.fx_mac_a(fx_mac_a),.fx_mac_b(fx_mac_b),.fx_mac_q(),
   .fe_envelope_request(fe_envelope_request[e]),.fe_timbre_request(fe_timbre_request[e]),.fe_release(fe_release[e]),
   .fe_envelope_response(fe_envelope_response),.fe_timbre_response(fe_timbre_response),
   .control_retire(e_retire[e]),.clk(clk),.rst(rst),.start(e==0?frame_tick:start_delay[1]),.test_linear(test_linear),.flags(audio_flags[e*4*EV+:4*EV]),
   .dir_we(dir_we&&(ENGINES==1||((dir_slot>=ENGINE_SLOTS)==(e==1)))),.dir_bank(dir_bank),.dir_read_bank(dir_read_bank),.dir_published(dir_published),
   .dir_slot(ESW'(ENGINES==2&&dir_slot>=ENGINE_SLOTS?dir_slot-ENGINE_SLOTS:dir_slot)),.dir_data(dir_data),.completion_pan(mix_cp[e*9*EL+:9*EL]),
   .vibrato_depth(audio_vibrato),.glide_code(glide_code),.busy(e_busy[e]),.mix_valid(e_mix_valid[e]),.mix_l_q8(e_mix_l[e]),.mix_r_q8(e_mix_r[e]),
   .level_read_slot(ESW'(level_local_slot)),.level_read_value(e_level[e]),
   .envelope_levels(envelope_levels[e*17*EV+:17*EV]),.envelope_states(envelope_states[e*3*EV+:3*EV]),
   .reclaim_pending(audio_reclaim[e*EV+:EV]),.voice_samples(voice_samples[e*18*EV+:18*EV]),
   .completion_valid(mix_cv[e*EL+:EL]),.completion_accept(mix_ca[e*EL+:EL]),.completion_slot(mix_cs[e*3*EL+:3*EL]),
   .completion_sample(mix_cd[e*18*EL+:18*EL]),.protocol_error(e_protocol[e]),
   .deadline_error(e_deadline[e]),.last_complete_cycle());
 end
 assign fx_mac_q=54'd0;
 assign level_read_value=e_level[level_engine];
 // Engines share one schedule, so retire and publish edges coincide.
 assign audio_retire=e_retire[0];
 if(ENGINES==2)begin: shared_frontends
  r28_shared_envelope_glide #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),.PREPARED_RELEASE(SAMPLE_RATE_HZ==128000)) frontend(
   .prepared_release_q(fe_release[0]),.prepared_release_alt(fe_release[1]),.clk(clk),.rst(rst),.start(frame_tick),.busy(e_busy[0]),
   .envelope_requests({fe_envelope_request[1],fe_envelope_request[1],fe_envelope_request[0],fe_envelope_request[0]}),
   .envelope_response(fe_envelope_response),.glide_requests(456'd0),.glide_response(),.advance_requests(500'd0),.advance_response());
  r28_shared_timbre_lfo #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)) timbre_prepare(.clk(clk),.rst(rst),.start(frame_tick),.busy(e_busy[0]),
   .requests({fe_timbre_request[0],fe_timbre_request[0],fe_timbre_request[1],fe_timbre_request[1]}),.response(fe_timbre_response));
 end else begin: own_frontends
  assign fe_envelope_response=0;assign fe_timbre_response=0;
 end
 // The last engine finishes two clocks later; earlier mixes are held until then.
 assign mix_valid=e_mix_valid[ENGINES-1];
 assign audio_busy=|e_busy;
 assign audio_protocol_error=|e_protocol;
 assign audio_deadline_error=|e_deadline;
 if(ENGINES==1)begin: single
  assign mix_l_q8=e_mix_l[0];assign mix_r_q8=e_mix_r[0];
  assign shared_mix_valid=0;assign shared_protocol=0;assign shared_deadline=0;assign shared_cycle=0;
  assign ensemble_metrics=e_metrics[0];
 end else begin: summed
  // Engine results never coincide (engine 1 is two clocks behind), so one
  // saturating sum over all Lanes collects both.
  osc_stereo_sum #(.LANES(LANES),.WIDE(1)) mixer(.clk(clk),.rst(rst),.sample_tick(frame_tick),.completion_valid(mix_cv),.completion_accept(mix_ca),
   .completion_slot(mix_cs),.completion_sample(mix_cd),.completion_pan(mix_cp),.mix_l_q8(shared_l),.mix_r_q8(shared_r),
   .mix_valid(shared_mix_valid),.protocol_error(shared_protocol),.deadline_error(shared_deadline),.last_complete_cycle(shared_cycle));
  assign mix_l_q8=shared_l;assign mix_r_q8=shared_r;
  // Count fields add across engines; flags OR; cycles and frame from engine 0.
  reg[7:0] allocated,gated,nonzero,peak,completed;reg[7:0] faults;
  always @*begin
   allocated=0;gated=0;nonzero=0;peak=0;completed=0;faults=0;
   for(integer e=0;e<ENGINES;e++)begin
    allocated=allocated+e_metrics[e][23:16];gated=gated+e_metrics[e][31:24];nonzero=nonzero+e_metrics[e][39:32];
    peak=peak+e_metrics[e][47:40];completed=completed+e_metrics[e][55:48];faults=faults|e_metrics[e][63:56];
   end
  end
  assign ensemble_metrics={e_metrics[0][127:64],faults,completed,peak,nonzero,gated,allocated,8'(VOICES),e_metrics[0][7:0]};
 end
endmodule
