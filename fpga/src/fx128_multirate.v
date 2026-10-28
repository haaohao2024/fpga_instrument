// Native128k dry; rational 3/8 wet send retains the 48k effect timebase.
// Jobs at native 0,3,6 of each8; polyphase fractional delay 0,1/3,2/3.
// FIR centre64 + interpolation delay8 =72 native samples =562.5us.
module fx128_multirate #(parameter integer MIX_SHIFT=5)(
 input wire clk,rst,sample_tick,
 input wire signed[31:0] in_l_q8,in_r_q8,
 input wire in_valid,cfg_valid,input wire[351:0] cfg_data,
 output reg signed[31:0] out_l_q8,out_r_q8,output reg out_valid,
 output wire protocol_error,output reg[31:0] frame_count,
 output wire[31:0] cfg_accepted,cfg_rejected,
 output wire effective_bypass,output wire[351:0] observe_config,output wire[31:0] observe_version
);
 reg[2:0] phase,next_phase;reg started,local_error;reg[8:0] cycle;
 wire job_enable=phase==0||phase==3||phase==6;
 wire[1:0] job_phase=phase==0?0:phase==3?1:2;
 wire dry_request=started&&cycle==240;
 wire config_tick=started&&cycle==32&&job_enable;
 wire signed[31:0] dry_l,dry_r,filtered_l,filtered_r;
 wire dry_valid,filtered_valid,fir_error;
 fx128_downsample converter(.clk(clk),.rst(rst),.dry_request(dry_request),.job_enable(job_enable),.job_phase(job_phase),
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
 reg signed[32:0] wet_l[0:3],wet_r[0:3];
 wire older_three=phase==1||phase==2||phase==4||phase==5||phase==7;
 wire signed[32:0] lower_l=older_three?wet_l[3]:wet_l[2],lower_r=older_three?wet_r[3]:wet_r[2];
 wire signed[32:0] upper_l=older_three?wet_l[2]:wet_l[1],upper_r=older_three?wet_r[2]:wet_r[1];
 reg signed[33:0] delta_l,delta_r;
 reg signed[36:0] accumulator_l,accumulator_r;
 reg signed[31:0] dry_hold_l,dry_hold_r;
 reg[2:0] fraction;reg[2:0] interpolation_step;
 wire signed[36:0] dl_ext={{3{delta_l[33]}},delta_l},dr_ext={{3{delta_r[33]}},delta_r};
 // Three mutually exclusive cycles share one adder per channel.
 wire signed[36:0] add_l=interpolation_step==1?dl_ext:interpolation_step==2?(dl_ext<<<1):(dl_ext<<<2);
 wire signed[36:0] add_r=interpolation_step==1?dr_ext:interpolation_step==2?(dr_ext<<<1):(dr_ext<<<2);
 wire add_enable=(interpolation_step==1&&fraction[0])||(interpolation_step==2&&fraction[1])||(interpolation_step==3&&fraction[2]);
 wire signed[36:0] interp_l=(accumulator_l>>>3)+((accumulator_l<0&&accumulator_l[2:0]!=0)?37'sd1:37'sd0);
 wire signed[36:0] interp_r=(accumulator_r>>>3)+((accumulator_r<0&&accumulator_r[2:0]!=0)?37'sd1:37'sd0);
 function signed[31:0] saturate(input signed[37:0] v);
  if(v>38'sd2147483647)saturate=32'sh7fffffff;
  else if(v < -38'sd2147483648)saturate=32'sh80000000;else saturate=v[31:0];
 endfunction
 assign protocol_error=local_error|fir_error|effect_error;
 integer j;
 always @(posedge clk)begin
  if(rst)begin
   phase<=0;next_phase<=0;started<=0;cycle<=0;local_error<=0;
   send_l<=0;send_r<=0;send_pending<=0;
   for(j=0;j<4;j=j+1)begin wet_l[j]<=0;wet_r[j]<=0;end
   delta_l<=0;delta_r<=0;accumulator_l<=0;accumulator_r<=0;
   dry_hold_l<=0;dry_hold_r<=0;fraction<=0;interpolation_step<=0;
   out_valid<=0;out_l_q8<=0;out_r_q8<=0;frame_count<=0;
  end else begin
   out_valid<=0;
   if(sample_tick)begin phase<=next_phase;next_phase<=next_phase+1'b1;started<=1;cycle<=0;end
   else if(started&&cycle<511)cycle<=cycle+1'b1;
   if(filtered_valid)begin
    if(send_pending)local_error<=1;
    send_l<=filtered_l;send_r<=filtered_r;send_pending<=1;
   end
   if(effect_valid)begin
    if(!send_pending)local_error<=1;
    for(j=3;j>0;j=j-1)begin wet_l[j]<=wet_l[j-1];wet_r[j]<=wet_r[j-1];end
    wet_l[0]<=$signed({effect_l[31],effect_l})-$signed({send_l[31],send_l});
    wet_r[0]<=$signed({effect_r[31],effect_r})-$signed({send_r[31],send_r});
    send_pending<=0;
   end
   if(dry_valid)begin
    if(send_pending||interpolation_step!=0)local_error<=1;
    dry_hold_l<=dry_l;dry_hold_r<=dry_r;
    accumulator_l<=$signed({{4{lower_l[32]}},lower_l})<<<3;
    accumulator_r<=$signed({{4{lower_r[32]}},lower_r})<<<3;
    delta_l<=$signed({upper_l[32],upper_l})-$signed({lower_l[32],lower_l});
    delta_r<=$signed({upper_r[32],upper_r})-$signed({lower_r[32],lower_r});
    fraction<=3'(phase+(phase<<1));interpolation_step<=1;
   end else if(interpolation_step!=0)begin
    interpolation_step<=interpolation_step==4?0:interpolation_step+1'b1;
    if(add_enable)begin accumulator_l<=accumulator_l+add_l;accumulator_r<=accumulator_r+add_r;end
    if(interpolation_step==4)begin
     out_l_q8<=saturate($signed(dry_hold_l)+interp_l);out_r_q8<=saturate($signed(dry_hold_r)+interp_r);
     out_valid<=1;frame_count<=frame_count+1'b1;
    end
   end
  end
 end
endmodule

module fx128_downsample(
 input wire clk,rst,in_valid,dry_request,job_enable,input wire[1:0] job_phase,
 input wire signed[31:0] in_l,in_r,
 output reg signed[31:0] dry_l,dry_r,filtered_l,filtered_r,
 output reg dry_valid,filtered_valid,output reg protocol_error
);
 reg[63:0] history[0:255];
 reg[7:0] wp,base,age,job_age,tap;reg busy; reg[8:0] coefficient_base;
 reg signed[31:0] current_l,current_r;reg[63:0] ram_q;
 wire[31:0] coef_data;wire signed[17:0] coef_q=coef_data[17:0];
 reg read_valid,read_last,read_zero,read_current,product_valid,product_last,dry_pending,dry_zero;
 reg signed[49:0] product_l,product_r;reg signed[56:0] acc_l,acc_r;
 wire write_history=in_valid&&!busy;
 wire fir_read=busy&&tap<129;
 wire[7:0] address=dry_request?wp-8'd72:base-tap;
 wire[8:0] coefficient_address=coefficient_base+tap;
 pROM #(.BIT_WIDTH(32),.READ_MODE(0),.RESET_MODE("SYNC"),
 .INIT_RAM_00(256'h0003ffd70003fff90000001700000017000000020003fff20003fff500000000),
 .INIT_RAM_01(256'h0000003c0003ffc10003ff9d0003ffde0000003100000042000000110003ffdd),
 .INIT_RAM_02(256'h0000005400000104000000980003ffad0003ff3d0003ff9e0000004b0000008e),
 .INIT_RAM_03(256'h0003fdff0003fe4300000030000001a3000001420003ffb60003feb20003ff1e),
 .INIT_RAM_04(256'h0000040c000000c40003fd310003fce50003ffb2000002650000025900000000),
 .INIT_RAM_05(256'h0003fc4900000409000006ad0000025f0003fc5c0003faca0003fe920000033a),
 .INIT_RAM_06(256'h0003fb050003f10d0003f756000004b800000b22000005aa0003fb9a0003f770),
 .INIT_RAM_07(256'h00008fa7000043950003fab50003dac10003e7380000052c0000159000000dcd),
 .INIT_RAM_08(256'h000015900000052c0003e7380003dac10003fab50000439500008fa70000b006),
 .INIT_RAM_09(256'h0003fb9a000005aa00000b22000004b80003f7560003f10d0003fb0500000dcd),
 .INIT_RAM_0A(256'h0003fe920003faca0003fc5c0000025f000006ad000004090003fc490003f770),
 .INIT_RAM_0B(256'h00000259000002650003ffb20003fce50003fd31000000c40000040c0000033a),
 .INIT_RAM_0C(256'h0003feb20003ffb600000142000001a3000000300003fe430003fdff00000000),
 .INIT_RAM_0D(256'h0000004b0003ff9e0003ff3d0003ffad0000009800000104000000540003ff1e),
 .INIT_RAM_0E(256'h0000001100000042000000310003ffde0003ff9d0003ffc10000003c0000008e),
 .INIT_RAM_0F(256'h0003fff50003fff20000000200000017000000170003fff90003ffd70003ffdd),
 .INIT_RAM_10(256'h000000060000001d000000120003fffb0003fff00003fff80000000300000000),
 .INIT_RAM_11(256'h0003ffa50003ffa70003fffd00000042000000390003fffc0003ffd30003ffde),
 .INIT_RAM_12(256'h000001030000004d0003ff6c0003ff440003ffd8000000770000008400000010),
 .INIT_RAM_13(256'h0003fecb000000d8000001c1000000ce0003ff380003fea60003ff7d000000b0),
 .INIT_RAM_14(256'h0003ff5f0003fc9a0003fd93000000cc000002c6000001bd0003ff240003fdc6),
 .INIT_RAM_15(256'h000005cc000005e9000000330003fb1c0003fb8e000000510000041900000350),
 .INIT_RAM_16(256'h0003f1730003fbbd0000083300000a89000002430003f9230003f8260003fefe),
 .INIT_RAM_17(256'h000028950003ea800003dace0003f0f900000d4400001577000007bc0003f5ee),
 .INIT_RAM_18(256'h0003fb6d0003df790003dfe600000fba00005efe0000a11b0000ac4500007920),
 .INIT_RAM_19(256'h0000087e00000a4c0000006a0003f3cd0003f29c0000012a0000128e000012c6),
 .INIT_RAM_1A(256'h0003faad0003fe200000044f00000698000001ae0003f9f50003f7d00003fec1),
 .INIT_RAM_1B(256'h000001b20003fe9b0003fc990003fe290000021900000447000001e90003fcf6),
 .INIT_RAM_1C(256'h0000003f0000018e0000014e0003ff7f0003fdf10003fe7d000000e0000002ab),
 .INIT_RAM_1D(256'h0003ff6f0003ff4e0003fff9000000d2000000e30003ffed0003fedb0003fee9),
 .INIT_RAM_1E(256'h00000043000000190003ffc40003ff9f0003ffe6000000600000008600000015),
 .INIT_RAM_1F(256'h0003fff600000009000000190000000f0003ffed0003ffd50003ffeb00000024),
 .INIT_RAM_20(256'h0000001e0000000b0003fff40003fff00003fffc000000060003fffd0003fff3),
 .INIT_RAM_21(256'h0003ffbd0000001c0000004b000000280003ffe80003ffcf0003ffea00000012),
 .INIT_RAM_22(256'h0003fff80003ff400003ff630000001700000093000000690003ffe40003ff95),
 .INIT_RAM_23(256'h00000161000001a6000000430003fed60003fec70003ffeb000000f3000000e2),
 .INIT_RAM_24(256'h0003fc750003fe8c000001c6000002cb000000eb0003fe690003fdd50003ff78),
 .INIT_RAM_25(256'h0000046e0003fe120003fa830003fcdc000001fa0000046e0000022d0003fe17),
 .INIT_RAM_26(256'h0000006c00000a7a000008a70003febb0003f7a30003f9d1000001b9000006c4),
 .INIT_RAM_27(256'h0003dfbe0003df450003fb64000012f1000012bf0000012e0003f26f0003f3a0),
 .INIT_RAM_28(256'h0003db050003ea9900002875000078e90000ac2d0000a13900005f3400000fc8),
 .INIT_RAM_29(256'h000008100003fbce0003f1a60003f60f000007a60000154100000d280003f114),
 .INIT_RAM_2A(256'h00000032000005c1000005a70003ff040003f8530003f9480000023800000a59),
 .INIT_RAM_2B(256'h0003fdac0003fcbd0003ff6500000331000003f50000004f0003fbb20003fb41),
 .INIT_RAM_2C(256'h000001a8000000cc0003fedb0003fde20003ff2f000001a8000002a7000000c3),
 .INIT_RAM_2D(256'h0003ff7800000047000000f1000000a40003ff860003febc0003ff44000000c2),
 .INIT_RAM_2E(256'h0003fffd0003ffb00003ffae0000000f000000780000006c0003ffdb0003ff53),
 .INIT_RAM_2F(256'h0000000f00000018000000050003ffe30003ffd90003fffd000000320000003b),
 .INIT_RAM_30(256'h00000000000000000000000000000000000000000003fffa0003fff30003fffc),
 .INIT_RAM_31(256'h0000000000000000000000000000000000000000000000000000000000000000),
 .INIT_RAM_32(256'h0000000000000000000000000000000000000000000000000000000000000000),
 .INIT_RAM_33(256'h0000000000000000000000000000000000000000000000000000000000000000),
 .INIT_RAM_34(256'h0000000000000000000000000000000000000000000000000000000000000000),
 .INIT_RAM_35(256'h0000000000000000000000000000000000000000000000000000000000000000),
 .INIT_RAM_36(256'h0000000000000000000000000000000000000000000000000000000000000000),
 .INIT_RAM_37(256'h0000000000000000000000000000000000000000000000000000000000000000),
 .INIT_RAM_38(256'h0000000000000000000000000000000000000000000000000000000000000000),
 .INIT_RAM_39(256'h0000000000000000000000000000000000000000000000000000000000000000),
 .INIT_RAM_3A(256'h0000000000000000000000000000000000000000000000000000000000000000),
 .INIT_RAM_3B(256'h0000000000000000000000000000000000000000000000000000000000000000),
 .INIT_RAM_3C(256'h0000000000000000000000000000000000000000000000000000000000000000),
 .INIT_RAM_3D(256'h0000000000000000000000000000000000000000000000000000000000000000),
 .INIT_RAM_3E(256'h0000000000000000000000000000000000000000000000000000000000000000),
 .INIT_RAM_3F(256'h0000000000000000000000000000000000000000000000000000000000000000)) coefficient_rom(.CLK(clk),.CE(fir_read),.OCE(1'b1),.RESET(1'b0),.AD({coefficient_address,5'b0}),.DO(coef_data));

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
   coefficient_base<=0;wp<=0;base<=0;age<=0;job_age<=0;tap<=0;busy<=0;
   current_l<=0;current_r<=0;read_valid<=0;read_last<=0;read_zero<=0;read_current<=0;
   product_valid<=0;product_last<=0;product_l<=0;product_r<=0;acc_l<=0;acc_r<=0;
   dry_pending<=0;dry_zero<=1;dry_l<=0;dry_r<=0;filtered_l<=0;filtered_r<=0;
   dry_valid<=0;filtered_valid<=0;protocol_error<=0;
  end else begin
   dry_pending<=dry_request;dry_valid<=dry_pending;filtered_valid<=0;
   read_valid<=fir_read;product_valid<=read_valid;product_last<=read_last;
   if((in_valid&&busy)||(dry_request&&(busy||in_valid)))protocol_error<=1;
   if(dry_request)dry_zero<=age<72;
   if(dry_pending)begin dry_l<=dry_zero?32'sd0:$signed(ram_q[63:32]);dry_r<=dry_zero?32'sd0:$signed(ram_q[31:0]);end
   if(write_history)begin
    wp<=wp+1'b1;if(age<255)age<=age+1'b1;
    if(job_enable)begin coefficient_base<=job_phase==0?9'd0:job_phase==1?9'd129:9'd258; busy<=1;tap<=0;base<=wp;job_age<=age;current_l<=in_l;current_r<=in_r;acc_l<=0;acc_r<=0;end
   end
   if(fir_read)begin tap<=tap+1'b1;read_last<=tap==128;read_zero<=tap>job_age;read_current<=tap==0;end
   if(read_valid)begin product_l<=operand_l*coef_q;product_r<=operand_r*coef_q;end
   if(product_valid)begin
    acc_l<=acc_l+product_l;acc_r<=acc_r+product_r;
    if(product_last)begin filtered_l<=finish(acc_l+product_l);filtered_r<=finish(acc_r+product_r);filtered_valid<=1;busy<=0;end
   end
  end
 end
endmodule
