`include "s9_constants.vh"
// Semantic validation before any frozen endpoint sees a remote transaction.
// S9AP framing/CRC/session were checked by reassembly; these are public ranges.
module s9_request_validate(
 input wire[1535:0] command_bytes,
 output reg legal,output reg signed[15:0] error_code
);
 wire[7:0] channel=command_bytes[47:40],op=command_bytes[55:48];
 wire[15:0] n=command_bytes[239:224];
 wire[1151:0] p=command_bytes[1407:256];
 wire[31:0] fx_base=p[127:96],fx_depth=p[159:128];
 integer i;reg[127:0] r;
 always @*begin
  legal=0;error_code=-4;r=0;
  if(channel==0)begin
   if(op!=`S9_OP_EVENTS||n==0||n%16!=0||n>144)error_code=-2;
   else begin
    legal=1;
    for(i=0;i<9;i=i+1)if(i<n/16)begin
     r=p[i*128+:128];
     if(r[127:96]!=0||r[71:64]<1||r[71:64]>4||r[87:80]>127)legal=0;
     if(r[71:64]==4)begin if(r[63:0]!=0||r[79:72]!=255||r[87:80]!=0)legal=0;end
     else begin
      if(r[63:0]==0||r[79:72]>=32)legal=0;
      if(r[71:64]==1&&r[95:88]==0)legal=0;
      if(r[71:64]==2&&r[95:80]!=0)legal=0;
     end
    end
   end
  end else if(channel==1)begin
   case(op)
    `S9_OP_HELLO,`S9_OP_KEEPALIVE,`S9_OP_DISCONNECT:begin legal=n==0;error_code=-1;end
    8'd41:legal=n==0;
    `S9_OP_QUERY_RESULT:legal=n==5&&p[7:0]<=2&&p[39:8]!=0;
    `S9_OP_BARRIER:legal=n==8&&p[7:0]<=1&&p[15:8]>=3&&p[15:8]<=5&&p[31:16]==0&&p[63:32]!=0;
    `S9_OP_TIMBRE:legal=n==1&&p[7:0]<=`S9_MAX_TIMBRE;
    `S9_OP_GLIDE:legal=n==1&&p[7:0]<=`S9_MAX_GLIDE;
    `S9_OP_PAN:legal=n==16&&p[63:0]!=0&&p[95:80]<=`S9_MAX_PAN&&p[127:96]==0;
    `S9_OP_GAIN:legal=n==8&&p[15:0]<=`S9_UNITY_GAIN&&p[31:16]<=`S9_UNITY_GAIN&&p[39:32]<=3&&p[63:40]==0;
    `S9_OP_KEYMAP:begin
     legal=n==8;
     if(n!=8)error_code=-1;
     for(i=0;i<8;i=i+1)if(p[i*8+:8]<`S9_KEYMAP_MIN||p[i*8+:8]>`S9_KEYMAP_MAX)legal=0;
    end
    `S9_OP_INSTANCE:legal=n==9&&p[7:0]<32&&p[71:8]!=0;
    `S9_OP_PLAY:legal=n==8&&p[7:0]>=1&&p[7:0]<=6&&p[7:0]!=2&&p[63:16]==0&&
     ((p[7:0]==1&&p[15:8]<=3)||(p[7:0]==6&&p[15:8]<=1)||((p[7:0]==3||p[7:0]==4||p[7:0]==5)&&p[15:8]==0));
    8'd86:legal=n==8&&p[63:16]==0&&((p[7:0]==1&&(p[15:8]==1||p[15:8]==8||p[15:8]==16||p[15:8]==32))||(p[7:0]==2&&p[15:8]==0));
    `S9_OP_EFFECTS:begin
     if(n!=44)begin legal=0;error_code=-1;end
     else legal=p[31:0]<=127&&p[63:32]>=`S9_DELAY_MIN&&p[63:32]<=`S9_DELAY_MAX&&p[95:64]<=`S9_DELAY_FEEDBACK_MAX&&
      fx_base>=`S9_CHORUS_BASE_MIN&&fx_base<=`S9_CHORUS_BASE_MAX&&fx_depth<=`S9_CHORUS_DEPTH_MAX&&
      fx_base>=fx_depth+2&&fx_base+fx_depth<=`S9_CHORUS_ADDRESS_MAX&&
      (p[191:160]==0||(p[191:160]>=`S9_CHORUS_STEP_MIN&&p[191:160]<=`S9_CHORUS_STEP_MAX))&&
      p[223:192]<=`S9_FDN_COEFFICIENT_MAX&&p[255:224]<=`S9_FDN_COEFFICIENT_MAX&&
      p[287:256]<=`S9_WET_GAIN_MAX&&p[319:288]<=`S9_WET_GAIN_MAX&&p[351:320]<=`S9_WET_GAIN_MAX;
    end
    default:error_code=-2;
   endcase
  end else error_code=-2;
  if(legal)error_code=0;
 end
endmodule
