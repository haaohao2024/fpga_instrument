// Passive measurement of completed synthesis work. All inputs are in clk.
// "nonzero" is a pre-effects voice contribution, not an estimate from MIDI.
// The 512-frame peak avoids counting silent allocated slots or summing tracks.
module r83_voice_metrics(
 input wire clk,rst,start,done,result_valid,result_accepted,result_gate,
 input wire signed [17:0] result_sample,
 input wire [8:0] complete_cycle,input wire protocol_error,deadline_error,
 output reg [127:0] metrics
);
 reg [5:0] completed,allocated,gated,nonzero,peak;
 reg [8:0] window_frame;
 reg [31:0] frame;
 wire [5:0] peak_next=nonzero>peak?nonzero:peak;
 always @(posedge clk)begin
  if(rst)begin completed<=0;allocated<=0;gated<=0;nonzero<=0;peak<=0;window_frame<=0;frame<=0;metrics<=0;end
  else begin
   if(start)begin completed<=0;allocated<=0;gated<=0;nonzero<=0;end
   if(result_valid)begin
    completed<=completed+1'b1;
    if(result_accepted)begin
     allocated<=allocated+1'b1;
     if(result_gate)gated<=gated+1'b1;
     if(result_sample!=0)nonzero<=nonzero+1'b1;
    end
   end
   if(done)begin
    frame<=frame+1'b1;window_frame<=window_frame+1'b1;
    peak<=window_frame==511?6'd0:peak_next;
    metrics[7:0]<=1;metrics[15:8]<=32;
    metrics[23:16]<={2'd0,allocated};metrics[31:24]<={2'd0,gated};
    metrics[39:32]<={2'd0,nonzero};
    if(window_frame==511)metrics[47:40]<={2'd0,peak_next};
    metrics[55:48]<={2'd0,completed};
    metrics[63:56]<={6'd0,deadline_error,protocol_error};
    metrics[79:64]<={7'd0,complete_cycle};metrics[95:80]<=512;
    metrics[127:96]<=frame;
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(start&&result_valid)$fatal(1,"R83_METRIC_OVERLAP");
  if(done&&(completed!=32||result_valid))$fatal(1,"R83_METRIC_INCOMPLETE_FRAME");
 end
 // synthesis translate_on
endmodule
