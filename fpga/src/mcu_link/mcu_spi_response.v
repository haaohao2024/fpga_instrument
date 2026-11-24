// Response CRC preparation reads the pinned recorder prefix in place. No
// retransmission RAM is copied here. A payload becomes advertised only after
// its complete 512-byte CRC has been scanned; a new CS freezes its identity.
module mcu_spi_response #(parameter integer S11_VERSION=1,SOURCE_SYNC_TX=0,COMM_SEPARATE=0, STREAM_HEADER_CRC=0,PINNED_PREFIX=0)(
 input wire spi_sck,spi_cs_n,
 input wire comm_clk,fast_fall,fast_start,clk,rst,select_start,transaction,short_transaction,bulk_transaction,input wire [14:0] tx_bit_index,
 input wire [1:0] media_state,input wire [63:0] media_epoch,
 input wire [31:0] media_last_sequence,input wire [8:0] media_credit,
 input wire [2:0] recorder_state,input wire recorder_incomplete,missing_is_event,
 input wire [7:0] recorder_mask,input wire [63:0] recorder_id,
 input wire [31:0] recorder_command_sequence,recorder_error,captured_pcm_pairs,input wire [63:0] first_missing_frame,
 input wire block_valid,input wire [7:0] block_kind,
 input wire [31:0] block_sequence,input wire [63:0] block_first_frame,
 input wire [15:0] block_bytes,block_items,
 output wire [10:0] peek_byte_address,input wire [7:0] peek_byte_data,
 output wire serial_bit,output wire [511:0] snapshot_header,
 output wire payload_ready
);
 function [31:0] crcbyte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer k;begin v=c^b;for(k=0;k<8;k=k+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
 // CRC(header[0:60], little-endian complemented header CRC) has raw
 // residue DEBB20E3. Its continuation through 512 zero bytes is constant.
 localparam [31:0] ZERO_PACKET_RAW=32'h538d84e8; // raw CRC residue continued through 512 zeros
 localparam [31:0] SHORT_PACKET_CRC=32'h2144df1c; // complement of header64 raw residue DEBB20E3
 localparam [31:0] ZERO_BULK_RAW=32'h17f076dc;
 reg [1:0] scan_state;reg [11:0] scan_index;reg [31:0] scan_crc,payload_crc;
 reg [31:0] payload_crc512,packet_crc512_snapshot;
 reg scan_owned;
 reg prepared;reg [63:0] scan_id;
 reg [31:0] scan_sequence;reg [15:0] scan_bytes;
 reg [7:0] scan_kind;reg [15:0] scan_items;
 // Completed CRC and active scan never own different live blocks.
 // A new scan starts only after the prepared flag is invalidated, and
 // cannot overwrite the context of an advertised in-flight payload.
 reg [63:0] scan_first_frame;
 reg [511:0] header,header_snapshot;reg [31:0] hcrc,packet_crc_snapshot;
 reg payload_snapshot;reg [15:0] payload_bytes_snapshot;
 reg [31:0] header_crc;reg [5:0] header_crc_index;reg header_crc_busy;
 wire full_context_match=scan_id==recorder_id&&scan_sequence==block_sequence&&scan_kind==block_kind&&
  scan_bytes==block_bytes&&scan_items==block_items&&scan_first_frame==block_first_frame;
 wire same_context=PINNED_PREFIX?scan_owned:full_context_match;
 wire payload_crc_step=!select_start&&(!transaction||!payload_snapshot||short_transaction)&&scan_state==2&&
  block_valid&&same_context;
 // The existing payload scan uses at most alternate clocks. Its priority
 // leaves60 header updates within120 clocks, before original bit480.
 wire [31:0] shared_crc_next=crcbyte(payload_crc_step?scan_crc:header_crc,
  payload_crc_step?(scan_index<scan_bytes?peek_byte_data:8'd0):header_snapshot[header_crc_index*8+:8]);
 integer j;
 wire match_payload=block_valid&&prepared&&same_context;
 assign payload_ready=match_payload;
 wire [11:0] wire_byte=tx_bit_index>>3;
 reg [7:0] payload_tx_byte;
 wire serial_clk=COMM_SEPARATE?comm_clk:clk;
 // With SOURCE_SYNC_TX the bit index is clocked by SCK. Sample it into the
 // serial clock first, so the address decode below is a same-clock path
 // instead of being timed against half an SCK period. The byte index only moves
 // at bit4 and then holds for eight SCK bits, so one extra cycle is harmless.
 reg [14:0] tx_bit_sampled;
 always @(posedge serial_clk)tx_bit_sampled<=tx_bit_index;
 wire [14:0] address_bit_index=COMM_SEPARATE?tx_bit_sampled:tx_bit_index;
 // At bit4 request the following byte; capture at bit7's falling edge.
 // This gives the synchronous recorder port three SCK bit times to respond.
 wire [11:0] read_byte=wire_byte+(((COMM_SEPARATE||SOURCE_SYNC_TX)&&tx_bit_index[2:0]>=4)?12'd1:12'd0);
 wire [11:0] address_byte=(address_bit_index>>3)+(((COMM_SEPARATE||SOURCE_SYNC_TX)&&address_bit_index[2:0]>=4)?12'd1:12'd0);
 generate if(!SOURCE_SYNC_TX)begin: old_payload_capture
 always @(posedge serial_clk)begin
  if(rst||fast_start)payload_tx_byte<=0;
  else if(fast_fall&&tx_bit_index[2:0]==7)payload_tx_byte<=peek_byte_data;
 end
 end else begin: unused_payload_capture
  always @(*)payload_tx_byte=8'd0;
 end endgenerate
 wire [10:0] decoded_payload_address=address_byte>=64&&address_byte<2112?address_byte-64:11'd0;
 reg [10:0] registered_payload_address;
 // Bit4 look-ahead is retained. One 80MHz edge for address decoding still
 // leaves >300ns before bit7 capture at 8MHz SPI. CRC scan stays unpipelined.
 always @(posedge serial_clk)begin
  if(rst||fast_start)registered_payload_address<=0;
  else registered_payload_address<=decoded_payload_address;
 end
 assign peek_byte_address=transaction&&payload_snapshot&&!short_transaction?
   (COMM_SEPARATE?registered_payload_address:decoded_payload_address):scan_index[10:0];
 assign snapshot_header=header_snapshot;
 wire [31:0] selected_packet_crc=bulk_transaction?packet_crc_snapshot:packet_crc512_snapshot;
 wire [7:0] output_byte=wire_byte<64?header_snapshot[{wire_byte[5:0],3'b000}+:8]:
  short_transaction?(wire_byte<68?SHORT_PACKET_CRC[{wire_byte[1:0],3'b000}+:8]:8'd0):
  wire_byte<(bulk_transaction?2112:576)?(payload_snapshot&&wire_byte-64<payload_bytes_snapshot?(COMM_SEPARATE?payload_tx_byte:peek_byte_data):8'd0):
  wire_byte<(bulk_transaction?2116:580)?selected_packet_crc[{wire_byte[1:0],3'b000}+:8]:8'd0;
 // A complete next byte is prepared while the previous byte is shifting.
 wire [7:0] lookahead_byte=read_byte<64?header_snapshot[{read_byte[5:0],3'b000}+:8]:
  short_transaction?(read_byte<68?SHORT_PACKET_CRC[{read_byte[1:0],3'b000}+:8]:8'd0):
  read_byte<(bulk_transaction?2112:576)?(payload_snapshot&&read_byte-64<payload_bytes_snapshot?peek_byte_data:8'd0):
  read_byte<(bulk_transaction?2116:580)?selected_packet_crc[{read_byte[1:0],3'b000}+:8]:8'd0;
 generate if(SOURCE_SYNC_TX)begin: source_sync_byte
  reg [7:0] shift;
  wire tx_reset=rst||spi_cs_n;
  always @(negedge spi_sck or posedge tx_reset)begin
   if(tx_reset)shift<=8'h53;
   else if(tx_bit_index[2:0]==7)shift<=lookahead_byte;
   else shift<={shift[6:0],1'b0};
  end
  assign serial_bit=shift[7];
 end else begin: old_serial_bit
  assign serial_bit=output_byte[~tx_bit_index[2:0]];
 end endgenerate
 always @(*)begin
  header=0;header[31:0]=32'h54533753;header[39:32]=S11_VERSION;
  header[47:40]={6'd0,media_state};header[55:48]={5'd0,recorder_state};
  header[63:56]={5'd0,(S11_VERSION==2?(recorder_incomplete&&!match_payload&&missing_is_event):1'b1),recorder_incomplete,match_payload};header[127:64]=media_epoch;
  header[159:128]=media_last_sequence;header[175:160]={7'd0,media_credit};
  header[183:176]=match_payload?block_kind:0;header[191:184]=recorder_mask;
  header[255:192]=recorder_id;header[287:256]=recorder_command_sequence;
  header[319:288]=match_payload?block_sequence:0;
  header[383:320]=match_payload?block_first_frame:(recorder_incomplete?first_missing_frame:64'd0);
  header[399:384]=match_payload?block_bytes:0;header[415:400]=match_payload?block_items:0;
  header[447:416]=recorder_error;header[479:448]=captured_pcm_pairs;
  hcrc=32'hffffffff;if(!STREAM_HEADER_CRC)begin for(j=0;j<60;j=j+1)hcrc=crcbyte(hcrc,header[j*8+:8]);
  header[511:480]=~hcrc;end
 end
 always @(posedge clk)begin
  if(rst)begin scan_owned<=0;scan_state<=0;scan_index<=0;scan_crc<=0;payload_crc<=0;payload_crc512<=0;packet_crc512_snapshot<=0;prepared<=0;
   scan_id<=0;scan_sequence<=0;scan_bytes<=0;
   scan_kind<=0;scan_items<=0;
   scan_first_frame<=0;
   header_snapshot<=0;packet_crc_snapshot<=0;payload_snapshot<=0;payload_bytes_snapshot<=0;
   header_crc<=32'hffffffff;header_crc_index<=0;header_crc_busy<=0;end
  else begin
   if(!block_valid)scan_owned<=0;
   if(!match_payload)prepared<=0;
   if(select_start)begin
    header_snapshot<=header;payload_snapshot<=match_payload;payload_bytes_snapshot<=match_payload?block_bytes:16'd0;
    packet_crc_snapshot<=~(ZERO_BULK_RAW^(match_payload?payload_crc:32'd0));
    packet_crc512_snapshot<=~(ZERO_PACKET_RAW^(match_payload?payload_crc512:32'd0));
    if(STREAM_HEADER_CRC)begin header_crc<=32'hffffffff;header_crc_index<=0;header_crc_busy<=1;end
   end else if(STREAM_HEADER_CRC&&header_crc_busy&&!payload_crc_step)begin
    header_crc<=shared_crc_next;
    if(header_crc_index==59)begin header_snapshot[511:480]<=~shared_crc_next;header_crc_busy<=0;end
    else header_crc_index<=header_crc_index+1'b1;
   end
   // An empty snapshot sends zero payload, so its RAM port is available to
   // finish preparation for the next CS. Polling cannot starve the scanner.
   if(!select_start&&(!transaction||!payload_snapshot||short_transaction))begin
    if(scan_state==0)begin
     if(block_valid&&!match_payload)begin scan_owned<=1;scan_id<=recorder_id;scan_sequence<=block_sequence;
      scan_kind<=block_kind;scan_bytes<=block_bytes;scan_items<=block_items;scan_first_frame<=block_first_frame;
      scan_index<=0;scan_crc<=0;scan_state<=1;end
    end else if(!block_valid||!same_context)scan_state<=0;
    else if(scan_state==1)scan_state<=2; // synchronous RAM read has completed
    else begin
     scan_crc<=STREAM_HEADER_CRC?shared_crc_next:crcbyte(scan_crc,scan_index<scan_bytes?peek_byte_data:8'd0);
     if(scan_index==511)payload_crc512<=STREAM_HEADER_CRC?shared_crc_next:crcbyte(scan_crc,scan_index<scan_bytes?peek_byte_data:8'd0);
     if(scan_index==2047)begin
      payload_crc<=STREAM_HEADER_CRC?shared_crc_next:crcbyte(scan_crc,scan_index<scan_bytes?peek_byte_data:8'd0);
      prepared<=1;scan_state<=0;
      
     end else begin scan_index<=scan_index+1'b1;scan_state<=1;end
    end
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst&&PINNED_PREFIX&&block_valid&&scan_owned&&!full_context_match)
  $fatal(1,"R54_PREFIX_METADATA_CHANGED_WITHOUT_RELEASE");
 always @(posedge clk)if(!rst)begin
  if(STREAM_HEADER_CRC&&transaction&&tx_bit_index>=480&&tx_bit_index<512&&header_crc_busy)$fatal(1,"S11_HEADER_CRC_NOT_READY_AT_BIT");
  if($isunknown({select_start,transaction,block_valid,recorder_incomplete}))$fatal(1,"S11_RESPONSE_CONTROL_XZ");
  if(block_valid&&(block_bytes==0||block_bytes>2048))$fatal(1,"S11_RESPONSE_BLOCK_LENGTH");
  if(transaction&&payload_snapshot&&!block_valid)$fatal(1,"S11_RESPONSE_PREFIX_RELEASED_IN_FLIGHT");
 end
 // synthesis translate_on
endmodule

