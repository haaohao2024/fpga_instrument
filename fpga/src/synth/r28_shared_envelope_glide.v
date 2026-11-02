// Each 16-clock group prepares lane L at offsets L..L+6. All four
// backends still launch together at16. Only combinational operators are shared.
module r28_shared_envelope_glide #(parameter integer SAMPLE_RATE_HZ=48000, PREPARED_RELEASE=0, EW=(SAMPLE_RATE_HZ>=128000?15:SAMPLE_RATE_HZ>=72000?14:13),EPW=37+4*EW)(
 // Release estimate for lanes 0/1 and for lanes 2/3 (a second engine two clocks later).
 input wire[6:0] prepared_release_q,prepared_release_alt,
 input wire[499:0] advance_requests,output wire[101:0] advance_response,
 input wire clk,rst,start,busy,input wire[4*(EPW+8)-1:0] envelope_requests,input wire[455:0] glide_requests,
 output wire[EPW-1:0] envelope_response,output wire[124:0] glide_response
);
 reg[3:0] step;
 always @(posedge clk)if(rst||start)step<=0;else if(busy)step<=step+1'b1;
 wire[1:0] envelope_lane=step[1:0]-2'd1,glide_lane=step[1:0]-2'd2;
 wire[EPW+7:0] e=envelope_requests[envelope_lane*(EPW+8)+:EPW+8];
 wire[2:0] envelope_timbre=e[EPW+7:EPW+5],drum_role=e[EPW+4:EPW+2];
 wire[113:0] g=glide_requests[glide_lane*114+:114];
 wire[2:0] state;wire[16:0] level,quotient;wire[EW-1:0] remaining,duration,remainder,error_acc;wire gate,retrigger;
 assign {state,level,quotient,remaining,duration,remainder,error_acc,gate,retrigger}=e[EPW+1:0];
 wire new_owner,up;wire[6:0] note,target;wire[3:0] code,stored_code;wire[22:0] pitch;
 wire[2:0] state_next;wire[16:0] level_next,quotient_next;
 wire[31:0] remaining_next,duration_next,remainder_next,error_next;
 voice_release_adsr_step #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),.PREPARED_RELEASE(PREPARED_RELEASE)) adsr(.prepared_release_q(envelope_lane[1]?prepared_release_alt:prepared_release_q),.release_code(code),.state(state),.level(level),.quotient(quotient),.remaining({{(32-EW){1'b0}},remaining}),.duration({{(32-EW){1'b0}},duration}),
  .remainder({{(32-EW){1'b0}},remainder}),.error_acc({{(32-EW){1'b0}},error_acc}),.gate(gate),.retrigger(retrigger),
  .state_next(state_next),.level_next(level_next),.quotient_next(quotient_next),.remaining_next(remaining_next),
  .duration_next(duration_next),.remainder_next(remainder_next),.error_next(error_next));
 wire[2:0] drum_state;wire[16:0] drum_level;
 voice_drum_envelope_step #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)) drum_envelope(.role(drum_role),.state(state),.level(level),.retrigger(retrigger),
  .state_next(drum_state),.level_next(drum_level));
 assign envelope_response=envelope_timbre==5?
  {drum_state,drum_level,17'd0,EW'(0),EW'(1),EW'(0),EW'(0)}:
  {state_next,level_next,quotient_next,remaining_next[EW-1:0],duration_next[EW-1:0],remainder_next[EW-1:0],error_next[EW-1:0]};
 // code is now release time; pitch changes are direct, with continuous phase.

 wire[16:0] rem,base,err;wire[15:0] fraction;
 assign {new_owner,note,code,pitch,target,rem,base,fraction,err,up,stored_code}=g;
 glide_pitch_prepare glide(.new_owner(new_owner),.note_target(note),.glide_code(4'd0),.current_pitch(pitch),.stored_target(target),
  .remaining(rem),.base_step(base),.remainder(fraction),.error_acc(err),.direction_up(up),.stored_code(stored_code),.prepared(glide_response));
 wire[1:0] advance_lane=step[1:0]-2'd3;
 r28_glide_pipeline advance(.clk(clk),.rst(rst),.prepared(advance_requests[advance_lane*125+:125]),.result(advance_response));

endmodule
