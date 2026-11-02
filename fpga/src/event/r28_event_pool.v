// Three streaming producers share one 32-bit RAM write port. Committed
// descriptors retain the original five global / eight local batch credits.
module r28_event_pool #(parameter integer LOCAL_BUFFER=1,FAST_READ=0,RAW_SCORE=0)(
 input wire clk,rst,
 input wire[1:0] score_owner,input wire[2:0] score_timbre,
 output wire[2:0] event_timbre,
 input wire[2:0] write_valid,output wire[2:0] write_ready,
 input wire[11:0] write_index,input wire[287:0] write_data,
 input wire[2:0] commit_valid,output wire[2:0] commit_ready,
 input wire[122:0] commit_header,input wire phone_abort,score_urgent,discard_local,
 output wire discarded,output reg rejected,output reg[1:0] rejected_source,output wire event_valid,input wire event_ready,retire,
 output wire[40:0] event_header,output wire[3:0] event_source,
 input wire item_request,input wire[3:0] item_index,output wire item_ready,
 output reg item_response,output wire[95:0] item_data,
 output reg[3:0] local_occupancy,output reg[2:0] occupancy
);
 reg[40:0] headers[0:15] /* synthesis syn_ramstyle="distributed_ram" */;
 reg[2:0] timbres[0:15];
 reg[1:0] sources[0:15] /* synthesis syn_ramstyle="distributed_ram" */;
 reg[15:0] free_rows;reg[2:0] reserved;reg[3:0] producer_rows[0:2];
 reg[8:0] written[0:2],bad[0:2];
 reg[3:0] local_rows[0:7],global_rows[0:4];
 reg[2:0] local_read,local_write,global_read,global_write;
 reg owned;reg[3:0] free_row;reg free_found;
 reg[1:0] write_left;reg[8:0] write_address;reg[95:0] write_buffer;
 reg[2:0] read_phase;reg[8:0] read_address;reg[31:0] ram_q;
 reg[95:0] read_buffer;
 reg[95:0] slow_item_data;wire[95:0] fast_item_data;
 assign item_data=FAST_READ?(occupancy!=0?fast_item_data:96'd0):slow_item_data;
 always @*begin
  free_found=0;free_row=0;
  for(integer s=15;s>=0;s--)if(free_rows[s])begin free_found=1;free_row=4'(s);end
 end
 function bad_item(input[95:0] w);
  bad_item=w[0]||w[27:24]<1||w[27:24]>4||
    (w[27:24]==4&&(w[23:16]!=255||w[15:9]!=0))||(w[27:24]!=4&&w[95:32]==0);
 endfunction
 function[8:0] address(input[3:0] row,input[3:0] index);
  address={row,5'd0}+{5'd0,index}+({5'd0,index}<<1);
 endfunction
 wire[3:0] head=global_rows[global_read];
 assign event_header=occupancy!=0?headers[head]:41'd0;
 assign event_source=occupancy!=0?{2'd0,sources[head]}:4'd0;
 assign event_timbre=RAW_SCORE&&occupancy!=0&&sources[head]==3?timbres[head]:3'd0;
 assign discarded=!rst&&occupancy!=0&&!owned&&discard_local&&event_source==0;
 // Validation is performed once, before a producer descriptor is committed.
 wire first_valid,first_ready,choose_score;
 performance_event_arbiter #(.WIDTH(1)) choice(.clk(clk),.rst(rst),
 .s0_valid(LOCAL_BUFFER?(local_occupancy!=0):(commit_valid[0]&&reserved[0]&&write_left==0&&!write_valid[0]&&!discard_local)),.s0_data(1'b0),.s0_ready(),
 .s1_valid(commit_valid[1]&&reserved[1]&&write_left==0&&!write_valid[1]),.s1_data(1'b1),.s1_ready(),
 .m_valid(first_valid),.m_ready(first_ready),.m_data(choose_score));
 wire choose_phone=!first_valid&&!score_urgent;
 wire space=occupancy<5||retire||discarded;
 wire local_commit=!rst&&commit_valid[0]&&commit_ready[0];
 wire promote=LOCAL_BUFFER&&!rst&&space&&first_valid&&!choose_score;
 wire score_commit=!rst&&space&&first_valid&&choose_score&&!local_commit;
 wire phone_commit=!rst&&space&&choose_phone&&commit_valid[2]&&reserved[2]&&write_left==0&&!write_valid[2]&&!phone_abort&&!local_commit;
 assign commit_ready[0]=!rst&&!discard_local&&reserved[0]&&write_left==0&&!write_valid[0]&&
   (LOCAL_BUFFER?(local_occupancy<8||promote):(space&&first_valid&&!choose_score));
 assign commit_ready[1]=!rst&&space&&first_valid&&choose_score&&!local_commit;
 assign commit_ready[2]=!rst&&space&&choose_phone&&reserved[2]&&write_left==0&&!write_valid[2]&&!phone_abort&&!local_commit;
 wire[2:0] committing={phone_commit,score_commit,local_commit};
 wire[1:0] committer=local_commit?0:score_commit?1:2;
 wire[2:0] malformed;
 generate for(genvar p=0;p<3;p++)begin: validation
  wire[8:0] mask=commit_header[p*41+:9];
  assign malformed[p]=mask==0|||(mask&(~written[p]|bad[p]));
 end endgenerate
 wire malformed_commit=|(committing&malformed);
 wire admit=promote||(!LOCAL_BUFFER&&local_commit&&!malformed[0])||(score_commit&&!malformed[1])||(phone_commit&&!malformed[2]);
 wire local_push=LOCAL_BUFFER&&local_commit&&!malformed[0];
 assign first_ready=promote||score_commit||(!LOCAL_BUFFER&&local_commit);
 wire[3:0] admitted_row=promote?local_rows[local_read]:!LOCAL_BUFFER&&local_commit?producer_rows[0]:phone_commit?producer_rows[2]:producer_rows[1];
 wire release_head=retire||discarded;
 assign event_valid=!rst&&occupancy!=0&&!owned&&!discarded;
 wire storage_idle=!rst&&write_left==0;
 assign write_ready[0]=storage_idle&&!discard_local&&!committing[0]&&(reserved[0]||(free_found&&(!LOCAL_BUFFER||local_occupancy<8)));
 wire w0=write_valid[0]&&write_ready[0];
 assign write_ready[1]=storage_idle&&!w0&&!committing[1]&&(reserved[1]||free_found);
 wire w1=write_valid[1]&&write_ready[1];
 assign write_ready[2]=storage_idle&&!w0&&!w1&&!committing[2]&&!phone_abort&&(reserved[2]||free_found);
 wire w2=write_valid[2]&&write_ready[2];
 wire writing=w0||w1||w2;wire[1:0] writer=w0?0:w1?1:2;
 wire[3:0] wi=write_index[writer*4+:4];wire[95:0] wd=write_data[writer*96+:96];
 wire[3:0] row=reserved[writer]?producer_rows[writer]:free_row;
 wire allocate=writing&&!reserved[writer];
 reg[15:0] freeing;
 always @*begin
  freeing=release_head?(16'h1<<head):16'd0;
  for(integer p=0;p<3;p++)if(committing[p]&&malformed[p])freeing=freeing|(16'h1<<producer_rows[p]);
  if(phone_abort&&reserved[2])freeing=freeing|(16'h1<<producer_rows[2]);
  if(discard_local&&reserved[0])freeing=freeing|(16'h1<<producer_rows[0]);
 end
 // Independent RAM read and write ports never address the same owned row.
 generate if(FAST_READ)begin: wide_memory
  reg[95:0] body[0:255] /* synthesis syn_ramstyle="block_ram" */;
  reg[95:0] q;
  always @(posedge clk)begin
   q<=body[{head,item_index}];
   if(writing)body[{row,wi}]<=wd;
  end
  assign fast_item_data=q;
 end else begin: narrow_memory
  reg[31:0] body[0:511] /* synthesis syn_ramstyle="block_ram" */;
  always @(posedge clk)begin
   ram_q<=body[read_address];
   if(!rst&&write_left!=0)body[write_address]<=write_buffer[31:0];
  end
  assign fast_item_data=0;
 end endgenerate
 assign item_ready=!rst&&owned&&(FAST_READ||read_phase==0)&&!retire;
 always @(posedge clk)begin
  item_response<=0;
  rejected<=malformed_commit;
  if(malformed_commit)rejected_source<=committer;
  if(rst)begin
   rejected<=0;rejected_source<=0;
   free_rows<=16'hffff;reserved<=0;owned<=0;
   local_read<=0;local_write<=0;global_read<=0;global_write<=0;local_occupancy<=0;occupancy<=0;
   write_left<=0;write_address<=0;write_buffer<=0;read_phase<=0;read_address<=0;read_buffer<=0;slow_item_data<=0;
   for(integer p=0;p<3;p++)begin producer_rows[p]<=0;written[p]<=0;bad[p]<=0;end
  end else begin
   free_rows<=(free_rows|freeing)&~(allocate?(16'h1<<free_row):16'd0);
   if(writing)begin
    write_address<=address(row,wi);write_left<=FAST_READ?0:3;write_buffer<=wd;
    reserved[writer]<=1;producer_rows[writer]<=row;
    written[writer]<=(reserved[writer]?written[writer]:9'd0)|(9'b1<<wi);
    bad[writer]<=((reserved[writer]?bad[writer]:9'd0)&~(9'b1<<wi))|(bad_item(wd)?(9'b1<<wi):9'd0);
   end else if(write_left!=0)begin write_left<=write_left-1'b1;write_address<=write_address+1'b1;write_buffer<=write_buffer>>32;end
   if(|committing)begin
    reserved[committer]<=0;
    headers[producer_rows[committer]]<=commit_header[committer*41+:41];sources[producer_rows[committer]]<=RAW_SCORE&&committer==1?score_owner:committer;
    if(RAW_SCORE&&committer==1)timbres[producer_rows[committer]]<=score_timbre;
   end
   if(phone_abort)reserved[2]<=0;
   if(discard_local)reserved[0]<=0;
   if(local_push)begin local_rows[local_write]<=producer_rows[0];local_write<=local_write+1'b1;end
   if(promote)local_read<=local_read+1'b1;
   case({local_push,promote})
    2'b10:local_occupancy<=local_occupancy+1'b1;
    2'b01:local_occupancy<=local_occupancy-1'b1;
    default:begin end
   endcase
   if(admit)begin global_rows[global_write]<=admitted_row;global_write<=global_write==4?0:global_write+1'b1;end
   if(event_valid&&event_ready)owned<=1;
   if(release_head)begin owned<=0;global_read<=global_read==4?0:global_read+1'b1;end
   case({admit,release_head})
    2'b10:occupancy<=occupancy+1'b1;
    2'b01:occupancy<=occupancy-1'b1;
    default:begin end
   endcase
   if(FAST_READ)item_response<=item_request&&item_ready;
   else if(item_request&&item_ready)begin read_phase<=1;read_address<=address(head,item_index);end
   else if(read_phase!=0)begin
    if(read_phase==4)begin slow_item_data<={ram_q,read_buffer[95:32]};item_response<=1;read_phase<=0;end
    else begin
     if(read_phase!=1)read_buffer<={ram_q,read_buffer[95:32]};
     if(read_phase<3)read_address<=read_address+1'b1;
     read_phase<=read_phase+1'b1;
    end
   end
   if(retire||discarded)begin read_phase<=0;item_response<=0;end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(local_occupancy>8||occupancy>5)$fatal(1,"R28_POOL_CAPACITY");
  if(retire&&(!owned||occupancy==0))$fatal(1,"R28_POOL_RETIRE");
  if(allocate&&!free_found)$fatal(1,"R28_POOL_OVERWRITE");
  if(writing&&wi>=9)$fatal(1,"R28_POOL_WRITE_INDEX");
  if(item_request&&item_ready&&(item_index>=9||!event_header[item_index]))$fatal(1,"R28_POOL_READ_INDEX");
 end
 // synthesis translate_on
endmodule
