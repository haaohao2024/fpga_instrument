// Passive execution-to-EVR observer. No output returns to the allocator.
// Applied working-bank items are held until successful publication. Aborted
// batches become diagnostics; their speculative instances never update the
// persistent identity map. Snapshot values are latched together at ARM.
module s11_execution_observer #(parameter integer SYNC_READ=1, INDEXED_OVERLAY=0, SNAPSHOT_TOKEN_DIRECTORY=0)(
 output wire token_snapshot_capture,token_snapshot_read,output wire [4:0] token_snapshot_slot,
 input wire [63:0] token_snapshot_data,

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
 input wire [5:0] tx_index,
 output wire [255:0] tx_cell,
 input wire tx_read_valid,input wire [15:0] tx_read_epoch,
 output reg tx_response_valid,output reg [5:0] tx_response_index,
 output reg [15:0] tx_response_epoch,
 input wire tx_ready,tx_done,
 output reg [31:0] published_batches,aborted_batches,applied_items,
 output reg [31:0] initial_instances,
 output reg [63:0] persistent_id_next,
 output wire observer_idle,
 input wire [4:0] map_query_slot,
 output wire [63:0] map_query_runtime,map_query_persistent,
 output wire [15:0] map_query_generation
);
 localparam START=1,BIND_ID=2,BIND_TOKEN=3,NOTE_ON=4,NOTE_OFF=5,EXPRESSION=6,
  VIBRATO=7,CONTINUATION=8,STEAL=9,RECLAIM=10,STALE=11,REJECT=12,ABORT=13,
  END=22,RESET=24,PUBLISH=25;
 wire [143:0] apply_map_word;
 wire [5:0] overlay_slot[0:5];wire [63:0] overlay_runtime[0:5];wire [15:0] overlay_generation[0:5];
 wire [143:0] overlay_published[0:5];wire [63:0] overlay_pid[0:5];
 wire [2:0] reclaim_query_slot[0:3];
 wire [143:0] reclaim_map_word[0:3],apply_lane_word[0:3],cfg_lane_word[0:3];
 reg [63:0] snapshot_runtime[0:31],snapshot_token[0:31],snapshot_payload[0:31];
 reg [15:0] snapshot_source_key[0:31];
 // The entire immutable snapshot has one lifetime, from the original
 // simultaneous START edge to reset/the next START. Reset its ownership,
 // not all 6656 data bits. The directory masks the selected word while
 // unowned; the serializer cannot enter a snapshot batch before START.
 reg snapshot_initialized;
 reg [31:0] snapshot_valid,snapshot_gate;
 reg [63:0] snapshot_frame;reg [15:0] snapshot_subcycle;
 reg [5:0] snapshot_index;
 // File make_cell cell_sequence_counter is supplied by the single FIFO serializer. Omitting
 // that redundant 32-bit field here saves 148 bytes of register state.
 // Nine actual apply edges per Allocator packet; each immutable raw record
 // describes up to four EVR cells. Only the requested cell is encoded.
 reg [479:0] stage_records[0:8] /*synthesis syn_ramstyle="distributed_ram"*/;reg [3:0] stage_record_count;
 reg [3:0] stage_record_index[0:36];reg [2:0] stage_record_kind[0:36];
 reg [36:0] stage_record_diagnostic;reg [223:0] terminal_cell;
 reg [63:0] first_stage_frame;

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
 wire [4:0] snapshot_read_slot=snapshot_index-6'd1;
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
 function equal64(input [63:0] a,b);
  reg [31:0] matched /* synthesis syn_keep=1 */;integer k;
  begin for(k=0;k<32;k=k+1)matched[k]=(a[k*2+:2]==b[k*2+:2]);equal64=&matched;end
 endfunction
 function equal16(input [15:0] a,b);
  reg [7:0] matched /* synthesis syn_keep=1 */;integer k;
  begin for(k=0;k<8;k=k+1)matched[k]=(a[k*2+:2]==b[k*2+:2]);equal16=&matched;end
 endfunction
 function equal6(input [5:0] a,b);
  reg [2:0] matched /* synthesis syn_keep=1 */;integer k;
  begin for(k=0;k<3;k=k+1)matched[k]=(a[k*2+:2]==b[k*2+:2]);equal6=&matched;end
 endfunction
 function [63:0] identity;
  input [5:0] slot;input [63:0] runtime;input [15:0] generation;input [143:0] published_word;
  integer m;reg [8:0] lookup_hits;reg [3:0] winning_record;
  begin
   lookup_hits=0;identity=0;winning_record=0;
   // Old loop priority is the highest matching allocation record, even
   // for duplicate slot/runtime/generation entries. Retain all nine records.
   for(m=0;m<9;m=m+1)
    if(m<allocation_items && equal6({1'b0,allocation_slots[m]},slot) &&
       equal64(allocation_runtime[m],runtime) && equal16(allocation_generation[m],generation))lookup_hits[m]=1;
   for(m=0;m<9;m=m+1)if(lookup_hits[m])winning_record=m;
   if(|lookup_hits)identity=allocation_persistent[winning_record];
   else begin
    if(slot<32 && equal64(published_word[63:0],runtime) && equal16(published_word[143:128],generation))
     identity=published_word[127:64];
   end
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
 // The authoritative producer has four disjoint 8-slot Lanes and one
 // final writeback per Lane per clock. Only the selected slot of each Lane
 // needs an identity lookup; all four results are captured on the original
 // reclaim edge, without waiting for serialization or changing admission.
 wire [63:0] reclaim_lane_pid[0:3];
 generate for(genvar l=0;l<4;l=l+1)begin: shared_reclaim_identity
  localparam [1:0] LANE=l;
  wire [7:0] lane_mask=reclaim_mask[l*8+:8];
  wire [63:0] runtime_words[0:7];wire [15:0] generation_words[0:7];
  for(genvar s=0;s<8;s=s+1)begin: fixed_input_words
   assign runtime_words[s]=reclaim_ids[(l*8+s)*64+:64];
   assign generation_words[s]=reclaim_generations[(l*8+s)*16+:16];
  end
  reg [2:0] selected_slot;reg [63:0] selected_pid;
  always_comb begin
   selected_slot=0;
   for(integer s=0;s<8;s=s+1)if(lane_mask[s])selected_slot=s;
   selected_pid=INDEXED_OVERLAY?overlay_pid[l]:identity({1'b0,LANE,selected_slot},runtime_words[selected_slot],generation_words[selected_slot],reclaim_map_word[l]);
  end
  assign overlay_slot[l]={1'b0,LANE,selected_slot};
  assign overlay_runtime[l]=runtime_words[selected_slot];assign overlay_generation[l]=generation_words[selected_slot];
  assign overlay_published[l]=reclaim_map_word[l];
  assign reclaim_query_slot[l]=selected_slot;
  assign reclaim_lane_pid[l]=selected_pid;
  // synthesis translate_off
  always @(posedge clk)if(!rst && !$isunknown(lane_mask) && !$onehot0(lane_mask))
   $fatal(1,"S11_EXEC_RECLAIM_MULTI_PER_LANE lane=%0d mask=%h",l,lane_mask);
  // synthesis translate_on
 end endgenerate
 // Rank each fixed slot in the frozen reclaim bitmap. Decode only the
 // requested slot; no 32-way variable insertion into a whole-batch bus.
 wire [5:0] reclaim_rank[0:32];
 assign reclaim_rank[0]=6'd0;
 // Exact six-bit prefix population, using a balanced tree. The former
 // 32-deep prefix chain became a register path under synchronous reads.
 function [2:0] population4(input [3:0] bits);
  reg [1:0] a,b;
  begin a={1'b0,bits[0]}+{1'b0,bits[1]};
   b={1'b0,bits[2]}+{1'b0,bits[3]};
   population4={1'b0,a}+{1'b0,b};end
 endfunction
 function [5:0] population32(input [31:0] bits);
  reg [2:0] n[0:7];reg [3:0] a[0:3];reg [4:0] b[0:1];
  begin
   for(integer i=0;i<8;i=i+1)n[i]=population4(bits[i*4+:4]);
   for(integer i=0;i<4;i=i+1)a[i]={1'b0,n[i*2]}+{1'b0,n[i*2+1]};
   for(integer i=0;i<2;i=i+1)b[i]={1'b0,a[i*2]}+{1'b0,a[i*2+1]};
   population32={1'b0,b[0]}+{1'b0,b[1]};
  end
 endfunction
 generate for(genvar r=0;r<32;r=r+1)begin: reclaim_rank_decode
  localparam [31:0] PREFIX=32'hffffffff>>(31-r);
  assign reclaim_rank[r+1]=population32(saved_reclaim_mask&PREFIX);
 end endgenerate
 // Capture all exact prefix ranks during the EXISTING reclaim settle
 // clocks. This register bank has no reset/data-valid role. The original
 // two quiet clocks make it current before any valid offer or read request.
 wire [5:0] reclaim_read_rank[0:31];
 generate for(genvar r=0;r<32;r=r+1)begin: prepared_reclaim_rank
  if(SYNC_READ)begin: registered
   reg [5:0] value;
   always @(posedge clk)value<=reclaim_rank[r];
   assign reclaim_read_rank[r]=value;
  end else assign reclaim_read_rank[r]=reclaim_rank[r];
 end endgenerate
 wire [31:0] reclaim_read_select;
 wire [4:0] reclaim_read_slot;
 generate for(genvar r=0;r<32;r=r+1)begin: parallel_reclaim_read
  assign reclaim_read_select[r]=saved_reclaim_mask[r]&&reclaim_read_rank[r]==tx_index;
 end endgenerate
 // Every set bit has a distinct prefix rank, for every 32-bit bitmap.
 // Thus these parallel OR reductions are exactly the old priority index.
 assign reclaim_read_slot[0]=|(reclaim_read_select&32'haaaaaaaa);
 assign reclaim_read_slot[1]=|(reclaim_read_select&32'hcccccccc);
 assign reclaim_read_slot[2]=|(reclaim_read_select&32'hf0f0f0f0);
 assign reclaim_read_slot[3]=|(reclaim_read_select&32'hff00ff00);
 assign reclaim_read_slot[4]=|(reclaim_read_select&32'hffff0000);
 function [223:0] encode_stage(input [2:0] record_kind,input [479:0] raw,input diagnostic,input [223:0] terminal);
  reg [7:0] typ,flg,src,ky;reg [63:0] fr,ident,body;
  begin
   typ=0;flg=0;src=raw[15:8];ky=raw[7:0];fr=raw[479:416];ident=raw[415:352];body=0;
   case(record_kind)
    1:begin typ=STEAL;flg=4;ident=raw[159:96];body=raw[223:160];end
    2:begin typ=NOTE_ON;body=raw[95:32];end
    3:begin typ=BIND_ID;body=raw[351:288];end
    4:begin typ=BIND_TOKEN;body=raw[287:224];end
    5:begin typ=raw[31:24];flg=raw[23:16];body=raw[95:32];end
    7:begin typ=REJECT;flg=12;ident=0;body=raw[95:32];end
    default:begin end
   endcase
   if(diagnostic)flg=flg|8'd12;
   if(record_kind==0)encode_stage=0;
   else if(record_kind==6)encode_stage=terminal;
   else encode_stage=staged_cell(typ,flg,src,ky,0,fr,ident,body);
  end
 endfunction
 wire [223:0] selected_stage_cell=SYNC_READ ?
  (tx_index<37 && stage_record_kind[tx_index]==6 ? terminal_cell:224'd0) :
  (tx_index<37 ? encode_stage(stage_record_kind[tx_index],stage_records[stage_record_index[tx_index]],stage_record_diagnostic[tx_index],terminal_cell):224'd0);
 reg [255:0] capture_tx_cell;
 wire read_is_stage=(tx_inflight&&tx_kind==2)||(!tx_inflight&&!arming&&pending);
 wire read_is_reclaim=(tx_inflight&&tx_kind==3)||(!tx_inflight&&!arming&&!pending&&reclaim_pending);
 always @*begin
  capture_tx_cell=0;tx_count=0;
  if((tx_inflight && tx_kind==1) || (!tx_inflight && arming))begin
   if(snapshot_index==0)begin
    tx_count=1;
    if(tx_index==0)capture_tx_cell=make_cell(START,8'd3,8'hff,8'hff,cell_sequence_counter,
      snapshot_frame,0,{48'd0,snapshot_subcycle});
   end else if(snapshot_index<=32)begin
    tx_count=3;
    case(tx_index)
     0:capture_tx_cell=make_cell(CONTINUATION,8'd2|(snapshot_gate[snapshot_read_slot]?8'd0:8'd16),
      snapshot_source_key[snapshot_read_slot][15:8],snapshot_source_key[snapshot_read_slot][7:0],
      cell_sequence_counter,snapshot_frame,{58'd0,snapshot_index},snapshot_payload[snapshot_read_slot]);
     1:capture_tx_cell=make_cell(BIND_ID,8'd2,
      snapshot_source_key[snapshot_read_slot][15:8],snapshot_source_key[snapshot_read_slot][7:0],
      cell_sequence_counter+1,snapshot_frame,{58'd0,snapshot_index},snapshot_runtime[snapshot_read_slot]);
     2:capture_tx_cell=make_cell(BIND_TOKEN,8'd3,
      snapshot_source_key[snapshot_read_slot][15:8],snapshot_source_key[snapshot_read_slot][7:0],
      cell_sequence_counter+2,snapshot_frame,{58'd0,snapshot_index},SNAPSHOT_TOKEN_DIRECTORY?64'd0:snapshot_token[snapshot_read_slot]);
    endcase
   end
  end else if((tx_inflight && tx_kind==2) || (!tx_inflight && pending))begin
   tx_count=staged_count;
   if(tx_index<37)
    capture_tx_cell={selected_stage_cell[223:32],(cell_sequence_counter+{26'd0,tx_index}),selected_stage_cell[31:0]};
  end else if((tx_inflight && tx_kind==3) || (!tx_inflight && reclaim_pending))begin
   tx_count=reclaim_rank[32];
   if(tx_index<tx_count)
    capture_tx_cell=make_cell(RECLAIM,tx_index==tx_count-1'b1 ? 8'd5 : 8'd4,8'hff,8'hff,
     cell_sequence_counter+{26'd0,tx_index},
     (saved_reclaim_next_frame[reclaim_read_slot] ? saved_reclaim_frame+64'd1 : saved_reclaim_frame),(SYNC_READ?64'd0:saved_reclaim_pid[reclaim_read_slot]),
     {43'd0,reclaim_read_slot,saved_reclaim_subcycles[reclaim_read_slot]});
  end
 end
 // A one-clock response is owned by the request's exact batch/index.
 // Wide apply records have ONE write and ONE synchronous read port.
 reg [479:0] response_raw;
 reg [255:0] response_meta;
 reg response_stage,response_reclaim,response_snapshot_token;
 reg [2:0] response_record_kind;
 reg response_diagnostic;
 reg [1:0] response_reclaim_lane;
 wire [63:0] response_pid_lane[0:3];
 wire reclaim_capture_ok=active && reclaim_mask!=0 &&
  !((tx_inflight&&tx_kind==3)||(saved_reclaim_mask&reclaim_mask)!=0||
    (reclaim_pending&&frame_id!=saved_reclaim_frame&&frame_id!=saved_reclaim_frame+1));
 generate for(genvar l=0;l<4;l=l+1)begin: reclaim_read_bank
  if(SYNC_READ)begin: synchronous
   reg [63:0] pid_memory[0:7] /*synthesis syn_ramstyle="distributed_ram"*/;
   reg [63:0] pid_q;
   reg [2:0] write_slot;
   always @*begin write_slot=0;for(integer s=0;s<8;s=s+1)if(reclaim_mask[l*8+s])write_slot=s;end
   always @(posedge clk)begin
    if(!rst&&reclaim_capture_ok&&(|reclaim_mask[l*8+:8]))pid_memory[write_slot]<=reclaim_lane_pid[l];
    if(!rst&&tx_read_valid&&read_is_reclaim&&reclaim_read_slot[4:3]==l)
     pid_q<=pid_memory[reclaim_read_slot[2:0]];
   end
   assign response_pid_lane[l]=pid_q;
  end else assign response_pid_lane[l]=64'd0;
 end endgenerate
 always @(posedge clk)begin
  if(rst)begin tx_response_valid<=0;tx_response_index<=0;tx_response_epoch<=0;
   response_stage<=0;response_reclaim<=0;response_snapshot_token<=0;response_record_kind<=0;response_diagnostic<=0;response_reclaim_lane<=0;end
  else begin
   tx_response_valid<=SYNC_READ&&tx_read_valid;
   if(SYNC_READ&&tx_read_valid)begin
    tx_response_index<=tx_index;tx_response_epoch<=tx_read_epoch;
    response_meta<=capture_tx_cell;response_stage<=read_is_stage;response_reclaim<=read_is_reclaim;response_snapshot_token<=token_snapshot_read;
    response_record_kind<=stage_record_kind[tx_index];response_diagnostic<=stage_record_diagnostic[tx_index];
    response_reclaim_lane<=reclaim_read_slot[4:3];
   end
  end
 end
 always @(posedge clk)if(SYNC_READ&&!rst&&tx_read_valid&&read_is_stage&&stage_record_kind[tx_index]!=6)
  response_raw<=stage_records[stage_record_index[tx_index]];
 wire [223:0] decoded_response=encode_stage(response_record_kind,response_raw,response_diagnostic,
  {response_meta[255:64],response_meta[31:0]});
 assign tx_cell=!SYNC_READ?capture_tx_cell:response_stage?
  {decoded_response[223:32],response_meta[63:32],decoded_response[31:0]}:response_reclaim?
  {response_meta[255:192],response_pid_lane[response_reclaim_lane],response_meta[127:0]}:response_snapshot_token?
  {token_snapshot_data,response_meta[191:0]}:response_meta;
 // synthesis translate_off
 always @(posedge clk)if(SYNC_READ&&!rst)begin
  if($isunknown(tx_read_valid))$fatal(1,"EXEC_READ_CONTROL_XZ");
  if(tx_read_valid&&($isunknown({tx_index,tx_read_epoch})||tx_index>=tx_count))$fatal(1,"EXEC_READ_REQUEST_RANGE");
  if(tx_read_valid&&read_is_reclaim)begin
   // Every old valid offered/locked reclaim index remains supported.
   for(integer r=0;r<32;r=r+1)
    if(reclaim_read_rank[r]!==reclaim_rank[r])$fatal(1,"EXEC_RECLAIM_RANK_NOT_PREPARED");
  end
 end
 // synthesis translate_on
 // Fixed-address staging writes. A shared apply descriptor supplies up to
 // four adjacent cells; publication and abort retain the original priorities.
 wire stage_apply=(active || stop_pending) && apply_valid && batch_tracking;
 wire stage_alloc=stage_apply && apply_outcome==1 &&
  staged_count+(apply_steal?6'd4:6'd3)<=36 && allocation_items<9 &&
  persistent_id_next!=64'hffffffffffffffff;
 wire stage_other=stage_apply && apply_outcome!=1 && staged_count<36;
 wire stage_publish=(active || stop_pending) && batch_tracking && publish_ok && staged_count<37;
 wire stage_abort=(active || stop_pending) && batch_tracking && batch_abort;
 wire stage_reject=stage_abort && apply_valid && apply_outcome==6;
 wire stage_end=stop_pending && stop_delivery_idle && !pending && !tx_inflight && !arming && !batch_tracking && !reclaim_pending;
 wire stage_reset=audio_reset && active && !pending && !tx_inflight && !arming;
 // A single apply writes the unpublished bank of its fixed slot. Only
 // the 32 small bank selectors change at publication, so every visible map
 // entry changes atomically on the original edge. Initial map fields reuse
 // the immutable ARM snapshot instead of requiring a 32-address RAM write.
 reg [31:0] map_initial,map_bank_select,map_dirty;

 wire map_publish=(active || stop_pending) && batch_tracking && publish_ok && staged_count<37;
 wire map_start=start_valid && !active && !arming && !pending && !tx_inflight && !allocator_busy && start_record_id!=0;
 assign token_snapshot_capture=SNAPSHOT_TOKEN_DIRECTORY && map_start;
 assign token_snapshot_slot=snapshot_read_slot;
 // This RAM response is synchronous with the EXISTING metadata response.
 // A valid bit binds the original snapshot/index/epoch; no extra writer cycle.
 assign token_snapshot_read=SNAPSHOT_TOKEN_DIRECTORY && SYNC_READ && !rst && tx_read_valid &&
  ((tx_inflight&&tx_kind==1)||(!tx_inflight&&arming)) && snapshot_index>0 && snapshot_index<=32 && tx_index==2;
 // synthesis translate_off
 initial if(SNAPSHOT_TOKEN_DIRECTORY && !SYNC_READ)$fatal(1,"TOKEN_REQUIRES_SYNC_PREFETCH");
 // synthesis translate_on
 always @(posedge clk)begin
  if(rst)snapshot_initialized<=0;
  else if(map_start)snapshot_initialized<=1;
 end
 generate for(genvar s=0;s<32;s=s+1)begin: capture_snapshot_bank
  always @(posedge clk)if(!rst&&map_start)begin
   snapshot_runtime[s]<=slot_ids[s*64+:64];snapshot_token[s]<=slot_tokens[s*64+:64];
   snapshot_payload[s]<=event_payload(subcycle,slot_notes[s*7+:7],slot_pressures[s*8+:8],
    slot_timbres[s*3+:3],slot_pans[s*9+:9],slot_generations[s*16+:16],s);
   snapshot_source_key[s]<={4'd0,slot_sources[s*4+:4],slot_keys[s*8+:8]};
  end
 end endgenerate
 always @(posedge clk)begin
  if(rst)begin map_initial<=32'hffffffff;map_bank_select<=0;map_dirty<=0;end
  else begin
   if(map_start)begin map_initial<=32'hffffffff;map_bank_select<=0;map_dirty<=0;end
   if(active && batch_begin && !(pending || (tx_inflight && !tx_snapshot)))map_dirty<=0;
   if(stage_alloc)map_dirty[apply_slot[4:0]]<=1;
   if(map_publish)begin
    map_initial<=map_initial&~map_dirty;
    map_bank_select<=map_bank_select^map_dirty;
    map_dirty<=0;
   end
   if(stage_abort)map_dirty<=0;
  end
 end
 // Four disjoint Lane banks, each with three asynchronous read ports.
 // Each port has a 16x144 mirror. All writes target the unpublished version;
 // selectors publish all changed entries together on the original edge.
 // Snapshot fallback is immutable and remains a simultaneous 32-slot capture.
 generate for(genvar l=0;l<4;l=l+1)begin: identity_directory
  wire [143:0] initial_words[0:7];
  for(genvar s=0;s<8;s=s+1)begin: snapshot_words
   localparam integer SLOT=l*8+s;
   assign initial_words[s]={snapshot_payload[SLOT][58:43],
    (snapshot_valid[SLOT]?SLOT+64'd1:64'd0),snapshot_runtime[SLOT]};
  end
  wire [2:0] read_slot[0:2];
  wire [143:0] port_word[0:2];
  assign read_slot[0]=reclaim_query_slot[l];
  assign read_slot[1]=apply_slot[2:0];
  assign read_slot[2]=map_query_slot[2:0];
  wire [7:0] selectors=map_bank_select[l*8+:8];
  wire [7:0] initial_select=map_initial[l*8+:8];
  wire [3:0] write_address={~selectors[apply_slot[2:0]],apply_slot[2:0]};
  wire write_enable=!rst && stage_alloc && !apply_slot[5] && apply_slot[4:3]==l;
  wire [143:0] write_word={apply_generation,persistent_id_next,apply_id};
  for(genvar p=0;p<3;p=p+1)begin: mirror
   wire [3:0] read_address={selectors[read_slot[p]],read_slot[p]};
   wire [143:0] stored_word;
   for(genvar b=0;b<36;b=b+1)begin: nibble
    RAM16SDP4 memory(.CLK(clk),.WRE(write_enable),.WAD(write_address),
     .RAD(read_address),.DI(write_word[b*4+:4]),.DO(stored_word[b*4+:4]));
   end
   assign port_word[p]=initial_select[read_slot[p]]?
    (snapshot_initialized?initial_words[read_slot[p]]:144'd0):stored_word;
  end
  assign reclaim_map_word[l]=port_word[0];
  assign apply_lane_word[l]=port_word[1];
  assign cfg_lane_word[l]=port_word[2];
 end endgenerate
 assign apply_map_word=apply_lane_word[apply_slot[4:3]];
 assign {map_query_generation,map_query_persistent,map_query_runtime}=cfg_lane_word[map_query_slot[4:3]];
 // synthesis translate_off
 always @(posedge clk)if(!rst && publish_ok && apply_valid)
  $fatal(1,"S11_EXEC_PUBLISH_APPLY_OVERLAP");
 // synthesis translate_on
 reg [63:0] apply_identity,stolen_identity;
 // always_comb includes state read inside identity(), including publication
 // of an unchanged runtime ID between two adjacent observed applies.
 always_comb begin
  apply_identity=INDEXED_OVERLAY?overlay_pid[4]:identity(apply_slot,apply_id,apply_generation,apply_map_word);
  stolen_identity=INDEXED_OVERLAY?overlay_pid[5]:identity(apply_slot,retired_id,retired_generation,apply_map_word);
 end

 wire stage_begin=active && batch_begin && !(pending || (tx_inflight && !tx_snapshot));
 assign overlay_slot[4]=apply_slot;assign overlay_runtime[4]=apply_id;assign overlay_generation[4]=apply_generation;assign overlay_published[4]=apply_map_word;
 assign overlay_slot[5]=apply_slot;assign overlay_runtime[5]=retired_id;assign overlay_generation[5]=retired_generation;assign overlay_published[5]=apply_map_word;
 generate if(INDEXED_OVERLAY)begin: indexed_overlay
  reg [63:0] bucket_valid;
  // This validity follows precisely allocation_items' reset boundaries.
  // Publication retains the overlay until the next batch, as before.
  always @(posedge clk)begin
   if(rst)bucket_valid<=0;
   else begin
    if(map_start || stage_begin || stage_abort)bucket_valid<=0;
    if(stage_alloc)bucket_valid[apply_id[5:0]]<=1;
   end
  end
  wire [151:0] write_word={3'd0,apply_slot[4:0],apply_generation,apply_id,persistent_id_next};
  for(genvar q=0;q<6;q=q+1)begin: query
   wire [3:0] bucket_index[0:3];wire [3:0] record_index;
   wire [151:0] word;
   for(genvar b=0;b<4;b=b+1)begin: buckets
    RAM16SDP4 index_ram(.CLK(clk),.WRE(!rst&&stage_alloc&&apply_id[5:4]==b),
     .WAD(apply_id[3:0]),.RAD(overlay_runtime[q][3:0]),.DI(allocation_items),.DO(bucket_index[b]));
   end
   assign record_index=bucket_index[overlay_runtime[q][5:4]];
   for(genvar n=0;n<38;n=n+1)begin: records
    RAM16SDP4 record_ram(.CLK(clk),.WRE(!rst&&stage_alloc),.WAD(allocation_items),
     .RAD(record_index),.DI(write_word[n*4+:4]),.DO(word[n*4+:4]));
   end
   wire hit=bucket_valid[overlay_runtime[q][5:0]]&&record_index<allocation_items&&
    overlay_slot[q]<32&&word[148:144]==overlay_slot[q][4:0]&&
    equal64(word[127:64],overlay_runtime[q])&&equal16(word[143:128],overlay_generation[q]);
   wire published_hit=overlay_slot[q]<32&&equal64(overlay_published[q][63:0],overlay_runtime[q])&&
    equal16(overlay_published[q][143:128],overlay_generation[q]);
   assign overlay_pid[q]=hit?word[63:0]:published_hit?overlay_published[q][127:64]:64'd0;
  end
  // synthesis translate_off
  always @(posedge clk)if(!rst&&stage_alloc)begin
   for(integer m=0;m<9;m=m+1)if(m<allocation_items&&allocation_runtime[m][5:0]==apply_id[5:0]&&
    {allocation_slots[m],allocation_generation[m],allocation_runtime[m]}!={apply_slot[4:0],apply_generation,apply_id})
     $fatal(1,"EXEC_OVERLAY_INDEX_ALIAS");
  end
  // Keep the original full identity comparison as an independent assertion.
  // It is excluded from synthesis; no redundant formal storage is retained.
  always @(posedge clk)begin #1;if(!rst)begin
   for(integer q=0;q<6;q=q+1)
    if(overlay_pid[q]!==identity(overlay_slot[q],overlay_runtime[q],overlay_generation[q],overlay_published[q]))
      $fatal(1,"EXEC_OVERLAY_FULL_ID_EQ query=%0d",q);
  end
  end
  // synthesis translate_on
 end else begin: ordinary_overlay
  for(genvar q=0;q<6;q=q+1)begin assign overlay_pid[q]=0;end
 end endgenerate
 wire [63:0] live_runtime[0:31];wire [15:0] live_generation[0:31];wire [8:0] live_pan[0:31];
 generate for(genvar s=0;s<32;s=s+1)begin: fixed_live_slot_words
  assign live_runtime[s]=slot_ids[s*64+:64];assign live_generation[s]=slot_generations[s*16+:16];
  assign live_pan[s]=slot_pans[s*9+:9];
 end endgenerate
 wire [63:0] allocate_payload=event_payload(subcycle,note,pressure,apply_timbre,9'd128,apply_generation,apply_slot[4:0]);
 wire [63:0] observed_payload=event_payload(subcycle,note,pressure,apply_timbre,
  (apply_slot<32 && live_runtime[apply_slot[4:0]]==apply_id &&
   live_generation[apply_slot[4:0]]==apply_generation)?live_pan[apply_slot[4:0]]:9'd128,
  apply_generation,apply_slot[4:0]);
 wire [7:0] observed_type=apply_outcome==2?NOTE_OFF:apply_outcome==3?EXPRESSION:
  apply_outcome==4?VIBRATO:apply_outcome==5?STALE:REJECT;
 wire [223:0] apply_cells[0:3];
 assign apply_cells[0]=apply_steal?
  staged_cell(STEAL,8'd4,{4'd0,source},key,0,frame_id,stolen_identity,retired_id):
  staged_cell(NOTE_ON,0,{4'd0,source},key,0,frame_id,persistent_id_next,allocate_payload);
 assign apply_cells[1]=apply_steal?
  staged_cell(NOTE_ON,0,{4'd0,source},key,0,frame_id,persistent_id_next,allocate_payload):
  staged_cell(BIND_ID,0,{4'd0,source},key,0,frame_id,persistent_id_next,apply_id);
 assign apply_cells[2]=apply_steal?
  staged_cell(BIND_ID,0,{4'd0,source},key,0,frame_id,persistent_id_next,apply_id):
  staged_cell(BIND_TOKEN,0,{4'd0,source},key,0,frame_id,persistent_id_next,apply_item[95:32]);
 assign apply_cells[3]=staged_cell(BIND_TOKEN,0,{4'd0,source},key,0,frame_id,persistent_id_next,apply_item[95:32]);
 wire [223:0] other_cell=staged_cell(observed_type,apply_outcome>=5?8'd4:8'd0,{4'd0,source},key,0,frame_id,apply_identity,observed_payload);
 wire [223:0] publish_cell=staged_cell(PUBLISH,8'd5,8'hff,8'hff,0,frame_id,0,{16'd0,batch_timestamp,subcycle});
 wire [223:0] reject_cell=staged_cell(REJECT,8'd12,{4'd0,source},key,0,frame_id,0,allocate_payload);
 wire [223:0] abort_cell=staged_cell(ABORT,8'd13,8'hff,8'hff,0,frame_id,0,{16'd0,batch_timestamp,subcycle});
 wire [223:0] end_cell=staged_cell(END,8'd1,8'hff,8'hff,0,frame_id,0,{48'd0,subcycle});
 wire [223:0] reset_cell=staged_cell(RESET,8'd13,8'hff,8'hff,0,frame_id,0,{48'd0,subcycle});
 wire stage_capture=stage_alloc || stage_other || stage_reject;
 wire [479:0] captured_stage_record={frame_id,
  stage_alloc?persistent_id_next:apply_identity,apply_id,apply_item[95:32],retired_id,stolen_identity,
  (stage_alloc || stage_reject)?allocate_payload:observed_payload,observed_type,
  apply_outcome>=5?8'd4:8'd0,{4'd0,source},key};
 always @(posedge clk)begin
  if(rst)begin stage_record_count<=0;terminal_cell<=0;first_stage_frame<=0;end
  else begin
   if(map_start || stage_begin)stage_record_count<=0;
   if(stage_capture)stage_record_count<=stage_record_count+1'b1;
   if(stage_publish)terminal_cell<=publish_cell;
   if(stage_abort)terminal_cell<=abort_cell;
   if(stage_end)terminal_cell<=end_cell;
   if(stage_reset)terminal_cell<=reset_cell;
   if(((stage_alloc || stage_other || stage_publish || stage_reject) && staged_count==0) ||
      (stage_abort && staged_count+{5'd0,stage_reject}==0) || stage_end || stage_reset)
    first_stage_frame<=frame_id;
  end
 end
 always @(posedge clk)if(!rst && stage_capture && stage_record_count<9)
  stage_records[stage_record_count]<=captured_stage_record;
 generate for(genvar s=0;s<37;s=s+1)begin: fixed_stage_descriptor
  wire [5:0] delta=s-staged_count;
  always @(posedge clk)begin
   if(rst)begin stage_record_index[s]<=0;stage_record_kind[s]<=0;stage_record_diagnostic[s]<=0;end
   else begin
    if(stage_alloc && s>=staged_count && delta<(apply_steal?6'd4:6'd3))begin
     stage_record_index[s]<=stage_record_count;stage_record_diagnostic[s]<=0;
     stage_record_kind[s]<=apply_steal?(delta+6'd1):(delta+6'd2);
    end
    if(stage_other && s==staged_count)begin
     stage_record_index[s]<=stage_record_count;stage_record_kind[s]<=5;stage_record_diagnostic[s]<=0;
    end
    if(stage_publish && s==staged_count)begin stage_record_kind[s]<=6;stage_record_diagnostic[s]<=0;end
    if(stage_abort && s<staged_count)stage_record_diagnostic[s]<=1;
    if(stage_reject && s==staged_count)begin
     stage_record_index[s]<=stage_record_count;stage_record_kind[s]<=7;stage_record_diagnostic[s]<=0;
    end
    if(stage_abort && s==staged_count+{5'd0,stage_reject})begin stage_record_kind[s]<=6;stage_record_diagnostic[s]<=0;end
    if(stage_end && s==0)begin stage_record_kind[s]<=6;stage_record_diagnostic[s]<=0;end
    if(stage_reset && s==0)begin stage_record_kind[s]<=6;stage_record_diagnostic[s]<=0;end
   end
  end
 end endgenerate
 // synthesis translate_off
 always @(posedge clk)if(!rst && stage_capture && stage_record_count>=9)
  $fatal(1,"S11_EXEC_MORE_THAN_NINE_APPLIES");
 // synthesis translate_on
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
       
    if(!SYNC_READ)saved_reclaim_pid[i]<=0;
    saved_reclaim_subcycles[i]<=0;
   end
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
    n=0;for(i=0;i<32;i=i+1)if(slot_valid[i])n=n+1;
    initial_instances<=n;
   end
   if(active && batch_begin)begin
    if(pending || (tx_inflight && !tx_snapshot))begin
     active<=0;incomplete<=1;error_code<=8'd2;first_missing_frame<=frame_id;
    end else begin staged_count<=0;allocation_items<=0;batch_tracking<=1;end
   end
   if((active || stop_pending) && apply_valid && batch_tracking)begin
    n=staged_count;pid=apply_identity;
    payload=event_payload(subcycle,note,pressure,apply_timbre,
      (apply_slot<32 && live_runtime[apply_slot[4:0]]==apply_id &&
       live_generation[apply_slot[4:0]]==apply_generation)?live_pan[apply_slot[4:0]]:9'd128,
       apply_generation,apply_slot[4:0]);
    if(apply_outcome==1)begin
     if(n+(apply_steal?4:3)>36 || allocation_items>=9 || persistent_id_next==64'hffffffffffffffff)begin
      active<=0;incomplete<=1;error_code<=8'd2;first_missing_frame<=frame_id;
     end else begin
      pid=persistent_id_next;persistent_id_next<=persistent_id_next+1;
      if(apply_steal)begin
       old_pid=stolen_identity;n=n+1;
      end
      // New instances always start center; a previous slot pan cannot leak.
      payload=event_payload(subcycle,note,pressure,apply_timbre,9'd128,apply_generation,apply_slot[4:0]);n=n+1;n=n+1;n=n+1;
      allocation_slots[allocation_items]<=apply_slot;
      allocation_runtime[allocation_items]<=apply_id;allocation_persistent[allocation_items]<=pid;
      allocation_generation[allocation_items]<=apply_generation;allocation_items<=allocation_items+1;
     end
    end else begin
     cell_type=apply_outcome==2?NOTE_OFF:apply_outcome==3?EXPRESSION:
       apply_outcome==4?VIBRATO:apply_outcome==5?STALE:REJECT;
     flags=apply_outcome>=5?8'd4:8'd0;
     if(n>=36)begin active<=0;incomplete<=1;error_code<=8'd2;first_missing_frame<=frame_id;end
     else begin n=n+1;end
    end
    staged_count<=n;applied_items<=applied_items+1;
   end
   if((active || stop_pending) && batch_tracking && publish_ok)begin
    if(staged_count<37)begin
     staged_count<=staged_count+1;pending<=1;batch_tracking<=0;
     published_batches<=published_batches+1;
    end else begin active<=0;incomplete<=1;error_code<=8'd2;first_missing_frame<=frame_id;end
   end
   if((active || stop_pending) && batch_tracking && batch_abort)begin
    // Preserve actual working applies for audit, but mark every speculative
    // cell as diagnostic/incomplete. ABORT supplies the publication failure;
    // none of these allocations is committed to the persistent map.
    n=staged_count;
    if(apply_valid && apply_outcome==6)begin
     n=n+1;
    end
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
      if(!SYNC_READ)saved_reclaim_pid[i]<=reclaim_lane_pid[i/8];
      saved_reclaim_subcycles[i]<=subcycle;
      saved_reclaim_next_frame[i]<=reclaim_pending && frame_id==saved_reclaim_frame+1;
     end
    end
   end
   if(stop_valid && active)begin active<=0;stop_pending<=1;end
   if(stop_pending && stop_delivery_idle && !pending && !tx_inflight && !arming && !batch_tracking && !reclaim_pending)begin
    staged_count<=1;pending<=1;stop_pending<=0;
   end
   if(audio_reset && active)begin
    active<=0;incomplete<=1;error_code<=8'd5;first_missing_frame<=frame_id;
    if(!pending && !tx_inflight && !arming)begin
     staged_count<=1;pending<=1;batch_tracking<=0;
    end
   end
   if(capture_fault && !incomplete && (active || arming || pending || tx_inflight))begin
    active<=0;incomplete<=1;error_code<=capture_fault_code;
    // The first unaccepted transaction, rather than the later fault detection
    // edge, defines the lost prefix boundary. Accepted transactions still drain.
    first_missing_frame<=pending && !tx_inflight ? first_stage_frame :
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
  if((tx_valid || tx_inflight) && $isunknown(tx_index))$fatal(1,"S11_EXEC_INDEX_XZ");
  if(staged_count>37)$fatal(1,"S11_EXEC_BATCH_SIZE");
  if(batch_abort && batch_tracking && staged_count+(apply_valid && apply_outcome==6?2:1)>37)
    $fatal(1,"S11_EXEC_ABORT_SIZE");
 end
 // synthesis translate_on
endmodule



module r8_indexed_exec_probe #(parameter integer SYNC_READ=1, INDEXED_OVERLAY=0)(
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
 input wire [5:0] tx_index,
 output wire [255:0] tx_cell,
 input wire tx_read_valid,input wire [15:0] tx_read_epoch,
 output reg tx_response_valid,output reg [5:0] tx_response_index,
 output reg [15:0] tx_response_epoch,
 input wire tx_ready,tx_done,
 output reg [31:0] published_batches,aborted_batches,applied_items,
 output reg [31:0] initial_instances,
 output reg [63:0] persistent_id_next,
 output wire observer_idle,
 input wire [4:0] map_query_slot,
 output wire [63:0] map_query_runtime,map_query_persistent,
 output wire [15:0] map_query_generation
);

s11_execution_observer #(.INDEXED_OVERLAY(1)) impl(.*);
endmodule
