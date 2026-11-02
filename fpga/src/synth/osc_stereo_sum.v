// One completion per cycle at most; each accepted sample is panned and
// accumulated as it arrives. Integer sums are order-independent, so the
// mix equals the former fixed-pair schedule for any number of Lanes.
module osc_stereo_sum #(parameter integer LANES=6, COMPLETION_LIMIT=400, WIDE=0)(
 input wire clk,rst,sample_tick,
 input wire[LANES-1:0] completion_valid,completion_accept,
 input wire[3*LANES-1:0] completion_slot,input wire[18*LANES-1:0] completion_sample,
 input wire[9*LANES-1:0] completion_pan,
 output reg signed[31:0] mix_l_q8,mix_r_q8,output reg mix_valid,
 output reg protocol_error,deadline_error,output reg[8:0] last_complete_cycle
);
 localparam integer LW=LANES>8?4:3;
 reg[LW-1:0] lane;reg any;
 always @*begin lane=0;any=0;for(integer k=0;k<LANES;k++)if(completion_valid[k])begin lane=LW'(k);any=1;end end
 wire signed[17:0] in_sample=completion_accept[lane]?$signed(completion_sample[lane*18+:18]):18'sd0;
 wire[8:0] in_pan=completion_pan[lane*9+:9];
 wire[2:0] in_index=completion_slot[lane*3+:3];
 wire in_last=lane==LANES-1&&in_index==7;
 reg signed[17:0] operand;reg[8:0] coefficient;reg right_unity,op_valid,op_last;
 reg signed[27:0] product_l,product_r;reg product_valid,product_last,mix_pending;
 wire signed[27:0] variable_product=$signed(operand)*$signed({1'b0,coefficient});
 wire signed[27:0] unity_product=$signed({{10{operand[17]}},operand})<<<8;
 // 34-bit accumulation; WIDE saturates the 32-bit output, otherwise the low
 // 32 bits are kept exactly as a 32-bit accumulator would.
 reg signed[33:0] sum_l,sum_r;
 function signed[31:0] mix_out(input signed[33:0] v);
  mix_out=(WIDE==0||v[33:31]==3'b000||v[33:31]==3'b111) ? v[31:0] : v[33] ? 32'h80000000 : 32'h7fffffff;
 endfunction
 // One flat bit per (Lane, slot): an array indexed by the variable Lane was
 // synthesized as RAM whose whole-array clear did not take effect.
 reg busy;reg[8:0] age;reg[8*LANES-1:0] seen;
 always @(posedge clk)begin
  if(rst)begin
   operand<=0;coefficient<=256;right_unity<=0;op_valid<=0;op_last<=0;
   product_l<=0;product_r<=0;product_valid<=0;product_last<=0;mix_pending<=0;
   sum_l<=0;sum_r<=0;busy<=0;age<=0;
   mix_l_q8<=0;mix_r_q8<=0;mix_valid<=0;protocol_error<=0;deadline_error<=0;last_complete_cycle<=0;
   seen<=0;
  end else begin
   op_valid<=any;op_last<=any&&in_last;
   product_valid<=op_valid;product_last<=op_valid&&op_last;
   mix_pending<=product_valid&&product_last;mix_valid<=mix_pending;
   if(busy)begin age<=age+1'b1;if(age>=399)deadline_error<=1;end
   if(sample_tick)begin
    if(busy||op_valid||product_valid||any)deadline_error<=1;
    busy<=1;age<=0;sum_l<=0;sum_r<=0;
    seen<=0;
   end else if(product_valid)begin
    sum_l<=sum_l+{{6{product_l[27]}},product_l};
    sum_r<=sum_r+{{6{product_r[27]}},product_r};
   end
   if(any)begin
    if((completion_valid&(completion_valid-1'b1))!=0)protocol_error<=1;
    if(!busy||seen[{lane,in_index}])protocol_error<=1;
    if(in_index==7&&seen[{lane,3'd0}+:8]!=8'h7f)protocol_error<=1;
    seen[{lane,in_index}]<=1;
    if(in_pan>256)protocol_error<=1;
    operand<=in_sample;right_unity<=in_pan>128;
    coefficient<=in_pan>128?((9'd256-in_pan)<<1):(in_pan<<1);
   end
   if(op_valid)begin
    product_l<=right_unity?variable_product:unity_product;
    product_r<=right_unity?unity_product:variable_product;
   end
   if(mix_pending)begin
    mix_l_q8<=mix_out(sum_l);mix_r_q8<=mix_out(sum_r);busy<=0;last_complete_cycle<=age+1'b1;
    if(!busy||age>=COMPLETION_LIMIT)deadline_error<=1;
   end
  end
 end
endmodule
