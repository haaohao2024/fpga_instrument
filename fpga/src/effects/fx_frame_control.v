// Formal audio producer provides the complete frame configuration at tick,
// and the FX job starts only after all four lanes and the stereo mixer finish.
// This implementation prepares 10 independent ramp states during
// tick+1..tick+10 and commits EVERY public value on the original start edge.
module fx_frame_control(
 input wire clk,rst,start,sample_tick,
 input wire [351:0] config_data,input wire [2:0] clear_request,
 output wire [319:0] values,output reg [2:0] clear_pulse,
 output wire effective_bypass
);
 reg signed [19:0] current[0:9],prepared_current[0:9];
 reg [9:0] context_valid;
 reg [3:0] prep_slot;
 reg prep_busy,prepared;
 reg [2:0] clearing;
 wire [63:0] context_word;
 reg [63:0] next_context;
 reg signed [19:0] next_current;
 function [31:0] reset_current(input [3:0] s);
  begin case(s)
   6:reset_current=12288;7:reset_current=24576;
   8:reset_current=16384;9:reset_current=71583;
   default:reset_current=0;
  endcase end
 endfunction
 reg[3:0] context_slot_q;reg context_use_q,context_ready_q;
 reg[63:0] context_q;reg signed[19:0] current_q;reg signed[31:0] desired_q;
 reg signed[31:0] selected_desired;
 always @(posedge clk)begin
  if(rst)begin context_slot_q<=0;context_use_q<=0;context_ready_q<=0;context_q<=0;current_q<=0;desired_q<=0;end
  else begin
   context_ready_q<=prep_busy;
   if(prep_busy)begin
    context_slot_q<=prep_slot;context_use_q<=context_valid[prep_slot];
    context_q<=context_word;current_q<=current[prep_slot];desired_q<=selected_desired;
   end
  end
 end
 wire signed [19:0] target=context_use_q?context_q[19:0]:reset_current(context_slot_q);
 wire signed [10:0] increment=context_use_q?context_q[30:20]:32'd0;
 wire [9:0] residue=context_use_q?context_q[40:31]:11'd0;
 wire [9:0] error_acc=context_use_q?context_q[50:41]:11'd0;
 wire [9:0] remaining=context_use_q?context_q[60:51]:11'd0;
 wire sign_down=context_use_q?context_q[61]:1'b0;
 wire signed [19:0] old_current=current_q;
 wire signed[31:0] desired=desired_q;
 reg signed [19:0] delta,next_v;
 reg signed [10:0] step_v;
 reg [19:0] magnitude;
 reg [10:0] err_v;
 reg down_v;
 wire [10:0] ramp_length=context_slot_q==9?11'd1024:11'd64;
 wire [31:0] ramp_mask=context_slot_q==9?32'd1023:32'd63;
 always @*begin
  if(prep_slot<3)selected_desired=(!config_data[3]&&config_data[prep_slot]&&!clearing[prep_slot]&&!clear_request[prep_slot])?32768:0;
  else if(prep_slot<6)selected_desired=(!config_data[3]&&!clearing[prep_slot-3]&&!clear_request[prep_slot-3])?config_data[(prep_slot+5)*32+:32]:0;
  else case(prep_slot)
   6:selected_desired=config_data[95:64];7:selected_desired=config_data[223:192];
   8:selected_desired=config_data[255:224];default:selected_desired=config_data[191:160];
  endcase
 end
 always @*begin
  next_context={2'd0,sign_down,remaining,error_acc,residue,increment,target};
  next_current=old_current;
  delta=desired-old_current;down_v=delta<0;magnitude=down_v?-delta:delta;
  step_v=context_slot_q==9?$signed(magnitude>>10):$signed(magnitude>>6);
  if(down_v)step_v=-step_v;
  err_v={1'b0,error_acc}+{1'b0,residue};
  next_v=old_current+increment;
  if(err_v>=ramp_length)begin next_v=next_v+(sign_down?-1:1);err_v=err_v-ramp_length;end
  if(desired!=target)begin
   next_current=old_current+step_v;
   next_context[19:0]=desired;next_context[30:20]=step_v;
   next_context[40:31]=magnitude&ramp_mask;next_context[50:41]=magnitude&ramp_mask;
   next_context[60:51]=ramp_length-1'b1;next_context[61]=down_v;
  end else if(remaining!=0)begin
   next_current=remaining==1?target:next_v;
   next_context[60:51]=remaining-1'b1;next_context[50:41]=err_v;
  end
 end
 for(genvar n=0;n<16;n=n+1)begin: context_memory
  RAM16SDP4 memory(.CLK(clk),.WRE(!rst&&context_ready_q),.WAD(context_slot_q),.RAD(prep_slot),
   .DI(next_context[n*4+:4]),.DO(context_word[n*4+:4]));
 end
 for(genvar s=0;s<10;s=s+1)begin: states
  assign values[s*32+:32]=current[s];
  always @(posedge clk)begin
   if(rst)current[s]<=reset_current(s);
   else if(start)current[s]<=prepared_current[s];
   if(!rst&&context_ready_q&&context_slot_q==s)prepared_current[s]<=next_current;
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst&&context_ready_q)begin
  if(desired<0 || desired>447392)$fatal(1,"FX_CONTROL_TARGET_RANGE");
  if($signed(current_q)<0 || $signed(next_current)<0)$fatal(1,"FX_CONTROL_CURRENT_RANGE");
  if($signed(step_v)!=(down_v?-$signed(context_slot_q==9?(magnitude>>10):(magnitude>>6)):$signed(context_slot_q==9?(magnitude>>10):(magnitude>>6))))$fatal(1,"FX_CONTROL_STEP_RANGE");
 end
 // synthesis translate_on
 assign effective_bypass=current[3]==0&&current[4]==0&&current[5]==0;
 always @(posedge clk)begin
  clear_pulse<=0;
  if(rst)begin clearing<=0;context_valid<=0;prep_slot<=0;prep_busy<=0;prepared<=0;end
  else begin
   if(sample_tick)begin prep_slot<=0;prep_busy<=1;prepared<=0;end
   if(prep_busy)begin
    if(prep_slot==9)begin prep_busy<=0;end
    else prep_slot<=prep_slot+1'b1;
   end
   if(context_ready_q)begin
    context_valid[context_slot_q]<=1;
    if(context_slot_q==9)prepared<=1;
   end
   if(start)begin
    prepared<=0;
    for(integer c=0;c<3;c=c+1)begin
     if(clear_request[c])clearing[c]<=1;
     else if(clearing[c]&&current[c]==0&&current[c+3]==0)begin clear_pulse[c]<=1;clearing[c]<=0;end
    end
   end
  end
 end
 // Internal scheduling is narrowed ONLY on the formal producer connection.
 // No waiting path, backpressure, clock, PLL or public edge is introduced.
 // synthesis translate_off
 reg [351:0] preparing_config;reg [2:0] preparing_clear;
 reg capture_config;
 always @(posedge clk)begin
  if(rst)capture_config<=0;
  else begin
   capture_config<=sample_tick;
   if(capture_config)begin preparing_config<=config_data;preparing_clear<=clear_request;end
   if((prep_busy&&!capture_config)||context_ready_q||prepared)
    if({config_data,clear_request}!={preparing_config,preparing_clear})$fatal(1,"FX_PREP_CONFIG_CHANGED");
   if(sample_tick&&(prep_busy||context_ready_q||prepared))$fatal(1,"FX_PREP_FRAME_OVERLAP");
   if(start&&(!prepared||prep_busy||context_ready_q||sample_tick))$fatal(1,"FX_PREP_DEADLINE");
  end
 end
 // synthesis translate_on
endmodule
