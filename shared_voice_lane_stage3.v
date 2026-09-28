// Eight independent instance states, one arithmetic issue per system clock.
// The longer timbre pipeline completes all eight jobs before the next 48 kHz tick.
module shared_voice_lane_stage3 #(
    parameter integer ATTACK_MS=10, DECAY_MS=50, SUSTAIN_LEVEL=180,
    parameter integer RELEASE_MS=100, VIBRATO_RATE_HZ=5,
    parameter integer VIBRATO_MAX_PPM=10000
) (
    input wire clk,rst,sample_tick,
    input wire [7:0] slot_valid,slot_gate,slot_trigger,slot_cancel,
    input wire [55:0] slot_notes,
    input wire [63:0] slot_pressures,
    input wire [511:0] slot_ids,
    input wire [127:0] slot_generations,
    input wire [23:0] slot_timbres,
    input wire [7:0] vibrato_depth,
    input wire [3:0] glide_code,
    output reg signed [23:0] lane_sum,
    output reg lane_sum_valid,
    output wire [135:0] envelope_levels,
    output wire [23:0] envelope_states,
    output reg [7:0] done_mask,
    output reg [511:0] done_ids,
    output reg [143:0] voice_samples,
    output reg [31:0] issued_count,completed_count,
    output reg deadline_error
);
    localparam [31:0] LFO_STEP=(64'd4294967296*VIBRATO_RATE_HZ+24000)/48000;
    localparam signed [17:0] MAX_MOD_Q16=
        (64'd65536*VIBRATO_MAX_PPM+500000)/1000000;
    reg [7:0] snap_valid,snap_gate,snap_trigger;
    reg [55:0] snap_notes;
    reg [63:0] snap_pressures;
    reg [511:0] snap_ids;
    reg [127:0] snap_generations;
    reg [23:0] snap_timbres;
    reg [7:0] snap_vibrato;
    reg [3:0] snap_glide;
    reg running;
    reg [3:0] issue_index;
    wire issue=running && issue_index<8;
    wire [2:0] sel=issue_index[2:0];

    reg [63:0] owner_id[0:7];
    reg [15:0] owner_generation[0:7];
    reg [31:0] phase_acc[0:7],lfo_phase[0:7];
    reg [6:0] held_note[0:7];
    reg [7:0] held_pressure[0:7];
    reg [2:0] env_state[0:7],timbre_state[0:7];
    reg [16:0] env_level[0:7],env_quotient[0:7];
    reg [31:0] env_remaining[0:7],env_duration[0:7],
               env_remainder[0:7],env_error[0:7];
    reg [22:0] pitch_q[0:7];
    reg [6:0] pitch_target[0:7];
    reg [16:0] glide_remaining[0:7],glide_base[0:7],glide_error[0:7];
    reg [15:0] glide_remainder[0:7];
    reg glide_up[0:7];
    reg [3:0] glide_duration_code[0:7];
    reg [16:0] pressure_gain[0:7],transient_gain[0:7],body_gain[0:7];

    wire owner_matches=(owner_id[sel]==snap_ids[sel*64 +:64] &&
                        owner_generation[sel]==snap_generations[sel*16 +:16]);
    wire issue_current=slot_valid[sel] && !slot_cancel[sel] &&
        snap_ids[sel*64 +:64]==slot_ids[sel*64 +:64] &&
        snap_generations[sel*16 +:16]==slot_generations[sel*16 +:16];
    wire [2:0] adsr_state=owner_matches?env_state[sel]:3'd0;
    wire [16:0] adsr_level=owner_matches?env_level[sel]:17'd0;
    wire [31:0] adsr_remaining=owner_matches?env_remaining[sel]:0;
    wire [31:0] adsr_duration=owner_matches?env_duration[sel]:1;
    wire [31:0] adsr_remainder=owner_matches?env_remainder[sel]:0;
    wire [31:0] adsr_error=owner_matches?env_error[sel]:0;
    wire [16:0] adsr_quotient=owner_matches?env_quotient[sel]:0;
    wire [31:0] issue_phase=owner_matches?phase_acc[sel]:0;
    wire [31:0] issue_lfo=owner_matches?lfo_phase[sel]:0;
    wire [6:0] issue_held_note=owner_matches?held_note[sel]:0;
    wire [7:0] issue_held_pressure=owner_matches?held_pressure[sel]:0;
    wire [2:0] issue_timbre=owner_matches?timbre_state[sel]:
        snap_timbres[sel*3 +:3];
    wire [2:0] state_next;
    wire [16:0] level_next,quotient_next;
    wire [31:0] remaining_next,duration_next,remainder_next,error_next;
    voice_adsr_step #(.ATTACK_MS(ATTACK_MS),.DECAY_MS(DECAY_MS),
        .SUSTAIN_LEVEL(SUSTAIN_LEVEL),.RELEASE_MS(RELEASE_MS)) u_adsr_math (
        .state(adsr_state),.level(adsr_level),.remaining(adsr_remaining),
        .duration(adsr_duration),.remainder(adsr_remainder),
        .error_acc(adsr_error),.quotient(adsr_quotient),
        .gate(snap_gate[sel]),.retrigger(snap_trigger[sel] && snap_valid[sel]),
        .state_next(state_next),.level_next(level_next),
        .remaining_next(remaining_next),.duration_next(duration_next),
        .remainder_next(remainder_next),.error_next(error_next),
        .quotient_next(quotient_next)
    );
    wire [6:0] effective_note=(state_next==4)?issue_held_note:
        snap_notes[sel*7 +:7];
    wire [22:0] next_pitch;
    wire [6:0] next_target;
    wire [16:0] next_glide_remaining,next_glide_base,next_glide_error;
    wire [15:0] next_glide_remainder;
    wire next_glide_up;
    wire [3:0] next_glide_code;
    wire [31:0] note_step;
    glide_pitch_step u_glide(
        .new_owner(!owner_matches),.note_target(effective_note),
        .glide_code(snap_glide),.current_pitch(pitch_q[sel]),
        .stored_target(pitch_target[sel]),.remaining(glide_remaining[sel]),
        .base_step(glide_base[sel]),.remainder(glide_remainder[sel]),
        .error_acc(glide_error[sel]),.direction_up(glide_up[sel]),
        .stored_code(glide_duration_code[sel]),
        .pitch_next(next_pitch),.target_next(next_target),
        .remaining_next(next_glide_remaining),.base_next(next_glide_base),
        .remainder_next(next_glide_remainder),.error_next(next_glide_error),
        .direction_next(next_glide_up),.code_next(next_glide_code),
        .phase_step(note_step)
    );
    wire [7:0] effective_pressure=(state_next==4)?issue_held_pressure:
        snap_pressures[sel*8 +:8];
    wire [16:0] next_pressure;
    pressure_gain_step u_pressure(
        .new_owner(!owner_matches),.release_hold(state_next==4),
        .pressure(effective_pressure),.current_gain(pressure_gain[sel]),
        .gain_next(next_pressure)
    );
    wire [16:0] old_transient=owner_matches?transient_gain[sel]:17'd65536;
    wire [16:0] old_body=owner_matches?body_gain[sel]:17'd65536;
    wire [16:0] decay_amount=(issue_timbre==3)?
        ((old_transient+17'd1023)>>10):((old_transient+17'd2047)>>11);
    wire [16:0] next_transient=(!owner_matches ||
        (issue_timbre!=1 && issue_timbre!=3))?17'd65536:
        ((old_transient<=decay_amount)?17'd0:old_transient-decay_amount);
    wire [16:0] body_decay=(old_body+17'd2047)>>11;
    wire [16:0] next_body=(!owner_matches || issue_timbre!=3)?17'd65536:
        ((old_body<=body_decay)?17'd0:old_body-body_decay);
    wire [31:0] ep_index_product=next_transient*15'd20000;
    wire [16:0] raw_fm_index=(issue_timbre==1)?
        ep_index_product[31:16]:(issue_timbre==4)?17'd10000:17'd0;
    // Above MIDI 108, taper FM sidebands continuously; by MIDI 120 the
    // carrier is pure sine, avoiding severe high-note sideband aliasing.
    wire [16:0] fm_taper=(next_pitch<=23'd7077888)?17'd65536:
        (next_pitch>=23'd7864320)?17'd0:
        ((23'd7864320-next_pitch)/12);
    wire [33:0] tapered_index=raw_fm_index*fm_taper;
    wire [16:0] issue_fm_index=tapered_index>>16;

    wire signed [15:0] lfo_sine,harm1_sine,harm2_sine,harm3_sine,carrier_sine;
    sine_rom u_lfo(.address(issue_lfo[31:24]),.sample(lfo_sine));
    reg [31:0] phase_value[0:11];
    sine_rom u_harm1(.address(phase_value[6][31:24]),.sample(harm1_sine));
    wire [31:0] phase2=phase_value[6]<<1;
    sine_rom u_harm2(.address(phase2[31:24]),.sample(harm2_sine));
    wire [31:0] phase3=phase_value[6]+(phase_value[6]<<1);
    sine_rom u_harm3(.address(phase3[31:24]),.sample(harm3_sine));
    reg [31:0] fm_offset[0:11];
    wire [31:0] carrier_phase=phase_value[8]+fm_offset[8];
    sine_rom u_carrier(.address(carrier_phase[31:24]),.sample(carrier_sine));

    function [16:0] gain;
        input [7:0] value;
        begin gain=(value==255)?17'd65536:{1'b0,value,value};end
    endfunction
    function [16:0] scale_const;
        input [16:0] value,coefficient;
        reg [33:0] product;
        begin product=value*coefficient;scale_const=product>>16;end
    endfunction
    function signed [17:0] round_mod;
        input signed [51:0] value;
        reg signed [52:0] wide;
        begin
            wide={value[51],value};
            if (wide<0) round_mod=-(((-wide)+53'sd1073741824) >>> 31);
            else round_mod=(wide+53'sd1073741824) >>> 31;
        end
    endfunction
    function signed [34:0] round_delta;
        input signed [50:0] value;
        reg signed [51:0] wide;
        begin
            wide={value[50],value};
            if (wide<0) round_delta=-(((-wide)+52'sd32768) >>> 16);
            else round_delta=(wide+52'sd32768) >>> 16;
        end
    endfunction
    function signed [17:0] round_audio;
        input signed [53:0] value;
        reg signed [54:0] wide;
        reg signed [22:0] shifted;
        begin
            wide={value[53],value};
            if (wide<0) shifted=-(((-wide)+55'sd2147483648) >>> 32);
            else shifted=(wide+55'sd2147483648) >>> 32;
            if (shifted>23'sd131071) round_audio=18'sh1ffff;
            else if (shifted< -23'sd131072) round_audio=18'h20000;
            else round_audio=shifted[17:0];
        end
    endfunction
    function signed [17:0] timbre_wave;
        input [2:0] timbre;
        input signed [15:0] h1,h2,h3,carrier;
        input [16:0] transient,body,shape_gain;
        input [31:0] base_step;
        reg signed [63:0] total;
        reg signed [17:0] shaped;
        reg [16:0] w1,w2,w3,amplitude;
        begin
            total=0;w1=0;w2=0;w3=0;amplitude=65536;shaped=0;
            case (timbre)
                3'd1: begin // Electric piano: decaying-index 2:1 FM.
                    amplitude=17'd13107+scale_const(transient,17'd52429);
                    total=$signed(carrier)*$signed({1'b0,amplitude});
                    timbre_wave=total >>> 16;
                end
                3'd2: begin // Organ: fixed drawbar partials.
                    w1=17'd18000;
                    if (base_step<32'h40000000) w2=17'd10000;
                    if (base_step<32'd715827882) w3=17'd4000;
                    total=$signed(h1)*$signed({1'b0,w1})+
                          $signed(h2)*$signed({1'b0,w2})+
                          $signed(h3)*$signed({1'b0,w3});
                    timbre_wave=(total+64'sd16384) >>> 15;
                end
                3'd3: begin // Pluck: fundamental and partials decay together.
                    w1=17'd1000+scale_const(body,17'd24000);
                    if (base_step<32'h40000000)
                        w2=scale_const(transient,17'd5000);
                    if (base_step<32'd715827882)
                        w3=scale_const(transient,17'd2500);
                    total=$signed(h1)*$signed({1'b0,w1})+
                          $signed(h2)*$signed({1'b0,w2})+
                          $signed(h3)*$signed({1'b0,w3});
                    timbre_wave=(total+64'sd16384) >>> 15;
                end
                3'd4: begin // Sustained FM; fade nonlinear shaping at high pitch.
                    if (carrier>16'sd16384)
                        shaped=18'sd16384+(($signed(carrier)-18'sd16384) >>> 1);
                    else if (carrier< -16'sd16384)
                        shaped=-18'sd16384+(($signed(carrier)+18'sd16384) >>> 1);
                    else shaped=carrier;
                    // FM=0 alone is insufficient: clipping also generates harmonics.
                    // Blend to the unshaped carrier using the same pitch taper.
                    total=($signed(shaped)-$signed(carrier))*
                          $signed({1'b0,shape_gain});
                    timbre_wave=$signed(carrier)+(total >>> 16);
                end
                default: timbre_wave=h1; // ID0 sine; same pressure semantics.
            endcase
        end
    endfunction

    reg [11:0] valid_pipe;
    reg [2:0] p_slot[0:11],p_timbre[0:11];
    reg [63:0] p_id[0:11];
    reg [15:0] p_generation[0:11];
    reg [16:0] p_env[0:11],p_pressure[0:11],p_depth[0:11];
    reg [16:0] p_transient[0:11],p_body[0:11],p_fm_index[0:11];
    reg [16:0] p_shape_gain[0:11];
    reg [31:0] p_base_step[0:11],p_base_phase[0:11];
    reg p_restart[0:11],p_gate[0:11];
    reg signed [15:0] p_lfo[0:11],p_h1[0:11],p_h2[0:11],p_h3[0:11];
    reg signed [17:0] p_wave[0:11];
    reg signed [33:0] lfo_depth;
    reg signed [51:0] lfo_max;
    reg signed [17:0] modulation;
    reg signed [50:0] frequency_product;
    reg [31:0] adjusted_step;
    reg signed [35:0] wave_env;
    reg signed [53:0] wave_pressure;
    wire signed [35:0] adjusted_wide=
        $signed({4'b0,p_base_step[4]})+$signed(round_delta(frequency_product));
    wire [31:0] new_phase=p_restart[5]?32'd0:p_base_phase[5]+adjusted_step;
    wire signed [15:0] fm_source=(p_timbre[7]==1)?p_h2[7]:p_h1[7];
    wire signed [33:0] fm_product=fm_source*$signed({1'b0,p_fm_index[7]});
    wire signed [17:0] final_sample=round_audio(wave_pressure);
    wire final_current=(p_id[11]==slot_ids[p_slot[11]*64 +:64] &&
                        p_generation[11]==slot_generations[p_slot[11]*16 +:16] &&
                        slot_valid[p_slot[11]] && !slot_cancel[p_slot[11]]);
    genvar g;
    generate for (g=0;g<8;g=g+1) begin : levels
        wire feedback_current=slot_valid[g] &&
            owner_id[g]==slot_ids[g*64 +:64] &&
            owner_generation[g]==slot_generations[g*16 +:16];
        assign envelope_levels[g*17 +:17]=feedback_current?env_level[g]:17'd0;
        assign envelope_states[g*3 +:3]=feedback_current?env_state[g]:3'd0;
    end endgenerate
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            snap_valid<=0;snap_gate<=0;snap_trigger<=0;snap_notes<=0;
            snap_pressures<=0;snap_ids<=0;snap_generations<=0;
            snap_timbres<=0;snap_vibrato<=0;snap_glide<=0;
            running<=0;issue_index<=0;valid_pipe<=0;
            lane_sum<=0;lane_sum_valid<=0;done_mask<=0;done_ids<=0;
            voice_samples<=0;issued_count<=0;completed_count<=0;deadline_error<=0;
            lfo_depth<=0;lfo_max<=0;modulation<=0;frequency_product<=0;
            adjusted_step<=0;wave_env<=0;wave_pressure<=0;
            for (i=0;i<8;i=i+1) begin
                owner_id[i]<=0;owner_generation[i]<=0;
                phase_acc[i]<=0;lfo_phase[i]<=0;
                held_note[i]<=0;held_pressure[i]<=0;timbre_state[i]<=0;
                env_state[i]<=0;env_level[i]<=0;
                env_remaining[i]<=0;env_duration[i]<=1;
                env_remainder[i]<=0;env_error[i]<=0;env_quotient[i]<=0;
                pitch_q[i]<=0;pitch_target[i]<=0;glide_remaining[i]<=0;
                glide_base[i]<=0;glide_remainder[i]<=0;glide_error[i]<=0;
                glide_up[i]<=0;glide_duration_code[i]<=0;
                pressure_gain[i]<=0;transient_gain[i]<=0;body_gain[i]<=0;
            end
            for (i=0;i<12;i=i+1) begin
                p_slot[i]<=0;p_timbre[i]<=0;p_id[i]<=0;p_generation[i]<=0;
                p_env[i]<=0;p_pressure[i]<=0;p_depth[i]<=0;
                p_transient[i]<=0;p_body[i]<=0;p_fm_index[i]<=0;p_shape_gain[i]<=0;
                p_base_step[i]<=0;p_base_phase[i]<=0;
                p_restart[i]<=0;p_gate[i]<=0;p_lfo[i]<=0;
                p_h1[i]<=0;p_h2[i]<=0;p_h3[i]<=0;p_wave[i]<=0;
                phase_value[i]<=0;fm_offset[i]<=0;
            end
        end else begin
            lane_sum_valid<=0;done_mask<=0;
            valid_pipe<={valid_pipe[10:0],issue};
            for (i=1;i<12;i=i+1) begin
                p_slot[i]<=p_slot[i-1];p_timbre[i]<=p_timbre[i-1];
                p_id[i]<=p_id[i-1];p_generation[i]<=p_generation[i-1];
                p_env[i]<=p_env[i-1];p_pressure[i]<=p_pressure[i-1];
                p_depth[i]<=p_depth[i-1];p_transient[i]<=p_transient[i-1];
                p_body[i]<=p_body[i-1];
                p_fm_index[i]<=p_fm_index[i-1];
                p_shape_gain[i]<=p_shape_gain[i-1];
                p_base_step[i]<=p_base_step[i-1];p_base_phase[i]<=p_base_phase[i-1];
                p_restart[i]<=p_restart[i-1];p_gate[i]<=p_gate[i-1];
                p_lfo[i]<=p_lfo[i-1];p_h1[i]<=p_h1[i-1];
                p_h2[i]<=p_h2[i-1];p_h3[i]<=p_h3[i-1];
                p_wave[i]<=p_wave[i-1];
                if (i!=6) phase_value[i]<=phase_value[i-1];
                if (i!=8) fm_offset[i]<=fm_offset[i-1];
            end
            if (sample_tick) begin
                if (running || valid_pipe!=0) deadline_error<=1;
                snap_valid<=slot_valid;snap_gate<=slot_gate;
                snap_trigger<=slot_trigger;snap_notes<=slot_notes;
                snap_pressures<=slot_pressures;snap_ids<=slot_ids;
                snap_generations<=slot_generations;snap_timbres<=slot_timbres;
                snap_vibrato<=vibrato_depth;snap_glide<=glide_code;
                running<=1;issue_index<=0;lane_sum<=0;
            end
            if (issue) begin
                issue_index<=issue_index+1'b1;
                if (issue_index==7) running<=0;
                issued_count<=issued_count+1'b1;
                p_slot[0]<=sel;p_id[0]<=snap_ids[sel*64 +:64];
                p_generation[0]<=snap_generations[sel*16 +:16];
                p_timbre[0]<=issue_timbre;
                p_env[0]<=level_next;p_pressure[0]<=next_pressure;
                p_depth[0]<=gain(snap_vibrato);
                p_transient[0]<=next_transient;p_body[0]<=next_body;
                p_fm_index[0]<=issue_fm_index;
                p_shape_gain[0]<=fm_taper;
                p_base_step[0]<=note_step;p_base_phase[0]<=issue_phase;
                p_restart[0]<=snap_trigger[sel] && snap_valid[sel];
                p_gate[0]<=snap_gate[sel];p_lfo[0]<=lfo_sine;
                if (issue_current) begin
                    owner_id[sel]<=snap_ids[sel*64 +:64];
                    owner_generation[sel]<=snap_generations[sel*16 +:16];
                    timbre_state[sel]<=issue_timbre;
                    env_state[sel]<=state_next;env_level[sel]<=level_next;
                    env_remaining[sel]<=remaining_next;env_duration[sel]<=duration_next;
                    env_remainder[sel]<=remainder_next;env_error[sel]<=error_next;
                    env_quotient[sel]<=quotient_next;
                    lfo_phase[sel]<=issue_lfo+LFO_STEP;
                    pitch_q[sel]<=next_pitch;pitch_target[sel]<=next_target;
                    glide_remaining[sel]<=next_glide_remaining;
                    glide_base[sel]<=next_glide_base;
                    glide_remainder[sel]<=next_glide_remainder;
                    glide_error[sel]<=next_glide_error;
                    glide_up[sel]<=next_glide_up;
                    glide_duration_code[sel]<=next_glide_code;
                    pressure_gain[sel]<=next_pressure;
                    transient_gain[sel]<=next_transient;
                    body_gain[sel]<=next_body;
                    if (snap_trigger[sel] || snap_gate[sel]) begin
                        held_note[sel]<=snap_notes[sel*7 +:7];
                        held_pressure[sel]<=snap_pressures[sel*8 +:8];
                    end else if (state_next==0) begin
                        held_note[sel]<=0;held_pressure[sel]<=0;
                    end
                end
            end
            if (valid_pipe[0])
                lfo_depth<=$signed(p_lfo[0])*$signed({1'b0,p_depth[0]});
            if (valid_pipe[1]) lfo_max<=lfo_depth*MAX_MOD_Q16;
            if (valid_pipe[2]) modulation<=round_mod(lfo_max);
            if (valid_pipe[3])
                frequency_product<=$signed({1'b0,p_base_step[3]})*modulation;
            if (valid_pipe[4]) adjusted_step<=adjusted_wide[31:0];
            if (valid_pipe[5]) phase_value[6]<=new_phase;
            if (valid_pipe[6]) begin
                p_h1[7]<=harm1_sine;p_h2[7]<=harm2_sine;
                p_h3[7]<=harm3_sine;
            end
            if (valid_pipe[7]) fm_offset[8]<=fm_product[31:0]<<1;
            if (valid_pipe[8])
                p_wave[9]<=timbre_wave(p_timbre[8],p_h1[8],p_h2[8],
                    p_h3[8],carrier_sine,p_transient[8],p_body[8],p_shape_gain[8],p_base_step[8]);
            if (valid_pipe[9])
                wave_env<=$signed(p_wave[9])*$signed({1'b0,p_env[9]});
            if (valid_pipe[10])
                wave_pressure<=wave_env*$signed({1'b0,p_pressure[10]});
            if (valid_pipe[11]) begin
                completed_count<=completed_count+1'b1;
                if (final_current) begin
                    phase_acc[p_slot[11]]<=phase_value[11];
                    voice_samples[p_slot[11]*18 +:18]<=final_sample;
                    lane_sum<=lane_sum+{{6{final_sample[17]}},final_sample};
                    if (!p_gate[11] && env_state[p_slot[11]]==0 &&
                        final_sample==0) begin
                        done_mask[p_slot[11]]<=1;
                        done_ids[p_slot[11]*64 +:64]<=p_id[11];
                    end
                end
                if (p_slot[11]==7) lane_sum_valid<=1;
            end
        end
    end
    // synthesis translate_off
    always @(posedge clk) if (!rst && sample_tick && (running || valid_pipe!=0))
        $fatal(1,"shared_voice_lane_stage3: frame deadline missed");
    // synthesis translate_on
endmodule
