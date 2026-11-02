// Immutable execution facts -> original EVR cells and transaction protocol.
module r18_execution_observer(
 input wire clk,rst,audio_reset,start_valid,stop_valid,capture_fault,
 input wire[7:0] capture_fault_code,input wire stop_delivery_idle,
 input wire[63:0] start_record_id,frame_id,input wire[15:0] subcycle,
 input wire allocator_busy,batch_begin,publish_ok,batch_abort,input wire[31:0] batch_timestamp,
 input wire fact_valid,input wire[95:0] fact_item,input wire[7:0] fact_outcome,
 input wire[5:0] fact_slot,input wire fact_steal,input wire[314:0] fact_before,fact_after,
 input wire[63:0] fact_frame,input wire[15:0] fact_subcycle,input wire reclaim_batch_busy,
 input wire[31:0] slot_valid,slot_gate,
 output wire[63:0] allocated_persistent_id,
 output wire snapshot_query_valid,input wire snapshot_query_ready,output wire[4:0] snapshot_query_slot,
 input wire snapshot_response_valid,input wire[4:0] snapshot_response_slot,input wire[314:0] snapshot_response_word,
 output reg active,arming,incomplete,output reg[7:0] error_code,output reg[63:0] first_missing_frame,
 output wire tx_valid,output reg[5:0] tx_count,input wire[5:0] tx_index,output wire[255:0] tx_cell,
 input wire tx_read_valid,input wire[15:0] tx_read_epoch,
 output reg tx_response_valid,output reg[5:0] tx_response_index,output reg[15:0] tx_response_epoch,
 input wire tx_ready,tx_done,output reg[31:0] published_batches,aborted_batches,applied_items,initial_instances,
 output reg[63:0] persistent_id_next,output wire observer_idle
);
 // EVR2 records actual musical operations. No runtime/token binding, audit
 // expansion, reclaim ranking or recording-owned identity directory.
 function automatic [63:0] voice_tag(input [4:0] slot,input [15:0] gen);
  voice_tag={42'd0,1'b1,gen,slot};
 endfunction
 function automatic [63:0] payload(input [15:0] sc,input [314:0] w,input [4:0] slot);
  payload={slot,w[58:43],w[12:4],w[30:28],w[27:20],w[19:13],sc};
 endfunction
 function automatic [223:0] cell_data(input [7:0] typ,flags,src,key,input [63:0] fr,id,p);
  cell_data={p,id,fr,key,src,flags,typ};
 endfunction
 reg [223:0] events[0:8] /* synthesis syn_ramstyle="distributed_ram" */;
 reg [3:0] count; reg tracking,pending,inflight,stop_pending;
 reg [1:0] owner;reg [223:0] terminal;
 reg [31:0] initial_mask;reg [5:0] snap_index;
 reg [58:0] snap_word;reg snap_loaded,snap_wait;
 reg [63:0] snap_frame;reg [15:0] snap_subcycle;
 reg [223:0] response;
 wire starting=start_valid && !active && !arming && !pending && !inflight && !allocator_busy && start_record_id!=0;
 wire musical=fact_valid && fact_outcome>=1 && fact_outcome<=4;
 wire capture=(active||stop_pending)&&tracking&&musical&&!batch_abort;
 wire [7:0] typ=fact_outcome==1?8'd4:fact_outcome==2?8'd5:fact_outcome==3?8'd6:8'd7;
 wire [314:0] before_or_after=fact_outcome==1?fact_after:fact_before;
 wire [63:0] tag=fact_slot<32?{42'd0,1'b1,before_or_after[58:43],fact_slot[4:0]}:64'd0;
 wire [63:0] body=fact_outcome==4?{40'd0,fact_item[8:1],fact_subcycle}:
  {fact_slot[4:0],before_or_after[58:43],before_or_after[12:4],before_or_after[30:28],fact_item[8:1],fact_item[15:9],fact_subcycle};
 assign allocated_persistent_id=64'd0;
 assign observer_idle=!active&&!arming&&!pending&&!inflight&&!tracking&&!stop_pending;
 assign tx_valid=!inflight && !incomplete && (arming?(snap_index==0||snap_loaded):pending);
 always @* tx_count=arming || (inflight&&owner==1)?6'd1:{2'd0,count}+6'd1;
 assign snapshot_query_valid=arming&&snap_index>0&&!snap_loaded&&!snap_wait&&!incomplete;
 assign snapshot_query_slot=snap_index-1'b1;
 reg [5:0] next_snapshot;
 always @*begin
  next_snapshot=33;
  for(integer i=31;i>=0;i--)if(initial_mask[i]&&i+1>snap_index)next_snapshot=i+1;
 end
 always @(posedge clk)begin
  if(rst)begin tx_response_valid<=0;tx_response_index<=0;tx_response_epoch<=0;end
  else begin
   tx_response_valid<=tx_read_valid;
   if(tx_read_valid)begin
    tx_response_index<=tx_index;tx_response_epoch<=tx_read_epoch;
    if(arming || (inflight&&owner==1))begin
     if(snap_index==0)response<=cell_data(1,3,255,255,snap_frame,0,{48'd0,snap_subcycle});
     else response<=cell_data(8,snap_word[2]?8'd3:8'd19,{4'd0,snap_word[42:39]},snap_word[38:31],snap_frame,
       {42'd0,1'b1,snap_word[58:43],snapshot_query_slot},{snapshot_query_slot,snap_word[58:43],snap_word[12:4],snap_word[30:28],snap_word[27:20],snap_word[19:13],snap_subcycle});
    end else response<=tx_index<count?events[tx_index]:terminal;
   end
  end
 end
 assign tx_cell={response[223:32],32'd0,response[31:0]};
 always @(posedge clk)if(!rst&&capture&&count<9)
  events[count]<=cell_data(typ,fact_steal?8'd32:8'd0,{4'd0,fact_item[31:28]},fact_item[23:16],fact_frame,tag,body);
 always @(posedge clk)begin
  if(rst)begin
   active<=0;arming<=0;incomplete<=0;error_code<=0;first_missing_frame<=64'hffffffffffffffff;
   count<=0;tracking<=0;pending<=0;inflight<=0;stop_pending<=0;owner<=0;
   initial_mask<=0;snap_index<=0;snap_loaded<=0;snap_wait<=0;snap_frame<=0;snap_subcycle<=0;
   published_batches<=0;aborted_batches<=0;applied_items<=0;initial_instances<=0;persistent_id_next<=0;
  end else begin
   if(snapshot_query_valid&&snapshot_query_ready)snap_wait<=1;
   if(snapshot_response_valid&&snap_wait&&snapshot_response_slot==snapshot_query_slot)begin
    snap_word<=snapshot_response_word[58:0];snap_wait<=0;snap_loaded<=1;
   end
   if(tx_valid&&tx_ready)begin inflight<=1;owner<=arming?1:2;end
   if(tx_done&&inflight)begin
    inflight<=0;
    if(owner==1)begin
     snap_loaded<=0;snap_wait<=0;snap_index<=next_snapshot;
     if(next_snapshot==49)arming<=0;
    end else begin pending<=0;count<=0;end
   end
   if(starting)begin
    active<=1;arming<=1;incomplete<=0;error_code<=0;first_missing_frame<=64'hffffffffffffffff;
    initial_mask<=slot_valid;snap_frame<=frame_id;snap_subcycle<=subcycle;snap_index<=0;snap_loaded<=0;snap_wait<=0;
    count<=0;tracking<=batch_begin;pending<=0;stop_pending<=0;
   end
   if(active&&batch_begin)begin
    if(pending||(inflight&&owner==2))begin incomplete<=1;error_code<=2;active<=0;end
    else begin tracking<=1;count<=0;end
   end
   if(capture)begin
    if(count<9)begin count<=count+1'b1;applied_items<=applied_items+1'b1;end
    else begin incomplete<=1;error_code<=2;active<=0;end
   end
   if((active||stop_pending)&&tracking&&publish_ok)begin
    terminal<=cell_data(25,1,255,255,frame_id,0,{16'd0,batch_timestamp,subcycle});
    pending<=1;tracking<=0;published_batches<=published_batches+1'b1;
   end
   if(batch_abort&&(active||arming||pending||inflight||stop_pending))begin
    incomplete<=1;error_code<=8'd5;active<=0;first_missing_frame<=frame_id;
   end
   if(batch_abort&&tracking)begin count<=0;tracking<=0;aborted_batches<=aborted_batches+1'b1;end
   if(stop_valid&&active)begin active<=0;stop_pending<=1;end
   if(stop_pending&&stop_delivery_idle&&!pending&&!inflight&&!arming&&!tracking)begin
    terminal<=cell_data(22,1,255,255,frame_id,0,{48'd0,subcycle});count<=0;pending<=1;stop_pending<=0;
   end
   if((capture_fault||audio_reset)&&(active||arming||pending||inflight||stop_pending))begin
    incomplete<=1;error_code<=audio_reset?8'd5:capture_fault_code;active<=0;
   end
   // Finish an accepted RAM transaction, then abandon only unpublished data.
   if(incomplete&&!inflight&&!starting)begin active<=0;arming<=0;pending<=0;tracking<=0;stop_pending<=0;count<=0;snap_wait<=0;end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(tx_read_valid&&tx_index>=tx_count)$fatal(1,"R25_EXEC_INDEX");
  if(capture&&count>=9)$display("R25_EXEC_OVERFLOW");
  if(snapshot_response_valid&&snap_wait&&snapshot_response_slot!=snapshot_query_slot)$fatal(1,"R25_SNAPSHOT_SLOT");
 end
 // synthesis translate_on

endmodule
