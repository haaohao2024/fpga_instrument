// Production RT execution adapter. COMMITTED is driven by the actual allocator
// publication, never by a packet-time budget. It does not label COMMITTED as
// an audible/EFFECTIVE response; parameters have separate snapshot feedback.
module s9_event_endpoint #(parameter integer DEFER_RESULT_CRC=0)(
 input wire clk,rst,session_flush,session_ready,input wire[127:0] session_id,
 input wire phone_open,phone_close,output wire phone_open_ready,phone_active,phone_close_done,
 input wire command_valid,output wire command_ready,input wire[2:0] command_slot,
 input wire[1535:0] command_bytes,input wire[7:0] command_length,
 output wire config_valid,input wire config_ready,
 output wire[2:0] config_slot,output wire[1535:0] config_bytes,
 output reg result_valid,input wire result_ready,output reg[2:0] result_slot,
 output reg[31:0] result_sequence,output wire[511:0] result_bytes,
 input wire[31:0] sample_time,output wire event_valid,input wire event_ready,
 output wire[904:0] event_packet,output wire[575:0] event_press_ids,input wire dispatch_done,
 output wire[31:0] held_keys,
 output wire[31:0] accepted_commands,committed_commands,rejected_commands,cancelled_commands,cleanup_offs,
 output wire token_exhausted
);
 wire rt=command_bytes[47:40]==0;
 wire phone_command_ready,phone_done,phone_cancelled,phone_closing;
 wire signed[15:0] phone_error;
 reg tracked;reg[2:0] tracked_slot;reg[31:0] tracked_sequence;
 reg signed[15:0] result_error;
 wire rt_valid=command_valid&&rt&&session_ready&&!session_flush&&!tracked&&!result_valid;
 assign config_valid=command_valid&&!rt&&session_ready&&!session_flush;
 assign config_slot=command_slot;assign config_bytes=command_bytes;
 assign command_ready=session_ready&&!session_flush&&(rt?(phone_command_ready&&!tracked&&!result_valid):config_ready);
 s9_phone_events u_phone(.clk(clk),.rst(rst),.session_open(phone_open),.session_close(phone_close),
 .open_ready(phone_open_ready),.active(phone_active),.closing(phone_closing),.close_done(phone_close_done),
 .command_valid(rt_valid),.command_ready(phone_command_ready),.command_count(command_bytes[231:228]),.command_records(command_bytes[1407:256]),
 .sample_time(sample_time),.command_done(phone_done),.command_error(phone_error),.command_cancelled(phone_cancelled),
 .event_valid(event_valid),.event_ready(event_ready),.event_packet(event_packet),.dispatch_done(dispatch_done),
 .held_keys(held_keys),.held_press_ids(),.held_tokens(),.event_press_ids(event_press_ids),.token_exhausted(token_exhausted),
 .accepted_commands(accepted_commands),.rejected_commands(rejected_commands),.cancelled_commands(cancelled_commands),.committed_commands(committed_commands),.cleanup_offs(cleanup_offs));
 reg[511:0] packed_result;reg[31:0] crc;integer i;
 function[31:0] crcbyte(input[31:0] c,input[7:0] b);
  reg[31:0] v;integer j;begin v=c^b;for(j=0;j<8;j=j+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
 always @*begin
  packed_result=0;packed_result[31:0]=32'h54533953;packed_result[39:32]=1;packed_result[47:40]=2;
  packed_result[191:64]=session_id;packed_result[223:192]=result_sequence;
  packed_result[239:232]=(result_error==0)?3:7;packed_result[255:240]=result_error;
  crc=32'hffffffff;if(!DEFER_RESULT_CRC)begin for(i=0;i<60;i=i+1)crc=crcbyte(crc,packed_result[i*8+:8]);packed_result[511:480]=~crc;end
 end
 assign result_bytes=packed_result;
 always @(posedge clk)begin
  if(rst)begin tracked<=0;tracked_slot<=0;tracked_sequence<=0;result_valid<=0;result_slot<=0;result_sequence<=0;result_error<=0;end
  else if(session_flush)begin tracked<=0;result_valid<=0;end
  else begin
   if(result_valid&&result_ready)result_valid<=0;
   if(rt_valid&&phone_command_ready)begin tracked<=1;tracked_slot<=command_slot;tracked_sequence<=command_bytes[223:192];end
   if(phone_done&&tracked)begin
    tracked<=0;
    if(!phone_cancelled)begin result_valid<=1;result_slot<=tracked_slot;result_sequence<=tracked_sequence;result_error<=phone_error;end
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if((^{session_flush,session_ready,command_valid,config_ready,result_ready})===1'bx)$fatal(1,"S9_ENDPOINT_CONTROL_XZ");
  if(command_valid&&(^({command_slot,command_bytes,command_length}))===1'bx)$fatal(1,"S9_ENDPOINT_COMMAND_XZ");
  if(rt_valid&&(command_length!=36+command_bytes[239:224]||command_bytes[239:224]<16||command_bytes[239:224]>144||command_bytes[227:224]!=0))$fatal(1,"S9_ENDPOINT_UNVALIDATED_RT");
 end
 // synthesis translate_on
endmodule

// MCU prepares validated 96-bit events. The only per-key hardware table is
// the accepted token needed to release keys if the MCU disappears.
// command_bytes stays owned until publication; ACK/KEEP may still pass it.
module r21_event_endpoint(
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
 reg[2:0] state;reg closing,published;reg[3:0] index;reg[5:0] clean_key;
 reg[31:0] timestamp;reg[63:0] release_tokens[0:31],release_read;
 wire[3:0] count=command_bytes[35:32];
 wire[95:0] record_items[0:8];
 wire[95:0] item=record_items[index];
 wire[3:0] kind=item[27:24];wire[4:0] key=item[20:16];
 wire clean=state==CLEAN_READ||state==CLEAN_OFFER||state==CLEAN_WAIT;
 wire[863:0] items;wire[575:0] presses;
 for(genvar i=0;i<9;i=i+1)begin: unpack
  assign items[i*96+:96]=command_bytes[64+i*160+:96];
  assign record_items[i]=command_bytes[64+i*160+:96];
  assign presses[i*64+:64]=command_bytes[160+i*160+:64];
 end
 assign buffer_busy=state==OFFER||state==ACCOUNT||state==WAIT_DONE||state==RETIRE;
 assign phone_open_ready=!rst&&!phone_active&&!closing&&state==IDLE&&!token_exhausted;
 assign config_valid=command_valid&&!command_event&&session_ready&&!session_flush;
 assign config_slot=command_slot;assign config_bytes=command_bytes;
 assign command_ready=command_event?(state==RETIRE):config_ready&&session_ready&&!session_flush;
 assign event_valid=!rst&&(state==OFFER||state==CLEAN_OFFER);
 assign event_packet=clean?{timestamp,9'd1,768'd0,release_read,4'd2,4'd2,2'd0,clean_key,16'd0}:
     {timestamp,(9'h1ff>>(9-count)),items};
 assign event_press_ids=clean?576'd0:presses;
 assign result_bytes={256'd0,16'd0,8'd3,8'd0,result_sequence,session_id,16'd0,8'd2,8'd1,32'h54533953};
 always @(posedge clk)begin
  release_read<=release_tokens[clean_key[4:0]];
  if(!rst&&state==ACCOUNT&&kind==1)release_tokens[key]<=item[95:32];
  if(rst)begin
   state<=IDLE;phone_active<=0;phone_close_done<=0;closing<=0;published<=0;
   index<=0;clean_key<=0;timestamp<=0;held_keys<=0;next_token<=1;token_exhausted<=0;
   result_valid<=0;result_slot<=0;result_sequence<=0;cleanup_offs<=0;
  end else begin
   phone_close_done<=0;
   if(phone_close&&phone_active)closing<=1;
   if(session_flush)result_valid<=0;else if(result_valid&&result_ready)result_valid<=0;
   if(dispatch_done&&buffer_busy)published<=1;
   if(phone_open&&phone_open_ready)phone_active<=1;
   case(state)
    IDLE:if(phone_active&&(closing||phone_close))begin clean_key<=0;state<=CLEAN_READ;end
     else if(command_valid&&command_event&&session_ready&&!session_flush&&!result_valid)begin
      timestamp<=sample_time;result_slot<=command_slot;result_sequence<=command_bytes[31:0];state<=OFFER;
     end
    OFFER:if(event_ready)begin index<=0;published<=0;state<=ACCOUNT;end
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
    CLEAN_OFFER:if(event_ready)state<=CLEAN_WAIT;
    CLEAN_WAIT:if(dispatch_done)begin held_keys[clean_key]<=0;cleanup_offs<=cleanup_offs+1'b1;clean_key<=clean_key+1'b1;state<=CLEAN_READ;end
   endcase
  end
 end
 // synthesis translate_off
 reg[1535:0] saved;reg was_busy;
 always @(posedge clk)begin
  was_busy<=!rst&&buffer_busy;saved<=command_bytes;
  if(!rst)begin
   if(was_busy&&buffer_busy&&saved!==command_bytes)$fatal(1,"R21_EVENT_BUFFER_CHANGED");
   if(state==OFFER&&(count==0||count>9||command_length!=8+count*20))$fatal(1,"R21_EVENT_LENGTH");
   if(state==ACCOUNT)begin
    if(item[31:28]!=2||item[0]||kind<1||kind>4)$fatal(1,"R21_UNVALIDATED_ITEM");
    if(kind!=4&&item[23:16]>=32)$fatal(1,"R21_UNVALIDATED_KEY");
    if(kind==1&&(token_exhausted||item[95:32]!=next_token))$fatal(1,"R21_TOKEN_CONTINUITY");
   end
   if(dispatch_done&&state!=ACCOUNT&&state!=WAIT_DONE&&state!=CLEAN_WAIT)$fatal(1,"R21_UNOWNED_PUBLISH");
  end
 end
 // synthesis translate_on
endmodule

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

