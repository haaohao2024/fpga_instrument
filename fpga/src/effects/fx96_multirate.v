// Native96k synthesis/dry with the unchanged48k effect engine.
// One frame contains312/313 system clocks at30MHz. The FIR/effect job
// crosses a frame boundary; it finishes before cycle240 of the next frame.
// Dry is fetched at240 independently of the current late voice result.
// FIR group delay52 + causal interpolation2 =54 native samples (562.5us).
module fx96_multirate #(parameter integer MIX_SHIFT=5)(
 input wire clk,rst,sample_tick,
 input wire signed[31:0] in_l_q8,in_r_q8,
 input wire in_valid,cfg_valid,input wire[351:0] cfg_data,
 output reg signed[31:0] out_l_q8,out_r_q8,output reg out_valid,
 output wire protocol_error,output reg[31:0] frame_count,
 output wire[31:0] cfg_accepted,cfg_rejected,
 output wire effective_bypass,output wire[351:0] observe_config,output wire[31:0] observe_version
);
 reg phase,next_phase,started,local_error;reg[8:0] cycle;
 wire dry_request=started&&cycle==240;
 wire config_tick=started&&cycle==32&&!phase;
 wire signed[31:0] dry_l,dry_r,filtered_l,filtered_r;
 wire dry_valid,filtered_valid,fir_error;
 fx96_downsample converter(.clk(clk),.rst(rst),.dry_request(dry_request),.even_sample(!phase),
  .in_valid(in_valid),.in_l(in_l_q8),.in_r(in_r_q8),.dry_l(dry_l),.dry_r(dry_r),
  .filtered_l(filtered_l),.filtered_r(filtered_r),.dry_valid(dry_valid),
  .filtered_valid(filtered_valid),.protocol_error(fir_error));
 wire signed[31:0] effect_l,effect_r;wire effect_valid,effect_error;
 r46_serial_effects #(.MIX_SHIFT(MIX_SHIFT),.SCHEDULED_CONTROL(1),.SHARED_MAC(0)) engine(
  .clk(clk),.rst(rst),.sample_tick(config_tick),.in_valid(filtered_valid),.in_l_q8(filtered_l),.in_r_q8(filtered_r),
  .cfg_valid(cfg_valid),.cfg_data(cfg_data),.out_l_q8(effect_l),.out_r_q8(effect_r),.out_valid(effect_valid),
  .protocol_error(effect_error),.frame_count(),.cfg_accepted(cfg_accepted),.cfg_rejected(cfg_rejected),
  .effective_bypass(effective_bypass),.observe_config(observe_config),.observe_version(observe_version),.fx_mac_q(48'd0));
 reg signed[31:0] send_l,send_r;reg send_pending;
 reg signed[32:0] wet_l0,wet_l1,wet_r0,wet_r1;
 reg signed[33:0] wet_sum_l,wet_sum_r;
 reg signed[31:0] dry_hold_l,dry_hold_r;
 reg calculate,return_pending;
 wire signed[33:0] interpolated_l=(wet_sum_l>>>1)+((wet_sum_l[33]&&wet_sum_l[0])?34'sd1:34'sd0);
 wire signed[33:0] interpolated_r=(wet_sum_r>>>1)+((wet_sum_r[33]&&wet_sum_r[0])?34'sd1:34'sd0);
 function signed[31:0] saturate(input signed[34:0] v);
  if(v>35'sd2147483647)saturate=32'sh7fffffff;
  else if(v < -35'sd2147483648)saturate=32'sh80000000;else saturate=v[31:0];
 endfunction
 assign protocol_error=local_error|fir_error|effect_error;
 always @(posedge clk)begin
  if(rst)begin
   phase<=0;next_phase<=0;started<=0;cycle<=0;local_error<=0;
   send_l<=0;send_r<=0;send_pending<=0;wet_l0<=0;wet_l1<=0;wet_r0<=0;wet_r1<=0;
   wet_sum_l<=0;wet_sum_r<=0;dry_hold_l<=0;dry_hold_r<=0;
   calculate<=0;return_pending<=0;out_valid<=0;out_l_q8<=0;out_r_q8<=0;frame_count<=0;
  end else begin
   if(sample_tick)begin phase<=next_phase;next_phase<=!next_phase;started<=1;cycle<=0;end
   else if(started&&cycle<511)cycle<=cycle+1'b1;
   if(filtered_valid)begin
    if(send_pending)local_error<=1;
    send_l<=filtered_l;send_r<=filtered_r;send_pending<=1;
   end
   if(effect_valid)begin
    if(!send_pending)local_error<=1;
    wet_l1<=wet_l0;wet_r1<=wet_r0;
    wet_l0<=$signed({effect_l[31],effect_l})-$signed({send_l[31],send_l});
    wet_r0<=$signed({effect_r[31],effect_r})-$signed({send_r[31],send_r});
    send_pending<=0;
   end
   // Even output time uses latest e[k-2]; odd uses mean(e[k-3],e[k-1]).
   // Both map to input time k-54. Divide by2 truncates toward zero.
   calculate<=dry_valid;return_pending<=calculate;out_valid<=return_pending;
   if(dry_valid)begin
    if(send_pending)local_error<=1;
    dry_hold_l<=dry_l;dry_hold_r<=dry_r;
    wet_sum_l<=phase?($signed(wet_l0)+$signed(wet_l1)):($signed(wet_l0)<<<1);
    wet_sum_r<=phase?($signed(wet_r0)+$signed(wet_r1)):($signed(wet_r0)<<<1);
   end
   if(calculate)begin
    out_l_q8<=saturate($signed(dry_hold_l)+$signed(interpolated_l));
    out_r_q8<=saturate($signed(dry_hold_r)+$signed(interpolated_r));
   end
   if(return_pending)frame_count<=frame_count+1'b1;
  end
 end
endmodule

module fx96_downsample(
 input wire clk,rst,in_valid,dry_request,even_sample,
 input wire signed[31:0] in_l,in_r,
 output reg signed[31:0] dry_l,dry_r,filtered_l,filtered_r,
 output reg dry_valid,filtered_valid,output reg protocol_error
);
 reg[63:0] history[0:127];
 reg[6:0] wp,base,age,job_age,tap;reg busy;
 reg signed[31:0] current_l,current_r;reg[63:0] ram_q;
 wire[31:0] coef_data;wire signed[17:0] coef_q=coef_data[17:0];
 reg read_valid,read_last,read_zero,read_current,product_valid,product_last,dry_pending,dry_zero;
 reg signed[49:0] product_l,product_r;reg signed[56:0] acc_l,acc_r;
 wire write_history=in_valid&&!busy;
 wire fir_read=busy&&tap<105;
 wire[6:0] address=dry_request?wp-7'd54:base-tap;
 pROM #(.BIT_WIDTH(32),.READ_MODE(0),.RESET_MODE("SYNC"),
  .INIT_RAM_00(256'h0000000f0003fffd0003fff90000000000000003000000000000000000000000),
  .INIT_RAM_01(256'h0000000e0003ffac0003ffe5000000320000001c0003ffe60003ffe90000000b),
  .INIT_RAM_02(256'h0003fedd0003ff1e000000a8000000ce0003ffb20003ff57000000130000007d),
  .INIT_RAM_03(256'h0003fc65000000e60000030f000000000003fd9b0003ff73000001bb000000d2),
  .INIT_RAM_04(256'h0003febc00000858000002f30003fa0a0003fc42000003e3000003e50003fdcf),
  .INIT_RAM_05(256'h000018e8000012320003f2d50003effa0000062200000d890003fe640003f515),
  .INIT_RAM_06(256'h0003ce7c000014f70000a1570000eaaa0000a157000014f70003ce7c0003ec1c),
  .INIT_RAM_07(256'h0003fe6400000d89000006220003effa0003f2d500001232000018e80003ec1c),
  .INIT_RAM_08(256'h000003e5000003e30003fc420003fa0a000002f3000008580003febc0003f515),
  .INIT_RAM_09(256'h000001bb0003ff730003fd9b000000000000030f000000e60003fc650003fdcf),
  .INIT_RAM_0A(256'h000000130003ff570003ffb2000000ce000000a80003ff1e0003fedd000000d2),
  .INIT_RAM_0B(256'h0003ffe90003ffe60000001c000000320003ffe50003ffac0000000e0000007d),
  .INIT_RAM_0C(256'h000000000000000000000003000000000003fff90003fffd0000000f0000000b),
  .INIT_RAM_0D(256'h0000000000000000000000000000000000000000000000000000000000000000),
  .INIT_RAM_0E(256'h0000000000000000000000000000000000000000000000000000000000000000),
  .INIT_RAM_0F(256'h0000000000000000000000000000000000000000000000000000000000000000)) coefficient_rom(.CLK(clk),.CE(fir_read),.OCE(1'b1),.RESET(1'b0),.AD({2'b0,tap,5'b0}),.DO(coef_data));

 wire signed[31:0] operand_l=read_zero?32'sd0:read_current?current_l:$signed(ram_q[63:32]);
 wire signed[31:0] operand_r=read_zero?32'sd0:read_current?current_r:$signed(ram_q[31:0]);
 function signed[31:0] finish(input signed[56:0] a);
  reg signed[56:0] b;
  begin b=(a>>>17)+((a<0&&a[16:0]!=0)?1:0);
   if(b>2147483647)finish=32'sh7fffffff;else if(b < -57'sd2147483648)finish=32'sh80000000;else finish=b[31:0];end
 endfunction
 always @(posedge clk)begin
  if(write_history)history[wp]<={in_l,in_r};
  if(dry_request||fir_read)ram_q<=history[address];

 end
 always @(posedge clk)begin
  if(rst)begin
   wp<=0;base<=0;age<=0;job_age<=0;tap<=0;busy<=0;
   current_l<=0;current_r<=0;read_valid<=0;read_last<=0;read_zero<=0;read_current<=0;
   product_valid<=0;product_last<=0;product_l<=0;product_r<=0;acc_l<=0;acc_r<=0;
   dry_pending<=0;dry_zero<=1;dry_l<=0;dry_r<=0;filtered_l<=0;filtered_r<=0;
   dry_valid<=0;filtered_valid<=0;protocol_error<=0;
  end else begin
   dry_pending<=dry_request;dry_valid<=dry_pending;filtered_valid<=0;
   read_valid<=fir_read;product_valid<=read_valid;product_last<=read_last;
   if((in_valid&&busy)||(dry_request&&(busy||in_valid)))protocol_error<=1;
   if(dry_request)dry_zero<=age<54;
   if(dry_pending)begin dry_l<=dry_zero?32'sd0:$signed(ram_q[63:32]);dry_r<=dry_zero?32'sd0:$signed(ram_q[31:0]);end
   if(write_history)begin
    wp<=wp+1'b1;if(age<127)age<=age+1'b1;
    if(even_sample)begin busy<=1;tap<=0;base<=wp;job_age<=age;current_l<=in_l;current_r<=in_r;acc_l<=0;acc_r<=0;end
   end
   if(fir_read)begin tap<=tap+1'b1;read_last<=tap==104;read_zero<=tap>job_age;read_current<=tap==0;end
   if(read_valid)begin product_l<=operand_l*coef_q;product_r<=operand_r*coef_q;end
   if(product_valid)begin
    acc_l<=acc_l+product_l;acc_r<=acc_r+product_r;
    if(product_last)begin filtered_l<=finish(acc_l+product_l);filtered_r<=finish(acc_r+product_r);filtered_valid<=1;busy<=0;end
   end
  end
 end
endmodule
