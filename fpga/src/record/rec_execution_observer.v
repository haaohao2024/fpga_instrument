module rec_execution_observer(
 input wire pan_applied,input wire[5:0] pan_applied_slot,input wire[314:0] pan_applied_word,
 input wire clk,rst,audio_reset,start_valid,stop_valid,capture_fault,
 input wire[7:0] capture_fault_code,input wire stop_delivery_idle,
 input wire[63:0] start_record_id,frame_id,input wire[15:0] subcycle,
 input wire allocator_busy,batch_begin,publish_ok,batch_abort,input wire[31:0] batch_timestamp,
 input wire fact_valid,input wire[95:0] fact_item,input wire[7:0] fact_outcome,
 input wire[5:0] fact_slot,input wire fact_steal,input wire[314:0] fact_before,fact_after,
 input wire[63:0] fact_frame,input wire[15:0] fact_subcycle,input wire reclaim_batch_busy,
 input wire[63:0] slot_valid,slot_gate,
 output wire[63:0] allocated_persistent_id,
 output wire snapshot_query_valid,input wire snapshot_query_ready,output wire[5:0] snapshot_query_slot,
 input wire snapshot_response_valid,input wire[5:0] snapshot_response_slot,input wire[314:0] snapshot_response_word,
 output reg active,arming,incomplete,output reg[7:0] error_code,output reg[63:0] first_missing_frame,
 output wire tx_valid,output reg[5:0] tx_count,input wire[5:0] tx_index,output wire[255:0] tx_cell,
 input wire tx_read_valid,input wire[15:0] tx_read_epoch,
 output reg tx_response_valid,output reg[5:0] tx_response_index,output reg[15:0] tx_response_epoch,
 input wire tx_ready,tx_done,output reg[31:0] published_batches,aborted_batches,applied_items,initial_instances,
 output reg[63:0] persistent_id_next,output wire observer_idle,output wire pipeline_empty
);
 // Facts are collected while the unpublished working bank is computed.
 // One frame marker publishes their common audible timestamp. The musical
 // descriptor retains every EVR2 field; external identities stay in Allocator.
 reg[31:0] memory[0:511] /* synthesis syn_ramstyle="block_ram" */;
 reg write_bank,read_bank;reg[1:0] pending;
 reg[7:0] write_count,bank_count[0:1];reg[6:0] offset;
 reg[63:0] bank_frame[0:1];reg[15:0] bank_subcycle[0:1];reg[31:0] bank_timestamp[0:1];
 reg second_write;reg[31:0] write_high;reg[8:0] write_address;
 reg[8:0] read_address;reg[31:0] ram_q,read_low;
 reg[2:0] read_phase;reg[5:0] request_index;reg[15:0] request_epoch;
 reg[63:0] request_frame;reg[15:0] request_subcycle;
 reg inflight,stop_pending,stop_cell;reg[1:0] owner;
 reg[63:0] initial_mask;reg[6:0] snap_index;
 reg[58:0] snap_word;reg snap_loaded,snap_wait;
 reg[63:0] snap_frame,stop_frame;reg[15:0] snap_subcycle,stop_subcycle;
 reg[223:0] response;
 wire starting=start_valid&&!active&&!arming&&pending==0&&!inflight&&!allocator_busy&&start_record_id!=0;
 wire musical=fact_valid&&fact_outcome>=1&&fact_outcome<=4;
 wire capture=(active||stop_pending)&&(musical||pan_applied)&&!batch_abort&&!incomplete;
 wire[314:0] selected=pan_applied?pan_applied_word:fact_outcome==1?fact_after:fact_before;
 wire[63:0] descriptor={pan_applied?1'b0:fact_steal,pan_applied?3'd5:fact_outcome[2:0],
  pan_applied?3'h7:fact_item[30:28],pan_applied?8'hff:fact_item[23:16],
  pan_applied?pan_applied_slot:fact_slot[5:0],selected[58:43],selected[12:4],selected[30:28],
  pan_applied?8'd0:fact_item[8:1],pan_applied?7'd0:fact_item[15:9]};
 wire capture_ok=capture&&!pending[write_bank]&&!second_write&&write_count<128;
 wire publishing=(active||stop_pending)&&publish_ok&&write_count!=0&&!incomplete;
 wire[7:0] remaining=bank_count[read_bank]-{1'b0,offset};
 wire[3:0] chunk=remaining>9?4'd9:remaining[3:0];
 wire[1:0] current=arming?2'd1:pending[read_bank]?2'd2:2'd3;
 wire[1:0] selected_owner=inflight?owner:current;
 assign allocated_persistent_id=0;
 assign pipeline_empty=!arming&&pending==0&&!inflight&&!stop_pending&&!stop_cell&&write_count==0&&!second_write;
 assign observer_idle=!active&&pipeline_empty;
 assign tx_valid=!incomplete&&!inflight&&(arming?(snap_index==0||snap_loaded):(pending[read_bank]||stop_cell));
 always @* tx_count=selected_owner==2?{2'd0,chunk}+6'd1:6'd1;
 assign snapshot_query_valid=arming&&snap_index>0&&!snap_loaded&&!snap_wait&&!incomplete;
 assign snapshot_query_slot=6'(snap_index-1'b1);
 reg[6:0] next_snapshot;
 always @*begin next_snapshot=65;for(integer i=63;i>=0;i--)if(initial_mask[i]&&i+1>snap_index)next_snapshot=i+1;end
 function automatic[223:0] cell_data(input[7:0] typ,flags,src,key,input[63:0] fr,id,p);
  cell_data={p,id,fr,key,src,flags,typ};
 endfunction
 function automatic[223:0] decode(input[63:0] d,fr,input[15:0] sc);
  reg[2:0] kind;reg[7:0] typ,src,key;reg[63:0] id,p;
  begin
   kind=d[62:60];typ=kind==1?4:kind==2?5:kind==3?6:kind==4?7:16;
   src=kind==5?8'hff:{5'd0,d[59:57]};key=d[56:49];
   id=kind==4?0:{41'd0,d[48],1'b1,d[42:27],d[47:43]};
   p=kind==4?{40'd0,d[14:7],sc}:kind==5?{d[47:18],18'd0,sc}:{d[47:0],sc};
   decode=cell_data(typ,(d[63]?8'd32:8'd0)|((kind!=4&&d[48])?8'd64:8'd0),src,key,fr,id,p);
  end
 endfunction
 wire memory_write_enable=!rst&&(capture_ok||second_write);
 wire[8:0] memory_write_address=capture_ok?{write_bank,write_count[6:0],1'b0}:write_address;
 wire[31:0] memory_write_data=capture_ok?descriptor[31:0]:write_high;
 always @(posedge clk)begin
  ram_q<=memory[read_address];
  if(memory_write_enable)memory[memory_write_address]<=memory_write_data;
 end
 assign tx_cell={response[223:32],32'd0,response[31:0]};
 always @(posedge clk)begin
  tx_response_valid<=0;
  if(rst)begin
   read_phase<=0;read_address<=0;read_low<=0;request_index<=0;request_epoch<=0;
   request_frame<=0;request_subcycle<=0;tx_response_index<=0;tx_response_epoch<=0;
  end else begin
   if(tx_read_valid)begin
    request_index<=tx_index;request_epoch<=tx_read_epoch;
    if(selected_owner==2&&tx_index<chunk)begin
     read_address<={read_bank,7'(offset+tx_index),1'b0};read_phase<=1;
     request_frame<=bank_frame[read_bank];request_subcycle<=bank_subcycle[read_bank];
    end else begin
     tx_response_valid<=1;tx_response_index<=tx_index;tx_response_epoch<=tx_read_epoch;
     if(selected_owner==1)begin
      if(snap_index==0)response<=cell_data(1,3,255,255,snap_frame,0,{48'd0,snap_subcycle});
      else response<=cell_data(8,(snap_word[2]?8'd3:8'd19)|(snapshot_query_slot[5]?8'd64:8'd0),{4'd0,snap_word[42:39]},snap_word[38:31],snap_frame,
       {41'd0,snapshot_query_slot[5],1'b1,snap_word[58:43],snapshot_query_slot[4:0]},{snapshot_query_slot[4:0],snap_word[58:43],snap_word[12:4],snap_word[30:28],snap_word[27:20],snap_word[19:13],snap_subcycle});
     end else if(selected_owner==3)response<=cell_data(22,1,255,255,stop_frame,0,{48'd0,stop_subcycle});
     else response<=cell_data(25,1,255,255,bank_frame[read_bank],0,{16'd0,bank_timestamp[read_bank],bank_subcycle[read_bank]});
    end
   end else if(read_phase!=0)begin
    if(read_phase==1)begin read_address<=read_address+1'b1;read_phase<=2;end
    else if(read_phase==2)begin read_low<=ram_q;read_phase<=3;end
    else begin
     response<=decode({ram_q,read_low},request_frame,request_subcycle);
     tx_response_valid<=1;tx_response_index<=request_index;tx_response_epoch<=request_epoch;read_phase<=0;
    end
   end
  end
 end
 always @(posedge clk)begin
  if(rst)begin
   write_bank<=0;read_bank<=0;pending<=0;write_count<=0;offset<=0;
   bank_count[0]<=0;bank_count[1]<=0;bank_frame[0]<=0;bank_frame[1]<=0;
   bank_subcycle[0]<=0;bank_subcycle[1]<=0;bank_timestamp[0]<=0;bank_timestamp[1]<=0;
   second_write<=0;write_high<=0;write_address<=0;
   active<=0;arming<=0;incomplete<=0;error_code<=0;first_missing_frame<=64'hffffffffffffffff;
   inflight<=0;stop_pending<=0;stop_cell<=0;owner<=0;initial_mask<=0;snap_index<=0;snap_word<=0;
   snap_loaded<=0;snap_wait<=0;snap_frame<=0;snap_subcycle<=0;stop_frame<=0;stop_subcycle<=0;
   published_batches<=0;aborted_batches<=0;applied_items<=0;initial_instances<=0;persistent_id_next<=0;
  end else begin
   second_write<=0;
   if(capture_ok)begin
    second_write<=1;write_high<=descriptor[63:32];write_address<={write_bank,write_count[6:0],1'b1};
    write_count<=write_count+1'b1;applied_items<=applied_items+1'b1;
   end
   if(publishing)begin
    pending[write_bank]<=1;bank_count[write_bank]<=write_count;
    bank_frame[write_bank]<=frame_id;bank_subcycle[write_bank]<=subcycle;bank_timestamp[write_bank]<=batch_timestamp;
    write_bank<=~write_bank;write_count<=0;published_batches<=published_batches+1'b1;
   end
   if(snapshot_query_valid&&snapshot_query_ready)snap_wait<=1;
   if(snapshot_response_valid&&snap_wait&&snapshot_response_slot==snapshot_query_slot)begin
    snap_word<=snapshot_response_word[58:0];snap_wait<=0;snap_loaded<=1;
   end
   if(tx_valid&&tx_ready)begin inflight<=1;owner<=current;end
   if(tx_done&&inflight)begin
    inflight<=0;
    if(owner==1)begin
     if(snap_index!=0)initial_instances<=initial_instances+1'b1;
     snap_loaded<=0;snap_wait<=0;snap_index<=next_snapshot;
     if(next_snapshot==65)arming<=0;
    end else if(owner==2)begin
     if(remaining<=9)begin pending[read_bank]<=0;read_bank<=~read_bank;offset<=0;end
     else offset<=offset+chunk;
    end else stop_cell<=0;
   end
   if(starting)begin
    active<=1;arming<=1;incomplete<=0;error_code<=0;first_missing_frame<=64'hffffffffffffffff;
    initial_mask<=slot_valid;snap_frame<=frame_id;snap_subcycle<=subcycle;snap_index<=0;snap_loaded<=0;snap_wait<=0;
    write_bank<=0;read_bank<=0;pending<=0;write_count<=0;offset<=0;stop_pending<=0;stop_cell<=0;
   end
   if(stop_valid&&active)begin active<=0;stop_pending<=1;end
   if(stop_pending&&stop_delivery_idle&&!allocator_busy&&pending==0&&write_count==0&&!inflight&&!arming)begin
    stop_frame<=frame_id;stop_subcycle<=subcycle;stop_cell<=1;stop_pending<=0;
   end
   if(capture&&!capture_ok || publishing&&(second_write||capture||pending[write_bank]))begin
    incomplete<=1;error_code<=2;active<=0;first_missing_frame<=frame_id;
   end
   if(batch_abort&&(active||arming||pending!=0||inflight||stop_pending))begin
    incomplete<=1;error_code<=5;active<=0;first_missing_frame<=frame_id;aborted_batches<=aborted_batches+1'b1;
   end
   if((capture_fault||audio_reset)&&(active||arming||pending!=0||inflight||stop_pending))begin
    incomplete<=1;error_code<=audio_reset?8'd5:capture_fault_code;active<=0;
   end
   if(incomplete&&!inflight&&!starting)begin
    active<=0;arming<=0;pending<=0;write_count<=0;stop_pending<=0;stop_cell<=0;snap_wait<=0;
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(capture&&musical&&fact_item[31:28]>3)$fatal(1,"EVR_SOURCE_RANGE_PROOF");
  if(tx_read_valid&&tx_index>=tx_count)$fatal(1,"R28_JOURNAL_INDEX");
  if(tx_read_valid&&read_phase!=0)$fatal(1,"R28_JOURNAL_OVERLAPPING_READ");
  if(capture&&musical&&pan_applied)$fatal(1,"R28_JOURNAL_TWO_FACTS");
 end
 // synthesis translate_on
endmodule
