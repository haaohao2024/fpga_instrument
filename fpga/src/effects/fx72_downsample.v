// 72kHz dry remains unfiltered. Only the wet effect send is resampled to48k.
// One synchronous stereo history, sequential two-channel FIR; no reset on RAM.
// Output indices m correspond to input times 1.5*m-40. Dry is delayed42 frames
// to align with the subsequent causal48->72 wet interpolation.
module fx72_downsample(
 input wire clk,rst,in_valid,
 input wire signed[31:0] in_l,in_r,
 output reg signed[31:0] dry_l,dry_r,filtered_l,filtered_r,
 output reg dry_valid,filtered_valid,
 output reg[1:0] dry_phase,
 output reg protocol_error
);
 reg[63:0] history[0:127];
 reg signed[17:0] coefficients[0:163];
 initial $readmemh("src/effects/fx72_coeff.mem",coefficients);
 reg[6:0] wp,base,age;
 reg[1:0] phase,job_phase;
 reg busy,launch;
 reg[6:0] tap;
 reg signed[31:0] current_l,current_r;
 reg[63:0] ram_q;
 reg signed[17:0] coef_q;
 reg read_valid,read_last,read_zero,read_current;
 reg product_valid,product_last;
 reg signed[49:0] product_l,product_r;
 reg signed[56:0] acc_l,acc_r;
 reg[6:0] job_age;
 wire write_history=in_valid&&!busy;
 wire read_history=write_history || (busy&&!launch&&tap<82);
 wire[6:0] history_address=write_history?wp-7'd42:base-tap;
 wire signed[31:0] operand_l=read_zero?32'sd0:read_current?current_l:$signed(ram_q[63:32]);
 wire signed[31:0] operand_r=read_zero?32'sd0:read_current?current_r:$signed(ram_q[31:0]);
 function signed[31:0] finish(input signed[56:0] a);
  reg signed[56:0] b;
  begin
   b=(a>>>17)+((a<0 && a[16:0]!=0)?1:0);
   if(b>2147483647)finish=32'sh7fffffff;
   else if(b < -57'sd2147483648)finish=32'sh80000000;
   else finish=b[31:0];
  end
 endfunction
 // Single read port: dry read at launch, then coefficient taps. Write is
 // independent. Current sample bypass avoids read-during-write ambiguity.
 always @(posedge clk)begin
  if(write_history)history[wp]<={in_l,in_r};
  if(read_history)ram_q<=history[history_address];
  if(busy&&!launch && tap<82)coef_q<=coefficients[(job_phase==0?0:82)+tap];
 end
 always @(posedge clk)begin
  if(rst)begin
   wp<=0;base<=0;age<=0;phase<=0;job_phase<=0;busy<=0;launch<=0;tap<=0;
   current_l<=0;current_r<=0;read_valid<=0;read_last<=0;read_zero<=0;read_current<=0;
   product_valid<=0;product_last<=0;product_l<=0;product_r<=0;acc_l<=0;acc_r<=0;
   dry_l<=0;dry_r<=0;filtered_l<=0;filtered_r<=0;dry_valid<=0;filtered_valid<=0;dry_phase<=0;
   job_age<=0;protocol_error<=0;
  end else begin
   dry_valid<=0;filtered_valid<=0;read_valid<=0;product_valid<=read_valid;product_last<=read_last;
   if(in_valid&&busy)protocol_error<=1;
   if(in_valid&&!busy)begin
    busy<=1;launch<=1;tap<=0;base<=wp;wp<=wp+1'b1;
    job_phase<=phase;phase<=phase==2?0:phase+1'b1;
    job_age<=age;if(age<127)age<=age+1'b1;
    current_l<=in_l;current_r<=in_r;acc_l<=0;acc_r<=0;
   end
   if(launch)begin
    launch<=0;dry_valid<=1;dry_phase<=job_phase;
    dry_l<=job_age>=42?$signed(ram_q[63:32]):32'sd0;
    dry_r<=job_age>=42?$signed(ram_q[31:0]):32'sd0;
    if(job_phase==1)busy<=0;
   end else if(busy&&tap<82)begin
    read_valid<=1;read_last<=tap==81;read_zero<=tap>job_age;read_current<=tap==0;tap<=tap+1'b1;
   end
   if(read_valid)begin product_l<=operand_l*coef_q;product_r<=operand_r*coef_q;end
   if(product_valid)begin
    acc_l<=acc_l+product_l;acc_r<=acc_r+product_r;
    if(product_last)begin
     filtered_l<=finish(acc_l+product_l);filtered_r<=finish(acc_r+product_r);
     filtered_valid<=1;busy<=0;
    end
   end
  end
 end
endmodule
