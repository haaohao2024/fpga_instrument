// Current-session ownership metadata only. Allocation decisions remain frozen.
// Captures press IDs against actual newly published tokens, including two ONs
// of one key separated by OFF in the same packet. Release ownership is retained.
module s9_instance_observer(
 input wire clk,rst,session_flush,session_ready,
 input wire allocator_publish,remote_dispatch_done,
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
 reg[31:0] owned,published_cancel;
 reg[63:0] press_id[0:31];
 reg published,remote_published;
 assign stable=!allocator_publish&&!published;
 assign owned_slots=owned;
 integer i,j;
 always @(posedge clk)begin
  if(rst||session_flush)begin owned<=0;published<=0;remote_published<=0;published_cancel<=0;end
  else begin
   published<=allocator_publish;remote_published<=remote_dispatch_done;
   if(allocator_publish)published_cancel<=slot_cancel;
   if(published&&remote_published&&session_ready)
    for(i=0;i<32;i=i+1)if(published_cancel[i]&&slot_valid[i]&&slot_sources[i*4+:4]==2)
     for(j=0;j<9;j=j+1)
      if(event_packet[864+j]&&event_packet[j*96+24+:4]==1&&event_packet[j*96+32+:64]==slot_tokens[i*64+:64])begin
       owned[i]<=1;press_id[i]<=event_press_ids[j*64+:64];
      end
   for(i=0;i<32;i=i+1)if(slot_cancel[i]||!slot_valid[i])owned[i]<=0;
  end
 end
 always @*begin
  found=0;query_slot=0;query_instance_id=0;query_generation=0;pan_found=0;pan_slot=0;
  if(session_ready&&stable)for(integer k=0;k<32;k=k+1)begin
   if(owned[k]&&slot_valid[k]&&!slot_cancel[k]&&slot_sources[k*4+:4]==2)begin
    if(slot_keys[k*8+:8]==query_key&&press_id[k]==query_press_id&&!found)begin
     found=1;query_slot=k;query_instance_id=slot_ids[k*64+:64];query_generation=slot_generations[k*16+:16];
    end
    if(slot_ids[k*64+:64]==pan_instance_id&&slot_generations[k*16+:16]==pan_generation)begin pan_found=1;pan_slot=k;end
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if((^{session_flush,session_ready,allocator_publish,remote_dispatch_done})===1'bx)$fatal(1,"S9_IDENTITY_CONTROL_XZ");
  if(allocator_publish&&(^({slot_valid,slot_cancel,slot_sources,slot_keys,slot_tokens,slot_ids,slot_generations}))===1'bx)$fatal(1,"S9_IDENTITY_PUBLICATION_XZ");
  if(remote_dispatch_done&&(^({event_packet,event_press_ids}))===1'bx)$fatal(1,"S9_IDENTITY_EVENT_XZ");
 end
 // synthesis translate_on
endmodule
