// The field sequence uses the ordinary source1 Sequencer and its STOP fence.
// No Voice slot or oscillator is written directly. ROM is generated from
// counters, so the 1/8/16/32 voice sequence consumes no additional BSRAM.
module s11_field_test_source (
 input wire clk,rst,request_valid,request_start,input wire [1:0] request_size,
 input wire [7:0] player_state,input wire [63:0] player_epoch,
 input wire player_ctrl_ready,input wire parser_clear,
 output wire request_ready,output reg active,output reg rejected,
 output wire committed,running,
 output reg ctrl_valid,output reg [7:0] ctrl_cmd,output reg [63:0] ctrl_epoch,
 output wire [63:0] ctrl_arg,
 output wire header_valid,eof_seen,output wire [63:0] last_verified_time,
 output wire record_valid,input wire record_ready,output wire [127:0] record_data,
 output wire [8:0] visible_records,output wire [5:0] voice_count
);
 reg [1:0] size,part;reg [5:0] key;reg launched,seen_busy;
 assign voice_count=size==0?6'd1:size==1?6'd8:size==2?6'd16:6'd32;
 assign request_ready=!rst&&!ctrl_valid;
 assign committed=!rst&&ctrl_valid&&player_ctrl_ready;
 assign running=active&&player_state==2;
 assign ctrl_arg=0;
 assign header_valid=active&&launched;
 assign eof_seen=active&&launched;
 assign last_verified_time=64'd768;
 assign record_valid=active&&launched&&part<3;
 wire last_key=key==voice_count-1;
 wire [63:0] record_time=part==0?64'd0:part==1?64'd512:64'd768;
 wire [7:0] record_op=part==0?8'd1:part==1?8'd2:8'd4;
 wire [7:0] record_key=part==2?8'd0:{2'd0,key};
 // Every voice has a distinct semitone, including the 32 Voice sequence.
 wire [7:0] record_note=part==0?8'd48+key:8'd0;
 wire [7:0] record_pressure=part==0?8'd192:8'd0;
 wire [31:0] record_flags=(part==2||last_key)?32'd1:32'd0;
 assign record_data={record_flags,record_pressure,record_note,record_key,record_op,record_time};
 assign visible_records=part==0?({3'd0,voice_count}<<1)+1-key:
                        part==1?{3'd0,voice_count}+1-key:part==2?9'd1:9'd0;
 always @(posedge clk)begin
  if(rst)begin active<=0;rejected<=0;ctrl_valid<=0;ctrl_cmd<=0;ctrl_epoch<=0;
   size<=0;part<=0;key<=0;launched<=0;seen_busy<=0;end
  else begin
   rejected<=0;
   if(ctrl_valid&&player_ctrl_ready)begin ctrl_valid<=0;if(ctrl_cmd==1)launched<=1;end
   if(active&&player_state!=0)seen_busy<=1;
   if(active&&seen_busy&&player_state==0)begin active<=0;launched<=0;seen_busy<=0;end
   if(record_valid&&record_ready)begin
    if(part==2)part<=3;
    else if(last_key)begin part<=part+1'b1;key<=0;end
    else key<=key+1'b1;
   end
   if(parser_clear&&active&&!seen_busy)begin part<=0;key<=0;end
   if(request_valid&&request_ready)begin
    if(request_start)begin
     if(active||player_state!=0)rejected<=1;
     else begin active<=1;size<=request_size;part<=0;key<=0;launched<=0;seen_busy<=0;
      ctrl_valid<=1;ctrl_cmd<=1;ctrl_epoch<=player_epoch==64'hffffffffffffffff ? 64'd1 : player_epoch+1'b1;end
    end else if(active)begin ctrl_valid<=1;ctrl_cmd<=3;ctrl_epoch<=player_epoch;end
    else rejected<=1;
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if((^{request_valid,request_start,request_size,record_ready,player_ctrl_ready})===1'bx)$fatal(1,"S11_FIELD_CONTROL_XZ");
 end
 // synthesis translate_on
endmodule
