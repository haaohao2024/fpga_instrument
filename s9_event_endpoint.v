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
