// Passive execution-to-EVR observer. No output returns to the allocator.
// Applied working-bank items are held until successful publication. Aborted
// batches become diagnostics; their speculative instances never update the
// persistent identity map. Snapshot values are latched together at ARM.
module s11_execution_observer(
 input wire clk,rst,audio_reset,start_valid,stop_valid,
 input wire capture_fault,
 input wire [7:0] capture_fault_code,
 input wire stop_delivery_idle,
 input wire [63:0] start_record_id,frame_id,
 input wire [15:0] subcycle,
 input wire allocator_busy,batch_begin,publish_ok,batch_abort,apply_valid,
 input wire [31:0] batch_timestamp,
 input wire [3:0] apply_lane,
 input wire [95:0] apply_item,
 input wire [7:0] apply_outcome,
 input wire [5:0] apply_slot,
 input wire [63:0] apply_id,
 input wire [15:0] apply_generation,
 input wire [2:0] apply_timbre,
 input wire apply_steal,
 input wire [63:0] retired_id,
 input wire [15:0] retired_generation,
 input wire [31:0] reclaim_mask,
 input wire [2047:0] reclaim_ids,
 input wire [511:0] reclaim_generations,
 input wire [31:0] slot_valid,slot_gate,
 input wire [223:0] slot_notes,
 input wire [255:0] slot_pressures,slot_keys,
 input wire [127:0] slot_sources,
 input wire [2047:0] slot_ids,slot_tokens,
 input wire [511:0] slot_generations,
 input wire [95:0] slot_timbres,
 input wire [287:0] slot_pans,
 output reg active,arming,incomplete,
 output reg [7:0] error_code,
 output reg [63:0] first_missing_frame,
 output wire tx_valid,
 output reg [5:0] tx_count,
 output reg [10239:0] tx_cells,
 input wire tx_ready,tx_done,
 output reg [31:0] published_batches,aborted_batches,applied_items,
 output reg [31:0] initial_instances,
 output reg [63:0] persistent_id_next,
 output wire observer_idle,
 output wire [2047:0] mapped_runtime_ids,mapped_persistent_ids,
 output wire [511:0] mapped_generations
);
 localparam START=1,BIND_ID=2,BIND_TOKEN=3,NOTE_ON=4,NOTE_OFF=5,EXPRESSION=6,
  VIBRATO=7,CONTINUATION=8,STEAL=9,RECLAIM=10,STALE=11,REJECT=12,ABORT=13,
  END=22,RESET=24,PUBLISH=25;
 reg [63:0] map_runtime[0:31],map_persistent[0:31];
 reg [15:0] map_generation[0:31];
 reg [63:0] snapshot_runtime[0:31],snapshot_token[0:31],snapshot_payload[0:31];
 reg [15:0] snapshot_source_key[0:31];
 reg [31:0] snapshot_valid,snapshot_gate;
 reg [63:0] snapshot_frame;reg [15:0] snapshot_subcycle;
 reg [5:0] snapshot_index;
 // File make_cell cell_sequence_counter is supplied by the single FIFO serializer. Omitting
 // that redundant 32-bit field here saves 148 bytes of register state.
 reg [223:0] stage_cells[0:36];
 reg [5:0] staged_count;
 reg pending,tx_inflight,tx_snapshot;
 reg [1:0] tx_kind;
 reg stop_pending,batch_tracking;
 reg reclaim_pending;
 reg [31:0] saved_reclaim_mask;
 reg [63:0] saved_reclaim_frame,saved_reclaim_pid[0:31];
 reg [15:0] saved_reclaim_subcycles[0:31];
 reg [31:0] saved_reclaim_next_frame;
 reg [1:0] reclaim_settle;
 reg [31:0] cell_sequence_counter;
 reg [3:0] allocation_items;
 reg [4:0] allocation_slots[0:8];
 reg [63:0] allocation_runtime[0:8],allocation_persistent[0:8];
 reg [15:0] allocation_generation[0:8];
 integer i,j,n;reg [63:0] pid,old_pid,payload;
 reg [7:0] cell_type,flags;
 wire [3:0] source=apply_item[31:28],kind=apply_item[27:24];
 wire [7:0] key=apply_item[23:16],pressure=apply_item[8:1];
 wire [6:0] note=apply_item[15:9];
 function [255:0] make_cell;
  input [7:0] t,f,s,k;input [31:0] seq;
  input [63:0] fr,id,p;
  begin make_cell={p,id,fr,seq,k,s,f,t};end
 endfunction
 function [223:0] staged_cell;
  input [7:0] t,f,s,k;input [31:0] ignored_seq;
  input [63:0] fr,id,p;
  begin staged_cell={p,id,fr,k,s,f,t};end
 endfunction
 function [63:0] identity;
  input [5:0] slot;input [63:0] runtime;input [15:0] generation;
  integer m;
  begin
   identity=0;
   if(slot<32 && map_runtime[slot]==runtime && map_generation[slot]==generation)
    identity=map_persistent[slot];
   for(m=0;m<9;m=m+1)
    if(m<allocation_items && allocation_slots[m]==slot &&
       allocation_runtime[m]==runtime && allocation_generation[m]==generation)
      identity=allocation_persistent[m];
  end
 endfunction
 function [63:0] event_payload;
  input [15:0] clock_offset;input [6:0] midi;input [7:0] gain;
  input [2:0] timbre;input [8:0] pan;input [15:0] gen;input [4:0] slot;
  begin event_payload={slot,gen,pan,timbre,gain,midi,clock_offset};end
 endfunction
 assign tx_valid=(arming || pending ||
     (reclaim_pending && reclaim_settle==0 && reclaim_mask==0)) && !tx_inflight;
 assign observer_idle=!active && !arming && !pending && !tx_inflight &&
     !batch_tracking && !reclaim_pending && !stop_pending;
 generate for(genvar q=0;q<32;q=q+1)begin: readonly_persistent_map
  assign mapped_runtime_ids[q*64+:64]=map_runtime[q];
  assign mapped_persistent_ids[q*64+:64]=map_persistent[q];
  assign mapped_generations[q*16+:16]=map_generation[q];
 end endgenerate
 always @*begin
  tx_cells=0;tx_count=0;
  if((tx_inflight && tx_kind==1) || (!tx_inflight && arming))begin
   if(snapshot_index==0)begin
    tx_count=1;
    tx_cells[255:0]=make_cell(START,8'd3,8'hff,8'hff,cell_sequence_counter,
      snapshot_frame,0,{48'd0,snapshot_subcycle});
   end else if(snapshot_index<=32)begin
    tx_count=3;
    tx_cells[255:0]=make_cell(CONTINUATION,8'd2|(snapshot_gate[snapshot_index-1]?8'd0:8'd16),
     snapshot_source_key[snapshot_index-1][15:8],snapshot_source_key[snapshot_index-1][7:0],
     cell_sequence_counter,snapshot_frame,{58'd0,snapshot_index},snapshot_payload[snapshot_index-1]);
    tx_cells[511:256]=make_cell(BIND_ID,8'd2,
     snapshot_source_key[snapshot_index-1][15:8],snapshot_source_key[snapshot_index-1][7:0],
     cell_sequence_counter+1,snapshot_frame,{58'd0,snapshot_index},snapshot_runtime[snapshot_index-1]);
    tx_cells[767:512]=make_cell(BIND_TOKEN,8'd3,
     snapshot_source_key[snapshot_index-1][15:8],snapshot_source_key[snapshot_index-1][7:0],
     cell_sequence_counter+2,snapshot_frame,{58'd0,snapshot_index},snapshot_token[snapshot_index-1]);
   end
  end else if((tx_inflight && tx_kind==2) || (!tx_inflight && pending))begin
   tx_count=staged_count;
   for(integer k=0;k<37;k=k+1)begin
    tx_cells[k*256+:256]={stage_cells[k][223:32],(cell_sequence_counter+k),stage_cells[k][31:0]};
   end
  end else if((tx_inflight && tx_kind==3) || (!tx_inflight && reclaim_pending))begin
   tx_count=0;
   for(integer k=0;k<32;k=k+1)if(saved_reclaim_mask[k])begin
    tx_cells[tx_count*256+:256]=make_cell(RECLAIM,8'd4,8'hff,8'hff,cell_sequence_counter+tx_count,
     saved_reclaim_frame+saved_reclaim_next_frame[k],saved_reclaim_pid[k],
     {43'd0,k[4:0],saved_reclaim_subcycles[k]});
    tx_count=tx_count+1'b1;
   end
   if(tx_count!=0)tx_cells[(tx_count-1)*256+8+:8]=8'd5;
  end
 end
 always @(posedge clk)begin
  if(rst)begin
   active<=0;arming<=0;incomplete<=0;error_code<=0;first_missing_frame<=0;
   snapshot_valid<=0;snapshot_gate<=0;snapshot_frame<=0;snapshot_subcycle<=0;
   snapshot_index<=0;staged_count<=0;pending<=0;tx_inflight<=0;tx_snapshot<=0;tx_kind<=0;
   stop_pending<=0;batch_tracking<=0;cell_sequence_counter<=0;allocation_items<=0;
   reclaim_pending<=0;saved_reclaim_mask<=0;saved_reclaim_frame<=0;
   saved_reclaim_next_frame<=0;reclaim_settle<=0;
   published_batches<=0;aborted_batches<=0;applied_items<=0;initial_instances<=0;
   persistent_id_next<=33;
   for(i=0;i<32;i=i+1)begin
    map_runtime[i]<=0;map_persistent[i]<=0;map_generation[i]<=0;
    snapshot_runtime[i]<=0;snapshot_token[i]<=0;snapshot_payload[i]<=0;
    snapshot_source_key[i]<=0;
    saved_reclaim_pid[i]<=0;
    saved_reclaim_subcycles[i]<=0;
   end
   for(i=0;i<37;i=i+1)stage_cells[i]<=0;
   for(i=0;i<9;i=i+1)begin allocation_slots[i]<=0;allocation_runtime[i]<=0;
    allocation_persistent[i]<=0;allocation_generation[i]<=0;end
  end else begin
   if(tx_valid && tx_ready)begin tx_inflight<=1;tx_snapshot<=arming;
    tx_kind<=arming?2'd1:pending?2'd2:2'd3;end
   if(tx_done && tx_inflight)begin
    tx_inflight<=0;cell_sequence_counter<=cell_sequence_counter+tx_count;
    if(tx_snapshot)begin
     n=33;
     for(i=31;i>=0;i=i-1)if(i+1>snapshot_index && snapshot_valid[i])n=i+1;
     if(n==33)begin arming<=0;snapshot_index<=33;end else snapshot_index<=n;
    end else if(tx_kind==2)begin pending<=0;staged_count<=0;end
    else begin reclaim_pending<=0;saved_reclaim_mask<=0;end
   end
   if(start_valid && !active && !arming && !pending && !tx_inflight && !allocator_busy && start_record_id!=0)begin
    active<=1;arming<=1;incomplete<=0;error_code<=0;first_missing_frame<=0;
    snapshot_valid<=slot_valid;snapshot_gate<=slot_gate;snapshot_frame<=frame_id;
    snapshot_subcycle<=subcycle;snapshot_index<=0;cell_sequence_counter<=0;
    persistent_id_next<=33;allocation_items<=0;staged_count<=0;stop_pending<=0;
    batch_tracking<=batch_begin;reclaim_pending<=0;saved_reclaim_mask<=0;
    saved_reclaim_next_frame<=0;reclaim_settle<=0;
    published_batches<=0;aborted_batches<=0;applied_items<=0;initial_instances<=0;
    for(i=0;i<32;i=i+1)begin
     map_runtime[i]<=slot_ids[i*64+:64];map_persistent[i]<=slot_valid[i]?i+1:0;
     map_generation[i]<=slot_generations[i*16+:16];
     snapshot_runtime[i]<=slot_ids[i*64+:64];snapshot_token[i]<=slot_tokens[i*64+:64];
     snapshot_payload[i]<=event_payload(subcycle,slot_notes[i*7+:7],slot_pressures[i*8+:8],
       slot_timbres[i*3+:3],slot_pans[i*9+:9],slot_generations[i*16+:16],i);
     snapshot_source_key[i]<={4'd0,slot_sources[i*4+:4],slot_keys[i*8+:8]};
    end
    n=0;for(i=0;i<32;i=i+1)if(slot_valid[i])n=n+1;
    initial_instances<=n;
   end
   if(active && batch_begin)begin
    if(pending || (tx_inflight && !tx_snapshot))begin
     active<=0;incomplete<=1;error_code<=8'd2;first_missing_frame<=frame_id;
    end else begin staged_count<=0;allocation_items<=0;batch_tracking<=1;end
   end
   if((active || stop_pending) && apply_valid && batch_tracking)begin
    n=staged_count;pid=identity(apply_slot,apply_id,apply_generation);
    payload=event_payload(subcycle,note,pressure,apply_timbre,
      (apply_slot<32 && slot_ids[apply_slot*64+:64]==apply_id &&
       slot_generations[apply_slot*16+:16]==apply_generation)?slot_pans[apply_slot*9+:9]:9'd128,
       apply_generation,apply_slot[4:0]);
    if(apply_outcome==1)begin
     if(n+(apply_steal?4:3)>36 || allocation_items>=9 || persistent_id_next==64'hffffffffffffffff)begin
      active<=0;incomplete<=1;error_code<=8'd2;first_missing_frame<=frame_id;
     end else begin
      pid=persistent_id_next;persistent_id_next<=persistent_id_next+1;
      if(apply_steal)begin
       old_pid=identity(apply_slot,retired_id,retired_generation);
       stage_cells[n]<=staged_cell(STEAL,8'd4,{4'd0,source},key,cell_sequence_counter+n,frame_id,old_pid,retired_id);n=n+1;
      end
      // New instances always start center; a previous slot pan cannot leak.
      payload=event_payload(subcycle,note,pressure,apply_timbre,9'd128,apply_generation,apply_slot[4:0]);
      stage_cells[n]<=staged_cell(NOTE_ON,0,{4'd0,source},key,cell_sequence_counter+n,frame_id,pid,payload);n=n+1;
      stage_cells[n]<=staged_cell(BIND_ID,0,{4'd0,source},key,cell_sequence_counter+n,frame_id,pid,apply_id);n=n+1;
      stage_cells[n]<=staged_cell(BIND_TOKEN,0,{4'd0,source},key,cell_sequence_counter+n,frame_id,pid,apply_item[95:32]);n=n+1;
      allocation_slots[allocation_items]<=apply_slot;
      allocation_runtime[allocation_items]<=apply_id;allocation_persistent[allocation_items]<=pid;
      allocation_generation[allocation_items]<=apply_generation;allocation_items<=allocation_items+1;
     end
    end else begin
     cell_type=apply_outcome==2?NOTE_OFF:apply_outcome==3?EXPRESSION:
       apply_outcome==4?VIBRATO:apply_outcome==5?STALE:REJECT;
     flags=apply_outcome>=5?8'd4:8'd0;
     if(n>=36)begin active<=0;incomplete<=1;error_code<=8'd2;first_missing_frame<=frame_id;end
     else begin stage_cells[n]<=staged_cell(cell_type,flags,{4'd0,source},key,cell_sequence_counter+n,frame_id,pid,payload);n=n+1;end
    end
    staged_count<=n;applied_items<=applied_items+1;
   end
   if((active || stop_pending) && batch_tracking && publish_ok)begin
    if(staged_count<37)begin
     stage_cells[staged_count]<=staged_cell(PUBLISH,8'd5,8'hff,8'hff,cell_sequence_counter+staged_count,
       frame_id,0,{16'd0,batch_timestamp,subcycle});
     staged_count<=staged_count+1;pending<=1;batch_tracking<=0;
     published_batches<=published_batches+1;
     for(i=0;i<9;i=i+1)if(i<allocation_items)begin
      map_runtime[allocation_slots[i]]<=allocation_runtime[i];
      map_persistent[allocation_slots[i]]<=allocation_persistent[i];
      map_generation[allocation_slots[i]]<=allocation_generation[i];
     end
    end else begin active<=0;incomplete<=1;error_code<=8'd2;first_missing_frame<=frame_id;end
   end
   if((active || stop_pending) && batch_tracking && batch_abort)begin
    // Preserve actual working applies for audit, but mark every speculative
    // cell as diagnostic/incomplete. ABORT supplies the publication failure;
    // none of these allocations is committed to the persistent map.
    n=staged_count;
    for(i=0;i<37;i=i+1)if(i<staged_count)
     stage_cells[i][15:8]<=stage_cells[i][15:8]|8'd12;
    if(apply_valid && apply_outcome==6)begin
     stage_cells[n]<=staged_cell(REJECT,8'd12,{4'd0,source},key,cell_sequence_counter+n,frame_id,0,
      event_payload(subcycle,note,pressure,apply_timbre,9'd128,apply_generation,apply_slot[4:0]));
     n=n+1;
    end
    stage_cells[n]<=staged_cell(ABORT,8'd13,8'hff,8'hff,cell_sequence_counter+n,frame_id,0,{16'd0,batch_timestamp,subcycle});
    staged_count<=n+1;
    pending<=1;batch_tracking<=0;allocation_items<=0;
    aborted_batches<=aborted_batches+1;
   end
   // Four lane pipelines can return all 32 completions over eight adjacent
   // clocks. Keep one cell PER completion with its actual clock/frame, then
   // offer the bounded batch after two quiet clocks. No events are merged.
   if(reclaim_pending && reclaim_settle!=0)reclaim_settle<=reclaim_settle-1'b1;
   if(active && reclaim_mask!=0)begin
    if((tx_inflight && tx_kind==3) || (saved_reclaim_mask & reclaim_mask)!=0 ||
       (reclaim_pending && frame_id!=saved_reclaim_frame && frame_id!=saved_reclaim_frame+1))begin
     active<=0;incomplete<=1;error_code<=8'd2;first_missing_frame<=frame_id;end
    else begin
     reclaim_pending<=1;saved_reclaim_mask<=saved_reclaim_mask|reclaim_mask;reclaim_settle<=2;
     if(!reclaim_pending)saved_reclaim_frame<=frame_id;
     for(i=0;i<32;i=i+1)if(reclaim_mask[i])begin
      saved_reclaim_pid[i]<=identity(i,reclaim_ids[i*64+:64],reclaim_generations[i*16+:16]);
      saved_reclaim_subcycles[i]<=subcycle;
      saved_reclaim_next_frame[i]<=reclaim_pending && frame_id==saved_reclaim_frame+1;
     end
    end
   end
   if(stop_valid && active)begin active<=0;stop_pending<=1;end
   if(stop_pending && stop_delivery_idle && !pending && !tx_inflight && !arming && !batch_tracking && !reclaim_pending)begin
    stage_cells[0]<=staged_cell(END,8'd1,8'hff,8'hff,cell_sequence_counter,frame_id,0,{48'd0,subcycle});
    staged_count<=1;pending<=1;stop_pending<=0;
   end
   if(audio_reset && active)begin
    active<=0;incomplete<=1;error_code<=8'd5;first_missing_frame<=frame_id;
    if(!pending && !tx_inflight && !arming)begin
     stage_cells[0]<=staged_cell(RESET,8'd13,8'hff,8'hff,cell_sequence_counter,frame_id,0,{48'd0,subcycle});
     staged_count<=1;pending<=1;batch_tracking<=0;
    end
   end
   if(capture_fault && !incomplete && (active || arming || pending || tx_inflight))begin
    active<=0;incomplete<=1;error_code<=capture_fault_code;
    // The first unaccepted transaction, rather than the later fault detection
    // edge, defines the lost prefix boundary. Accepted transactions still drain.
    first_missing_frame<=pending && !tx_inflight ? stage_cells[0][95:32] :
      arming ? snapshot_frame : reclaim_pending && !tx_inflight ? saved_reclaim_frame : 64'hffffffffffffffff;
   end
   // Keep an accepted immutable transaction until its final RAM write.
   // Everything not accepted at the failure boundary is explicitly outside
   // the retained complete prefix, so it cannot hang later START commands.
   if(incomplete && !tx_inflight && !start_valid)begin
    arming<=0;pending<=0;reclaim_pending<=0;batch_tracking<=0;stop_pending<=0;staged_count<=0;
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if($isunknown({audio_reset,start_valid,stop_valid,capture_fault,stop_delivery_idle,allocator_busy,batch_begin,
     publish_ok,batch_abort,apply_valid,reclaim_mask,tx_ready,tx_done}))$fatal(1,"S11_EXEC_CONTROL_XZ");
  if(apply_valid && $isunknown({apply_item,apply_outcome,apply_slot,apply_id,
     apply_generation,apply_timbre,apply_steal}))$fatal(1,"S11_EXEC_APPLY_XZ");
  if(reclaim_mask!=0 && $isunknown({reclaim_ids,reclaim_generations}))
    $fatal(1,"S11_EXEC_RECLAIM_XZ");
  if(start_valid && $isunknown({start_record_id,slot_valid,slot_gate,slot_notes,
     slot_pressures,slot_keys,slot_sources,slot_ids,slot_tokens,slot_generations,
     slot_timbres,slot_pans}))$fatal(1,"S11_EXEC_SNAPSHOT_XZ");
  if(staged_count>37)$fatal(1,"S11_EXEC_BATCH_SIZE");
  if(batch_abort && batch_tracking && staged_count+(apply_valid && apply_outcome==6?2:1)>37)
    $fatal(1,"S11_EXEC_ABORT_SIZE");
 end
 // synthesis translate_on
endmodule


