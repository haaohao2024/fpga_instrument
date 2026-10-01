// 50MHz oversampled Mode0 shared-SPI slave. RAM content is never reset.
// A page is visible only after both complete transaction and CRC validation.
module score_spi_transport # (parameter integer WATCHDOG_CLOCKS=5000000)(
 input wire clk,rst,spi_sck,fpga_cs_n,sd_cs_n,spi_mosi,
 output wire spi_miso,spi_miso_oe,
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
);
 function [31:0] crcbyte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer i;begin v=c^b;for(i=0;i<8;i=i+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
 reg [2:0] ss,cs;reg [1:0] ms,ds;
 wire rise=ss[2:1]==2'b01,fall=ss[2:1]==2'b10;
 wire select_start=cs[2:1]==2'b10,select_end=cs[2:1]==2'b01;
 reg [7:0] memory[0:511];
 reg [255:0] header,response;
 reg [31:0] rx_crc,footer,last_sequence;
 reg [9:0] byte_count,expected_bytes;
 reg [2:0] bit_count;reg [7:0] rx_shift;
 reg [8:0] tx_index;
 reg in_transaction,bad,ram_available,page_busy;
 reg [63:0] pending_epoch;
 reg [31:0] pending_sequence;
 reg [31:0] watchdog;
 reg [255:0] status_tmp;reg [31:0] status_crc;integer k;
 wire [7:0] next_byte={rx_shift[6:0],ms[1]};
 wire [7:0] command=header[47:40];
 wire [63:0] epoch=header[127:64],argument=header[255:192];
 wire [31:0] request_sequence=header[159:128];
 wire [15:0] length=header[175:160];
 assign spi_miso_oe=!rst&&!fpga_cs_n&&sd_cs_n&&in_transaction&&!bad&&tx_index<256;
 assign spi_miso=(tx_index<256)?response[255-tx_index]:1'b0;
 always @(*)begin
  status_tmp=0;status_tmp[31:0]=32'h54533753;status_tmp[39:32]=1;
  status_tmp[47:40]=player_error;status_tmp[55:48]={6'd0,reload_request,(!page_busy&&page_ready)};
  status_tmp[63:56]=player_state;status_tmp[127:64]=active_epoch;
  status_tmp[159:128]=last_sequence;status_tmp[191:160]=accepted_pages;
  status_tmp[223:192]=rejected_transactions;
  status_crc=32'hffffffff;for(k=0;k<28;k=k+1)status_crc=crcbyte(status_crc,status_tmp[k*8+:8]);
  status_tmp[255:224]=~status_crc;
 end
 integer j;
 always @(posedge clk)begin
  ss<={ss[1:0],spi_sck};cs<={cs[1:0],fpga_cs_n};ms<={ms[0],spi_mosi};ds<={ds[0],sd_cs_n};
  page_data<=memory[page_addr];
  if(rst)begin
   ss<=0;cs<=7;ds<=3;ms<=0;ctrl_valid<=0;page_valid<=0;page_busy<=0;
   header<=0;response<=0;rx_crc<=32'hffffffff;footer<=0;last_sequence<=32'hffffffff;
   byte_count<=0;bit_count<=0;tx_index<=0;expected_bytes<=36;in_transaction<=0;bad<=0;
   active_epoch<=0;accepted_pages<=0;rejected_transactions<=0;cs_conflicts<=0;
   watchdog<=0;link_timeout<=0;pending_epoch<=0;pending_sequence<=0;
   ctrl_cmd<=0;ctrl_epoch<=0;ctrl_arg<=0;page_sequence<=0;ram_available<=0;rx_shift<=0;
  end else begin
   if(active_epoch!=0&&player_state!=0)begin
    if(watchdog<WATCHDOG_CLOCKS)watchdog<=watchdog+1;
    else if(!ctrl_valid)begin ctrl_valid<=1;ctrl_cmd<=7;ctrl_epoch<=active_epoch;ctrl_arg<=0;link_timeout<=1;end
   end
   if(ctrl_valid&&ctrl_ready)begin
    ctrl_valid<=0;
    if(ctrl_cmd==1)begin active_epoch<=ctrl_epoch;last_sequence<=32'hffffffff;accepted_pages<=0;page_busy<=0;page_valid<=0;link_timeout<=0;watchdog<=0;end
   end
   if(page_valid&&page_ready)page_valid<=0;
   if(page_done&&page_busy)begin
    page_busy<=0;
    if(page_ok&&pending_epoch==active_epoch)begin last_sequence<=pending_sequence;accepted_pages<=accepted_pages+1;end
    else rejected_transactions<=rejected_transactions+1;
   end
   if(select_start)begin
    in_transaction<=1;header<=0;footer<=0;byte_count<=0;bit_count<=0;rx_shift<=0;tx_index<=0;
    expected_bytes<=36;rx_crc<=32'hffffffff;bad<=!ds[1];ram_available<=!page_busy&&page_ready;
    // Reverse byte order for wire MSB-first, without reversing bits within a byte.
    for(j=0;j<32;j=j+1)response[255-j*8-:8]<=status_tmp[j*8+:8];
    if(!ds[1])cs_conflicts<=cs_conflicts+1;
   end
   if(in_transaction&&!ds[1]&&!bad)begin bad<=1;cs_conflicts<=cs_conflicts+1;end
   if(in_transaction&&!cs[2]&&rise)begin
    rx_shift<=next_byte;bit_count<=bit_count+1'b1;
    if(bit_count==7)begin
     if(byte_count<32)begin
      header[byte_count*8+:8]<=next_byte;
      rx_crc<=crcbyte(rx_crc,next_byte);
      if(byte_count==31)begin
       if(header[175:160]>512)bad<=1;
       else expected_bytes<=36+header[175:160];
      end
     end else if(byte_count<expected_bytes-4)begin
      rx_crc<=crcbyte(rx_crc,next_byte);
      if(ram_available&&byte_count<544)memory[byte_count-32]<=next_byte;
     end else if(byte_count<expected_bytes)footer[(byte_count-(expected_bytes-4))*8+:8]<=next_byte;
     else bad<=1;
     if(byte_count<1023)byte_count<=byte_count+1;else bad<=1;
    end
   end
   if(in_transaction&&fall&&tx_index<256)tx_index<=tx_index+1;
   if(select_end&&in_transaction)begin
    in_transaction<=0;
    if(bad||bit_count!=0||byte_count!=expected_bytes||footer!=~rx_crc||
       header[31:0]!=32'h4b503753||header[39:32]!=1||header[63:48]!=0||header[191:176]!=0||
       (command==2 ? length!=512 : length!=0))rejected_transactions<=rejected_transactions+1;
    else if(command==8)watchdog<=0;
    else if(command==2)begin
     watchdog<=0;
     if(epoch!=active_epoch||active_epoch==0)rejected_transactions<=rejected_transactions+1;
     else if(request_sequence==last_sequence&&accepted_pages!=0)begin end // ACK-only retry
     else if(request_sequence!=last_sequence+1||!ram_available||page_busy)rejected_transactions<=rejected_transactions+1;
     else begin page_valid<=1;page_busy<=1;page_sequence<=request_sequence;pending_epoch<=epoch;pending_sequence<=request_sequence;end
    end else if(command>=1&&command<=7&&!ctrl_valid&&
       ((command==1&&epoch!=0&&epoch!=active_epoch&&player_state==0&&argument<4)||
        (command!=1&&epoch==active_epoch&&active_epoch!=0)))begin
     ctrl_valid<=1;ctrl_cmd<=command;ctrl_epoch<=epoch;ctrl_arg<=argument;watchdog<=0;
    end else rejected_transactions<=rejected_transactions+1;
   end
  end
 end
endmodule
