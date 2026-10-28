// Combinational one-sample ADSR transition for a time-shared voice lane.
// Arithmetic is the same as voice_adsr; persistent state lives per voice.
module voice_adsr_step #(
    parameter integer SAMPLE_RATE_HZ=48000, ATTACK_MS=10, DECAY_MS=50,
    parameter integer SUSTAIN_LEVEL=180, RELEASE_MS=100
) (
    input wire [2:0] state,
    input wire [16:0] level,
    input wire [31:0] remaining,duration,remainder,error_acc,
    input wire [16:0] quotient,
    input wire gate,retrigger,
    output reg [2:0] state_next,
    output reg [16:0] level_next,
    output reg [31:0] remaining_next,duration_next,remainder_next,error_next,
    output reg [16:0] quotient_next
);
    localparam [2:0] IDLE=0,ATTACK=1,DECAY=2,SUSTAIN=3,RELEASE=4;
    localparam [31:0] A_N=(64'(SAMPLE_RATE_HZ)*ATTACK_MS+999)/1000;
    localparam [31:0] D_N=(64'(SAMPLE_RATE_HZ)*DECAY_MS+999)/1000;
    localparam [31:0] R_N=(64'(SAMPLE_RATE_HZ)*RELEASE_MS+999)/1000;
    localparam [31:0] A_SAFE=(A_N==0)?1:A_N;
    localparam [31:0] D_SAFE=(D_N==0)?1:D_N;
    localparam [31:0] R_SAFE=(R_N==0)?1:R_N;
    localparam [16:0] S_LEVEL=(SUSTAIN_LEVEL==255)?65536:SUSTAIN_LEVEL*257;
    reg [32:0] error_sum;
    reg [17:0] delta;
    always @* begin
        state_next=state;level_next=level;
        remaining_next=remaining;duration_next=duration;
        remainder_next=remainder;error_next=error_acc;quotient_next=quotient;
        error_sum={1'b0,error_acc}+{1'b0,remainder};
        delta={1'b0,quotient};
        if (error_sum>={1'b0,duration}) begin
            delta=delta+1'b1;error_next=error_sum-{1'b0,duration};
        end else error_next=error_sum[31:0];
        if (retrigger) begin
            level_next=0;state_next=ATTACK;error_next=0;
            remaining_next=A_N;duration_next=A_N;
            quotient_next=65536/A_SAFE;remainder_next=65536%A_SAFE;
            if (A_N==0) begin
                level_next=65536;state_next=DECAY;
                remaining_next=D_N;duration_next=D_N;
                quotient_next=(65536-S_LEVEL)/D_SAFE;
                remainder_next=(65536-S_LEVEL)%D_SAFE;
                if (D_N==0) begin level_next=S_LEVEL;state_next=SUSTAIN;end
            end
        end else if (!gate && state!=IDLE && state!=RELEASE) begin
            state_next=RELEASE;error_next=0;
            remaining_next=R_N;duration_next=R_N;
            quotient_next=level/R_SAFE;remainder_next=level%R_SAFE;
            if (R_N==0 || level==0) begin level_next=0;state_next=IDLE;end
        end else begin
            case (state)
                IDLE: begin level_next=0;error_next=0;end
                ATTACK,DECAY,RELEASE: begin
                    if (remaining>1) begin
                        remaining_next=remaining-1'b1;
                        if (state==ATTACK) level_next=level+delta;
                        else level_next=level-delta;
                    end else begin
                        error_next=0;remaining_next=0;
                        case (state)
                            ATTACK: begin
                                level_next=65536;state_next=DECAY;
                                remaining_next=D_N;duration_next=D_N;
                                quotient_next=(65536-S_LEVEL)/D_SAFE;
                                remainder_next=(65536-S_LEVEL)%D_SAFE;
                                if (D_N==0) begin level_next=S_LEVEL;state_next=SUSTAIN;end
                            end
                            DECAY: begin level_next=S_LEVEL;state_next=SUSTAIN;end
                            RELEASE: begin level_next=0;state_next=IDLE;end
                            default: begin level_next=0;state_next=IDLE;end
                        endcase
                    end
                end
                SUSTAIN: begin level_next=S_LEVEL;error_next=0;end
                default: begin level_next=0;state_next=IDLE;error_next=0;end
            endcase
        end
    end
endmodule

// Adjustable release with unchanged attack/decay/sustain. Persistent envelope
// state remains per oscillator. Duration is latched only on the gate-off edge.
// 7-bit constant divisions replace a wide run-time divider. For c=1..7,
// floor(level/(1024*c)) == floor(floor(level/1024)/c).
module voice_release_adsr_step #(parameter integer SAMPLE_RATE_HZ=48000, PREPARED_RELEASE=0) (
 input wire[6:0] prepared_release_q,
 input wire [3:0] release_code,
 input wire [2:0] state,input wire [16:0] level,quotient,
 input wire [31:0] remaining,duration,remainder,error_acc,
 input wire gate,retrigger,
 output wire [2:0] state_next,output wire [16:0] level_next,quotient_next,
 output wire [31:0] remaining_next,duration_next,remainder_next,error_next
);
 wire [2:0] bs;wire [16:0] bl,bq;wire [31:0] bn,bd,br,be;
 voice_adsr_step #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),.RELEASE_MS(0)) base(.state(state),.level(level),.quotient(quotient),
  .remaining(remaining),.duration(duration),.remainder(remainder),.error_acc(error_acc),
  .gate(gate),.retrigger(retrigger),.state_next(bs),.level_next(bl),.quotient_next(bq),
  .remaining_next(bn),.duration_next(bd),.remainder_next(br),.error_next(be));
 wire [2:0] c=release_code>7?3'd7:release_code[2:0];
 wire [18:0] level_times_three={2'b0,level}+({2'b0,level}<<1);
 wire [6:0] high_level=SAMPLE_RATE_HZ==128000 ? {1'b0,level_times_three[18:13]} : SAMPLE_RATE_HZ==96000 ? {1'b0,level[16:11]} : SAMPLE_RATE_HZ==72000 ? (level[16:9]/8'd3) : level[16:10];
 reg [6:0] local_q;
 always @*begin
  case(c)
   1:local_q=high_level;
   2:local_q=high_level>>1;
   3:local_q=high_level/7'd3;
   4:local_q=high_level>>2;
   5:local_q=high_level/7'd5;
   6:local_q=high_level/7'd6;
   7:local_q=high_level/7'd7;
   default:local_q=0;
  endcase
 end
 wire[6:0] q=PREPARED_RELEASE?prepared_release_q:local_q;
 // Keep this tiny product in logic; an inferred DSP adds unnecessary routing.
 reg [6:0] whole_blocks;
 always @*begin
  case(c)
   1:whole_blocks=q;
   2:whole_blocks=q<<1;
   3:whole_blocks=(q<<1)+q;
   4:whole_blocks=q<<2;
   5:whole_blocks=(q<<2)+q;
   6:whole_blocks=(q<<2)+(q<<1);
   7:whole_blocks=(q<<3)-q;
   default:whole_blocks=0;
  endcase
 end
 wire [16:0] old_residual=SAMPLE_RATE_HZ==96000 ? level-{whole_blocks,11'd0} : level-({whole_blocks,10'd0}+(SAMPLE_RATE_HZ==72000?{1'b0,whole_blocks,9'd0}:17'd0));
 wire [13:0] old_samples=SAMPLE_RATE_HZ==96000 ? {c,11'd0} : {1'b0,c,10'd0}+(SAMPLE_RATE_HZ==72000?{2'b0,c,9'd0}:14'd0);
 reg[14:0] samples128;reg[16:0] qproduct128;
 always @*begin
 samples128=0;qproduct128=0;
 case(c)
 1:begin samples128=15'd2731;case(q)
 0:qproduct128=17'd0;
 1:qproduct128=17'd2731;
 2:qproduct128=17'd5462;
 3:qproduct128=17'd8193;
 4:qproduct128=17'd10924;
 5:qproduct128=17'd13655;
 6:qproduct128=17'd16386;
 7:qproduct128=17'd19117;
 8:qproduct128=17'd21848;
 9:qproduct128=17'd24579;
 10:qproduct128=17'd27310;
 11:qproduct128=17'd30041;
 12:qproduct128=17'd32772;
 13:qproduct128=17'd35503;
 14:qproduct128=17'd38234;
 15:qproduct128=17'd40965;
 16:qproduct128=17'd43696;
 17:qproduct128=17'd46427;
 18:qproduct128=17'd49158;
 19:qproduct128=17'd51889;
 20:qproduct128=17'd54620;
 21:qproduct128=17'd57351;
 22:qproduct128=17'd60082;
 23:qproduct128=17'd62813;
 24:qproduct128=17'd65544;
 default:qproduct128=17'd131071;endcase end
 2:begin samples128=15'd5462;case(q)
 0:qproduct128=17'd0;
 1:qproduct128=17'd5462;
 2:qproduct128=17'd10924;
 3:qproduct128=17'd16386;
 4:qproduct128=17'd21848;
 5:qproduct128=17'd27310;
 6:qproduct128=17'd32772;
 7:qproduct128=17'd38234;
 8:qproduct128=17'd43696;
 9:qproduct128=17'd49158;
 10:qproduct128=17'd54620;
 11:qproduct128=17'd60082;
 12:qproduct128=17'd65544;
 default:qproduct128=17'd131071;endcase end
 3:begin samples128=15'd8192;case(q)
 0:qproduct128=17'd0;
 1:qproduct128=17'd8192;
 2:qproduct128=17'd16384;
 3:qproduct128=17'd24576;
 4:qproduct128=17'd32768;
 5:qproduct128=17'd40960;
 6:qproduct128=17'd49152;
 7:qproduct128=17'd57344;
 8:qproduct128=17'd65536;
 9:qproduct128=17'd73728;
 default:qproduct128=17'd131071;endcase end
 4:begin samples128=15'd10923;case(q)
 0:qproduct128=17'd0;
 1:qproduct128=17'd10923;
 2:qproduct128=17'd21846;
 3:qproduct128=17'd32769;
 4:qproduct128=17'd43692;
 5:qproduct128=17'd54615;
 6:qproduct128=17'd65538;
 default:qproduct128=17'd131071;endcase end
 5:begin samples128=15'd13654;case(q)
 0:qproduct128=17'd0;
 1:qproduct128=17'd13654;
 2:qproduct128=17'd27308;
 3:qproduct128=17'd40962;
 4:qproduct128=17'd54616;
 5:qproduct128=17'd68270;
 default:qproduct128=17'd131071;endcase end
 6:begin samples128=15'd16384;case(q)
 0:qproduct128=17'd0;
 1:qproduct128=17'd16384;
 2:qproduct128=17'd32768;
 3:qproduct128=17'd49152;
 4:qproduct128=17'd65536;
 5:qproduct128=17'd81920;
 default:qproduct128=17'd131071;endcase end
 7:begin samples128=15'd19115;case(q)
 0:qproduct128=17'd0;
 1:qproduct128=17'd19115;
 2:qproduct128=17'd38230;
 3:qproduct128=17'd57345;
 4:qproduct128=17'd76460;
 default:qproduct128=17'd131071;endcase end
 endcase
 end
 wire adjust128=qproduct128>level;
 wire[6:0] release_q=SAMPLE_RATE_HZ==128000?(adjust128?q-1'b1:q):q;
 wire[14:0] samples=SAMPLE_RATE_HZ==128000?samples128:{1'b0,old_samples};
 wire[16:0] residual=SAMPLE_RATE_HZ==128000?level-qproduct128+(adjust128?{2'b0,samples128}:17'd0):old_residual;
 wire begin_release=!retrigger&&!gate&&state!=0&&state!=4&&level!=0&&c!=0;
 assign state_next=begin_release?3'd4:bs;
 assign level_next=begin_release?level:bl;
 assign quotient_next=begin_release?{10'd0,release_q}:bq;
 assign remaining_next=begin_release?{17'd0,samples}:bn;
 assign duration_next=begin_release?{17'd0,samples}:bd;
 assign remainder_next=begin_release?{15'd0,residual}:br;
 assign error_next=begin_release?32'd0:be;
endmodule

// R78: shared one-shot envelope. A held gate and pressure/note updates cannot
// restart a completed hit: only the allocator's explicit trigger can do so.
// Reuse the existing per-voice envelope state/level; no new persistent storage.
module voice_drum_envelope_step #(parameter integer SAMPLE_RATE_HZ=48000)(
 input wire[2:0] role,state,input wire[16:0] level,input wire retrigger,
 output wire[2:0] state_next,output wire[16:0] level_next
);
 reg[16:0] delta;
 always @*begin
  case(role)
   0,4:delta=SAMPLE_RATE_HZ==128000 ? (({2'b0,level}+({2'b0,level}<<1)+19'd8191)>>13) : SAMPLE_RATE_HZ==96000 ? ((level+17'd2047)>>11) : SAMPLE_RATE_HZ==72000 ? (level+17'd1535)/17'd1536 : ((level+17'd1023)>>10);
   1,5,6:delta=SAMPLE_RATE_HZ==128000 ? (({2'b0,level}+({2'b0,level}<<1)+19'd4095)>>12) : SAMPLE_RATE_HZ==96000 ? ((level+17'd1023)>>10) : SAMPLE_RATE_HZ==72000 ? (level+17'd767)/17'd768 : ((level+17'd511)>>9);
   2:delta=SAMPLE_RATE_HZ==128000 ? (({2'b0,level}+({2'b0,level}<<1)+19'd1023)>>10) : SAMPLE_RATE_HZ==96000 ? ((level+17'd255)>>8) : SAMPLE_RATE_HZ==72000 ? (level+17'd191)/17'd192 : ((level+17'd127)>>7);
   3:delta=SAMPLE_RATE_HZ==128000 ? (({2'b0,level}+({2'b0,level}<<1)+19'd16383)>>14) : SAMPLE_RATE_HZ==96000 ? ((level+17'd4095)>>12) : SAMPLE_RATE_HZ==72000 ? (level+17'd3071)/17'd3072 : ((level+17'd2047)>>11);
   7:delta=SAMPLE_RATE_HZ==128000 ? (({2'b0,level}+({2'b0,level}<<1)+19'd32767)>>15) : SAMPLE_RATE_HZ==96000 ? ((level+17'd8191)>>13) : SAMPLE_RATE_HZ==72000 ? (level+17'd6143)/17'd6144 : ((level+17'd4095)>>12);
   default:delta=17'd1;
  endcase
 end
 wire done=state==0||level<=17'd32||level<=delta;
 assign state_next=retrigger?3'd2:done?3'd0:3'd2;
 assign level_next=retrigger?17'd65536:done?17'd0:level-delta;
endmodule
