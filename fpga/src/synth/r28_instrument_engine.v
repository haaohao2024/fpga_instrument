module r28_instrument_engine #(parameter integer SAMPLE_RATE_HZ=48000,parameter integer LEASED_ITEM=0,NO_UNDO=0,INDEXED_INPUT=0,ID_WIDTH=64,PHONE_LOOKUP=0,CLK_FREQ_HZ=50_000_000,parameter integer SHARE_FX=0,LOOP_ENABLE=0,VOICES=48)(
 output wire [127:0] ensemble_metrics,
 input wire fx_mac_use,input wire signed[35:0] fx_mac_a,input wire signed[17:0] fx_mac_b,
 output wire signed[53:0] fx_mac_q,
 input wire loop_cleanup_valid,loop_cleanup_all,loop_abort_batch,input wire[1:0] loop_cleanup_sources,input wire[15:0] loop_cleanup_revision,
 output wire loop_cleanup_ready,loop_cleanup_done,
 input wire[2:0] event_loop_timbre,
 input wire hold_publication,output wire audible_publish,
 input wire[95:0] indexed_item,input wire[2:0] indexed_occupancy,output wire[3:0] indexed_item_index,
 input wire session_flush,session_ready,input wire[575:0] event_phone_presses,
 input wire lookup_valid,lookup_pan,input wire[7:0] lookup_key,
 input wire[63:0] lookup_identity,input wire[15:0] lookup_generation,lookup_tag,
 output wire lookup_ready,lookup_response_valid,lookup_found,
 output wire[5:0] lookup_response_slot,output wire[314:0] lookup_response_word,
 output wire[15:0] lookup_response_tag,
 input wire clk,rst,sample_tick,panic,test_linear,
 input wire event_valid,output wire event_ready,input wire[904:0] event_packet,
 input wire[2:0] timbre_id,input wire[3:0] glide_code,
 input wire[63:0] frame_id,input wire[15:0] subcycle,input wire[63:0] allocated_persistent_id,
 input wire snapshot_valid,snapshot_record_start,output wire snapshot_ready,
 input wire pan_valid,input wire[5:0] pan_slot,input wire[63:0] pan_id,
 input wire[15:0] pan_generation,input wire[8:0] pan_value,output wire pan_ready,
 output wire pan_response_valid,output wire[1:0] pan_result,
 output wire[5:0] pan_response_slot,output wire[314:0] pan_before,pan_after,
 output wire reclaim_batch_busy,
 input wire query_valid,query_snapshot,input wire[5:0] query_slot,output wire query_ready,
 output wire query_response_valid,output wire[5:0] query_response_slot,output wire[314:0] query_response_word,
 output wire mix_valid,output wire signed[31:0] mix_l_q8,mix_r_q8,
 output wire[815:0] envelope_levels,output wire[143:0] envelope_states,output wire[863:0] voice_samples,
 output wire protocol_error,deadline_error,output wire[2:0] queue_occupancy,
 output wire batch_begin,batch_publish,batch_abort,output wire[31:0] batch_timestamp,
 output wire fact_valid,output wire[3:0] fact_lane,output wire[95:0] fact_item,
 output wire[7:0] fact_outcome,output wire[5:0] fact_slot,output wire fact_steal,
 output wire[314:0] fact_before,fact_after,output wire[63:0] fact_frame,output wire[15:0] fact_subcycle,
 output wire identity_stable,output wire event_busy,audio_busy,
 output wire[63:0] control_valid,control_gate,
 output wire[1487:0] control_state,output wire[3:0] batch_source
);
 reg[2:0] delivery;reg[8:0] mask;reg[3:0] index,source_q;reg[31:0] stamp;
 reg started;reg[2:0] loop_timbre_q;reg[95:0] item_q;reg[5:0] query_slot_q;
 wire controller_ready,controller_busy,controller_error,batch_done,controller_abort,snapshot_done;
 // Ports above keep the 6-bit slot layout (control vectors are 64 wide);
 // with more voices the probe's wider slot fields are truncated here.
 localparam integer PSW=(VOICES==(1<<$clog2(VOICES)))?$clog2(VOICES)+1:$clog2(VOICES);
 wire[PSW-1:0] probe_fact_slot;
 assign fact_slot=probe_fact_slot[5:0];
 wire[4*VOICES-1:0] audio_flags;wire[7:0] audio_vibrato;
 wire[VOICES-1:0] audio_reclaim;wire audio_protocol;
 function[3:0] next_item(input[8:0] m,input[3:0] begin_at);
  begin next_item=9;for(integer i=8;i>=0;i--)if(i>=begin_at&&m[i])next_item=4'(i);end
 endfunction
 wire[3:0] following=next_item(mask,index+4'd1);
 assign event_ready=delivery==0&&controller_ready;
 assign indexed_item_index=index;
 assign batch_begin=delivery==3&&controller_ready&&!started;
 assign batch_publish=batch_done;
 assign batch_abort=controller_abort||(delivery!=0&&panic&&!started);
 assign batch_source=source_q;assign batch_timestamp=stamp;
 assign fact_lane=index;assign fact_frame=frame_id;assign fact_subcycle=subcycle;
 assign protocol_error=controller_error||audio_protocol;
 assign queue_occupancy=indexed_occupancy;
 assign identity_stable=snapshot_ready&&delivery==0;
 assign event_busy=controller_busy||delivery!=0;
 assign reclaim_batch_busy=fact_valid&&fact_outcome==10;
 assign query_response_slot=query_slot_q;
 for(genvar s=0;s<64;s++)begin
  if(s<VOICES)begin assign control_valid[s]=audio_flags[s*4+1];assign control_gate[s]=audio_flags[s*4+2];end
  else begin assign control_valid[s]=0;assign control_gate[s]=0;end
 end
 always @(posedge clk)begin
  if(rst)begin delivery<=0;mask<=0;index<=0;source_q<=0;stamp<=0;started<=0;loop_timbre_q<=0;item_q<=0;query_slot_q<=0;end
  else begin
   if(query_valid&&query_ready)query_slot_q<=query_slot;
   case(delivery)
    0:if(event_valid&&event_ready)begin mask<=event_packet[872:864];stamp<=event_packet[904:873];source_q<=event_packet[31:28];loop_timbre_q<=event_loop_timbre;index<=next_item(event_packet[872:864],0);delivery<=1;end
    1:delivery<=2;
    2:begin if(!LEASED_ITEM)item_q<=indexed_item;delivery<=3;end
    3:if(controller_ready)begin delivery<=4;started<=1;end
    4:if(fact_valid&&fact_outcome!=10)begin
     if(following==9)delivery<=5;else begin index<=following;delivery<=1;end
    end
    5:begin end
    default:delivery<=0;
   endcase
   if(batch_done||batch_abort)begin delivery<=0;started<=0;end
  end
 end
 // synthesis translate_off
 reg[95:0] leased_reference;
 always @(posedge clk)begin
  if(!rst&&delivery==2)leased_reference<=indexed_item;
  if(!rst&&LEASED_ITEM&&delivery==3&&controller_ready&&indexed_item!==leased_reference)
   $fatal(1,"R45_EVENT_LEASE_CHANGED");
  // No-slot (all ones) is only reported where consumers ignore the slot.
  if(!rst&&fact_valid&&probe_fact_slot=={PSW{1'b1}}&&fact_outcome!=4&&fact_outcome!=5&&fact_outcome!=6)
   $fatal(1,"R28_NO_SLOT_OUTCOME");
 end
 // synthesis translate_on
 r28_control_audio_probe #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),.ID_WIDTH(ID_WIDTH),.SHARE_FX(SHARE_FX),.LOOP_ENABLE(LOOP_ENABLE),.VOICES(VOICES)) core(.test_linear(test_linear),.ensemble_metrics(ensemble_metrics),.loop_cleanup_valid(loop_cleanup_valid),.loop_cleanup_sources(loop_cleanup_sources),.loop_cleanup_all(loop_cleanup_all),.loop_cleanup_revision(loop_cleanup_revision),.loop_cleanup_ready(loop_cleanup_ready),.loop_cleanup_done(loop_cleanup_done),.loop_abort_batch(loop_abort_batch),.fx_mac_use(fx_mac_use),.fx_mac_a(fx_mac_a),.fx_mac_b(fx_mac_b),.fx_mac_q(fx_mac_q),.clk(clk),.rst(rst),.frame_tick(sample_tick),.hold_publication(hold_publication),.panic(panic),
 .session_flush(PHONE_LOOKUP?session_flush:1'b0),.session_ready(PHONE_LOOKUP?session_ready:1'b1),.lookup_valid(PHONE_LOOKUP?lookup_valid:1'b0),.lookup_key(lookup_key),.lookup_identity(lookup_identity),
 .lookup_generation(lookup_generation),.lookup_tag(lookup_tag),.lookup_ready(lookup_ready),.lookup_response_valid(lookup_response_valid),
 .lookup_found(lookup_found),.lookup_response_slot(lookup_response_slot),.lookup_response_word(lookup_response_word),.lookup_response_tag(lookup_response_tag),
 .pan_valid(pan_valid),.pan_slot(pan_slot),.pan_id(pan_id),.pan_generation(pan_generation),.pan_value(pan_value),.pan_ready(pan_ready),
 .pan_response_valid(pan_response_valid),.pan_result(pan_result),.pan_response_slot(pan_response_slot),.pan_before(pan_before),.pan_after(pan_after),
 .audio_reclaim(audio_reclaim),.envelope_levels(envelope_levels),.glide_code(glide_code),.mix_valid(mix_valid),.mix_l_q8(mix_l_q8),.mix_r_q8(mix_r_q8),
 .audio_busy(audio_busy),.audio_protocol_error(audio_protocol),.audio_deadline_error(deadline_error),.voice_samples(voice_samples),.envelope_states(envelope_states),
 .event_valid(delivery==3),.event_ready(controller_ready),.event_item(LEASED_ITEM?indexed_item:item_q),.event_last(following==9),.timbre(LOOP_ENABLE&&source_q==3?loop_timbre_q:timbre_id),
 .fact_valid(fact_valid),.fact_item(fact_item),.fact_outcome(fact_outcome),.fact_slot(probe_fact_slot),.fact_steal(fact_steal),.fact_before(fact_before),.fact_after(fact_after),
 .batch_done(batch_done),.batch_abort(controller_abort),.published(audible_publish),.audio_flags(audio_flags),.audio_vibrato(audio_vibrato),.control_state(control_state),
 .busy(controller_busy),.protocol_error(controller_error),.snapshot_valid(snapshot_valid),.snapshot_ready(snapshot_ready),.snapshot_done(snapshot_done),
 .query_valid(query_valid),.query_ready(query_ready),.query_view(query_snapshot?2'd2:2'd0),.query_slot(query_slot),.query_response_valid(query_response_valid),.query_response(query_response_word),
 .accepted_events(),.max_event_cycles());
endmodule
