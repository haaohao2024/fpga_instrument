// Validates complete page CRC before reading any record. Local byte RAM512.
// The only downstream visibility is through a closed-group record FIFO.
module score_file_parser(
 input wire clk,rst,clear,enable,
 input wire page_valid,output wire page_ready,input wire [31:0] page_sequence,
 output reg page_done,page_ok,
 output reg [8:0] page_addr,input wire [7:0] page_data,
 output reg record_valid,input wire record_ready,output reg [127:0] record_data,
 output reg header_valid,eof_seen,output reg [63:0] end_time,last_verified_time,
 output reg [31:0] total_records,parsed_records,output reg [7:0] error_code
);
 function [31:0] crcbyte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer i;begin v=c^b;for(i=0;i<8;i=i+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
 reg [7:0] memory[0:511];
 // Every accepted nonfinal page contains exactly30 records. Track the
 // validated page frontier instead of recomputing a32-bit divide on the
 // validation edge. Full32-bit incoming sequence comparison is retained.
 reg [31:0] expected_data_page;
 reg [7:0] state;reg [8:0] copy_index;reg [31:0] crc,footer,seq;
 reg [223:0] head;reg reserved_bad;
 reg [5:0] page_count,record_index;reg [3:0] record_byte;
 reg [8:0] read_addr;reg [7:0] read_data;reg [127:0] candidate;
 reg [31:0] logical_held;reg [63:0] last_time;reg group_closed;reg [6:0] group_count;
 reg [63:0] recent_times[0:127];reg [6:0] recent_ptr;reg [31:0] seen;
 wire [63:0] t=candidate[63:0];wire [7:0] op=candidate[71:64],key=candidate[79:72],note=candidate[87:80],value=candidate[95:88];
 wire [31:0] flags=candidate[127:96];
 wire valid_record=(flags<=1)&&(t>=last_time)&&
  (seen==0||((t==last_time)?!group_closed:group_closed))&&
  ((t!=last_time)?1:group_count<64)&&
  (seen<128||t-recent_times[recent_ptr]>=4800)&&
  ((op==1&&key<32&&note<128&&value!=0&&!logical_held[key[4:0]])||
   (op==2&&key<32&&note==0&&value==0&&logical_held[key[4:0]])||
   (op==3&&key<32&&note<128&&logical_held[key[4:0]])||
   (op==4&&key==0&&note==0&&value==0&&flags==1&&t==end_time&&parsed_records+1==total_records));
 assign page_ready=!rst&&!clear&&enable&&state==0&&error_code==0&&!eof_seen;
 always @(posedge clk)begin
  read_data<=memory[read_addr];
  page_done<=0;
  if(rst||clear)begin
   expected_data_page<=1;state<=0;page_addr<=0;copy_index<=0;crc<=32'hffffffff;footer<=0;head<=0;reserved_bad<=0;seq<=0;
   page_done<=0;page_ok<=0;record_valid<=0;record_data<=0;header_valid<=0;eof_seen<=0;
   end_time<=0;total_records<=0;parsed_records<=0;error_code<=0;last_verified_time<=0;
   logical_held<=0;last_time<=0;group_closed<=1;group_count<=0;recent_ptr<=0;seen<=0;
   record_index<=0;record_byte<=0;read_addr<=0;candidate<=0;page_count<=0;
  end else begin
   case(state)
    0: if(page_valid&&page_ready)begin
     seq<=page_sequence;copy_index<=0;page_addr<=0;crc<=32'hffffffff;footer<=0;head<=0;reserved_bad<=0;state<=1;
    end
    1: state<=2; // synchronous upstream RAM latency
    2: begin
     memory[copy_index]<=page_data;
     if(copy_index<28)head[copy_index*8+:8]<=page_data;
     if(copy_index<508)crc<=crcbyte(crc,page_data);
     else footer[(copy_index-508)*8+:8]<=page_data;
     if(seq==0)begin if(copy_index>=28&&copy_index<508&&page_data!=0)reserved_bad<=1;end
     else begin
      if(((copy_index>=6&&copy_index<16)||(copy_index>=16+head[47:32]*16&&copy_index<508))&&page_data!=0)reserved_bad<=1;
     end
     if(copy_index==511)state<=3;
     else begin copy_index<=copy_index+1;page_addr<=copy_index+1;state<=1;end
    end
    3: begin
     if(footer!=~crc||reserved_bad)begin error_code<=1;state<=8;end
     else if(seq==0)begin
      if(header_valid||head[31:0]!=32'h56453753||head[63:32]!=1||head[95:64]!=48000||
       head[127:96]==0||head[127:96]>1000000||head[223:192]>1)begin error_code<=2;state<=8;end
      else begin header_valid<=1;total_records<=head[127:96];end_time<=head[191:128];page_ok<=1;page_done<=1;state<=0;end
     end else if(!header_valid||head[31:0]!=seq||head[47:32]==0||head[47:32]>30||
       seq!=expected_data_page||head[47:32]!=((total_records-parsed_records>=30)?30:total_records-parsed_records))begin error_code<=3;state<=8;end
     else begin page_count<=head[47:32];record_index<=0;record_byte<=0;candidate<=0;read_addr<=16;state<=4;end
    end
    4: state<=5;
    5: begin
     candidate[record_byte*8+:8]<=read_data;
     if(record_byte==15)state<=6;
     else begin record_byte<=record_byte+1;read_addr<=read_addr+1;state<=4;end
    end
    6:begin
     if(!valid_record)begin error_code<=4;state<=8;end
     else begin record_valid<=1;record_data<=candidate;state<=7;end
    end
    7:if(record_valid&&record_ready)begin
     record_valid<=0;parsed_records<=parsed_records+1;seen<=seen+1;recent_times[recent_ptr]<=t;recent_ptr<=recent_ptr+1;
     last_time<=t;group_closed<=flags[0];group_count<=(t==last_time)?group_count+1:1;
     if(flags[0])last_verified_time<=t;
     if(op==1)logical_held[key[4:0]]<=1;else if(op==2)logical_held[key[4:0]]<=0;
     if(op==4)eof_seen<=1;
     if(parsed_records+1==total_records&&op!=4)begin error_code<=5;state<=8;end
     else if(record_index+1==page_count)begin if(page_count==30)expected_data_page<=expected_data_page+1;page_ok<=1;page_done<=1;state<=0;end
     else begin record_index<=record_index+1;record_byte<=0;read_addr<=16+(record_index+1)*16;state<=4;end
    end
    8:begin page_ok<=0;page_done<=1;record_valid<=0;state<=9;end
    9:begin end
   endcase
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst && !clear && (state==0 || state==3))begin
  if(expected_data_page!==(parsed_records/30)+1)
   $fatal(1,"PARSER_PAGE_FRONTIER_ORACLE");
 end
 // synthesis translate_on
endmodule

// Validate the page CRC, then reread its pinned transport RAM in place.
// The transport page_busy lease lasts until page_done, including record backpressure.
// The only downstream visibility is through a closed-group record FIFO.
module r28_borrowed_score_parser(
 input wire clk,rst,clear,enable,
 input wire page_valid,output wire page_ready,input wire [31:0] page_sequence,
 output reg page_done,page_ok,
 output wire [8:0] page_addr,input wire [7:0] page_data,
 output reg record_valid,input wire record_ready,output reg [127:0] record_data,
 output reg header_valid,eof_seen,output reg [63:0] end_time,last_verified_time,
 output reg [31:0] total_records,parsed_records,output reg [7:0] error_code
);
 function [31:0] crcbyte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer i;begin v=c^b;for(i=0;i<8;i=i+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
 reg[8:0] scan_addr;
 // Every accepted nonfinal page contains exactly30 records. Track the
 // validated page frontier instead of recomputing a32-bit divide on the
 // validation edge. Full32-bit incoming sequence comparison is retained.
 reg [31:0] expected_data_page;
 reg [7:0] state;reg [8:0] copy_index;reg [31:0] crc,footer,seq;
 reg [223:0] head;reg reserved_bad;
 reg [5:0] page_count,record_index;reg [3:0] record_byte;
 reg [8:0] read_addr;wire [7:0] read_data=page_data;reg [127:0] candidate;
 reg [31:0] logical_held;reg [63:0] last_time;reg group_closed;reg [6:0] group_count;
 reg [63:0] recent_times[0:127];reg [6:0] recent_ptr;reg [31:0] seen;
 assign page_addr=(state>=4&&state<=7)?read_addr:scan_addr;
 wire [63:0] t=candidate[63:0];wire [7:0] op=candidate[71:64],key=candidate[79:72],note=candidate[87:80],value=candidate[95:88];
 wire [31:0] flags=candidate[127:96];
 wire valid_record=(flags<=1)&&(t>=last_time)&&
  (seen==0||((t==last_time)?!group_closed:group_closed))&&
  ((t!=last_time)?1:group_count<64)&&
  (seen<128||t-recent_times[recent_ptr]>=4800)&&
  ((op==1&&key<32&&note<128&&value!=0&&!logical_held[key[4:0]])||
   (op==2&&key<32&&note==0&&value==0&&logical_held[key[4:0]])||
   (op==3&&key<32&&note<128&&logical_held[key[4:0]])||
   (op==4&&key==0&&note==0&&value==0&&flags==1&&t==end_time&&parsed_records+1==total_records));
 assign page_ready=!rst&&!clear&&enable&&state==0&&error_code==0&&!eof_seen;
 always @(posedge clk)begin
  page_done<=0;
  if(rst||clear)begin
   expected_data_page<=1;state<=0;scan_addr<=0;copy_index<=0;crc<=32'hffffffff;footer<=0;head<=0;reserved_bad<=0;seq<=0;
   page_done<=0;page_ok<=0;record_valid<=0;record_data<=0;header_valid<=0;eof_seen<=0;
   end_time<=0;total_records<=0;parsed_records<=0;error_code<=0;last_verified_time<=0;
   logical_held<=0;last_time<=0;group_closed<=1;group_count<=0;recent_ptr<=0;seen<=0;
   record_index<=0;record_byte<=0;read_addr<=0;candidate<=0;page_count<=0;
  end else begin
   case(state)
    0: if(page_valid&&page_ready)begin
     seq<=page_sequence;copy_index<=0;scan_addr<=0;crc<=32'hffffffff;footer<=0;head<=0;reserved_bad<=0;state<=1;
    end
    1: state<=2; // synchronous upstream RAM latency
    2: begin
     if(copy_index<28)head[copy_index*8+:8]<=page_data;
     if(copy_index<508)crc<=crcbyte(crc,page_data);
     else footer[(copy_index-508)*8+:8]<=page_data;
     if(seq==0)begin if(copy_index>=28&&copy_index<508&&page_data!=0)reserved_bad<=1;end
     else begin
      if(((copy_index>=6&&copy_index<16)||(copy_index>=16+head[47:32]*16&&copy_index<508))&&page_data!=0)reserved_bad<=1;
     end
     if(copy_index==511)state<=3;
     else begin copy_index<=copy_index+1;scan_addr<=copy_index+1;state<=1;end
    end
    3: begin
     if(footer!=~crc||reserved_bad)begin error_code<=1;state<=8;end
     else if(seq==0)begin
      if(header_valid||head[31:0]!=32'h56453753||head[63:32]!=1||head[95:64]!=48000||
       head[127:96]==0||head[127:96]>1000000||head[223:192]>1)begin error_code<=2;state<=8;end
      else begin header_valid<=1;total_records<=head[127:96];end_time<=head[191:128];page_ok<=1;page_done<=1;state<=0;end
     end else if(!header_valid||head[31:0]!=seq||head[47:32]==0||head[47:32]>30||
       seq!=expected_data_page||head[47:32]!=((total_records-parsed_records>=30)?30:total_records-parsed_records))begin error_code<=3;state<=8;end
     else begin page_count<=head[47:32];record_index<=0;record_byte<=0;candidate<=0;read_addr<=16;state<=4;end
    end
    4: state<=5;
    5: begin
     candidate[record_byte*8+:8]<=read_data;
     if(record_byte==15)state<=6;
     else begin record_byte<=record_byte+1;read_addr<=read_addr+1;state<=4;end
    end
    6:begin
     if(!valid_record)begin error_code<=4;state<=8;end
     else begin record_valid<=1;record_data<=candidate;state<=7;end
    end
    7:if(record_valid&&record_ready)begin
     record_valid<=0;parsed_records<=parsed_records+1;seen<=seen+1;recent_times[recent_ptr]<=t;recent_ptr<=recent_ptr+1;
     last_time<=t;group_closed<=flags[0];group_count<=(t==last_time)?group_count+1:1;
     if(flags[0])last_verified_time<=t;
     if(op==1)logical_held[key[4:0]]<=1;else if(op==2)logical_held[key[4:0]]<=0;
     if(op==4)eof_seen<=1;
     if(parsed_records+1==total_records&&op!=4)begin error_code<=5;state<=8;end
     else if(record_index+1==page_count)begin if(page_count==30)expected_data_page<=expected_data_page+1;page_ok<=1;page_done<=1;state<=0;end
     else begin record_index<=record_index+1;record_byte<=0;read_addr<=16+(record_index+1)*16;state<=4;end
    end
    8:begin page_ok<=0;page_done<=1;record_valid<=0;state<=9;end
    9:begin end
   endcase
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst && !clear && (state==0 || state==3))begin
  if(expected_data_page!==(parsed_records/30)+1)
   $fatal(1,"PARSER_PAGE_FRONTIER_ORACLE");
 end
 // synthesis translate_on
endmodule
