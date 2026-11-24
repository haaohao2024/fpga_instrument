// One in-place complex DIF FFT packs L+jR. 12 stages, /2 per stage.
// Input/window, twiddles and every rounding operation are fixed-point and bit-exact.
// 8 BSRAM work + 1 quarter-wave ROM. Two shared signed 18x18 multipliers.
module visual_fft4096 #(parameter ROM_FILE="src/video/visual_cos_q16.mem")(
 input wire clk,rst,start,rectangular,
 input wire sample_valid,input wire signed [15:0] sample_l,sample_r,
 output wire sample_ready,output wire capturing,output wire busy,
 output reg spectrum_valid,input wire spectrum_ready,output reg [11:0] spectrum_bin,
 output reg signed [17:0] left_real,left_imag,right_real,right_imag,
 output reg [36:0] left_power,right_power,
 output reg done,output reg error,output reg [18:0] processing_cycles,
 output reg [18:0] last_processing_cycles
);
 localparam IDLE=0,CWAIT=1,C0=2,C1=3,C2=4,C3=5,C4=6,C5=7,C6=8,C7=9,
  F0=10,F1=11,F2=12,F3=13,F4=14,F5=15,F6=16,F7=17,F8=18,F9=19,
  P0=20,P1=21,P2=22,P3=23,P4=24,P5=25,P6=26,P7=27,PWAIT=28;
 reg [4:0] state;
 reg [11:0] capture_index,a_address,b_address,twiddle_phase;
 reg signed [15:0] captured_l,captured_r;
 reg [12:0] span,halfspan,group_base,j;
 reg [3:0] fft_stage;

 wire signed [17:0] a_r0,a_i0,b_r0,b_i0;
 reg signed [17:0] a_r,a_i,b_r,b_i;
 reg write_a,write_b;
 reg signed [17:0] wa_r,wa_i,wb_r,wb_i;

 reg [9:0] cos_address,sin_address;
 wire [17:0] cos_data,sin_data;
 reg signed [17:0] ma0,ma1,mb0,mb1;
 reg signed [35:0] m0_stage,m1_stage,m0,m1,first0,first1;
 reg signed [18:0] sum_r,sum_i;
 reg [11:0] post_bin;
 generate if(ROM_FILE=="src/video/visual_cos_q16.mem")begin: packed_cosine
  DPX9B #(.READ_MODE0(1'b0),.READ_MODE1(1'b0),
   .WRITE_MODE0(2'b00),.WRITE_MODE1(2'b00),.BIT_WIDTH_0(18),.BIT_WIDTH_1(18),
   .BLK_SEL_0(3'b000),.BLK_SEL_1(3'b000),.RESET_MODE("SYNC"),
`include "visual_cosine_init.vh"
  ) rom(.CLKA(clk),.CLKB(clk),.CEA(1'b1),.CEB(1'b1),.OCEA(1'b1),.OCEB(1'b1),
   .RESETA(1'b0),.RESETB(1'b0),.WREA(1'b0),.WREB(1'b0),
   .BLKSELA(3'b000),.BLKSELB(3'b000),.ADA({cos_address,4'b0000}),.ADB({sin_address,4'b0000}),
   .DIA(18'd0),.DIB(18'd0),.DOA(cos_data),.DOB(sin_data));
 end else begin: custom_cosine
  // Preserve the configurable-ROM interface for non-default tables.
  reg [17:0] memory[0:1023];reg [17:0] c,s;
  initial $readmemh(ROM_FILE,memory);
 always @(posedge clk)begin c<=memory[cos_address];s<=memory[sin_address];end
  assign cos_data=c;assign sin_data=s;
 end endgenerate
 function [9:0] quarter_address(input [11:0] phase);
  begin quarter_address=phase[10] ? (10'd0-phase[9:0]) : phase[9:0];end
 endfunction
 function signed [17:0] cosine_value(input [11:0] phase,input [17:0] value);
  reg signed [17:0] magnitude;
  begin
   magnitude=(phase[9:0]==0&&phase[10])?18'sd0:$signed(value);
   cosine_value=(phase[11]^phase[10]) ? -magnitude : magnitude;
  end
 endfunction
 wire signed [17:0] tw_cos=cosine_value(twiddle_phase,cos_data);
 wire [11:0] sin_phase=twiddle_phase-12'd1024;
 wire signed [17:0] tw_sin=cosine_value(sin_phase,sin_data);
 wire signed [18:0] difference_r=$signed({a_r[17],a_r})-$signed({b_r[17],b_r});
 wire signed [18:0] difference_i=$signed({a_i[17],a_i})-$signed({b_i[17],b_i});
 function signed [37:0] rounded(input signed [37:0] x,input integer shift);
  reg signed [38:0] magnitude;
  begin
   magnitude=x<0 ? -$signed({x[37],x}) : $signed({x[37],x});
   magnitude=(magnitude+(39'sd1<<(shift-1)))>>>shift;
   rounded=x<0 ? -magnitude : magnitude;
  end
 endfunction
 function [11:0] reverse12(input [11:0] x);
  integer i;begin for(i=0;i<12;i=i+1)reverse12[i]=x[11-i];end
 endfunction
 wire signed [37:0] rot_r=$signed({{2{first0[35]}},first0})+$signed({{2{first1[35]}},first1});
 wire signed [37:0] rot_i=$signed({{2{m1[35]}},m1})-$signed({{2{m0[35]}},m0});
 wire signed [37:0] pr=rounded($signed({{20{a_r[17]}},a_r})+$signed({{20{b_r[17]}},b_r}),1);
 wire signed [37:0] pi=rounded($signed({{20{a_i[17]}},a_i})-$signed({{20{b_i[17]}},b_i}),1);
 wire signed [37:0] qr=rounded($signed({{20{a_i[17]}},a_i})+$signed({{20{b_i[17]}},b_i}),1);
 wire signed [37:0] qi=rounded($signed({{20{b_r[17]}},b_r})-$signed({{20{a_r[17]}},a_r}),1);
 assign busy=state!=IDLE;
 assign sample_ready=state==CWAIT;
 assign capturing=state>=CWAIT&&state<=C7;
  ram18_dp work_real(.clk(clk),.ea(1'b1),.eb(1'b1),.wea(write_a),.web(write_b),
  .aa(a_address),.ab(b_address),.da(wa_r),.db(wb_r),.qa(a_r0),.qb(b_r0));
 ram18_dp work_imag(.clk(clk),.ea(1'b1),.eb(1'b1),.wea(write_a),.web(write_b),
  .aa(a_address),.ab(b_address),.da(wa_i),.db(wb_i),.qa(a_i0),.qb(b_i0));
 always @(posedge clk)begin
  // GW5AT-60B DPB supports normal/write-through, not read-before-write.
  // A port holds its read output during its own write. F0..F2 and P0..P2
  // refill both read pipeline stages before F3/F4/P3 consume them.
  a_r<=a_r0;a_i<=a_i0;b_r<=b_r0;b_i<=b_i0;

  m0_stage<=ma0*mb0;m1_stage<=ma1*mb1;m0<=m0_stage;m1<=m1_stage;
 end
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;capture_index<=0;a_address<=0;b_address<=0;twiddle_phase<=0;
   cos_address<=0;sin_address<=0;write_a<=0;write_b<=0;
   ma0<=0;ma1<=0;mb0<=0;mb1<=0;first0<=0;first1<=0;sum_r<=0;sum_i<=0;
   span<=4096;halfspan<=2048;group_base<=0;j<=0;fft_stage<=0;post_bin<=0;
   spectrum_valid<=0;spectrum_bin<=0;left_real<=0;left_imag<=0;right_real<=0;right_imag<=0;
   left_power<=0;right_power<=0;captured_l<=0;captured_r<=0;done<=0;error<=0;processing_cycles<=0;last_processing_cycles<=0;
   wa_r<=0;wa_i<=0;wb_r<=0;wb_i<=0;
  end else begin
   done<=0;write_a<=0;write_b<=0;
   if(state>=F0)begin processing_cycles<=processing_cycles+1'b1;if(processing_cycles>=320000)error<=1;end
   if(capturing&&sample_valid&&!sample_ready)error<=1;
   case(state)
    IDLE:if(start)begin state<=CWAIT;capture_index<=0;processing_cycles<=0;end
    CWAIT:if(sample_valid)begin
     captured_l<=sample_l;captured_r<=sample_r;a_address<=capture_index;
     twiddle_phase<=capture_index;cos_address<=quarter_address(capture_index);
     sin_address<=quarter_address(capture_index-12'd1024);state<=C0;
    end
    C0:state<=C1;
    C1:state<=C2;
    C2:begin
     ma0<={{2{captured_l[15]}},captured_l};ma1<={{2{captured_r[15]}},captured_r};
     // Field tests use a rectangular window of the Hann window's mean gain:
     // exact-bin test tones then occupy one bin each.
     mb0<=rectangular?19'sd32768:(19'sd65536-$signed({tw_cos[17],tw_cos}))>>>1;
     mb1<=rectangular?19'sd32768:(19'sd65536-$signed({tw_cos[17],tw_cos}))>>>1;state<=C3;
    end
    C3:state<=C4;
    C4:state<=C5;
    C5:begin wa_r<=rounded($signed({{2{m0[35]}},m0}),16);wa_i<=rounded($signed({{2{m1[35]}},m1}),16);write_a<=1;state<=C6;end
    C6:state<=C7;
    C7:if(capture_index==4095)begin
      span<=4096;halfspan<=2048;group_base<=0;j<=0;fft_stage<=0;state<=F0;
     end else begin capture_index<=capture_index+1'b1;state<=CWAIT;end
    F0:begin
     a_address<=group_base+j;b_address<=group_base+j+halfspan;
     twiddle_phase<=j<<fft_stage;cos_address<=quarter_address(j<<fft_stage);
     sin_address<=quarter_address((j<<fft_stage)-12'd1024);state<=F1;
    end
    F1:state<=F2;
    F2:state<=F3;
    F3:begin
     ma0<=difference_r;mb0<=tw_cos;ma1<=difference_i;mb1<=tw_sin;
     sum_r<=$signed({a_r[17],a_r})+$signed({b_r[17],b_r});
     sum_i<=$signed({a_i[17],a_i})+$signed({b_i[17],b_i});
     if(difference_r>131071||difference_r< -131072||difference_i>131071||difference_i< -131072)error<=1;
     state<=F4;
    end
    F4:begin ma0<=difference_r;mb0<=tw_sin;ma1<=difference_i;mb1<=tw_cos;state<=F5;end
    F5:state<=F6;
    F6:begin first0<=m0;first1<=m1;state<=F7;end
    F7:begin
     wa_r<=rounded($signed({{19{sum_r[18]}},sum_r}),1);wa_i<=rounded($signed({{19{sum_i[18]}},sum_i}),1);
     wb_r<=rounded(rot_r,17);wb_i<=rounded(rot_i,17);write_a<=1;write_b<=1;
     if(rounded(rot_r,17)>131071||rounded(rot_r,17)< -131072||rounded(rot_i,17)>131071||rounded(rot_i,17)< -131072)error<=1;
     state<=F8;
    end
    F8:state<=F9;
    F9:begin
     if(j+1<halfspan)begin j<=j+1'b1;state<=F0;end
     else if(group_base+span<4096)begin group_base<=group_base+span;j<=0;state<=F0;end
     else if(fft_stage<11)begin fft_stage<=fft_stage+1'b1;span<=halfspan;halfspan<=halfspan>>1;group_base<=0;j<=0;state<=F0;end
     else begin post_bin<=0;state<=P0;end
    end
    P0:begin a_address<=reverse12(post_bin);b_address<=reverse12(12'd0-post_bin);state<=P1;end
    P1:state<=P2;
    P2:state<=P3;
    P3:begin
     left_real<=pr;left_imag<=pi;right_real<=qr;right_imag<=qi;spectrum_bin<=post_bin;
     ma0<=pr;mb0<=pr;ma1<=pi;mb1<=pi;state<=P4;
    end
    P4:begin ma0<=right_real;mb0<=right_real;ma1<=right_imag;mb1<=right_imag;state<=P5;end
    P5:state<=P6;
    P6:begin left_power<={1'b0,m0}+{1'b0,m1};state<=P7;end
    P7:begin right_power<={1'b0,m0}+{1'b0,m1};spectrum_valid<=1;state<=PWAIT;end
    PWAIT:if(spectrum_ready)begin
     spectrum_valid<=0;
     if(post_bin==2048)begin done<=1;last_processing_cycles<=processing_cycles+1'b1;state<=IDLE;end
     else begin post_bin<=post_bin+1'b1;state<=P0;end
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
