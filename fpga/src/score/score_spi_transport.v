// comm_clk (80 MHz) oversampled Mode0 shared-SPI slave. RAM content is never reset.
// A page is visible only after both complete transaction and CRC validation.
module score_spi_transport # (parameter integer RAW_ONLY=0,EXTERNAL_SCORE_RX=0,COMM_SEPARATE=0, WATCHDOG_CLOCKS=5000000, ENABLE_S10_ROUTE=0, ENABLE_FIELD=0, STREAM_STATUS_CRC=0)(
 input wire comm_clk,clk,rst,spi_sck,fpga_cs_n,sd_cs_n,spi_mosi,
 input wire raw_mode,capture_caught_up,raw_published_valid,raw_barrier_busy,
 input wire [31:0] raw_frame,raw_last_audible,raw_completed_barrier,
 output reg ctrl_raw,
 output wire spi_miso,spi_miso_oe,
 output wire [255:0] observe_status_bytes,
 output reg ctrl_valid, input wire ctrl_ready,
 output reg [7:0] ctrl_cmd, output reg [63:0] ctrl_epoch,ctrl_arg,
 output reg page_valid,input wire page_ready,
 output reg [31:0] page_sequence,
 input wire page_done,page_ok,
 input wire [8:0] page_addr,output reg [7:0] page_data,
 input wire [7:0] player_state,player_error,input wire reload_request,
 output reg [63:0] active_epoch,
 output reg [31:0] accepted_pages,rejected_transactions,cs_conflicts,
 output reg link_timeout
 ,input wire field_busy,input wire [540:0] shared_score_rx
);
 wire r54_equal_0;
 wire r54_equal_1;
 wire r54_equal_2;

 function [31:0] crcbyte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer i;begin v=c^b;for(i=0;i<8;i=i+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
 reg [1:0] ds;
 wire rise,fall,select_start,select_end,phy_selected,phy_bit,fast_start,fast_fall,fast_selected;
 wire serial_clk=COMM_SEPARATE?comm_clk:clk;
 generate if(!EXTERNAL_SCORE_RX)begin: own_front
 spi_edge_sampler #(.COMM_SEPARATE(COMM_SEPARATE)) phy(.clk(clk),.comm_clk(comm_clk),.rst(rst),
 .sck(spi_sck),.cs_n(fpga_cs_n),.mosi(spi_mosi),.rise(rise),.fall(fall),.start(select_start),.finish(select_end),
 .selected(phy_selected),.bit_data(phy_bit),.fast_start(fast_start),.fast_fall(fast_fall),.fast_selected(fast_selected));
 end else begin: shared_front
  // Shared bit1 was an unused slow-fall indication; it now carries
  // the original fast-domain select for TX. All payload bit offsets stay.
  assign {fast_fall,fast_start,phy_bit,phy_selected,select_end,select_start,fast_selected,rise}=shared_score_rx[7:0];
  assign fall=1'b0;
 end endgenerate

 reg [7:0] memory[0:511];
 reg [255:0] local_header,local_response;
 wire [255:0] header=EXTERNAL_SCORE_RX?shared_score_rx[284:29]:local_header;
 wire [255:0] response=EXTERNAL_SCORE_RX?shared_score_rx[540:285]:local_response;
 reg [31:0] rx_crc,footer,last_sequence;
 reg [9:0] local_byte_count,expected_bytes;
 wire [9:0] byte_count=EXTERNAL_SCORE_RX?shared_score_rx[28:19]:local_byte_count;
 reg [2:0] local_bit_count;reg [7:0] local_rx_shift;
 wire [2:0] bit_count=EXTERNAL_SCORE_RX?shared_score_rx[18:16]:local_bit_count;
 wire [7:0] rx_shift=EXTERNAL_SCORE_RX?shared_score_rx[15:8]:local_rx_shift;
 reg [8:0] tx_index;
 reg in_transaction,bad,ram_available,page_busy;
 reg transaction_s10;
 reg [63:0] pending_epoch;
 reg [31:0] pending_sequence;
 reg [31:0] watchdog;
 reg [255:0] status_tmp;reg [31:0] status_crc;integer k;
 wire [1:0] footer_lane=byte_count[1:0]-expected_bytes[1:0];
 wire [7:0] next_byte={rx_shift[6:0],phy_bit};
 wire request_raw=header[39:32]==2;
 wire [7:0] command=header[47:40];
 wire [63:0] epoch=header[127:64],argument=header[255:192];
 wire [31:0] request_sequence=header[159:128];
 wire [15:0] length=header[175:160];
 assign observe_status_bytes=status_tmp;
 assign spi_miso_oe=!rst&&!fpga_cs_n&&sd_cs_n&&fast_selected&&tx_index<256;
 // The actual protocol first byte is fixed magic; capture it at fast CS
 // so even a zero-extra-setup master sees the first bit on time.
 reg [7:0] first_tx_byte;
 always @(posedge serial_clk)if(rst)first_tx_byte<=0;else if(fast_start)first_tx_byte<=status_tmp[7:0];
 assign spi_miso=tx_index<8?first_tx_byte[~tx_index[2:0]]:(tx_index<256?response[~tx_index[7:0]]:1'b0);
 always @(*)begin
  status_tmp=0;status_tmp[31:0]=32'h54533753;status_tmp[39:32]=1;
  status_tmp[47:40]=player_error;status_tmp[55:48]={6'd0,reload_request,(!page_busy&&page_ready)};
  status_tmp[63:56]=player_state;status_tmp[127:64]=active_epoch;
  // Bytes 20..27 (page/reject counters) are unused by BL616; constant zero.
  status_tmp[159:128]=last_sequence;status_tmp[191:160]=32'd0;
  status_tmp[223:192]=32'd0;
  if(raw_mode)begin
   // Keep S7ST magic: the shared S11 SPI route chooses its encoder after byte4.
   status_tmp[39:32]=2;status_tmp[55:48]={3'd0,raw_published_valid,raw_barrier_busy,
    capture_caught_up,(player_state!=0),(!page_busy&&page_ready)};
   status_tmp[63:56]=player_state==0?0:player_state==4?3:raw_barrier_busy?2:1;
   status_tmp[95:64]=active_epoch[31:0];status_tmp[127:96]=last_sequence;
   status_tmp[159:128]=raw_frame;status_tmp[191:160]=raw_last_audible;
   status_tmp[223:192]=raw_completed_barrier;
  end
  status_crc=32'hffffffff;if(!STREAM_STATUS_CRC)for(k=0;k<28;k=k+1)status_crc=crcbyte(status_crc,status_tmp[k*8+:8]);
  status_tmp[255:224]=~status_crc;
 end
 // The first28 transmitted bytes freeze on the original CS edge. Compute
 // their CRC in idle receive-byte slots; the earliest CRC bit is >=448
 // system clocks later (28bytes*8bits*2 edges), versus <=30 prepare clocks.
 // In streamed mode the internal exported CRC field is unprepared. Its
 // sole formal consumer, media transport, computes its own frozen copy.
 reg response_crc_busy;reg [4:0] response_crc_index;
 reg [31:0] response_crc_value;
 wire receive_crc_step=!select_start && in_transaction && phy_selected && rise && bit_count==7 &&
     (byte_count<32 || (!transaction_s10 && byte_count<expected_bytes-4));
 wire [7:0] frozen_crc_byte=response[{~response_crc_index,3'b111}-:8];
 wire [31:0] scheduled_crc_next=crcbyte(receive_crc_step?rx_crc:response_crc_value,
     receive_crc_step?next_byte:frozen_crc_byte);
 wire [31:0] received_crc_next=EXTERNAL_SCORE_RX?crcbyte(rx_crc,next_byte):STREAM_STATUS_CRC?scheduled_crc_next:crcbyte(rx_crc,next_byte);
 wire [31:0] completed_response_crc=~scheduled_crc_next;
 always @(posedge serial_clk)begin
  if(rst||fast_start)tx_index<=0;
  else if(fast_selected&&fast_fall&&tx_index<256)tx_index<=tx_index+1'b1;
 end
 integer j;
 always @(posedge clk)begin
  ds<={ds[0],sd_cs_n};
  page_data<=memory[page_addr];
  if(rst)begin
   response_crc_busy<=0;response_crc_index<=0;response_crc_value<=32'hffffffff;
   ds<=3;ctrl_valid<=0;ctrl_raw<=0;page_valid<=0;page_busy<=0;
   transaction_s10<=0;local_header<=0;local_response<=0;rx_crc<=32'hffffffff;footer<=0;last_sequence<=32'hffffffff;
   local_byte_count<=0;local_bit_count<=0;expected_bytes<=36;in_transaction<=0;bad<=0;
   active_epoch<=0;accepted_pages<=0;rejected_transactions<=0;cs_conflicts<=0;
   watchdog<=0;link_timeout<=0;pending_epoch<=0;pending_sequence<=0;
   ctrl_cmd<=0;ctrl_epoch<=0;ctrl_arg<=0;page_sequence<=0;ram_available<=0;local_rx_shift<=0;
  end else begin
   if(STREAM_STATUS_CRC && !EXTERNAL_SCORE_RX && response_crc_busy && !receive_crc_step && !select_start)begin
    response_crc_value<=scheduled_crc_next;
    if(response_crc_index==27)begin
     for(integer b=0;b<4;b++)local_response[31-b*8-:8]<=completed_response_crc[b*8+:8];
     response_crc_busy<=0;
    end else response_crc_index<=response_crc_index+1'b1;
   end
   if(active_epoch!=0&&player_state!=0&&!(ENABLE_FIELD&&field_busy))begin
    if(watchdog<WATCHDOG_CLOCKS)watchdog<=watchdog+1;
    else if(!ctrl_valid)begin ctrl_valid<=1;ctrl_cmd<=7;ctrl_raw<=raw_mode;ctrl_epoch<=active_epoch;ctrl_arg<=0;link_timeout<=1;end
   end
   if(ctrl_valid&&ctrl_ready)begin
    ctrl_valid<=0;
    if(ctrl_cmd==1)begin active_epoch<=ctrl_epoch;last_sequence<=32'hffffffff;accepted_pages<=0;page_busy<=0;page_valid<=0;link_timeout<=0;watchdog<=0;end
   end
   if(raw_mode&&player_state==4)begin page_valid<=0;page_busy<=0;end
   if(page_valid&&page_ready)page_valid<=0;
   if(page_done&&page_busy)begin
    page_busy<=0;
    if(page_ok&&r54_equal_0)begin last_sequence<=pending_sequence;accepted_pages<=accepted_pages+1;end
    else rejected_transactions<=rejected_transactions+1;
   end
   if(select_start)begin
    if(STREAM_STATUS_CRC&&!EXTERNAL_SCORE_RX)begin response_crc_busy<=1;response_crc_index<=0;response_crc_value<=32'hffffffff;end
    in_transaction<=1;transaction_s10<=0;local_header<=0;footer<=0;local_byte_count<=0;local_bit_count<=0;local_rx_shift<=0;
    expected_bytes<=36;rx_crc<=32'hffffffff;bad<=!ds[1];ram_available<=!page_busy&&page_ready;
    // Reverse byte order for wire MSB-first, without reversing bits within a byte.
    for(j=0;j<32;j=j+1)local_response[255-j*8-:8]<=status_tmp[j*8+:8];
    if(!ds[1])cs_conflicts<=cs_conflicts+1;
   end
   if(in_transaction&&!ds[1]&&!bad)begin bad<=1;cs_conflicts<=cs_conflicts+1;end
   if(in_transaction&&phy_selected&&rise)begin
    local_rx_shift<=next_byte;local_bit_count<=bit_count+1'b1;
    if(bit_count==7)begin
     if(byte_count<32)begin
      for(integer hb=0;hb<32;hb=hb+1)if(byte_count==hb)local_header[hb*8+:8]<=next_byte;
      rx_crc<=received_crc_next;
      if(ENABLE_S10_ROUTE && byte_count==3 && ({next_byte,header[23:0]}==32'h50303153||{next_byte,header[23:0]}==32'h50313153))transaction_s10<=1;
      if(byte_count==31 && !transaction_s10)begin
       if(header[175:160]>512)bad<=1;
       else expected_bytes<=36+header[175:160];
      end
     end else if(transaction_s10)begin
      // S10 owns this transaction. Never write the score RAM or commit a score command.
     end else if(byte_count<expected_bytes-4)begin
      rx_crc<=received_crc_next;
      if(ram_available&&byte_count<544)memory[byte_count-32]<=next_byte;
     end else if(byte_count<expected_bytes)case(footer_lane)
       0:footer[7:0]<=next_byte;1:footer[15:8]<=next_byte;2:footer[23:16]<=next_byte;3:footer[31:24]<=next_byte;
      endcase
     else bad<=1;
     if(byte_count<1023)local_byte_count<=byte_count+1;else bad<=1;
    end
   end

   if(select_end&&in_transaction)begin
    in_transaction<=0;
    if(transaction_s10)begin end // new handler owns validation and diagnostics
    else if(bad||bit_count!=0||byte_count!=expected_bytes||footer!=~rx_crc||(RAW_ONLY&&!request_raw)||
       header[31:0]!=32'h4b503753||(header[39:32]!=1&&!request_raw)||header[63:48]!=0||header[191:176]!=0||
       (command==2 ? length!=512 : length!=0)||
       (request_raw&&(epoch[63:32]!=0||epoch[31:0]==0||argument!=0||
         (command!=2&&request_sequence!=0)||
         (command!=1&&command!=2&&command!=3&&command!=8))))rejected_transactions<=rejected_transactions+1;
    else if(command!=1&&request_raw!=raw_mode)rejected_transactions<=rejected_transactions+1;
    else if(command==8)begin
     if(!request_raw||r54_equal_1)watchdog<=0;
     else rejected_transactions<=rejected_transactions+1;
    end
    else if(ENABLE_FIELD&&field_busy)rejected_transactions<=rejected_transactions+1;
    else if(command==2)begin
     watchdog<=0;
     if(!r54_equal_1||active_epoch==0)rejected_transactions<=rejected_transactions+1;
     else if(r54_equal_2&&accepted_pages!=0)begin end // ACK-only retry
     else if(request_sequence!=last_sequence+1||!ram_available||page_busy)rejected_transactions<=rejected_transactions+1;
     else begin page_valid<=1;page_busy<=1;page_sequence<=request_sequence;pending_epoch<=epoch;pending_sequence<=request_sequence;end
    end else if(command>=1&&command<=7&&!ctrl_valid&&
       ((command==1&&epoch!=0&&!r54_equal_1&&player_state==0&&argument<4)||
        (command!=1&&r54_equal_1&&active_epoch!=0)))begin
     ctrl_valid<=1;ctrl_raw<=request_raw;ctrl_cmd<=command;ctrl_epoch<=epoch;ctrl_arg<=argument;watchdog<=0;
     if(request_raw&&command==3)begin page_busy<=0;page_valid<=0;end
    end else rejected_transactions<=rejected_transactions+1;
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst && STREAM_STATUS_CRC && !EXTERNAL_SCORE_RX && in_transaction &&
     tx_index>=224 && tx_index<256 && response_crc_busy)
  $fatal(1,"SCORE_STATUS_CRC_DEADLINE");
 // synthesis translate_on
 wide_equal #(.WIDTH(64)) r54_equal_0_tree(.a(pending_epoch),.b(active_epoch),.equal(r54_equal_0));
 wide_equal #(.WIDTH(64)) r54_equal_1_tree(.a(epoch),.b(active_epoch),.equal(r54_equal_1));
 wide_equal #(.WIDTH(32)) r54_equal_2_tree(.a(request_sequence),.b(last_sequence),.equal(r54_equal_2));
endmodule
