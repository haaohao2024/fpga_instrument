
// Validate the page CRC, then reread its pinned transport RAM in place.
// The transport page_busy lease lasts until page_done, including record backpressure.
// The only downstream visibility is through a closed-group record FIFO.
module score_page_parser(
 input wire clk,rst,clear,enable,raw_mode,
 input wire page_valid,output wire page_ready,input wire [31:0] page_sequence,
 output reg page_done,page_ok,
 output wire [8:0] page_addr,input wire [7:0] page_data,
 output reg record_valid,input wire record_ready,output reg [127:0] record_data,
 output reg header_valid,eof_seen,output reg [63:0] end_time,last_verified_time,
 output reg [31:0] total_records,parsed_records,output reg [7:0] error_code
);
 wire raw_enabled=(raw_mode===1'b1);
 wire r54_equal_0;
 wire r54_equal_1;
 wire r54_equal_2;
 wire r54_equal_3;

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
 // One 256 x 32 history bank retains all 128 full timestamps.
 reg [31:0] recent_times[0:255] /* synthesis syn_ramstyle="block_ram" */;
 reg [6:0] recent_ptr;reg [31:0] seen;
 reg [31:0] recent_q;reg [63:0] recent_value;
 wire [7:0] recent_address={recent_ptr,(state==10)};
 wire recent_write=!raw_enabled&&!rst&&!clear&&(state==12||state==13);
 always @(posedge clk)begin
  recent_q<=recent_times[recent_address];
  if(recent_write)recent_times[{recent_ptr,(state==13)}]<=state==13?candidate[63:32]:candidate[31:0];
 end
 assign page_addr=(state>=4&&state<=7)?read_addr:scan_addr;
 wire [63:0] t=candidate[63:0];wire [7:0] op=candidate[71:64],key=candidate[79:72],note=candidate[87:80],value=candidate[95:88];
 wire [31:0] flags=candidate[127:96];
 // One 32-bit subtractor covers chronological and density checks.
 reg time_ge,time_equal,density_ok,subtract_borrow,low_zero;
 reg [31:0] density_low;
 wire subtract_high=state==15||state==17;
 wire [63:0] subtract_reference=state<16?last_time:recent_value;
 wire [31:0] subtract_a=subtract_high?t[63:32]:t[31:0];
 wire [31:0] subtract_b=subtract_high?subtract_reference[63:32]:subtract_reference[31:0];
 wire [32:0] time_difference={1'b0,subtract_a}-{1'b0,subtract_b}-(subtract_high&&subtract_borrow);
 wire valid_record=(flags<=1)&&time_ge&&
  (seen==0||(time_equal?!group_closed:group_closed))&&
  (!time_equal?1:group_count<64)&&
  (seen<128||density_ok)&&
  ((op==1&&key<32&&note<128&&value!=0&&!logical_held[key[4:0]])||
   (op==2&&key<32&&note==0&&value==0&&logical_held[key[4:0]])||
   (op==3&&key<32&&note<128&&logical_held[key[4:0]])||
   (op==4&&key==0&&note==0&&value==0&&flags==1&&r54_equal_0&&parsed_records+1==total_records));
 // Raw mode reuses the exclusive legacy parser frontier/owner registers.
 // group_count is remaining ITEMs; logical_held[2:0] is {last,owner}.
 // last_time high32 retains the last barrier ID; low32 retains target.
 wire raw_head=group_count==0;
 wire [3:0] raw_count=candidate[110:107];
 wire [1:0] raw_owner=candidate[103:102];
 wire [31:0] raw_control=candidate[63:32];
 wire [31:0] raw_target_delta=candidate[31:0]-last_time[31:0];
 wire raw_order=(seen==0)||((raw_target_delta==0)?!group_closed:(!raw_target_delta[31]&&group_closed));
 wire raw_barrier_control=raw_control[31:20]==0&&
   (!raw_control[19]||raw_control[0])&&
   (raw_control[1]?(raw_control[2]?(raw_control[18:3]==0):(raw_control[18:3]!=0)):
    (raw_control[18:2]==0))&&
   (raw_control[1:0]!=0||raw_control==0);
 wire raw_head_format=candidate[127:112]==16'h5248&&!candidate[111]&&candidate[99:97]==0&&
  ((raw_count==0)?
   (candidate[106:100]==7'b0000010&&candidate[96]&&candidate[95:64]!=0&&raw_barrier_control):
   (raw_count<=9&&(raw_owner==1||raw_owner==3)&&candidate[106:104]<=5&&
    (raw_owner==1?candidate[106:104]==0:!candidate[100])&&
    candidate[95:32]==0&&!candidate[96]));
 wire raw_item_format=candidate[127:97]==0&&!candidate[0]&&candidate[95:32]!=0&&
  candidate[31:28]=={2'd0,logical_held[1:0]}&&
  (logical_held[1:0]!=1||candidate[23:16]<32)&&
  candidate[27:24]>=1&&candidate[27:24]<=3&&
  candidate[96]==(group_count==1&&logical_held[2]);
 assign page_ready=!rst&&!clear&&enable&&state==0&&error_code==0&&!eof_seen;
 always @(posedge clk)begin
  page_done<=0;
  if(rst||clear)begin
   expected_data_page<=raw_enabled?0:1;state<=0;scan_addr<=0;copy_index<=0;crc<=32'hffffffff;footer<=0;head<=0;reserved_bad<=0;seq<=0;
   page_done<=0;page_ok<=0;record_valid<=0;record_data<=0;header_valid<=raw_enabled;eof_seen<=0;
   end_time<=0;total_records<=0;parsed_records<=0;error_code<=0;last_verified_time<=0;
   logical_held<=0;last_time<=0;group_closed<=1;group_count<=0;recent_ptr<=0;seen<=0;
   record_index<=0;record_byte<=0;read_addr<=0;candidate<=0;page_count<=0;recent_value<=0;time_ge<=0;time_equal<=0;density_ok<=0;subtract_borrow<=0;low_zero<=0;density_low<=0;
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
     if(!raw_enabled&&seq==0)begin if(copy_index>=28&&copy_index<508&&page_data!=0)reserved_bad<=1;end
     else begin
      if(((copy_index>=6&&copy_index<16)||(copy_index>=16+head[47:32]*16&&copy_index<508))&&page_data!=0)reserved_bad<=1;
     end
     if(copy_index==511)state<=3;
     else begin copy_index<=copy_index+1;scan_addr<=copy_index+1;state<=1;end
    end
    3: begin
     if(footer!=~crc||reserved_bad)begin error_code<=1;state<=8;end
     else if(raw_enabled)begin
      if(head[31:0]!=seq||seq!=expected_data_page)begin error_code<=3;state<=8;end
      else if(head[47:32]==0||head[47:32]>30)begin error_code<=2;state<=8;end
      else begin page_count<=head[47:32];record_index<=0;record_byte<=0;candidate<=0;read_addr<=16;state<=4;end
     end else if(seq==0)begin
      if(header_valid||head[31:0]!=32'h56453753||head[63:32]!=1||head[95:64]!=48000||
       head[127:96]==0||head[127:96]>1000000||head[223:192]>1)begin error_code<=2;state<=8;end
      else begin header_valid<=1;total_records<=head[127:96];end_time<=head[191:128];page_ok<=1;page_done<=1;state<=0;end
     end else if(!header_valid||!r54_equal_1||head[47:32]==0||head[47:32]>30||
       !r54_equal_2||head[47:32]!=((total_records-parsed_records>=30)?30:total_records-parsed_records))begin error_code<=3;state<=8;end
     else begin page_count<=head[47:32];record_index<=0;record_byte<=0;candidate<=0;read_addr<=16;state<=4;end
    end
    4: state<=5;
    5: begin
     candidate<={read_data,candidate[127:8]};
     if(record_byte==15)state<=raw_enabled?6:10;
     else begin record_byte<=record_byte+1;read_addr<=read_addr+1;state<=4;end
    end
    10:begin recent_value[31:0]<=recent_q;state<=11;end
    11:begin recent_value[63:32]<=recent_q;state<=14;end
    14:begin low_zero<=time_difference[31:0]==0;subtract_borrow<=time_difference[32];state<=15;end
    15:begin time_ge<=!time_difference[32];time_equal<=low_zero&&time_difference[31:0]==0;state<=16;end
    16:begin density_low<=time_difference[31:0];subtract_borrow<=time_difference[32];state<=17;end
    17:begin density_ok<=time_difference[31:0]!=0||density_low>=4800;state<=6;end
    12:state<=13;
    13:begin
     if(!raw_enabled)recent_ptr<=recent_ptr+1'b1;
     if(!raw_enabled&&r54_equal_3&&op!=4)begin error_code<=5;state<=8;end
     else if(record_index+1==page_count)begin if(raw_enabled||page_count==30)expected_data_page<=expected_data_page+1;page_ok<=1;page_done<=1;state<=0;end
     else begin record_index<=record_index+1;record_byte<=0;read_addr<=16+(record_index+1)*16;state<=4;end
    end
    6:begin
     if(raw_enabled&&!(raw_head?raw_head_format:raw_item_format))begin error_code<=2;state<=8;end
     else if(raw_enabled&&raw_head&&(!raw_order||(raw_count==0&&candidate[95:64]<=last_time[63:32])))begin error_code<=3;state<=8;end
     else if(!raw_enabled&&!valid_record)begin error_code<=4;state<=8;end
     else begin record_valid<=1;record_data<=candidate;state<=7;end
    end
    7:if(record_valid&&record_ready)begin
     record_valid<=0;parsed_records<=parsed_records+1;seen<=seen+1;state<=12;
     if(raw_enabled)begin
      if(raw_head)begin
       last_time[31:0]<=candidate[31:0];group_count<=raw_count;
       logical_held[2:0]<={candidate[101],raw_owner};group_closed<=raw_count==0;
       if(raw_count==0)last_time[63:32]<=candidate[95:64];
      end else begin group_count<=group_count-1'b1;group_closed<=candidate[96];end
      if(candidate[96])last_verified_time<={32'd0,raw_head?candidate[31:0]:last_time[31:0]};
     end else begin
      last_time<=t;group_closed<=flags[0];group_count<=time_equal?group_count+1:1;
      if(flags[0])last_verified_time<=t;
      if(op==1)logical_held[key[4:0]]<=1;else if(op==2)logical_held[key[4:0]]<=0;
      if(op==4)eof_seen<=1;
     end

    end
    8:begin page_ok<=0;page_done<=1;record_valid<=0;state<=9;end
    9:begin end
   endcase
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst && !clear && !raw_enabled && (state==0 || state==3))begin
  if(expected_data_page!==(parsed_records/30)+1)
   $fatal(1,"PARSER_PAGE_FRONTIER_ORACLE");
 end
 // synthesis translate_on
 wide_equal #(.WIDTH(64)) r54_equal_0_tree(.a(t),.b(end_time),.equal(r54_equal_0));
 wide_equal #(.WIDTH(32)) r54_equal_1_tree(.a(head[31:0]),.b(seq),.equal(r54_equal_1));
 wide_equal #(.WIDTH(32)) r54_equal_2_tree(.a(seq),.b(expected_data_page),.equal(r54_equal_2));
 wide_equal #(.WIDTH(32)) r54_equal_3_tree(.a(parsed_records),.b(total_records),.equal(r54_equal_3));
endmodule

