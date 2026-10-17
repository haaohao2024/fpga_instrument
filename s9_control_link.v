// Real STE2 pins -> authenticated application commands / cached execution status.
// Execution endpoints own semantic COMMITTED/EFFECTIVE updates. This module
// never fabricates an effective sample frame from transport completion.
module s9_control_link #(parameter integer REBUILD_RESULT_CRC=0, STREAM_STATUS_CRC=0, SHARED_FRAGMENT_POOL=0, PREDICTIVE_LEASE=0)(
 input wire clk,rst,input wire[31:0] now_ms,
 input wire [31:0] now_ms_next,
 input wire spi_sck,control_cs_n,score_cs_n,sd_cs_n,spi_mosi,
 output wire spi_miso,spi_miso_oe,
 input wire phone_open_ready,phone_active,phone_close_done,
 output wire phone_open,phone_close,session_flush,session_ready,
 output wire[127:0] session_id,output wire[2:0] link_state,
 output wire config_payload_changed,
 output wire identity_query_prepare,output wire [63:0] identity_prepare_press,
 output wire command_valid,input wire command_ready,output wire[2:0] command_slot,
 output wire[1535:0] command_bytes,output wire[7:0] command_length,
 input wire result_valid,output wire result_ready,input wire[2:0] result_slot,
 input wire result_channel,input wire[31:0] result_sequence,input wire[511:0] result_bytes,input wire result_final,
 input wire lookup_valid,output wire lookup_ready,input wire lookup_channel,lookup_echo,input wire[31:0] lookup_sequence,
 output wire lookup_done,output wire signed[15:0] lookup_error,output wire[511:0] lookup_result,
 output wire[31:0] rejected_transactions,cs_conflicts,lease_expirations,stale_result_updates
);
 wire [1:0] fragment_bank,pool_read_bank,pool_response_bank,pool_release_bank;
 wire [6:0] pool_read_index,pool_response_index;wire [7:0] pool_read_data;
 wire pool_read_enable,pool_response_valid,pool_release;
 wire fragment_valid,fragment_ready;wire[255:0] fragment_header;wire[1023:0] fragment_payload;wire[7:0] fragment_length;
 wire[31:0] physical_accepted,physical_rejected,physical_timeout;
 wire status_read;wire[511:0] status_snapshot,status_bytes;
 s9_spi_transport #(.STREAM_STATUS_CRC(STREAM_STATUS_CRC),.SHARED_FRAGMENT_POOL(SHARED_FRAGMENT_POOL)) u_spi(.clk(clk),.rst(rst),.spi_sck(spi_sck),.control_cs_n(control_cs_n),.score_cs_n(score_cs_n),.sd_cs_n(sd_cs_n),.spi_mosi(spi_mosi),
 .spi_miso(spi_miso),.spi_miso_oe(spi_miso_oe),.status_bytes(status_bytes),.fragment_valid(fragment_valid),.fragment_ready(fragment_ready),
 .fragment_header(fragment_header),.fragment_payload(fragment_payload),.fragment_length(fragment_length),
 .fragment_bank(fragment_bank),.pool_read_enable(pool_read_enable),.pool_read_bank(pool_read_bank),.pool_read_index(pool_read_index),.pool_read_data(pool_read_data),.pool_response_valid(pool_response_valid),.pool_response_bank(pool_response_bank),.pool_response_index(pool_response_index),.pool_release(pool_release),.pool_release_bank(pool_release_bank),
 .status_read(status_read),.status_snapshot(status_snapshot),.accepted_transactions(physical_accepted),.rejected_transactions(physical_rejected),.cs_conflicts(cs_conflicts),.timeouts(physical_timeout));
 wire management_valid,management_ready;wire[7:0] management_op;wire[127:0] management_session;
 wire management_done;wire signed[15:0] management_error;wire[31:0] opened,closed,management_rejected;
 s9_session_control #(.PREDICTIVE_LEASE(PREDICTIVE_LEASE)) u_session(.now_ms_next(now_ms_next),.clk(clk),.rst(rst),.now_ms(now_ms),.management_valid(management_valid),.management_ready(management_ready),
 .management_op(management_op),.management_session(management_session),.phone_open_ready(phone_open_ready),.phone_active(phone_active),.phone_close_done(phone_close_done),
 .phone_open(phone_open),.phone_close(phone_close),.flush(session_flush),.session_id(session_id),.link_state(link_state),.session_ready(session_ready),
 .management_done(management_done),.management_error(management_error),.opened_count(opened),.closed_count(closed),.expired_count(lease_expirations),.rejected_count(management_rejected));
 wire request_valid,request_ready;wire[1535:0] request_bytes;wire[7:0] request_length;wire request_channel;wire[31:0] request_sequence;
 wire assembly_error,assembly_error_channel;wire signed[15:0] assembly_error_code;wire[31:0] assembly_error_sequence;
 wire[31:0] assembled,assembly_rejected,duplicate_fragments,assembly_timeouts;
 reg status_pending;
 wire assembly_ready;
 assign fragment_ready=assembly_ready&&!status_pending&&request_ready;
 s9_command_reassembly #(.SHARED_FRAGMENT_POOL(SHARED_FRAGMENT_POOL)) u_reassembly(.clk(clk),.rst(rst),.flush(session_flush),.session_ready(session_ready),.session_id(session_id),.now_ms(now_ms),
 .fragment_valid(fragment_valid&&!status_pending&&request_ready),.fragment_ready(assembly_ready),.fragment_header(fragment_header),.fragment_payload(fragment_payload),.fragment_length(fragment_length),
 .fragment_bank(fragment_bank),.pool_read_enable(pool_read_enable),.pool_read_bank(pool_read_bank),.pool_read_index(pool_read_index),.pool_read_data(pool_read_data),.pool_response_valid(pool_response_valid),.pool_response_bank(pool_response_bank),.pool_response_index(pool_response_index),.pool_release(pool_release),.pool_release_bank(pool_release_bank),
 .management_valid(management_valid),.management_ready(management_ready),.management_op(management_op),.management_session(management_session),
 .command_valid(request_valid),.command_ready(request_ready),.command_bytes(request_bytes),.command_length(request_length),.command_channel(request_channel),.command_sequence(request_sequence),
 .error_valid(assembly_error),.error_code(assembly_error_code),.error_channel(assembly_error_channel),.error_sequence(assembly_error_sequence),
 .completed_count(assembled),.rejected_count(assembly_rejected),.duplicate_fragments(duplicate_fragments),.timeout_count(assembly_timeouts));
 assign config_payload_changed=request_valid&&request_ready&&session_ready;
 assign identity_query_prepare=request_valid&&request_ready&&session_ready&&request_bytes[55:48]==39;
 assign identity_prepare_press=request_bytes[327:264];
 wire semantic_legal;wire signed[15:0] semantic_error;
 s9_request_validate u_validate(.command_bytes(request_bytes),.legal(semantic_legal),.error_code(semantic_error));
 wire cache_reply_valid,cache_error,cache_error_channel;wire[511:0] cache_reply;
 wire signed[15:0] cache_error_code;wire[31:0] cache_error_sequence,admitted,retries,cache_rejected;
 wire[3:0] credits;
 wire cache_command_valid;
 assign command_valid=cache_command_valid&&session_ready&&!session_flush;
 wire cache_update_ready;
 assign result_ready=cache_update_ready&&assembly_ready;
 s9_command_cache #(.REBUILD_UPDATE_CRC(REBUILD_RESULT_CRC)) u_cache(.clk(clk),.rst(rst),.flush(session_flush),.session_id(session_id),
 .request_valid(request_valid&&session_ready),.request_ready(request_ready),.request_bytes(request_bytes),.request_length(request_length),
 .request_channel(request_channel),.request_sequence(request_sequence),.request_error(semantic_error),
 .dispatch_valid(cache_command_valid),.dispatch_ready(command_ready&&session_ready&&!session_flush),.dispatch_slot(command_slot),.dispatch_bytes(command_bytes),.dispatch_length(command_length),
 .update_valid(result_valid&&assembly_ready),.update_ready(cache_update_ready),.update_slot(result_slot),.update_channel(result_channel),.update_sequence(result_sequence),.update_result(result_bytes),.update_final(result_final),
 .lookup_valid(lookup_valid),.lookup_ready(lookup_ready),.lookup_channel(lookup_channel),.lookup_echo(lookup_echo),.lookup_sequence(lookup_sequence),.lookup_done(lookup_done),.lookup_error(lookup_error),
 .reply_valid(cache_reply_valid),.reply_ready(!status_pending),.reply_result(cache_reply),.error_valid(cache_error),.error_code(cache_error_code),.error_channel(cache_error_channel),.error_sequence(cache_error_sequence),
 .credit(credits),.admitted_count(admitted),.retry_count(retries),.rejected_count(cache_rejected),.stale_updates(stale_result_updates));
 assign lookup_result=cache_reply;
 assign rejected_transactions=physical_rejected+assembly_rejected+cache_rejected+management_rejected;
 reg[511:0] status_build;reg[31:0] crc;integer k;
 function[31:0] crcbyte(input[31:0] c,input[7:0] b);
  reg[31:0] v;integer j;begin v=c^b;for(j=0;j<8;j=j+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
 // Preserve endpoint result24..55, including its command-specific diagnostic.
 reg[255:0] result_fields;reg[7:0] result_flags;reg[127:0] result_session;
 always @*begin
  status_build=0;status_build[31:0]=32'h54533953;status_build[39:32]=1;status_build[47:40]={5'd0,link_state};
  status_build[55:48]=(session_ready&&!status_pending)?{4'd0,credits}:8'd0;
  status_build[63:56]=result_flags;status_build[191:64]=session_id;
  status_build[447:192]=result_fields;
  crc=32'hffffffff;if(!STREAM_STATUS_CRC)begin for(k=0;k<60;k=k+1)crc=crcbyte(crc,status_build[k*8+:8]);status_build[511:480]=~crc;end
 end
 assign status_bytes=status_build;
 wire read_our_result=status_read&&status_snapshot[191:64]==result_session&&
  status_snapshot[447:192]==result_fields&&status_snapshot[63:56]==result_flags;
 always @(posedge clk)begin
  if(rst||session_flush)begin status_pending<=0;result_fields<=0;result_flags<=0;result_session<=0;end
  else begin
   if(read_our_result)status_pending<=0;
   if(cache_reply_valid&&!status_pending)begin
    result_fields<=cache_reply[447:192];result_flags<=cache_reply[63:56];result_session<=cache_reply[191:64];status_pending<=1;
   end else if(cache_error)begin
    result_fields<=0;result_fields[31:0]<=cache_error_sequence;result_fields[39:32]<={7'd0,cache_error_channel};
    result_fields[47:40]<=7;result_fields[63:48]<=cache_error_code;result_flags<=0;result_session<=session_id;status_pending<=1;
   end else if(assembly_error&&assembly_error_sequence!=0)begin
    result_fields<=0;result_fields[31:0]<=assembly_error_sequence;result_fields[39:32]<={7'd0,assembly_error_channel};
    result_fields[47:40]<=7;result_fields[63:48]<=assembly_error_code;result_flags<=0;result_session<=session_id;status_pending<=1;
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if((^{command_ready,result_valid,lookup_valid,phone_open_ready,phone_active,phone_close_done})===1'bx)$fatal(1,"S9_LINK_CONTROL_XZ");
  if(result_valid&&(^({result_slot,result_channel,result_sequence,result_bytes,result_final}))===1'bx)$fatal(1,"S9_LINK_RESULT_XZ");
 end
 // synthesis translate_on
endmodule

module r8_control_crc_probe #(parameter integer REBUILD_RESULT_CRC=0, STREAM_STATUS_CRC=0, SHARED_FRAGMENT_POOL=0)(
 input wire clk,rst,input wire[31:0] now_ms,
 input wire spi_sck,control_cs_n,score_cs_n,sd_cs_n,spi_mosi,
 output wire spi_miso,spi_miso_oe,
 input wire phone_open_ready,phone_active,phone_close_done,
 output wire phone_open,phone_close,session_flush,session_ready,
 output wire[127:0] session_id,output wire[2:0] link_state,
 output wire command_valid,input wire command_ready,output wire[2:0] command_slot,
 output wire[1535:0] command_bytes,output wire[7:0] command_length,
 input wire result_valid,output wire result_ready,input wire[2:0] result_slot,
 input wire result_channel,input wire[31:0] result_sequence,input wire[511:0] result_bytes,input wire result_final,
 input wire lookup_valid,output wire lookup_ready,input wire lookup_channel,lookup_echo,input wire[31:0] lookup_sequence,
 output wire lookup_done,output wire signed[15:0] lookup_error,output wire[511:0] lookup_result,
 output wire[31:0] rejected_transactions,cs_conflicts,lease_expirations,stale_result_updates
);

s9_control_link #(.REBUILD_RESULT_CRC(1),.STREAM_STATUS_CRC(1),.SHARED_FRAGMENT_POOL(1)) impl(.config_payload_changed(),.now_ms_next(now_ms),.*);
endmodule

// R20 private board mailbox. BLE/application validation, histories and barriers
// belong to the MCU. Eight execution tickets retain the old admission capacity.
// A result remains held until a CRC-valid ACK with its epoch and serial arrives.
module r21_control_link(
 input wire clk,rst,input wire [31:0] now_ms,now_ms_next,
 input wire spi_sck,control_cs_n,score_cs_n,sd_cs_n,spi_mosi,
 output wire spi_miso,spi_miso_oe,
 input wire phone_open_ready,phone_active,phone_close_done,
 input wire command_buffer_busy,input wire[63:0] phone_next_token,input wire phone_token_exhausted,
 output wire phone_open,phone_close,session_flush,session_ready,
 output wire [127:0] session_id,output wire [2:0] link_state,
 output wire config_payload_changed,identity_query_prepare,
 output wire [63:0] identity_prepare_press,
 output reg command_valid,output reg command_event,input wire command_ready,output reg [2:0] command_slot,
 output reg [1535:0] command_bytes,output reg [7:0] command_length,
 input wire result_valid,output wire result_ready,input wire [2:0] result_slot,
 input wire result_channel,input wire [31:0] result_sequence,
 input wire [511:0] result_bytes,input wire result_final,
 input wire lookup_valid,output wire lookup_ready,input wire lookup_channel,lookup_echo,
 input wire [31:0] lookup_sequence,output reg lookup_done,
 output wire signed [15:0] lookup_error,output wire [511:0] lookup_result,
 output wire [31:0] rejected_transactions,output reg [31:0] cs_conflicts,
 output wire [31:0] lease_expirations,output reg [31:0] stale_result_updates
);
 function [31:0] crcbyte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer n;begin v=c^b;for(n=0;n<8;n=n+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
 reg [2:0] sck_sync,cs_sync;reg [1:0] mosi_sync,score_sync,sd_sync;
 wire start=cs_sync[2:1]==2'b10,finish=cs_sync[2:1]==2'b01;
 wire rise=sck_sync[2:1]==2'b01,fall=sck_sync[2:1]==2'b10;
 reg transaction,bad,capacity,packet;
 reg [127:0] header,packet_header;
 reg [8:0] rx_count,wire_length,expected;
 reg [2:0] rx_bits;reg [7:0] rx_shift;
 reg [31:0] rx_crc,footer,watchdog,physical_rejected;
 reg [7:0] memory[0:255];reg [7:0] read_byte;
 reg [7:0] cursor;reg [1:0] load_state;
 wire [7:0] byte_in={rx_shift[6:0],mosi_sync[1]};
 wire rx_write=transaction&&!start&&!cs_sync[2]&&rise&&rx_bits==7&&rx_count>=16&&rx_count<expected-4&&capacity;
 wire [7:0] op=packet_header[47:40];
 wire [15:0] length=packet_header[63:48];
 wire [31:0] packet_epoch=packet_header[95:64],serial=packet_header[127:96];
 reg [31:0] epoch,accepted_serial,result_serial;
 reg [7:0] owned,channels;reg [31:0] sequences[0:7];
 reg [287:0] result_hold;reg result_pending;
 reg [31:0] rejected;
 reg found_free;reg [2:0] free_slot;reg [3:0] free_count;integer k;
 always @*begin
  found_free=0;free_slot=0;free_count=0;
  for(integer j=0;j<8;j=j+1)if(!owned[j])begin
   free_count=free_count+1'b1;if(!found_free)begin found_free=1;free_slot=j;end
  end
 end
 reg management_valid;reg [7:0] management_op;reg [127:0] management_session;
 wire management_ready;wire [31:0] management_rejected;
 s9_session_control #(.PREDICTIVE_LEASE(1)) session(.clk(clk),.rst(rst),.now_ms(now_ms),.now_ms_next(now_ms_next),
  .management_valid(management_valid),.management_ready(management_ready),.management_op(management_op),.management_session(management_session),
  .phone_open_ready(phone_open_ready),.phone_active(phone_active),.phone_close_done(phone_close_done),
  .phone_open(phone_open),.phone_close(phone_close),.flush(session_flush),.session_id(session_id),.link_state(link_state),.session_ready(session_ready),
  .management_done(),.management_error(),.opened_count(),.closed_count(),.expired_count(lease_expirations),.rejected_count(management_rejected));
 assign rejected_transactions=physical_rejected+rejected+management_rejected;
 assign result_ready=!rst&&!session_flush&&!result_pending;
 assign config_payload_changed=load_state==3&&op==4&&session_ready&&packet_epoch==epoch&&serial!=0&&serial==accepted_serial+1&&found_free;
 assign identity_query_prepare=config_payload_changed&&command_bytes[55:48]==39;
 assign identity_prepare_press=command_bytes[327:264];
 // Application QUERY_RESULT/BARRIER are consumed by s9_router on BL616.
 assign lookup_ready=1'b1;assign lookup_error=-16'sd13;assign lookup_result=0;
 reg [767:0] response,status;
 reg [9:0] tx_bit;reg [31:0] tx_crc;reg [6:0] tx_index;reg tx_crc_busy;
 wire [31:0] tx_crc_next=crcbyte(tx_crc,response[767-tx_index*8-:8]);
 always @*begin
  status=0;status[31:0]=32'h53303252;status[39:32]=2;status[47:40]={5'd0,link_state};
  status[55:48]=(session_ready&&!command_valid&&!command_buffer_busy&&!packet&&load_state==0)?{4'd0,free_count}:8'd0;
  status[63:56]={7'd0,result_pending};status[95:64]=epoch;status[127:96]=accepted_serial;
  status[159:128]=result_serial;status[447:160]=result_hold;status[575:448]=session_id;status[639:576]=phone_next_token;status[640]=phone_token_exhausted;
 end
 assign spi_miso_oe=!rst&&!control_cs_n&&score_cs_n&&sd_cs_n&&transaction&&!bad;
 assign spi_miso=tx_bit<768?response[767-tx_bit]:1'b0;
 always @(posedge clk)begin
  if(rx_write)memory[rx_count-9'd16]<=byte_in;
  read_byte<=memory[cursor];
  sck_sync<={sck_sync[1:0],spi_sck};cs_sync<={cs_sync[1:0],control_cs_n};
  mosi_sync<={mosi_sync[0],spi_mosi};score_sync<={score_sync[0],score_cs_n};sd_sync<={sd_sync[0],sd_cs_n};
  if(rst)begin
   sck_sync<=0;cs_sync<=7;mosi_sync<=0;score_sync<=3;sd_sync<=3;
   transaction<=0;bad<=0;capacity<=0;header<=0;packet_header<=0;packet<=0;
   rx_count<=0;wire_length<=96;expected<=20;rx_bits<=0;rx_shift<=0;rx_crc<=32'hffffffff;footer<=0;watchdog<=0;
   physical_rejected<=0;cs_conflicts<=0;cursor<=0;load_state<=0;
   command_bytes<=0;command_length<=0;command_slot<=0;command_valid<=0;command_event<=0;
   epoch<=0;accepted_serial<=0;result_serial<=0;owned<=0;channels<=0;result_hold<=0;result_pending<=0;
   management_valid<=0;management_op<=0;management_session<=0;rejected<=0;stale_result_updates<=0;lookup_done<=0;
   response<=0;tx_bit<=0;tx_crc<=32'hffffffff;tx_index<=0;tx_crc_busy<=0;
   for(k=0;k<8;k=k+1)sequences[k]<=0;
  end else begin
   management_valid<=0;lookup_done<=lookup_valid;
   if(command_valid&&command_ready)command_valid<=0;
   if(result_valid&&result_ready)begin
    if(owned[result_slot]&&channels[result_slot]==result_channel&&sequences[result_slot]==result_sequence&&result_bytes[191:64]==session_id)begin
     result_hold<={24'd0,result_bytes[63:56],result_bytes[447:192]};
     result_serial<=result_serial+1'b1;result_pending<=1;
     if(result_final)owned[result_slot]<=0;
    end else stale_result_updates<=stale_result_updates+1'b1;
   end
   if(tx_crc_busy&&!start)begin
    tx_crc<=tx_crc_next;
    if(tx_index==91)begin response[31:0]<={~tx_crc_next[7:0],~tx_crc_next[15:8],~tx_crc_next[23:16],~tx_crc_next[31:24]};tx_crc_busy<=0;end
    else tx_index<=tx_index+1'b1;
   end
   if(start)begin
    transaction<=1;bad<=!score_sync[1]||!sd_sync[1];capacity<=!packet&&load_state==0;
    header<=0;rx_crc<=32'hffffffff;footer<=0;watchdog<=0;rx_count<=0;rx_bits<=0;rx_shift<=0;expected<=20;wire_length<=96;tx_bit<=0;
    for(k=0;k<96;k=k+1)response[767-k*8-:8]<=status[k*8+:8];
    tx_crc<=32'hffffffff;tx_index<=0;tx_crc_busy<=1;
    if(!score_sync[1]||!sd_sync[1])cs_conflicts<=cs_conflicts+1'b1;
   end else if(transaction)begin
    if(watchdog<500000)watchdog<=watchdog+1'b1;else bad<=1;
    if((!score_sync[1]||!sd_sync[1])&&!bad)begin bad<=1;cs_conflicts<=cs_conflicts+1'b1;end
    if(!cs_sync[2]&&rise)begin
     rx_shift<=byte_in;rx_bits<=rx_bits+1'b1;
     if(rx_bits==7)begin
      if(rx_count<16)begin
       header[rx_count*8+:8]<=byte_in;rx_crc<=crcbyte(rx_crc,byte_in);
       if(rx_count==15)begin
        if(header[63:48]>192)bad<=1;
        else begin expected<=20+header[63:48];wire_length<=header[63:48]>76?20+header[63:48]:96;end
       end
      end else if(rx_count<expected-4)rx_crc<=crcbyte(rx_crc,byte_in);
      else if(rx_count<expected)footer[(rx_count-expected+4)*8+:8]<=byte_in;
      else if(byte_in!=0||rx_count>=wire_length)bad<=1;
      if(rx_count<511)rx_count<=rx_count+1'b1;else bad<=1;
     end
    end
    if(fall&&tx_bit<768)tx_bit<=tx_bit+1'b1;
    if(finish)begin
     transaction<=0;
     if(bad||!score_sync[1]||!sd_sync[1]||rx_bits!=0||rx_count!=wire_length||footer!=~rx_crc||header[31:0]!=32'h43303252||header[39:32]!=2||header[47:40]>6)
      physical_rejected<=physical_rejected+1'b1;
     else if(capacity&&(!(command_valid||command_buffer_busy)||(header[47:40]!=1&&header[47:40]!=4&&header[47:40]!=6)))begin packet<=1;packet_header<=header;end
     else if(header[47:40]!=0)physical_rejected<=physical_rejected+1'b1;
    end
   end
   // Synchronous byte RAM -> transitional execution adapter. No application
   // history, second CRC, request compare or per-slot wide payload is retained.
   case(load_state)
    0:if(packet&&(!(command_valid||command_buffer_busy)||(op!=1&&op!=4&&op!=6)))begin
     packet<=0;
     if(op==0)begin end
     else if(op==5)begin
      if(length==0&&packet_epoch==epoch&&result_pending&&serial==result_serial)result_pending<=0;
     end else if(op==2||op==3)begin
      if(length==0&&packet_epoch==epoch)begin management_valid<=1;management_op<=op==2?8'h91:8'h92;management_session<=session_id;end
     end else if((op==1&&length==16)||((op==4||op==6)&&length>=8&&length<=192&&packet_epoch==epoch&&session_ready&&found_free))begin
      cursor<=0;command_bytes<=0;load_state<=1;
     end else rejected<=rejected+1'b1;
    end
    1:load_state<=2;
    2:begin
     command_bytes<={(cursor<length?read_byte:8'd0),command_bytes[1535:8]};
     if(cursor==191)load_state<=3;
     else begin cursor<=cursor+1'b1;load_state<=1;end
    end
    3:begin
     load_state<=0;
     if(op==1)begin
      if(packet_epoch!=0&&((link_state==0&&phone_open_ready)||(packet_epoch==epoch&&command_bytes[127:0]==session_id)))begin
       management_valid<=1;management_op<=8'h90;management_session<=command_bytes[127:0];
       if(link_state==0&&command_bytes[63:0]!=0&&command_bytes[127:64]!=0&&(command_bytes[63:0]!=session_id[63:0]||command_bytes[127:64]>session_id[127:64]))begin epoch<=packet_epoch;accepted_serial<=0;result_serial<=0;end
      end else rejected<=rejected+1'b1;
     end else if(session_ready&&packet_epoch==epoch)begin
      if(serial!=0&&serial==accepted_serial)begin end // same stop-and-wait transmission
      else if(serial!=0&&serial==accepted_serial+1&&found_free&&((op==4&&length>=36&&command_bytes[191:64]==session_id&&command_bytes[47:40]==1)||(op==6&&command_bytes[39:32]>=1&&command_bytes[39:32]<=9&&command_bytes[63:40]==0&&length==8+command_bytes[39:32]*20)))begin
       command_valid<=1;command_event<=op==6;command_slot<=free_slot;command_length<=length[7:0];accepted_serial<=serial;
       owned[free_slot]<=1;channels[free_slot]<=op==4;sequences[free_slot]<=op==6?command_bytes[31:0]:command_bytes[223:192];
      end else rejected<=rejected+1'b1;
     end
    end
   endcase
   if(session_flush)begin command_valid<=0;owned<=0;result_pending<=0;load_state<=0;packet<=0;end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(tx_crc_busy&&transaction&&tx_bit>=736)$fatal(1,"R20_RESPONSE_CRC_LATE");
  if(result_valid&&result_ready&&owned[result_slot]&&(result_sequence!=result_bytes[223:192]||result_channel!=result_bytes[224]))$fatal(1,"R20_RESULT_BINDING");
  if(lookup_valid)$fatal(1,"R20_APPLICATION_LOOKUP_NOT_MIGRATED");
 end
 // synthesis translate_on
endmodule

module r22_control_link #(parameter integer COMM_SEPARATE=0, CLK_FREQ_HZ=50_000_000)(
 output reg event_write_valid,output reg[3:0] event_write_index,output reg[95:0] event_write_data,
 input wire event_write_ready,output reg event_write_abort,
 output reg[3:0] map_address,input wire[95:0] map_data,input wire[8:0] map_mask,
 output reg maps_release,
 input wire comm_clk,clk,rst,input wire [31:0] now_ms,now_ms_next,
 input wire spi_sck,control_cs_n,score_cs_n,sd_cs_n,spi_mosi,
 output wire spi_miso,spi_miso_oe,
 input wire phone_open_ready,phone_active,phone_close_done,
 input wire command_buffer_busy,input wire[63:0] phone_next_token,input wire phone_token_exhausted,
 output wire phone_open,phone_close,session_flush,session_ready,
 output wire [127:0] session_id,output wire [2:0] link_state,
 output wire config_payload_changed,identity_query_prepare,
 output wire [63:0] identity_prepare_press,
 output reg command_valid,output reg command_event,input wire command_ready,output reg [2:0] command_slot,
 output wire [1535:0] command_bytes,output reg [7:0] command_length,
 input wire result_valid,output wire result_ready,input wire [2:0] result_slot,
 input wire result_channel,input wire [31:0] result_sequence,
 input wire [511:0] result_bytes,input wire result_final,
 input wire lookup_valid,output wire lookup_ready,input wire lookup_channel,lookup_echo,
 input wire [31:0] lookup_sequence,output reg lookup_done,
 output wire signed [15:0] lookup_error,output wire [511:0] lookup_result,
 output wire [31:0] rejected_transactions,output reg [31:0] cs_conflicts,
 output wire [31:0] lease_expirations,output reg [31:0] stale_result_updates
);
 wire r54_equal_0;
 wire r54_equal_1;
 wire r54_equal_2;
 wire r54_equal_3;
 wire r54_equal_4;
 wire r54_equal_5;
 wire r54_equal_6;

 reg[7:0] read_byte;
 reg[415:0] command_payload;assign command_bytes={1120'd0,command_payload};
 reg[3:0] event_column,event_number;reg event_bad;reg[63:0] checked_next_token;
 reg checked_exhausted;
 wire[95:0] assembled_event={read_byte,event_write_data[95:8]};
 wire[3:0] assembled_kind=assembled_event[27:24];
 wire assembled_bad=assembled_event[0] || assembled_event[31:28]!=2 || assembled_kind<1 || assembled_kind>4 ||
  (assembled_kind==4?(assembled_event[23:16]!=255 || assembled_event[15:9]!=0):(assembled_event[23:16]>=32 || assembled_event[95:32]==0)) ||
  (assembled_kind==1 && (checked_exhausted || !r54_equal_0));
 function [31:0] crcbyte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer n;begin v=c^b;for(n=0;n<8;n=n+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
 reg [1:0] score_sync,sd_sync;
 wire rise,fall,start,finish,phy_selected,phy_bit,fast_start,fast_fall;
 wire serial_clk=COMM_SEPARATE?comm_clk:clk;
 r24_spi_edges #(.COMM_SEPARATE(COMM_SEPARATE)) phy(.clk(clk),.comm_clk(comm_clk),.rst(rst),
 .sck(spi_sck),.cs_n(control_cs_n),.mosi(spi_mosi),.rise(rise),.fall(fall),.start(start),.finish(finish),
 .selected(phy_selected),.bit_data(phy_bit),.fast_start(fast_start),.fast_fall(fast_fall));
 reg transaction,bad,capacity,packet;
 reg [127:0] header,packet_header;
 reg [8:0] rx_count,wire_length,expected;
 reg [2:0] rx_bits;reg [7:0] rx_shift;
 reg [31:0] rx_crc,footer,watchdog,physical_rejected;
 reg [7:0] memory[0:255];
 reg [7:0] cursor;reg [1:0] load_state;
 wire [7:0] byte_in={rx_shift[6:0],phy_bit};
 wire rx_write=transaction&&!start&&phy_selected&&rise&&rx_bits==7&&rx_count>=16&&rx_count<expected-4&&capacity;
 wire [7:0] op=packet_header[47:40];
 wire [15:0] length=packet_header[63:48];
 wire [31:0] packet_epoch=packet_header[95:64],serial=packet_header[127:96];
 reg [31:0] epoch,accepted_serial,result_serial;
 reg [7:0] owned,channels;reg[2:0] accepted_slot;reg held_final;
 reg [287:0] result_hold;reg result_pending;
 reg [31:0] rejected;
 reg found_free;reg [2:0] free_slot;reg [3:0] free_count;integer k;
 always @*begin
  found_free=0;free_slot=0;free_count=0;
  for(integer j=0;j<8;j=j+1)if(!owned[j])begin
   free_count=free_count+1'b1;if(!found_free)begin found_free=1;free_slot=j;end
  end
 end
 reg management_valid;reg [7:0] management_op;reg [127:0] management_session;
 wire management_ready;wire [31:0] management_rejected;
 s9_session_control #(.PREDICTIVE_LEASE(1)) session(.clk(clk),.rst(rst),.now_ms(now_ms),.now_ms_next(now_ms_next),
  .management_valid(management_valid),.management_ready(management_ready),.management_op(management_op),.management_session(management_session),
  .phone_open_ready(phone_open_ready),.phone_active(phone_active),.phone_close_done(phone_close_done),
  .phone_open(phone_open),.phone_close(phone_close),.flush(session_flush),.session_id(session_id),.link_state(link_state),.session_ready(session_ready),
  .management_done(),.management_error(),.opened_count(),.closed_count(),.expired_count(lease_expirations),.rejected_count(management_rejected));
 assign rejected_transactions=physical_rejected+rejected+management_rejected;
 assign result_ready=!rst&&!session_flush&&!result_pending;
 assign config_payload_changed=load_state==3&&op==4&&session_ready&&r54_equal_1&&serial!=0&&serial==accepted_serial+1&&found_free;
 assign identity_query_prepare=config_payload_changed&&command_bytes[39:32]==39;
 assign identity_prepare_press=command_bytes[127:64];
 // Application QUERY_RESULT/BARRIER are consumed by s9_router on BL616.
 assign lookup_ready=1'b1;assign lookup_error=-16'sd13;assign lookup_result=0;
 reg[735:0] response,status;
 reg[7:0] tx_index,tx_shift;reg[2:0] tx_bit;
 reg[31:0] tx_crc;reg[8:0] tx_map_mask,held_map_mask;
 reg[3:0] map_column;wire[7:0] map_bytes[0:11];
 for(genvar m=0;m<12;m=m+1)assign map_bytes[m]=map_data[m*8+:8];
 wire[6:0] next_header_index=tx_index[6:0]+7'd1;
 wire[7:0] next_byte=tx_index<91?response[{next_header_index,3'b000}+:8]:
  tx_index<199?(tx_map_mask[map_address]?map_bytes[map_column]:8'd0):
  tx_index<203?~(tx_crc >> ((tx_index-199)*8)):8'd0;
 always @*begin
  status=0;status[31:0]=32'h53303252;status[39:32]=3;status[47:40]={5'd0,link_state};
  status[55:48]=(session_ready&&!command_valid&&!command_buffer_busy&&!packet&&load_state==0)?{4'd0,free_count}:8'd0;
  status[63:56]={7'd0,result_pending};status[95:64]=epoch;status[127:96]=accepted_serial;
  status[159:128]=result_serial;status[447:160]=result_hold;status[575:448]=session_id;status[639:576]=phone_next_token;status[640]=phone_token_exhausted;status[656:648]=held_map_mask;status[671:664]={5'd0,accepted_slot};
 end
 assign spi_miso_oe=!rst&&!control_cs_n&&score_cs_n&&sd_cs_n&&transaction&&!bad;
 assign spi_miso=tx_index<204?tx_shift[7-tx_bit]:1'b0;
 always @(posedge serial_clk)begin
  if(rst)begin response<=0;tx_shift<=0;tx_bit<=0;tx_crc<=32'hffffffff;tx_index<=0;map_address<=0;map_column<=0;tx_map_mask<=0; end
  else if(fast_start)begin
    response<=status;tx_shift<=status[7:0];tx_index<=0;tx_bit<=0;
    tx_crc<=crcbyte(32'hffffffff,status[7:0]);tx_map_mask<=held_map_mask;
    map_address<=0;map_column<=0;
  end else if(phy_selected)begin
    if(fast_fall&&tx_index<204)begin
     tx_bit<=tx_bit+1'b1;
     if(tx_bit==7)begin
      tx_index<=tx_index+1'b1;tx_shift<=next_byte;
      if(tx_index<199)tx_crc<=crcbyte(tx_crc,next_byte);
      // Header snapshot remains frozen until the next transaction.
      if(tx_index>=91&&tx_index<199)begin
       if(map_column==11)begin map_column<=0;map_address<=map_address+1'b1;end
       else map_column<=map_column+1'b1;
      end
     end
    end
  end
 end
 always @(posedge clk)begin
  if(rx_write)memory[rx_count-9'd16]<=byte_in;
  read_byte<=memory[cursor];
  
  score_sync<={score_sync[0],score_cs_n};sd_sync<={sd_sync[0],sd_cs_n};
  if(rst)begin
   score_sync<=3;sd_sync<=3;
   transaction<=0;bad<=0;capacity<=0;header<=0;packet_header<=0;packet<=0;
   rx_count<=0;wire_length<=204;expected<=20;rx_bits<=0;rx_shift<=0;rx_crc<=32'hffffffff;footer<=0;watchdog<=0;
   physical_rejected<=0;cs_conflicts<=0;cursor<=0;load_state<=0;
   event_write_valid<=0;event_write_index<=0;event_write_data<=0;event_write_abort<=0;event_column<=0;event_number<=0;event_bad<=0;checked_next_token<=1;checked_exhausted<=0;
   command_payload<=0;command_length<=0;command_slot<=0;command_valid<=0;command_event<=0;
   epoch<=0;accepted_serial<=0;result_serial<=0;owned<=0;channels<=0;result_hold<=0;result_pending<=0;
   management_valid<=0;management_op<=0;management_session<=0;rejected<=0;stale_result_updates<=0;lookup_done<=0;
   held_map_mask<=0;maps_release<=0;
   accepted_slot<=0;held_final<=0;
  end else begin
   event_write_abort<=0;if(event_write_valid&&event_write_ready)event_write_valid<=0;
   management_valid<=0;lookup_done<=lookup_valid;maps_release<=0;
   if(command_valid&&command_ready)command_valid<=0;
   if(result_valid&&result_ready)begin
    if(owned[result_slot]&&channels[result_slot]==result_channel&&result_sequence==0&&r54_equal_2)begin
     result_hold<={24'd0,result_bytes[63:56],result_bytes[447:224],29'd0,result_slot};
     held_map_mask<=result_channel?9'd0:map_mask;
     result_serial<=result_serial+1'b1;result_pending<=1;
     held_final<=result_final;
    end else stale_result_updates<=stale_result_updates+1'b1;
   end
   if(start)begin
    transaction<=1;bad<=!score_sync[1]||!sd_sync[1];capacity<=!packet&&load_state==0;
    header<=0;rx_crc<=32'hffffffff;footer<=0;watchdog<=0;rx_count<=0;rx_bits<=0;rx_shift<=0;expected<=20;wire_length<=204;
    if(!score_sync[1]||!sd_sync[1])cs_conflicts<=cs_conflicts+1'b1;
   end else if(transaction)begin
    if(watchdog<CLK_FREQ_HZ/100)watchdog<=watchdog+1'b1;else bad<=1;
    if((!score_sync[1]||!sd_sync[1])&&!bad)begin bad<=1;cs_conflicts<=cs_conflicts+1'b1;end
    if(phy_selected&&rise)begin
     rx_shift<=byte_in;rx_bits<=rx_bits+1'b1;
     if(rx_bits==7)begin
      if(rx_count<16)begin
       header[rx_count*8+:8]<=byte_in;rx_crc<=crcbyte(rx_crc,byte_in);
       if(rx_count==15)begin
        if(header[63:48]>116)bad<=1;
        else begin expected<=20+header[63:48];wire_length<=header[63:48]>184?20+header[63:48]:204;end
       end
      end else if(rx_count<expected-4)rx_crc<=crcbyte(rx_crc,byte_in);
      else if(rx_count<expected)footer[(rx_count-expected+4)*8+:8]<=byte_in;
      else if(byte_in!=0||rx_count>=wire_length)bad<=1;
      if(rx_count<511)rx_count<=rx_count+1'b1;else bad<=1;
     end
    end
    if(finish)begin
     transaction<=0;
     if(bad||!score_sync[1]||!sd_sync[1]||rx_bits!=0||rx_count!=wire_length||footer!=~rx_crc||header[31:0]!=32'h43303252||header[39:32]!=3||header[47:40]>6)
      physical_rejected<=physical_rejected+1'b1;
     else if(capacity&&(!(command_valid||command_buffer_busy)||(header[47:40]!=1&&header[47:40]!=4&&header[47:40]!=6)))begin packet<=1;packet_header<=header;end
     else if(header[47:40]!=0)physical_rejected<=physical_rejected+1'b1;
    end
   end
   // Synchronous byte RAM -> transitional execution adapter. No application
   // history, second CRC, request compare or per-slot wide payload is retained.
   case(load_state)
    0:if(packet&&(!(command_valid||command_buffer_busy)||(op!=1&&op!=4&&op!=6)))begin
     packet<=0;
     if(op==0)begin end
     else if(op==5)begin
      if(length==0&&r54_equal_1&&result_pending&&r54_equal_3)begin
       result_pending<=0;held_map_mask<=0;if(held_final)owned[result_hold[2:0]]<=0;
       if(!result_hold[32])maps_release<=1;
      end
     end else if(op==2||op==3)begin
      if(length==0&&r54_equal_1)begin management_valid<=1;management_op<=op==2?8'h91:8'h92;management_session<=session_id;end
     end else if((op==1&&length==16)||((op==4||op==6)&&length>=8&&length<=116&&r54_equal_1&&session_ready&&found_free))begin
      cursor<=0;command_payload<=0;load_state<=1;event_column<=0;event_number<=0;event_bad<=0;checked_next_token<=phone_next_token;checked_exhausted<=phone_token_exhausted;
     end else rejected<=rejected+1'b1;
    end
    1:load_state<=2;
    2:if(!event_write_valid)begin
     if(op==6)begin
      if(cursor<8)command_payload[cursor*8+:8]<=read_byte;
      else begin
       event_write_data<=assembled_event;
       if(event_column==11)begin
        event_column<=0;event_write_valid<=1;event_write_index<=event_number;event_number<=event_number+1'b1;
        if(assembled_bad)event_bad<=1;
        if(assembled_kind==1)begin
         checked_next_token<=assembled_event[95:32]+64'd1;
         if(assembled_event[95:32]==64'hffffffffffffffff)checked_exhausted<=1;
        end
       end else event_column<=event_column+1'b1;
      end
     end else command_payload<={(cursor<length?read_byte:8'd0),command_payload[415:8]};
     if(cursor==(op==6?length-1:51))load_state<=3;
     else begin cursor<=cursor+1'b1;load_state<=1;end
    end
    3:if(!event_write_valid)begin
     load_state<=0;
     if(op==6)event_write_abort<=1;
     if(op==1)begin
      if(packet_epoch!=0&&((link_state==0&&phone_open_ready)||(r54_equal_1&&r54_equal_4)))begin
       management_valid<=1;management_op<=8'h90;management_session<=command_bytes[127:0];
       if(link_state==0&&command_bytes[63:0]!=0&&command_bytes[127:64]!=0&&(!r54_equal_5||command_bytes[127:64]>session_id[127:64]))begin epoch<=packet_epoch;accepted_serial<=0;result_serial<=0;end
      end else rejected<=rejected+1'b1;
     end else if(session_ready&&r54_equal_1)begin
      if(serial!=0&&r54_equal_6)begin end // same stop-and-wait transmission
      else if(serial!=0&&serial==accepted_serial+1&&found_free&&((op==4&&length>=8&&length<=52&&command_bytes[63:40]==0)||(op==6&&!event_bad&&command_bytes[39:32]>=1&&command_bytes[39:32]<=9&&command_bytes[63:40]==0&&length==8+command_bytes[39:32]*12)))begin
       command_valid<=1;command_event<=op==6;if(op==6)event_write_abort<=0;command_slot<=free_slot;command_length<=length[7:0];accepted_serial<=serial;
       owned[free_slot]<=1;channels[free_slot]<=op==4;accepted_slot<=free_slot;
      end else rejected<=rejected+1'b1;
     end
    end
   endcase
   if(session_flush)begin event_write_valid<=0;event_write_abort<=1;held_map_mask<=0;maps_release<=1;command_valid<=0;owned<=0;result_pending<=0;load_state<=0;packet<=0;end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin

  if(result_valid&&result_ready&&owned[result_slot]&&(result_channel!=result_bytes[224]))$fatal(1,"R20_RESULT_BINDING");
  if(lookup_valid)$fatal(1,"R20_APPLICATION_LOOKUP_NOT_MIGRATED");
 end
 // synthesis translate_on
 r54_full_equal #(.WIDTH(64)) r54_equal_0_tree(.a(assembled_event[95:32]),.b(checked_next_token),.equal(r54_equal_0));
 r54_full_equal #(.WIDTH(32)) r54_equal_1_tree(.a(packet_epoch),.b(epoch),.equal(r54_equal_1));
 r54_full_equal #(.WIDTH(128)) r54_equal_2_tree(.a(result_bytes[191:64]),.b(session_id),.equal(r54_equal_2));
 r54_full_equal #(.WIDTH(32)) r54_equal_3_tree(.a(serial),.b(result_serial),.equal(r54_equal_3));
 r54_full_equal #(.WIDTH(128)) r54_equal_4_tree(.a(command_bytes[127:0]),.b(session_id),.equal(r54_equal_4));
 r54_full_equal #(.WIDTH(64)) r54_equal_5_tree(.a(command_bytes[63:0]),.b(session_id[63:0]),.equal(r54_equal_5));
 r54_full_equal #(.WIDTH(32)) r54_equal_6_tree(.a(serial),.b(accepted_serial),.equal(r54_equal_6));
endmodule
