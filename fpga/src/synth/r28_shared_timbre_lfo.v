// Lane L requests at offset5+L; the registered result is consumed at6+L.
// Per-oscillator LFO phase and timbre envelopes remain in independent RAM rows.
module r28_shared_timbre_lfo #(parameter integer SAMPLE_RATE_HZ=48000)(input wire clk,rst,start,busy,input wire[279:0] requests,output reg[81:0] response);
 reg[3:0] step;wire[1:0] lane=step[1:0]-2'd1;
 wire fresh;wire[2:0] timbre;wire[16:0] old_transient,old_body;wire[31:0] lfo;
 assign {fresh,timbre,old_transient,old_body,lfo}=requests[lane*70+:70];
 wire[16:0] transient_value=fresh?17'd65536:old_transient,body_value=fresh?17'd65536:old_body;
 wire[16:0] transient_delta=timbre==3?(SAMPLE_RATE_HZ==128000 ? (({2'b0,transient_value}+({2'b0,transient_value}<<1)+19'd8191)>>13) : SAMPLE_RATE_HZ==96000 ? ((transient_value+17'd2047)>>11) : SAMPLE_RATE_HZ==72000 ? (transient_value+17'd1535)/17'd1536 : ((transient_value+17'd1023)>>10)):(SAMPLE_RATE_HZ==128000 ? (({2'b0,transient_value}+({2'b0,transient_value}<<1)+19'd16383)>>14) : SAMPLE_RATE_HZ==96000 ? ((transient_value+17'd4095)>>12) : SAMPLE_RATE_HZ==72000 ? (transient_value+17'd3071)/17'd3072 : ((transient_value+17'd2047)>>11));
 wire[16:0] body_delta=(SAMPLE_RATE_HZ==128000 ? (({2'b0,body_value}+({2'b0,body_value}<<1)+19'd16383)>>14) : SAMPLE_RATE_HZ==96000 ? ((body_value+17'd4095)>>12) : SAMPLE_RATE_HZ==72000 ? (body_value+17'd3071)/17'd3072 : ((body_value+17'd2047)>>11));
 wire[16:0] drum_delta=(SAMPLE_RATE_HZ==128000 ? (({2'b0,transient_value}+({2'b0,transient_value}<<1)+19'd2047)>>11) : SAMPLE_RATE_HZ==96000 ? ((transient_value+17'd511)>>9) : SAMPLE_RATE_HZ==72000 ? (transient_value+17'd383)/17'd384 : ((transient_value+17'd255)>>8));
 wire[16:0] next_transient=(timbre==5)?(fresh?17'd65536:
  transient_value<=drum_delta?17'd0:transient_value-drum_delta):
  (fresh||(timbre!=1&&timbre!=3))?17'd65536:
  transient_value<=transient_delta?17'd0:transient_value-transient_delta;
 wire[16:0] next_body=(fresh||timbre!=3)?17'd65536:body_value<=body_delta?17'd0:body_value-body_delta;
 // Reuse each oscillator's 32-bit LFO state as its own drum noise state.
 // Xorshift32 advances once per audio sample without a multiplier or table.
 wire[31:0] noise1=lfo^(lfo<<13),noise2=noise1^(noise1>>17);
 wire[31:0] noise_next=fresh?32'h6d2b79f5:(noise2^(noise2<<5));
 wire signed[15:0] sine;sine_rom lfo_table(.address(lfo[31:24]),.sample(sine));
 always @(posedge clk)begin
  if(rst||start)begin step<=0;response<=0;end
  else begin
   if(busy)step<=step+1'b1;
   response<={(timbre==5?noise_next:32'(lfo+(SAMPLE_RATE_HZ==128000?32'd167772:SAMPLE_RATE_HZ==96000?32'd223696:SAMPLE_RATE_HZ==72000?32'd298262:32'd447392))),
    (timbre==5?$signed(noise_next[31:16]):sine),next_transient,next_body};
  end
 end
endmodule
