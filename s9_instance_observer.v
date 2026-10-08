// Current-session ownership metadata only. Allocation decisions remain frozen.
// Captures press IDs against actual newly published tokens, including two ONs
// of one key separated by OFF in the same packet. Release ownership is retained.
module s9_instance_observer(
 input wire clk,rst,session_flush,session_ready,
 input wire allocator_publish,remote_dispatch_done,
 // Passive original decision edge. These inputs never feed Allocator state.
 input wire apply_batch_begin,apply_valid,input wire [7:0] apply_outcome,
 input wire [95:0] apply_item,input wire [3:0] apply_lane,input wire [5:0] apply_slot,
 input wire[31:0] slot_valid,slot_cancel,
 input wire[127:0] slot_sources,input wire[255:0] slot_keys,
 input wire[2047:0] slot_tokens,slot_ids,input wire[511:0] slot_generations,
 input wire[904:0] event_packet,input wire[575:0] event_press_ids,
 input wire[7:0] query_key,input wire[63:0] query_press_id,
 output wire stable,output reg found,output reg[4:0] query_slot,
 output reg[63:0] query_instance_id,output reg[15:0] query_generation,
 input wire[63:0] pan_instance_id,input wire[15:0] pan_generation,
 output reg pan_found,output reg[4:0] pan_slot,
 output wire[31:0] owned_slots
);
 function equal64(input [63:0] a,b);
  reg [31:0] matched /* synthesis syn_keep=1 */;integer k;
  begin
   for(k=0;k<32;k=k+1)matched[k]=(a[k*2+:2]==b[k*2+:2]);
   equal64=&matched;
  end
 endfunction
 function equal16(input [15:0] a,b);
  reg [7:0] matched /* synthesis syn_keep=1 */;integer k;
  begin
   for(k=0;k<8;k=k+1)matched[k]=(a[k*2+:2]==b[k*2+:2]);
   equal16=&matched;
  end
 endfunction
 reg[31:0] owned,published_cancel;
 reg[63:0] press_id[0:31],pending_press_id[0:31];reg[31:0] pending_on;
 wire [63:0] packet_press_words[0:8];
 generate for(genvar p=0;p<9;p=p+1)begin: fixed_press_word
  assign packet_press_words[p]=event_press_ids[p*64+:64];
 end endgenerate
 wire capture_on=apply_valid && apply_outcome==1 && apply_item[31:28]==2;
 generate for(genvar s=0;s<32;s=s+1)begin: fixed_pending_press
  always @(posedge clk)if(!rst&&!session_flush&&capture_on&&apply_slot==s)
   pending_press_id[s]<=packet_press_words[apply_lane];
 end endgenerate
 reg published,remote_published;
 assign stable=!allocator_publish&&!published;
 assign owned_slots=owned;
 integer i,j;
 always @(posedge clk)begin
  if(rst||session_flush)begin owned<=0;published<=0;remote_published<=0;published_cancel<=0;pending_on<=0;end
  else begin
   published<=allocator_publish;remote_published<=remote_dispatch_done;
   if(allocator_publish)published_cancel<=slot_cancel;
   if(apply_batch_begin)pending_on<=0;
   if(capture_on)pending_on[apply_slot[4:0]]<=1;
   if(published&&remote_published&&session_ready)
    for(i=0;i<32;i=i+1)if(published_cancel[i]&&slot_valid[i]&&slot_sources[i*4+:4]==2&&pending_on[i])begin
     owned[i]<=1;press_id[i]<=pending_press_id[i];
    end
   for(i=0;i<32;i=i+1)if(slot_cancel[i]||!slot_valid[i])owned[i]<=0;
  end
 end
 // Preserve first query match and last Pan match for arbitrary match sets.
 // Generate the one-hot query winner before selecting its full identity.
 function equal8(input [7:0] a,b);
  reg [3:0] matched /* synthesis syn_keep=1 */;integer k;
  begin for(k=0;k<4;k=k+1)matched[k]=(a[k*2+:2]==b[k*2+:2]);equal8=&matched;end
 endfunction
 reg [31:0] query_matches,pan_matches;
 wire [31:0] query_winner;
 generate for(genvar k=0;k<32;k=k+1)begin: first_query_winner
  if(k==0)assign query_winner[k]=query_matches[k];
  else assign query_winner[k]=query_matches[k] && !(|query_matches[k-1:0]);
 end endgenerate
 always @*begin
  query_matches=0;pan_matches=0;
  if(session_ready&&stable)for(integer k=0;k<32;k=k+1)begin
   if(owned[k]&&slot_valid[k]&&!slot_cancel[k]&&slot_sources[k*4+:4]==2)begin
    if(equal8(slot_keys[k*8+:8],query_key)&&equal64(press_id[k],query_press_id))query_matches[k]=1;
    if(equal64(slot_ids[k*64+:64],pan_instance_id)&&equal16(slot_generations[k*16+:16],pan_generation))pan_matches[k]=1;
   end
  end
 end
 always @*begin
  found=|query_matches;query_slot=0;query_instance_id=0;query_generation=0;
  pan_found=|pan_matches;pan_slot=0;
  for(integer k=0;k<32;k=k+1)begin
   if(query_winner[k])begin
    query_slot=query_slot|5'(k);query_instance_id=query_instance_id|slot_ids[k*64+:64];
    query_generation=query_generation|slot_generations[k*16+:16];
   end
   if(pan_matches[k])pan_slot=k;
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if((^{session_flush,session_ready,allocator_publish,remote_dispatch_done})===1'bx)$fatal(1,"S9_IDENTITY_CONTROL_XZ");
  if(allocator_publish&&(^({slot_valid,slot_cancel,slot_sources,slot_keys,slot_tokens,slot_ids,slot_generations}))===1'bx)$fatal(1,"S9_IDENTITY_PUBLICATION_XZ");
  if(remote_dispatch_done&&(^({event_packet,event_press_ids}))===1'bx)$fatal(1,"S9_IDENTITY_EVENT_XZ");
  if($isunknown({apply_batch_begin,apply_valid}))$fatal(1,"S9_IDENTITY_APPLY_CONTROL_XZ");
  if(capture_on)begin
   if(apply_slot>=32||apply_lane>=9)$fatal(1,"S9_IDENTITY_APPLY_RANGE");
   if(!event_packet[864+apply_lane] || apply_item!==event_packet[apply_lane*96+:96])
    $fatal(1,"S9_IDENTITY_REMOTE_ITEM_UNALIGNED");
   if($isunknown({apply_item,apply_outcome,apply_slot,apply_lane,packet_press_words[apply_lane]}))
    $fatal(1,"S9_IDENTITY_APPLY_DATA_XZ");
  end
 end
 // synthesis translate_on
endmodule
