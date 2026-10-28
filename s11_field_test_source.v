// Native RAW field producer: ordinary source1 events, no direct oscillator writes.
// Source1 tokens with bit63=1 are reserved for this producer. MCU score tokens
// retain all64 bits but are allocated below2^63. Each run reserves32 identities.
module s11_field_test_source #(parameter integer AUDIO_RATE_HZ=48000)(
 input wire clk,rst,request_valid,request_start,input wire [1:0] request_size,
 input wire [31:0] raw_frame,
 input wire [7:0] player_state,input wire [63:0] player_epoch,
 input wire player_ctrl_ready,input wire parser_clear,
 output wire request_ready,output reg active,output reg rejected,
 output wire committed,running,
 output reg ctrl_valid,output reg [7:0] ctrl_cmd,output wire [63:0] ctrl_epoch,
 output wire [63:0] ctrl_arg,
 output wire header_valid,eof_seen,output wire [63:0] last_verified_time,
 output wire record_valid,input wire record_ready,output reg [127:0] record_data,
 output wire [8:0] visible_records,output wire [5:0] voice_count
);
 localparam integer HOLD_FRAMES=AUDIO_RATE_HZ*512/48000;
 localparam integer END_FRAMES=AUDIO_RATE_HZ*768/48000;
 reg [57:0] run_id;
 reg [31:0] anchor;
 reg [1:0] size;
 reg [2:0] part;
 reg [5:0] key;
 reg [3:0] row_left;
 reg header_pending,launched,seen_busy,stop_requested;
 assign voice_count=size==0?6'd1:size==1?6'd8:size==2?6'd16:6'd32;
 assign request_ready=!rst&&!ctrl_valid;
 assign committed=!rst&&ctrl_valid&&player_ctrl_ready;
 assign running=active&&player_state==2;
 assign ctrl_epoch={1'b1,5'd0,run_id};
 assign ctrl_arg=0;
 assign header_valid=active&&launched;
 assign eof_seen=0;
 assign last_verified_time={32'd0,anchor}+END_FRAMES;
 wire stop_boundary=stop_requested&&header_pending&&key==0;
 assign record_valid=active&&launched&&part<3&&!stop_boundary;
 assign visible_records=record_valid?9'd1:9'd0;
 wire last_key=key==voice_count-1;
 wire [5:0] remaining=voice_count-key;
 wire [3:0] row_count=remaining>9?4'd9:remaining[3:0];
 wire [31:0] target=anchor+(part==0?0:part==1?HOLD_FRAMES:END_FRAMES);
 wire [7:0] key_byte={2'd0,key};
 wire [6:0] note=part==0?7'd48+key:7'd0;
 wire [7:0] pressure=part==0?8'd192:8'd0;
 always @*begin
  record_data=0;
  if(part==2)begin
   record_data[127:112]=16'h5248;
   record_data[101]=1;record_data[96]=1;
   record_data[95:64]=32'd1;
   record_data[63:32]=32'h00080001; // release source1, clear guide
   record_data[31:0]=target;
  end else if(header_pending)begin
   record_data[127:112]=16'h5248;
   record_data[110:107]=row_count;
   record_data[103:102]=2'd1;
   record_data[101]=remaining<=9;
   record_data[31:0]=target;
  end else begin
   record_data[96]=last_key;
   record_data[95:32]={1'b1,run_id,key[4:0]};
   record_data[31:0]={4'd1,(part==0?4'd1:4'd2),key_byte,note,pressure,1'b0};
  end
 end
 always @(posedge clk)begin
  if(rst)begin
   active<=0;rejected<=0;ctrl_valid<=0;ctrl_cmd<=0;run_id<=0;anchor<=0;
   size<=0;part<=0;key<=0;row_left<=0;header_pending<=1;
   launched<=0;seen_busy<=0;stop_requested<=0;
  end else begin
   rejected<=0;
   if(ctrl_valid&&player_ctrl_ready)begin
    ctrl_valid<=0;
    if(ctrl_cmd==1)begin launched<=1;anchor<=raw_frame+4;end
   end
   if(active&&player_state!=0)seen_busy<=1;
   if(active&&seen_busy&&player_state==0)begin active<=0;launched<=0;seen_busy<=0;end
   if(record_valid&&record_ready)begin
    if(part==2)part<=3;
    else if(header_pending)begin header_pending<=0;row_left<=row_count;end
    else begin
     row_left<=row_left-1'b1;
     if(last_key)begin part<=part+1'b1;key<=0;header_pending<=1;end
     else begin key<=key+1'b1;if(row_left==1)header_pending<=1;end
    end
   end
   // Never cut an open group. Once its final item has been offered, CLOSE
   // drains the ordinary dispatcher and performs the existing source cleanup.
   if(active&&launched&&!ctrl_valid&&part!=4&&(part==3||stop_boundary))begin
    ctrl_valid<=1;ctrl_cmd<=3;part<=4;
   end
   if(request_valid&&request_ready)begin
    if(request_start)begin
     if(active||player_state!=0||(&run_id))rejected<=1;
     else begin
      active<=1;size<=request_size;part<=0;key<=0;row_left<=0;header_pending<=1;
      launched<=0;seen_busy<=0;stop_requested<=0;run_id<=run_id+1'b1;
      ctrl_valid<=1;ctrl_cmd<=1;
     end
    end else if(active)stop_requested<=1;
    else rejected<=1;
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst&&record_valid&&!header_pending&&part<2)begin
  if(row_left==0||key>=voice_count)$fatal(1,"FIELD_RAW_ROW_STATE");
  if(!record_data[95])$fatal(1,"FIELD_TOKEN_NAMESPACE");
 end
 // synthesis translate_on
endmodule
