// Two 256-byte synchronous RAM banks, one for each RT/CFG contiguous prefix.
// Physical fragments have already passed S9PK/CS/CRC validation. This layer
// verifies identity, overlap, whole S9AP length/header/CRC before exposing bytes.
module s9_command_reassembly (
 input wire clk,rst,flush,session_ready,
 input wire [127:0] session_id,input wire [31:0] now_ms,
 input wire fragment_valid,output wire fragment_ready,
 input wire [255:0] fragment_header,input wire [1023:0] fragment_payload,
 input wire [7:0] fragment_length,
 output reg management_valid,input wire management_ready,
 output reg [7:0] management_op,output reg [127:0] management_session,
 output reg command_valid,input wire command_ready,
 output reg [1535:0] command_bytes,output reg [7:0] command_length,
 output reg command_channel,output reg [31:0] command_sequence,
 output reg error_valid,output reg signed[15:0] error_code,
 output reg error_channel,output reg[31:0] error_sequence,
 output reg[31:0] completed_count,rejected_count,duplicate_fragments,timeout_count
);
 localparam IDLE=0,COPY=1,COMPARE_WAIT=2,COMPARE=3,SCAN_WAIT=4,SCAN=5,CHECK=6;
 reg[2:0] state;
 reg[7:0] memory[0:511];
 reg[7:0] used[0:1];reg[31:0] message_seq[0:1],started[0:1],progress[0:1];
 reg[1:0] active_bank;
 reg channel;reg[1023:0] payload;reg[7:0] offset,length,index,total;
 reg[31:0] crc;reg[8:0] read_address;reg[7:0] read_data;
 wire[7:0] operation=fragment_header[47:40];
 wire incoming_channel=operation[0];
 wire[31:0] incoming_sequence=fragment_header[223:192];
 wire[15:0] incoming_offset=fragment_header[239:224];
 wire incoming_expired=active_bank[incoming_channel]&&
  ((now_ms-progress[incoming_channel]>=250)||(now_ms-started[incoming_channel]>=3000));

 assign fragment_ready=!rst&&!flush&&state==IDLE&&!command_valid&&!management_valid;
 function[31:0] crcbyte(input[31:0] c,input[7:0] b);
  reg[31:0] v;integer k;begin v=c^b;for(k=0;k<8;k=k+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
 always @*read_address={channel,8'd0}+offset+index;
 wire [7:0] payload_words[0:127];
 generate for(genvar b=0;b<128;b=b+1)begin: payload_word
  assign payload_words[b]=payload[b*8+:8];
 end endgenerate
 integer i;
 always @(posedge clk)begin
  read_data<=memory[read_address];
  if(rst)begin
   state<=IDLE;active_bank<=0;channel<=0;payload<=0;offset<=0;length<=0;index<=0;total<=0;crc<=32'hffffffff;
   management_valid<=0;management_op<=0;management_session<=0;
   command_valid<=0;command_bytes<=0;command_length<=0;command_channel<=0;command_sequence<=0;
   error_valid<=0;error_code<=0;error_channel<=0;error_sequence<=0;
   completed_count<=0;rejected_count<=0;duplicate_fragments<=0;timeout_count<=0;
   for(i=0;i<2;i=i+1)begin used[i]<=0;message_seq[i]<=0;started[i]<=0;progress[i]<=0;end
  end else if(flush)begin
   state<=IDLE;active_bank<=0;management_valid<=0;command_valid<=0;error_valid<=0;
   used[0]<=0;used[1]<=0;
  end else begin
   error_valid<=0;
   if(command_valid&&command_ready)command_valid<=0;
   if(management_valid&&management_ready)management_valid<=0;
   case(state)
   IDLE:if(fragment_valid&&fragment_ready)begin
    error_channel<=incoming_channel;error_sequence<=incoming_sequence;
    if(operation==8'h80||operation==8'h90||operation==8'h91||operation==8'h92)begin
     management_valid<=1;management_op<=operation;management_session<=fragment_header[191:64];
    end else if(operation>1||fragment_length==0||fragment_length>128||incoming_offset>192||fragment_length>192-incoming_offset)begin
     error_valid<=1;error_code<=-1;rejected_count<=rejected_count+1'b1;
    end else if(!session_ready||fragment_header[191:64]!=session_id)begin
     error_valid<=1;error_code<=-5;rejected_count<=rejected_count+1'b1;
    end else if(incoming_expired)begin
     active_bank[incoming_channel]<=0;used[incoming_channel]<=0;
     error_valid<=1;error_code<=-8;timeout_count<=timeout_count+1'b1;rejected_count<=rejected_count+1'b1;
    end else if((active_bank[incoming_channel]&&message_seq[incoming_channel]!=incoming_sequence)||
       (!active_bank[incoming_channel]&&incoming_offset!=0)||
       (active_bank[incoming_channel]&&incoming_offset>used[incoming_channel]))begin
     error_valid<=1;error_code<=-6;rejected_count<=rejected_count+1'b1;
    end else if(active_bank[incoming_channel]&&incoming_offset<used[incoming_channel]&&
       incoming_offset+fragment_length>used[incoming_channel])begin
     error_valid<=1;error_code<=-9;rejected_count<=rejected_count+1'b1;
    end else begin
     channel<=incoming_channel;offset<=incoming_offset[7:0];length<=fragment_length;index<=0;payload<=fragment_payload;
     if(!active_bank[incoming_channel])begin
      active_bank[incoming_channel]<=1;used[incoming_channel]<=0;message_seq[incoming_channel]<=incoming_sequence;
      started[incoming_channel]<=now_ms;progress[incoming_channel]<=now_ms;
     end
     state<=active_bank[incoming_channel]&&incoming_offset<used[incoming_channel]?COMPARE_WAIT:COPY;
    end
   end
   COPY:begin
    memory[{channel,8'd0}+offset+index]<=payload_words[index];
    if(index+1'b1==length)begin
     used[channel]<=offset+length;progress[channel]<=now_ms;
     if(offset+length>=32)begin
      total<=offset+length;offset<=0;index<=0;command_bytes<=0;crc<=32'hffffffff;state<=SCAN_WAIT;
     end else state<=IDLE;
    end else index<=index+1'b1;
   end
   COMPARE_WAIT:state<=COMPARE;
   COMPARE:begin
    if(read_data!=payload_words[index])begin
     error_valid<=1;error_code<=-9;error_channel<=channel;error_sequence<=message_seq[channel];
     rejected_count<=rejected_count+1'b1;state<=IDLE;
    end else if(index+1'b1==length)begin duplicate_fragments<=duplicate_fragments+1'b1;state<=IDLE;end
    else begin index<=index+1'b1;state<=COMPARE_WAIT;end
   end
   SCAN_WAIT:state<=SCAN;
   SCAN:begin
    for(integer b=0;b<192;b=b+1)if(index==b)command_bytes[b*8+:8]<=read_data;
    if(index<total-4)crc<=crcbyte(crc,read_data);
    if(index+1'b1==total)state<=CHECK;
    else begin index<=index+1'b1;state<=SCAN_WAIT;end
   end
   CHECK:begin
    state<=IDLE;
    if(command_bytes[31:0]!=32'h50413953||command_bytes[39:32]!=1||command_bytes[47:40]!={7'd0,channel}||
       command_bytes[63:56]!=0||command_bytes[255:240]!=0||command_bytes[191:64]!=session_id||
       command_bytes[223:192]!=message_seq[channel]||message_seq[channel]==0||command_bytes[239:224]>156||
       total>36+command_bytes[239:224])begin
     active_bank[channel]<=0;used[channel]<=0;error_valid<=1;error_code<=-2;
     error_channel<=channel;error_sequence<=message_seq[channel];rejected_count<=rejected_count+1'b1;
    end else if(total==36+command_bytes[239:224])begin
     active_bank[channel]<=0;used[channel]<=0;
     if(command_bytes[(total-4)*8+:32]!=~crc)begin
      error_valid<=1;error_code<=-3;error_channel<=channel;error_sequence<=message_seq[channel];rejected_count<=rejected_count+1'b1;
     end else begin
      command_valid<=1;command_length<=total;command_channel<=channel;command_sequence<=message_seq[channel];completed_count<=completed_count+1'b1;
     end
    end
   end
   default:state<=IDLE;
   endcase
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if((^{flush,session_ready,fragment_valid,command_ready,management_ready})===1'bx)$fatal(1,"S9_REASSEMBLY_CONTROL_XZ");
  if(fragment_valid&&(^({fragment_header,fragment_length}))===1'bx)$fatal(1,"S9_REASSEMBLY_HEADER_XZ");
  if(fragment_valid)for(integer k=0;k<fragment_length;k=k+1)
   if((^fragment_payload[k*8+:8])===1'bx)$fatal(1,"S9_REASSEMBLY_PAYLOAD_XZ");
 end
 // synthesis translate_on
endmodule
