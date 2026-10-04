// One 2048x8 synchronous memory: each slot is request[192]+result[64].
// Pending slots are never evicted. Completed slots use oldest admission order.
// All ownership checks include slot/channel/sequence; clearing is session-only.
module s9_command_cache(
 input wire clk,rst,flush,input wire[127:0] session_id,
 input wire request_valid,output wire request_ready,
 input wire[1535:0] request_bytes,input wire[7:0] request_length,
 input wire request_channel,input wire[31:0] request_sequence,
 input wire signed[15:0] request_error,
 input wire lookup_valid,output wire lookup_ready,input wire lookup_channel,lookup_echo,input wire[31:0] lookup_sequence,
 output reg lookup_done,output reg signed[15:0] lookup_error,
 output reg dispatch_valid,input wire dispatch_ready,
 output reg[2:0] dispatch_slot,output reg[1535:0] dispatch_bytes,output reg[7:0] dispatch_length,
 input wire update_valid,output wire update_ready,input wire[2:0] update_slot,
 input wire update_channel,input wire[31:0] update_sequence,input wire[511:0] update_result,input wire update_final,
 output reg reply_valid,input wire reply_ready,output reg[511:0] reply_result,
 output reg error_valid,output reg signed[15:0] error_code,output reg error_channel,output reg[31:0] error_sequence,
 output wire[3:0] credit,
 output reg[31:0] admitted_count,retry_count,rejected_count,stale_updates
);
 localparam IDLE=0,WRITE_REQUEST=1,WRITE_RESULT=2,DISPATCH=3,COMPARE_WAIT=4,COMPARE=5,READ_WAIT=6,READ_RESULT=7;
 reg[2:0] state,slot;reg[7:0] cursor;
 reg[7:0] memory[0:2047];reg[7:0] read_byte;reg[10:0] read_address;
 reg[7:0] valid,pending,channels;reg[31:0] sequences[0:7];reg[7:0] lengths[0:7],phases[0:7];
 reg[63:0] ages[0:7],next_age;reg[31:0] highwater[0:1];
 reg[511:0] result_buffer;reg new_request;reg final_result,is_lookup,echo_lookup;
 reg found_lookup;reg[2:0] lookup_slot;
 reg found_match,found_free,found_finished;reg[2:0] match_slot,victim;reg[63:0] oldest;reg[3:0] free_slots;
  integer k,j;
 always @*begin
  found_match=0;found_free=0;found_finished=0;match_slot=0;victim=0;oldest=64'hffffffffffffffff;free_slots=0;
  found_lookup=0;lookup_slot=0;
   for(j=0;j<8;j=j+1)begin
   if(valid[j]&&channels[j]==request_channel&&sequences[j]==request_sequence)begin found_match=1;match_slot=j;end
   if(valid[j]&&channels[j]==lookup_channel&&sequences[j]==lookup_sequence)begin found_lookup=1;lookup_slot=j;end
   if(!valid[j]&&!found_free)begin found_free=1;victim=j;end
   if(!pending[j])free_slots=free_slots+1'b1;
  end
   if(!found_free)for(j=0;j<8;j=j+1)
   if(valid[j]&&!pending[j]&&(!found_finished||ages[j]<oldest))begin found_finished=1;victim=j;oldest=ages[j];end
 end
 assign credit=free_slots;
 // An offered dispatch owns dispatch_bytes until handshake, independently of
 // the RAM sequencer. Older results/lookups must progress while it is stalled.
 assign request_ready=!rst&&!flush&&state==IDLE&&!dispatch_valid&&!reply_valid&&!update_valid&&!lookup_valid;
 assign update_ready=!rst&&!flush&&state==IDLE&&!reply_valid;
 assign lookup_ready=!rst&&!flush&&state==IDLE&&!reply_valid&&!update_valid;
 always @*read_address={slot,8'd0}+((state==READ_WAIT||state==READ_RESULT)?8'd192:8'd0)+cursor;
 function[31:0] crcbyte(input[31:0] c,input[7:0] b);
  reg[31:0] v;integer i;begin v=c^b;for(i=0;i<8;i=i+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
  function[511:0] accepted_status(input[127:0] sid,input ch,input[31:0] seqnum,input[7:0] credits,input signed[15:0] err);
  reg[511:0] b;reg[31:0] crc;integer i;begin
   b=0;b[31:0]=32'h54533953;b[39:32]=1;b[47:40]=2;b[55:48]=credits;
   b[191:64]=sid;b[223:192]=seqnum;b[231:224]={7'd0,ch};b[239:232]=(err==0)?2:7;b[255:240]=err;
   crc=32'hffffffff;for(i=0;i<60;i=i+1)crc=crcbyte(crc,b[i*8+:8]);b[511:480]=~crc;accepted_status=b;
  end
 endfunction
 always @(posedge clk)begin
  read_byte<=memory[read_address];
  if(rst)begin
   state<=IDLE;slot<=0;cursor<=0;valid<=0;pending<=0;channels<=0;next_age<=1;highwater[0]<=0;highwater[1]<=0;
   result_buffer<=0;new_request<=0;final_result<=0;is_lookup<=0;echo_lookup<=0;lookup_done<=0;lookup_error<=0;
   dispatch_valid<=0;dispatch_slot<=0;dispatch_bytes<=0;dispatch_length<=0;
   reply_valid<=0;reply_result<=0;error_valid<=0;error_code<=0;error_channel<=0;error_sequence<=0;
   admitted_count<=0;retry_count<=0;rejected_count<=0;stale_updates<=0;
   for(k=0;k<8;k=k+1)begin sequences[k]<=0;lengths[k]<=0;phases[k]<=0;ages[k]<=0;end
  end else if(flush)begin
   state<=IDLE;valid<=0;pending<=0;next_age<=1;highwater[0]<=0;highwater[1]<=0;
   dispatch_valid<=0;reply_valid<=0;error_valid<=0;lookup_done<=0;
  end else begin
   error_valid<=0;lookup_done<=0;
   if(reply_valid&&reply_ready)reply_valid<=0;
   if(dispatch_valid&&dispatch_ready)dispatch_valid<=0;
   case(state)
   IDLE:begin
    if(update_valid&&update_ready)begin
     if(!valid[update_slot]||!pending[update_slot]||channels[update_slot]!=update_channel||sequences[update_slot]!=update_sequence||
        update_result[223:192]!=update_sequence||update_result[231:224]!={7'd0,update_channel}||
        update_result[191:64]!=session_id||update_result[239:232]<phases[update_slot]||update_result[239:232]>7)
      stale_updates<=stale_updates+1'b1;
     else begin
      slot<=update_slot;cursor<=0;result_buffer<=update_result;new_request<=0;final_result<=update_final;state<=WRITE_RESULT;
     end
    end else if(lookup_valid&&lookup_ready)begin
     if(!found_lookup)begin lookup_done<=1;lookup_error<=-13;end
     else begin slot<=lookup_slot;cursor<=0;is_lookup<=1;echo_lookup<=lookup_echo;lookup_error<=0;state<=READ_WAIT;end
    end else if(request_valid&&request_ready)begin
     error_channel<=request_channel;error_sequence<=request_sequence;
     dispatch_bytes<=request_bytes;dispatch_length<=request_length;cursor<=0;
     if(request_length<36||request_length>192||request_sequence==0)begin
      error_valid<=1;error_code<=-1;rejected_count<=rejected_count+1'b1;
     end else if(found_match)begin
      if(lengths[match_slot]!=request_length)begin error_valid<=1;error_code<=-9;rejected_count<=rejected_count+1'b1;end
      else begin slot<=match_slot;state<=COMPARE_WAIT;end
     end else if(request_sequence<=highwater[request_channel])begin
      error_valid<=1;error_code<=-13;rejected_count<=rejected_count+1'b1;
     end else if((!found_free&&!found_finished)||next_age==64'hffffffffffffffff)begin
      error_valid<=1;error_code<=-7;rejected_count<=rejected_count+1'b1;
     end else begin
      slot<=victim;dispatch_slot<=victim;new_request<=request_error==0;final_result<=request_error!=0;
      valid[victim]<=1;pending[victim]<=1;channels[victim]<=request_channel;sequences[victim]<=request_sequence;
      lengths[victim]<=request_length;ages[victim]<=next_age;next_age<=next_age+1'b1;
      highwater[request_channel]<=request_sequence;
      result_buffer<=accepted_status(session_id,request_channel,request_sequence,{4'd0,free_slots-1'b1},request_error);
      admitted_count<=admitted_count+1'b1;state<=WRITE_REQUEST;
     end
    end
   end
   WRITE_REQUEST:begin
    memory[{slot,8'd0}+cursor]<=dispatch_bytes[cursor*8+:8];
    if(cursor+1'b1==dispatch_length)begin cursor<=0;state<=WRITE_RESULT;end else cursor<=cursor+1'b1;
   end
   WRITE_RESULT:begin
    memory[{slot,8'd0}+11'd192+cursor]<=result_buffer[cursor*8+:8];
    if(cursor==63)begin
     phases[slot]<=result_buffer[239:232];pending[slot]<=!final_result;
     reply_result<=result_buffer;reply_valid<=1;
     if(new_request)dispatch_valid<=1;
     state<=IDLE;
    end else cursor<=cursor+1'b1;
   end
   COMPARE_WAIT:state<=COMPARE;
   COMPARE:begin
    if(read_byte!=dispatch_bytes[cursor*8+:8])begin error_valid<=1;error_code<=-9;rejected_count<=rejected_count+1'b1;state<=IDLE;end
    else if(cursor+1'b1==dispatch_length)begin retry_count<=retry_count+1'b1;cursor<=0;is_lookup<=0;state<=READ_WAIT;end
    else begin cursor<=cursor+1'b1;state<=COMPARE_WAIT;end
   end
   READ_WAIT:state<=READ_RESULT;
   READ_RESULT:begin
    result_buffer[cursor*8+:8]<=read_byte;
    if(cursor==63)begin
     reply_result<={read_byte,result_buffer[503:0]};
     if(is_lookup)begin lookup_done<=1;if(echo_lookup)reply_valid<=1;end else reply_valid<=1;
     state<=IDLE;
    end
    else begin cursor<=cursor+1'b1;state<=READ_WAIT;end
   end
   default:state<=IDLE;
   endcase
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if((^{flush,request_valid,dispatch_ready,update_valid,reply_ready,lookup_valid})===1'bx)$fatal(1,"S9_CACHE_CONTROL_XZ");
  if(request_valid&&(^({request_bytes,request_length,request_channel,request_sequence,request_error}))===1'bx)$fatal(1,"S9_CACHE_REQUEST_XZ");
  if(lookup_valid&&(^({lookup_channel,lookup_sequence,lookup_echo}))===1'bx)$fatal(1,"S9_CACHE_LOOKUP_XZ");
  if(update_valid&&(^({update_slot,update_channel,update_sequence,update_result,update_final}))===1'bx)$fatal(1,"S9_CACHE_UPDATE_XZ");
 end
 // synthesis translate_on
endmodule
