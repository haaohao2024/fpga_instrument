// One sample of per-instance pitch movement. Pitch is MIDI semitones in Q7.16.
// A remainder accumulator guarantees the exact target after 2^k samples.
module glide_pitch_step (
    input wire new_owner,
    input wire [6:0] note_target,
    input wire [3:0] glide_code, // 0=off; 1..11 => 2^(code+5) samples
    input wire [22:0] current_pitch,
    input wire [6:0] stored_target,
    input wire [16:0] remaining,
    input wire [16:0] base_step,
    input wire [15:0] remainder,
    input wire [16:0] error_acc,
    input wire direction_up,
    input wire [3:0] stored_code,
    output reg [22:0] pitch_next,
    output reg [6:0] target_next,
    output reg [16:0] remaining_next,
    output reg [16:0] base_next,
    output reg [15:0] remainder_next,
    output reg [16:0] error_next,
    output reg direction_next,
    output reg [3:0] code_next,
    output wire [31:0] phase_step
);
    reg [4:0] k;
    reg [16:0] duration, work_remaining, work_base, work_error;
    reg [15:0] work_remainder;
    reg work_up;
    reg [22:0] target_pitch, work_pitch, delta;
    reg [17:0] error_sum, increment;
    reg [23:0] moved;
    reg [6:0] lower_note, upper_note;
    wire [31:0] lower_step, upper_step;
    wire [31:0] step_delta=upper_step-lower_step;
    wire [47:0] fraction_product=step_delta*pitch_next[15:0];
    wire [48:0] interpolated={17'd0,lower_step}+
        (({1'b0,fraction_product}+49'd32768)>>16);
    assign phase_step=interpolated[31:0];
    phase_step_rom u_lower(.note_code(lower_note),.phase_step(lower_step));
    phase_step_rom u_upper(.note_code(upper_note),.phase_step(upper_step));

    always @* begin
        target_pitch={note_target,16'd0};
        target_next=stored_target;
        work_pitch=current_pitch;
        work_remaining=remaining;
        work_base=base_step;
        work_remainder=remainder;
        work_error=error_acc;
        work_up=direction_up;
        code_next=stored_code;
        k=0;duration=0;delta=0;error_sum=0;increment=0;moved=0;
        if (new_owner) begin
            target_next=note_target;
            work_pitch=target_pitch;
            work_remaining=0;work_base=0;work_remainder=0;work_error=0;
            work_up=1;
            code_next=0;
        end else if (glide_code==0 && (note_target!=stored_target || remaining!=0)) begin
            target_next=note_target;
            work_pitch=target_pitch;
            work_remaining=0;work_base=0;work_remainder=0;work_error=0;
            work_up=1;
            code_next=0;
        end else if (note_target!=stored_target) begin
            target_next=note_target;
            k=(glide_code>11)?5'd16:{1'b0,glide_code}+5'd5;
            duration=17'd1<<k;
            work_up=(target_pitch>=current_pitch);
            delta=work_up?(target_pitch-current_pitch):(current_pitch-target_pitch);
            work_base=delta>>k;
            work_remainder=delta & (duration-1'b1);
            work_error=0;
            work_remaining=duration;
            code_next=(glide_code>11)?4'd11:glide_code;
        end
        if (work_remaining!=0) begin
            k={1'b0,code_next}+5'd5;
            duration=17'd1<<k;
            error_sum={1'b0,work_error}+{2'b0,work_remainder};
            increment={1'b0,work_base};
            if (error_sum>=duration) begin
                increment=increment+1'b1;
                work_error=error_sum-duration;
            end else work_error=error_sum[16:0];
            if (work_remaining==1) begin
                work_pitch=target_pitch;
                work_remaining=0;work_error=0;
            end else begin
                moved=work_up?({1'b0,work_pitch}+increment):
                    ({1'b0,work_pitch}-increment);
                if ((work_up && moved>={1'b0,target_pitch}) ||
                    (!work_up && moved<={1'b0,target_pitch})) begin
                    work_pitch=target_pitch;work_remaining=0;work_error=0;
                end else begin
                    work_pitch=moved[22:0];
                    work_remaining=work_remaining-1'b1;
                end
            end
        end
        pitch_next=work_pitch;
        remaining_next=work_remaining;
        base_next=work_base;
        remainder_next=work_remainder;
        error_next=work_error;
        direction_next=work_up;
        lower_note=pitch_next[22:16];
        upper_note=(lower_note==7'd127)?7'd127:lower_note+1'b1;
    end
endmodule

// One sample of per-instance pitch movement. Pitch is MIDI semitones in Q7.16.
// A remainder accumulator guarantees the exact target after 2^k samples.
module glide_pitch_prepare (
    input wire new_owner,
    input wire [6:0] note_target,
    input wire [3:0] glide_code, // 0=off; 1..11 => 2^(code+5) samples
    input wire [22:0] current_pitch,
    input wire [6:0] stored_target,
    input wire [16:0] remaining,
    input wire [16:0] base_step,
    input wire [15:0] remainder,
    input wire [16:0] error_acc,
    input wire direction_up,
    input wire [3:0] stored_code,
    output reg [124:0] prepared
);
    reg [4:0] k;
    reg [16:0] duration, work_remaining, work_base, work_error;
    reg [15:0] work_remainder;
    reg work_up;
    reg [22:0] target_pitch, work_pitch, delta;
    reg [17:0] error_sum, increment;
    reg [23:0] moved;
    reg [6:0] target_next;reg [3:0] code_next;
    always @* begin
        target_pitch={note_target,16'd0};
        target_next=stored_target;
        work_pitch=current_pitch;
        work_remaining=remaining;
        work_base=base_step;
        work_remainder=remainder;
        work_error=error_acc;
        work_up=direction_up;
        code_next=stored_code;
        k=0;duration=0;delta=0;error_sum=0;increment=0;moved=0;
        if (new_owner) begin
            target_next=note_target;
            work_pitch=target_pitch;
            work_remaining=0;work_base=0;work_remainder=0;work_error=0;
            work_up=1;
            code_next=0;
        end else if (glide_code==0 && (note_target!=stored_target || remaining!=0)) begin
            target_next=note_target;
            work_pitch=target_pitch;
            work_remaining=0;work_base=0;work_remainder=0;work_error=0;
            work_up=1;
            code_next=0;
        end else if (note_target!=stored_target) begin
            target_next=note_target;
            k=(glide_code>11)?5'd16:{1'b0,glide_code}+5'd5;
            duration=17'd1<<k;
            work_up=(target_pitch>=current_pitch);
            delta=work_up?(target_pitch-current_pitch):(current_pitch-target_pitch);
            work_base=delta>>k;
            work_remainder=delta & (duration-1'b1);
            work_error=0;
            work_remaining=duration;
            code_next=(glide_code>11)?4'd11:glide_code;
        end
        prepared={target_pitch,target_next,work_pitch,work_remaining,work_base,work_remainder,work_error,work_up,code_next};
    end
endmodule

module glide_pitch_advance (
    input wire [124:0] prepared,
    output reg [22:0] pitch_next,
    output reg [6:0] target_next,
    output reg [16:0] remaining_next,
    output reg [16:0] base_next,
    output reg [15:0] remainder_next,
    output reg [16:0] error_next,
    output reg direction_next,
    output reg [3:0] code_next,
    output wire [31:0] phase_step
);
    reg [4:0] k;
    reg [16:0] duration, work_remaining, work_base, work_error;
    reg [15:0] work_remainder;
    reg work_up;
    reg [22:0] target_pitch, work_pitch, delta;
    reg [17:0] error_sum, increment;
    reg [23:0] moved,move_addend;
    reg arithmetic_carry;
    reg [6:0] lower_note, upper_note;
    wire [31:0] lower_step, upper_step;
    wire [31:0] step_delta=upper_step-lower_step;
    wire [47:0] fraction_product=step_delta*pitch_next[15:0];
    wire [48:0] interpolated={17'd0,lower_step}+
        (({1'b0,fraction_product}+49'd32768)>>16);
    assign phase_step=interpolated[31:0];
    phase_step_rom u_lower(.note_code(lower_note),.phase_step(lower_step));
    phase_step_rom u_upper(.note_code(upper_note),.phase_step(upper_step));

    always @* begin
        {target_pitch,target_next,work_pitch,work_remaining,work_base,work_remainder,work_error,work_up,code_next}=prepared;
        k=0;duration=0;delta=0;error_sum=0;increment=0;moved=0;move_addend=0;arithmetic_carry=0;
        if (work_remaining!=0) begin
            k={1'b0,code_next}+5'd5;
            duration=17'd1<<k;
            error_sum={1'b0,work_error}+{2'b0,work_remainder};
            increment={1'b0,work_base};
            if (error_sum>=duration) begin
                increment=increment+1'b1;
                work_error=error_sum-duration;
            end else work_error=error_sum[16:0];
            if (work_remaining==1) begin
                work_pitch=target_pitch;
                work_remaining=0;work_error=0;
            end else begin
                // One add/subtract carry chain. The remainder carry feeds
                // carry-in instead of first incrementing the base in a
                // separate dependent adder. All24 bits, including underflow
                // behavior for abnormal states, match the old operation.
                arithmetic_carry=(error_sum>=duration);
                move_addend=work_up?{7'd0,work_base}:~{7'd0,work_base};
                moved={1'b0,work_pitch}+move_addend+24'(work_up?arithmetic_carry:!arithmetic_carry);
                if ((work_up && moved>={1'b0,target_pitch}) ||
                    (!work_up && moved<={1'b0,target_pitch})) begin
                    work_pitch=target_pitch;work_remaining=0;work_error=0;
                end else begin
                    work_pitch=moved[22:0];
                    work_remaining=work_remaining-1'b1;
                end
            end
        end
        pitch_next=work_pitch;
        remaining_next=work_remaining;
        base_next=work_base;
        remainder_next=work_remainder;
        error_next=work_error;
        direction_next=work_up;
        lower_note=pitch_next[22:16];
        upper_note=(lower_note==7'd127)?7'd127:lower_note+1'b1;
    end
endmodule
