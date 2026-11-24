// Transaction state and audio state are different owners.
// Full external identities are retained; only the control computation is shared.
// VOICES slots in LANES=VOICES/8 Lanes. SIW indexes a slot; SW is the
// external slot field, one bit wider when VOICES is a power of two so the
// all-ones "no slot" value never names a real slot.
module voice_allocator #(parameter integer ID_WIDTH=64,LOOP_ENABLE=0,VOICES=48,
  SIW=$clog2(VOICES),SW=(VOICES==(1<<$clog2(VOICES)))?$clog2(VOICES)+1:$clog2(VOICES),LANES=VOICES/8)(
 input wire loop_cleanup_valid,loop_cleanup_all,loop_abort_batch,input wire[1:0] loop_cleanup_sources,input wire[15:0] loop_cleanup_revision,
 output wire loop_cleanup_ready,output reg loop_cleanup_done,
 input wire clk,rst,frame_tick,audio_retire,hold_publication,panic,
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
 input wire[VOICES-1:0] audio_reclaim,
 output wire[SW-1:0] level_read_slot,input wire[16:0] level_read_value,
 input wire event_valid,output wire event_ready,input wire[95:0] event_item,
 input wire event_last,input wire[2:0] timbre,
 output reg fact_valid,output wire[95:0] fact_item,
 output reg[7:0] fact_outcome,output reg[SW-1:0] fact_slot,
 output reg fact_steal,output wire[314:0] fact_before,fact_after,
 output reg batch_done,batch_abort,published,
 // Audio directory write port; each engine keeps the directory of its slots.
 output wire dir_we,dir_bank,dir_read_bank,dir_published,output wire[SW-1:0] dir_slot,output wire[26:0] dir_data,
 output wire[4*VOICES-1:0] audio_flags,output reg[7:0] audio_vibrato,
 output wire[31*VOICES-1:0] control_state,
 output wire busy,output reg protocol_error,
 input wire snapshot_valid,output wire snapshot_ready,output reg snapshot_done,
 input wire query_valid,output wire query_ready,input wire[1:0] query_view,
 input wire[SW-1:0] query_slot,output reg query_response_valid,
 output wire[314:0] query_response,
 output reg[31:0] accepted_events,output reg[31:0] max_event_cycles
);
 wire r54_equal_0;

 localparam[63:0] ID_MAX=64'hffffffffffffffff>>(64-ID_WIDTH);
 localparam[7:0] IDLE=0,SCAN_WORK=1,SCAN_AUDIO=2,SELECT=3,BEFORE=4,
   APPLY=5,FINISH=6,COPY_READ=7,COPY_GOT=8,COPY_NEXT=9,
   QUERY_GOT=10,RECLAIM_AUDIO=11,RECLAIM_WORK=12,RECLAIM_DONE=13,
   PREP_READ=14,PREP_GOT=15,RECLAIM_WRITTEN=16,
   LOOKUP_GOT=17,LOOKUP_REPLY=18,PAN_GOT=19,PAN_APPLY=20,PAN_REPLY=21,
   RANK_UPDATE=22,ID_LOW=23,ID_HIGH=24,SELECT_DONE=25,INIT=26,READ_WORDS=250,WRITE_WORDS=251;
 localparam[7:0] LOOP_READ=40,LOOP_GOT=41,LOOP_APPLY=42,LOOP_NEXT=43;
 reg[SW-1:0] loop_scan;reg loop_all;reg[1:0] loop_sources;reg[15:0] loop_revision;
 reg loop_cleanup_pending,loop_wait_output;
 reg[7:0] state,return_state;
 localparam integer AW=2+SIW+3;
 // Banks 0/1 (work/audio) and 2 (frozen snapshot); bank 3 is never addressed.
 // Six words per row: control, metadata, two identity words, two token words.
 localparam integer ROW_WORDS=6,BANK_WORDS=ROW_WORDS*(1<<SIW);
 // Work/audio banks and the frozen bank are separate arrays so each maps to
 // the widest BSRAM shape its depth allows.
 localparam[AW-1:0] FROZEN_BASE=2*BANK_WORDS;
 reg[31:0] live_memory[0:2*BANK_WORDS-1] /* synthesis syn_ramstyle="block_ram" */;
 reg[31:0] frozen_memory[0:BANK_WORDS-1] /* synthesis syn_ramstyle="block_ram" */;
 reg[2:0] init_word;
 reg[AW-1:0] read_address,write_base;
 reg[31:0] live_q,frozen_q;reg frozen_read;
 wire[31:0] memory_q=frozen_read?frozen_q:live_q;
 // Stream each aligned word. Only valid reply/fact operands are
 // assembled; scans and bank copies never instantiate a whole-row shifter.
 reg[186:0] record_q;
 wire[155:0] old_metadata=record_q[186:31];
 wire[30:0] old_control=record_q[30:0];
 assign query_response={128'd0,record_q};
 reg[30:0] control_q;
 // R78: read the original key only for the private audio directory.
 // Full allocator facts, snapshots and observed pitch keep the original note.
 reg[2:0] prepared_key;
 reg[SW-1:0] read_slot_q;reg[1:0] read_bank_q,write_mode;
 reg[2:0] read_cycle,write_cycle,write_last;
 reg meta_equal,id_equal,token_equal,id_carry;
 reg[15:0] next_generation;
 wire copying=state==READ_WORDS&&return_state==COPY_GOT&&read_cycle!=0;
 wire memory_write=!rst&&(state==WRITE_WORDS||copying||state==INIT);
 reg[31:0] memory_write_data;
 reg[3:0] audible[0:VOICES-1];
 reg[4*VOICES-1:0] prepared_flags;reg prepared_valid;reg[SW-1:0] prepare_slot;
 reg[SW-1:0] rank[0:VOICES-1] /* synthesis syn_ramstyle="distributed_ram" */;
 reg[SW-1:0] rank_cursor,selected_rank;
 // After reset, INIT writes every row with the empty-slot value (control
 // 2048, other words 0) and rank[s]=s. Reads then need no per-slot
 // row-valid masks; only the audio directory waits for its first publish.
 reg audio_published;
 reg work_bank,audio_bank,dirty,in_batch,copy_snapshot,panic_pending,panic_urgent,publish_due;
 reg[VOICES-1:0] allocated_since_publish;
 reg[VOICES-1:0] phone_owned;reg session_live,lookup_cancelled;
 reg[7:0] lookup_key_q;reg[63:0] control_id;reg[15:0] control_generation,control_tag;
 reg[8:0] control_pan;reg lookup_found_q;reg[1:0] pan_status;
 reg[SW-1:0] copy_slot,scan_slot,selected_slot,query_slot_q;
 reg[1:0] query_view_q;
 reg[7:0] working_vibrato;
 reg[VOICES-1:0] pending_reclaim;
 // The reclaim set, its emptiness and its lowest member are registered from
 // the same next value, so admission and slot selection read flip-flops
 // instead of a VOICES-input reduction and priority encoder.
 reg reclaim_any;reg[SW-1:0] reclaim_first;
 wire[VOICES-1:0] reclaim_clear=(!rst&&state==RECLAIM_WRITTEN)?VOICES'(1)<<selected_slot:VOICES'(0);
 wire[VOICES-1:0] reclaim_next=rst?VOICES'(0):((pending_reclaim|(audio_retire?audio_reclaim:VOICES'(0)))&~reclaim_clear);
 reg[SW-1:0] reclaim_lowest;
 always @*begin reclaim_lowest=0;for(integer s=VOICES-1;s>=0;s--)if(reclaim_next[s])reclaim_lowest=SW'(s);end
 always @(posedge clk)begin pending_reclaim<=reclaim_next;reclaim_any<=reclaim_next!=0;reclaim_first<=reclaim_lowest;end
 reg[95:0] item_q;
 reg last_q;reg[2:0] timbre_q;
 reg[63:0] id_cursor;
 reg collision_mode,collision_hit,retry_scan;
 reg[63:0] search_id;reg[6:0] identity_retries;
 // Victim order is (class, level, rank); the scan is ascending and the
 // comparison strict, so equal keys keep the lowest slot without comparing it.
 localparam integer KW=2+17+SW;
 reg[KW-1:0] best;
 reg[SW-1:0] victim,target;
 reg found;

 reg[63:0] chosen_id,following_id;
 reg[31:0] event_age;
 // R45: item_q remains owned until the valid fact is consumed.
 // Reclaim has no input event. Invalid-cycle residue is not consumed.
 assign fact_item=fact_outcome==10?96'd0:item_q;
 wire[3:0] kind=item_q[27:24];
 wire invalid_item=item_q[0]||kind<1||kind>4||
  (kind==4&&(item_q[23:16]!=255||item_q[15:9]!=0))||
  (kind!=4&&item_q[95:32]==0);
 wire stale=(kind==1&&found)||((kind==2||kind==3)&&!found);
 wire collision_scan=kind==1&&collision_mode;
 wire[30:0] scan_control=work_control(control_q);
 wire[SW-1:0] rank_read_slot=state==RANK_UPDATE?rank_cursor:read_slot_q;
 wire[SW-1:0] rank_read=rank[rank_read_slot];
 wire rank_we=!rst&&state==RANK_UPDATE;
 wire[SW-1:0] rank_next=rank_cursor==selected_slot?SW'(VOICES-1):rank_read>selected_rank?rank_read-1'b1:rank_read;
 always @(posedge clk)begin
  if(rank_we)rank[rank_cursor]<=rank_next;
  else if(!rst&&state==INIT&&write_base<VOICES)rank[SW'(write_base)]<=SW'(write_base);
 end
 wire[KW-1:0] candidate={(!scan_control[1]?2'd0:(!scan_control[2]?2'd1:2'd2)),
   (!scan_control[1]||scan_control[2]||scan_control[0])?17'd0:level_read_value,
   scan_control[1]?rank_read:SW'(0)};
 // Victim choice reads the current envelope level of the scanned slot
 // through the engine's read port instead of a whole-pool snapshot.
 assign level_read_slot=read_slot_q;
 wire matching=scan_control[1]&&scan_control[2]&&meta_equal&&token_equal;
 // One pair of 32-bit operands serves streaming equality, victim ordering,
 // generation increment and both halves of identity increment.
 reg[31:0] alu_a,alu_b;reg alu_sub;
 always @*begin
  alu_a=0;alu_b=0;alu_sub=0;
  if(state==READ_WORDS)begin
   alu_a=memory_q;
   case(read_cycle)
    2:begin
     if(return_state==LOOKUP_GOT)begin alu_a=memory_q&32'h0fffff00;alu_b={4'd0,control_generation,4'd2,8'd0};end
     else if(return_state==PAN_GOT)begin alu_a=memory_q&32'h0ffff000;alu_b={4'd0,control_generation,12'd0};end
     else if(return_state==RECLAIM_DONE)begin alu_a=memory_q&32'h0ffff000;alu_b={4'd0,old_metadata[27:12],12'd0};end
     else begin alu_a={20'd0,memory_q[11:0]};alu_b={20'd0,item_q[31:28],item_q[23:16]};end
    end
    3:alu_b=return_state==RECLAIM_DONE?record_q[90:59]:return_state==PAN_GOT?control_id[31:0]:search_id[31:0];
    4:alu_b=return_state==RECLAIM_DONE?record_q[122:91]:return_state==PAN_GOT?control_id[63:32]:search_id[63:32];
    5:alu_b=return_state==LOOKUP_GOT?control_id[31:0]:item_q[63:32];
    6:alu_b=return_state==LOOKUP_GOT?control_id[63:32]:item_q[95:64];
    default:begin end
   endcase
  end else if(state==SCAN_WORK)begin alu_a=32'(candidate);alu_b=32'(best);alu_sub=1;end
  else if(state==ID_LOW)begin alu_a=search_id[31:0];alu_b=1;end
  else if(state==ID_HIGH)begin alu_a=search_id[63:32];alu_b={31'd0,id_carry};end
  else if(state==BEFORE)begin alu_a={16'd0,old_metadata[27:12]};alu_b=1;end
 end
 wire[32:0] alu_sum={1'b0,alu_a}+{1'b0,alu_b^{32{alu_sub}}}+alu_sub;
 wire alu_equal=r54_equal_0;
 wire candidate_less=!alu_sum[32];
 wire capture_record=return_state==BEFORE||return_state==QUERY_GOT||return_state==LOOKUP_GOT||return_state==PAN_GOT||return_state==RECLAIM_WORK||return_state==LOOP_GOT;
 wire[31:0] record_data=memory_q;
 wire[30:0] record_control=read_bank_q==2?memory_q[30:0]:
   read_bank_q[0]==work_bank?work_control(memory_q[30:0]):{memory_q[30:4],audible[read_slot_q]};
 reg[30:0] new_control;reg[155:0] new_metadata;
 // Fact consumers sample only while fact_valid. These operands already stay
 // registered through that edge; a second pair of wide result registers is redundant.
 assign fact_before=fact_outcome==10?{128'd0,old_metadata,old_control[30:2],1'b1,old_control[0]}:
   {128'd0,old_metadata,old_control};
 assign fact_after=fact_outcome==10?{128'd0,old_metadata,old_control[30:2],1'b0,old_control[0]}:
   {128'd0,(fact_outcome>=1&&fact_outcome<=3)?new_metadata:old_metadata,
           (fact_outcome>=1&&fact_outcome<=3)?new_control:old_control};
 always @*begin
  new_control=old_control;new_metadata=old_metadata;
  if(kind==1)begin
   new_control={timbre_q,item_q[8:1],item_q[15:9],9'd128,4'b1111};
   new_metadata={item_q[95:32],chosen_id,next_generation,item_q[31:28],item_q[23:16]};
  end else if(kind==2)new_control[2]=0;
  else if(kind==3)begin new_control[27:20]=item_q[8:1];new_control[19:13]=item_q[15:9];end
 end
 // bank*BANK_WORDS + slot*6 as explicit shifts and adds: BANK_WORDS is
 // 3<<(SIW+1) and 6 is 4+2.
 function[AW-1:0] row_address(input[1:0] bank,input[SW-1:0] slot);
  reg[AW-1:0] b,s;
  begin
   b={{(AW-2){1'b0}},bank};s={{(AW-SIW){1'b0}},slot[SIW-1:0]};
   row_address=(((b<<1)+b)<<(SIW+1))+(s<<2)+(s<<1);
  end
 endfunction
 // Every per-slot flag read happens while the row of read_slot_q is being
 // read (scan, prepare, copy, query, lookup, reclaim, loop, apply), so all of
 // them share that one index: one VOICES-input selector per flag vector.
 function[30:0] work_control(input[30:0] raw);
  begin
   work_control=raw;
   if(!allocated_since_publish[read_slot_q])begin work_control[0]=0;work_control[3]=0;end
   if(panic_urgent)work_control[3:0]=0;
  end
 endfunction
 task read_row(input[1:0] bank,input[SW-1:0] slot,input[7:0] continuation);
  begin read_address<=row_address(bank,slot);read_cycle<=0;read_slot_q<=slot;read_bank_q<=bank;
   meta_equal<=0;id_equal<=0;token_equal<=0;
   if(continuation==COPY_GOT)write_base<=row_address(copy_snapshot?2'd2:{1'b0,work_bank},slot);
   return_state<=continuation;state<=READ_WORDS;end
 endtask
 task write_words(input[1:0] mode,input[2:0] last_word,input[7:0] continuation);
  begin write_base<=row_address({1'b0,work_bank},selected_slot);write_cycle<=0;write_last<=last_word;write_mode<=mode;
   return_state<=continuation;state<=WRITE_WORDS;end
 endtask
 task next_scan;
  begin
   if(scan_slot==VOICES-1)state<=SELECT;
   else begin scan_slot<=scan_slot+1'b1;read_row({1'b0,work_bank},scan_slot+1'b1,SCAN_WORK);end
  end
 endtask
 always @*begin
  memory_write_data=0;
  if(copying)begin
   memory_write_data=memory_q;
   if(read_cycle==1)memory_write_data={1'b0,memory_q[30:4],
     audible[read_slot_q]};
  end else if(state==INIT)memory_write_data=init_word==0?32'd2048:32'd0;
  else if(write_mode==1)memory_write_data={1'b0,old_control[30:13],control_pan,old_control[3:0]};
  else if(write_mode==2)memory_write_data={1'b0,control_q[30:2],1'b0,control_q[0]};
  else if(write_mode==3)memory_write_data={1'b0,old_control[30:4],allocated_since_publish[read_slot_q]?4'd0:(old_control[3:0]&4'b1011)};
  else case(write_cycle)
   0:memory_write_data={1'b0,new_control};
   1:memory_write_data={4'd0,next_generation,item_q[31:28],item_q[23:16]};
   2:memory_write_data=chosen_id[31:0];
   3:memory_write_data=chosen_id[63:32];
   4:memory_write_data=item_q[63:32];
   5:memory_write_data=item_q[95:64];
  endcase
 end
 always @(posedge clk)begin
  frozen_read<=read_address>=FROZEN_BASE;
  live_q<=live_memory[read_address];frozen_q<=frozen_memory[read_address-FROZEN_BASE];
  if(memory_write)begin
   if(write_base>=FROZEN_BASE)frozen_memory[write_base-FROZEN_BASE]<=memory_write_data;
   else live_memory[write_base]<=memory_write_data;
  end
 end
 assign loop_cleanup_ready=LOOP_ENABLE&&!rst&&state==IDLE&&!in_batch&&!loop_cleanup_pending&&!panic&&!panic_pending;
 assign event_ready=!rst&&!(LOOP_ENABLE&&((loop_cleanup_valid&&!in_batch)||loop_cleanup_pending))&&state==IDLE&&
   (in_batch?!(query_valid&&query_view==2):(!snapshot_valid&&!query_valid&&!lookup_valid&&!pan_valid))&&(!reclaim_any||in_batch)&&
   !((frame_tick||publish_due)&&dirty&&!in_batch&&(!hold_publication||panic_urgent||loop_cleanup_pending))&&!panic&&!panic_pending;
 assign snapshot_ready=!rst&&state==IDLE&&!in_batch&&!loop_cleanup_pending&&!dirty&&!reclaim_any&&!panic&&!panic_pending;
 wire publication_service=dirty&&!in_batch&&(!hold_publication||panic_urgent||loop_cleanup_pending)&&(publish_due||frame_tick);
 assign query_ready=!rst&&state==IDLE&&!publication_service&&!snapshot_valid&&!pan_valid&&!lookup_valid&&
   (query_view==2||!in_batch)&&(!reclaim_any||(in_batch&&query_view==2))&&!panic&&!panic_pending;
 assign pan_ready=!rst&&state==IDLE&&!publication_service&&!in_batch&&!snapshot_valid&&!reclaim_any&&!panic&&!panic_pending;
 assign lookup_ready=pan_ready&&!pan_valid;
 assign lookup_response_valid=!rst&&state==LOOKUP_REPLY;
 assign lookup_found=lookup_found_q&&!lookup_cancelled&&!session_flush&&session_ready&&!panic&&!panic_pending;
 assign lookup_response_slot=selected_slot;assign lookup_response_word={128'd0,old_metadata,old_control};
 assign lookup_response_tag=control_tag;
 assign pan_response_valid=!rst&&state==PAN_REPLY;
 assign pan_result=panic||panic_pending?2'd3:pan_status;
 assign pan_response_slot=selected_slot;assign pan_before={128'd0,old_metadata,old_control};
 assign pan_after=pan_status==0?{128'd0,old_metadata,old_control[30:13],control_pan,old_control[3:0]}:pan_before;
 assign busy=state!=IDLE||in_batch;
 generate
 for(genvar s=0;s<VOICES;s++)begin: view
  assign audio_flags[s*4+:4]=audible[s];
 end
 wire[30:0] preparing=work_control(control_q);
 assign dir_we=!rst&&state==PREP_GOT;assign dir_slot=prepare_slot;assign dir_bank=work_bank;
 assign dir_read_bank=audio_bank;assign dir_published=audio_published;
 assign dir_data=preparing[30:28]==3'd5 ? {preparing[30:20],4'd0,prepared_key,preparing[12:4]}:preparing[30:4];
 for(genvar l=0;l<LANES;l++)begin: audio_directory
  // Display-only timbre mirror; the audio directory itself lives in the engines.
  reg[26:0] controls[0:15];
  always @(posedge clk)if(!rst&&state==PREP_GOT&&prepare_slot[SW-1:3]==l)
   controls[{work_bank,prepare_slot[2:0]}]<=preparing[30:4];
  // The board retains the three timbre bits per slot for its visual status;
  // unused note/pressure/Pan observation bits are removed by synthesis.
  for(genvar v=0;v<8;v++)begin: observation
   assign control_state[(l*8+v)*31+:31]=audio_published?
    {controls[{audio_bank,3'(v)}],audible[l*8+v]}:31'd2048;
  end
 end
 endgenerate
 always @(posedge clk)begin
  loop_cleanup_done<=0;fact_valid<=0;batch_done<=0;batch_abort<=0;published<=0;snapshot_done<=0;query_response_valid<=0;
  if(rst)begin
   loop_scan<=0;loop_all<=0;loop_sources<=0;loop_revision<=0;loop_cleanup_done<=0;loop_cleanup_pending<=0;loop_wait_output<=0;
   state<=INIT;init_word<=0;return_state<=IDLE;read_address<=0;write_base<=0;
   record_q<=0;control_q<=0;prepared_key<=0;read_cycle<=0;write_cycle<=0;write_last<=0;write_mode<=0;read_slot_q<=0;read_bank_q<=0;meta_equal<=0;id_equal<=0;token_equal<=0;id_carry<=0;next_generation<=0;
   prepared_flags<=0;prepared_valid<=0;prepare_slot<=0;
   work_bank<=0;audio_bank<=1;dirty<=0;in_batch<=0;copy_snapshot<=0;copy_slot<=0;
   panic_pending<=0;panic_urgent<=0;allocated_since_publish<=0;publish_due<=0;
   phone_owned<=0;session_live<=0;lookup_cancelled<=0;lookup_key_q<=0;control_id<=0;
   control_generation<=0;control_tag<=0;control_pan<=128;lookup_found_q<=0;pan_status<=0;
   audio_published<=0;
   scan_slot<=0;selected_slot<=0;query_slot_q<=0;query_view_q<=0;
   working_vibrato<=0;audio_vibrato<=0;
   item_q<=0;last_q<=0;timbre_q<=0;id_cursor<=1;collision_mode<=0;collision_hit<=0;retry_scan<=0;search_id<=1;identity_retries<=0;
   best<={31{1'b1}};victim<=0;target<=0;found<=0;
   
   chosen_id<=1;following_id<=2;event_age<=0;max_event_cycles<=0;accepted_events<=0;
   fact_outcome<=0;fact_slot<=0;fact_steal<=0;
   protocol_error<=0;rank_cursor<=0;selected_rank<=0;
   for(integer s=0;s<VOICES;s++)begin audible[s]<=4'd0;end
  end else begin
   if(panic)panic_pending<=1;
   if(frame_tick&&dirty)publish_due<=1;
   // The scan is not an effective fence: wait for the bank swap and the
   // PT8211 load of the resulting mixed frame before acknowledging cleanup.
   if(LOOP_ENABLE&&loop_wait_output&&frame_tick)begin
    loop_wait_output<=0;loop_cleanup_pending<=0;loop_cleanup_done<=1;
   end
   if(state!=IDLE)event_age<=event_age+1'b1;
   if(audio_retire)begin
    if(audio_reclaim!=0)prepared_valid<=0;
    for(integer s=0;s<VOICES;s++)begin
     audible[s][3]<=0;audible[s][0]<=0;
     
     if(audio_reclaim[s]&&!audible[s][2])audible[s][1]<=0;
    end
   end
   case(state)
    IDLE:begin
     // Panic is selected before any bank swap or port operation. Deferring
     // its state assignment until after this case could swap banks and then
     // cancel the required clone on the very same edge.
     if(LOOP_ENABLE&&loop_abort_batch&&in_batch&&item_q[31:28]==3&&(loop_cleanup_all||item_q[95:80]==loop_cleanup_revision))begin
      in_batch<=0;batch_abort<=1;dirty<=1;prepared_valid<=0;
     end else if(LOOP_ENABLE&&loop_cleanup_valid&&loop_cleanup_ready)begin
      loop_scan<=0;loop_all<=loop_cleanup_all;loop_sources<=loop_cleanup_sources;loop_revision<=loop_cleanup_revision;loop_cleanup_pending<=1;loop_wait_output<=0;state<=LOOP_READ;
     end else if(panic_pending||panic)begin
      if(in_batch)batch_abort<=1;
      in_batch<=0;dirty<=1;panic_pending<=0;panic_urgent<=1;prepared_valid<=0;
     end else if(reclaim_any&&!in_batch)begin
      selected_slot<=reclaim_first;
      // The selected slot is registered before the synchronous read.
      state<=RECLAIM_AUDIO;
     end else if(frame_tick&&dirty&&prepared_valid&&!in_batch&&(!hold_publication||panic_urgent||loop_cleanup_pending))begin
      for(integer s=0;s<VOICES;s++)audible[s]<=prepared_flags[s*4+:4];
      audio_vibrato<=working_vibrato;audio_published<=1;
      audio_bank<=work_bank;work_bank<=audio_bank;published<=1;dirty<=0;
      if(LOOP_ENABLE&&loop_cleanup_pending)loop_wait_output<=1;
      allocated_since_publish<=0;panic_urgent<=0;publish_due<=0;prepared_valid<=0;
      copy_snapshot<=0;copy_slot<=0;state<=COPY_READ;
     end else if(dirty&&!prepared_valid&&!in_batch&&(!hold_publication||panic_urgent||loop_cleanup_pending)&&(publish_due||frame_tick))begin
      prepare_slot<=0;state<=PREP_READ;
     end else if(snapshot_valid&&snapshot_ready)begin
      // The audio bank and non-flag controls cannot change while copying.
      // The frozen bank's reader (execution observer) uses only the gate
      // flag, which changes only at publication; copying blocks publication,
      // so the live gate equals its value at START.
      copy_snapshot<=1;copy_slot<=0;state<=COPY_READ;
     end else if(pan_valid&&pan_ready)begin
      selected_slot<=pan_slot;control_id<=pan_id;control_generation<=pan_generation;control_pan<=pan_value;
      read_row({1'b0,work_bank},pan_slot,PAN_GOT);
     end else if(lookup_valid&&lookup_ready)begin
      selected_slot<=SW'(lookup_key);lookup_key_q<=lookup_key;control_id<=lookup_identity;
      control_generation<=lookup_generation;control_tag<=lookup_tag;lookup_cancelled<=!session_ready;
      read_row({1'b0,work_bank},SW'(lookup_key),LOOKUP_GOT);
     end else if(query_valid&&query_ready)begin
      query_slot_q<=query_slot;query_view_q<=query_view;
      read_row(query_view==2?2'd2:query_view==1?{1'b0,audio_bank}:{1'b0,work_bank},query_slot,QUERY_GOT);
     end else if(event_valid&&event_ready)begin
      item_q<=event_item;last_q<=event_last;timbre_q<=timbre;
      scan_slot<=0;best<={31{1'b1}};victim<=0;target<=0;found<=0;collision_hit<=0;retry_scan<=0;search_id<=id_cursor;identity_retries<=0;
      event_age<=0;accepted_events<=accepted_events+1'b1;in_batch<=1;
      if(!in_batch)session_live<=session_ready;
      read_row({1'b0,work_bank},0,SCAN_WORK);
     end
    end
    READ_WORDS:begin
     if(read_cycle==1)control_q<=memory_q[30:0];
     if(read_cycle==2&&return_state==PREP_GOT)prepared_key<=memory_q[2:0];
     case(read_cycle)
      2:meta_equal<=alu_equal;
      3:id_equal<=alu_equal;
      4:id_equal<=id_equal&&alu_equal;
      5:token_equal<=alu_equal;
      6:token_equal<=token_equal&&alu_equal;
     endcase
     if(capture_record)case(read_cycle)
      1:record_q[30:0]<=record_control;
      2:record_q[58:31]<=record_data[27:0];
      3:record_q[90:59]<=record_data;
      4:record_q[122:91]<=record_data;
      5:record_q[154:123]<=record_data;
      6:record_q[186:155]<=record_data;
     endcase
     if(copying)write_base<=write_base+1'b1;
     if(read_cycle==6)state<=return_state;
     else begin read_cycle<=read_cycle+1'b1;if(read_cycle<5)read_address<=read_address+1'b1;end
    end
    WRITE_WORDS:begin
     write_base<=write_base+1'b1;
     if(write_cycle==write_last)state<=return_state;else write_cycle<=write_cycle+1'b1;
    end
    SCAN_WORK:begin
     if(!retry_scan&&candidate_less)begin best<=candidate;victim<=scan_slot;end
     if(!retry_scan&&matching)begin found<=1;target<=scan_slot;end
     if(collision_scan&&scan_control[1]&&id_equal)collision_hit<=1;
     if(collision_scan&&audible[read_slot_q][1])read_row({1'b0,audio_bank},scan_slot,SCAN_AUDIO);
     else next_scan();
    end
    SCAN_AUDIO:begin
     // Even an un-gated audible tail reserves its identity until it retires.
     if(audible[read_slot_q][1]&&id_equal)collision_hit<=1;
     next_scan();
    end
    SELECT:begin
     selected_slot<=kind==1?victim:target;chosen_id<=search_id;state<=ID_LOW;
    end
    ID_LOW:begin following_id[31:0]<=alu_sum[31:0];id_carry<=alu_sum[32];state<=ID_HIGH;end
    ID_HIGH:begin
     following_id[63:32]<=alu_sum[31:0];
     if(search_id==ID_MAX)following_id<=64'd1;
     state<=SELECT_DONE;
    end
    SELECT_DONE:begin
     if(collision_scan&&collision_hit&&!stale&&!invalid_item)begin
      search_id<=following_id;collision_hit<=0;retry_scan<=1;identity_retries<=identity_retries+1'b1;
      scan_slot<=0;read_row({1'b0,work_bank},0,SCAN_WORK);
     end else read_row({1'b0,work_bank},selected_slot,BEFORE);
    end
    BEFORE:begin next_generation<=alu_sum[15:0];state<=APPLY;end
    APPLY:begin
     fact_valid<=1;
     fact_outcome<=invalid_item?8'd6:stale?8'd5:{4'd0,kind};
     fact_slot<=kind==4||((kind==2||kind==3)&&!found)?{SW{1'b1}}:selected_slot;
     fact_steal<=kind==1&&!stale&&!invalid_item&&old_control[1];
     if(invalid_item)begin protocol_error<=1;batch_abort<=1;in_batch<=0;state<=IDLE;end
     else if(!stale&&kind!=4)begin
      dirty<=1;prepared_valid<=0;
      if(kind==1)begin
       allocated_since_publish[selected_slot]<=1;
       phone_owned[selected_slot]<=item_q[31:28]==2&&session_live&&session_ready;
       id_cursor<=following_id;
       if(following_id<id_cursor)collision_mode<=1;
       // Freeze the old rank before updating any slot. Audio reads the
       // published bank; event/query admission stays closed until FINISH.
       selected_rank<=rank_read;rank_cursor<=0;
       write_words(0,5,RANK_UPDATE);
      end else write_words(0,0,FINISH);
     end else begin
      if(!stale&&kind==4)begin working_vibrato<=item_q[8:1];dirty<=1;end
      state<=FINISH;
     end
    end
    RANK_UPDATE:begin
     if(rank_cursor==VOICES-1)state<=FINISH;else rank_cursor<=rank_cursor+1'b1;
    end
    FINISH:begin
     if(event_age>max_event_cycles)max_event_cycles<=event_age;
     // Even a stale/no-op batch receives a frame publication fence. Phone
     // completion and score group scheduling must not wait forever for a
     // bank change that an all-stale batch would otherwise never request.
     if(last_q)begin in_batch<=0;batch_done<=1;dirty<=1;prepared_valid<=0;end
     state<=IDLE;
    end
    LOOP_READ:begin selected_slot<=loop_scan;read_row({1'b0,work_bank},loop_scan,LOOP_GOT);end
    LOOP_GOT:begin
     if(old_control[1]&&
       ((loop_sources[0]&&old_metadata[11:8]==1)||
        (loop_sources[1]&&old_metadata[11:8]==3&&(loop_all||old_metadata[155:140]==loop_revision))))begin
      item_q<={old_metadata[155:92],old_metadata[11:8],4'd2,old_metadata[7:0],16'd0};state<=LOOP_APPLY;
     end else state<=LOOP_NEXT;
    end
    LOOP_APPLY:begin
     dirty<=1;prepared_valid<=0;phone_owned[selected_slot]<=0;
     if(!allocated_since_publish[read_slot_q]&&old_control[2])begin fact_valid<=1;fact_outcome<=2;fact_slot<=selected_slot;fact_steal<=0;end
     write_words(3,0,LOOP_NEXT);
    end
    LOOP_NEXT:begin
     if(loop_scan==VOICES-1)begin dirty<=1;prepared_valid<=0;publish_due<=1;state<=IDLE;end
     else begin loop_scan<=loop_scan+1'b1;state<=LOOP_READ;end
    end
    COPY_READ:read_row({1'b0,audio_bank},copy_slot,COPY_GOT);
    COPY_GOT:state<=COPY_NEXT;
    COPY_NEXT:begin
     if(copy_slot==VOICES-1)begin state<=IDLE;if(copy_snapshot)snapshot_done<=1;end
     else begin copy_slot<=copy_slot+1'b1;state<=COPY_READ;end
    end
    QUERY_GOT:begin
     if(query_view_q==1)record_q[3:0]<=audible[read_slot_q];
     query_response_valid<=1;state<=IDLE;
    end
    LOOKUP_GOT:begin
     lookup_found_q<=lookup_key_q<VOICES&&phone_owned[read_slot_q]&&
      control_q[1]&&!panic_urgent&&meta_equal&&token_equal;
     state<=LOOKUP_REPLY;
    end
    LOOKUP_REPLY:state<=IDLE;
    PAN_GOT:state<=PAN_APPLY;
    PAN_APPLY:begin
     pan_status<=control_pan>256?2'd1:!old_control[1]||!id_equal||!meta_equal?2'd2:2'd0;
     if(control_pan<=256&&old_control[1]&&id_equal&&meta_equal)begin
      dirty<=1;prepared_valid<=0;
      write_words(1,0,PAN_REPLY);
     end else state<=PAN_REPLY;
    end
    PAN_REPLY:state<=IDLE;
    RECLAIM_AUDIO:read_row({1'b0,audio_bank},selected_slot,RECLAIM_WORK);
    RECLAIM_WORK:begin
     record_q[3:0]<=audible[read_slot_q];
     read_row({1'b0,work_bank},selected_slot,RECLAIM_DONE);
    end
    RECLAIM_DONE:begin
     prepared_valid<=0;
     fact_valid<=1;fact_outcome<=10;fact_slot<=selected_slot;fact_steal<=0;
     if(id_equal&&meta_equal&&!control_q[2])begin
      phone_owned[selected_slot]<=0;
      write_words(2,0,RECLAIM_WRITTEN);
     end else state<=RECLAIM_WRITTEN;
    end
    RECLAIM_WRITTEN:state<=IDLE;
    INIT:begin
     write_base<=write_base+1'b1;init_word<=init_word==ROW_WORDS-1?3'd0:init_word+1'b1;
     if(write_base==AW'(3*BANK_WORDS-1))state<=IDLE;
    end
    PREP_READ:read_row({1'b0,work_bank},prepare_slot,PREP_GOT);
    PREP_GOT:begin
     prepared_flags<={4'(work_control(control_q)),prepared_flags[4*VOICES-1:4]};
     if(prepare_slot==VOICES-1)begin prepared_valid<=1;state<=IDLE;end
     else begin prepare_slot<=prepare_slot+1'b1;state<=PREP_READ;end
    end
    default:begin protocol_error<=1;state<=IDLE;end
   endcase
   if(session_flush)begin phone_owned<=0;session_live<=0;lookup_cancelled<=1;end
  end
 end
 // synthesis translate_off
 initial if(ID_WIDTH<7||ID_WIDTH>64)$fatal(1,"R28_ID_WIDTH");
 reg frame_tick_previous;
 always @(posedge clk)frame_tick_previous<=frame_tick;
 always @(posedge clk)if(!rst)begin
  if(identity_retries>64)$fatal(1,"R28_ID_SEARCH_BOUND");
  if(published&&!frame_tick_previous)$fatal(1,"R28_PUBLICATION_EDGE");
  if(event_valid&&event_ready&&query_valid&&query_ready)$fatal(1,"R28_PORT_OWNER");
  if(fact_valid&&fact_outcome==1&&(fact_after[122:59]==0))$fatal(1,"R28_ZERO_ID");
 end
 // synthesis translate_on
 wide_equal #(.WIDTH(32)) r54_equal_0_tree(.a(alu_a),.b(alu_b),.equal(r54_equal_0));
endmodule
