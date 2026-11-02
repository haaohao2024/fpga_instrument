

module r22_event_endpoint #(parameter integer SHARED_STORE=0,STREAM_CLEAN=0)(
 output wire cleanup_write_valid,input wire cleanup_write_ready,output wire[95:0] cleanup_write_data,
 input wire fact_valid,input wire[3:0] fact_index,input wire[95:0] fact_item,
 input wire[7:0] fact_outcome,input wire[5:0] fact_slot,input wire[314:0] fact_after,
 input wire maps_release,input wire[3:0] map_address,output reg[95:0] map_data,
 output reg[8:0] map_mask,
 input wire clk,rst,session_flush,session_ready,input wire[127:0] session_id,
 input wire phone_open,phone_close,output wire phone_open_ready,output reg phone_active,phone_close_done,
 input wire command_valid,command_event,output wire command_ready,output wire buffer_busy,
 input wire[2:0] command_slot,input wire[1535:0] command_bytes,input wire[7:0] command_length,
 output wire config_valid,input wire config_ready,output wire[2:0] config_slot,output wire[1535:0] config_bytes,
 output reg result_valid,input wire result_ready,output reg[2:0] result_slot,
 output reg[31:0] result_sequence,output wire[511:0] result_bytes,
 input wire[31:0] sample_time,output wire event_valid,input wire event_ready,
 output wire[904:0] event_packet,output wire[575:0] event_press_ids,input wire dispatch_done,
 output reg[31:0] held_keys,output reg[63:0] next_token,output reg token_exhausted,
 output reg[31:0] cleanup_offs
);
 localparam IDLE=0,OFFER=1,ACCOUNT=2,WAIT_DONE=3,RETIRE=4,CLEAN_READ=5,CLEAN_OFFER=6,CLEAN_WAIT=7;
 reg[2:0] state;reg[95:0] maps[0:8];reg maps_locked;
 wire capture_map=fact_valid && buffer_busy && fact_item[31:28]==2 &&
   fact_item[27:24]==1 && fact_index<9 && fact_outcome==1;
 always @(posedge clk)begin
  map_data<=maps[map_address];
  if(!rst&&capture_map)maps[fact_index]<={8'd1,2'd0,fact_slot,fact_after[58:43],fact_after[122:59]};
  if(rst||session_flush)begin map_mask<=0;maps_locked<=0;end
  else begin
   if(maps_release)maps_locked<=0;
   if(state==IDLE&&command_valid&&command_event&&session_ready&&!result_valid&&!maps_locked)begin
    map_mask<=0;maps_locked<=1;
   end
   if(capture_map)map_mask[fact_index]<=1;
  end
 end
 reg cleanup_stored;
 reg closing,published;reg[3:0] index;reg[5:0] clean_key;
 reg[31:0] timestamp;reg[63:0] release_tokens[0:31],release_read;
 wire[3:0] count=command_bytes[35:32];
 wire[95:0] record_items[0:8];
 wire accounting=SHARED_STORE?(fact_valid&&buffer_busy&&fact_item[31:28]==2):(state==ACCOUNT);
 wire[95:0] item=SHARED_STORE?fact_item:record_items[index];
 wire[3:0] kind=item[27:24];wire[4:0] key=item[20:16];
 wire clean=state==CLEAN_READ||state==CLEAN_OFFER||state==CLEAN_WAIT;
 wire[863:0] items;wire[575:0] presses;
 for(genvar i=0;i<9;i=i+1)begin: unpack
  assign items[i*96+:96]=SHARED_STORE?96'd0:command_bytes[64+i*96+:96];
  assign record_items[i]=SHARED_STORE?96'd0:command_bytes[64+i*96+:96];
  assign presses[i*64+:64]=64'd0;
 end
 assign buffer_busy=state==OFFER||state==ACCOUNT||state==WAIT_DONE||state==RETIRE;
 assign phone_open_ready=!rst&&!phone_active&&!closing&&state==IDLE&&!token_exhausted;
 assign config_valid=command_valid&&!command_event&&session_ready&&!session_flush;
 assign config_slot=command_slot;assign config_bytes=command_bytes;
 assign command_ready=command_event?(state==RETIRE):config_ready&&session_ready&&!session_flush;
 assign cleanup_write_valid=STREAM_CLEAN&&!rst&&state==CLEAN_OFFER&&!cleanup_stored;
 assign cleanup_write_data={release_read,4'd2,4'd2,2'd0,clean_key,16'd0};
 assign event_valid=!rst&&(state==OFFER||(state==CLEAN_OFFER&&(!STREAM_CLEAN||cleanup_stored)));
 assign event_packet=clean?{timestamp,9'd1,768'd0,release_read,4'd2,4'd2,2'd0,clean_key,16'd0}:
     {timestamp,(9'h1ff>>(9-count)),items};
 assign event_press_ids=clean?576'd0:presses;
 assign result_bytes={256'd0,16'd0,8'd3,8'd0,result_sequence,session_id,16'd0,8'd2,8'd1,32'h54533953};
 always @(posedge clk)begin
  release_read<=release_tokens[clean_key[4:0]];
  if(!rst&&accounting&&kind==1)release_tokens[key]<=item[95:32];
  if(rst)begin
   cleanup_stored<=0;state<=IDLE;phone_active<=0;phone_close_done<=0;closing<=0;published<=0;
   index<=0;clean_key<=0;timestamp<=0;held_keys<=0;next_token<=1;token_exhausted<=0;
   result_valid<=0;result_slot<=0;result_sequence<=0;cleanup_offs<=0;
  end else begin
   phone_close_done<=0;
   if(state==CLEAN_READ)cleanup_stored<=0;
   else if(cleanup_write_valid&&cleanup_write_ready)cleanup_stored<=1;
   if(phone_close&&phone_active)closing<=1;
   if(session_flush)result_valid<=0;else if(result_valid&&result_ready)result_valid<=0;
   if(dispatch_done&&buffer_busy)published<=1;
   if(phone_open&&phone_open_ready)phone_active<=1;
   if(SHARED_STORE&&accounting)begin
     if(kind==1)begin
      held_keys[key]<=1;
      if(item[95:32]==64'hffffffffffffffff)token_exhausted<=1;
      else next_token<=item[95:32]+64'd1;
     end else if(kind==2)held_keys[key]<=0;
   end
   case(state)
    IDLE:if(phone_active&&(closing||phone_close))begin clean_key<=0;state<=CLEAN_READ;end
     else if(command_valid&&command_event&&session_ready&&!session_flush&&!result_valid&&!maps_locked)begin
      timestamp<=sample_time;result_slot<=command_slot;result_sequence<=0;state<=OFFER;
     end
    OFFER:if(event_ready)begin index<=0;published<=0;state<=SHARED_STORE?WAIT_DONE:ACCOUNT;end
    ACCOUNT:begin
     if(kind==1)begin
      held_keys[key]<=1;
      if(item[95:32]==64'hffffffffffffffff)token_exhausted<=1;
      else next_token<=item[95:32]+64'd1;
     end else if(kind==2)held_keys[key]<=0;
     if(index+1'b1==count)state<=WAIT_DONE;else index<=index+1'b1;
    end
    WAIT_DONE:if(dispatch_done||published)state<=RETIRE;
    RETIRE:begin
     if(!closing&&!phone_close&&!session_flush)result_valid<=1;
     state<=IDLE;
    end
    CLEAN_READ:if(clean_key==32)begin phone_active<=0;closing<=0;phone_close_done<=1;state<=IDLE;end
     else if(held_keys[clean_key])begin timestamp<=sample_time;state<=CLEAN_OFFER;end
     else clean_key<=clean_key+1'b1;
    CLEAN_OFFER:if(event_valid&&event_ready)state<=CLEAN_WAIT;
    CLEAN_WAIT:if(dispatch_done)begin held_keys[clean_key]<=0;cleanup_offs<=cleanup_offs+1'b1;clean_key<=clean_key+1'b1;state<=CLEAN_READ;end
   endcase
  end
 end
 // synthesis translate_off
 reg[1535:0] saved;reg was_busy;
 always @(posedge clk)begin
  was_busy<=!rst&&buffer_busy;saved<=command_bytes;
  if(!rst)begin
   if(!SHARED_STORE&&capture_map&&fact_item!==record_items[fact_index])$fatal(1,"R22_MAP_WRONG_BATCH_ITEM");
   if(capture_map&&map_mask[fact_index])$fatal(1,"R22_MAP_DUPLICATE_FACT");
   if(was_busy&&buffer_busy&&saved!==command_bytes)$fatal(1,"R21_EVENT_BUFFER_CHANGED");
   if(state==OFFER&&(count==0||count>9||command_length!=8+count*12))$fatal(1,"R21_EVENT_LENGTH");
   if(accounting)begin
    if(item[31:28]!=2||item[0]||kind<1||kind>4)$fatal(1,"R21_UNVALIDATED_ITEM");
    if(kind!=4&&item[23:16]>=32)$fatal(1,"R21_UNVALIDATED_KEY");
    if(kind==1&&(token_exhausted||item[95:32]!=next_token))$fatal(1,"R21_TOKEN_CONTINUITY");
   end
   if(dispatch_done&&state!=ACCOUNT&&state!=WAIT_DONE&&state!=CLEAN_WAIT)$fatal(1,"R21_UNOWNED_PUBLISH");
  end
 end
 // synthesis translate_on
endmodule

