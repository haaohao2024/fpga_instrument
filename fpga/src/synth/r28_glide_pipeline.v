// Three pipeline stages replace four separate step3/4/5 operators. The
// full per-voice state travels with the arithmetic, never with a current slot.
module r28_glide_pipeline(input wire clk,rst,input wire[124:0] prepared,output reg[101:0] result);
 wire[22:0] target,pitch;wire[6:0] target_note;wire[16:0] remaining,base,error;
 wire[15:0] remainder;wire up;wire[3:0] code;
 assign {target,target_note,pitch,remaining,base,remainder,error,up,code}=prepared;
 wire[16:0] duration=17'd1<<({1'b0,code}+5'd5);
 wire[17:0] error_sum={1'b0,error}+{2'b0,remainder};
 reg[124:0] p1,p2;reg carry1;reg[16:0] error1,error2;reg[23:0] moved2;
 wire[22:0] target1,pitch1,target2,pitch2;wire[6:0] note1,note2;
 wire[16:0] rem1,base1,old_error1,rem2,base2,old_error2;wire[15:0] fraction1,fraction2;wire up1,up2;wire[3:0] code1,code2;
 assign {target1,note1,pitch1,rem1,base1,fraction1,old_error1,up1,code1}=p1;
 assign {target2,note2,pitch2,rem2,base2,fraction2,old_error2,up2,code2}=p2;
 wire[23:0] addend=up1?{7'd0,base1}:~{7'd0,base1};
 wire reached=(up2&&moved2>={1'b0,target2})||(!up2&&moved2<={1'b0,target2});
 always @(posedge clk)begin
  if(rst)begin p1<=0;p2<=0;carry1<=0;error1<=0;error2<=0;moved2<=0;result<=0;end
  else begin
   p1<=prepared;carry1<=error_sum>=duration;error1<=error_sum>=duration?17'(error_sum-duration):error_sum[16:0];
   p2<=p1;error2<=error1;moved2<={1'b0,pitch1}+addend+24'(up1?carry1:!carry1);
   if(rem2==0)result<={pitch2,note2,rem2,base2,fraction2,old_error2,up2,code2};
   else if(rem2==1||reached)result<={target2,note2,17'd0,base2,fraction2,17'd0,up2,code2};
   else result<={moved2[22:0],note2,17'(rem2-1'b1),base2,fraction2,error2,up2,code2};
  end
 end
endmodule
