// Sample-enabled linear ADSR. State/level_next describe THIS sample, not the last.
// Integer quotient + carried remainder makes every segment reach its exact
// endpoint after N sample intervals, even when N is greater than 65536.
module voice_adsr #(
    parameter integer ATTACK_MS = 10,
    parameter integer DECAY_MS = 50,
    parameter integer SUSTAIN_LEVEL = 180,
    parameter integer RELEASE_MS = 100
) (
    input wire clk, rst, sample_tick, gate, retrigger,
    output reg [2:0] state,
    output reg [16:0] level,
    output reg [2:0] state_next,
    output reg [16:0] level_next
);
    localparam [2:0] IDLE=0, ATTACK=1, DECAY=2, SUSTAIN=3, RELEASE=4;
    localparam [31:0] A_N = (64'd48000 * ATTACK_MS + 999) / 1000;
    localparam [31:0] D_N = (64'd48000 * DECAY_MS + 999) / 1000;
    localparam [31:0] R_N = (64'd48000 * RELEASE_MS + 999) / 1000;
    localparam [31:0] A_SAFE = (A_N == 0) ? 1 : A_N;
    localparam [31:0] D_SAFE = (D_N == 0) ? 1 : D_N;
    localparam [31:0] R_SAFE = (R_N == 0) ? 1 : R_N;
    localparam [16:0] S_LEVEL = (SUSTAIN_LEVEL == 255) ? 65536 : SUSTAIN_LEVEL*257;
    reg [31:0] remaining, duration, remainder, error_acc;
    reg [16:0] quotient;
    reg [31:0] remaining_next, duration_next, remainder_next, error_next;
    reg [16:0] quotient_next;
    reg [32:0] error_sum;
    reg [17:0] delta;

    always @* begin
        state_next=state; level_next=level;
        remaining_next=remaining; duration_next=duration;
        remainder_next=remainder; error_next=error_acc; quotient_next=quotient;
        error_sum={1'b0,error_acc}+{1'b0,remainder};
        delta={1'b0,quotient};
        if (error_sum >= {1'b0,duration}) begin
            delta=delta+1'b1;
            error_next=error_sum-{1'b0,duration};
        end else error_next=error_sum[31:0];

        if (retrigger) begin
            level_next=0; state_next=ATTACK; error_next=0;
            remaining_next=A_N; duration_next=A_N;
            quotient_next=65536/A_SAFE; remainder_next=65536%A_SAFE;
            if (A_N == 0) begin
                level_next=65536; state_next=DECAY;
                remaining_next=D_N; duration_next=D_N;
                quotient_next=(65536-S_LEVEL)/D_SAFE;
                remainder_next=(65536-S_LEVEL)%D_SAFE;
                if (D_N == 0) begin level_next=S_LEVEL; state_next=SUSTAIN; end
            end
        end else if (!gate && state != IDLE && state != RELEASE) begin
            state_next=RELEASE; error_next=0;
            remaining_next=R_N; duration_next=R_N;
            // Only a constant divisor; numerator is the level at release entry.
            quotient_next=level/R_SAFE; remainder_next=level%R_SAFE;
            if (R_N == 0 || level == 0) begin level_next=0; state_next=IDLE; end
        end else begin
            case (state)
                IDLE: begin level_next=0; error_next=0; end
                ATTACK, DECAY, RELEASE: begin
                    if (remaining > 1) begin
                        remaining_next=remaining-1'b1;
                        if (state == ATTACK) level_next=level+delta;
                        else level_next=level-delta;
                    end else begin
                        error_next=0; remaining_next=0;
                        case (state)
                            ATTACK: begin
                                level_next=65536; state_next=DECAY;
                                remaining_next=D_N; duration_next=D_N;
                                quotient_next=(65536-S_LEVEL)/D_SAFE;
                                remainder_next=(65536-S_LEVEL)%D_SAFE;
                                if (D_N == 0) begin level_next=S_LEVEL; state_next=SUSTAIN; end
                            end
                            DECAY: begin level_next=S_LEVEL; state_next=SUSTAIN; end
                            RELEASE: begin level_next=0; state_next=IDLE; end
                            default: begin level_next=0; state_next=IDLE; end
                        endcase
                    end
                end
                SUSTAIN: begin level_next=S_LEVEL; error_next=0; end
                default: begin level_next=0; state_next=IDLE; error_next=0; end
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state<=IDLE; level<=0; remaining<=0; duration<=1;
            remainder<=0; error_acc<=0; quotient<=0;
        end else if (sample_tick) begin
            state<=state_next; level<=level_next;
            remaining<=remaining_next; duration<=duration_next;
            remainder<=remainder_next; error_acc<=error_next; quotient<=quotient_next;
        end
    end
endmodule
