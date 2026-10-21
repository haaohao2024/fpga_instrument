// Combinational one-sample ADSR transition for a time-shared voice lane.
// Arithmetic is the same as voice_adsr; persistent state lives per voice.
module voice_adsr_step #(
    parameter integer ATTACK_MS=10, DECAY_MS=50,
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
    localparam [31:0] A_N=(64'd48000*ATTACK_MS+999)/1000;
    localparam [31:0] D_N=(64'd48000*DECAY_MS+999)/1000;
    localparam [31:0] R_N=(64'd48000*RELEASE_MS+999)/1000;
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
module voice_release_adsr_step (
 input wire [3:0] release_code,
 input wire [2:0] state,input wire [16:0] level,quotient,
 input wire [31:0] remaining,duration,remainder,error_acc,
 input wire gate,retrigger,
 output wire [2:0] state_next,output wire [16:0] level_next,quotient_next,
 output wire [31:0] remaining_next,duration_next,remainder_next,error_next
);
 wire [2:0] bs;wire [16:0] bl,bq;wire [31:0] bn,bd,br,be;
 voice_adsr_step #(.RELEASE_MS(0)) base(.state(state),.level(level),.quotient(quotient),
  .remaining(remaining),.duration(duration),.remainder(remainder),.error_acc(error_acc),
  .gate(gate),.retrigger(retrigger),.state_next(bs),.level_next(bl),.quotient_next(bq),
  .remaining_next(bn),.duration_next(bd),.remainder_next(br),.error_next(be));
 wire [2:0] c=release_code>7?3'd7:release_code[2:0];
 wire [6:0] high_level=level[16:10];
 reg [6:0] q;
 always @*begin
  case(c)
   1:q=high_level;
   2:q=high_level>>1;
   3:q=high_level/7'd3;
   4:q=high_level>>2;
   5:q=high_level/7'd5;
   6:q=high_level/7'd6;
   7:q=high_level/7'd7;
   default:q=0;
  endcase
 end
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
 wire [16:0] residual=level-{whole_blocks,10'd0};
 wire [12:0] samples={c,10'd0};
 wire begin_release=!retrigger&&!gate&&state!=0&&state!=4&&level!=0&&c!=0;
 assign state_next=begin_release?3'd4:bs;
 assign level_next=begin_release?level:bl;
 assign quotient_next=begin_release?{10'd0,q}:bq;
 assign remaining_next=begin_release?{19'd0,samples}:bn;
 assign duration_next=begin_release?{19'd0,samples}:bd;
 assign remainder_next=begin_release?{15'd0,residual}:br;
 assign error_next=begin_release?32'd0:be;
endmodule
