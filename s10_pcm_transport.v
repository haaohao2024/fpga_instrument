// S10P v1, 50 MHz oversampled shared Mode0 SPI. 4 MHz is a digital
// verification contract; this module does not qualify physical IO timing.
// Two 512-byte synchronous byte RAMs own each accepted packet until its
// stereo pairs handshake or an explicit stream barrier discards them.
module s10_pcm_transport #(parameter integer COMM_SEPARATE=0, WATCHDOG_CLOCKS=500000, ENABLE_S11=0, STREAM_STATUS_CRC=0, DEFER_LEGACY_CRC=0)(
 input wire comm_clk,clk,rst,spi_sck,score_cs_n,control_cs_n,sd_cs_n,spi_mosi,
 input wire [255:0] legacy_status_bytes,
 input wire [11:0] stream_buffered,input wire [31:0] stream_generation,
 input wire [2:0] stream_state,input wire cancel,
 output wire spi_miso,spi_miso_oe,output reg route_s10,
 output reg pcm_valid,input wire pcm_ready,
 output reg signed [15:0] pcm_l,pcm_r,output reg [63:0] pcm_epoch,
 output reg ctrl_valid,input wire ctrl_ready,
 output reg [1:0] ctrl_cmd,output reg [63:0] ctrl_epoch,
 output wire [31:0] ctrl_rate,output reg ctrl_track,
 output reg [1:0] state,output wire [1:0] bank_count,
 output wire [8:0] free_pair_credit,reserved_pair_count,resident_pairs,
 output reg [63:0] accepted_pair_count,delivered_pair_count,discard_pair_count,
 output reg [31:0] accepted_packets,duplicate_packets,rejected_transactions,
 output reg [31:0] cs_conflicts,timeout_count,last_sequence,
 output reg [63:0] stream_epoch,next_source_start,
 output reg route_s11,
 output reg record_cmd_valid,input wire record_cmd_ready,
 output reg [1:0] record_cmd,output reg [63:0] record_cmd_id,
 output reg [7:0] record_cmd_mask,record_ack_kind,
 output reg [31:0] record_cmd_sequence,record_ack_sequence,
 input wire [2:0] record_state,input wire record_incomplete,
 input wire [7:0] record_mask,input wire [63:0] record_id,
 input wire [31:0] record_last_command,record_error,record_captured_pcm,input wire [63:0] record_first_missing_frame,
 input wire record_block_valid,input wire [7:0] record_block_kind,
 input wire [31:0] record_block_sequence,input wire [63:0] record_block_first,
 input wire [15:0] record_block_bytes,record_block_items,
 output wire [8:0] record_peek_address,input wire [7:0] record_peek_data
);
 localparam STOPPED=0,OPENING=1,PLAY=2,CLOSING=3;
 localparam OP_START=1,OP_DATA=2,OP_STOP=3,OP_STATUS=4;
 function [31:0] crcbyte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer k;begin v=c^b;for(k=0;k<8;k=k+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
 reg [7:0] memory0[0:511],memory1[0:511];
 reg [1:0] bank_used;reg [8:0] bank_pairs[0:1],bank_remaining[0:1];reg head_bank;
 reg [9:0] read_index;reg read_pending,read_bank;reg [1:0] read_phase;
 reg [31:0] generation,read_generation;reg [63:0] read_epoch;
 reg [7:0] ram_q,part0,part1,part2;reg stop_pending;
 reg [1:0] sd_sync,control_sync;
 wire rise,fall,select_start,select_end,phy_selected,phy_bit,fast_start,fast_fall;
 wire serial_clk=COMM_SEPARATE?comm_clk:clk;
 r24_spi_edges #(.COMM_SEPARATE(COMM_SEPARATE)) phy(.clk(clk),.comm_clk(comm_clk),.rst(rst),
 .sck(spi_sck),.cs_n(score_cs_n),.mosi(spi_mosi),.rise(rise),.fall(fall),.start(select_start),.finish(select_end),
 .selected(phy_selected),.bit_data(phy_bit),.fast_start(fast_start),.fast_fall(fast_fall));

 reg transaction,bad,capacity,receive_bank;
 reg [511:0] header;
 // Three frozen views retain one owner each. Selecting telemetry changes only
 // the view selector, never copies a complete response over another version.
 reg [255:0] legacy_snapshot,status_snapshot,telemetry_snapshot;
 reg extension_telemetry;
 wire [511:0] response={legacy_snapshot,extension_telemetry?telemetry_snapshot:status_snapshot};
 reg [31:0] rx_crc,footer,watchdog,request_header_crc;
 reg [9:0] byte_count,expected_bytes,wire_length;
 reg [2:0] bit_count;reg [7:0] rx_shift;reg [12:0] tx_index;
 wire [1:0] footer_lane=byte_count[1:0]-expected_bytes[1:0];
 wire [7:0] next_byte={rx_shift[6:0],phy_bit};
 wire [7:0] operation=header[47:40];wire [15:0] request_pairs=header[63:48];
 wire [63:0] request_epoch=header[127:64];wire [31:0] request_sequence=header[159:128];
 wire [63:0] source_start=header[223:160];wire [31:0] flags=header[255:224];
 reg [63:0] last_source_start;reg [8:0] last_pair_count;reg [31:0] last_packet_crc;reg last_track;
 reg [255:0] status_tmp,telemetry_tmp;reg [31:0] status_crc,telemetry_crc;integer j;
 wire handshake=pcm_valid&&pcm_ready,control_handshake=ctrl_valid&&ctrl_ready;
 wire can_read=bank_used[head_bank]&&read_index<{bank_pairs[head_bank],2'b0}
                  &&(!pcm_valid||pcm_ready)&&state==PLAY;
 assign ctrl_rate=32'd48000;
 assign bank_count={1'b0,bank_used[0]}+{1'b0,bank_used[1]};
 assign resident_pairs=bank_remaining[0]+bank_remaining[1];
 wire receiving_reservation=transaction&&route_s10&&operation==OP_DATA&&capacity;
 assign reserved_pair_count=receiving_reservation?9'd128:9'd0;
 assign free_pair_credit=(9'd256-({7'd0,bank_count}<<7))-reserved_pair_count;
 // Front 32 bytes are the unchanged S7 snapshot for every STE1 selection.
 // Only S10P extends OE into the next 32 bytes. Legacy frames remain HiZ.
 wire s11_serial_bit;wire [511:0] s11_snapshot;wire s11_payload_ready;
 wire short_s11=route_s11&&header[431:416]==0;
 generate if(ENABLE_S11)begin: s11_response_enabled
  s11_spi_response #(.COMM_SEPARATE(COMM_SEPARATE),.STREAM_HEADER_CRC(1)) response_encoder(.comm_clk(comm_clk),.fast_fall(fast_fall),.fast_start(fast_start),.clk(clk),.rst(rst),.select_start(select_start),.transaction(transaction),.short_transaction(short_s11),.tx_bit_index(tx_index),
   .media_state(state),.media_epoch(stream_epoch),.media_last_sequence(last_sequence),.media_credit(free_pair_credit),
   .recorder_state(record_state),.recorder_incomplete(record_incomplete),.recorder_mask(record_mask),.recorder_id(record_id),
   .recorder_command_sequence(record_last_command),.recorder_error(record_error),.captured_pcm_pairs(record_captured_pcm),.first_missing_frame(record_first_missing_frame),
   .block_valid(record_block_valid),.block_kind(record_block_kind),.block_sequence(record_block_sequence),.block_first_frame(record_block_first),
   .block_bytes(record_block_bytes),.block_items(record_block_items),.peek_byte_address(record_peek_address),.peek_byte_data(record_peek_data),
   .serial_bit(s11_serial_bit),.snapshot_header(s11_snapshot),.payload_ready(s11_payload_ready));
 end else begin: s11_response_disabled
  assign s11_serial_bit=0;assign s11_snapshot=0;assign s11_payload_ready=0;assign record_peek_address=0;
 end endgenerate
 assign spi_miso_oe=!rst&&!score_cs_n&&control_cs_n&&sd_cs_n&&transaction&&!bad
                     &&(tx_index<256||(route_s10&&tx_index<512)||(route_s11&&tx_index<(short_s11?544:4640)));
 // First byte keeps the original CS snapshot edge. Subsequent bytes are
 // loaded on their preceding byte's final falling edge; only 8 bits shift.
 reg[7:0] media_tx_byte;
 wire[5:0] media_next_index=tx_index[8:3]+6'd1;
 wire[7:0] media_next_byte=response[{~media_next_index,3'b111}-:8];
 assign spi_miso=route_s11?s11_serial_bit:(tx_index<8?
  legacy_snapshot[{5'b11111,~tx_index[2:0]}]:(tx_index<512?media_tx_byte[7]:1'b0));
 always @(posedge serial_clk)begin
  if(rst||fast_start)media_tx_byte<=0;
  else if(phy_selected&&fast_fall&&tx_index<512)begin
   if(tx_index[2:0]==7)media_tx_byte<=media_next_byte;
   else media_tx_byte<={media_tx_byte[6:0],1'b0};
  end
 end
 always @(posedge serial_clk)begin
  if(rst||fast_start)tx_index<=0;
  else if(phy_selected&&fast_fall&&tx_index<4640)tx_index<=tx_index+1'b1;
 end
 always @(*)begin
  status_tmp=0;status_tmp[31:0]=32'h53303153;status_tmp[39:32]=1;
  status_tmp[47:40]={6'd0,state};status_tmp[63:48]={7'd0,free_pair_credit};
  status_tmp[127:64]=stream_epoch;status_tmp[159:128]=last_sequence;
  status_tmp[223:160]=delivered_pair_count;
  status_crc=32'hffffffff;if(!STREAM_STATUS_CRC)for(j=0;j<28;j=j+1)status_crc=crcbyte(status_crc,status_tmp[j*8+:8]);
  status_tmp[255:224]=~status_crc;
  telemetry_tmp=status_tmp;telemetry_tmp[47:40]={1'b1,4'd0,stream_state};
  telemetry_tmp[175:160]={4'd0,stream_buffered};telemetry_tmp[191:176]={7'd0,resident_pairs};
  telemetry_tmp[223:192]=stream_generation;
  telemetry_crc=32'hffffffff;if(!STREAM_STATUS_CRC)for(j=0;j<28;j=j+1)telemetry_crc=crcbyte(telemetry_crc,telemetry_tmp[j*8+:8]);
  telemetry_tmp[255:224]=~telemetry_crc;
 end
 // Both 28-byte response prefixes freeze at CS. One CRC datapath serves
 // RX first, then the frozen status and telemetry prefixes in 56 free clocks.
 // No transmit/receive edge or packet admission is delayed. The selector
 // arrives at byte 28, much later than this bounded preparation interval.
 reg response_crc_busy,response_crc_telemetry,response_crc_legacy;
 reg [4:0] response_crc_index;reg [31:0] response_crc_value;
 wire receive_crc_step=!select_start&&transaction&&phy_selected&&rise&&bit_count==7&&
  (byte_count<32||(route_s11&&byte_count<64)||byte_count<expected_bytes-4);
 wire [7:0] frozen_crc_byte=response_crc_legacy?
  response[{1'b1,~response_crc_index,3'b111}-:8]:response_crc_telemetry?
  telemetry_snapshot[{~response_crc_index,3'b111}-:8]:status_snapshot[{~response_crc_index,3'b111}-:8];
 wire [31:0] scheduled_crc_next=crcbyte(receive_crc_step?rx_crc:response_crc_value,
  receive_crc_step?next_byte:frozen_crc_byte);
 wire [31:0] received_crc_next=STREAM_STATUS_CRC?scheduled_crc_next:crcbyte(rx_crc,next_byte);
 wire [31:0] completed_response_crc=~scheduled_crc_next;
 reg barrier;
 always @(posedge clk)begin
  
  sd_sync<={sd_sync[0],sd_cs_n};control_sync<={control_sync[0],control_cs_n};
  if(rst)begin
   sd_sync<=3;control_sync<=3;
   state<=STOPPED;bank_used<=0;bank_pairs[0]<=0;bank_pairs[1]<=0;
   bank_remaining[0]<=0;bank_remaining[1]<=0;head_bank<=0;
   read_index<=0;read_pending<=0;read_bank<=0;read_phase<=0;read_generation<=0;
   read_epoch<=0;generation<=0;ram_q<=0;part0<=0;part1<=0;part2<=0;
   pcm_valid<=0;pcm_l<=0;pcm_r<=0;pcm_epoch<=0;
   ctrl_valid<=0;ctrl_cmd<=0;ctrl_epoch<=0;ctrl_track<=1;stop_pending<=0;
   accepted_pair_count<=0;delivered_pair_count<=0;discard_pair_count<=0;
   accepted_packets<=0;duplicate_packets<=0;rejected_transactions<=0;cs_conflicts<=0;timeout_count<=0;
   last_sequence<=0;stream_epoch<=0;next_source_start<=0;last_source_start<=0;last_pair_count<=0;last_packet_crc<=0;last_track<=1;
   route_s10<=0;route_s11<=0;record_cmd_valid<=0;record_cmd<=0;record_cmd_id<=0;
   record_cmd_mask<=0;record_ack_kind<=0;record_cmd_sequence<=0;record_ack_sequence<=0;request_header_crc<=0;
   transaction<=0;bad<=0;capacity<=0;receive_bank<=0;
   response_crc_busy<=0;response_crc_telemetry<=0;response_crc_legacy<=0;response_crc_index<=0;response_crc_value<=32'hffffffff;
   header<=0;legacy_snapshot<=0;status_snapshot<=0;telemetry_snapshot<=0;extension_telemetry<=0;rx_crc<=32'hffffffff;footer<=0;watchdog<=0;
   byte_count<=0;expected_bytes<=36;wire_length<=64;bit_count<=0;rx_shift<=0;barrier<=0;
  end else begin
   barrier<=0;
   if(STREAM_STATUS_CRC&&response_crc_busy&&!receive_crc_step&&!select_start)begin
    response_crc_value<=scheduled_crc_next;
    if(response_crc_index==27)begin
     if(response_crc_legacy)begin
      for(integer b=0;b<4;b=b+1)legacy_snapshot[31-b*8-:8]<=completed_response_crc[b*8+:8];
      response_crc_legacy<=0;response_crc_index<=0;response_crc_value<=32'hffffffff;
     end else if(response_crc_telemetry)begin
      for(integer b=0;b<4;b=b+1)telemetry_snapshot[31-b*8-:8]<=completed_response_crc[b*8+:8];
      response_crc_busy<=0;
     end else begin
      for(integer b=0;b<4;b=b+1)status_snapshot[31-b*8-:8]<=completed_response_crc[b*8+:8];
      response_crc_telemetry<=1;response_crc_index<=0;response_crc_value<=32'hffffffff;
     end
    end else response_crc_index<=response_crc_index+1'b1;
   end
   if(ENABLE_S11&&record_cmd_valid&&record_cmd_ready)record_cmd_valid<=0;
   // Every RAM request has bank, epoch and generation ownership. RAM is not
   // reset; a barrier removes read_pending before any old ram_q is usable.
   read_pending<=can_read;
   if(can_read)begin
    ram_q<=head_bank?memory1[read_index[8:0]]:memory0[read_index[8:0]];
    read_bank<=head_bank;read_phase<=read_index[1:0];read_generation<=generation;
    read_epoch<=stream_epoch;read_index<=read_index+1'b1;
   end
   if(read_pending&&read_generation==generation&&state==PLAY&&bank_used[read_bank])begin
    case(read_phase)
     0:part0<=ram_q;
     1:part1<=ram_q;
     2:part2<=ram_q;
     3:begin pcm_l<={part1,part0};pcm_r<={ram_q,part2};pcm_epoch<=read_epoch;pcm_valid<=1;end
    endcase
   end
   if(handshake)begin
    delivered_pair_count<=delivered_pair_count+1;
    // A same-edge completed next pair replaces the pair just handshaken.
    if(!(read_pending&&read_phase==3&&read_generation==generation&&state==PLAY&&bank_used[read_bank]))pcm_valid<=0;
    bank_remaining[head_bank]<=bank_remaining[head_bank]-1'b1;
    if(bank_remaining[head_bank]==1)begin bank_used[head_bank]<=0;head_bank<=~head_bank;read_index<=0;end
   end
   if(control_handshake)begin
    ctrl_valid<=0;
    if(ctrl_cmd==0)begin
     if(stop_pending||state==CLOSING)begin ctrl_valid<=1;ctrl_cmd<=1;state<=CLOSING;stop_pending<=0;end
     else state<=PLAY;
    end else if(ctrl_cmd==1)state<=STOPPED;
   end
   if(stop_pending&&!ctrl_valid)begin ctrl_valid<=1;ctrl_cmd<=1;ctrl_epoch<=stream_epoch;state<=CLOSING;stop_pending<=0;end
   if(select_start)begin
    if(STREAM_STATUS_CRC)begin response_crc_busy<=1;response_crc_telemetry<=0;response_crc_legacy<=DEFER_LEGACY_CRC;response_crc_index<=0;response_crc_value<=32'hffffffff;end
    transaction<=1;route_s10<=0;route_s11<=0;bad<=!sd_sync[1]||!control_sync[1];
    capacity<=!bank_used[0]||!bank_used[1];receive_bank<=bank_used[0];
    header<=0;footer<=0;rx_crc<=32'hffffffff;watchdog<=0;byte_count<=0;expected_bytes<=36;wire_length<=64;
    bit_count<=0;rx_shift<=0;
    extension_telemetry<=0;
    for(j=0;j<32;j=j+1)begin legacy_snapshot[255-j*8-:8]<=legacy_status_bytes[j*8+:8];status_snapshot[255-j*8-:8]<=status_tmp[j*8+:8];telemetry_snapshot[255-j*8-:8]<=telemetry_tmp[j*8+:8];end
    if(!sd_sync[1]||!control_sync[1])cs_conflicts<=cs_conflicts+1;
   end else if(transaction)begin
    if(watchdog<WATCHDOG_CLOCKS)watchdog<=watchdog+1;
    else if(!bad)begin bad<=1;timeout_count<=timeout_count+1;end
    if((!sd_sync[1]||!control_sync[1])&&!bad)begin bad<=1;cs_conflicts<=cs_conflicts+1;end
    if(phy_selected&&rise)begin
     rx_shift<=next_byte;bit_count<=bit_count+1'b1;
     if(bit_count==7)begin
      if(byte_count<32||(route_s11&&byte_count<64))begin
       for(integer hb=0;hb<64;hb=hb+1)if(byte_count==hb)header[hb*8+:8]<=next_byte;rx_crc<=received_crc_next;
       if(byte_count==3)begin
        route_s11<=ENABLE_S11&&{next_byte,header[23:0]}==32'h50313153;
        route_s10<=({next_byte,header[23:0]}==32'h50303153)||(ENABLE_S11&&{next_byte,header[23:0]}==32'h50313153);
       end
       if(route_s11&&byte_count==59)request_header_crc<=~received_crc_next;
       if(route_s11&&byte_count==53)begin
        if({next_byte,header[423:416]}==0)begin expected_bytes<=68;wire_length<=68;end
        else if({next_byte,header[423:416]}!=512)bad<=1;
       end
       if(route_s11&&byte_count==63&&{next_byte,header[503:480]}!=request_header_crc)bad<=1;
       // The selector is byte28, leaving three complete bytes before the
       // response extension begins. Other flag bytes are checked at commit.
       if(byte_count==28&&route_s10&&!route_s11&&operation==OP_STATUS&&next_byte[0])extension_telemetry<=1'b1;
       if(byte_count==31)begin
        if(header[63:48]>128)bad<=1;
        else if(route_s11)begin expected_bytes<=580;wire_length<=580;end
        else begin expected_bytes<=36+(header[63:48]<<2);wire_length<=header[63:48]<7?64:36+(header[63:48]<<2);end
       end
      end else if(byte_count<expected_bytes-4)begin
       rx_crc<=received_crc_next;
       if(route_s11&&byte_count>=64+(request_pairs<<2)&&next_byte!=0)bad<=1;
       if(route_s10&&capacity&&byte_count<(route_s11?576:544))begin
        if(route_s11)begin if(receive_bank)memory1[byte_count-64]<=next_byte;else memory0[byte_count-64]<=next_byte;end
        else begin if(receive_bank)memory1[byte_count-32]<=next_byte;else memory0[byte_count-32]<=next_byte;end
       end
      end else if(byte_count<expected_bytes)case(footer_lane)
       0:footer[7:0]<=next_byte;1:footer[15:8]<=next_byte;2:footer[23:16]<=next_byte;3:footer[31:24]<=next_byte;
      endcase
      else if(next_byte!=0||byte_count>=wire_length)bad<=1;
      if(byte_count<1023)byte_count<=byte_count+1;else bad<=1;
     end
    end

    if(select_end)begin
     transaction<=0;
     if(route_s10)begin
      if(cancel||bad||bit_count!=0||byte_count!=wire_length||footer!=~rx_crc||header[39:32]!=1||
         (route_s11&&(header[327:320]>3||header[351:344]!=0||header[439:432]!=0||
           (header[431:416]!=512&&header[431:416]!=0)||header[479:440]!=0||record_cmd_valid||
           (short_s11&&(operation!=0&&operation!=OP_STATUS||request_pairs!=0||(header[327:320]!=0&&header[327:320]!=3)))))||
         (operation==OP_DATA?(request_pairs==0||request_pairs>128||flags!=0):
          (request_pairs!=0||request_sequence!=0||source_start!=0))||
         (operation==OP_START?(flags>1||request_epoch==0):(operation==OP_STATUS?flags>1:flags!=0)))rejected_transactions<=rejected_transactions+1;
      else begin
       if(route_s11)begin
        record_cmd_valid<=1;record_cmd<=header[321:320];record_cmd_id<=header[319:256];
        record_cmd_mask<=header[335:328];record_ack_kind<=header[343:336];
        record_cmd_sequence<=header[383:352];record_ack_sequence<=header[415:384];
       end
       if(route_s11&&operation==0)begin end
       else if(operation==OP_STATUS)begin
       if(request_epoch!=0&&request_epoch!=stream_epoch)rejected_transactions<=rejected_transactions+1;
      end else if(operation==OP_START)begin
       if((state==OPENING||state==PLAY)&&request_epoch==stream_epoch&&last_track==flags[0])duplicate_packets<=duplicate_packets+1;
       else if(state!=STOPPED||ctrl_valid||stop_pending||request_epoch==stream_epoch||request_epoch==0)rejected_transactions<=rejected_transactions+1;
       else begin
        state<=OPENING;stream_epoch<=request_epoch;next_source_start<=0;last_sequence<=0;last_source_start<=0;last_pair_count<=0;last_packet_crc<=0;last_track<=flags[0];
        ctrl_valid<=1;ctrl_cmd<=0;ctrl_epoch<=request_epoch;ctrl_track<=flags[0];
        generation<=generation+1;bank_used<=0;bank_remaining[0]<=0;bank_remaining[1]<=0;
        head_bank<=0;read_index<=0;read_pending<=0;pcm_valid<=0;barrier<=1;
       end
      end else if(operation==OP_DATA)begin
       if(state!=PLAY||request_epoch!=stream_epoch||request_epoch==0)rejected_transactions<=rejected_transactions+1;
       else if(request_sequence==last_sequence&&last_sequence!=0)begin
        if(request_pairs==last_pair_count&&source_start==last_source_start&&footer==last_packet_crc)duplicate_packets<=duplicate_packets+1;
        else rejected_transactions<=rejected_transactions+1;
       end else if(request_sequence!=last_sequence+1||last_sequence==32'hffffffff||source_start!=next_source_start||!capacity||bank_used[receive_bank]||
                    next_source_start>64'hffffffffffffffff-request_pairs)rejected_transactions<=rejected_transactions+1;
       else begin
        bank_used[receive_bank]<=1;bank_pairs[receive_bank]<=request_pairs[8:0];bank_remaining[receive_bank]<=request_pairs[8:0];
        if(bank_used==0)begin head_bank<=receive_bank;read_index<=0;end
        last_sequence<=request_sequence;last_source_start<=source_start;last_pair_count<=request_pairs[8:0];last_packet_crc<=footer;
        next_source_start<=next_source_start+request_pairs;accepted_pair_count<=accepted_pair_count+request_pairs;accepted_packets<=accepted_packets+1;
       end
      end else if(operation==OP_STOP)begin
       if(request_epoch!=stream_epoch||request_epoch==0)rejected_transactions<=rejected_transactions+1;
       else if(state==STOPPED||state==CLOSING)duplicate_packets<=duplicate_packets+1;
       else begin
        state<=CLOSING;bank_used<=0;bank_remaining[0]<=0;bank_remaining[1]<=0;
        discard_pair_count<=discard_pair_count+resident_pairs-(handshake?1:0);
        generation<=generation+1;read_index<=0;read_pending<=0;pcm_valid<=0;barrier<=1;
        if(ctrl_valid)stop_pending<=1;else begin ctrl_valid<=1;ctrl_cmd<=1;ctrl_epoch<=stream_epoch;end
       end
      end else rejected_transactions<=rejected_transactions+1;
      end
     end
    end
   end
   if(cancel&&(state!=STOPPED||bank_used!=0))begin
    state<=CLOSING;bank_used<=0;bank_remaining[0]<=0;bank_remaining[1]<=0;
    discard_pair_count<=discard_pair_count+resident_pairs-(handshake?1:0);
    generation<=generation+1;read_index<=0;read_pending<=0;pcm_valid<=0;barrier<=1;
    if(ctrl_valid)stop_pending<=1;else begin ctrl_valid<=1;ctrl_cmd<=1;ctrl_epoch<=stream_epoch;end
    if(transaction&&route_s10)bad<=1;
   end
  end
 end
 // synthesis translate_off
 initial if(DEFER_LEGACY_CRC && !STREAM_STATUS_CRC)$fatal(1,"LEGACY_CRC_REQUIRES_SCHEDULED_ENGINE");
 always @(posedge clk)if(!rst&&STREAM_STATUS_CRC)begin
  if(DEFER_LEGACY_CRC && transaction && tx_index>=224 && tx_index<256 && response_crc_legacy)
   $fatal(1,"MEDIA_LEGACY_CRC_DEADLINE");
  if(transaction&&tx_index>=480&&tx_index<512&&response_crc_busy)$fatal(1,"MEDIA_STATUS_CRC_DEADLINE");
  if(transaction&&!select_start&&phy_selected&&rise&&bit_count==7&&byte_count==28&&route_s10&&!route_s11&&operation==OP_STATUS&&next_byte[0]&&response_crc_busy)
   $fatal(1,"MEDIA_TELEMETRY_CRC_DEADLINE");
 end
 // synthesis translate_on
 // synthesis translate_off
 reg previous_stall;reg [95:0] previous_pair;
 reg previous_ctrl_stall;reg [98:0] previous_ctrl;
 always @(posedge clk)begin
  if(rst)begin previous_stall<=0;previous_ctrl_stall<=0;previous_pair<=0;previous_ctrl<=0;end
  else begin
   if((^{spi_sck,score_cs_n,control_cs_n,sd_cs_n,pcm_ready,ctrl_ready,cancel})===1'bx)$fatal(1,"S10_HANDSHAKE_CONTROL_XZ");
   if(pcm_valid!==1'b0&&pcm_valid!==1'b1)$fatal(1,"S10_PCM_VALID_XZ");
   if(ctrl_valid!==1'b0&&ctrl_valid!==1'b1)$fatal(1,"S10_CTRL_VALID_XZ");
   if(ENABLE_S11 && $isunknown({record_cmd_valid,record_cmd_ready,record_block_valid,record_incomplete}))$fatal(1,"S11_TRANSPORT_CONTROL_XZ");
   if(ENABLE_S11 && record_block_valid && $isunknown({record_block_kind,record_block_sequence,record_block_first,record_block_bytes,record_block_items,record_id}))$fatal(1,"S11_TRANSPORT_BLOCK_XZ");
   if(!score_cs_n&&spi_mosi!==1'b0&&spi_mosi!==1'b1)$fatal(1,"S10_MOSI_XZ");
   if(select_start&&(^legacy_status_bytes)===1'bx)$fatal(1,"S10_LEGACY_STATUS_XZ");
   if(select_start&&(^ {stream_buffered,stream_generation,stream_state})===1'bx)$fatal(1,"S10_OBSERVE_XZ");
   if(previous_stall&&!barrier&&(!pcm_valid||{pcm_l,pcm_r,pcm_epoch}!==previous_pair))$fatal(1,"S10_PCM_BACKPRESSURE_CHANGED");
   if(previous_ctrl_stall&&(!ctrl_valid||{ctrl_cmd,ctrl_epoch,ctrl_rate,ctrl_track}!==previous_ctrl))$fatal(1,"S10_CONTROL_BACKPRESSURE_CHANGED");
   if(accepted_pair_count-delivered_pair_count-discard_pair_count!=resident_pairs)$fatal(1,"S10_PAIR_CONSERVATION");
   if(read_pending&&read_phase==3&&read_generation==generation&&state==PLAY&&bank_used[read_bank]&&pcm_valid&&!pcm_ready)$fatal(1,"S10_OUTPUT_PAIR_OVERWRITE");
   previous_stall<=pcm_valid&&!pcm_ready;previous_pair<={pcm_l,pcm_r,pcm_epoch};
   previous_ctrl_stall<=ctrl_valid&&!ctrl_ready;previous_ctrl<={ctrl_cmd,ctrl_epoch,ctrl_rate,ctrl_track};
  end
 end
 // synthesis translate_on
endmodule

// S10P v1, 50 MHz oversampled shared Mode0 SPI. 4 MHz is a digital
// verification contract; this module does not qualify physical IO timing.
// Two 512-byte synchronous byte RAMs own each accepted packet until its
// stereo pairs handshake or an explicit stream barrier discards them.
module r12_media_crc_probe #(parameter integer WATCHDOG_CLOCKS=500000, ENABLE_S11=0, STREAM_STATUS_CRC=1)(
 input wire clk,rst,spi_sck,score_cs_n,control_cs_n,sd_cs_n,spi_mosi,
 input wire [255:0] legacy_status_bytes,
 input wire [11:0] stream_buffered,input wire [31:0] stream_generation,
 input wire [2:0] stream_state,input wire cancel,
 output wire spi_miso,spi_miso_oe,output reg route_s10,
 output reg pcm_valid,input wire pcm_ready,
 output reg signed [15:0] pcm_l,pcm_r,output reg [63:0] pcm_epoch,
 output reg ctrl_valid,input wire ctrl_ready,
 output reg [1:0] ctrl_cmd,output reg [63:0] ctrl_epoch,
 output wire [31:0] ctrl_rate,output reg ctrl_track,
 output reg [1:0] state,output wire [1:0] bank_count,
 output wire [8:0] free_pair_credit,reserved_pair_count,resident_pairs,
 output reg [63:0] accepted_pair_count,delivered_pair_count,discard_pair_count,
 output reg [31:0] accepted_packets,duplicate_packets,rejected_transactions,
 output reg [31:0] cs_conflicts,timeout_count,last_sequence,
 output reg [63:0] stream_epoch,next_source_start,
 output reg route_s11,
 output reg record_cmd_valid,input wire record_cmd_ready,
 output reg [1:0] record_cmd,output reg [63:0] record_cmd_id,
 output reg [7:0] record_cmd_mask,record_ack_kind,
 output reg [31:0] record_cmd_sequence,record_ack_sequence,
 input wire [2:0] record_state,input wire record_incomplete,
 input wire [7:0] record_mask,input wire [63:0] record_id,
 input wire [31:0] record_last_command,record_error,record_captured_pcm,input wire [63:0] record_first_missing_frame,
 input wire record_block_valid,input wire [7:0] record_block_kind,
 input wire [31:0] record_block_sequence,input wire [63:0] record_block_first,
 input wire [15:0] record_block_bytes,record_block_items,
 output wire [8:0] record_peek_address,input wire [7:0] record_peek_data
);
s10_pcm_transport #(.ENABLE_S11(1),.STREAM_STATUS_CRC(STREAM_STATUS_CRC)) impl(.clk(clk),.rst(rst),.spi_sck(spi_sck),.score_cs_n(score_cs_n),.control_cs_n(control_cs_n),.sd_cs_n(sd_cs_n),.spi_mosi(spi_mosi),.legacy_status_bytes(legacy_status_bytes),.stream_buffered(stream_buffered),.stream_generation(stream_generation),.stream_state(stream_state),.cancel(cancel),.spi_miso(spi_miso),.spi_miso_oe(spi_miso_oe),.route_s10(route_s10),.pcm_valid(pcm_valid),.pcm_ready(pcm_ready),.pcm_l(pcm_l),.pcm_r(pcm_r),.pcm_epoch(pcm_epoch),.ctrl_valid(ctrl_valid),.ctrl_ready(ctrl_ready),.ctrl_cmd(ctrl_cmd),.ctrl_epoch(ctrl_epoch),.ctrl_rate(ctrl_rate),.ctrl_track(ctrl_track),.state(state),.bank_count(bank_count),.free_pair_credit(free_pair_credit),.reserved_pair_count(reserved_pair_count),.resident_pairs(resident_pairs),.accepted_pair_count(accepted_pair_count),.delivered_pair_count(delivered_pair_count),.discard_pair_count(discard_pair_count),.accepted_packets(accepted_packets),.duplicate_packets(duplicate_packets),.rejected_transactions(rejected_transactions),.cs_conflicts(cs_conflicts),.timeout_count(timeout_count),.last_sequence(last_sequence),.stream_epoch(stream_epoch),.next_source_start(next_source_start),.route_s11(route_s11),.record_cmd_valid(record_cmd_valid),.record_cmd_ready(record_cmd_ready),.record_cmd(record_cmd),.record_cmd_id(record_cmd_id),.record_cmd_mask(record_cmd_mask),.record_ack_kind(record_ack_kind),.record_cmd_sequence(record_cmd_sequence),.record_ack_sequence(record_ack_sequence),.record_state(record_state),.record_incomplete(record_incomplete),.record_mask(record_mask),.record_id(record_id),.record_last_command(record_last_command),.record_error(record_error),.record_captured_pcm(record_captured_pcm),.record_first_missing_frame(record_first_missing_frame),.record_block_valid(record_block_valid),.record_block_kind(record_block_kind),.record_block_sequence(record_block_sequence),.record_block_first(record_block_first),.record_block_bytes(record_block_bytes),.record_block_items(record_block_items),.record_peek_address(record_peek_address),.record_peek_data(record_peek_data));
endmodule
