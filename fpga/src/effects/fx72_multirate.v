// Native72k dry +48k effect history. The two rational sample grids share clk.
// All effect ranges, coefficients and history lifetimes remain in48k units.
module fx72_multirate #(parameter integer MIX_SHIFT=5)(
 input wire clk,rst,sample_tick,
 input wire signed[31:0] in_l_q8,in_r_q8,
 input wire in_valid,cfg_valid,input wire[351:0] cfg_data,
 output reg signed[31:0] out_l_q8,out_r_q8,output reg out_valid,
 output wire protocol_error,output reg[31:0] frame_count,
 output wire[31:0] cfg_accepted,cfg_rejected,
 output wire effective_bypass,output wire[351:0] observe_config,output wire[31:0] observe_version
);
 reg[1:0] phase,next_phase;
 reg[8:0] cycle;
 reg frame_started,local_error;
 wire config_tick=frame_started && cycle==96 && phase!=1;
 wire signed[31:0] dry_l,dry_r,filtered_l,filtered_r;
 wire dry_valid,filtered_valid,fir_error;
 wire[1:0] dry_phase;
 fx72_downsample converter(.clk(clk),.rst(rst),.in_valid(in_valid),.in_l(in_l_q8),.in_r(in_r_q8),
  .dry_l(dry_l),.dry_r(dry_r),.filtered_l(filtered_l),.filtered_r(filtered_r),
  .dry_valid(dry_valid),.filtered_valid(filtered_valid),.dry_phase(dry_phase),.protocol_error(fir_error));
 wire signed[31:0] effect_l,effect_r;
 wire effect_valid,effect_error;
 wire[31:0] effect_frames;
 r46_serial_effects #(.MIX_SHIFT(MIX_SHIFT),.SCHEDULED_CONTROL(1),.SHARED_MAC(0)) engine(
  .clk(clk),.rst(rst),.sample_tick(config_tick),.in_valid(filtered_valid),.in_l_q8(filtered_l),.in_r_q8(filtered_r),
  .cfg_valid(cfg_valid),.cfg_data(cfg_data),.out_l_q8(effect_l),.out_r_q8(effect_r),.out_valid(effect_valid),
  .protocol_error(effect_error),.frame_count(effect_frames),.cfg_accepted(cfg_accepted),.cfg_rejected(cfg_rejected),
  .effective_bypass(effective_bypass),.observe_config(observe_config),.observe_version(observe_version),.fx_mac_q(48'd0));
 reg signed[31:0] send_l,send_r;
 reg send_pending;
 reg signed[32:0] wet_l0,wet_r0,wet_l1,wet_r1;
 reg signed[34:0] numerator_l,numerator_r;
 reg signed[31:0] dry_hold_l,dry_hold_r;
 reg division_start;wire division_ready,division_valid;
 wire signed[34:0] quotient_l,quotient_r;
 wire signed[32:0] interpolated_l=quotient_l[32:0],interpolated_r=quotient_r[32:0];
 reg result_pending;
 div3_pair35 interpolator(.clk(clk),.rst(rst),.in_valid(division_start),.in_ready(division_ready),
  .numerator_l(numerator_l),.numerator_r(numerator_r),.out_valid(division_valid),
  .quotient_l(quotient_l),.quotient_r(quotient_r));
 function signed[31:0] saturate(input signed[34:0] a);
  begin if(a>35'sd2147483647)saturate=32'sh7fffffff;
   else if(a < -35'sd2147483648)saturate=32'sh80000000;else saturate=a[31:0];end
 endfunction
 assign protocol_error=fir_error|effect_error|local_error;
 always @(posedge clk)begin
  if(rst)begin
   phase<=0;next_phase<=0;cycle<=0;frame_started<=0;local_error<=0;
   send_l<=0;send_r<=0;send_pending<=0;wet_l0<=0;wet_l1<=0;wet_r0<=0;wet_r1<=0;
   numerator_l<=0;numerator_r<=0;division_start<=0;result_pending<=0;
   dry_hold_l<=0;dry_hold_r<=0;out_l_q8<=0;out_r_q8<=0;out_valid<=0;frame_count<=0;
  end else begin
   if(sample_tick)begin phase<=next_phase;next_phase<=next_phase==2?0:next_phase+1'b1;cycle<=0;frame_started<=1;end
   else if(frame_started&&cycle<511)cycle<=cycle+1'b1;
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
   division_start<=dry_valid;result_pending<=division_valid;out_valid<=result_pending;
   if(division_start&&!division_ready)local_error<=1;
   if(dry_valid)begin
    if(dry_phase!=phase)local_error<=1;
    dry_hold_l<=dry_l;dry_hold_r<=dry_r;
    // Causal wet resampling at native time k-2:
    // phase0: (older+2*latest)/3; phase1: (2*older+latest)/3;
    // phase2: latest exactly. Full33bit delta survives extreme saturation.
    case(dry_phase)
     0:begin numerator_l<=$signed(wet_l1)+($signed(wet_l0)<<<1);numerator_r<=$signed(wet_r1)+($signed(wet_r0)<<<1);end
     1:begin numerator_l<=($signed(wet_l1)<<<1)+$signed(wet_l0);numerator_r<=($signed(wet_r1)<<<1)+$signed(wet_r0);end
     default:begin numerator_l<=$signed(wet_l0)*3;numerator_r<=$signed(wet_r0)*3;end
    endcase
   end
   if(division_valid)begin
    out_l_q8<=saturate($signed(dry_hold_l)+$signed(interpolated_l));
    out_r_q8<=saturate($signed(dry_hold_r)+$signed(interpolated_r));
   end
   if(result_pending)frame_count<=frame_count+1'b1;
  end
 end
endmodule

// Original local implementation: exact signed constant divide, fixed schedule.
// Two stereo lanes keep their own arithmetic state; one shared bit counter.
module div3_pair35(input wire clk,rst,in_valid,output wire in_ready,
 input wire signed[34:0] numerator_l,numerator_r,
 output reg out_valid,output reg signed[34:0] quotient_l,quotient_r);
 reg busy,finish;reg[5:0] bits_left;reg negative_l,negative_r;
 reg[34:0] work_l,work_r;reg[1:0] remainder_l,remainder_r;
 wire[2:0] next_l={remainder_l,work_l[34]},next_r={remainder_r,work_r[34]};
 wire bit_l=next_l>=3,bit_r=next_r>=3;
 assign in_ready=!busy&&!finish&&!rst;
 always @(posedge clk)begin
  if(rst)begin busy<=0;finish<=0;bits_left<=0;negative_l<=0;negative_r<=0;
   work_l<=0;work_r<=0;remainder_l<=0;remainder_r<=0;
   quotient_l<=0;quotient_r<=0;out_valid<=0;end
  else begin
   out_valid<=0;finish<=0;
   if(in_valid&&in_ready)begin
    busy<=1;bits_left<=34;negative_l<=numerator_l[34];negative_r<=numerator_r[34];
    work_l<=numerator_l[34]?-numerator_l:numerator_l;
    work_r<=numerator_r[34]?-numerator_r:numerator_r;
    remainder_l<=0;remainder_r<=0;
   end
   if(busy)begin
    work_l<={work_l[33:0],bit_l};work_r<={work_r[33:0],bit_r};
    remainder_l<=bit_l?next_l-3:next_l;remainder_r<=bit_r?next_r-3:next_r;
    bits_left<=bits_left-1'b1;
    if(bits_left==0)begin busy<=0;finish<=1;end
   end
   if(finish)begin
    quotient_l<=negative_l?-$signed(work_l):$signed(work_l);
    quotient_r<=negative_r?-$signed(work_r):$signed(work_r);out_valid<=1;
   end
  end
 end
endmodule
