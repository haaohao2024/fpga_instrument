// Real STE2 pins -> authenticated application commands / cached execution status.
// Execution endpoints own semantic COMMITTED/EFFECTIVE updates. This module
// never fabricates an effective sample frame from transport completion.
module s9_control_link(
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
 wire fragment_valid,fragment_ready;wire[255:0] fragment_header;wire[1023:0] fragment_payload;wire[7:0] fragment_length;
 wire[31:0] physical_accepted,physical_rejected,physical_timeout;
 wire status_read;wire[511:0] status_snapshot,status_bytes;
 s9_spi_transport u_spi(.clk(clk),.rst(rst),.spi_sck(spi_sck),.control_cs_n(control_cs_n),.score_cs_n(score_cs_n),.sd_cs_n(sd_cs_n),.spi_mosi(spi_mosi),
 .spi_miso(spi_miso),.spi_miso_oe(spi_miso_oe),.status_bytes(status_bytes),.fragment_valid(fragment_valid),.fragment_ready(fragment_ready),
 .fragment_header(fragment_header),.fragment_payload(fragment_payload),.fragment_length(fragment_length),
 .status_read(status_read),.status_snapshot(status_snapshot),.accepted_transactions(physical_accepted),.rejected_transactions(physical_rejected),.cs_conflicts(cs_conflicts),.timeouts(physical_timeout));
 wire management_valid,management_ready;wire[7:0] management_op;wire[127:0] management_session;
 wire management_done;wire signed[15:0] management_error;wire[31:0] opened,closed,management_rejected;
 s9_session_control u_session(.clk(clk),.rst(rst),.now_ms(now_ms),.management_valid(management_valid),.management_ready(management_ready),
 .management_op(management_op),.management_session(management_session),.phone_open_ready(phone_open_ready),.phone_active(phone_active),.phone_close_done(phone_close_done),
 .phone_open(phone_open),.phone_close(phone_close),.flush(session_flush),.session_id(session_id),.link_state(link_state),.session_ready(session_ready),
 .management_done(management_done),.management_error(management_error),.opened_count(opened),.closed_count(closed),.expired_count(lease_expirations),.rejected_count(management_rejected));
 wire request_valid,request_ready;wire[1535:0] request_bytes;wire[7:0] request_length;wire request_channel;wire[31:0] request_sequence;
 wire assembly_error,assembly_error_channel;wire signed[15:0] assembly_error_code;wire[31:0] assembly_error_sequence;
 wire[31:0] assembled,assembly_rejected,duplicate_fragments,assembly_timeouts;
 reg status_pending;
 wire assembly_ready;
 assign fragment_ready=assembly_ready&&!status_pending&&request_ready;
 s9_command_reassembly u_reassembly(.clk(clk),.rst(rst),.flush(session_flush),.session_ready(session_ready),.session_id(session_id),.now_ms(now_ms),
 .fragment_valid(fragment_valid&&!status_pending&&request_ready),.fragment_ready(assembly_ready),.fragment_header(fragment_header),.fragment_payload(fragment_payload),.fragment_length(fragment_length),
 .management_valid(management_valid),.management_ready(management_ready),.management_op(management_op),.management_session(management_session),
 .command_valid(request_valid),.command_ready(request_ready),.command_bytes(request_bytes),.command_length(request_length),.command_channel(request_channel),.command_sequence(request_sequence),
 .error_valid(assembly_error),.error_code(assembly_error_code),.error_channel(assembly_error_channel),.error_sequence(assembly_error_sequence),
 .completed_count(assembled),.rejected_count(assembly_rejected),.duplicate_fragments(duplicate_fragments),.timeout_count(assembly_timeouts));
 wire semantic_legal;wire signed[15:0] semantic_error;
 s9_request_validate u_validate(.command_bytes(request_bytes),.legal(semantic_legal),.error_code(semantic_error));
 wire cache_reply_valid,cache_error,cache_error_channel;wire[511:0] cache_reply;
 wire signed[15:0] cache_error_code;wire[31:0] cache_error_sequence,admitted,retries,cache_rejected;
 wire[3:0] credits;
 wire cache_command_valid;
 assign command_valid=cache_command_valid&&session_ready&&!session_flush;
 wire cache_update_ready;
 assign result_ready=cache_update_ready&&assembly_ready;
 s9_command_cache u_cache(.clk(clk),.rst(rst),.flush(session_flush),.session_id(session_id),
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
  crc=32'hffffffff;for(k=0;k<60;k=k+1)crc=crcbyte(crc,status_build[k*8+:8]);status_build[511:480]=~crc;
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
