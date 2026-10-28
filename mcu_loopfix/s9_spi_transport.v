// Oversampled 50MHz / Mode0 control slave, bounded 2MHz shared SPI contract.
// Outputs become valid only at a complete CS end with BOTH CRC and pad checked.
// Physical fragment staging is 128 bytes of registers; application RAM is owned
// by the downstream reassembler. Busy transactions may still read a snapshot.
module s9_spi_transport #(parameter integer WATCHDOG_CLOCKS=500000, STREAM_STATUS_CRC=0, SHARED_FRAGMENT_POOL=0)(
 input wire clk,rst,spi_sck,control_cs_n,score_cs_n,sd_cs_n,spi_mosi,
 output wire spi_miso,spi_miso_oe,
 input wire [511:0] status_bytes,
 output reg fragment_valid,input wire fragment_ready,
 output reg [255:0] fragment_header,
 output wire [1023:0] fragment_payload,
 output reg [1:0] fragment_bank,
 input wire pool_read_enable,input wire [1:0] pool_read_bank,input wire [6:0] pool_read_index,
 output reg [7:0] pool_read_data,output reg pool_response_valid,
 output reg [1:0] pool_response_bank,output reg [6:0] pool_response_index,
 input wire pool_release,input wire [1:0] pool_release_bank,
 output reg [7:0] fragment_length,
 output reg status_read,output wire [511:0] status_snapshot,
 output reg [31:0] accepted_transactions,rejected_transactions,cs_conflicts,timeouts
);
 function [31:0] crcbyte(input[31:0] c,input[7:0] b);
  reg[31:0] v;integer i;begin v=c^b;for(i=0;i<8;i=i+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
 reg[2:0] sck_sync,cs_sync;reg[1:0] mosi_sync,score_sync,sd_sync;
 wire start=cs_sync[2:1]==2'b10,finish=cs_sync[2:1]==2'b01;
 wire rise=sck_sync[2:1]==2'b01,fall=sck_sync[2:1]==2'b10;
 reg transaction,bad,capacity;
 reg[255:0] header;
 reg[1023:0] payload,fragment_payload_private;
 assign fragment_payload=SHARED_FRAGMENT_POOL?1024'd0:fragment_payload_private;
 // Three owners can coexist: receive, offered fragment, reassembly. Banks
 // stay locked from successful publication through the last reassembly read.
 reg [7:0] fragment_pool[0:511];
 reg [2:0] pool_owned;reg [1:0] receive_bank;
 wire [1:0] free_bank=!pool_owned[0]?2'd0:!pool_owned[1]?2'd1:2'd2;

 reg[511:0] response;
 reg[31:0] crc,footer,watchdog;
 reg[7:0] bytes_received,expected,wire_length,rx_shift;
 reg[2:0] bits_received;
 reg[9:0] tx_bit;
 reg [31:0] response_crc;reg [5:0] response_crc_index;reg response_crc_busy;
 wire pool_write=SHARED_FRAGMENT_POOL && !rst && transaction && !start &&
   !cs_sync[2] && rise && bits_received==7 && bytes_received>=32 &&
   bytes_received<expected-4 && capacity && bytes_received<160;
 wire [6:0] pool_write_index=bytes_received[6:0]-7'd32;
 // Incoming byte updates have priority. At most one every16 clocks, so
 //60 outgoing bytes finish in <=64 clocks, before MISO bit480 can be read.
 wire receive_crc_step=transaction&&!start&&!cs_sync[2]&&rise&&bits_received==7&&
   (bytes_received<32 || bytes_received<expected-4);
 wire[7:0] next_byte={rx_shift[6:0],mosi_sync[1]};
 wire [31:0] shared_crc_next=crcbyte(receive_crc_step?crc:response_crc,
   receive_crc_step?next_byte:response[511-response_crc_index*8-:8]);
 wire[7:0] operation=header[47:40];
 wire[15:0] length=header[63:48],offset=header[239:224];
 wire management=operation==8'h80||operation==8'h90||operation==8'h91||operation==8'h92;
 wire data_command=operation<2;
 assign spi_miso_oe=!rst&&!control_cs_n&&score_cs_n&&sd_cs_n&&transaction&&!bad;
 assign spi_miso=tx_bit<512?response[511-tx_bit]:1'b0;
 genvar sb;
 generate for(sb=0;sb<64;sb=sb+1)begin: snapshot_bytes
  assign status_snapshot[sb*8+:8]=response[511-sb*8-:8];
 end endgenerate

 wire pool_publish=SHARED_FRAGMENT_POOL && transaction && !start && finish &&
   !(bad||!score_sync[1]||!sd_sync[1]||bits_received!=0||bytes_received!=wire_length||footer!=~crc||
       header[31:0]!=32'h4b503953||header[39:32]!=1||header[255:240]!=0||
       (!management&&!data_command)||
       (management&&(length!=0||header[223:192]!=0||offset!=0))||
       (data_command&&(length==0||length>128||header[223:192]==0||offset>192||length>192-offset))) && operation!=8'h80 && capacity;
 always @(posedge clk)begin
  if(pool_write)fragment_pool[{receive_bank,pool_write_index}]<=next_byte;
  if(SHARED_FRAGMENT_POOL && pool_read_enable)
   pool_read_data<=fragment_pool[{pool_read_bank,pool_read_index}];
  if(rst)begin
   pool_owned<=0;receive_bank<=0;fragment_bank<=0;pool_response_valid<=0;
   pool_response_bank<=0;pool_response_index<=0;
  end else if(SHARED_FRAGMENT_POOL)begin
   pool_response_valid<=pool_read_enable;
   if(pool_read_enable)begin pool_response_bank<=pool_read_bank;pool_response_index<=pool_read_index;end
   if(pool_release)pool_owned[pool_release_bank]<=0;
   if(start)receive_bank<=free_bank;
   if(pool_publish)begin pool_owned[receive_bank]<=1;fragment_bank<=receive_bank;end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst && SHARED_FRAGMENT_POOL)begin
  if(start && (&pool_owned))$fatal(1,"S9_POOL_NO_FREE_BANK");
  if(pool_write && pool_owned[receive_bank])$fatal(1,"S9_POOL_OVERWRITE_OWNER");
  if(pool_publish && pool_owned[receive_bank])$fatal(1,"S9_POOL_PUBLISH_OWNED");
  if(pool_release && (pool_release_bank>=3 || !pool_owned[pool_release_bank]))$fatal(1,"S9_POOL_RELEASE_OWNER");
  if(pool_read_enable && (pool_read_bank>=3 || !pool_owned[pool_read_bank]))$fatal(1,"S9_POOL_READ_OWNER");
 end
 // synthesis translate_on

 integer i;
 always @(posedge clk)begin
  sck_sync<={sck_sync[1:0],spi_sck};cs_sync<={cs_sync[1:0],control_cs_n};
  mosi_sync<={mosi_sync[0],spi_mosi};score_sync<={score_sync[0],score_cs_n};sd_sync<={sd_sync[0],sd_cs_n};
  if(rst)begin
   sck_sync<=0;cs_sync<=7;mosi_sync<=0;score_sync<=3;sd_sync<=3;
   transaction<=0;bad<=0;capacity<=0;header<=0;response<=0;crc<=32'hffffffff;footer<=0;watchdog<=0;
   bytes_received<=0;expected<=36;wire_length<=80;rx_shift<=0;bits_received<=0;tx_bit<=0;
   response_crc<=32'hffffffff;response_crc_index<=0;response_crc_busy<=0;
   fragment_valid<=0;fragment_header<=0;fragment_length<=0;status_read<=0;
   accepted_transactions<=0;rejected_transactions<=0;cs_conflicts<=0;timeouts<=0;
   // Payload data need not reset. Valid and explicit length protect all reads.
  end else begin
   status_read<=0;
   if(STREAM_STATUS_CRC&&!start&&response_crc_busy&&!receive_crc_step)begin
    response_crc<=shared_crc_next;
    if(response_crc_index==59)begin
     response[31:0]<={~shared_crc_next[7:0],~shared_crc_next[15:8],~shared_crc_next[23:16],~shared_crc_next[31:24]};
     response_crc_busy<=0;
    end else response_crc_index<=response_crc_index+1'b1;
   end
   if(fragment_valid&&fragment_ready)fragment_valid<=0;
   if(start)begin
    transaction<=1;bad<=!score_sync[1]||!sd_sync[1];capacity<=!fragment_valid||fragment_ready;
    header<=0;footer<=0;crc<=32'hffffffff;watchdog<=0;bytes_received<=0;bits_received<=0;rx_shift<=0;tx_bit<=0;
    expected<=36;wire_length<=80;
    for(i=0;i<64;i=i+1)response[511-i*8-:8]<=status_bytes[i*8+:8];
    if(STREAM_STATUS_CRC)begin response_crc<=32'hffffffff;response_crc_index<=0;response_crc_busy<=1;end
    if(!score_sync[1]||!sd_sync[1])cs_conflicts<=cs_conflicts+1'b1;
   end else if(transaction)begin
    if(watchdog<WATCHDOG_CLOCKS)watchdog<=watchdog+1'b1;
    else if(!bad)begin bad<=1;timeouts<=timeouts+1'b1;end
    if((!score_sync[1]||!sd_sync[1])&&!bad)begin bad<=1;cs_conflicts<=cs_conflicts+1'b1;end
    if(!cs_sync[2]&&rise)begin
     rx_shift<=next_byte;bits_received<=bits_received+1'b1;
     if(bits_received==7)begin
      if(bytes_received<32)begin
       header[bytes_received*8+:8]<=next_byte;crc<=STREAM_STATUS_CRC?shared_crc_next:crcbyte(crc,next_byte);
       if(bytes_received==31)begin
        if(header[63:48]>128)bad<=1;
        else begin expected<=36+header[63:48];wire_length<=(header[63:48]>44)?36+header[63:48]:80;end
       end
      end else if(bytes_received<expected-4)begin
       crc<=STREAM_STATUS_CRC?shared_crc_next:crcbyte(crc,next_byte);
       if(!SHARED_FRAGMENT_POOL&&capacity&&bytes_received<160)payload[(bytes_received-32)*8+:8]<=next_byte;
      end else if(bytes_received<expected)footer[(bytes_received-expected+4)*8+:8]<=next_byte;
      else if(next_byte!=0||bytes_received>=wire_length)bad<=1;
      if(bytes_received<255)bytes_received<=bytes_received+1'b1;else bad<=1;
     end
    end
    if(fall&&tx_bit<512)tx_bit<=tx_bit+1'b1;
    if(finish)begin
     transaction<=0;
     // A complete unconflicted64-byte MISO snapshot has been clocked even if
     // MOSI is subsequently rejected (e.g. no request buffer credit). There is
     // no inference about MCU application consumption; command retry/lookup
     // still recovers a status whose wire CRC was lost.
     if(!bad&&score_sync[1]&&sd_sync[1]&&bits_received==0&&bytes_received>=64)status_read<=1;
     if(bad||!score_sync[1]||!sd_sync[1]||bits_received!=0||bytes_received!=wire_length||footer!=~crc||
       header[31:0]!=32'h4b503953||header[39:32]!=1||header[255:240]!=0||
       (!management&&!data_command)||
       (management&&(length!=0||header[223:192]!=0||offset!=0))||
       (data_command&&(length==0||length>128||header[223:192]==0||offset>192||length>192-offset)))
      rejected_transactions<=rejected_transactions+1'b1;
     else if(operation==8'h80)accepted_transactions<=accepted_transactions+1'b1; // read-only POLL needs no request slot
     else if(!capacity)rejected_transactions<=rejected_transactions+1'b1;
     else begin
      fragment_header<=header;fragment_length<=length[7:0];if(!SHARED_FRAGMENT_POOL)fragment_payload_private<=payload;
      fragment_valid<=1;accepted_transactions<=accepted_transactions+1'b1;
     end
    end
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(STREAM_STATUS_CRC&&transaction&&tx_bit>=480&&tx_bit<512&&response_crc_busy)$fatal(1,"S9_STATUS_CRC_NOT_READY_AT_BIT");
  if((^{spi_sck,control_cs_n,score_cs_n,sd_cs_n,fragment_ready})===1'bx)$fatal(1,"S9_SPI_CONTROL_XZ");
  if(!control_cs_n&&spi_mosi!==1'b0&&spi_mosi!==1'b1)$fatal(1,"S9_SPI_MOSI_XZ");
  if(start&&(^status_bytes)===1'bx)$fatal(1,"S9_SPI_STATUS_XZ");
 end
 // synthesis translate_on
endmodule
