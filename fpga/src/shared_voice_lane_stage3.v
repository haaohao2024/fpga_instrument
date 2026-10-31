// Eight independent instance states, one arithmetic issue per system clock.
// The longer timbre pipeline completes all eight jobs before the next 48 kHz tick.
module shared_voice_lane_stage3 #(
    parameter integer ATTACK_MS=10, DECAY_MS=50, SUSTAIN_LEVEL=180,
    parameter integer RELEASE_MS=100, VIBRATO_RATE_HZ=5,
    parameter integer VIBRATO_MAX_PPM=10000, EXTERNAL_BACKEND=0, COMPACT_RECLAIM=0, DIRECT_BACKEND_SAMPLE=0
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
    output wire completion_valid,completion_accept,
    output wire [2:0] completion_slot,
    output wire signed [17:0] completion_sample,
    output wire [63:0] completion_id,
    output wire [15:0] completion_generation,
    output reg deadline_error,
    output wire backend_take_sample,output wire backend_issue,output wire [2:0] backend_write_slot,
    output wire [193:0] backend_job,
    output wire [2:0] backend_sample_slot,backend_phase_slot,
    input wire signed [17:0] backend_sample,input wire [31:0] backend_phase
) /*synthesis syn_srlstyle="distributed_ram"*/;
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

    reg [2:0] env_state[0:7];
    reg [16:0] env_level[0:7];
    // These 32-bit constants exactly match voice_adsr_step, including its
    // parameter rounding/truncation. State starts within the maximum duration;
    // remaining only decreases, and remainder/error are bounded by duration.
    localparam [31:0] ENV_A=(64'd48000*ATTACK_MS+999)/1000;
    localparam [31:0] ENV_D=(64'd48000*DECAY_MS+999)/1000;
    localparam [31:0] ENV_R=(64'd48000*RELEASE_MS+999)/1000;
    localparam [31:0] ENV_AD_MAX=(ENV_A>ENV_D)?ENV_A:ENV_D;
    localparam [31:0] ENV_MAX0=(ENV_AD_MAX>ENV_R)?ENV_AD_MAX:ENV_R;
    localparam [31:0] ENV_MAX=(ENV_MAX0<1)?32'd1:ENV_MAX0;
    localparam integer ENV_W=$clog2({1'b0,ENV_MAX}+33'd1);

    wire [32-1:0] lfo_phase;
    wire [7-1:0] held_note;
    wire [8-1:0] held_pressure;
    wire [3-1:0] timbre_state;
    wire [17-1:0] env_quotient;
    wire [ENV_W-1:0] env_remaining;
    wire [ENV_W-1:0] env_duration;
    wire [ENV_W-1:0] env_remainder;
    wire [ENV_W-1:0] env_error;
    wire [23-1:0] pitch_q;
    wire [7-1:0] pitch_target;
    wire [17-1:0] glide_remaining;
    wire [17-1:0] glide_base;
    wire [17-1:0] glide_error;
    wire [16-1:0] glide_remainder;
    wire [1-1:0] glide_up;
    wire [4-1:0] glide_duration_code;
    wire [17-1:0] pressure_gain;
    wire [17-1:0] transient_gain;
    wire [17-1:0] body_gain;
    wire [31:0] phase_acc;
    wire owner_matches=(owner_id[sel]==snap_ids[sel*64 +:64] &&
                        owner_generation[sel]==snap_generations[sel*16 +:16]);
    wire issue_current=slot_valid[sel] && !slot_cancel[sel] &&
        snap_ids[sel*64 +:64]==slot_ids[sel*64 +:64] &&
        snap_generations[sel*16 +:16]==slot_generations[sel*16 +:16];
    wire [2:0] adsr_state=owner_matches?env_state[sel]:3'd0;
    wire [16:0] adsr_level=owner_matches?env_level[sel]:17'd0;
    wire [31:0] adsr_remaining=owner_matches?env_remaining:0;
    wire [31:0] adsr_duration=owner_matches?env_duration:1;
    wire [31:0] adsr_remainder=owner_matches?env_remainder:0;
    wire [31:0] adsr_error=owner_matches?env_error:0;
    wire [16:0] adsr_quotient=owner_matches?env_quotient:0;
    wire [31:0] issue_phase=owner_matches?phase_acc:0;
    wire [31:0] issue_lfo=owner_matches?lfo_phase:0;
    wire [6:0] issue_held_note=owner_matches?held_note:0;
    wire [7:0] issue_held_pressure=owner_matches?held_pressure:0;
    wire [2:0] issue_timbre=owner_matches?timbre_state:
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
        .glide_code(snap_glide),.current_pitch(pitch_q),
        .stored_target(pitch_target),.remaining(glide_remaining),
        .base_step(glide_base),.remainder(glide_remainder),
        .error_acc(glide_error),.direction_up(glide_up),
        .stored_code(glide_duration_code),
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
        .pressure(effective_pressure),.current_gain(pressure_gain),
        .gain_next(next_pressure)
    );
    wire [16:0] old_transient=owner_matches?transient_gain:17'd65536;
    wire [16:0] old_body=owner_matches?body_gain:17'd65536;
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
                3'd2,3'd3: begin // Select drawbar/decay coefficients before the shared harmonic MAC.
                    if(timbre==2)begin
                        w1=17'd18000;
                        if(base_step<32'h40000000)w2=17'd10000;
                        if(base_step<32'd715827882)w3=17'd4000;
                    end else begin
                        w1=17'd1000+scale_const(body,17'd24000);
                        if(base_step<32'h40000000)w2=scale_const(transient,17'd5000);
                        if(base_step<32'd715827882)w3=scale_const(transient,17'd2500);
                    end
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
    // Interpolate the phase step in the existing stage 1. Stage 0 retains
    // the exact computed pitch; stages 1..11 still receive the original job
    // on the original edge. The flag preserves reset/idle pipeline contents.
    reg [22:0] issue_pitch;
    reg have_issue_pitch;
    wire [6:0] phase_lower_note=issue_pitch[22:16];
    wire [6:0] phase_upper_note=phase_lower_note==7'd127 ? 7'd127 : phase_lower_note+1'b1;
    wire [31:0] phase_lower_step,phase_upper_step;
    phase_step_rom phase_lower(.note_code(phase_lower_note),.phase_step(phase_lower_step));
    phase_step_rom phase_upper(.note_code(phase_upper_note),.phase_step(phase_upper_step));
    wire [31:0] phase_step_delta=phase_upper_step-phase_lower_step;
    wire [47:0] phase_fraction_product=phase_step_delta*issue_pitch[15:0];
    wire [48:0] phase_interpolated={17'd0,phase_lower_step}+
        (({1'b0,phase_fraction_product}+49'd32768)>>16);
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
    reg signed [17:0] backend_sample_hold;
    always @(posedge clk)begin
        if(rst)backend_sample_hold<=0;
        else if(valid_pipe[10])backend_sample_hold<=backend_sample;
    end
    assign backend_take_sample=valid_pipe[10];
    assign backend_issue=issue;
    assign backend_write_slot=sel;
    assign backend_sample_slot=p_slot[10];
    assign backend_phase_slot=p_slot[11];
    assign backend_job={issue_phase,snap_trigger[sel] && snap_valid[sel],next_pitch,lfo_sine,gain(snap_vibrato),level_next,next_pressure,next_transient,next_body,issue_fm_index,fm_taper,issue_timbre};
    wire signed [17:0] final_sample=EXTERNAL_BACKEND?(DIRECT_BACKEND_SAMPLE?backend_sample:backend_sample_hold):round_audio(wave_pressure);
    wire final_current=(p_id[11]==slot_ids[p_slot[11]*64 +:64] &&
                        p_generation[11]==slot_generations[p_slot[11]*16 +:16] &&
                        slot_valid[p_slot[11]] && !slot_cancel[p_slot[11]]);
    // Passive pre-edge view of the original writeback transaction. No new state.
    assign completion_valid=valid_pipe[11];
    assign completion_accept=final_current;
    assign completion_slot=p_slot[11];
    assign completion_sample=final_sample;
    assign completion_id=p_id[11];
    assign completion_generation=p_generation[11];

    // Per-voice private context: exactly the original issue edge and read
    // value, with a small reset-valid bitmap instead of a resettable wide bank.
    localparam integer CONTEXT_WIDTH=32+7+8+3+17+ENV_W+ENV_W+ENV_W+ENV_W+23+7+17+17+17+16+1+4+17+17+17;

    wire [CONTEXT_WIDTH-1:0] context_stored;
    wire [31:0] phase_stored;
    reg [7:0] context_initialized,phase_initialized;
    wire context_write=!rst && issue && issue_current;
    wire phase_write=!rst && valid_pipe[11] && final_current;
    assign {lfo_phase,held_note,held_pressure,timbre_state,env_quotient,env_remaining,env_duration,env_remainder,env_error,pitch_q,pitch_target,glide_remaining,glide_base,glide_error,glide_remainder,glide_up,glide_duration_code,pressure_gain,transient_gain,body_gain}=context_initialized[sel]?context_stored:{32'(0),7'(0),8'(0),3'(0),17'(0),ENV_W'(0),ENV_W'(1),ENV_W'(0),ENV_W'(0),23'(0),7'(0),17'(0),17'(0),17'(0),16'(0),1'(0),4'(0),17'(0),17'(0),17'(0)};
    assign phase_acc=phase_initialized[sel]?phase_stored:32'd0;
    s3_private_context_store #(.WIDTH(CONTEXT_WIDTH)) context_memory(
        .clk(clk),.write_enable(context_write),.write_slot(sel),.read_slot(sel),
        .write_value({32'(issue_lfo+LFO_STEP),7'((snap_trigger[sel]||snap_gate[sel])?snap_notes[sel*7+:7]:(state_next==0?7'd0:held_note)),8'((snap_trigger[sel]||snap_gate[sel])?snap_pressures[sel*8+:8]:(state_next==0?8'd0:held_pressure)),3'(issue_timbre),17'(quotient_next),ENV_W'(remaining_next),ENV_W'(duration_next),ENV_W'(remainder_next),ENV_W'(error_next),23'(next_pitch),7'(next_target),17'(next_glide_remaining),17'(next_glide_base),17'(next_glide_error),16'(next_glide_remainder),1'(next_glide_up),4'(next_glide_code),17'(next_pressure),17'(next_transient),17'(next_body)}),.read_value(context_stored));
    s3_private_context_store #(.WIDTH(32)) phase_memory(
        .clk(clk),.write_enable(phase_write),.write_slot(p_slot[11]),.read_slot(sel),
        .write_value(EXTERNAL_BACKEND?backend_phase:phase_value[11]),.read_value(phase_stored));
    always @(posedge clk)begin
        if(rst)begin context_initialized<=0;phase_initialized<=0;end
        else begin
            if(context_write)context_initialized[sel]<=1;
            if(phase_write)phase_initialized[p_slot[11]]<=1;
        end
    end
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
            running<=0;issue_index<=0;valid_pipe<=0;issue_pitch<=0;have_issue_pitch<=0;
            lane_sum<=0;lane_sum_valid<=0;done_mask<=0;done_ids<=0;
            voice_samples<=0;issued_count<=0;completed_count<=0;deadline_error<=0;
            lfo_depth<=0;lfo_max<=0;modulation<=0;frequency_product<=0;
            adjusted_step<=0;wave_env<=0;wave_pressure<=0;
            for (i=0;i<8;i=i+1) begin
                owner_id[i]<=0;owner_generation[i]<=0;

                env_state[i]<=0;env_level[i]<=0;

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
                p_base_step[i]<=i==1?(have_issue_pitch?phase_interpolated[31:0]:32'd0):p_base_step[i-1];p_base_phase[i]<=p_base_phase[i-1];
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
                issue_pitch<=next_pitch;have_issue_pitch<=1;
                p_restart[0]<=snap_trigger[sel] && snap_valid[sel];
                p_gate[0]<=snap_gate[sel];p_lfo[0]<=lfo_sine;
                if (issue_current) begin
                    owner_id[sel]<=snap_ids[sel*64 +:64];
                    owner_generation[sel]<=snap_generations[sel*16 +:16];
                    
                    env_state[sel]<=state_next;env_level[sel]<=level_next;

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
                    
                    voice_samples[p_slot[11]*18 +:18]<=final_sample;
                    lane_sum<=lane_sum+{{6{final_sample[17]}},final_sample};
                    if (!p_gate[11] && env_state[p_slot[11]]==0 &&
                        final_sample==0) begin
                        done_mask[p_slot[11]]<=1;
                        if(COMPACT_RECLAIM)done_ids<={8{p_id[11]}};
                        else done_ids[p_slot[11]*64 +:64]<=p_id[11];
                    end
                end
                if (p_slot[11]==7) lane_sum_valid<=1;
            end
        end
    end
    // synthesis translate_off
    always @(posedge clk)if(!rst && issue && issue_current)begin
        if(remaining_next>ENV_MAX || duration_next>ENV_MAX || remainder_next>ENV_MAX || error_next>ENV_MAX)
            $fatal(1,"S3_ENV_STORAGE_BOUND");
    end
    always @(posedge clk)if(!rst)begin
        if($isunknown(done_mask))$fatal(1,"S3_RECLAIM_MASK_XZ");
        if(!$onehot0(done_mask))$fatal(1,"S3_RECLAIM_MULTI");
    end
    always @(posedge clk) if (!rst && sample_tick && (running || valid_pipe!=0))
        $fatal(1,"shared_voice_lane_stage3: frame deadline missed");
    // synthesis translate_on
endmodule

// One asynchronous read, one synchronous write. The unused upper eight words
// are unreachable. Caller-owned initialization bits preserve reset values.
module s3_private_context_store #(parameter integer WIDTH=32)(
 input wire clk,write_enable,input wire [2:0] write_slot,read_slot,
 input wire [WIDTH-1:0] write_value,output wire [WIDTH-1:0] read_value);
 localparam integer PADDED=((WIDTH+3)/4)*4;
 wire [PADDED-1:0] padded_write={{(PADDED-WIDTH){1'b0}},write_value};
 wire [PADDED-1:0] padded_read;
 generate for(genvar n=0;n<PADDED/4;n=n+1)begin: nibble
  RAM16SDP4 memory(.CLK(clk),.WRE(write_enable),.WAD({1'b0,write_slot}),
   .RAD({1'b0,read_slot}),.DI(padded_write[n*4+:4]),.DO(padded_read[n*4+:4]));
 end endgenerate
 assign read_value=padded_read[WIDTH-1:0];
endmodule

// Two compute engines serve four independent context banks.
// Fixed eight-job Lane bursts avoid a general result-bank crossbar.
// All 32 oscillator states and original update/writeback edges are retained.
module r8_voice_backend #(parameter integer DERIVE_FM=0) (input wire clk,rst,in_valid,input wire [4:0] in_tag,
 input wire [193:0] job_in,output wire out_valid,output wire [4:0] out_tag,
 output wire signed [17:0] out_sample,output wire [31:0] out_phase);
 localparam signed [17:0] MAX_MOD_Q16=(64'd65536*10000+500000)/1000000;
 reg [2:0] valid;reg [4:0] tag[0:2];reg [193:0] job[0:2];reg [31:0] phase[0:2];
 reg [31:0] base_step,base_step1;reg signed [17:0] modulation,wave;
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
                3'd2,3'd3: begin // Select drawbar/decay coefficients before the shared harmonic MAC.
                    if(timbre==2)begin
                        w1=17'd18000;
                        if(base_step<32'h40000000)w2=17'd10000;
                        if(base_step<32'd715827882)w3=17'd4000;
                    end else begin
                        w1=17'd1000+scale_const(body,17'd24000);
                        if(base_step<32'h40000000)w2=scale_const(transient,17'd5000);
                        if(base_step<32'd715827882)w3=scale_const(transient,17'd2500);
                    end
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
 wire [6:0] lower_note=job_in[138+:23]>>16;
 wire [6:0] upper_note=lower_note==127?7'd127:lower_note+1'b1;
 wire [31:0] lower_step,upper_step;
 phase_step_rom lo(.note_code(lower_note),.phase_step(lower_step));
 phase_step_rom hi(.note_code(upper_note),.phase_step(upper_step));
 wire [31:0] step_delta=upper_step-lower_step;
 wire [47:0] fraction_product=step_delta*job_in[138+:16];
 wire [48:0] interpolated={17'd0,lower_step}+(({1'b0,fraction_product}+49'd32768)>>16);
 wire signed [33:0] lfo_depth=$signed(job_in[122+:16])*$signed({1'b0,job_in[105+:17]});
 wire signed [51:0] lfo_max=lfo_depth*MAX_MOD_Q16;
 wire signed [50:0] frequency_product=$signed({1'b0,base_step})*modulation;
 wire signed [35:0] adjusted_wide=$signed({4'b0,base_step})+$signed(round_delta(frequency_product));
 wire [31:0] adjusted_step=adjusted_wide[31:0];
 wire signed [15:0] sine1,sine2,sine3,carrier;
 wire [31:0] phase2=phase[1]<<1,phase3=phase[1]+(phase[1]<<1);
 sine_rom s1(.address(phase[1][31:24]),.sample(sine1));
 sine_rom s2(.address(phase2[31:24]),.sample(sine2));
 sine_rom s3(.address(phase3[31:24]),.sample(sine3));
 wire signed [15:0] fm_source=job[1][0+:3]==1?sine2:sine1;
 wire signed [33:0] fm_product=fm_source*$signed({1'b0,job[1][20+:17]});
 wire [31:0] fm_offset=fm_product[31:0]<<1;
 wire [31:0] carrier_phase=phase[1]+fm_offset;
 sine_rom sc(.address(carrier_phase[31:24]),.sample(carrier));
 wire signed [35:0] wave_env=$signed(wave)*$signed({1'b0,job[2][88+:17]});
 wire signed [53:0] wave_pressure=wave_env*$signed({1'b0,job[2][71+:17]});
 assign out_valid=valid[2];assign out_tag=tag[2];
 assign out_sample=round_audio(wave_pressure);assign out_phase=phase[2];
 // FM shaping is derived in the existing first two engine stages.
 // The four Lane frontends and their delayed-job memories carry operands
 // already needed elsewhere; no additional issue or completion cycle.
 wire [22:0] fm_pitch=job_in[138+:23];
 wire [16:0] engine_taper=(fm_pitch<=23'd7077888)?17'd65536:
     (fm_pitch>=23'd7864320)?17'd0:((23'd7864320-fm_pitch)/12);
 wire [31:0] engine_ep_product=job[0][54+:17]*15'd20000;
 wire [16:0] engine_raw_index=job[0][0+:3]==1?engine_ep_product[31:16]:
     job[0][0+:3]==4?17'd10000:17'd0;
 wire [33:0] engine_index_product=engine_raw_index*job[0][3+:17];
 integer q;
 always @(posedge clk)begin
  if(rst)begin
   valid<=0;modulation<=0;wave<=0;base_step<=0;base_step1<=0;
   for(q=0;q<3;q=q+1)begin tag[q]<=0;job[q]<=0;phase[q]<=0;end
  end else begin
   valid<={valid[1:0],in_valid};
   for(q=1;q<3;q=q+1)begin tag[q]<=tag[q-1];job[q]<=job[q-1];phase[q]<=phase[q-1];end
   if(in_valid)begin tag[0]<=in_tag;job[0]<=job_in;base_step<=interpolated[31:0];modulation<=round_mod(lfo_max);end
   if(DERIVE_FM)begin
    if(in_valid)job[0][3+:17]<=engine_taper;
    job[1][20+:17]<=engine_index_product>>16;
   end
   if(valid[0])base_step1<=base_step;
   if(valid[0])phase[1]<=job[0][161+:1]?32'd0:job[0][162+:32]+adjusted_step;
   if(valid[1])wave<=timbre_wave(job[1][0+:3],sine1,sine2,sine3,carrier,
     job[1][54+:17],job[1][37+:17],job[1][3+:17],base_step1);
  end
 end
endmodule

// Eight independent instance states, one arithmetic issue per system clock.
// The longer timbre pipeline completes all eight jobs before the next 48 kHz tick.
module shared_voice_lane_owner_directory #(
    parameter integer ATTACK_MS=10, DECAY_MS=50, SUSTAIN_LEVEL=180,
    parameter integer RELEASE_MS=100, VIBRATO_RATE_HZ=5,
    parameter integer VIBRATO_MAX_PPM=10000, EXTERNAL_BACKEND=0, COMPACT_RECLAIM=0, DIRECT_BACKEND_SAMPLE=0, COMPLETION_LAG=0
) (
    input wire clk,rst,sample_tick,
    input wire owner_allocate,owner_publish,
    input wire [2:0] owner_allocate_slot,
    input wire [63:0] owner_allocate_id,
    input wire [15:0] owner_allocate_generation,
    input wire [7:0] working_public_equal,
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
    output wire completion_valid,completion_accept,
    output wire [2:0] completion_slot,
    output wire signed [17:0] completion_sample,
    output wire [63:0] completion_id,
    output wire [15:0] completion_generation,
    output reg deadline_error,
    output wire backend_take_sample,output wire backend_issue,output wire [2:0] backend_write_slot,
    output wire [193:0] backend_job,
    output wire [2:0] backend_sample_slot,backend_phase_slot,
    input wire signed [17:0] backend_sample,input wire [31:0] backend_phase
) /*synthesis syn_srlstyle="distributed_ram"*/;
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

    // Full identity is retained in two query mirrors: current issue and
    // allocator apply. All eight public comparisons become exact predicates
    // maintained at the same producer edges, including aborted work banks.
    reg [7:0] owner_initialized,owner_public_equal,owner_work_equal;
    wire context_write;
    reg [7:0] context_initialized,phase_initialized;
    wire [79:0] owner_allocate_word;
    // The frame snapshot freezes all eight full identities on its original
    // edge. Track exact owner/snapshot equality at snapshot and context-write
    // edges, removing one complete 8x80 issue-query RAM mirror per Lane.
    reg [7:0] owner_snapshot_equal;
    always @(posedge clk)begin
        if(rst)owner_snapshot_equal<=8'hff;
        else begin
            if(context_write)owner_snapshot_equal[sel]<=1;
            if(sample_tick)owner_snapshot_equal<=owner_public_equal;
        end
    end
    // synthesis translate_off
    wire [79:0] owner_issue_word;
    wire [79:0] current_owner_word=owner_initialized[sel]?owner_issue_word:80'd0;
    // synthesis translate_on
    wire [79:0] allocating_owner_word=owner_initialized[owner_allocate_slot]?owner_allocate_word:80'd0;
    wire [79:0] captured_owner_word={snap_generations[sel*16+:16],snap_ids[sel*64+:64]};
    wire [79:0] allocated_owner_word={owner_allocate_generation,owner_allocate_id};
    wire allocation_matches_old_owner=allocated_owner_word==allocating_owner_word;
    wire allocation_matches_issued_owner=allocated_owner_word==captured_owner_word;
    s3_private_context_store #(.WIDTH(80)) owner_allocate_memory(
        .clk(clk),.write_enable(context_write),.write_slot(sel),.read_slot(owner_allocate_slot),
        .write_value(captured_owner_word),.read_value(owner_allocate_word));
    always @(posedge clk)begin
        if(rst)begin owner_initialized<=0;owner_public_equal<=8'hff;owner_work_equal<=8'hff;end
        else begin
            if(owner_allocate)owner_work_equal[owner_allocate_slot]<=allocation_matches_old_owner;
            if(owner_publish)owner_public_equal<=owner_work_equal;
            if(context_write)begin
                owner_initialized[sel]<=1;owner_public_equal[sel]<=1;
                // Allocation and issue may collide before publication.
                // New owner identity then compares against the identity
                // actually captured by this SAME context write edge.
                owner_work_equal[sel]<=owner_allocate&&owner_allocate_slot==sel?
                    allocation_matches_issued_owner:working_public_equal[sel];
            end
        end
    end
    // Independent complete identity state is retained only in simulation.
    // synthesis translate_off
    reg [63:0] owner_id[0:7];reg [15:0] owner_generation[0:7];
    assign owner_issue_word={owner_generation[sel],owner_id[sel]};
    reg [79:0] work_identity[0:7];
    always @(posedge clk)begin
        if(rst)for(integer s=0;s<8;s=s+1)begin owner_id[s]<=0;owner_generation[s]<=0;work_identity[s]<=0;end
        else begin
            if(owner_allocate)work_identity[owner_allocate_slot]<=allocated_owner_word;
            if(context_write)begin owner_id[sel]<=captured_owner_word[63:0];owner_generation[sel]<=captured_owner_word[79:64];end
        end
    end
    always @(posedge clk)if(!rst)begin
        if($isunknown({owner_allocate,owner_publish,working_public_equal}))$fatal(1,"AUDIO_OWNER_PRODUCER_XZ");
        if(owner_allocate&&owner_publish)$fatal(1,"AUDIO_OWNER_APPLY_PUBLISH_OVERLAP");
        for(integer s=0;s<8;s=s+1)begin
            if(owner_public_equal[s]!==({owner_generation[s],owner_id[s]}=={slot_generations[s*16+:16],slot_ids[s*64+:64]}))
                $fatal(1,"AUDIO_OWNER_PUBLIC_PREDICATE slot=%0d",s);
            if(owner_snapshot_equal[s]!==({owner_generation[s],owner_id[s]}=={snap_generations[s*16+:16],snap_ids[s*64+:64]}))
                $fatal(1,"AUDIO_SNAPSHOT_OWNER_PREDICATE slot=%0d",s);
            if(owner_work_equal[s]!==({owner_generation[s],owner_id[s]}==work_identity[s]))
                $fatal(1,"AUDIO_OWNER_WORK_PREDICATE slot=%0d",s);
        end
        if(current_owner_word!=={owner_generation[sel],owner_id[sel]})$fatal(1,"AUDIO_OWNER_ISSUE_STORAGE");
        if(allocating_owner_word!=={owner_generation[owner_allocate_slot],owner_id[owner_allocate_slot]})$fatal(1,"AUDIO_OWNER_APPLY_STORAGE");
    end
    // synthesis translate_on

    reg [2:0] env_state[0:7];
    reg [16:0] env_level[0:7];
    // These 32-bit constants exactly match voice_adsr_step, including its
    // parameter rounding/truncation. State starts within the maximum duration;
    // remaining only decreases, and remainder/error are bounded by duration.
    localparam [31:0] ENV_A=(64'd48000*ATTACK_MS+999)/1000;
    localparam [31:0] ENV_D=(64'd48000*DECAY_MS+999)/1000;
    localparam [31:0] ENV_R=(64'd48000*RELEASE_MS+999)/1000;
    localparam [31:0] ENV_AD_MAX=(ENV_A>ENV_D)?ENV_A:ENV_D;
    localparam [31:0] ENV_MAX0=(ENV_AD_MAX>ENV_R)?ENV_AD_MAX:ENV_R;
    localparam [31:0] ENV_MAX=(ENV_MAX0<1)?32'd1:ENV_MAX0;
    localparam integer ENV_W=$clog2({1'b0,ENV_MAX}+33'd1);

    wire [32-1:0] lfo_phase;
    wire [7-1:0] held_note;
    wire [8-1:0] held_pressure;
    wire [3-1:0] timbre_state;
    wire [17-1:0] env_quotient;
    wire [ENV_W-1:0] env_remaining;
    wire [ENV_W-1:0] env_duration;
    wire [ENV_W-1:0] env_remainder;
    wire [ENV_W-1:0] env_error;
    wire [23-1:0] pitch_q;
    wire [7-1:0] pitch_target;
    wire [17-1:0] glide_remaining;
    wire [17-1:0] glide_base;
    wire [17-1:0] glide_error;
    wire [16-1:0] glide_remainder;
    wire [1-1:0] glide_up;
    wire [4-1:0] glide_duration_code;
    wire [17-1:0] pressure_gain;
    wire [17-1:0] transient_gain;
    wire [17-1:0] body_gain;
    wire [31:0] phase_acc;
    wire owner_matches=owner_snapshot_equal[sel];
    wire issue_current=slot_valid[sel] && !slot_cancel[sel] &&
        snap_ids[sel*64 +:64]==slot_ids[sel*64 +:64] &&
        snap_generations[sel*16 +:16]==slot_generations[sel*16 +:16];
    // C0 prepares slot0 from the same pre-edge public snapshot. C1..C7
    // prepare slots1..7 from the frozen frame; original issue remains C1..C8.
    // A different slot's context write cannot change this preparation input.
    wire adsr_prepare=sample_tick || (issue && issue_index<7);
    wire [2:0] adsr_prepare_slot=sample_tick?3'd0:sel+3'd1;
    wire adsr_prepare_owner=sample_tick?owner_public_equal[adsr_prepare_slot]:owner_snapshot_equal[adsr_prepare_slot];
    wire adsr_prepare_gate=sample_tick?slot_gate[adsr_prepare_slot]:snap_gate[adsr_prepare_slot];
    wire adsr_prepare_trigger=sample_tick?(slot_trigger[adsr_prepare_slot] && slot_valid[adsr_prepare_slot]):
        (snap_trigger[adsr_prepare_slot] && snap_valid[adsr_prepare_slot]);
    localparam integer ENV_CONTEXT_WIDTH=17+4*ENV_W;
    wire [ENV_CONTEXT_WIDTH-1:0] env_context_stored;
    assign {env_quotient,env_remaining,env_duration,env_remainder,env_error}=
        context_initialized[adsr_prepare_slot]?env_context_stored:
        {17'd0,ENV_W'(0),ENV_W'(1),ENV_W'(0),ENV_W'(0)};
    wire [2:0] adsr_state=adsr_prepare_owner?env_state[adsr_prepare_slot]:3'd0;
    wire [16:0] adsr_level=adsr_prepare_owner?env_level[adsr_prepare_slot]:17'd0;
    wire [31:0] adsr_remaining=adsr_prepare_owner?env_remaining:0;
    wire [31:0] adsr_duration=adsr_prepare_owner?env_duration:1;
    wire [31:0] adsr_remainder=adsr_prepare_owner?env_remainder:0;
    wire [31:0] adsr_error=adsr_prepare_owner?env_error:0;
    wire [16:0] adsr_quotient=adsr_prepare_owner?env_quotient:0;
    wire [31:0] issue_phase=owner_matches?phase_acc:0;
    wire [31:0] issue_lfo=owner_matches?lfo_phase:0;
    wire [6:0] issue_held_note=owner_matches?held_note:0;
    wire [7:0] issue_held_pressure=owner_matches?held_pressure:0;
    wire [2:0] issue_timbre=owner_matches?timbre_state:
        snap_timbres[sel*3 +:3];
    wire [2:0] state_next;
    wire [16:0] level_next,quotient_next;
    wire [31:0] remaining_next,duration_next,remainder_next,error_next;
    wire [2:0] prepared_state_next;
    wire [16:0] prepared_level_next,prepared_quotient_next;
    wire [31:0] prepared_remaining_next,prepared_duration_next,prepared_remainder_next,prepared_error_next;
    voice_adsr_step #(.ATTACK_MS(ATTACK_MS),.DECAY_MS(DECAY_MS),
        .SUSTAIN_LEVEL(SUSTAIN_LEVEL),.RELEASE_MS(RELEASE_MS)) u_adsr_prepare_math (
        .state(adsr_state),.level(adsr_level),.remaining(adsr_remaining),
        .duration(adsr_duration),.remainder(adsr_remainder),
        .error_acc(adsr_error),.quotient(adsr_quotient),
        .gate(adsr_prepare_gate),.retrigger(adsr_prepare_trigger),
        .state_next(prepared_state_next),.level_next(prepared_level_next),
        .remaining_next(prepared_remaining_next),.duration_next(prepared_duration_next),
        .remainder_next(prepared_remainder_next),.error_next(prepared_error_next),
        .quotient_next(prepared_quotient_next)
    );

    localparam integer ENV_RESULT_WIDTH=3+17+17+4*ENV_W;
    reg env_result_bank,env_result_valid;reg [2:0] env_result_slot;
    wire [ENV_RESULT_WIDTH-1:0] env_result_word;
    wire [ENV_W-1:0] result_remaining,result_duration,result_remainder,result_error;
    assign {state_next,level_next,quotient_next,result_remaining,result_duration,result_remainder,result_error}=env_result_word;
    assign remaining_next={{(32-ENV_W){1'b0}},result_remaining};
    assign duration_next={{(32-ENV_W){1'b0}},result_duration};
    assign remainder_next={{(32-ENV_W){1'b0}},result_remainder};
    assign error_next={{(32-ENV_W){1'b0}},result_error};
    // Two alternating RAM words hold the one-cycle arithmetic boundary;
    // this avoids adding four wide FF banks to the nearly-full device.
    s3_private_context_store #(.WIDTH(ENV_RESULT_WIDTH)) envelope_results(
        .clk(clk),.write_enable(!rst && adsr_prepare),.write_slot({2'd0,env_result_bank}),
        .read_slot({2'd0,~env_result_bank}),
        .write_value({prepared_state_next,prepared_level_next,prepared_quotient_next,
            ENV_W'(prepared_remaining_next),ENV_W'(prepared_duration_next),ENV_W'(prepared_remainder_next),ENV_W'(prepared_error_next)}),
        .read_value(env_result_word));
    s3_private_context_store #(.WIDTH(ENV_CONTEXT_WIDTH)) envelope_context(
        .clk(clk),.write_enable(context_write),.write_slot(sel),.read_slot(adsr_prepare_slot),
        .write_value({quotient_next,ENV_W'(remaining_next),ENV_W'(duration_next),ENV_W'(remainder_next),ENV_W'(error_next)}),
        .read_value(env_context_stored));
    always @(posedge clk)begin
        if(rst)begin env_result_bank<=0;env_result_valid<=0;env_result_slot<=0;end
        else begin
            env_result_valid<=adsr_prepare;
            if(adsr_prepare)begin env_result_bank<=~env_result_bank;env_result_slot<=adsr_prepare_slot;end
        end
    end
    wire [6:0] effective_note=(state_next==4)?issue_held_note:
        snap_notes[sel*7 +:7];
    wire [22:0] next_pitch;
    wire [6:0] next_target;
    wire [16:0] next_glide_remaining,next_glide_base,next_glide_error;
    wire [15:0] next_glide_remainder;
    wire next_glide_up;
    wire [3:0] next_glide_code;
    wire [31:0] note_step;
    wire [6:0] prepared_held_note;
    wire [108:0] pitch_context_stored;
    assign {prepared_held_note,pitch_q,pitch_target,glide_remaining,glide_base,glide_error,glide_remainder,glide_up,glide_duration_code}=context_initialized[adsr_prepare_slot]?pitch_context_stored:109'd0;
    wire [6:0] prepared_note=(prepared_state_next==4)?(adsr_prepare_owner?prepared_held_note:7'd0):
        (sample_tick?slot_notes[adsr_prepare_slot*7+:7]:snap_notes[adsr_prepare_slot*7+:7]);
    wire [124:0] glide_prepared_input,glide_prepared_result;
    glide_pitch_prepare glide_prepare(
        .new_owner(!adsr_prepare_owner),.note_target(prepared_note),
        .glide_code(sample_tick?glide_code:snap_glide),.current_pitch(pitch_q),
        .stored_target(pitch_target),.remaining(glide_remaining),.base_step(glide_base),
        .remainder(glide_remainder),.error_acc(glide_error),.direction_up(glide_up),
        .stored_code(glide_duration_code),.prepared(glide_prepared_input));
    s3_private_context_store #(.WIDTH(132)) glide_results(
        .clk(clk),.write_enable(!rst && adsr_prepare),.write_slot({2'd0,env_result_bank}),
        .read_slot({2'd0,~env_result_bank}),.write_value({glide_prepared_input,prepared_held_note}),
        .read_value({glide_prepared_result,held_note}));
    s3_private_context_store #(.WIDTH(109)) pitch_context(
        .clk(clk),.write_enable(context_write),.write_slot(sel),.read_slot(adsr_prepare_slot),
        .write_value({7'((snap_trigger[sel]||snap_gate[sel])?snap_notes[sel*7+:7]:(state_next==0?7'd0:held_note)),23'(next_pitch),7'(next_target),17'(next_glide_remaining),17'(next_glide_base),17'(next_glide_error),16'(next_glide_remainder),1'(next_glide_up),4'(next_glide_code)}),.read_value(pitch_context_stored));
    glide_pitch_advance u_glide(
        .prepared(glide_prepared_result),
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
        .pressure(effective_pressure),.current_gain(pressure_gain),
        .gain_next(next_pressure)
    );
    wire [16:0] old_transient=owner_matches?transient_gain:17'd65536;
    wire [16:0] old_body=owner_matches?body_gain:17'd65536;
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
                3'd2,3'd3: begin // Select drawbar/decay coefficients before the shared harmonic MAC.
                    if(timbre==2)begin
                        w1=17'd18000;
                        if(base_step<32'h40000000)w2=17'd10000;
                        if(base_step<32'd715827882)w3=17'd4000;
                    end else begin
                        w1=17'd1000+scale_const(body,17'd24000);
                        if(base_step<32'h40000000)w2=scale_const(transient,17'd5000);
                        if(base_step<32'd715827882)w3=scale_const(transient,17'd2500);
                    end
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
    // Interpolate the phase step in the existing stage 1. Stage 0 retains
    // the exact computed pitch; stages 1..11 still receive the original job
    // on the original edge. The flag preserves reset/idle pipeline contents.
    reg [22:0] issue_pitch;
    reg have_issue_pitch;
    wire [6:0] phase_lower_note=issue_pitch[22:16];
    wire [6:0] phase_upper_note=phase_lower_note==7'd127 ? 7'd127 : phase_lower_note+1'b1;
    wire [31:0] phase_lower_step,phase_upper_step;
    phase_step_rom phase_lower(.note_code(phase_lower_note),.phase_step(phase_lower_step));
    phase_step_rom phase_upper(.note_code(phase_upper_note),.phase_step(phase_upper_step));
    wire [31:0] phase_step_delta=phase_upper_step-phase_lower_step;
    wire [47:0] phase_fraction_product=phase_step_delta*issue_pitch[15:0];
    wire [48:0] phase_interpolated={17'd0,phase_lower_step}+
        (({1'b0,phase_fraction_product}+49'd32768)>>16);
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
    wire final_current=(p_id[11]==slot_ids[p_slot[11]*64 +:64] &&
                        p_generation[11]==slot_generations[p_slot[11]*16 +:16] &&
                        slot_valid[p_slot[11]] && !slot_cancel[p_slot[11]]);
    wire actual_valid,actual_accept,take_sample;
    wire [2:0] actual_slot,take_slot;
    generate if(COMPLETION_LAG==3)begin: delayed_completion
        reg [2:0] valids,accepts,takes;
        reg [2:0] slots[0:2],take_slots[0:2];
        always @(posedge clk)begin
            if(rst)begin valids<=0;accepts<=0;takes<=0;
                for(integer d=0;d<3;d++)begin slots[d]<=0;take_slots[d]<=0;end
            end else begin
                valids<={valids[1:0],valid_pipe[11]};
                accepts<={accepts[1:0],final_current};
                takes<={takes[1:0],valid_pipe[10]};
                slots[0]<=p_slot[11];take_slots[0]<=p_slot[10];
                for(integer d=1;d<3;d++)begin slots[d]<=slots[d-1];take_slots[d]<=take_slots[d-1];end
            end
        end
        assign actual_valid=valids[2];assign actual_accept=accepts[2];
        assign actual_slot=slots[2];assign take_sample=takes[2];assign take_slot=take_slots[2];
        // synthesis translate_off
        always @(posedge clk)if(!rst && sample_tick && (|valids || |takes))$fatal(1,"AUDIO_DELAY_FRAME_OVERLAP");
        // synthesis translate_on
    end else begin: original_completion
        assign actual_valid=valid_pipe[11];assign actual_accept=final_current;
        assign actual_slot=p_slot[11];assign take_sample=valid_pipe[10];assign take_slot=p_slot[10];
    end endgenerate
    reg signed [17:0] backend_sample_hold;
    always @(posedge clk)begin
        if(rst)backend_sample_hold<=0;
        else if(take_sample)backend_sample_hold<=backend_sample;
    end
    assign backend_take_sample=take_sample;
    assign backend_issue=issue;
    assign backend_write_slot=sel;
    assign backend_sample_slot=take_slot;
    assign backend_phase_slot=actual_slot;
    assign backend_job={issue_phase,snap_trigger[sel] && snap_valid[sel],next_pitch,lfo_sine,gain(snap_vibrato),level_next,next_pressure,next_transient,next_body,(EXTERNAL_BACKEND?17'd0:issue_fm_index),(EXTERNAL_BACKEND?17'd0:fm_taper),issue_timbre};
    wire signed [17:0] final_sample=EXTERNAL_BACKEND?(DIRECT_BACKEND_SAMPLE?backend_sample:backend_sample_hold):round_audio(wave_pressure);
    wire [79:0] completed_identity;
    generate if(COMPLETION_LAG==3)begin: completion_identity_store
        // Store the original full completion identity, then consume it three
        // cycles later. All8 entries have independent slots; a new frame
        // cannot reuse them until every previous response has retired.
        s3_private_context_store #(.WIDTH(80)) identities(
            .clk(clk),.write_enable(!rst && valid_pipe[11]),.write_slot(p_slot[11]),
            .read_slot(actual_slot),.write_value({p_generation[11],p_id[11]}),
            .read_value(completed_identity));
    end else begin: completion_identity_direct
        assign completed_identity={p_generation[11],p_id[11]};
    end endgenerate
    // Passive pre-edge view of the original writeback transaction. No new state.
    assign completion_valid=actual_valid;
    assign completion_accept=actual_accept;
    assign completion_slot=actual_slot;
    assign completion_sample=final_sample;
    assign completion_id=completed_identity[63:0];
    assign completion_generation=completed_identity[79:64];

    // Per-voice private context: exactly the original issue edge and read
    // value, with a small reset-valid bitmap instead of a resettable wide bank.
    localparam integer CONTEXT_WIDTH=32+8+3+17+17+17;

    wire [CONTEXT_WIDTH-1:0] context_stored;
    wire [31:0] phase_stored;
    assign context_write=!rst && issue && issue_current;
    wire phase_write=!rst && actual_valid && actual_accept;
    assign {lfo_phase,held_pressure,timbre_state,pressure_gain,transient_gain,body_gain}=context_initialized[sel]?context_stored:{32'(0),8'(0),3'(0),17'(0),17'(0),17'(0)};
    assign phase_acc=phase_initialized[sel]?phase_stored:32'd0;
    s3_private_context_store #(.WIDTH(CONTEXT_WIDTH)) context_memory(
        .clk(clk),.write_enable(context_write),.write_slot(sel),.read_slot(sel),
        .write_value({32'(issue_lfo+LFO_STEP),8'((snap_trigger[sel]||snap_gate[sel])?snap_pressures[sel*8+:8]:(state_next==0?8'd0:held_pressure)),3'(issue_timbre),17'(next_pressure),17'(next_transient),17'(next_body)}),.read_value(context_stored));
    s3_private_context_store #(.WIDTH(32)) phase_memory(
        .clk(clk),.write_enable(phase_write),.write_slot(actual_slot),.read_slot(sel),
        .write_value(EXTERNAL_BACKEND?backend_phase:phase_value[11]),.read_value(phase_stored));
    always @(posedge clk)begin
        if(rst)begin context_initialized<=0;phase_initialized<=0;end
        else begin
            if(context_write)context_initialized[sel]<=1;
            if(phase_write)phase_initialized[actual_slot]<=1;
        end
    end
    genvar g;
    generate for (g=0;g<8;g=g+1) begin : levels
        wire feedback_current=slot_valid[g] &&
            owner_public_equal[g];
        assign envelope_levels[g*17 +:17]=feedback_current?env_level[g]:17'd0;
        assign envelope_states[g*3 +:3]=feedback_current?env_state[g]:3'd0;
    end endgenerate
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            snap_valid<=0;snap_gate<=0;snap_trigger<=0;snap_notes<=0;
            snap_pressures<=0;snap_ids<=0;snap_generations<=0;
            snap_timbres<=0;snap_vibrato<=0;snap_glide<=0;
            running<=0;issue_index<=0;valid_pipe<=0;issue_pitch<=0;have_issue_pitch<=0;
            lane_sum<=0;lane_sum_valid<=0;done_mask<=0;done_ids<=0;
            voice_samples<=0;issued_count<=0;completed_count<=0;deadline_error<=0;
            lfo_depth<=0;lfo_max<=0;modulation<=0;frequency_product<=0;
            adjusted_step<=0;wave_env<=0;wave_pressure<=0;
            for (i=0;i<8;i=i+1) begin


                env_state[i]<=0;env_level[i]<=0;

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
                p_base_step[i]<=i==1?(have_issue_pitch?phase_interpolated[31:0]:32'd0):p_base_step[i-1];p_base_phase[i]<=p_base_phase[i-1];
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
                issue_pitch<=next_pitch;have_issue_pitch<=1;
                p_restart[0]<=snap_trigger[sel] && snap_valid[sel];
                p_gate[0]<=snap_gate[sel];p_lfo[0]<=lfo_sine;
                if (issue_current) begin

                    
                    env_state[sel]<=state_next;env_level[sel]<=level_next;

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
            // An accepted idle envelope has level zero. Its wave*envelope
            // product is exactly zero, regardless of timbre/pressure. Reclaim
            // therefore retains the original decision edge and full identity.
            if(valid_pipe[11] && final_current && !p_gate[11] && env_state[p_slot[11]]==0 &&
               (COMPLETION_LAG==3 || final_sample==0))begin
                done_mask[p_slot[11]]<=1;
                if(COMPACT_RECLAIM)done_ids<={8{p_id[11]}};
                else done_ids[p_slot[11]*64+:64]<=p_id[11];
            end
            if (actual_valid) begin
                completed_count<=completed_count+1'b1;
                if (actual_accept) begin
                    
                    voice_samples[actual_slot*18 +:18]<=final_sample;
                    lane_sum<=lane_sum+{{6{final_sample[17]}},final_sample};

                end
                if (actual_slot==7) lane_sum_valid<=1;
            end
        end
    end
    // synthesis translate_off
    initial if(COMPLETION_LAG!=0 && COMPLETION_LAG!=3)$fatal(1,"AUDIO_COMPLETION_LAG_PARAMETER");
    always @(posedge clk)if(!rst && valid_pipe[11] && final_current && !p_gate[11] && env_state[p_slot[11]]==0)
        if(env_level[p_slot[11]]!=0 || p_env[11]!=0)$fatal(1,"AUDIO_EARLY_RECLAIM_ZERO_PROOF");
    // Independent old-edge ADSR reference keeps its own history. Never
    // substitute the prepared output for the old-edge arithmetic input.
    reg [ENV_CONTEXT_WIDTH-1:0] oracle_env[0:7];
    wire [16:0] oracle_q;wire [ENV_W-1:0] oracle_rem,oracle_dur,oracle_frac,oracle_err;
    assign {oracle_q,oracle_rem,oracle_dur,oracle_frac,oracle_err}=oracle_env[sel];
    wire [2:0] oracle_state;wire [16:0] oracle_level,oracle_quotient;
    wire [31:0] oracle_remaining,oracle_duration,oracle_remainder,oracle_error;
    voice_adsr_step #(.ATTACK_MS(ATTACK_MS),.DECAY_MS(DECAY_MS),.SUSTAIN_LEVEL(SUSTAIN_LEVEL),.RELEASE_MS(RELEASE_MS)) old_edge_adsr(
        .state(owner_matches?env_state[sel]:3'd0),.level(owner_matches?env_level[sel]:17'd0),
        .remaining(owner_matches?32'(oracle_rem):32'd0),.duration(owner_matches?32'(oracle_dur):32'd1),
        .remainder(owner_matches?32'(oracle_frac):32'd0),.error_acc(owner_matches?32'(oracle_err):32'd0),
        .quotient(owner_matches?oracle_q:17'd0),.gate(snap_gate[sel]),.retrigger(snap_trigger[sel] && snap_valid[sel]),
        .state_next(oracle_state),.level_next(oracle_level),.quotient_next(oracle_quotient),
        .remaining_next(oracle_remaining),.duration_next(oracle_duration),.remainder_next(oracle_remainder),.error_next(oracle_error));
    always @(posedge clk)begin
        if(rst)for(integer s=0;s<8;s++)oracle_env[s]<={17'd0,ENV_W'(0),ENV_W'(1),ENV_W'(0),ENV_W'(0)};
        else begin
            if(adsr_prepare && (prepared_remaining_next>ENV_MAX || prepared_duration_next>ENV_MAX || prepared_remainder_next>ENV_MAX || prepared_error_next>ENV_MAX))
                $fatal(1,"AUDIO_ENV_PREPARED_BOUND");
            if(issue)begin
                if(!env_result_valid || env_result_slot!==sel)$fatal(1,"AUDIO_ENV_PREPARED_BINDING");
                if({state_next,level_next,quotient_next,remaining_next,duration_next,remainder_next,error_next} !==
                   {oracle_state,oracle_level,oracle_quotient,oracle_remaining,oracle_duration,oracle_remainder,oracle_error})
                    $fatal(1,"AUDIO_ENV_OLD_EDGE_EQ slot=%0d",sel);
            end
            if(context_write)oracle_env[sel]<={oracle_quotient,ENV_W'(oracle_remaining),ENV_W'(oracle_duration),ENV_W'(oracle_remainder),ENV_W'(oracle_error)};
        end
    end
    always @(posedge clk)if(!rst && issue && issue_current)begin
        if(remaining_next>ENV_MAX || duration_next>ENV_MAX || remainder_next>ENV_MAX || error_next>ENV_MAX)
            $fatal(1,"S3_ENV_STORAGE_BOUND");
    end
    always @(posedge clk)if(!rst)begin
        if($isunknown(done_mask))$fatal(1,"S3_RECLAIM_MASK_XZ");
        if(!$onehot0(done_mask))$fatal(1,"S3_RECLAIM_MULTI");
    end
    always @(posedge clk) if (!rst && sample_tick && (running || valid_pipe!=0))
        $fatal(1,"shared_voice_lane_stage3: frame deadline missed");
    // synthesis translate_on
endmodule

module r8_voice_backend_six_stage #(parameter integer DERIVE_FM=0) (input wire clk,rst,in_valid,input wire [4:0] in_tag,
 input wire [193:0] job_in,output wire out_valid,output wire [4:0] out_tag,
 output wire signed [17:0] out_sample,output wire [31:0] out_phase);
 localparam signed [17:0] MAX_MOD_Q16=(64'd65536*10000+500000)/1000000;
 reg [5:0] valid;reg [4:0] tag[0:5];reg [193:0] job[0:5];reg [31:0] phase[0:5];
 reg [31:0] base_step,base_step1,base_step2;
 reg [31:0] carrier_phase2;reg signed [15:0] harmonic1,harmonic2,harmonic3;reg signed [17:0] modulation,wave;
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
                3'd2,3'd3: begin // Select drawbar/decay coefficients before the shared harmonic MAC.
                    if(timbre==2)begin
                        w1=17'd18000;
                        if(base_step<32'h40000000)w2=17'd10000;
                        if(base_step<32'd715827882)w3=17'd4000;
                    end else begin
                        w1=17'd1000+scale_const(body,17'd24000);
                        if(base_step<32'h40000000)w2=scale_const(transient,17'd5000);
                        if(base_step<32'd715827882)w3=scale_const(transient,17'd2500);
                    end
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
 wire [6:0] lower_note=job_in[138+:23]>>16;
 wire [6:0] upper_note=lower_note==127?7'd127:lower_note+1'b1;
 wire [31:0] lower_step,upper_step;
 phase_step_rom lo(.note_code(lower_note),.phase_step(lower_step));
 phase_step_rom hi(.note_code(upper_note),.phase_step(upper_step));
 wire [31:0] step_delta=upper_step-lower_step;
 wire [47:0] fraction_product=step_delta*job_in[138+:16];
 wire [48:0] interpolated={17'd0,lower_step}+(({1'b0,fraction_product}+49'd32768)>>16);
 wire signed [33:0] lfo_depth=$signed(job_in[122+:16])*$signed({1'b0,job_in[105+:17]});
 wire signed [51:0] lfo_max=lfo_depth*MAX_MOD_Q16;
 wire signed [50:0] frequency_product=$signed({1'b0,base_step})*modulation;
 wire signed [35:0] adjusted_wide=$signed({4'b0,base_step})+$signed(round_delta(frequency_product));
 wire [31:0] adjusted_step=adjusted_wide[31:0];
 wire signed [15:0] sine1,sine2,sine3,carrier;
 wire [31:0] phase2=phase[1]<<1,phase3=phase[1]+(phase[1]<<1);
 sine_rom s1(.address(phase[1][31:24]),.sample(sine1));
 sine_rom s2(.address(phase2[31:24]),.sample(sine2));
 sine_rom s3(.address(phase3[31:24]),.sample(sine3));
 wire signed [15:0] fm_source=job[1][0+:3]==1?sine2:sine1;
 wire signed [33:0] fm_product=fm_source*$signed({1'b0,job[1][20+:17]});
 wire [31:0] fm_offset=fm_product[31:0]<<1;
 wire [31:0] carrier_phase=phase[1]+fm_offset;
 sine_rom sc(.address(carrier_phase2[31:24]),.sample(carrier));
 reg signed [35:0] wave_env;
 reg signed [53:0] wave_pressure;
 assign out_valid=valid[5];assign out_tag=tag[5];
 assign out_sample=round_audio(wave_pressure);assign out_phase=phase[5];
 // FM shaping is derived in the existing first two engine stages.
 // The four Lane frontends and their delayed-job memories carry operands
 // already needed elsewhere; no additional issue or completion cycle.
 wire [22:0] fm_pitch=job_in[138+:23];
 wire [16:0] engine_taper=(fm_pitch<=23'd7077888)?17'd65536:
     (fm_pitch>=23'd7864320)?17'd0:((23'd7864320-fm_pitch)/12);
 wire [31:0] engine_ep_product=job[0][54+:17]*15'd20000;
 wire [16:0] engine_raw_index=job[0][0+:3]==1?engine_ep_product[31:16]:
     job[0][0+:3]==4?17'd10000:17'd0;
 wire [33:0] engine_index_product=engine_raw_index*job[0][3+:17];
 integer q;
 always @(posedge clk)begin
  if(rst)begin
   valid<=0;wave_env<=0;wave_pressure<=0;modulation<=0;wave<=0;base_step<=0;base_step1<=0;base_step2<=0;carrier_phase2<=0;harmonic1<=0;harmonic2<=0;harmonic3<=0;
   for(q=0;q<6;q=q+1)begin tag[q]<=0;job[q]<=0;phase[q]<=0;end
  end else begin
   valid<={valid[4:0],in_valid};
   for(q=1;q<6;q=q+1)begin tag[q]<=tag[q-1];job[q]<=job[q-1];phase[q]<=phase[q-1];end
   if(in_valid)begin tag[0]<=in_tag;job[0]<=job_in;base_step<=interpolated[31:0];modulation<=round_mod(lfo_max);end
   if(DERIVE_FM)begin
    if(in_valid)job[0][3+:17]<=engine_taper;
    job[1][20+:17]<=engine_index_product>>16;
   end
   if(valid[0])base_step1<=base_step;
   if(valid[0])phase[1]<=job[0][161+:1]?32'd0:job[0][162+:32]+adjusted_step;
   // Separate phase/FM address generation from carrier lookup and timbre MAC.
   if(valid[1])begin
    base_step2<=base_step1;carrier_phase2<=carrier_phase;
    harmonic1<=sine1;harmonic2<=sine2;harmonic3<=sine3;
   end
   if(valid[3])wave_env<=$signed(wave)*$signed({1'b0,job[3][88+:17]});
   if(valid[4])wave_pressure<=wave_env*$signed({1'b0,job[4][71+:17]});
   if(valid[2])wave<=timbre_wave(job[2][0+:3],harmonic1,harmonic2,harmonic3,carrier,
     job[2][54+:17],job[2][37+:17],job[2][3+:17],base_step2);
  end
 end
endmodule
// Static modulo-16 schedule. Two operand contexts and a small output tail.
// Intermediate values have disjoint lifetimes across consecutive voices.
module r18_scheduled_backend #(parameter DERIVE_FM=1)(
 input wire clk,rst,in_valid,output wire in_ready,
 input wire [4:0] in_tag,input wire [193:0] job_in,
 output reg out_valid,output reg [4:0] out_tag,
 output reg signed [17:0] out_sample,output reg [31:0] out_phase
);
 reg [4:0] cycle;
 wire [3:0] step=cycle[3:0];wire bank=cycle[4];
 wire prev=~bank,prev2=bank;
 reg [1:0] occupied;
 reg tail_valid;reg [4:0] tail_tag;reg [31:0] tail_phase;
 reg [193:0] job[0:1];reg [4:0] tag[0:1];
 reg [31:0] low_step,delta_step,base_step,adjusted,phase,carrier_phase;
 reg signed [17:0] modulation,wave;
 reg [16:0] taper,raw_index,fm_index,amplitude,w1,w2,w3;
 reg signed [15:0] h1,h2,h3,carrier;
 reg signed [53:0] term1,term3,pressure_product;
 reg signed [35:0] term2,env_product;
 reg signed [35:0] wa,wa_q;reg signed [17:0] wb,wb_q,na,nb,na_q,nb_q;
 reg signed [53:0] wp,wq;
 reg signed [35:0] np,nq;
 wire [6:0] note=job_in[160:154];
 wire [16:0] input_taper=job_in[160:138]<=23'd7077888 ? 17'd65536:
          job_in[160:138]>=23'd7864320 ? 17'd0:(23'd7864320-job_in[160:138])/12;
 wire [31:0] lo,hi;
 r18_phase_step_rom lower(.note_code(note),.phase_step(lo));
 r18_phase_step_rom upper(.note_code(note==127 ? 7'd127:note+1'b1),.phase_step(hi));
 wire [31:0] harmonic2_phase=phase<<1;
 wire [31:0] harmonic3_phase=phase+(phase<<1);
 reg [7:0] sine_address;
 wire signed [15:0] sine_value;
 reg signed [15:0] fm_sine;
 always @*begin
  case(step)
   13:sine_address=job[bank][2:0]==1 ? harmonic2_phase[31:24]:phase[31:24];
   14:sine_address=phase[31:24];
   15:sine_address=harmonic2_phase[31:24];
   0:sine_address=harmonic3_phase[31:24];
   2:sine_address=carrier_phase[31:24];
   default:sine_address=0;
  endcase
 end
 sine_rom shared_sine(.address(sine_address),.sample(sine_value));
 assign in_ready=!rst && step==0;

 // Rounding is copied from the frozen arithmetic contract; only scheduling
 // and shared operator ownership change. No extra intermediate quantization.
 function signed [17:0] round_mod(input signed [51:0] value);
  reg signed [52:0] wide;
  begin wide={value[51],value};
   if(wide<0)round_mod=-(((-wide)+53'sd1073741824)>>>31);
   else round_mod=(wide+53'sd1073741824)>>>31;
  end
 endfunction
 function signed [34:0] round_delta(input signed [50:0] value);
  reg signed [51:0] wide;
  begin wide={value[50],value};
   if(wide<0)round_delta=-(((-wide)+52'sd32768)>>>16);
   else round_delta=(wide+52'sd32768)>>>16;
  end
 endfunction
 function signed [17:0] round_audio(input signed [53:0] value);
  reg signed [54:0] wide;reg signed [22:0] shifted;
  begin wide={value[53],value};
   if(wide<0)shifted=-(((-wide)+55'sd2147483648)>>>32);
   else shifted=(wide+55'sd2147483648)>>>32;
   if(shifted>23'sd131071)round_audio=18'sh1ffff;
   else if(shifted < -23'sd131072)round_audio=18'h20000;
   else round_audio=shifted[17:0];
  end
 endfunction
 wire signed [17:0] carrier_wide={{2{carrier[15]}},carrier};
 wire signed [17:0] shaped=carrier>16'sd16384 ? 
     18'sd16384+((carrier_wide-18'sd16384)>>>1):
     carrier< -16'sd16384 ? -18'sd16384+((carrier_wide+18'sd16384)>>>1):carrier_wide;
 wire signed [35:0] shape_delta=$signed(shaped)-$signed(carrier_wide);
 wire signed [63:0] harmonic_total=$signed(term1)+$signed(term2)+$signed(term3);
 wire signed [63:0] shaped_total=$signed(carrier_wide)+($signed(term1)>>>16);
 wire [48:0] interpolated={17'd0,low_step}+(({1'b0,wq[47:0]}+49'd32768)>>16);
 wire signed [35:0] adjusted_wide=$signed({4'b0,base_step})+$signed(round_delta(wq[50:0]));

 // The wide unit has reserved issue offsets 1,4,8,19,21,27,31.
 // The narrow unit has reserved offsets 1,2,4,5,7,14,22.
 // Modulo-16 residues are distinct within each unit.
 always @* begin
  wa=0;wb=0;na=0;nb=0;
  case(step)
   1:begin
    wa=$signed({4'd0,delta_step});wb=$signed({2'd0,job[bank][153:138]});
    na=$signed(job[bank][137:122]);nb=$signed({1'b0,job[bank][121:105]});
   end
   4:begin
    wa=$signed(nq[33:0]);wb=18'sd655;
    na=$signed({1'b0,job[bank][70:54]});
    nb=job[bank][2:0]==1 ? 18'sd52429:18'sd5000;
   end
   8:begin wa=$signed({4'd0,base_step});wb=modulation;end
   3:begin
    case(job[prev][2:0])
     1:begin wa=$signed(carrier);wb=$signed({1'b0,amplitude});end
     2,3:begin wa=$signed(h1);wb=$signed({1'b0,w1});end
     4:begin wa=shape_delta;wb=$signed({1'b0,job[prev][19:3]});end
     default:begin wa=0;wb=0;end
    endcase
   end
   5:begin
    wa=$signed(h3);wb=$signed({1'b0,w3});
    na=$signed({1'b0,job[bank][70:54]});nb=18'sd2500;
   end
   11:begin wa=$signed(wave);wb=$signed({1'b0,job[prev][104:88]});end
   15:begin wa=$signed(env_product);wb=$signed({1'b0,job[prev][87:71]});end
   default:begin end
  endcase
  case(step)
   2:begin
    na=$signed({1'b0,job[bank][2:0]==1 ? job[bank][70:54]:job[bank][53:37]});
    nb=job[bank][2:0]==1 ? 18'sd20000:18'sd24000;
   end
   7:begin na=$signed({1'b0,raw_index});nb=$signed({1'b0,taper});end
   14:begin na=fm_sine;nb=$signed({1'b0,fm_index});end
   6:begin na=$signed(h2);nb=$signed({1'b0,w2});end
   default:begin end
  endcase
 end

 always @(posedge clk)begin
  if(rst)begin wa_q<=0;wb_q<=0;na_q<=0;nb_q<=0;wp<=0;wq<=0;np<=0;nq<=0;end
  else begin
   wa_q<=wa;wb_q<=wb;na_q<=na;nb_q<=nb;
   wp<=wa_q*wb_q;wq<=wp;np<=na_q*nb_q;nq<=np;
  end
 end
 always @(posedge clk)begin
  if(rst)begin cycle<=0;occupied<=0;tail_valid<=0;tail_tag<=0;tail_phase<=0;out_valid<=0;out_tag<=0;out_sample<=0;out_phase<=0;end
  else begin
   cycle<=cycle+1'b1;out_valid<=0;
   case(step)
    0:begin
     occupied[bank]<=in_valid;h3<=sine_value;
     if(in_valid)begin
      job[bank]<=job_in;tag[bank]<=in_tag;low_step<=lo;delta_step<=hi-lo;
      taper<=input_taper;
      if(DERIVE_FM)job[bank][19:3]<=input_taper;
      if(!DERIVE_FM)fm_index<=job_in[36:20];
     end
    end
    4:base_step<=interpolated[31:0];
    5:begin
     raw_index<=job[bank][2:0]==1 ? nq[31:16]:job[bank][2:0]==4 ? 17'd10000:17'd0;
     w1<=job[bank][2:0]==2 ? 17'd18000:17'd1000+nq[32:16];
    end
    7:begin
     modulation<=round_mod(wq[51:0]);
     amplitude<=17'd13107+nq[32:16];
     w2<=base_step<32'h40000000 ? (job[bank][2:0]==2 ? 17'd10000:nq[32:16]):17'd0;
    end
    8:begin
     w3<=base_step<32'd715827882 ? (job[bank][2:0]==2 ? 17'd4000:nq[32:16]):17'd0;
     term3<=wq;
    end
    10:begin
     tail_phase<=phase;
     if(DERIVE_FM)fm_index<=nq[32:16];
     case(job[prev][2:0])
      1:wave<=$signed(term1)>>>16;
      2,3:wave<=(harmonic_total+64'sd16384)>>>15;
      4:wave<=shaped_total;
      default:wave<=h1;
     endcase
    end
    11:adjusted<=adjusted_wide[31:0];
    12:phase<=job[bank][161] ? 32'd0:job[bank][193:162]+adjusted;
    13:fm_sine<=sine_value;
    1:carrier_phase<=phase+(nq[31:0]<<1);
    2:begin carrier<=sine_value;pressure_product<=wq;end
    6:term1<=wq;
    9:term2<=nq;
    14:begin env_product<=wq[35:0];h1<=sine_value;end
    15:begin tail_valid<=occupied[prev];tail_tag<=tag[prev];h2<=sine_value;end
    3:if(tail_valid)begin out_valid<=1;out_tag<=tail_tag;out_sample<=round_audio(pressure_product);out_phase<=tail_phase;end
    default:begin end
   endcase
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst && in_valid && !in_ready)$fatal(1,"R18_UNSCHEDULED_INPUT");
 // synthesis translate_on
endmodule

// Generated by scripts/generate_tables.py; A4=440Hz, equal temperament, Fs=48000.
// Full note range 0..127. Constant ROM, no run-time floating point.
module r18_phase_step_rom(input wire [6:0] note_code, output reg [31:0] phase_step) /* synthesis syn_romstyle="logic" */;
    always @* begin
        case (note_code)
            7'd0: phase_step = 32'd731558; // 8.175798916 Hz
            7'd1: phase_step = 32'd775059; // 8.661957218 Hz
            7'd2: phase_step = 32'd821146; // 9.177023997 Hz
            7'd3: phase_step = 32'd869974; // 9.722718241 Hz
            7'd4: phase_step = 32'd921705; // 10.300861154 Hz
            7'd5: phase_step = 32'd976513; // 10.913382232 Hz
            7'd6: phase_step = 32'd1034579; // 11.562325710 Hz
            7'd7: phase_step = 32'd1096099; // 12.249857374 Hz
            7'd8: phase_step = 32'd1161276; // 12.978271799 Hz
            7'd9: phase_step = 32'd1230329; // 13.750000000 Hz
            7'd10: phase_step = 32'd1303488; // 14.567617547 Hz
            7'd11: phase_step = 32'd1380998; // 15.433853164 Hz
            7'd12: phase_step = 32'd1463116; // 16.351597831 Hz
            7'd13: phase_step = 32'd1550118; // 17.323914436 Hz
            7'd14: phase_step = 32'd1642292; // 18.354047995 Hz
            7'd15: phase_step = 32'd1739948; // 19.445436483 Hz
            7'd16: phase_step = 32'd1843411; // 20.601722307 Hz
            7'd17: phase_step = 32'd1953026; // 21.826764465 Hz
            7'd18: phase_step = 32'd2069159; // 23.124651419 Hz
            7'd19: phase_step = 32'd2192197; // 24.499714749 Hz
            7'd20: phase_step = 32'd2322552; // 25.956543599 Hz
            7'd21: phase_step = 32'd2460658; // 27.500000000 Hz
            7'd22: phase_step = 32'd2606977; // 29.135235095 Hz
            7'd23: phase_step = 32'd2761996; // 30.867706329 Hz
            7'd24: phase_step = 32'd2926232; // 32.703195663 Hz
            7'd25: phase_step = 32'd3100235; // 34.647828872 Hz
            7'd26: phase_step = 32'd3284585; // 36.708095990 Hz
            7'd27: phase_step = 32'd3479896; // 38.890872965 Hz
            7'd28: phase_step = 32'd3686822; // 41.203444614 Hz
            7'd29: phase_step = 32'd3906052; // 43.653528929 Hz
            7'd30: phase_step = 32'd4138318; // 46.249302839 Hz
            7'd31: phase_step = 32'd4384395; // 48.999429498 Hz
            7'd32: phase_step = 32'd4645104; // 51.913087197 Hz
            7'd33: phase_step = 32'd4921317; // 55.000000000 Hz
            7'd34: phase_step = 32'd5213953; // 58.270470190 Hz
            7'd35: phase_step = 32'd5523991; // 61.735412657 Hz
            7'd36: phase_step = 32'd5852465; // 65.406391325 Hz
            7'd37: phase_step = 32'd6200470; // 69.295657744 Hz
            7'd38: phase_step = 32'd6569170; // 73.416191979 Hz
            7'd39: phase_step = 32'd6959793; // 77.781745931 Hz
            7'd40: phase_step = 32'd7373644; // 82.406889228 Hz
            7'd41: phase_step = 32'd7812103; // 87.307057858 Hz
            7'd42: phase_step = 32'd8276635; // 92.498605678 Hz
            7'd43: phase_step = 32'd8768789; // 97.998858995 Hz
            7'd44: phase_step = 32'd9290209; // 103.826174395 Hz
            7'd45: phase_step = 32'd9842633; // 110.000000000 Hz
            7'd46: phase_step = 32'd10427907; // 116.540940380 Hz
            7'd47: phase_step = 32'd11047982; // 123.470825314 Hz
            7'd48: phase_step = 32'd11704930; // 130.812782650 Hz
            7'd49: phase_step = 32'd12400941; // 138.591315488 Hz
            7'd50: phase_step = 32'd13138339; // 146.832383959 Hz
            7'd51: phase_step = 32'd13919586; // 155.563491861 Hz
            7'd52: phase_step = 32'd14747287; // 164.813778456 Hz
            7'd53: phase_step = 32'd15624207; // 174.614115717 Hz
            7'd54: phase_step = 32'd16553270; // 184.997211356 Hz
            7'd55: phase_step = 32'd17537579; // 195.997717991 Hz
            7'd56: phase_step = 32'd18580418; // 207.652348790 Hz
            7'd57: phase_step = 32'd19685267; // 220.000000000 Hz
            7'd58: phase_step = 32'd20855814; // 233.081880759 Hz
            7'd59: phase_step = 32'd22095965; // 246.941650628 Hz
            7'd60: phase_step = 32'd23409859; // 261.625565301 Hz
            7'd61: phase_step = 32'd24801882; // 277.182630977 Hz
            7'd62: phase_step = 32'd26276679; // 293.664767917 Hz
            7'd63: phase_step = 32'd27839171; // 311.126983722 Hz
            7'd64: phase_step = 32'd29494575; // 329.627556913 Hz
            7'd65: phase_step = 32'd31248413; // 349.228231433 Hz
            7'd66: phase_step = 32'd33106541; // 369.994422712 Hz
            7'd67: phase_step = 32'd35075158; // 391.995435982 Hz
            7'd68: phase_step = 32'd37160835; // 415.304697580 Hz
            7'd69: phase_step = 32'd39370534; // 440.000000000 Hz
            7'd70: phase_step = 32'd41711627; // 466.163761518 Hz
            7'd71: phase_step = 32'd44191930; // 493.883301256 Hz
            7'd72: phase_step = 32'd46819719; // 523.251130601 Hz
            7'd73: phase_step = 32'd49603764; // 554.365261954 Hz
            7'd74: phase_step = 32'd52553357; // 587.329535835 Hz
            7'd75: phase_step = 32'd55678342; // 622.253967444 Hz
            7'd76: phase_step = 32'd58989149; // 659.255113826 Hz
            7'd77: phase_step = 32'd62496826; // 698.456462866 Hz
            7'd78: phase_step = 32'd66213081; // 739.988845423 Hz
            7'd79: phase_step = 32'd70150316; // 783.990871963 Hz
            7'd80: phase_step = 32'd74321671; // 830.609395160 Hz
            7'd81: phase_step = 32'd78741067; // 880.000000000 Hz
            7'd82: phase_step = 32'd83423255; // 932.327523036 Hz
            7'd83: phase_step = 32'd88383859; // 987.766602512 Hz
            7'd84: phase_step = 32'd93639437; // 1046.502261202 Hz
            7'd85: phase_step = 32'd99207528; // 1108.730523907 Hz
            7'd86: phase_step = 32'd105106715; // 1174.659071670 Hz
            7'd87: phase_step = 32'd111356685; // 1244.507934888 Hz
            7'd88: phase_step = 32'd117978298; // 1318.510227651 Hz
            7'd89: phase_step = 32'd124993653; // 1396.912925732 Hz
            7'd90: phase_step = 32'd132426162; // 1479.977690847 Hz
            7'd91: phase_step = 32'd140300631; // 1567.981743927 Hz
            7'd92: phase_step = 32'd148643341; // 1661.218790320 Hz
            7'd93: phase_step = 32'd157482134; // 1760.000000000 Hz
            7'd94: phase_step = 32'd166846509; // 1864.655046072 Hz
            7'd95: phase_step = 32'd176767719; // 1975.533205024 Hz
            7'd96: phase_step = 32'd187278874; // 2093.004522405 Hz
            7'd97: phase_step = 32'd198415056; // 2217.461047815 Hz
            7'd98: phase_step = 32'd210213429; // 2349.318143339 Hz
            7'd99: phase_step = 32'd222713370; // 2489.015869777 Hz
            7'd100: phase_step = 32'd235956596; // 2637.020455303 Hz
            7'd101: phase_step = 32'd249987305; // 2793.825851464 Hz
            7'd102: phase_step = 32'd264852324; // 2959.955381693 Hz
            7'd103: phase_step = 32'd280601263; // 3135.963487854 Hz
            7'd104: phase_step = 32'd297286682; // 3322.437580640 Hz
            7'd105: phase_step = 32'd314964268; // 3520.000000000 Hz
            7'd106: phase_step = 32'd333693018; // 3729.310092145 Hz
            7'd107: phase_step = 32'd353535438; // 3951.066410049 Hz
            7'd108: phase_step = 32'd374557749; // 4186.009044810 Hz
            7'd109: phase_step = 32'd396830112; // 4434.922095630 Hz
            7'd110: phase_step = 32'd420426858; // 4698.636286679 Hz
            7'd111: phase_step = 32'd445426740; // 4978.031739553 Hz
            7'd112: phase_step = 32'd471913192; // 5274.040910606 Hz
            7'd113: phase_step = 32'd499974611; // 5587.651702928 Hz
            7'd114: phase_step = 32'd529704648; // 5919.910763386 Hz
            7'd115: phase_step = 32'd561202526; // 6271.926975708 Hz
            7'd116: phase_step = 32'd594573365; // 6644.875161279 Hz
            7'd117: phase_step = 32'd629928537; // 7040.000000000 Hz
            7'd118: phase_step = 32'd667386037; // 7458.620184289 Hz
            7'd119: phase_step = 32'd707070876; // 7902.132820098 Hz
            7'd120: phase_step = 32'd749115498; // 8372.018089619 Hz
            7'd121: phase_step = 32'd793660223; // 8869.844191260 Hz
            7'd122: phase_step = 32'd840853716; // 9397.272573357 Hz
            7'd123: phase_step = 32'd890853480; // 9956.063479107 Hz
            7'd124: phase_step = 32'd943826385; // 10548.081821212 Hz
            7'd125: phase_step = 32'd999949222; // 11175.303405856 Hz
            7'd126: phase_step = 32'd1059409297; // 11839.821526772 Hz
            7'd127: phase_step = 32'd1122405052; // 12543.853951416 Hz
            default: phase_step = 32'd0;
        endcase
    end
endmodule

// Eight independent oscillator contexts; fixed front-end and back-end slots.
// Control inputs are stable from start through busy. Ownership changes only
// outside that interval. No runtime identity enters the arithmetic pipeline.
module r18_static_voice_lane(
 input wire clk,rst,start,
 input wire [7:0] slot_valid,slot_gate,slot_trigger,slot_fresh,
 input wire [55:0] slot_notes,input wire [63:0] slot_pressures,
 input wire [23:0] slot_timbres,input wire [7:0] vibrato_depth,
 input wire [3:0] glide_code,
 output reg busy,output wire completion_valid,completion_accept,
 output wire [2:0] completion_slot,output wire signed [17:0] completion_sample,
 output wire [31:0] completion_phase,
 output wire [135:0] envelope_levels,output wire [23:0] envelope_states,
 output wire [7:0] done_mask,output reg deadline_error
);
 localparam integer EW=13;
 localparam integer CW=32+7+8+3+3+17+17+4*EW+23+7+17+17+16+17+1+4+17+17+17;
 localparam integer EPW=3+17+17+4*EW;
 reg [7:0] age;
 reg [11:0] expression_q;
 reg [7:0] initialized;
 wire [2:0] read_slot=age[6:4];
 reg [2:0] captured_slot;
 reg captured_valid,captured_gate,captured_trigger,new_owner;
 reg [6:0] captured_note;
 reg [7:0] captured_pressure;
 reg [2:0] captured_timbre;
 reg [31:0] phase_q;
 reg [CW-1:0] state_q;
 wire [CW-1:0] state_read;
 // Normalize a new owner's envelope at context capture, before the ADSR
 // arithmetic stage. This preserves its initial duration=1 without putting
 // the owner-selection mux ahead of the release quotient/remainder path.
 reg[CW-1:0] captured_state;
 always @*begin
  captured_state=initialized[read_slot]?state_read:{CW{1'b0}};
  if(slot_fresh[read_slot] || !initialized[read_slot])
   captured_state[CW-50-EPW+:EPW]={3'd0,17'd0,17'd0,EW'(0),EW'(1),EW'(0),EW'(0)};
 end
 wire [31:0] phase_read;
 reg [16:0] levels[0:7];reg [2:0] states[0:7];
 wire [31:0] old_lfo;
 wire [6:0] old_note,old_target;
 wire [7:0] old_pressure;
 wire [2:0] old_timbre,old_env_state;
 wire [16:0] old_level,old_quotient,old_glide_remaining,old_glide_base,old_glide_error;
 wire [EW-1:0] old_remaining,old_duration,old_remainder,old_error;
 wire [22:0] old_pitch;
 wire [15:0] old_glide_remainder;
 wire old_up;wire [3:0] old_code;
 wire [16:0] old_gain,old_transient,old_body;
 assign {old_lfo,old_note,old_pressure,old_timbre,old_env_state,old_level,old_quotient,
 old_remaining,old_duration,old_remainder,old_error,old_pitch,old_target,
 old_glide_remaining,old_glide_base,old_glide_remainder,old_glide_error,old_up,old_code,
 old_gain,old_transient,old_body}=state_q;
 wire [2:0] env_state_result;
 wire [16:0] env_level_result,env_quotient_result;
 wire [31:0] env_remaining_result,env_duration_result,env_remainder_result,env_error_result;
 voice_adsr_step adsr(.state(old_env_state),.level(old_level),
  .remaining({19'd0,old_remaining}),.duration({19'd0,old_duration}),
  .remainder({19'd0,old_remainder}),.error_acc({19'd0,old_error}),
  .quotient(old_quotient),.gate(captured_gate),.retrigger(captured_trigger),
  .state_next(env_state_result),.level_next(env_level_result),.quotient_next(env_quotient_result),
  .remaining_next(env_remaining_result),.duration_next(env_duration_result),
  .remainder_next(env_remainder_result),.error_next(env_error_result));
 reg [EPW-1:0] env_q;
 wire [2:0] next_state;wire [16:0] next_level,next_quotient;
 wire [EW-1:0] next_remaining,next_duration,next_remainder,next_error;
 assign {next_state,next_level,next_quotient,next_remaining,next_duration,next_remainder,next_error}=env_q;
 wire [6:0] effective_note=next_state==4?(new_owner?7'd0:old_note):captured_note;
 wire [124:0] prepared;
 reg [124:0] prepared_q;
 glide_pitch_prepare glide_prepare(.new_owner(new_owner),.note_target(effective_note),.glide_code(expression_q[3:0]),
  .current_pitch(old_pitch),.stored_target(old_target),.remaining(old_glide_remaining),.base_step(old_glide_base),
  .remainder(old_glide_remainder),.error_acc(old_glide_error),.direction_up(old_up),.stored_code(old_code),.prepared(prepared));
 wire [22:0] next_pitch;wire [6:0] next_target;
 wire [16:0] next_glide_remaining,next_glide_base,next_glide_error;
 wire [15:0] next_glide_remainder;wire next_up;wire [3:0] next_code;
 r18_glide_advance glide_advance(.clk(clk),.rst(rst),.step(age[3:0]),.enable(busy && age<128),
  .prepared(prepared_q),.pitch_next(next_pitch),.target_next(next_target),
  .remaining_next(next_glide_remaining),.base_next(next_glide_base),.remainder_next(next_glide_remainder),
  .error_next(next_glide_error),.direction_next(next_up),.code_next(next_code));
 // Fixed preparation edges break target -> difference -> rounded step -> add.
 // Release holds the gain; a new instance takes its exact initial pressure.
 wire [7:0] effective_pressure=next_state==4?(new_owner?8'd0:old_pressure):captured_pressure;
 reg [16:0] pressure_target,pressure_difference,pressure_step;
 reg pressure_up;
 wire [16:0] next_gain=new_owner?pressure_target:
  (next_state==4 || pressure_target==old_gain)?old_gain:
  pressure_step>=pressure_difference?pressure_target:
  pressure_up?old_gain+pressure_step:old_gain-pressure_step;
 wire [2:0] timbre=new_owner?captured_timbre:old_timbre;
 wire [16:0] transient_value=new_owner?17'd65536:old_transient;
 wire [16:0] body_value=new_owner?17'd65536:old_body;
 wire [16:0] transient_delta=timbre==3?((transient_value+17'd1023)>>10):((transient_value+17'd2047)>>11);
 wire [16:0] body_delta=(body_value+17'd2047)>>11;
 wire [16:0] next_transient=(new_owner || (timbre!=1 && timbre!=3))?17'd65536:
  transient_value<=transient_delta?17'd0:transient_value-transient_delta;
 wire [16:0] next_body=(new_owner || timbre!=3)?17'd65536:body_value<=body_delta?17'd0:body_value-body_delta;
 wire [31:0] lfo_value=new_owner?32'd0:old_lfo;
 wire signed [15:0] lfo_sine;
 sine_rom lfo_table(.address(lfo_value[31:24]),.sample(lfo_sine));
 wire [16:0] depth=expression_q[11:4]==255?17'd65536:{1'b0,expression_q[11:4],expression_q[11:4]};
 wire [CW-1:0] state_next={32'(lfo_value+32'd447392),
  7'((captured_trigger||captured_gate)?captured_note:(next_state==0?7'd0:old_note)),
  8'((captured_trigger||captured_gate)?captured_pressure:(next_state==0?8'd0:old_pressure)),
  timbre,next_state,next_level,next_quotient,next_remaining,next_duration,next_remainder,next_error,
  next_pitch,next_target,next_glide_remaining,next_glide_base,next_glide_remainder,next_glide_error,next_up,next_code,
  next_gain,next_transient,next_body};
 wire context_write=!rst && busy && age<128 && age[3:0]==6 && captured_valid;
 s3_private_context_store #(.WIDTH(CW)) context_store(.clk(clk),.write_enable(context_write),
  .write_slot(captured_slot),.read_slot(read_slot),.write_value(state_next),.read_value(state_read));
 s3_private_context_store #(.WIDTH(32)) phase_store(.clk(clk),.write_enable(!rst&&completion_valid&&completion_accept),
  .write_slot(completion_slot),.read_slot(read_slot),.write_value(completion_phase),.read_value(phase_read));
 reg [193:0] pending_job;reg [4:0] pending_tag;reg pending;
 wire backend_ready,backend_valid;wire [4:0] backend_tag;
 wire launch=pending && backend_ready;
 r18_scheduled_backend backend(.clk(clk),.rst(rst||start),.in_valid(launch),.in_ready(backend_ready),
  .in_tag(pending_tag),.job_in(pending_job),.out_valid(backend_valid),.out_tag(backend_tag),
  .out_sample(completion_sample),.out_phase(completion_phase));
 assign completion_valid=backend_valid;
 assign completion_slot=backend_tag[2:0];
 assign completion_accept=slot_valid[completion_slot];
 assign done_mask=(backend_valid && completion_accept && !slot_gate[completion_slot] &&
  states[completion_slot]==0 && completion_sample==0)?(8'b1<<completion_slot):8'd0;
 generate for(genvar s=0;s<8;s++)begin: visible
  assign envelope_levels[s*17+:17]=(initialized[s] && slot_valid[s])?levels[s]:17'd0;
  assign envelope_states[s*3+:3]=(initialized[s] && slot_valid[s])?states[s]:3'd0;
 end endgenerate
 always @(posedge clk)begin
  if(rst)begin busy<=0;age<=0;initialized<=0;pending<=0;deadline_error<=0;expression_q<=0;
   captured_slot<=0;captured_valid<=0;captured_gate<=0;captured_trigger<=0;new_owner<=0;
   captured_note<=0;captured_pressure<=0;captured_timbre<=0;phase_q<=0;state_q<=0;
   env_q<=0;prepared_q<=0;pending_job<=0;pending_tag<=0;
   pressure_target<=0;pressure_difference<=0;pressure_step<=0;pressure_up<=0;
  end else begin
   if(start)begin
    if(busy)deadline_error<=1;
    busy<=1;age<=0;pending<=0;expression_q<={vibrato_depth,glide_code};
   end else if(busy)begin
    age<=age+1'b1;
    if(launch)pending<=0;
    if(age<128)case(age[3:0])
     0:begin
      captured_slot<=read_slot;captured_valid<=slot_valid[read_slot];captured_gate<=slot_gate[read_slot];
      captured_trigger<=slot_trigger[read_slot]&&slot_valid[read_slot];
      new_owner<=slot_fresh[read_slot]||!initialized[read_slot];
      captured_note<=slot_notes[read_slot*7+:7];captured_pressure<=slot_pressures[read_slot*8+:8];
      captured_timbre<=slot_timbres[read_slot*3+:3];
      state_q<=captured_state;
      phase_q<=initialized[read_slot]?phase_read:32'd0;
     end
     1:env_q<={env_state_result,env_level_result,env_quotient_result,
       EW'(env_remaining_result),EW'(env_duration_result),EW'(env_remainder_result),EW'(env_error_result)};
     2:begin prepared_q<=prepared;pressure_target<=effective_pressure==255?17'd65536:{1'b0,effective_pressure,effective_pressure};end
     3:begin pressure_up<=pressure_target>old_gain;
       pressure_difference<=pressure_target>old_gain?pressure_target-old_gain:old_gain-pressure_target;end
     4:pressure_step<=pressure_difference==0?17'd1:((pressure_difference+17'd3)>>2);
     6:begin
      pending_job<={32'(new_owner?0:phase_q),captured_trigger,next_pitch,lfo_sine,depth,next_level,next_gain,next_transient,next_body,17'd0,17'd0,timbre};
      pending_tag<={2'b0,captured_slot};pending<=1;
      if(captured_valid)begin initialized[captured_slot]<=1;levels[captured_slot]<=next_level;states[captured_slot]<=next_state;end
     end
     default:begin end
    endcase
    if(backend_valid && backend_tag==7)busy<=0;
    if(age>=191)deadline_error<=1;
   end
  end
 end
 // synthesis translate_off
 reg [175:0] stable_control;
 always @(posedge clk)begin
  if(start)begin stable_control<={slot_fresh,slot_valid,slot_gate,slot_trigger,slot_notes,slot_pressures,slot_timbres};end
  if(!rst && busy && !start)begin
   if(stable_control!=={slot_fresh,slot_valid,slot_gate,slot_trigger,slot_notes,slot_pressures,slot_timbres})$fatal(1,"R18_CONTROL_CHANGED_DURING_AUDIO");
   if(age<128 && age[3:0]==6 && pending&&!launch)$fatal(1,"R18_PENDING_OVERWRITE");
  end
 end
 // synthesis translate_on
endmodule

// Exact glide advance, in the unused preparation slots 3/4/5. prepared is
// already registered and remains stable until the next voice's slot 2.
module r18_glide_advance(
 input wire clk,rst,enable,input wire[3:0] step,input wire[124:0] prepared,
 output reg[22:0] pitch_next,output reg[6:0] target_next,
 output reg[16:0] remaining_next,base_next,error_next,
 output reg[15:0] remainder_next,output reg direction_next,output reg[3:0] code_next
);
 wire[22:0] target,pitch;wire[6:0] target_note;
 wire[16:0] remaining,base,error;wire[15:0] remainder;wire up;wire[3:0] code;
 assign {target,target_note,pitch,remaining,base,remainder,error,up,code}=prepared;
 wire[16:0] duration=17'd1<<({1'b0,code}+5'd5);
 wire[17:0] error_sum={1'b0,error}+{2'b0,remainder};
 reg carry;reg[16:0] advanced_error;reg[23:0] moved;
 wire[23:0] addend=up?{7'd0,base}:~{7'd0,base};
 wire reached=(up && moved>={1'b0,target}) || (!up && moved<={1'b0,target});
 always @(posedge clk)begin
  if(rst)begin
   carry<=0;advanced_error<=0;moved<=0;pitch_next<=0;target_next<=0;
   remaining_next<=0;base_next<=0;error_next<=0;remainder_next<=0;direction_next<=0;code_next<=0;
  end else if(enable)case(step)
   3:begin carry<=error_sum>=duration;
    advanced_error<=error_sum>=duration?17'(error_sum-duration):error_sum[16:0];end
   4:moved<={1'b0,pitch}+addend+24'(up?carry:!carry);
   5:begin
    target_next<=target_note;base_next<=base;remainder_next<=remainder;direction_next<=up;code_next<=code;
    if(remaining==0)begin pitch_next<=pitch;remaining_next<=remaining;error_next<=error;end
    else if(remaining==1 || reached)begin pitch_next<=target;remaining_next<=0;error_next<=0;end
    else begin pitch_next<=moved[22:0];remaining_next<=remaining-1'b1;error_next<=advanced_error;end
   end
   default:begin end
  endcase
 end
endmodule

// Fixed-lane panning and exact Q8 accumulation. Control ownership is frozen
// by the frame scheduler, so this stage requires no historical identity bus.
module r18_fixed_stereo_sum #(parameter integer COMPLETION_LIMIT=192) (
    input wire clk,rst,sample_tick,
    input wire [3:0] completion_valid,completion_accept,
    input wire [11:0] completion_slot,
    input wire [71:0] completion_sample,
    input wire [287:0] snapshot_pan,
    output reg signed [31:0] mix_l_q8,mix_r_q8,
    output reg mix_valid,
    output reg protocol_error,deadline_error,
    output reg [7:0] last_complete_cycle
);
    reg [3:0] v0,v1,v2,last0,last1,last2;
    reg signed [17:0] x0[0:3],x1[0:3];
    reg [8:0] pan0[0:3],coefficient[0:3];
    reg [3:0] right_unity;
    reg signed [27:0] product_l[0:3],product_r[0:3];
    reg signed [31:0] sum_l[0:3],sum_r[0:3];
    reg [3:0] sums_valid;
    reg signed [31:0] pair_l0,pair_l1,pair_r0,pair_r1;
    reg pair_valid,busy;
    reg [7:0] age;
    reg [7:0] seen[0:3];
    integer k;
    wire signed [27:0] variable_product[0:3],unity_product[0:3];
    genvar g;
    generate for(g=0;g<4;g=g+1)begin: multiply
        assign variable_product[g]=$signed(x1[g])*$signed({1'b0,coefficient[g]});
        assign unity_product[g]=$signed({{10{x1[g][17]}},x1[g]})<<<8;
    end endgenerate
    wire [8:0] selected_pan[0:3];
    generate for(genvar l=0;l<4;l=l+1)begin: snapshot_lane
        wire [8:0] pans[0:7];
        for(genvar s=0;s<8;s=s+1)begin: snapshot_word
            assign pans[s]=snapshot_pan[(l*8+s)*9+:9];
        end
        wire [2:0] slot=completion_slot[l*3+:3];
        assign selected_pan[l]=pans[slot];
    end endgenerate
    always @(posedge clk)begin
        if(rst)begin
            v0<=0;v1<=0;v2<=0;last0<=0;last1<=0;last2<=0;right_unity<=0;
            sums_valid<=0;pair_valid<=0;mix_valid<=0;mix_l_q8<=0;mix_r_q8<=0;
            protocol_error<=0;deadline_error<=0;last_complete_cycle<=0;age<=0;busy<=0;
            pair_l0<=0;pair_l1<=0;pair_r0<=0;pair_r1<=0;
            for(k=0;k<4;k=k+1)begin
                x0[k]<=0;x1[k]<=0;pan0[k]<=128;coefficient[k]<=256;
                product_l[k]<=0;product_r[k]<=0;sum_l[k]<=0;sum_r[k]<=0;seen[k]<=0;
            end
        end else begin
            v0<=completion_valid;v1<=v0;v2<=v1;last1<=last0;last2<=last1;
            sums_valid<=v2 & last2;pair_valid<=&sums_valid;mix_valid<=pair_valid;
            if(busy)begin age<=age+1'b1;if(age>=191)deadline_error<=1;end
            if(sample_tick)begin
                if(busy || |v0 || |v1 || |v2 || |completion_valid)deadline_error<=1;
                busy<=1;age<=0;
                for(k=0;k<4;k=k+1)begin sum_l[k]<=0;sum_r[k]<=0;seen[k]<=0;end
            end
            if(completion_valid!=0 && completion_valid!=4'b1111)protocol_error<=1;
            if(sums_valid!=0 && sums_valid!=4'b1111)protocol_error<=1;
            for(k=0;k<4;k=k+1)begin
                if(completion_valid[k])begin
                    if(!busy || seen[k][completion_slot[k*3 +:3]])protocol_error<=1;
                    seen[k][completion_slot[k*3 +:3]]<=1;
                    if(completion_slot[k*3 +:3]==7 && seen[k]!=8'h7f)protocol_error<=1;
                    if(selected_pan[k]>256)protocol_error<=1;
                    x0[k]<=completion_accept[k]?$signed(completion_sample[k*18 +:18]):18'sd0;
                    pan0[k]<=selected_pan[k];
                    last0[k]<=completion_slot[k*3 +:3]==7;
                end
                if(v0[k])begin
                    x1[k]<=x0[k];right_unity[k]<=pan0[k]>128;
                    coefficient[k]<=pan0[k]>128?((9'd256-pan0[k])<<1):(pan0[k]<<1);
                end
                if(v1[k])begin
                    product_l[k]<=right_unity[k]?variable_product[k]:unity_product[k];
                    product_r[k]<=right_unity[k]?unity_product[k]:variable_product[k];
                end
                if(v2[k])begin
                    sum_l[k]<=sum_l[k]+{{4{product_l[k][27]}},product_l[k]};
                    sum_r[k]<=sum_r[k]+{{4{product_r[k][27]}},product_r[k]};
                end
            end
            if(&sums_valid)begin
                pair_l0<=sum_l[0]+sum_l[1];pair_l1<=sum_l[2]+sum_l[3];
                pair_r0<=sum_r[0]+sum_r[1];pair_r1<=sum_r[2]+sum_r[3];
            end
            if(pair_valid)begin
                mix_l_q8<=pair_l0+pair_l1;mix_r_q8<=pair_r0+pair_r1;
                busy<=0;last_complete_cycle<=age+1'b1;
                if(!busy || age>=COMPLETION_LIMIT)deadline_error<=1;
            end
        end
    end
endmodule

// Audio owns all 32 control contexts from start until busy falls. Event writes
// must occur outside this interval. Four fixed lanes retain eight independent
// phase/frequency/envelope contexts each. IDs stay in the event subsystem.
module r18_frame_audio(
 input wire clk,rst,start,
 input wire [31:0] slot_valid,slot_gate,slot_trigger,slot_fresh,
 input wire [223:0] slot_notes,input wire [255:0] slot_pressures,
 input wire [95:0] slot_timbres,input wire [287:0] slot_pan,
 input wire [7:0] vibrato_depth,input wire [3:0] glide_code,
 output reg busy,output wire mix_valid,
 output wire signed [31:0] mix_l_q8,mix_r_q8,
 output wire [543:0] envelope_levels,output wire [95:0] envelope_states,
 output reg [31:0] reclaim_pending,output reg [575:0] voice_samples,
 output wire [3:0] completion_valid,completion_accept,
 output wire [11:0] completion_slot,output wire [71:0] completion_sample,
 output wire protocol_error,output wire deadline_error,output wire [7:0] last_complete_cycle
);
 wire [3:0] lane_busy,lane_error;
 wire [31:0] done_mask;wire mixer_deadline;
 generate for(genvar l=0;l<4;l++)begin: lanes
  r18_static_voice_lane lane(.clk(clk),.rst(rst),.start(start),
   .slot_valid(slot_valid[l*8+:8]),.slot_gate(slot_gate[l*8+:8]),.slot_trigger(slot_trigger[l*8+:8]),.slot_fresh(slot_fresh[l*8+:8]),
   .slot_notes(slot_notes[l*56+:56]),.slot_pressures(slot_pressures[l*64+:64]),.slot_timbres(slot_timbres[l*24+:24]),
   .vibrato_depth(vibrato_depth),.glide_code(glide_code),.busy(lane_busy[l]),
   .completion_valid(completion_valid[l]),.completion_accept(completion_accept[l]),
   .completion_slot(completion_slot[l*3+:3]),.completion_sample(completion_sample[l*18+:18]),.completion_phase(),
   .envelope_levels(envelope_levels[l*136+:136]),.envelope_states(envelope_states[l*24+:24]),
   .done_mask(done_mask[l*8+:8]),.deadline_error(lane_error[l]));
 end endgenerate
 r18_fixed_stereo_sum stereo(.clk(clk),.rst(rst),.sample_tick(start),
  .completion_valid(completion_valid),.completion_accept(completion_accept),.completion_slot(completion_slot),
  .completion_sample(completion_sample),.snapshot_pan(slot_pan),.mix_l_q8(mix_l_q8),.mix_r_q8(mix_r_q8),
  .mix_valid(mix_valid),.protocol_error(protocol_error),.deadline_error(mixer_deadline),.last_complete_cycle(last_complete_cycle));
 assign deadline_error=(|lane_error)||mixer_deadline;
 always @(posedge clk)begin
  if(rst)begin busy<=0;reclaim_pending<=0;voice_samples<=0;end
  else begin
   if(start)begin busy<=1;reclaim_pending<=0;end
   else reclaim_pending<=reclaim_pending|done_mask;
   if(mix_valid)busy<=0;
   for(integer l=0;l<4;l++)if(completion_valid[l] && completion_accept[l])
    voice_samples[(l*8+completion_slot[l*3+:3])*18+:18]<=completion_sample[l*18+:18];
  end
 end
 // synthesis translate_off
 reg[287:0] pan_frozen;
 always @(posedge clk)begin
  if(start)pan_frozen<=slot_pan;
  if(!rst && busy && slot_pan!==pan_frozen)$fatal(1,"R18_PAN_CHANGED_DURING_AUDIO");
  if(!rst && start && busy)$fatal(1,"R18_OVERLAPPING_FRAME");
 end
 // synthesis translate_on
endmodule

// Fixed eight-edge search. Eight banks expose one of four rows per edge.
// State cannot change during the search. The event item is available by
// phase 0 (one edge after start), matching the synchronous indexed FIFO.
// A 33-bit occupied window replaces unbounded repeated ID collision scans.
module r18_banked_event_search #(parameter integer ID_WIDTH=64)(
 input wire clk,rst,start,input wire[63:0] first_id,input wire[95:0] item,
 input wire[7:0] bank_valid,bank_gate,input wire[511:0] bank_ids,bank_tokens,bank_ages,
 input wire[31:0] bank_sources,input wire[63:0] bank_keys,input wire[135:0] bank_levels,
 output wire[1:0] row,output reg busy,output wire done,output wire[3:0] phase_index,
 output wire[4:0] victim,target,output wire target_found,
 output wire[63:0] allocation_id,next_id,output reg[5:0] skipped_ids,
 output wire wrapped,output wire victim_is_free
);
 localparam[63:0] ID_MAX=64'hffffffffffffffff>>(64-ID_WIDTH);
 reg[3:0] phase;reg[63:0] first;reg[95:0] item_q;
 assign phase_index=phase;
 wire[95:0] current_item=phase==0?item:item_q;
 assign row=phase<4?phase[1:0]:2'd0;
 assign done=busy && phase==7;
 reg[87:0] best[0:7];reg[7:0] target_hits;reg[4:0] targets[0:7];
 reg[32:0] occupied[0:7];
 reg[32:0] diff_lo[0:7],diff_hi[0:7];
 reg[32:0] distance_low[0:7];reg[7:0] distance_negative,distance_near;
 reg[7:0] id_valid0,id_valid1;
 wire[32:0] all_occupied=occupied[0]|occupied[1]|occupied[2]|occupied[3]|
  occupied[4]|occupied[5]|occupied[6]|occupied[7];
 reg[5:0] first_free;reg found_free_id;
 always @*begin
  first_free=0;found_free_id=0;
  for(integer n=0;n<33;n++)if(!found_free_id && !all_occupied[n])begin first_free=n;found_free_id=1;end
 end
 // At most 32 occupied identities: selected offset <=32, next offset <=33.
 // Prepare first+64 while scanning. Phase 6 then needs only two seven-bit
 // additions; its carry selects a previously registered upper word.
 reg[6:0] selected_lo,following_lo;
 reg[26:0] increment_middle;reg[32:0] increment_high;
 wire[64:0] selected_sum={selected_lo[6]?{increment_high,increment_middle[25:0]}:{1'b0,first[63:6]},selected_lo[5:0]};
 wire[64:0] following_sum={following_lo[6]?{increment_high,increment_middle[25:0]}:{1'b0,first[63:6]},following_lo[5:0]};
 wire selected_wrap=selected_sum[ID_WIDTH],following_wrap=following_sum[ID_WIDTH];
 assign allocation_id=selected_wrap?{58'd0,6'(selected_lo[5:0]+6'd1)}:(selected_sum[63:0]&ID_MAX);
 assign next_id=following_wrap?{58'd0,6'(following_lo[5:0]+6'd1)}:(following_sum[63:0]&ID_MAX);
 assign wrapped=following_wrap;
 assign victim=best[0][4:0];assign victim_is_free=best[0][87:86]==0;
 reg target_found_q;reg[4:0] target_q;
 assign target_found=target_found_q;
 reg[4:0] target_value;
 always @*begin target_value=0;for(integer b=0;b<8;b++)if(target_hits[b])target_value=targets[b];end
 assign target=target_q;
 // Reduction inputs are registered bank winners only. Do not reuse the
 // row comparator here: its phase mux creates a RAM-to-two-comparators
 // timing path even though a row and a reduction never execute together.
 wire[87:0] pair_candidate[0:3],quad_candidate[0:1];
 generate for(genvar p=0;p<4;p++)begin: pair_reduce
  wire take_right;
  r14_unsigned88_dsp_less compare(.a(best[p*2+1]),.b(best[p*2]),.less(take_right));
  assign pair_candidate[p]=take_right?best[p*2+1]:best[p*2];
 end endgenerate
 generate for(genvar q=0;q<2;q++)begin: quad_reduce
  wire take_right;
  r14_unsigned88_dsp_less compare(.a(pair_candidate[q*2+1]),.b(pair_candidate[q*2]),.less(take_right));
  assign quad_candidate[q]=take_right?pair_candidate[q*2+1]:pair_candidate[q*2];
 end endgenerate
 generate for(genvar b=0;b<8;b++)begin: banks
  wire[4:0] slot={3'(b),row};
  wire[87:0] key_value={(!bank_valid[b]?2'd0:(!bank_gate[b]?2'd1:2'd2)),
   (!bank_valid[b] || bank_gate[b])?17'd0:bank_levels[b*17+:17],
   bank_valid[b]?bank_ages[b*64+:64]:64'd0,slot};
  wire[87:0] rhs;
  if(b==0)assign rhs=phase==5?best[4]:key_value;
  else assign rhs=key_value;
  wire compare_enable=phase<4 || (phase==5 && b==0);
  wire take_rhs;
  r14_unsigned88_dsp_less compare(.a(rhs),.b(best[b]),.less(take_rhs));
  wire[63:0] id=bank_ids[b*64+:64]&ID_MAX;
  wire[32:0] corrected_hi=diff_hi[b]-diff_lo[b][32];
  wire[5:0] distance_index=distance_low[b][5:0]-distance_negative[b];
  wire matching=bank_valid[b] && bank_gate[b] && bank_sources[b*4+:4]==current_item[31:28] &&
   bank_keys[b*8+:8]==current_item[23:16] && bank_tokens[b*64+:64]==current_item[95:32];
  always @(posedge clk)begin
   if(rst || start)begin
    best[b]<={88{1'b1}};target_hits[b]<=0;targets[b]<=0;occupied[b]<=0;
    diff_lo[b]<=0;diff_hi[b]<=0;distance_low[b]<=0;
    distance_negative[b]<=0;distance_near[b]<=0;id_valid0[b]<=0;id_valid1[b]<=0;
   end else if(busy)begin
    if(phase==4 && b%4==0)best[b]<=quad_candidate[b/4];
    else if(compare_enable && take_rhs)best[b]<=rhs;
    if(phase<4 && matching)begin target_hits[b]<=1;targets[b]<=slot;end
    id_valid0[b]<=phase<4 && bank_valid[b];id_valid1[b]<=id_valid0[b];
    if(phase<4)begin
     diff_lo[b]<={1'b0,id[31:0]}-{1'b0,first[31:0]};
     diff_hi[b]<={1'b0,id[63:32]}-{1'b0,first[63:32]};
    end
    if(id_valid0[b])begin
     if(ID_WIDTH>32)begin
      distance_negative[b]<=corrected_hi[ID_WIDTH-32];
      distance_near[b]<=((corrected_hi & (33'h1ffffffff>>(64-ID_WIDTH)))==
       (corrected_hi[ID_WIDTH-32]?(33'd1<<(ID_WIDTH-32)):33'd0));
      distance_low[b]<={1'b0,diff_lo[b][31:0]};
     end else begin
      distance_negative[b]<=diff_lo[b][ID_WIDTH];distance_near[b]<=1;
      distance_low[b]<=diff_lo[b]&{1'b0,ID_MAX[31:0]};
     end
    end
    if(id_valid1[b] && distance_near[b] &&
      ((!distance_negative[b] && distance_low[b]<=32) || (distance_negative[b] && distance_low[b]<=33)))
      occupied[b][distance_index]<=1;
   end
  end
 end endgenerate
 always @(posedge clk)begin
  if(rst)begin busy<=0;phase<=0;first<=1;item_q<=0;skipped_ids<=0;selected_lo<=0;following_lo<=0;increment_middle<=0;increment_high<=0;target_q<=0;target_found_q<=0;end
  else if(start)begin busy<=1;phase<=0;first<=first_id&ID_MAX;end
  else if(busy)begin
   if(phase==0)begin item_q<=item;increment_middle<={1'b0,first[31:6]}+27'd1;end
   if(phase==1)increment_high<={1'b0,first[63:32]}+increment_middle[26];
   // All four rows have completed by phase 4. Freeze the target before
   // the phase-6 state read, removing the target priority mux from the
   // RAM address / ranking path without adding an event service cycle.
   if(phase==4)begin target_q<=target_value;target_found_q<=|target_hits;end
   if(phase==6)begin
    skipped_ids<=first_free;
    selected_lo<={1'b0,first[5:0]}+first_free;
    following_lo<={1'b0,first[5:0]}+first_free+7'd1;
   end
   if(phase==7)begin busy<=0;phase<=0;end else phase<=phase+1'b1;
  end
 end
 // synthesis translate_off
 initial if(ID_WIDTH<6 || ID_WIDTH>64)$fatal(1,"R18_ID_WIDTH");
 always @(posedge clk)if(!rst)begin
  if(start && (first_id==0 || (first_id&~ID_MAX)!=0))$fatal(1,"R18_ZERO_OR_WIDE_ID");
  if(start && busy && !done)$fatal(1,"R18_SEARCH_RESTART");
  if(busy && phase==6 && !found_free_id)$fatal(1,"R18_ID_WINDOW_FULL");
  if(done && (allocation_id==0 || next_id==0))$fatal(1,"R18_ID_ZERO_RESULT");
 end
 // synthesis translate_on
endmodule
module r19_ranked_event_search #(parameter integer ID_WIDTH=64)(
 input wire clk,rst,start,input wire[63:0] first_id,input wire[95:0] item,
 input wire[7:0] bank_valid,bank_gate,input wire[511:0] bank_ids,bank_tokens,input wire[39:0] bank_ranks,
 input wire[31:0] bank_sources,input wire[63:0] bank_keys,input wire[135:0] bank_levels,
 output wire[1:0] row,output reg busy,output wire done,output wire[3:0] phase_index,
 output wire[4:0] victim,target,output wire target_found,
 output wire[63:0] allocation_id,next_id,output reg[5:0] skipped_ids,
 output wire wrapped,output wire victim_is_free
);
 localparam[63:0] ID_MAX=64'hffffffffffffffff>>(64-ID_WIDTH);
 reg[3:0] phase;reg[63:0] first;reg[95:0] item_q;
 assign phase_index=phase;
 wire[95:0] current_item=phase==0?item:item_q;
 assign row=phase<4?phase[1:0]:2'd0;
 assign done=busy && phase==7;
 reg[28:0] best[0:7];reg[7:0] target_hits;reg[4:0] targets[0:7];
 reg[32:0] occupied[0:7];
 reg[32:0] diff_lo[0:7],diff_hi[0:7];
 reg[32:0] distance_low[0:7];reg[7:0] distance_negative,distance_near;
 reg[7:0] id_valid0,id_valid1;
 wire[32:0] all_occupied=occupied[0]|occupied[1]|occupied[2]|occupied[3]|
  occupied[4]|occupied[5]|occupied[6]|occupied[7];
 reg[5:0] first_free;reg found_free_id;
 always @*begin
  first_free=0;found_free_id=0;
  for(integer n=0;n<33;n++)if(!found_free_id && !all_occupied[n])begin first_free=n;found_free_id=1;end
 end
 // At most 32 occupied identities: selected offset <=32, next offset <=33.
 // Prepare first+64 while scanning. Phase 6 then needs only two seven-bit
 // additions; its carry selects a previously registered upper word.
 reg[6:0] selected_lo,following_lo;
 reg[26:0] increment_middle;reg[32:0] increment_high;
 wire[64:0] selected_sum={selected_lo[6]?{increment_high,increment_middle[25:0]}:{1'b0,first[63:6]},selected_lo[5:0]};
 wire[64:0] following_sum={following_lo[6]?{increment_high,increment_middle[25:0]}:{1'b0,first[63:6]},following_lo[5:0]};
 wire selected_wrap=selected_sum[ID_WIDTH],following_wrap=following_sum[ID_WIDTH];
 assign allocation_id=selected_wrap?{58'd0,6'(selected_lo[5:0]+6'd1)}:(selected_sum[63:0]&ID_MAX);
 assign next_id=following_wrap?{58'd0,6'(following_lo[5:0]+6'd1)}:(following_sum[63:0]&ID_MAX);
 assign wrapped=following_wrap;
 assign victim=best[0][4:0];assign victim_is_free=best[0][28:27]==0;
 reg target_found_q;reg[4:0] target_q;
 assign target_found=target_found_q;
 reg[4:0] target_value;
 always @*begin target_value=0;for(integer b=0;b<8;b++)if(target_hits[b])target_value=targets[b];end
 assign target=target_q;
 // Reduction inputs are registered bank winners only. Do not reuse the
 // row comparator here: its phase mux creates a RAM-to-two-comparators
 // timing path even though a row and a reduction never execute together.
 wire[28:0] pair_candidate[0:3],quad_candidate[0:1];
 generate for(genvar p=0;p<4;p++)begin: pair_reduce
  wire take_right;
  r19_unsigned29_less compare(.a(best[p*2+1]),.b(best[p*2]),.less(take_right));
  assign pair_candidate[p]=take_right?best[p*2+1]:best[p*2];
 end endgenerate
 generate for(genvar q=0;q<2;q++)begin: quad_reduce
  wire take_right;
  r19_unsigned29_less compare(.a(pair_candidate[q*2+1]),.b(pair_candidate[q*2]),.less(take_right));
  assign quad_candidate[q]=take_right?pair_candidate[q*2+1]:pair_candidate[q*2];
 end endgenerate
 generate for(genvar b=0;b<8;b++)begin: banks
  wire[4:0] slot={3'(b),row};
  wire[28:0] key_value={(!bank_valid[b]?2'd0:(!bank_gate[b]?2'd1:2'd2)),
   (!bank_valid[b] || bank_gate[b])?17'd0:bank_levels[b*17+:17],
   bank_valid[b]?bank_ranks[b*5+:5]:5'd0,slot};
  wire[28:0] rhs;
  if(b==0)assign rhs=phase==5?best[4]:key_value;
  else assign rhs=key_value;
  wire compare_enable=phase<4 || (phase==5 && b==0);
  wire take_rhs;
  r19_unsigned29_less compare(.a(rhs),.b(best[b]),.less(take_rhs));
  wire[63:0] id=bank_ids[b*64+:64]&ID_MAX;
  wire[32:0] corrected_hi=diff_hi[b]-diff_lo[b][32];
  wire[5:0] distance_index=distance_low[b][5:0]-distance_negative[b];
  wire matching=bank_valid[b] && bank_gate[b] && bank_sources[b*4+:4]==current_item[31:28] &&
   bank_keys[b*8+:8]==current_item[23:16] && bank_tokens[b*64+:64]==current_item[95:32];
  always @(posedge clk)begin
   if(rst || start)begin
    best[b]<={29{1'b1}};target_hits[b]<=0;targets[b]<=0;occupied[b]<=0;
    diff_lo[b]<=0;diff_hi[b]<=0;distance_low[b]<=0;
    distance_negative[b]<=0;distance_near[b]<=0;id_valid0[b]<=0;id_valid1[b]<=0;
   end else if(busy)begin
    if(phase==4 && b%4==0)best[b]<=quad_candidate[b/4];
    else if(compare_enable && take_rhs)best[b]<=rhs;
    if(phase<4 && matching)begin target_hits[b]<=1;targets[b]<=slot;end
    id_valid0[b]<=phase<4 && bank_valid[b];id_valid1[b]<=id_valid0[b];
    if(phase<4)begin
     diff_lo[b]<={1'b0,id[31:0]}-{1'b0,first[31:0]};
     diff_hi[b]<={1'b0,id[63:32]}-{1'b0,first[63:32]};
    end
    if(id_valid0[b])begin
     if(ID_WIDTH>32)begin
      distance_negative[b]<=corrected_hi[ID_WIDTH-32];
      distance_near[b]<=((corrected_hi & (33'h1ffffffff>>(64-ID_WIDTH)))==
       (corrected_hi[ID_WIDTH-32]?(33'd1<<(ID_WIDTH-32)):33'd0));
      distance_low[b]<={1'b0,diff_lo[b][31:0]};
     end else begin
      distance_negative[b]<=diff_lo[b][ID_WIDTH];distance_near[b]<=1;
      distance_low[b]<=diff_lo[b]&{1'b0,ID_MAX[31:0]};
     end
    end
    if(id_valid1[b] && distance_near[b] &&
      ((!distance_negative[b] && distance_low[b]<=32) || (distance_negative[b] && distance_low[b]<=33)))
      occupied[b][distance_index]<=1;
   end
  end
 end endgenerate
 always @(posedge clk)begin
  if(rst)begin busy<=0;phase<=0;first<=1;item_q<=0;skipped_ids<=0;selected_lo<=0;following_lo<=0;increment_middle<=0;increment_high<=0;target_q<=0;target_found_q<=0;end
  else if(start)begin busy<=1;phase<=0;first<=first_id&ID_MAX;end
  else if(busy)begin
   if(phase==0)begin item_q<=item;increment_middle<={1'b0,first[31:6]}+27'd1;end
   if(phase==1)increment_high<={1'b0,first[63:32]}+increment_middle[26];
   // All four rows have completed by phase 4. Freeze the target before
   // the phase-6 state read, removing the target priority mux from the
   // RAM address / ranking path without adding an event service cycle.
   if(phase==4)begin target_q<=target_value;target_found_q<=|target_hits;end
   if(phase==6)begin
    skipped_ids<=first_free;
    selected_lo<={1'b0,first[5:0]}+first_free;
    following_lo<={1'b0,first[5:0]}+first_free+7'd1;
   end
   if(phase==7)begin busy<=0;phase<=0;end else phase<=phase+1'b1;
  end
 end
 // synthesis translate_off
 initial if(ID_WIDTH<6 || ID_WIDTH>64)$fatal(1,"R18_ID_WIDTH");
 always @(posedge clk)if(!rst)begin
  if(start && (first_id==0 || (first_id&~ID_MAX)!=0))$fatal(1,"R18_ZERO_OR_WIDE_ID");
  if(start && busy && !done)$fatal(1,"R18_SEARCH_RESTART");
  if(busy && phase==6 && !found_free_id)$fatal(1,"R18_ID_WINDOW_FULL");
  if(done && (allocation_id==0 || next_id==0))$fatal(1,"R18_ID_ZERO_RESULT");
 end
 // synthesis translate_on
endmodule

module r26_ranked_event_search #(parameter integer ID_WIDTH=64)(
 input wire clk,rst,start,input wire[63:0] first_id,input wire[95:0] item,
 input wire[7:0] bank_valid,bank_gate,input wire[5:0] available_skip,input wire[511:0] bank_tokens,input wire[39:0] bank_ranks,
 input wire[31:0] bank_sources,input wire[63:0] bank_keys,input wire[135:0] bank_levels,
 output wire[1:0] row,output reg busy,output wire done,output wire[3:0] phase_index,
 output wire[4:0] victim,target,output wire target_found,
 output wire[63:0] allocation_id,next_id,output reg[5:0] skipped_ids,
 output wire wrapped,output wire victim_is_free
);
 localparam[63:0] ID_MAX=64'hffffffffffffffff>>(64-ID_WIDTH);
 reg[3:0] phase;reg[63:0] first;reg[95:0] item_q;
 assign phase_index=phase;
 wire[95:0] current_item=phase==0?item:item_q;
 assign row=phase<4?phase[1:0]:2'd0;
 assign done=busy && phase==7;
 reg[28:0] best[0:7];reg[7:0] target_hits;reg[4:0] targets[0:7];
 wire[5:0] first_free=available_skip;
 // At most 32 occupied identities: selected offset <=32, next offset <=33.
 // Prepare first+64 while scanning. Phase 6 then needs only two seven-bit
 // additions; its carry selects a previously registered upper word.
 reg[6:0] selected_lo,following_lo;
 reg[26:0] increment_middle;reg[32:0] increment_high;
 wire[64:0] selected_sum={selected_lo[6]?{increment_high,increment_middle[25:0]}:{1'b0,first[63:6]},selected_lo[5:0]};
 wire[64:0] following_sum={following_lo[6]?{increment_high,increment_middle[25:0]}:{1'b0,first[63:6]},following_lo[5:0]};
 wire selected_wrap=selected_sum[ID_WIDTH],following_wrap=following_sum[ID_WIDTH];
 assign allocation_id=selected_wrap?{58'd0,6'(selected_lo[5:0]+6'd1)}:(selected_sum[63:0]&ID_MAX);
 assign next_id=following_wrap?{58'd0,6'(following_lo[5:0]+6'd1)}:(following_sum[63:0]&ID_MAX);
 assign wrapped=following_wrap;
 assign victim=best[0][4:0];assign victim_is_free=best[0][28:27]==0;
 reg target_found_q;reg[4:0] target_q;
 assign target_found=target_found_q;
 reg[4:0] target_value;
 always @*begin target_value=0;for(integer b=0;b<8;b++)if(target_hits[b])target_value=targets[b];end
 assign target=target_q;
 // Reduction inputs are registered bank winners only. Do not reuse the
 // row comparator here: its phase mux creates a RAM-to-two-comparators
 // timing path even though a row and a reduction never execute together.
 wire[28:0] pair_candidate[0:3],quad_candidate[0:1];
 generate for(genvar p=0;p<4;p++)begin: pair_reduce
  wire take_right;
  r19_unsigned29_less compare(.a(best[p*2+1]),.b(best[p*2]),.less(take_right));
  assign pair_candidate[p]=take_right?best[p*2+1]:best[p*2];
 end endgenerate
 generate for(genvar q=0;q<2;q++)begin: quad_reduce
  wire take_right;
  r19_unsigned29_less compare(.a(pair_candidate[q*2+1]),.b(pair_candidate[q*2]),.less(take_right));
  assign quad_candidate[q]=take_right?pair_candidate[q*2+1]:pair_candidate[q*2];
 end endgenerate
 generate for(genvar b=0;b<8;b++)begin: banks
  wire[4:0] slot={3'(b),row};
  wire[28:0] key_value={(!bank_valid[b]?2'd0:(!bank_gate[b]?2'd1:2'd2)),
   (!bank_valid[b] || bank_gate[b])?17'd0:bank_levels[b*17+:17],
   bank_valid[b]?bank_ranks[b*5+:5]:5'd0,slot};
  wire[28:0] rhs;
  if(b==0)assign rhs=phase==5?best[4]:key_value;
  else assign rhs=key_value;
  wire compare_enable=phase<4 || (phase==5 && b==0);
  wire take_rhs;
  r19_unsigned29_less compare(.a(rhs),.b(best[b]),.less(take_rhs));
  wire matching=bank_valid[b] && bank_gate[b] && bank_sources[b*4+:4]==current_item[31:28] &&
   bank_keys[b*8+:8]==current_item[23:16] && bank_tokens[b*64+:64]==current_item[95:32];
  always @(posedge clk)begin
   if(rst || start)begin
    best[b]<={29{1'b1}};target_hits[b]<=0;targets[b]<=0;
   end else if(busy)begin
    if(phase==4 && b%4==0)best[b]<=quad_candidate[b/4];
    else if(compare_enable && take_rhs)best[b]<=rhs;
    if(phase<4 && matching)begin target_hits[b]<=1;targets[b]<=slot;end

   end
  end
 end endgenerate
 always @(posedge clk)begin
  if(rst)begin busy<=0;phase<=0;first<=1;item_q<=0;skipped_ids<=0;selected_lo<=0;following_lo<=0;increment_middle<=0;increment_high<=0;target_q<=0;target_found_q<=0;end
  else if(start)begin busy<=1;phase<=0;first<=first_id&ID_MAX;end
  else if(busy)begin
   if(phase==0)begin item_q<=item;increment_middle<={1'b0,first[31:6]}+27'd1;end
   if(phase==1)increment_high<={1'b0,first[63:32]}+increment_middle[26];
   // All four rows have completed by phase 4. Freeze the target before
   // the phase-6 state read, removing the target priority mux from the
   // RAM address / ranking path without adding an event service cycle.
   if(phase==4)begin target_q<=target_value;target_found_q<=|target_hits;end
   if(phase==6)begin
    skipped_ids<=first_free;
    selected_lo<={1'b0,first[5:0]}+first_free;
    following_lo<={1'b0,first[5:0]}+first_free+7'd1;
   end
   if(phase==7)begin busy<=0;phase<=0;end else phase<=phase+1'b1;
  end
 end
 // synthesis translate_off
 initial if(ID_WIDTH<6 || ID_WIDTH>64)$fatal(1,"R18_ID_WIDTH");
 always @(posedge clk)if(!rst)begin
  if(start && (first_id==0 || (first_id&~ID_MAX)!=0))$fatal(1,"R18_ZERO_OR_WIDE_ID");
  if(start && busy && !done)$fatal(1,"R18_SEARCH_RESTART");
  if(done && (allocation_id==0 || next_id==0))$fatal(1,"R18_ID_ZERO_RESULT");
 end
 // synthesis translate_on
endmodule


// One authoritative control/identity record per Voice, plus one pinned START
// version. Eight banks x four slots x two versions fit each RAM16 word bank.
// Audio uses the small control view; identity consumers query a single bank.
// No complete runtime/generation/token bus is exported to the audio engine.
// Word [314:0]: PID64, age64, token64, runtime64, generation16, source4,
// key8, timbre3, pressure8, note7, pan9, trigger, gate, valid, fresh-owner.
module r18_voice_state_store #(parameter integer WIDTH=315,FULL_BANK_WORDS=1,PARTIAL_WRITES=0)(
 input wire clk,rst,
 input wire write_valid,input wire[4:0] write_slot,input wire[WIDTH-1:0] write_word,
 input wire metadata_write_valid,input wire[WIDTH-1:0] metadata_write_word,
 input wire bulk_audio_retire,bulk_initial_identity,input wire[31:0] reclaim_mask,input wire clear_gates,clear_fresh,
 input wire snapshot_capture,read_snapshot,input wire[1:0] read_row,
 input wire[2:0] query_bank,
 output wire[8*WIDTH-1:0] bank_words,output wire[7:0] bank_initialized,output wire[WIDTH-1:0] query_word,
 output wire[991:0] audio_controls
);
 // The 31-bit current audio/control view is authoritative. Only START owns
 // a historical copy; no control field is duplicated in the metadata RAM.
 localparam integer BODY_WIDTH=WIDTH-159;
 reg snapshot_valid;
 reg[30:0] controls[0:31],frozen_controls[0:31];
 reg[31:0] body_initialized,body_versions,body_snapshot_initialized,body_snapshot_versions;
 reg[31:0] pid_initialized,pid_versions,pid_snapshot_initialized,pid_snapshot_versions;
 reg[31:0] pid_derived,pid_derived_valid,pid_snapshot_derived,pid_snapshot_derived_valid;
 wire[BODY_WIDTH-1:0] body_data[0:7];wire[63:0] pid_data[0:7];
 wire[7:0] body_owned,pid_owned;
 assign bank_initialized=body_owned;
 wire[BODY_WIDTH-1:0] body_write;
 wire write_metadata=PARTIAL_WRITES?metadata_write_valid:write_valid;
 wire[WIDTH-1:0] metadata_word=PARTIAL_WRITES?metadata_write_word:write_word;
 for(genvar i=0;i<BODY_WIDTH;i++)begin:body_input
  assign body_write[i]=metadata_word[i<156?i+31:i+159];
 end
 wire[4:0] query_slot={query_bank,read_row};
 generate for(genvar b=0;b<8;b++)begin:banks
  wire[4:0] slot={3'(b),read_row};
  wire regular_write=!rst && write_valid && write_slot[4:2]==b;
  wire body_write_enable=!rst && write_metadata && write_slot[4:2]==b;
  wire body_read_version=read_snapshot?body_snapshot_versions[slot]:body_versions[slot];
  wire pid_read_version=read_snapshot?pid_snapshot_versions[slot]:pid_versions[slot];
  assign body_owned[b]=read_snapshot?(snapshot_valid && body_snapshot_initialized[slot]):body_initialized[slot];
  assign pid_owned[b]=read_snapshot?(snapshot_valid && pid_snapshot_initialized[slot]):pid_initialized[slot];
  wire body_destination_version=snapshot_valid?~body_snapshot_versions[write_slot]:body_versions[write_slot];
  wire[4:0] pid_destination=bulk_initial_identity?slot:write_slot;
  wire pid_destination_version=snapshot_valid?~pid_snapshot_versions[pid_destination]:pid_versions[pid_destination];
  wire pid_write_enable=!rst && (bulk_initial_identity || body_write_enable);
  wire[63:0] pid_write=bulk_initial_identity?(controls[slot][1]?({59'd0,slot}+64'd1):64'd0):metadata_word[314:251];
  s3_private_context_store #(.WIDTH(BODY_WIDTH)) body_memory(.clk(clk),.write_enable(body_write_enable),
   .write_slot({body_destination_version,write_slot[1:0]}),.read_slot({body_read_version,read_row}),
   .write_value(body_write),.read_value(body_data[b]));
  assign pid_data[b]=64'd0;
  wire[BODY_WIDTH-1:0] bank_body=(FULL_BANK_WORDS && !body_owned[b])?{BODY_WIDTH{1'b0}}:body_data[b];
  assign bank_words[b*WIDTH+31+:156]=bank_body[155:0];
  assign bank_words[b*WIDTH+187+:64]=64'd0;
  assign bank_words[b*WIDTH+251+:64]=64'd0;
  assign bank_words[b*WIDTH+:31]=read_snapshot?frozen_controls[slot]:controls[slot];
  if(WIDTH>315)assign bank_words[b*WIDTH+315+:WIDTH-315]=bank_body[BODY_WIDTH-1:156];
  for(genvar t=0;t<4;t++)begin:words
   localparam integer SLOT=b*4+t;
   assign audio_controls[SLOT*31+:31]=controls[SLOT];
   always @(posedge clk)begin
    if(rst)begin
     body_initialized[SLOT]<=0;body_versions[SLOT]<=0;
     pid_initialized[SLOT]<=0;pid_versions[SLOT]<=0;pid_derived[SLOT]<=0;pid_derived_valid[SLOT]<=0;
     controls[SLOT]<=31'd2048;frozen_controls[SLOT]<=31'd2048;
    end else begin
     if(snapshot_capture)frozen_controls[SLOT]<=controls[SLOT];
     if(body_write_enable && write_slot[1:0]==t)begin
      body_initialized[SLOT]<=1;body_versions[SLOT]<=body_destination_version;
     end
     if(regular_write && write_slot[1:0]==t)begin
      controls[SLOT]<=write_word[30:0];
     end else if(bulk_audio_retire && read_row==t)begin
      controls[SLOT][3]<=0;
      if(clear_fresh)controls[SLOT][0]<=0;
      if(clear_gates)controls[SLOT][2]<=0;
      if(reclaim_mask[SLOT] && (clear_gates || !controls[SLOT][2]))controls[SLOT][1]<=0;
     end
     if(pid_write_enable && pid_destination[1:0]==t)begin
      pid_initialized[SLOT]<=1;
      if(FULL_BANK_WORDS || !bulk_initial_identity)pid_versions[SLOT]<=pid_destination_version;
      pid_derived[SLOT]<=bulk_initial_identity;
      if(bulk_initial_identity)pid_derived_valid[SLOT]<=controls[SLOT][1];
     end
    end
   end
  end
 end endgenerate
 wire[BODY_WIDTH-1:0] query_body=body_owned[query_bank]?body_data[query_bank]:{BODY_WIDTH{1'b0}};
 assign query_word[186:31]=query_body[155:0];
 assign query_word[250:187]=64'd0;
 assign query_word[30:0]=read_snapshot?frozen_controls[query_slot]:controls[query_slot];
 assign query_word[314:251]=64'd0;
 generate if(WIDTH>315)assign query_word[WIDTH-1:315]=query_body[BODY_WIDTH-1:156];endgenerate
 always @(posedge clk)begin
  if(rst)begin
   snapshot_valid<=0;body_snapshot_initialized<=0;body_snapshot_versions<=0;
   pid_snapshot_initialized<=0;pid_snapshot_versions<=0;pid_snapshot_derived<=0;pid_snapshot_derived_valid<=0;
  end else if(snapshot_capture)begin
   snapshot_valid<=1;body_snapshot_initialized<=body_initialized;body_snapshot_versions<=body_versions;
   pid_snapshot_initialized<=pid_initialized;pid_snapshot_versions<=pid_versions;
   pid_snapshot_derived<=pid_derived;pid_snapshot_derived_valid<=pid_derived_valid;
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(snapshot_capture && (write_valid || bulk_audio_retire || bulk_initial_identity))$fatal(1,"R19_SNAPSHOT_WRITE_RACE");
  if((bulk_audio_retire || bulk_initial_identity) && (write_valid || read_snapshot))$fatal(1,"R19_STORE_PORT_CONFLICT");
  if(bulk_audio_retire && bulk_initial_identity)$fatal(1,"R19_STORE_BULK_CONFLICT");
 end
 // synthesis translate_on
endmodule

module r26_voice_state_store #(parameter integer WIDTH=315,FULL_BANK_WORDS=1,PARTIAL_WRITES=0)(
 input wire clk,rst,
 input wire write_valid,input wire[4:0] write_slot,input wire[WIDTH-1:0] write_word,
 input wire metadata_write_valid,input wire[WIDTH-1:0] metadata_write_word,
 input wire bulk_audio_retire,bulk_initial_identity,input wire[31:0] reclaim_mask,input wire clear_gates,clear_fresh,
 input wire snapshot_capture,read_snapshot,input wire[1:0] read_row,
 input wire[2:0] query_bank,
 output wire[8*WIDTH-1:0] bank_words,output wire[7:0] bank_initialized,output wire[WIDTH-1:0] query_word,
 output wire[991:0] audio_controls
);
 // The 31-bit current audio/control view is authoritative. Only START owns
 // a historical copy; no control field is duplicated in the metadata RAM.
 localparam integer BODY_WIDTH=WIDTH-159;
 reg snapshot_valid;
 reg[30:0] controls[0:31],frozen_controls[0:31];
 reg[31:0] body_initialized,body_versions,body_snapshot_initialized,body_snapshot_versions;
 reg[31:0] pid_initialized,pid_versions,pid_snapshot_initialized,pid_snapshot_versions;
 reg[31:0] pid_derived,pid_derived_valid,pid_snapshot_derived,pid_snapshot_derived_valid;
 wire[BODY_WIDTH-1:0] body_data[0:7];wire[63:0] pid_data[0:7];
 wire[7:0] body_owned,pid_owned;
 assign bank_initialized=body_owned;
 wire[BODY_WIDTH-1:0] body_write;
 wire write_metadata=PARTIAL_WRITES?metadata_write_valid:write_valid;
 wire[WIDTH-1:0] metadata_word=PARTIAL_WRITES?metadata_write_word:write_word;
 for(genvar i=0;i<BODY_WIDTH;i++)begin:body_input
  assign body_write[i]=metadata_word[i<156?i+31:i+159];
 end
 wire[4:0] query_slot={query_bank,read_row};
 wire[79:0] cold_data[0:3];
 wire[79:0] cold_query=cold_data[query_slot[4:3]];
 for(genvar c=0;c<4;c++)begin:cold_banks
  wire rv=read_snapshot?body_snapshot_versions[query_slot]:body_versions[query_slot];
  wire wv=snapshot_valid?~body_snapshot_versions[write_slot]:body_versions[write_slot];
  for(genvar n=0;n<20;n++)begin:bits4
   RAM16SDP4 memory(.CLK(clk),.WRE(!rst && write_metadata && write_slot[4:3]==c),
    .WAD({wv,write_slot[2:0]}),.RAD({rv,query_slot[2:0]}),
    .DI(metadata_word[43+n*4+:4]),.DO(cold_data[c][n*4+:4]));
  end
 end
 generate for(genvar b=0;b<8;b++)begin:banks
  wire[4:0] slot={3'(b),read_row};
  wire regular_write=!rst && write_valid && write_slot[4:2]==b;
  wire body_write_enable=!rst && write_metadata && write_slot[4:2]==b;
  wire body_read_version=read_snapshot?body_snapshot_versions[slot]:body_versions[slot];
  wire pid_read_version=read_snapshot?pid_snapshot_versions[slot]:pid_versions[slot];
  assign body_owned[b]=read_snapshot?(snapshot_valid && body_snapshot_initialized[slot]):body_initialized[slot];
  assign pid_owned[b]=read_snapshot?(snapshot_valid && pid_snapshot_initialized[slot]):pid_initialized[slot];
  wire body_destination_version=snapshot_valid?~body_snapshot_versions[write_slot]:body_versions[write_slot];
  wire[4:0] pid_destination=bulk_initial_identity?slot:write_slot;
  wire pid_destination_version=snapshot_valid?~pid_snapshot_versions[pid_destination]:pid_versions[pid_destination];
  wire pid_write_enable=!rst && (bulk_initial_identity || body_write_enable);
  wire[63:0] pid_write=bulk_initial_identity?(controls[slot][1]?({59'd0,slot}+64'd1):64'd0):metadata_word[314:251];
  localparam integer HOT_WIDTH=BODY_WIDTH-80;
  wire[HOT_WIDTH-1:0] hot_data;
  s3_private_context_store #(.WIDTH(HOT_WIDTH)) body_memory(.clk(clk),.write_enable(body_write_enable),
   .write_slot({body_destination_version,write_slot[1:0]}),.read_slot({body_read_version,read_row}),
   .write_value({body_write[BODY_WIDTH-1:92],body_write[11:0]}),.read_value(hot_data));
  assign body_data[b]={hot_data[HOT_WIDTH-1:12],80'd0,hot_data[11:0]};
  assign pid_data[b]=64'd0;
  wire[BODY_WIDTH-1:0] bank_body=(FULL_BANK_WORDS && !body_owned[b])?{BODY_WIDTH{1'b0}}:body_data[b];
  assign bank_words[b*WIDTH+31+:156]=bank_body[155:0];
  assign bank_words[b*WIDTH+187+:64]=64'd0;
  assign bank_words[b*WIDTH+251+:64]=64'd0;
  assign bank_words[b*WIDTH+:31]=read_snapshot?frozen_controls[slot]:controls[slot];
  if(WIDTH>315)assign bank_words[b*WIDTH+315+:WIDTH-315]=bank_body[BODY_WIDTH-1:156];
  for(genvar t=0;t<4;t++)begin:words
   localparam integer SLOT=b*4+t;
   assign audio_controls[SLOT*31+:31]=controls[SLOT];
   always @(posedge clk)begin
    if(rst)begin
     body_initialized[SLOT]<=0;body_versions[SLOT]<=0;
     pid_initialized[SLOT]<=0;pid_versions[SLOT]<=0;pid_derived[SLOT]<=0;pid_derived_valid[SLOT]<=0;
     controls[SLOT]<=31'd2048;frozen_controls[SLOT]<=31'd2048;
    end else begin
     if(snapshot_capture)frozen_controls[SLOT]<=controls[SLOT];
     if(body_write_enable && write_slot[1:0]==t)begin
      body_initialized[SLOT]<=1;body_versions[SLOT]<=body_destination_version;
     end
     if(regular_write && write_slot[1:0]==t)begin
      controls[SLOT]<=write_word[30:0];
     end else if(bulk_audio_retire && read_row==t)begin
      controls[SLOT][3]<=0;
      if(clear_fresh)controls[SLOT][0]<=0;
      if(clear_gates)controls[SLOT][2]<=0;
      if(reclaim_mask[SLOT] && (clear_gates || !controls[SLOT][2]))controls[SLOT][1]<=0;
     end
     if(pid_write_enable && pid_destination[1:0]==t)begin
      pid_initialized[SLOT]<=1;
      if(FULL_BANK_WORDS || !bulk_initial_identity)pid_versions[SLOT]<=pid_destination_version;
      pid_derived[SLOT]<=bulk_initial_identity;
      if(bulk_initial_identity)pid_derived_valid[SLOT]<=controls[SLOT][1];
     end
    end
   end
  end
 end endgenerate
 wire[BODY_WIDTH-1:0] query_body=body_owned[query_bank]?body_data[query_bank]:{BODY_WIDTH{1'b0}};
 assign query_word[186:31]={query_body[155:92],body_owned[query_bank]?cold_query:80'd0,query_body[11:0]};
 assign query_word[250:187]=64'd0;
 assign query_word[30:0]=read_snapshot?frozen_controls[query_slot]:controls[query_slot];
 assign query_word[314:251]=64'd0;
 generate if(WIDTH>315)assign query_word[WIDTH-1:315]=query_body[BODY_WIDTH-1:156];endgenerate
 always @(posedge clk)begin
  if(rst)begin
   snapshot_valid<=0;body_snapshot_initialized<=0;body_snapshot_versions<=0;
   pid_snapshot_initialized<=0;pid_snapshot_versions<=0;pid_snapshot_derived<=0;pid_snapshot_derived_valid<=0;
  end else if(snapshot_capture)begin
   snapshot_valid<=1;body_snapshot_initialized<=body_initialized;body_snapshot_versions<=body_versions;
   pid_snapshot_initialized<=pid_initialized;pid_snapshot_versions<=pid_versions;
   pid_snapshot_derived<=pid_derived;pid_snapshot_derived_valid<=pid_derived_valid;
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(snapshot_capture && (write_valid || bulk_audio_retire || bulk_initial_identity))$fatal(1,"R19_SNAPSHOT_WRITE_RACE");
  if((bulk_audio_retire || bulk_initial_identity) && (write_valid || read_snapshot))$fatal(1,"R19_STORE_PORT_CONFLICT");
  if(bulk_audio_retire && bulk_initial_identity)$fatal(1,"R19_STORE_BULK_CONFLICT");
 end
 // synthesis translate_on
endmodule



// Single-owner event/control/identity state. Audio and transactions are
// mutually exclusive. Queries cannot observe an uncommitted transaction.
// Undo records replace the old full working/public identity duplicates.
// Full before/after records leave at execution, so record consumers need not
// reconstruct a historical identity by searching the current slot directory.
module r18_event_controller #(parameter integer NO_UNDO=0,ID_WIDTH=64,PHONE_LOOKUP=0)(
 input wire clk,rst,panic,audio_busy,audio_retire,
 input wire session_flush,session_ready,input wire[575:0] event_phone_presses,
 input wire lookup_valid,lookup_pan,input wire[7:0] lookup_key,
 input wire[63:0] lookup_identity,input wire[15:0] lookup_generation,lookup_tag,
 output wire lookup_ready,lookup_response_valid,lookup_found,
 output wire[4:0] lookup_response_slot,output wire[314:0] lookup_response_word,
 output wire[15:0] lookup_response_tag,
 input wire[31:0] audio_reclaim,input wire[543:0] envelope_levels,
 input wire window_open,input wire[10:0] remaining_cycles,
 input wire event_valid,output wire event_ready,input wire[40:0] event_header,
 input wire[95:0] event_item,output wire[3:0] event_item_index,input wire[2:0] timbre_id,
 input wire[63:0] frame_id,input wire[15:0] subcycle,input wire[63:0] allocated_persistent_id,
 input wire snapshot_valid,snapshot_record_start,output wire snapshot_ready,
 input wire pan_valid,input wire[4:0] pan_slot,input wire[63:0] pan_id,
 input wire[15:0] pan_generation,input wire[8:0] pan_value,output wire pan_ready,
 output wire pan_response_valid,output wire[1:0] pan_result,
 output wire[4:0] pan_response_slot,output wire[314:0] pan_before,pan_after,
 output wire reclaim_batch_busy,
 input wire query_valid,query_snapshot,input wire[4:0] query_slot,
 output wire query_ready,output reg query_response_valid,output reg[4:0] query_response_slot,
 output reg[314:0] query_response_word,
 output wire identity_stable,output wire busy,output wire[991:0] audio_controls,
 output reg[7:0] vibrato_depth,output reg protocol_error,
 output wire batch_begin,batch_publish,output reg batch_abort,output reg[31:0] batch_timestamp,
 output wire fact_valid,output wire[3:0] fact_lane,output wire[95:0] fact_item,
 output wire[7:0] fact_outcome,output wire[5:0] fact_slot,output wire fact_steal,
 output wire[314:0] fact_before,fact_after,output wire[63:0] fact_frame,output wire[15:0] fact_subcycle,
 output reg[31:0] allocation_count,steal_count,stale_count,reclaim_count,id_skip_count,id_wrap_count
);
 reg[4:0] age_rank[0:31];
 localparam IDLE=0,RUN=1,COMMIT=2,ROLLBACK=3,GATE_CLEAR=4,AUDIO_CLEAR=5,RECLAIM=6,
  INITIAL_IDENTITY=7,PAN_READ=8,PAN_APPLY=9,LOOKUP_SCAN=10,LOOKUP_SELECT=11,LOOKUP_READ=12,LOOKUP_REPLY=13,ID_SCAN=14;
 localparam integer WORD_WIDTH=PHONE_LOOKUP==1?379:315;
 localparam[63:0] ID_MAX=64'hffffffffffffffff>>(64-ID_WIDTH);
 reg[63:0] id_cursor;
 reg collision_mode;reg[5:0] id_scan_cycle;
 reg[63:0] batch_first_id;
 reg[41:0] id_occupied;reg[5:0] id_offset;
 wire collision_check=collision_mode || id_cursor>ID_MAX-64'd42;
 reg[5:0] free_absolute;reg free_found;
 always @*begin
  free_absolute=id_offset;free_found=0;
  for(integer n=0;n<42;n++)if(!free_found && n>=id_offset && !id_occupied[n])begin free_absolute=6'(n);free_found=1;end
 end
 wire[5:0] available_skip=collision_mode?free_absolute-id_offset:6'd0;
 reg[3:0] state;reg[1:0] clear_row;reg[4:0] reclaim_slot;
 reg[63:0] pan_id_q;reg[15:0] pan_generation_q;reg[8:0] pan_value_q;
 reg[4:0] slot_q;reg[WORD_WIDTH-1:0] before_q;
 reg[31:0] phone_owned,saved_phone_owned;
 wire[31:0] lookup_matches;
 reg phone_batch_live,lookup_cancelled,lookup_pan_q,lookup_found_q;
 reg[7:0] lookup_key_q;reg[63:0] lookup_identity_q;reg[15:0] lookup_generation_q,lookup_tag_q;
 wire lookup_request=PHONE_LOOKUP && lookup_valid;
 wire flush_phone=PHONE_LOOKUP && session_flush;
 reg[31:0] pending_reclaims;reg[63:0] reclaim_frames[0:3];reg[15:0] reclaim_subcycles[0:3];
 reg panic_pending;reg[8:0] mask;reg[3:0] lane,undo_count;
 reg[95:0] item_q;reg[7:0] saved_vibrato;
 wire[3:0] phase;wire[1:0] search_row;wire search_busy,search_done;
 wire[4:0] victim,target;wire target_found,victim_free;
 wire[63:0] selected_id,following_id;wire[5:0] skips;wire wrapped;
 function[3:0] next_enabled(input[8:0] enabled,input[3:0] from);
  integer n;begin next_enabled=9;for(n=8;n>=0;n--)if(n>=from && enabled[n])next_enabled=n;end
 endfunction
 reg[6:0] packet_cost;
 // Eight service edges per item, at most one undo entry per item, and
 // six edges for commit interruption / rollback transition / gate clear.
 // Reserving nine undo entries for a one-item packet needlessly refuses
 // a legal final packet near the sample boundary.
 always @*begin packet_cost=collision_check?7'd43:7'd6;for(integer n=0;n<9;n++)if(event_header[n])packet_cost=packet_cost+7'd9;end
 assign busy=state!=IDLE;
 assign identity_stable=!rst && state==IDLE && !audio_busy && !audio_retire && !panic && !panic_pending;
 assign snapshot_ready=identity_stable && (!snapshot_record_start || remaining_cycles>=5);
 assign pan_ready=identity_stable && !snapshot_valid && remaining_cycles>=3;
 assign lookup_ready=PHONE_LOOKUP && identity_stable && !snapshot_valid && !pan_valid && remaining_cycles>=8;
 assign lookup_response_valid=PHONE_LOOKUP && !rst && state==LOOKUP_REPLY;
 assign lookup_found=lookup_found_q && !lookup_cancelled && !flush_phone && session_ready && !panic && !panic_pending;
 assign lookup_response_slot=slot_q;assign lookup_response_word=before_q[314:0];assign lookup_response_tag=lookup_tag_q;
 // Pinned START reads borrow only otherwise unused RAM read edges. IDLE
 // transitions consume controls/command registers; RUN 4/5 reduce saved
 // winners and RUN 7 applies before_q. Live scans (0..3), before capture
 // (6), bulk updates and identity lookups retain exclusive read ownership.
 // Snapshot reads therefore require neither another RAM image nor stalls.
 wire snapshot_read_slot=!rst && !panic && !panic_pending && !snapshot_valid &&
  (state==IDLE || (state==RUN && (phase==4 || phase==5 || phase==7)));
 assign query_ready=query_snapshot?snapshot_read_slot:
  (identity_stable && !snapshot_valid && !pan_valid && !lookup_request);
 wire reading_snapshot=query_valid && query_snapshot && query_ready;
 assign event_ready=identity_stable && !protocol_error && window_open && !snapshot_valid && !pan_valid && !lookup_request && (!query_valid || query_snapshot) && remaining_cycles>=packet_cost;
 assign reclaim_batch_busy=state==AUDIO_CLEAR || state==RECLAIM;
 assign pan_response_valid=!rst && state==PAN_APPLY;
 assign pan_result=(panic || panic_pending)?2'd3:pan_value_q>256?2'd1:
  (!before_q[1] || before_q[122:59]!=pan_id_q || before_q[58:43]!=pan_generation_q)?2'd2:2'd0;
 wire pan_write=pan_response_valid && pan_result==0;
 assign pan_response_slot=slot_q;assign pan_before=before_q;
 assign pan_after=pan_write?{before_q[314:13],pan_value_q,before_q[3:0]}:before_q[314:0];
 wire accepting=event_valid && event_ready;
 assign batch_begin=accepting && event_header[8:0]!=0;
 assign batch_publish=!rst && state==COMMIT && !panic && !panic_pending;
 // The search consumes the synchronous FIFO word at phase 0 and captures
 // it. Execution/next-event control uses only the captured word, avoiding
 // a false phase-0 FIFO -> phase-8 restart combinational path.
 wire[95:0] current_item=item_q;
 wire[3:0] source=current_item[31:28],kind=current_item[27:24];
 wire invalid_item=current_item[0] || kind<1 || kind>4 ||
  (kind==4 && (current_item[23:16]!=255 || current_item[15:9]!=0)) ||
  (kind!=4 && current_item[95:32]==0);
 wire stale=(kind==1 && target_found) || ((kind==2 || kind==3) && !target_found);
 wire apply=!rst && state==RUN && search_done && !panic && !panic_pending;
 wire mutate=apply && !invalid_item && !stale && kind!=4;
 wire allocate=mutate && kind==1;
 wire[3:0] next_lane=next_enabled(mask,lane+1'b1);
 wire start_search=(batch_begin && !collision_check) || (state==ID_SCAN && id_scan_cycle==36 && !panic && !panic_pending) || (apply && !invalid_item && next_lane<9);
 assign event_item_index=state==IDLE?next_enabled(event_header[8:0],0):
  (apply && !invalid_item && next_lane<9)?next_lane:lane;

 wire[7:0] bank_initialized;wire[39:0] bank_ranks;wire[8*WORD_WIDTH-1:0] bank_words;wire[WORD_WIDTH-1:0] store_query;
 wire[7:0] bv,bg;wire[511:0] bi,bt,ba;wire[31:0] bs;wire[63:0] bk;wire[135:0] bl;
 wire[4:0] selected_slot=kind==1?victim:target;
 wire[4:0] lookup_slot=state==ID_SCAN?id_scan_cycle[4:0]:(state==PAN_READ || state==PAN_APPLY || state==LOOKUP_READ || state==LOOKUP_REPLY)?slot_q:state==RECLAIM?reclaim_slot:state==RUN?selected_slot:query_slot;
 wire[1:0] read_row=reading_snapshot?query_slot[1:0]:(state==AUDIO_CLEAR || state==GATE_CLEAR || state==INITIAL_IDENTITY || state==LOOKUP_SCAN)?clear_row:
  (state==RUN && phase<6)?search_row:lookup_slot[1:0];
 generate for(genvar b=0;b<8;b++)begin: search_words
  wire[WORD_WIDTH-1:0] word=bank_words[b*WORD_WIDTH+:WORD_WIDTH];
  // Search reads only live audio control state at its own fixed scan row.
  // Background frozen queries never select these operands.
  wire[30:0] search_control=audio_controls[(b*4+search_row)*31+:31];
  assign bv[b]=search_control[1];assign bg[b]=search_control[2];assign bi[b*64+:64]=word[122:59];
  assign bt[b*64+:64]=word[186:123];assign ba[b*64+:64]=word[250:187];
  assign bank_ranks[b*5+:5]=age_rank[b*4+search_row];
  assign bs[b*4+:4]=word[42:39];assign bk[b*8+:8]=word[38:31];
  assign bl[b*17+:17]=search_control[0]?17'd0:envelope_levels[(b*4+search_row)*17+:17];
  if(PHONE_LOOKUP==1)begin: phone_lookup
   reg[3:0] row_matches;
   assign lookup_matches[b*4+:4]=row_matches;
   wire[4:0] slot={3'(b),read_row};
   wire match=phone_owned[slot] && word[1] && word[42:39]==2 &&
    (lookup_pan_q?(word[122:59]==lookup_identity_q && word[58:43]==lookup_generation_q):
     (word[378:315]==lookup_identity_q && word[38:31]==lookup_key_q));
   always @(posedge clk)begin
    if(rst)row_matches<=0;
    else if(lookup_request && lookup_ready)row_matches<=0;
    else if(state==LOOKUP_SCAN)row_matches[read_row]<=match;
   end
  end else begin: no_phone_lookup
   assign lookup_matches[b*4+:4]=4'd0;
  end
 end endgenerate
 r26_ranked_event_search #(.ID_WIDTH(ID_WIDTH)) search(.clk(clk),.rst(rst || state==ROLLBACK || state==GATE_CLEAR),
  .start(start_search),.first_id(allocate?following_id:id_cursor),.item(event_item),
  .bank_valid(bv),.bank_gate(bg),.available_skip(available_skip),.bank_tokens(bt),.bank_ranks(bank_ranks),.bank_sources(bs),.bank_keys(bk),.bank_levels(bl),
  .row(search_row),.phase_index(phase),.busy(search_busy),.done(search_done),.victim(victim),.target(target),
  .target_found(target_found),.allocation_id(selected_id),.next_id(following_id),.skipped_ids(skips),.wrapped(wrapped),.victim_is_free(victim_free));

 reg[WORD_WIDTH-1:0] updated_word,pan_store_word;
 always @*begin
  updated_word=before_q;
  if(kind==1)begin
   updated_word={PHONE_LOOKUP==1 && source==2?event_phone_presses[lane*64+:64]:64'd0,
    64'd0,64'd0,current_item[95:32],selected_id,
    16'(before_q[58:43]+16'd1),source,current_item[23:16],timbre_id,current_item[8:1],current_item[15:9],9'd128,4'b1111};
  end else if(kind==2)updated_word[2]=0;
  else if(kind==3)begin updated_word[27:20]=current_item[8:1];updated_word[19:13]=current_item[15:9];end
  pan_store_word=before_q;pan_store_word[314:0]=pan_after;
 end
 wire[WORD_WIDTH+4:0] undo_word;
 localparam integer UNDO_BITS=WORD_WIDTH+5-64;
 wire[UNDO_BITS-1:0] packed_undo_word;
 assign undo_word={packed_undo_word[UNDO_BITS-1:187],64'd0,packed_undo_word[186:0]};
 wire[3:0] undo_read=undo_count-4'd1;
 generate if(!NO_UNDO)begin:with_undo
 for(genvar n=0;n<UNDO_BITS/4;n++)begin: undo_log
  wire[UNDO_BITS-1:0] undo_input={slot_q,before_q[WORD_WIDTH-1:251],before_q[186:0]};
  RAM16SDP4 memory(.CLK(clk),.WRE(mutate),.WAD(undo_count),.RAD(undo_read),.DI(undo_input[n*4+:4]),.DO(packed_undo_word[n*4+:4]));
 end
 end else begin:no_undo
 assign packed_undo_word=0;
 end endgenerate
 wire restoring=!NO_UNDO && state==ROLLBACK && undo_count!=0;
 // Direct relative allocation order. Every allocation moves its slot to
 // newest; undo restores its previous position. Off, pressure, Pan, START,
 // and natural reclaim never change the ordering of surviving voices.
 // Unlike a finite numeric age counter this order never wraps.
 wire[7:0] undo_rank_input={2'd0,allocate,age_rank[slot_q]};wire[7:0] undo_rank_word;
 generate if(!NO_UNDO)begin:with_rank_undo
 for(genvar n=0;n<2;n++)begin:rank_undo
  RAM16SDP4 memory(.CLK(clk),.WRE(mutate),.WAD(undo_count),.RAD(undo_read),
   .DI(undo_rank_input[n*4+:4]),.DO(undo_rank_word[n*4+:4]));
 end
 end else begin:no_rank_undo
 assign undo_rank_word=0;
 end endgenerate
 wire rank_restore=restoring && undo_rank_word[5];
 wire rank_move=allocate || rank_restore;
 wire[4:0] rank_slot=rank_restore?undo_word[WORD_WIDTH+4:WORD_WIDTH]:slot_q;
 wire[4:0] old_rank=age_rank[rank_slot];
 wire[4:0] new_rank=rank_restore?undo_rank_word[4:0]:5'd31;
 for(genvar s=0;s<32;s++)begin:rank_update
  always @(posedge clk)begin
   if(rst)age_rank[s]<=5'(s);
   else if(rank_move)begin
    if(rank_slot==s)age_rank[s]<=new_rank;
    else if(old_rank<new_rank && age_rank[s]>old_rank && age_rank[s]<=new_rank)age_rank[s]<=age_rank[s]-5'd1;
    else if(new_rank<old_rank && age_rank[s]>=new_rank && age_rank[s]<old_rank)age_rank[s]<=age_rank[s]+5'd1;
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  for(integer x=0;x<32;x++)for(integer y=x+1;y<32;y++)
   if(age_rank[x]==age_rank[y])$fatal(1,"R19_RANK_NOT_PERMUTATION");
 end
 // synthesis translate_on

 wire[WORD_WIDTH-1:0] metadata_write_word=restoring?undo_word[WORD_WIDTH-1:0]:
  {PHONE_LOOKUP==1 && source==2?event_phone_presses[lane*64+:64]:64'd0,
   64'd0,64'd0,current_item[95:32],selected_id,
   16'(before_q[58:43]+16'd1),source,current_item[23:16],31'd0};
 generate if(PHONE_LOOKUP!=1)begin:compact_store
 r26_voice_state_store #(.WIDTH(WORD_WIDTH),.FULL_BANK_WORDS(0),.PARTIAL_WRITES(1)) store(.clk(clk),.rst(rst),.write_valid(mutate || restoring || pan_write),
  .write_slot(restoring?undo_word[WORD_WIDTH+4:WORD_WIDTH]:slot_q),.write_word(restoring?undo_word[WORD_WIDTH-1:0]:pan_write?pan_store_word:updated_word),
  .metadata_write_valid(allocate || restoring),.metadata_write_word(metadata_write_word),
  .bulk_audio_retire(state==AUDIO_CLEAR || state==GATE_CLEAR),
  .bulk_initial_identity(state==INITIAL_IDENTITY),
  .reclaim_mask(state==AUDIO_CLEAR?pending_reclaims:32'd0),.clear_gates(state==GATE_CLEAR),.clear_fresh(state==AUDIO_CLEAR),
  .snapshot_capture(snapshot_valid && snapshot_ready),.read_snapshot(reading_snapshot),
  .read_row(read_row),.query_bank(reading_snapshot?query_slot[4:2]:lookup_slot[4:2]),.bank_words(bank_words),.bank_initialized(bank_initialized),.query_word(store_query),.audio_controls(audio_controls));
 end else begin:legacy_store
 r18_voice_state_store #(.WIDTH(WORD_WIDTH),.FULL_BANK_WORDS(0),.PARTIAL_WRITES(1)) store(.clk(clk),.rst(rst),.write_valid(mutate || restoring || pan_write),
  .write_slot(restoring?undo_word[WORD_WIDTH+4:WORD_WIDTH]:slot_q),.write_word(restoring?undo_word[WORD_WIDTH-1:0]:pan_write?pan_store_word:updated_word),
  .metadata_write_valid(allocate || restoring),.metadata_write_word(metadata_write_word),
  .bulk_audio_retire(state==AUDIO_CLEAR || state==GATE_CLEAR),
  .bulk_initial_identity(state==INITIAL_IDENTITY),
  .reclaim_mask(state==AUDIO_CLEAR?pending_reclaims:32'd0),.clear_gates(state==GATE_CLEAR),.clear_fresh(state==AUDIO_CLEAR),
  .snapshot_capture(snapshot_valid && snapshot_ready),.read_snapshot(reading_snapshot),
  .read_row(read_row),.query_bank(reading_snapshot?query_slot[4:2]:lookup_slot[4:2]),.bank_words(bank_words),.bank_initialized(bank_initialized),.query_word(store_query),.audio_controls(audio_controls));
 end endgenerate

 wire reclaim_fire=!rst && state==RECLAIM && pending_reclaims[reclaim_slot];
 assign fact_valid=apply || reclaim_fire;
 assign fact_lane=reclaim_fire?4'd15:lane;
 assign fact_item=reclaim_fire?96'd0:current_item;
 assign fact_outcome=reclaim_fire?8'd10:invalid_item?8'd6:stale?8'd5:{4'd0,kind};
 assign fact_slot=reclaim_fire?{1'b0,reclaim_slot}:(kind==4 || ((kind==2 || kind==3) && !target_found))?6'd63:{1'b0,slot_q};
 assign fact_steal=allocate && !victim_free;
 assign fact_before=reclaim_fire?{store_query[314:2],1'b1,store_query[0]}:before_q[314:0];
 assign fact_after=reclaim_fire?store_query[314:0]:updated_word[314:0];
 assign fact_frame=reclaim_fire?reclaim_frames[reclaim_slot[1:0]]:frame_id;
 assign fact_subcycle=reclaim_fire?reclaim_subcycles[reclaim_slot[1:0]]:subcycle;
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;clear_row<=0;reclaim_slot<=0;pending_reclaims<=0;panic_pending<=0;
   mask<=0;lane<=0;undo_count<=0;item_q<=0;id_cursor<=1;vibrato_depth<=0;saved_vibrato<=0;
   protocol_error<=0;batch_abort<=0;batch_timestamp<=0;slot_q<=0;before_q<=0;
   pan_id_q<=0;pan_generation_q<=0;pan_value_q<=128;
   phone_owned<=0;saved_phone_owned<=0;phone_batch_live<=0;
   lookup_cancelled<=0;lookup_pan_q<=0;lookup_found_q<=0;lookup_key_q<=0;lookup_identity_q<=0;lookup_generation_q<=0;lookup_tag_q<=0;
   query_response_valid<=0;query_response_slot<=0;query_response_word<=0;
   allocation_count<=0;steal_count<=0;stale_count<=0;reclaim_count<=0;id_skip_count<=0;id_wrap_count<=0;
   for(integer r=0;r<4;r++)begin reclaim_frames[r]<=0;reclaim_subcycles[r]<=0;end
  end else begin
   query_response_valid<=query_valid && query_ready;batch_abort<=0;
   if(query_valid && query_ready)begin query_response_slot<=query_slot;query_response_word<=store_query[314:0];end
   if(panic)panic_pending<=1;
   if((panic || panic_pending) && (state==RUN || state==COMMIT || state==ID_SCAN))begin
    state<=NO_UNDO?GATE_CLEAR:ROLLBACK;clear_row<=0;batch_abort<=1;
    if(!NO_UNDO)begin vibrato_depth<=saved_vibrato;phone_owned<=saved_phone_owned;end
   end else case(state)
    IDLE:begin
     if(audio_retire)begin
      state<=AUDIO_CLEAR;clear_row<=0;
      if(PHONE_LOOKUP)for(integer s=0;s<32;s++)if(audio_reclaim[s] && audio_controls[s*31+1] && !audio_controls[s*31+2])phone_owned[s]<=0;
      for(integer s=0;s<32;s++)pending_reclaims[s]<=audio_reclaim[s] && audio_controls[s*31+1] && !audio_controls[s*31+2];
     end else if((panic || panic_pending) && !audio_busy && remaining_cycles>=5)begin state<=GATE_CLEAR;clear_row<=0;end
     else if(snapshot_valid && snapshot_ready && snapshot_record_start)begin state<=INITIAL_IDENTITY;clear_row<=0;end
     else if(pan_valid && pan_ready)begin
      slot_q<=pan_slot;pan_id_q<=pan_id;pan_generation_q<=pan_generation;pan_value_q<=pan_value;state<=PAN_READ;
     end
     else if(lookup_request && lookup_ready)begin
      state<=PHONE_LOOKUP==2?LOOKUP_READ:LOOKUP_SCAN;
      slot_q<=lookup_key[4:0];clear_row<=0;lookup_cancelled<=!session_ready;
      lookup_identity_q<=lookup_identity;lookup_key_q<=lookup_key;lookup_generation_q<=lookup_generation;
      lookup_pan_q<=lookup_pan;lookup_tag_q<=lookup_tag;lookup_found_q<=0;
     end
     else if(accepting)begin
      if(event_header[8:0]==0)begin protocol_error<=1;state<=GATE_CLEAR;clear_row<=0;end
      else begin
       state<=collision_check?ID_SCAN:RUN;mask<=event_header[8:0];lane<=next_enabled(event_header[8:0],0);undo_count<=0;
       batch_timestamp<=event_header[40:9];saved_vibrato<=vibrato_depth;
       saved_phone_owned<=phone_owned;phone_batch_live<=PHONE_LOOKUP && session_ready;
      end
     end
    end
    ID_SCAN:if(id_scan_cycle==36)state<=RUN;
    RUN:begin
     if(phase==0)item_q<=event_item;
     if(phase==6)begin slot_q<=selected_slot;before_q<=store_query;end
     if(apply)begin
      if(invalid_item)begin protocol_error<=1;batch_abort<=1;state<=NO_UNDO?GATE_CLEAR:ROLLBACK;clear_row<=0;
       if(!NO_UNDO)begin vibrato_depth<=saved_vibrato;phone_owned<=saved_phone_owned;end end
      else begin
       if(mutate && !NO_UNDO)undo_count<=undo_count+1'b1;
       if(allocate)begin
        if(PHONE_LOOKUP)phone_owned[slot_q]<=source==2 && phone_batch_live && session_ready;
        id_cursor<=following_id;allocation_count<=allocation_count+1'b1;
        id_skip_count<=id_skip_count+skips;if(wrapped)id_wrap_count<=id_wrap_count+1'b1;
        if(!victim_free)steal_count<=steal_count+1'b1;
       end
       if(stale)stale_count<=stale_count+1'b1;
       if(kind==4)vibrato_depth<=current_item[8:1];
       if(next_lane==9)state<=COMMIT;else lane<=next_lane;
      end
     end
    end
    COMMIT:begin state<=IDLE;undo_count<=0;end
    ROLLBACK:begin
     if(undo_count!=0)undo_count<=undo_count-1'b1;
     else begin state<=GATE_CLEAR;clear_row<=0;end
    end
    GATE_CLEAR:begin
     if(clear_row==3)begin state<=IDLE;panic_pending<=0;end else clear_row<=clear_row+1'b1;
    end
    INITIAL_IDENTITY:begin
     if(clear_row==3)state<=IDLE;else clear_row<=clear_row+1'b1;
    end
    PAN_READ:begin before_q<=store_query;state<=PAN_APPLY;end
    PAN_APPLY:state<=IDLE;
    LOOKUP_SCAN:begin if(clear_row==3)state<=LOOKUP_SELECT;else clear_row<=clear_row+1'b1;end
    LOOKUP_SELECT:begin
     lookup_found_q<=|lookup_matches;slot_q<=0;
     // Arbitrary match sets preserve first press match and last Pan match.
     for(integer s=0;s<32;s++)if(lookup_matches[lookup_pan_q?s:31-s])slot_q<=5'(lookup_pan_q?s:31-s);
     state<=LOOKUP_READ;
    end
    LOOKUP_READ:begin
     before_q<=store_query;state<=LOOKUP_REPLY;
     if(PHONE_LOOKUP==2)lookup_found_q<=lookup_key_q<32 && phone_owned[slot_q] &&
      store_query[1] && store_query[42:39]==2 && store_query[186:123]==lookup_identity_q &&
      store_query[58:43]==lookup_generation_q;
    end
    LOOKUP_REPLY:state<=IDLE;
    AUDIO_CLEAR:begin
     reclaim_frames[clear_row]<=frame_id;reclaim_subcycles[clear_row]<=subcycle;
     if(clear_row==3)begin state<=RECLAIM;reclaim_slot<=0;end else clear_row<=clear_row+1'b1;
    end
    RECLAIM:begin
     if(reclaim_fire)reclaim_count<=reclaim_count+1'b1;
     if(reclaim_slot==31)begin state<=IDLE;pending_reclaims<=0;end else reclaim_slot<=reclaim_slot+1'b1;
    end
    default:state<=IDLE;
   endcase
   // Flush also invalidates an in-flight transaction's restore image. A
   // later rollback or delayed response cannot revive the old session.
   if(flush_phone)begin phone_owned<=0;saved_phone_owned<=0;phone_batch_live<=0;lookup_cancelled<=1;end
  end
 end
 // One shared distance pipeline builds the circular 42-position window.
 // Before wrap, monotonic nonzero IDs cannot collide with existing voices.
 // After wrap the pre-scan reserves every live ID; subsequent events update
 // this window in program order, including clearing the evicted old ID.
 wire scan_identity=state==ID_SCAN && id_scan_cycle<32;
 wire distance_input_valid=scan_identity?store_query[1]:(collision_mode && allocate && before_q[1]);
 wire[63:0] distance_id=scan_identity?store_query[122:59]:before_q[122:59];
 reg[32:0] diff_lo,diff_hi,distance_low;
 reg distance_valid0,distance_valid1,distance_clear0,distance_clear1;
 reg distance_negative,distance_near;
 wire[32:0] corrected_hi=diff_hi-diff_lo[32];
 wire[5:0] distance_index=distance_low[5:0]-distance_negative;
 wire distance_commit=distance_valid1 && distance_near &&
  ((!distance_negative && distance_low<=41) || (distance_negative && distance_low>=1 && distance_low<=42));
 always @(posedge clk)begin
  if(rst)begin
   collision_mode<=0;id_scan_cycle<=0;batch_first_id<=1;id_occupied<=0;id_offset<=0;
   diff_lo<=0;diff_hi<=0;distance_low<=0;distance_valid0<=0;distance_valid1<=0;
   distance_clear0<=0;distance_clear1<=0;distance_negative<=0;distance_near<=0;
  end else begin
   distance_valid0<=distance_input_valid;distance_valid1<=distance_valid0;
   distance_clear0<=!scan_identity;distance_clear1<=distance_clear0;
   if(distance_input_valid)begin
    diff_lo<={1'b0,distance_id[31:0]}-{1'b0,batch_first_id[31:0]};
    diff_hi<={1'b0,distance_id[63:32]}-{1'b0,batch_first_id[63:32]};
   end
   if(distance_valid0)begin
    if(ID_WIDTH>32)begin
     distance_negative<=corrected_hi[ID_WIDTH-32];
     distance_near<=((corrected_hi & (33'h1ffffffff>>(64-ID_WIDTH)))==
      (corrected_hi[ID_WIDTH-32]?(33'd1<<(ID_WIDTH-32)):33'd0));
     distance_low<={1'b0,diff_lo[31:0]};
    end else begin
     distance_negative<=diff_lo[ID_WIDTH];distance_near<=1;
     distance_low<=diff_lo&{1'b0,ID_MAX[31:0]};
    end
   end
   if(distance_commit)id_occupied[distance_index]<=!distance_clear1;
   if(collision_mode && allocate)begin id_occupied[free_absolute]<=1;id_offset<=free_absolute+6'd1;end
   if(state==ID_SCAN)id_scan_cycle<=id_scan_cycle+6'd1;
   if(batch_begin)begin
    collision_mode<=collision_check;id_scan_cycle<=0;batch_first_id<=id_cursor;id_offset<=0;id_occupied<=0;
    distance_valid0<=0;distance_valid1<=0;
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst && allocate && collision_mode)begin
  if(!free_found || free_absolute>=42 || available_skip>32)$fatal(1,"R26_ID_WINDOW_EXHAUSTED");
 end
 // synthesis translate_on
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(audio_busy && busy)$fatal(1,"R18_EVENT_AUDIO_OWNERSHIP");
  if(audio_retire && state!=IDLE)$fatal(1,"R18_AUDIO_RETIRE_BUSY");
  if(mutate && undo_count>=9)$fatal(1,"R18_UNDO_CAPACITY");
  if(start_search && state!=IDLE && state!=ID_SCAN && !apply)$fatal(1,"R18_SEARCH_WITHOUT_EVENT");
  if(reading_snapshot && state!=IDLE && !(state==RUN && (phase==4 || phase==5 || phase==7)))$fatal(1,"R18_SNAPSHOT_READ_PORT_CONFLICT");
 end
 // synthesis translate_on
endmodule

// Fixed-frame audio/event ownership. The existing five-packet indexed FIFO
// retains its complete capacity and backpressure contract. A transaction is
// admitted only with enough time for every item and a complete abort unwind.
module r18_instrument_engine #(parameter integer NO_UNDO=0,INDEXED_INPUT=0,ID_WIDTH=64,PHONE_LOOKUP=0,CLK_FREQ_HZ=50_000_000)(
 input wire[95:0] indexed_item,input wire[2:0] indexed_occupancy,output wire[3:0] indexed_item_index,
 input wire session_flush,session_ready,input wire[575:0] event_phone_presses,
 input wire lookup_valid,lookup_pan,input wire[7:0] lookup_key,
 input wire[63:0] lookup_identity,input wire[15:0] lookup_generation,lookup_tag,
 output wire lookup_ready,lookup_response_valid,lookup_found,
 output wire[4:0] lookup_response_slot,output wire[314:0] lookup_response_word,
 output wire[15:0] lookup_response_tag,
 input wire clk,rst,sample_tick,panic,
 input wire event_valid,output wire event_ready,input wire[904:0] event_packet,
 input wire[2:0] timbre_id,input wire[3:0] glide_code,
 input wire[63:0] frame_id,input wire[15:0] subcycle,input wire[63:0] allocated_persistent_id,
 input wire snapshot_valid,snapshot_record_start,output wire snapshot_ready,
 input wire pan_valid,input wire[4:0] pan_slot,input wire[63:0] pan_id,
 input wire[15:0] pan_generation,input wire[8:0] pan_value,output wire pan_ready,
 output wire pan_response_valid,output wire[1:0] pan_result,
 output wire[4:0] pan_response_slot,output wire[314:0] pan_before,pan_after,
 output wire reclaim_batch_busy,
 input wire query_valid,query_snapshot,input wire[4:0] query_slot,output wire query_ready,
 output wire query_response_valid,output wire[4:0] query_response_slot,output wire[314:0] query_response_word,
 output wire mix_valid,output wire signed[31:0] mix_l_q8,mix_r_q8,
 output wire[543:0] envelope_levels,output wire[95:0] envelope_states,output wire[575:0] voice_samples,
 output wire protocol_error,deadline_error,output wire[2:0] queue_occupancy,
 output wire batch_begin,batch_publish,batch_abort,output wire[31:0] batch_timestamp,
 output wire fact_valid,output wire[3:0] fact_lane,output wire[95:0] fact_item,
 output wire[7:0] fact_outcome,output wire[5:0] fact_slot,output wire fact_steal,
 output wire[314:0] fact_before,fact_after,output wire[63:0] fact_frame,output wire[15:0] fact_subcycle,
 output wire identity_stable,output wire event_busy,audio_busy,
 output wire[31:0] control_valid,control_gate,
 output wire[991:0] control_state,output wire[3:0] batch_source
);
 localparam integer FRAME_MIN=CLK_FREQ_HZ/48000, EVENT_END=FRAME_MIN-8;
 reg[10:0] age;reg framed;reg boundary_error;
 // Control work is bounded even when a requester holds valid indefinitely.
 // Eleven cycles leave the final one-item packet's full cancellation reserve
 // intact in the dense 98-event frame. This bounds work, not valid inputs:
 // requesters retain unaccepted commands until a later frame grants them.
 // A validated lookup (8) followed by its Pan write (3) must fit together.
 localparam integer CONTROL_BUDGET=11;
 reg[3:0] control_used;
 wire allow_snapshot=control_used<=(snapshot_record_start?CONTROL_BUDGET-5:CONTROL_BUDGET-1);
 wire allow_pan=control_used<=CONTROL_BUDGET-3;
 wire allow_lookup=control_used<=CONTROL_BUDGET-8;
 // Pinned reads use idle RAM-port edges and never delay event service.
 // Only live queries spend the control work quota.
 wire allow_query=query_snapshot || control_used<CONTROL_BUDGET;
 wire event_snapshot_ready,event_pan_ready,event_lookup_ready,event_query_ready;
 assign snapshot_ready=event_snapshot_ready && allow_snapshot;
 assign pan_ready=event_pan_ready && allow_pan;
 assign lookup_ready=event_lookup_ready && allow_lookup;
 assign query_ready=event_query_ready && allow_query;
 always @(posedge clk)begin
  if(rst || sample_tick)control_used<=0;
  else if(snapshot_valid && snapshot_ready)control_used<=control_used+(snapshot_record_start?4'd5:4'd1);
  else if(pan_valid && pan_ready)control_used<=control_used+4'd3;
  else if(PHONE_LOOKUP && lookup_valid && lookup_ready)control_used<=control_used+4'd8;
  else if(query_valid && query_ready && !query_snapshot)control_used<=control_used+4'd1;
 end
 wire[10:0] remaining=framed && age<EVENT_END?11'(EVENT_END)-age:11'd0;
 wire available=framed && !audio_busy && age>=171 && age<EVENT_END;
 wire queue_valid,queue_ready;wire[904:0] queued_packet;wire[95:0] item;wire[3:0] item_index;
 wire[991:0] controls;wire[7:0] vibrato;wire[31:0] reclaim;
 wire[31:0] valid,gate,trigger,fresh;wire[223:0] notes;wire[255:0] pressures;
 wire[95:0] timbres;wire[287:0] pan;
 assign control_valid=valid;assign control_gate=gate;
 assign control_state=controls;assign batch_source=queued_packet[31:28];
 generate for(genvar s=0;s<32;s++)begin: control_view
  wire[30:0] word=controls[s*31+:31];
  assign fresh[s]=word[0];assign valid[s]=word[1];assign gate[s]=word[2];assign trigger[s]=word[3];
  assign pan[s*9+:9]=word[12:4];assign notes[s*7+:7]=word[19:13];
  assign pressures[s*8+:8]=word[27:20];assign timbres[s*3+:3]=word[30:28];
 end endgenerate
 assign indexed_item_index=item_index;
 generate if(INDEXED_INPUT)begin:indexed_input
  assign queue_valid=event_valid;assign event_ready=queue_ready;
  assign queued_packet=event_packet;assign item=indexed_item;assign queue_occupancy=indexed_occupancy;
 end else begin:legacy_input
 performance_indexed_event_queue queue(.clk(clk),.rst(rst),.s_valid(event_valid),.s_ready(event_ready),.s_data(event_packet),
  .m_valid(queue_valid),.m_ready(queue_ready),.m_data(queued_packet),.retire(batch_publish || batch_abort),
  .item_index(item_index),.item_data(item),.occupancy(queue_occupancy));
 end endgenerate
 r18_event_controller #(.NO_UNDO(NO_UNDO),.ID_WIDTH(ID_WIDTH),.PHONE_LOOKUP(PHONE_LOOKUP)) events(.clk(clk),.rst(rst),.panic(panic),
  .session_flush(session_flush),.session_ready(session_ready),.event_phone_presses(event_phone_presses),
  .lookup_valid(lookup_valid && allow_lookup),.lookup_pan(lookup_pan),.lookup_key(lookup_key),.lookup_identity(lookup_identity),
  .lookup_generation(lookup_generation),.lookup_tag(lookup_tag),.lookup_ready(event_lookup_ready),
  .lookup_response_valid(lookup_response_valid),.lookup_found(lookup_found),.lookup_response_slot(lookup_response_slot),
  .lookup_response_word(lookup_response_word),.lookup_response_tag(lookup_response_tag),
  .audio_busy(audio_busy || sample_tick),.audio_retire(mix_valid),.audio_reclaim(reclaim),.envelope_levels(envelope_levels),
  .window_open(available),.remaining_cycles(remaining),.event_valid(queue_valid),.event_ready(queue_ready),
  .event_header(queued_packet[904:864]),.event_item(item),.event_item_index(item_index),.timbre_id(timbre_id),
  .frame_id(frame_id),.subcycle(subcycle),.allocated_persistent_id(allocated_persistent_id),
  .snapshot_valid(snapshot_valid && allow_snapshot),.snapshot_record_start(snapshot_record_start),.snapshot_ready(event_snapshot_ready),
  .pan_valid(pan_valid && allow_pan),.pan_slot(pan_slot),.pan_id(pan_id),.pan_generation(pan_generation),.pan_value(pan_value),.pan_ready(event_pan_ready),
  .pan_response_valid(pan_response_valid),.pan_result(pan_result),.pan_response_slot(pan_response_slot),.pan_before(pan_before),.pan_after(pan_after),
  .reclaim_batch_busy(reclaim_batch_busy),.query_valid(query_valid && allow_query),.query_snapshot(query_snapshot),.query_slot(query_slot),
  .query_ready(event_query_ready),.query_response_valid(query_response_valid),.query_response_slot(query_response_slot),.query_response_word(query_response_word),
  .identity_stable(identity_stable),.busy(event_busy),.audio_controls(controls),.vibrato_depth(vibrato),.protocol_error(protocol_error),
  .batch_begin(batch_begin),.batch_publish(batch_publish),.batch_abort(batch_abort),.batch_timestamp(batch_timestamp),
  .fact_valid(fact_valid),.fact_lane(fact_lane),.fact_item(fact_item),.fact_outcome(fact_outcome),.fact_slot(fact_slot),.fact_steal(fact_steal),
  .fact_before(fact_before),.fact_after(fact_after),.fact_frame(fact_frame),.fact_subcycle(fact_subcycle),
  .allocation_count(),.steal_count(),.stale_count(),.reclaim_count(),.id_skip_count(),.id_wrap_count());
 wire audio_protocol,audio_deadline;
 r18_frame_audio audio(.clk(clk),.rst(rst),.start(sample_tick),.slot_valid(valid),.slot_gate(gate),.slot_trigger(trigger),.slot_fresh(fresh),
  .slot_notes(notes),.slot_pressures(pressures),.slot_timbres(timbres),.slot_pan(pan),.vibrato_depth(vibrato),.glide_code(glide_code),
  .busy(audio_busy),.mix_valid(mix_valid),.mix_l_q8(mix_l_q8),.mix_r_q8(mix_r_q8),
  .envelope_levels(envelope_levels),.envelope_states(envelope_states),.reclaim_pending(reclaim),.voice_samples(voice_samples),
  .completion_valid(),.completion_accept(),.completion_slot(),.completion_sample(),.protocol_error(audio_protocol),
  .deadline_error(audio_deadline),.last_complete_cycle());
 assign deadline_error=boundary_error || audio_deadline || audio_protocol;
 always @(posedge clk)begin
  if(rst)begin age<=0;framed<=0;boundary_error<=0;end
  else if(sample_tick)begin
   if(event_busy || audio_busy)boundary_error<=1;
   age<=0;framed<=1;
  end else if(framed && age<FRAME_MIN)age<=age+1'b1;
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(sample_tick && (event_busy || audio_busy))$fatal(1,"R18_FRAME_OWNERSHIP_DEADLINE");
  if(batch_begin && (!available || remaining<14))$fatal(1,"R18_BATCH_OUTSIDE_WINDOW");
  if(control_used>CONTROL_BUDGET)$fatal(1,"R18_CONTROL_FRAME_BUDGET");
 end
 // synthesis translate_on
endmodule

// Immutable execution facts -> original EVR cells and transaction protocol.
module r18_execution_observer(
 input wire clk,rst,audio_reset,start_valid,stop_valid,capture_fault,
 input wire[7:0] capture_fault_code,input wire stop_delivery_idle,
 input wire[63:0] start_record_id,frame_id,input wire[15:0] subcycle,
 input wire allocator_busy,batch_begin,publish_ok,batch_abort,input wire[31:0] batch_timestamp,
 input wire fact_valid,input wire[95:0] fact_item,input wire[7:0] fact_outcome,
 input wire[5:0] fact_slot,input wire fact_steal,input wire[314:0] fact_before,fact_after,
 input wire[63:0] fact_frame,input wire[15:0] fact_subcycle,input wire reclaim_batch_busy,
 input wire[31:0] slot_valid,slot_gate,
 output wire[63:0] allocated_persistent_id,
 output wire snapshot_query_valid,input wire snapshot_query_ready,output wire[4:0] snapshot_query_slot,
 input wire snapshot_response_valid,input wire[4:0] snapshot_response_slot,input wire[314:0] snapshot_response_word,
 output reg active,arming,incomplete,output reg[7:0] error_code,output reg[63:0] first_missing_frame,
 output wire tx_valid,output reg[5:0] tx_count,input wire[5:0] tx_index,output wire[255:0] tx_cell,
 input wire tx_read_valid,input wire[15:0] tx_read_epoch,
 output reg tx_response_valid,output reg[5:0] tx_response_index,output reg[15:0] tx_response_epoch,
 input wire tx_ready,tx_done,output reg[31:0] published_batches,aborted_batches,applied_items,initial_instances,
 output reg[63:0] persistent_id_next,output wire observer_idle
);
 // EVR2 records actual musical operations. No runtime/token binding, audit
 // expansion, reclaim ranking or recording-owned identity directory.
 function automatic [63:0] voice_tag(input [4:0] slot,input [15:0] gen);
  voice_tag={42'd0,1'b1,gen,slot};
 endfunction
 function automatic [63:0] payload(input [15:0] sc,input [314:0] w,input [4:0] slot);
  payload={slot,w[58:43],w[12:4],w[30:28],w[27:20],w[19:13],sc};
 endfunction
 function automatic [223:0] cell_data(input [7:0] typ,flags,src,key,input [63:0] fr,id,p);
  cell_data={p,id,fr,key,src,flags,typ};
 endfunction
 reg [223:0] events[0:8] /* synthesis syn_ramstyle="distributed_ram" */;
 reg [3:0] count; reg tracking,pending,inflight,stop_pending;
 reg [1:0] owner;reg [223:0] terminal;
 reg [31:0] initial_mask;reg [5:0] snap_index;
 reg [58:0] snap_word;reg snap_loaded,snap_wait;
 reg [63:0] snap_frame;reg [15:0] snap_subcycle;
 reg [223:0] response;
 wire starting=start_valid && !active && !arming && !pending && !inflight && !allocator_busy && start_record_id!=0;
 wire musical=fact_valid && fact_outcome>=1 && fact_outcome<=4;
 wire capture=(active||stop_pending)&&tracking&&musical&&!batch_abort;
 wire [7:0] typ=fact_outcome==1?8'd4:fact_outcome==2?8'd5:fact_outcome==3?8'd6:8'd7;
 wire [314:0] before_or_after=fact_outcome==1?fact_after:fact_before;
 wire [63:0] tag=fact_slot<32?{42'd0,1'b1,before_or_after[58:43],fact_slot[4:0]}:64'd0;
 wire [63:0] body=fact_outcome==4?{40'd0,fact_item[8:1],fact_subcycle}:
  {fact_slot[4:0],before_or_after[58:43],before_or_after[12:4],before_or_after[30:28],fact_item[8:1],fact_item[15:9],fact_subcycle};
 assign allocated_persistent_id=64'd0;
 assign observer_idle=!active&&!arming&&!pending&&!inflight&&!tracking&&!stop_pending;
 assign tx_valid=!inflight && !incomplete && (arming?(snap_index==0||snap_loaded):pending);
 always @* tx_count=arming || (inflight&&owner==1)?6'd1:{2'd0,count}+6'd1;
 assign snapshot_query_valid=arming&&snap_index>0&&!snap_loaded&&!snap_wait&&!incomplete;
 assign snapshot_query_slot=snap_index-1'b1;
 reg [5:0] next_snapshot;
 always @*begin
  next_snapshot=33;
  for(integer i=31;i>=0;i--)if(initial_mask[i]&&i+1>snap_index)next_snapshot=i+1;
 end
 always @(posedge clk)begin
  if(rst)begin tx_response_valid<=0;tx_response_index<=0;tx_response_epoch<=0;end
  else begin
   tx_response_valid<=tx_read_valid;
   if(tx_read_valid)begin
    tx_response_index<=tx_index;tx_response_epoch<=tx_read_epoch;
    if(arming || (inflight&&owner==1))begin
     if(snap_index==0)response<=cell_data(1,3,255,255,snap_frame,0,{48'd0,snap_subcycle});
     else response<=cell_data(8,snap_word[2]?8'd3:8'd19,{4'd0,snap_word[42:39]},snap_word[38:31],snap_frame,
       {42'd0,1'b1,snap_word[58:43],snapshot_query_slot},{snapshot_query_slot,snap_word[58:43],snap_word[12:4],snap_word[30:28],snap_word[27:20],snap_word[19:13],snap_subcycle});
    end else response<=tx_index<count?events[tx_index]:terminal;
   end
  end
 end
 assign tx_cell={response[223:32],32'd0,response[31:0]};
 always @(posedge clk)if(!rst&&capture&&count<9)
  events[count]<=cell_data(typ,fact_steal?8'd32:8'd0,{4'd0,fact_item[31:28]},fact_item[23:16],fact_frame,tag,body);
 always @(posedge clk)begin
  if(rst)begin
   active<=0;arming<=0;incomplete<=0;error_code<=0;first_missing_frame<=64'hffffffffffffffff;
   count<=0;tracking<=0;pending<=0;inflight<=0;stop_pending<=0;owner<=0;
   initial_mask<=0;snap_index<=0;snap_loaded<=0;snap_wait<=0;snap_frame<=0;snap_subcycle<=0;
   published_batches<=0;aborted_batches<=0;applied_items<=0;initial_instances<=0;persistent_id_next<=0;
  end else begin
   if(snapshot_query_valid&&snapshot_query_ready)snap_wait<=1;
   if(snapshot_response_valid&&snap_wait&&snapshot_response_slot==snapshot_query_slot)begin
    snap_word<=snapshot_response_word[58:0];snap_wait<=0;snap_loaded<=1;
   end
   if(tx_valid&&tx_ready)begin inflight<=1;owner<=arming?1:2;end
   if(tx_done&&inflight)begin
    inflight<=0;
    if(owner==1)begin
     snap_loaded<=0;snap_wait<=0;snap_index<=next_snapshot;
     if(next_snapshot==49)arming<=0;
    end else begin pending<=0;count<=0;end
   end
   if(starting)begin
    active<=1;arming<=1;incomplete<=0;error_code<=0;first_missing_frame<=64'hffffffffffffffff;
    initial_mask<=slot_valid;snap_frame<=frame_id;snap_subcycle<=subcycle;snap_index<=0;snap_loaded<=0;snap_wait<=0;
    count<=0;tracking<=batch_begin;pending<=0;stop_pending<=0;
   end
   if(active&&batch_begin)begin
    if(pending||(inflight&&owner==2))begin incomplete<=1;error_code<=2;active<=0;end
    else begin tracking<=1;count<=0;end
   end
   if(capture)begin
    if(count<9)begin count<=count+1'b1;applied_items<=applied_items+1'b1;end
    else begin incomplete<=1;error_code<=2;active<=0;end
   end
   if((active||stop_pending)&&tracking&&publish_ok)begin
    terminal<=cell_data(25,1,255,255,frame_id,0,{16'd0,batch_timestamp,subcycle});
    pending<=1;tracking<=0;published_batches<=published_batches+1'b1;
   end
   if(batch_abort&&(active||arming||pending||inflight||stop_pending))begin
    incomplete<=1;error_code<=8'd5;active<=0;first_missing_frame<=frame_id;
   end
   if(batch_abort&&tracking)begin count<=0;tracking<=0;aborted_batches<=aborted_batches+1'b1;end
   if(stop_valid&&active)begin active<=0;stop_pending<=1;end
   if(stop_pending&&stop_delivery_idle&&!pending&&!inflight&&!arming&&!tracking)begin
    terminal<=cell_data(22,1,255,255,frame_id,0,{48'd0,subcycle});count<=0;pending<=1;stop_pending<=0;
   end
   if((capture_fault||audio_reset)&&(active||arming||pending||inflight||stop_pending))begin
    incomplete<=1;error_code<=audio_reset?8'd5:capture_fault_code;active<=0;
   end
   // Finish an accepted RAM transaction, then abandon only unpublished data.
   if(incomplete&&!inflight&&!starting)begin active<=0;arming<=0;pending<=0;tracking<=0;stop_pending<=0;count<=0;snap_wait<=0;end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(tx_read_valid&&tx_index>=tx_count)$fatal(1,"R25_EXEC_INDEX");
  if(capture&&count>=9)$display("R25_EXEC_OVERFLOW");
  if(snapshot_response_valid&&snap_wait&&snapshot_response_slot!=snapshot_query_slot)$fatal(1,"R25_SNAPSHOT_SLOT");
 end
 // synthesis translate_on




endmodule

// Audio, event/control ownership, pinned START snapshot and immutable EXEC
// facts in one parent. Only narrow slot queries cross the identity boundary.
module r18_recorded_engine #(parameter integer ID_WIDTH=64,PHONE_LOOKUP=1,CLK_FREQ_HZ=50_000_000)(
 input wire session_flush,session_ready,input wire[575:0] event_phone_presses,
 input wire lookup_valid,lookup_pan,input wire[7:0] lookup_key,
 input wire[63:0] lookup_identity,input wire[15:0] lookup_generation,lookup_tag,
 output wire lookup_ready,lookup_response_valid,lookup_found,
 output wire[4:0] lookup_response_slot,output wire[314:0] lookup_response_word,
 output wire[15:0] lookup_response_tag,
 input wire clk,rst,sample_tick,panic,audio_reset,
 input wire event_valid,output wire event_ready,input wire[904:0] event_packet,
 input wire[2:0] timbre_id,input wire[3:0] glide_code,input wire[63:0] frame_id,input wire[15:0] subcycle,
 input wire record_start_valid,output wire record_start_ready,input wire[63:0] record_id,
 input wire record_stop_valid,capture_fault,input wire[7:0] capture_fault_code,input wire stop_delivery_idle,
 output wire record_active,record_arming,record_incomplete,output wire[7:0] record_error,
 output wire[63:0] first_missing_frame,output wire record_idle,
 input wire query_valid,input wire[4:0] query_slot,output wire query_ready,
 output wire query_response_valid,output wire[4:0] query_response_slot,output wire[314:0] query_response_word,
 input wire pan_valid,input wire[4:0] pan_slot,input wire[63:0] pan_id,input wire[15:0] pan_generation,
 input wire[8:0] pan_value,output wire pan_ready,pan_response_valid,output wire[1:0] pan_result,
 output wire[4:0] pan_response_slot,output wire[314:0] pan_before,pan_after,
 output wire mix_valid,output wire signed[31:0] mix_l_q8,mix_r_q8,
 output wire[543:0] envelope_levels,output wire[95:0] envelope_states,output wire[575:0] voice_samples,
 output wire protocol_error,deadline_error,output wire[2:0] queue_occupancy,
 output wire batch_begin,batch_publish,batch_abort,output wire[31:0] batch_timestamp,
 output wire fact_valid,output wire[3:0] fact_lane,output wire[95:0] fact_item,
 output wire[7:0] fact_outcome,output wire[5:0] fact_slot,output wire fact_steal,
 output wire[314:0] fact_before,fact_after,output wire[63:0] fact_frame,output wire[15:0] fact_subcycle,
 output wire identity_stable,event_busy,audio_busy,
 output wire tx_valid,output wire[5:0] tx_count,input wire[5:0] tx_index,output wire[255:0] tx_cell,
 input wire tx_read_valid,input wire[15:0] tx_read_epoch,input wire tx_ready,tx_done,
 output wire tx_response_valid,output wire[5:0] tx_response_index,output wire[15:0] tx_response_epoch
);
 wire engine_snapshot_ready,snapshot_query_valid,snapshot_query_ready,engine_query_ready,engine_response_valid;
 wire[4:0] snapshot_query_slot,engine_response_slot;wire[314:0] engine_response_word;
 wire[63:0] allocated_pid;wire[31:0] valid,gate;wire reclaim_busy;
 reg response_snapshot;
 assign record_start_ready=record_idle && engine_snapshot_ready && record_id!=0;
 wire start=record_start_valid && record_start_ready;
 assign snapshot_query_ready=engine_query_ready;
 assign query_ready=engine_query_ready && !snapshot_query_valid;
 assign query_response_valid=engine_response_valid && !response_snapshot;
 assign query_response_slot=engine_response_slot;assign query_response_word=engine_response_word;
 always @(posedge clk)begin
  if(rst)response_snapshot<=0;
  else if(engine_query_ready && (snapshot_query_valid || query_valid))response_snapshot<=snapshot_query_valid;
 end
 r18_instrument_engine #(.ID_WIDTH(ID_WIDTH),.PHONE_LOOKUP(PHONE_LOOKUP),.CLK_FREQ_HZ(CLK_FREQ_HZ)) core(.clk(clk),.rst(rst),.sample_tick(sample_tick),.panic(panic),
  .session_flush(session_flush),.session_ready(session_ready),.event_phone_presses(event_phone_presses),
  .lookup_valid(lookup_valid),.lookup_pan(lookup_pan),.lookup_key(lookup_key),.lookup_identity(lookup_identity),
  .lookup_generation(lookup_generation),.lookup_tag(lookup_tag),.lookup_ready(lookup_ready),
  .lookup_response_valid(lookup_response_valid),.lookup_found(lookup_found),.lookup_response_slot(lookup_response_slot),
  .lookup_response_word(lookup_response_word),.lookup_response_tag(lookup_response_tag),
  .event_valid(event_valid),.event_ready(event_ready),.event_packet(event_packet),.timbre_id(timbre_id),.glide_code(glide_code),
  .frame_id(frame_id),.subcycle(subcycle),.allocated_persistent_id(allocated_pid),
  .snapshot_valid(record_start_valid && record_idle && record_id!=0),.snapshot_record_start(1'b0),.snapshot_ready(engine_snapshot_ready),
  .pan_valid(pan_valid),.pan_slot(pan_slot),.pan_id(pan_id),.pan_generation(pan_generation),.pan_value(pan_value),.pan_ready(pan_ready),
  .pan_response_valid(pan_response_valid),.pan_result(pan_result),.pan_response_slot(pan_response_slot),.pan_before(pan_before),.pan_after(pan_after),
  .reclaim_batch_busy(reclaim_busy),.query_valid(snapshot_query_valid || query_valid),.query_snapshot(snapshot_query_valid),
  .query_slot(snapshot_query_valid?snapshot_query_slot:query_slot),.query_ready(engine_query_ready),
  .query_response_valid(engine_response_valid),.query_response_slot(engine_response_slot),.query_response_word(engine_response_word),
  .mix_valid(mix_valid),.mix_l_q8(mix_l_q8),.mix_r_q8(mix_r_q8),.envelope_levels(envelope_levels),.envelope_states(envelope_states),.voice_samples(voice_samples),
  .protocol_error(protocol_error),.deadline_error(deadline_error),.queue_occupancy(queue_occupancy),
  .batch_begin(batch_begin),.batch_publish(batch_publish),.batch_abort(batch_abort),.batch_timestamp(batch_timestamp),
  .fact_valid(fact_valid),.fact_lane(fact_lane),.fact_item(fact_item),.fact_outcome(fact_outcome),.fact_slot(fact_slot),.fact_steal(fact_steal),
  .fact_before(fact_before),.fact_after(fact_after),.fact_frame(fact_frame),.fact_subcycle(fact_subcycle),
  .identity_stable(identity_stable),.event_busy(event_busy),.audio_busy(audio_busy),.control_valid(valid),.control_gate(gate));
 r18_execution_observer exec(.clk(clk),.rst(rst),.audio_reset(audio_reset),.start_valid(start),.stop_valid(record_stop_valid),
  .capture_fault(capture_fault),.capture_fault_code(capture_fault_code),.stop_delivery_idle(stop_delivery_idle),
  .start_record_id(record_id),.frame_id(frame_id),.subcycle(subcycle),.allocator_busy(!identity_stable),
  .batch_begin(batch_begin),.publish_ok(batch_publish),.batch_abort(batch_abort),.batch_timestamp(batch_timestamp),
  .fact_valid(fact_valid),.fact_item(fact_item),.fact_outcome(fact_outcome),.fact_slot(fact_slot),.fact_steal(fact_steal),
  .fact_before(fact_before),.fact_after(fact_after),.fact_frame(fact_frame),.fact_subcycle(fact_subcycle),.reclaim_batch_busy(reclaim_busy),
  .slot_valid(valid),.slot_gate(gate),.allocated_persistent_id(allocated_pid),
  .snapshot_query_valid(snapshot_query_valid),.snapshot_query_ready(snapshot_query_ready),.snapshot_query_slot(snapshot_query_slot),
  .snapshot_response_valid(engine_response_valid && response_snapshot),.snapshot_response_slot(engine_response_slot),.snapshot_response_word(engine_response_word),
  .active(record_active),.arming(record_arming),.incomplete(record_incomplete),.error_code(record_error),.first_missing_frame(first_missing_frame),
  .tx_valid(tx_valid),.tx_count(tx_count),.tx_index(tx_index),.tx_cell(tx_cell),.tx_read_valid(tx_read_valid),.tx_read_epoch(tx_read_epoch),
  .tx_response_valid(tx_response_valid),.tx_response_index(tx_response_index),.tx_response_epoch(tx_response_epoch),.tx_ready(tx_ready),.tx_done(tx_done),
  .published_batches(),.aborted_batches(),.applied_items(),.initial_instances(),.persistent_id_next(),.observer_idle(record_idle));
endmodule

// Passive configuration journal. Initial values are cloned on START; later
// records describe real parameter state changes and actual engine edges.
// Fourteen cells include the immutable in-flight prefix: appending does not
// change a transaction already reserved by the EVR RAM writer.
module r18_config_observer #(parameter integer SYNC_READ=1)(
 input wire clk,rst,start,stop,recording,capture_fault,
 input wire [63:0] frame_id,input wire [15:0] subcycle,
 input wire [2:0] timbre_id,input wire [3:0] glide_code,
 input wire [55:0] keymap,input wire [31:0] keymap_version,
 input wire [351:0] fx_config,input wire [31:0] fx_version,
 input wire gain_cfg_valid,input wire [15:0] gain_local,gain_external,
 input wire gain_local_mute,gain_external_mute,
 input wire [31:0] gain_accepted,gain_frame,gain_version,
 input wire gain_sample,input wire [15:0] gain_current_l,gain_current_e,
 input wire [6:0] gain_remaining,input wire [103:0] gain_state,
 input wire pan_valid,input wire[4:0] pan_slot,
 input wire[314:0] pan_before,pan_after,
 input wire [2:0] stream_state,input wire [31:0] stream_generation,
 input wire [63:0] media_epoch,
 output wire tx_valid,output reg [5:0] tx_count,input wire [5:0] tx_index,output wire [255:0] tx_cell,
 input wire tx_read_valid,input wire [15:0] tx_read_epoch,
 output reg tx_response_valid,output reg [5:0] tx_response_index,output reg [15:0] tx_response_epoch,
 input wire tx_ready,tx_done,
 output reg fault_valid,output reg [63:0] first_missing_frame,
 output wire [7:0] fault_code,output wire idle,output wire capture_quiet
);
 wire r54_equal_0;
 wire r54_equal_1;
 wire r54_equal_2;
 wire r54_equal_3;
 wire r54_equal_4;

 localparam TIMBRE=14,GLIDE=15,PAN=16,EFFECTS=17,GAIN=18,KEYMAP=19,MEDIA=20,EXT=21;
 function [255:0] make_cell;
  input [7:0] typ,flags;input [63:0] frame,note,payload;
  begin make_cell={payload,note,frame,32'd0,8'hff,8'hff,flags,typ};end
 endfunction
 function [255:0] snapshot_cell;
  input integer which;input [811:0] s;input [63:0] fr;input [15:0] sc;
  reg [63:0] p;reg [7:0] typ;reg [3:0] phase;
  begin
   p=0;typ=EXT;phase=4;
   case(which)
    0:begin typ=TIMBRE;p={45'd0,s[2:0],sc};end
    1:begin typ=GLIDE;p={44'd0,s[6:3],sc};end
    2:begin typ=KEYMAP;p={8'd0,s[62:7]};end
    3:p={16'd0,s[94:63],sc};
    4:begin typ=GAIN;p={2'd0,phase,s[648],s[647:641],s[512:511],s[510:495],s[494:479],sc};end
    5:p={s[576:561],s[560:545],s[544:529],s[528:513]};
    6:p={s[680:649],s[640:609]};
    7:p={s[712:681],32'd0};
    8:begin typ=EFFECTS;p=s[158:95];end
    9:p=s[222:159];
    10:p=s[286:223];
    11:p=s[350:287];
    12:p=s[414:351];
    13:p={s[478:447],s[446:415]};
    14:begin typ=MEDIA;p={13'd0,s[747:716],s[715:713],sc};end
    15:p=s[811:748];
   endcase
   snapshot_cell=make_cell(typ,8'd2,fr,0,p);
  end
 endfunction
 // Musical configuration journal: one immutable pending change per producer.
 // A seven-bit mask FIFO preserves capture order; payloads are never replaced.

 reg [811:0] initial_state;reg [63:0] initial_frame;reg [15:0] initial_subcycle;
 reg initial_pending,inflight;reg [3:0] selected;
 reg [6:0] occupied,masks[0:7];reg [2:0] head,tail;reg [3:0] groups_used;
 reg [383:0] values[0:6];reg [63:0] times[0:6];reg [15:0] offsets[0:6];
 reg [63:0] pan_tag;reg [2:0] previous_timbre;reg [3:0] previous_glide;
 reg [31:0] previous_key,previous_fx,previous_gain,previous_stream;
 reg [63:0] previous_epoch,previous_frame;reg [15:0] previous_subcycle;
 reg [2:0] previous_state;reg [15:0] user_l,user_e;reg [1:0] user_mute;
 wire [811:0] live_state={media_epoch,stream_generation,stream_state,gain_frame,gain_accepted,
  gain_state,gain_current_e,gain_current_l,user_mute,user_e,user_l,
  fx_version,fx_config,keymap_version,keymap,glide_code,timbre_id};
 wire collect=recording&&!fault_valid&&!capture_fault&&!start;
 wire [6:0] changes={((recording||start)&&!stop&&pan_valid&&(!fault_valid||start)&&(!capture_fault||start)),
  collect&&(stream_state!=previous_state||!r54_equal_0||!r54_equal_1),
  collect&&(!r54_equal_2),collect&&(!r54_equal_3),
  collect&&(!r54_equal_4),collect&&(glide_code!=previous_glide),collect&&(timbre_id!=previous_timbre)};
 wire [6:0] front=masks[head];reg [2:0] first;
 always @*begin first=0;for(integer i=6;i>=0;i--)if(front[i])first=i;end
 wire [3:0] current=inflight?selected:initial_pending?4'd7:{1'b0,first};
 wire [6:0] removed=tx_done&&inflight&&selected<7?(7'd1<<selected):7'd0;
 wire pop=(|removed)&&((front&~removed)==0);
 wire collision=|(changes&(occupied&~removed));
 wire push=(|changes)&&(!collision||start)&&!rst;
 assign tx_valid=!fault_valid&&!capture_fault&&!inflight&&(initial_pending||groups_used!=0);
 assign idle=!inflight&&!initial_pending&&groups_used==0;
 assign capture_quiet=idle&&!(|changes);
 assign fault_code=8'd2;
 reg [255:0] response_cell,encoded;reg [63:0] part;reg [7:0] typ;
 always @*begin
  case(current) 7:tx_count=16;2:tx_count=2;3:tx_count=6;5:tx_count=2;default:tx_count=1;endcase
  part=0;typ=EXT;encoded=0;
  if(current==7)encoded=snapshot_cell(tx_index,initial_state,initial_frame,initial_subcycle);
  else begin
   case(current)
    0:begin typ=TIMBRE;part={45'd0,values[0][2:0],offsets[0]};end
    1:begin typ=GLIDE;part={44'd0,values[1][3:0],offsets[1]};end
    2:begin typ=tx_index==0?KEYMAP:EXT;part=tx_index==0?{8'd0,values[2][87:32]}:{16'd0,values[2][31:0],offsets[2]};end
    3:begin typ=tx_index==0?EFFECTS:EXT;part=values[3][tx_index*64+:64];end
    4:begin typ=GAIN;part={16'd0,values[4][31:0],offsets[4]};end
    5:begin typ=tx_index==0?MEDIA:EXT;part=tx_index==0?{13'd0,values[5][34:0],offsets[5]}:values[5][98:35];end
    6:begin typ=PAN;part={values[6][29:0],18'd0,offsets[6]};end
   endcase
   encoded=make_cell(typ,0,times[current],current==6?pan_tag:64'd0,part);
  end
  encoded[8]=(tx_index==tx_count-1'b1);
 end
 assign tx_cell=response_cell;
 always @(posedge clk)begin
  if(rst)begin tx_response_valid<=0;tx_response_index<=0;tx_response_epoch<=0;end
  else begin tx_response_valid<=tx_read_valid;
   if(tx_read_valid)begin response_cell<=encoded;tx_response_index<=tx_index;tx_response_epoch<=tx_read_epoch;end
  end
 end
 always @(posedge clk)begin
  if(rst)begin
   initial_pending<=0;inflight<=0;selected<=0;occupied<=0;head<=0;tail<=0;groups_used<=0;
   fault_valid<=0;first_missing_frame<=64'hffffffffffffffff;
   previous_timbre<=0;previous_glide<=0;previous_key<=0;previous_fx<=0;previous_gain<=0;
   previous_state<=0;previous_stream<=0;previous_epoch<=0;previous_frame<=0;previous_subcycle<=0;
   user_l<=32768;user_e<=32768;user_mute<=0;
  end else begin
   previous_timbre<=timbre_id;previous_glide<=glide_code;previous_key<=keymap_version;previous_fx<=fx_version;
   previous_gain<=gain_version;previous_state<=stream_state;previous_stream<=stream_generation;previous_epoch<=media_epoch;
   previous_frame<=frame_id;previous_subcycle<=subcycle;
   if(gain_cfg_valid&&gain_local<=32768&&gain_external<=32768)begin user_l<=gain_local;user_e<=gain_external;user_mute<={gain_external_mute,gain_local_mute};end
   if(tx_valid&&tx_ready)begin inflight<=1;selected<=current;end
   if(tx_done&&inflight)begin
    inflight<=0;if(selected==7)initial_pending<=0;
    else begin masks[head]<=front&~removed;if(pop)head<=head+1'b1;end
   end
   occupied<=(occupied&~removed)|(push?changes:7'd0);
   groups_used<=groups_used+(push?4'd1:4'd0)-(pop?4'd1:4'd0);
   if(push)begin masks[tail]<=changes;tail<=tail+1'b1;end
   if(collision&&!start)fault_valid<=1;
   if(capture_fault)fault_valid<=1;
   if(start)begin
    initial_state<=live_state;initial_frame<=frame_id;initial_subcycle<=subcycle;initial_pending<=1;inflight<=0;
    fault_valid<=0;first_missing_frame<=64'hffffffffffffffff;occupied<=changes;head<=0;tail<=push?1:0;groups_used<=push?1:0;
    if(push)masks[0]<=changes;
   end
   if(fault_valid&&!inflight&&!start)begin initial_pending<=0;groups_used<=0;occupied<=0;head<=0;tail<=0;end
  end
 end
 generate for(genvar g=0;g<7;g++)begin: capture_fields
  always @(posedge clk)if(push&&changes[g])begin
   times[g]<=g==6?frame_id:previous_frame;offsets[g]<=g==6?subcycle:previous_subcycle;
   case(g)
    0:values[g]<={381'd0,timbre_id};
    1:values[g]<={380'd0,glide_code};
    2:values[g]<={296'd0,keymap,keymap_version};
    3:values[g]<={fx_version,fx_config};
    4:values[g]<={352'd0,gain_state[31:0]};
    5:values[g]<={285'd0,media_epoch,stream_generation,stream_state};
    6:values[g]<={354'd0,pan_slot,pan_after[58:43],pan_after[12:4]};
   endcase
  end
 end endgenerate
 always @(posedge clk)if(push&&changes[6])pan_tag<={42'd0,1'b1,pan_after[58:43],pan_slot};
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(tx_read_valid&&tx_index>=tx_count)$fatal(1,"R25_CFG_INDEX");
  if(groups_used>7)$fatal(1,"R25_CFG_MASK_QUEUE");
 end
 // synthesis translate_on

 r54_full_equal #(.WIDTH(32)) r54_equal_0_tree(.a(stream_generation),.b(previous_stream),.equal(r54_equal_0));
 r54_full_equal #(.WIDTH(64)) r54_equal_1_tree(.a(media_epoch),.b(previous_epoch),.equal(r54_equal_1));
 r54_full_equal #(.WIDTH(32)) r54_equal_2_tree(.a(gain_version),.b(previous_gain),.equal(r54_equal_2));
 r54_full_equal #(.WIDTH(32)) r54_equal_3_tree(.a(fx_version),.b(previous_fx),.equal(r54_equal_3));
 r54_full_equal #(.WIDTH(32)) r54_equal_4_tree(.a(keymap_version),.b(previous_key),.equal(r54_equal_4));
endmodule

// Stage9 parameter adapter. Frozen parameter engines retain their arithmetic.
// COMMITTED follows the real configuration edge; EFFECTIVE names an observed
// snapshot frame. It never asserts that a muted/cancelled sound was audible.
module r18_config_bridge #(parameter integer ENABLE_FIELD=0, DEFER_RESULT_CRC=0)(
 input wire config_payload_changed,
 output wire id_req_valid,id_req_pan,input wire id_req_ready,
 output wire[7:0] id_req_key,output wire[63:0] id_req_identity,
 output wire[15:0] id_req_generation,id_req_tag,
 input wire id_response_valid,id_response_found,input wire[4:0] id_response_slot,
 input wire[314:0] id_response_word,input wire[15:0] id_response_tag,
 input wire pan_ready,pan_response_valid,input wire[1:0] pan_result,
 input wire[4:0] pan_response_slot,input wire[314:0] pan_response_before,pan_response_after,
 input wire fact_valid,input wire[7:0] fact_outcome,input wire[5:0] fact_slot,
 input wire clk,rst,session_flush,session_ready,input wire[127:0] session_id,
 input wire config_valid,output wire config_ready,input wire[2:0] config_slot,input wire[1535:0] config_bytes,
 input wire sample_tick,input wire[31:0] sample_time,now_ms,
 input wire[3:0] local_glide_code,output reg[3:0] glide_code,output reg[2:0] timbre_id,
 output wire fx_cfg_valid,output wire[351:0] fx_cfg_data,
 input wire[31:0] fx_accepted,fx_frame_version,
 output wire gain_cfg_valid,output wire[15:0] gain_local,gain_external,
 output wire gain_local_mute,gain_external_mute,
 input wire gain_sample,input wire[31:0] gain_frame,gain_frame_version,gain_accepted,
 input wire[15:0] gain_l,gain_e,input wire[6:0] gain_remaining,
 output wire pan_valid,output wire[4:0] pan_slot,output wire[63:0] pan_id,
 output wire[15:0] pan_generation,output wire[8:0] pan_value,
 input wire identity_stable,
 input wire[7:0] local_gate,input wire local_pending,output wire[55:0] keymap,
 output wire[31:0] keymap_version,
 output wire field_valid,field_start,output wire[2:0] field_size,
 input wire field_ready,field_active,field_rejected,field_committed,field_running,
 output wire lookup_valid,input wire lookup_ready,output wire lookup_channel,lookup_echo,
 output wire[31:0] lookup_sequence,input wire lookup_done,input wire signed[15:0] lookup_error,input wire[511:0] lookup_result,
 output reg result_valid,input wire result_ready,output reg[2:0] result_slot,
 output wire[31:0] result_sequence,output wire[511:0] result_bytes,output reg result_final
);
 // 0 immediate,1 Glide,2 Pan,3 Effects,4 Gain,5 keymap,6 query/barrier.
 reg[6:0] valid,dirty;
 reg[31:0] seq[0:6],frame[0:6],version[0:6];reg[2:0] slot[0:6],phase[0:6];
 reg signed[15:0] error[0:6];
 reg[63:0] held_pan_id,reply_id;reg[15:0] held_pan_generation,reply_generation;
 reg[4:0] held_pan_slot;reg[8:0] held_pan_value;
 reg[15:0] target_l,target_e;reg[3:0] previous_local_glide;
 reg tick_d,pan_defer_snapshot;reg[31:0] tick_frame;
 reg lookup_busy,lookup_is_query,lookup_is_instance,lookup_ch;
 reg[2:0] lookup_required;reg[31:0] lookup_seq,lookup_polled_ms;
 reg[2:0] result_index,cursor;
 reg[255:0] result_fields;reg[7:0] result_flags;
 reg hello_pending,field_pending,field_target_start;reg[70:0] hello_snapshot;
 wire[7:0] opcode=config_bytes[55:48];wire[31:0] command_sequence=config_bytes[223:192];
 reg[2:0] index;integer i;
 always @*begin
  case(opcode)33:index=1;34:index=2;35:index=3;36:index=4;37:index=5;4,39,40:index=6;default:index=0;endcase
 end
 wire map_accepted,map_rejected,map_applied,map_cancelled,map_pending;
 wire[31:0] map_applied_sequence,map_cancelled_sequence;wire[2:0] map_applied_slot,map_cancelled_slot;
 wire local_idle=local_gate==0&&!local_pending;
 wire replace_gain=index==4&&valid[4]&&phase[4]<5;
 wire replace_map=index==5&&valid[5]&&phase[5]==3&&map_pending&&!local_idle;
 wire replaceable=config_valid&&(replace_gain||replace_map)&&!result_valid;
 wire identity_needed=opcode==34||opcode==39;
 wire command_available=!rst&&!session_flush&&session_ready&&(!valid[index]||replaceable);
 reg id_wait,id_prepared,id_found;reg[4:0] id_slot;reg[314:0] id_word;
 reg[15:0] id_serial,id_active_tag;reg pan_watch_valid;
 assign id_req_valid=config_valid&&!config_payload_changed&&command_available&&identity_needed&&!id_wait&&!id_prepared;
 assign id_req_pan=opcode==34;assign id_req_key=config_bytes[263:256];
 assign id_req_identity=opcode==34?config_bytes[319:256]:config_bytes[327:264];
 assign id_req_generation=config_bytes[335:320];assign id_req_tag=id_serial;
 assign config_ready=command_available&&(!identity_needed||(identity_stable&&id_prepared))&&
  (opcode!=34||!id_found||pan_ready)&&(opcode!=86||!ENABLE_FIELD||field_ready);
 wire[63:0] query_id=id_found?id_word[122:59]:64'd0;
 wire[15:0] query_generation=id_found?id_word[58:43]:16'd0;
 wire query_found=id_found,commit_pan_found=id_found;
 always @(posedge clk)begin
  if(rst)begin id_wait<=0;id_prepared<=0;id_found<=0;id_slot<=0;id_word<=0;id_serial<=0;id_active_tag<=0;end
  else begin
   if(!identity_stable)id_prepared<=0;
   if(id_req_valid&&id_req_ready)begin id_wait<=1;id_active_tag<=id_serial;id_serial<=id_serial+16'd1;end
   if(id_response_valid&&id_wait&&id_response_tag==id_active_tag)begin
    id_wait<=0;id_prepared<=1;id_found<=id_response_found;id_slot<=id_response_slot;id_word<=id_response_word;
   end
   if(config_valid&&config_ready)id_prepared<=0;
   if(session_flush||config_payload_changed)begin id_wait<=0;id_prepared<=0;end
  end
 end
 wire accept=config_valid&&config_ready;
 assign field_valid=accept&&opcode==86&&ENABLE_FIELD;
 assign field_start=config_bytes[263:256]==1;
 assign field_size=config_bytes[271:264]==1?0:config_bytes[271:264]==8?1:config_bytes[271:264]==16?2:config_bytes[271:264]==32?3:4;
 assign fx_cfg_valid=accept&&opcode==35;assign fx_cfg_data=config_bytes[607:256];
 assign gain_cfg_valid=accept&&opcode==36;
 assign gain_local=config_bytes[271:256];assign gain_external=config_bytes[287:272];
 assign gain_local_mute=config_bytes[288];assign gain_external_mute=config_bytes[289];
 assign pan_valid=accept&&opcode==34&&commit_pan_found;
 assign pan_slot=id_slot;assign pan_id=config_bytes[319:256];
 assign pan_generation=config_bytes[335:320];assign pan_value=config_bytes[344:336];
 s9_keymap_config u_map(.clk(clk),.rst(rst),.disconnect(session_flush),
  .cfg_valid(accept&&opcode==37),.cfg_notes(config_bytes[319:256]),.cfg_sequence(command_sequence),.cfg_slot(config_slot),
  .local_gate(local_gate),.local_pending(local_pending),.active_notes(keymap),.version(keymap_version),
  .accepted(map_accepted),.rejected(map_rejected),.applied(map_applied),.applied_sequence(map_applied_sequence),.applied_slot(map_applied_slot),
  .cancelled(map_cancelled),.cancelled_sequence(map_cancelled_sequence),.cancelled_slot(map_cancelled_slot),.pending(map_pending));
 assign lookup_valid=valid[6]&&!lookup_is_instance&&phase[6]<3&&!lookup_busy&&lookup_polled_ms!=now_ms;
 assign lookup_channel=lookup_ch;assign lookup_sequence=lookup_seq;assign lookup_echo=lookup_is_query;
 assign result_sequence=result_fields[31:0];
 reg[511:0] packed_result;reg[31:0] crc;integer j;
 function[31:0] crcbyte(input[31:0] c,input[7:0] b);
  reg[31:0] v;integer k;begin v=c^b;for(k=0;k<8;k=k+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crcbyte=v;end
 endfunction
 always @*begin
  packed_result=0;packed_result[31:0]=32'h54533953;packed_result[39:32]=1;packed_result[47:40]=2;
  packed_result[63:56]=result_flags;packed_result[191:64]=session_id;packed_result[447:192]=result_fields;
  crc=32'hffffffff;if(!DEFER_RESULT_CRC)begin for(j=0;j<60;j=j+1)crc=crcbyte(crc,packed_result[j*8+:8]);packed_result[511:480]=~crc;end
 end
 assign result_bytes=packed_result;
 reg found_dirty;reg[2:0] selected;integer n;
 always @*begin
  found_dirty=0;selected=0;
  for(integer k=0;k<7;k=k+1)begin
   n=cursor+k;if(n>=7)n=n-7;
   if(valid[n]&&dirty[n]&&!found_dirty)begin found_dirty=1;selected=n;end
  end
 end
 task prepare_result(input[2:0] which,input[2:0] p);
  begin
   result_valid<=1;result_index<=which;result_slot<=slot[which];result_fields<=0;result_flags<=0;
   result_fields[31:0]<=seq[which];result_fields[39:32]<=1;result_fields[47:40]<={5'd0,p};
   result_fields[63:48]<=error[which];result_fields[95:64]<=frame[which];result_fields[127:96]<=version[which];
   if(p==4||p==5)result_flags<=1;
   if(which==6&&lookup_is_instance&&p==3)begin result_flags<=2;result_fields[191:128]<=reply_id;result_fields[207:192]<=reply_generation;end
   if(which==0&&hello_pending&&p==3)begin
    result_flags<=1;result_fields[159:128]<=hello_snapshot[31:0];
    result_fields[207:192]<=hello_snapshot[47:32];result_fields[223:208]<=hello_snapshot[63:48];
    result_fields[230:224]<=hello_snapshot[70:64];
   end
   result_final<=p>=6||(which==4?p==5:(p==4||((which==0&&!field_pending||which==6)&&p==3)));
  end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   valid<=0;dirty<=0;glide_code<=0;timbre_id<=0;previous_local_glide<=0;tick_d<=0;tick_frame<=0;pan_defer_snapshot<=0;
   hello_pending<=0;field_pending<=0;field_target_start<=0;hello_snapshot<=0;
   pan_watch_valid<=0;
   held_pan_id<=0;held_pan_generation<=0;held_pan_slot<=0;held_pan_value<=128;reply_id<=0;reply_generation<=0;
   target_l<=32768;target_e<=32768;lookup_busy<=0;lookup_is_query<=0;lookup_is_instance<=0;lookup_ch<=0;
   lookup_required<=3;lookup_seq<=0;lookup_polled_ms<=0;result_valid<=0;result_final<=0;result_slot<=0;result_index<=0;
   cursor<=0;result_fields<=0;result_flags<=0;
   for(i=0;i<7;i=i+1)begin seq[i]<=0;slot[i]<=0;phase[i]<=0;frame[i]<=0;version[i]<=0;error[i]<=0;end
  end else begin
   tick_d<=sample_tick;if(sample_tick)tick_frame<=sample_time;
   previous_local_glide<=local_glide_code;
   if(result_valid&&result_ready)begin
    result_valid<=0;
    if(result_final&&seq[result_index]==result_sequence)begin valid[result_index]<=0;dirty[result_index]<=0;if(result_index==0)field_pending<=0;end
   end
   if(!result_valid&&found_dirty&&!replaceable)begin
    prepare_result(selected,phase[selected]);dirty[selected]<=0;cursor<=selected==6?0:selected+1'b1;
   end
   if(field_pending&&valid[0])begin
    if(field_rejected)begin phase[0]<=7;error[0]<=-3;dirty[0]<=1;end
    else if(field_committed&&phase[0]==2)begin phase[0]<=3;frame[0]<=sample_time;dirty[0]<=1;end
    else if(phase[0]==3&&((field_target_start&&field_running)||(!field_target_start&&!field_active)))begin phase[0]<=4;frame[0]<=sample_time;dirty[0]<=1;end
   end
   // Record real snapshot edges even while an older result is backpressured.
   if(valid[0]&&hello_pending&&phase[0]==2&&gain_sample)begin
    phase[0]<=3;frame[0]<=gain_frame;version[0]<=fx_frame_version;dirty[0]<=1;
    hello_snapshot<={glide_code,timbre_id,gain_e,gain_l,keymap_version};
   end
   if(valid[1]&&phase[1]==3&&sample_tick)begin phase[1]<=4;frame[1]<=sample_time;dirty[1]<=1;end
   // COMMITTED is produced only by the actual Pan write response. Audio
   // ownership prevents a write on sample_tick; the next frame consumes it.
   if(valid[2]&&phase[2]==2&&pan_response_valid)begin
    dirty[2]<=1;
    if(pan_result==0)begin phase[2]<=3;pan_watch_valid<=1;end
    else begin phase[2]<=7;error[2]<=-11;pan_watch_valid<=0;end
   end
   if(valid[2]&&phase[2]==3&&sample_tick&&pan_watch_valid)begin
    phase[2]<=4;frame[2]<=sample_time;dirty[2]<=1;pan_watch_valid<=0;
   end
   // This compact lifetime watch replaces 32 full snapshot identities.
   // OFF/pressure preserve ownership; only allocation or reclaim ends it.
   if(valid[2]&&phase[2]==3&&fact_valid&&(fact_outcome==1||fact_outcome==10)&&fact_slot=={1'b0,held_pan_slot})begin
    phase[2]<=7;error[2]<=-11;dirty[2]<=1;pan_watch_valid<=0;
   end
   if(valid[3]&&phase[3]==3&&tick_d&&fx_frame_version==version[3])begin phase[3]<=4;frame[3]<=tick_frame;dirty[3]<=1;end
   if(valid[4]&&phase[4]>=3&&phase[4]<5&&gain_sample&&gain_frame_version==version[4])begin
    if(phase[4]==3)begin phase[4]<=4;frame[4]<=gain_frame;dirty[4]<=1;end
    if(gain_remaining==0&&gain_l==target_l&&gain_e==target_e)begin phase[4]<=5;frame[4]<=gain_frame;dirty[4]<=1;end
   end
   if(valid[5]&&phase[5]==3&&sample_tick&&!map_pending&&keymap_version==version[5])begin phase[5]<=4;frame[5]<=sample_time;dirty[5]<=1;end
   if(local_glide_code!=previous_local_glide&&local_glide_code<=11)begin
    glide_code<=local_glide_code;
    if(valid[1]&&phase[1]==3)begin phase[1]<=6;dirty[1]<=1;end
   end
   if(lookup_valid&&lookup_ready)begin lookup_busy<=1;lookup_polled_ms<=now_ms;end
   if(lookup_done&&lookup_busy)begin
    lookup_busy<=0;
    if(lookup_error!=0)begin phase[6]<=7;error[6]<=lookup_error;dirty[6]<=1;end
    else if(lookup_is_query)begin phase[6]<=3;dirty[6]<=1;end
    else if(lookup_result[239:232]>=6)begin phase[6]<=7;error[6]<=-10;dirty[6]<=1;end
    else if(lookup_result[239:232]>=lookup_required)begin phase[6]<=3;dirty[6]<=1;end
   end
   if(accept)begin
    if(replaceable)prepare_result(index,3'd6);
    valid[index]<=1;dirty[index]<=1;seq[index]<=command_sequence;slot[index]<=config_slot;
    phase[index]<=3;error[index]<=0;frame[index]<=0;version[index]<=0;
    case(opcode)
     1:begin hello_pending<=1;phase[0]<=2;dirty[0]<=0;end
     86:begin hello_pending<=0;if(ENABLE_FIELD)begin field_pending<=1;field_target_start<=field_start;phase[0]<=2;dirty[0]<=0;end else begin phase[0]<=7;error[0]<=-2;end end
     32:begin field_pending<=0;timbre_id<=config_bytes[258:256];hello_pending<=0;end
     33:begin
      if(local_glide_code!=previous_local_glide)begin phase[1]<=7;error[1]<=-10;end
      else glide_code<=config_bytes[259:256];
     end
     34:begin
      pan_watch_valid<=0;
      if(!commit_pan_found)begin phase[2]<=7;error[2]<=-11;end
      else begin phase[2]<=2;dirty[2]<=0;end
      held_pan_id<=pan_id;held_pan_generation<=pan_generation;held_pan_slot<=pan_slot;held_pan_value<=pan_value;
     end
     35:version[3]<=fx_accepted+1'b1;
     36:begin version[4]<=gain_accepted+1'b1;target_l<=gain_local_mute?0:gain_local;target_e<=gain_external_mute?0:gain_external;end
     37:version[5]<=keymap_version+1'b1;
     39:begin lookup_is_instance<=1;reply_id<=query_id;reply_generation<=query_generation;if(!query_found)begin phase[6]<=7;error[6]<=-11;end end
     4,40:begin
      lookup_is_instance<=0;lookup_is_query<=opcode==4;lookup_ch<=config_bytes[256];
      lookup_seq<=opcode==4?config_bytes[295:264]:config_bytes[319:288];
      lookup_required<=opcode==4?3:config_bytes[266:264];lookup_busy<=0;lookup_polled_ms<=now_ms-1'b1;
      phase[6]<=2;dirty[6]<=0;
     end
     // MCU consumes HELLO/KEEP/CLOSE and PLAY, never fabricates their FPGA ACK.
     default:begin phase[0]<=7;error[0]<=-10;end
    endcase
   end
   if(session_flush)begin pan_watch_valid<=0;field_pending<=0;valid<=0;dirty<=0;result_valid<=0;lookup_busy<=0;end
  end
 end
 // synthesis translate_off
 reg[1538:0] identity_command_reference;
 always @(posedge clk)if(!rst&&!session_flush)begin
  if(id_req_valid&&id_req_ready)identity_command_reference<={config_slot,config_bytes};
  if((id_wait||id_prepared)&&!config_payload_changed&&{config_slot,config_bytes}!==identity_command_reference)
   $fatal(1,"R18_CONFIG_QUERY_COMMAND_BINDING");
  if(id_response_valid&&id_wait&&id_response_tag!==id_active_tag)$fatal(1,"R18_CONFIG_QUERY_RESPONSE_TAG");
  if(valid[2]&&phase[2]==2&&pan_response_valid&&pan_result==0)
   if(pan_response_slot!==held_pan_slot || pan_response_before[122:59]!==held_pan_id ||
    pan_response_before[58:43]!==held_pan_generation || pan_response_after[12:4]!==held_pan_value)
     $fatal(1,"R18_CONFIG_PAN_RESPONSE_BINDING");
 end
 // synthesis translate_on
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if((^{session_flush,session_ready,config_valid,sample_tick,gain_sample,identity_stable,local_pending,result_ready,lookup_ready,lookup_done,local_glide_code})===1'bx)$fatal(1,"S9_CONFIG_CONTROL_XZ");
  if(config_valid&&(^({config_bytes,config_slot}))===1'bx)$fatal(1,"S9_CONFIG_INPUT_XZ");
  if(gain_sample&&(^({gain_frame,gain_frame_version,gain_l,gain_e,gain_remaining}))===1'bx)$fatal(1,"S9_CONFIG_GAIN_XZ");
 end
 // synthesis translate_on
endmodule

// Stage11 passive recording control and shared outbound-prefix ownership.
// Recorder commands never feed performance source cleanup or audio ready.
module r18_recording_subsystem #(parameter integer PCM_BLOCK_PAIRS=128, SERIAL_EVENTS=0, RECORD48=0)(
 input wire pan_applied,input wire[5:0] pan_applied_slot,input wire[314:0] pan_applied_word,
 output wire snapshot_valid,input wire snapshot_ready,
 output wire snapshot_query_valid,input wire snapshot_query_ready,output wire[5:0] snapshot_query_slot,
 input wire snapshot_response_valid,input wire[5:0] snapshot_response_slot,input wire[314:0] snapshot_response_word,
 output wire[63:0] allocated_persistent_id,
 input wire clk,rst,audio_reset,
 input wire record_cmd_valid,
 output wire record_cmd_ready,
 input wire [7:0] record_cmd,
 input wire [63:0] command_record_id,
 input wire [1:0] command_mask,ack_kind,
 input wire [31:0] command_sequence,ack_block_sequence,
 output wire [2:0] record_state,wire_record_state,
 output wire wire_record_incomplete,record_drained,
 output wire [31:0] record_error,
 output reg [63:0] recording_id,
 output reg [1:0] record_mask,
 output reg [31:0] last_command_sequence,rejected_commands,
 output wire record_start_pulse,record_stop_pulse,
 input wire observe_load,
 input wire signed [15:0] observe_l,observe_r,
 input wire [63:0] observe_frame_id,event_frame_id,
 input wire [15:0] event_subcycle,
 input wire allocator_busy,batch_begin,publish_ok,batch_abort,
 input wire[31:0] batch_timestamp,
 input wire fact_valid,input wire[95:0] fact_item,input wire[7:0] fact_outcome,
 input wire[5:0] fact_slot,input wire fact_steal,input wire[314:0] fact_before,fact_after,
 input wire[63:0] fact_frame,input wire[15:0] fact_subcycle,input wire reclaim_batch_busy,
 input wire[47:0] slot_valid,slot_gate,
 input wire cfg_tx_valid,
 input wire [5:0] cfg_tx_count,
 input wire [255:0] cfg_tx_cell,
 output wire [5:0] cfg_tx_index,
 output wire cfg_tx_read_valid,output wire [15:0] cfg_tx_read_epoch,
 input wire cfg_tx_response_valid,input wire [5:0] cfg_tx_response_index,
 input wire [15:0] cfg_tx_response_epoch,
 output wire cfg_tx_ready,cfg_tx_done,
 input wire cfg_fault_valid,
 input wire [7:0] cfg_fault_code,
 input wire [63:0] cfg_first_missing_frame,
 input wire cfg_idle,cfg_quiet,
 output wire capture_caught_up,
 output wire cfg_capture_fault,
 input wire block_request,
 output wire block_valid,
 output reg [1:0] block_kind,
 output wire [31:0] block_sequence,
 output wire [63:0] block_first_frame,
 output wire [15:0] block_items,block_bytes,
 input wire [10:0] peek_byte_address,
 output wire [7:0] peek_byte_data,
 output wire [63:0] captured_pcm_pairs,retired_pcm_pairs,discarded_pcm_pairs,
 output wire [63:0] first_pcm_frame,last_pcm_frame,first_missing_pcm_frame,
 output wire [12:0] buffered_pcm_pairs,
 output wire [63:0] captured_event_cells,retired_event_cells,discarded_event_cells,
 output wire [63:0] first_missing_event_frame,
 output wire [8:0] buffered_event_cells,
 output wire [31:0] published_batches,aborted_batches,applied_items,initial_instances
);
 wire r54_equal_0;
 wire r54_equal_1;
 wire r54_equal_2;

 wire new_start,new_stop;
 wire rec_load,rec_stop,rec_source_fault,rec_owned;
 wire signed[15:0] rec_l,rec_r;wire[63:0] rec_index;
 generate if(RECORD48)begin: record48_branch
  rec48_downsample downsample(.clk(clk),.rst(rst),.audio_reset(audio_reset),
   .start_valid(new_start&&command_mask[0]),.stop_valid(new_stop),
   .observe_load(observe_load),.observe_l(observe_l),.observe_r(observe_r),.observe_frame_id(observe_frame_id),
   .result_valid(rec_load),.result_l(rec_l),.result_r(rec_r),.result_index(rec_index),
   .stop_retired(rec_stop),.source_fault(rec_source_fault),.owned_inflight(rec_owned));
 end else begin: native_recording_branch
  assign rec_load=observe_load;assign rec_l=observe_l;assign rec_r=observe_r;assign rec_index=observe_frame_id;
  assign rec_stop=new_stop;assign rec_source_fault=0;assign rec_owned=0;
 end endgenerate
 wire pcm_start_ready,event_start_ready,observer_idle,exec_pipeline_empty;
 wire pcm_active,pcm_incomplete,event_active,event_incomplete,exec_active,exec_arming,exec_incomplete;
 wire [7:0] pcm_error,event_error,exec_error;
 wire [63:0] pcm_id,event_id,exec_missing,persistent_id_next;
 // Normal observer state is not a missing-position candidate.  If two
 // passive producers fail, preserve the earliest known actual omitted frame.
 wire [63:0] exec_fault_missing=(record_mask[1]&&exec_incomplete)?exec_missing:64'hffffffffffffffff;
 wire [63:0] cfg_fault_missing=(record_mask[1]&&(cfg_fault_valid||event_incomplete||exec_incomplete))?
   cfg_first_missing_frame:64'hffffffffffffffff;
 assign first_missing_event_frame=(exec_fault_missing<cfg_fault_missing)?exec_fault_missing:cfg_fault_missing;
 wire pcm_block_valid,event_block_valid;
 wire [31:0] pcm_block_sequence,event_block_sequence;
 wire [63:0] pcm_block_first,event_block_first;
 wire [15:0] pcm_block_items,event_block_items;
 wire [7:0] pcm_peek,event_peek;
 wire [31:0] pcm_stale_ack,event_stale_ack,pcm_rejected_start,event_rejected_start,event_aborted_cells;
 wire [255:0] exec_tx_cell;
 wire [5:0] exec_count;
 wire exec_valid,exec_ready,exec_done,event_tx_ready,event_tx_done;
 reg [1:0] tx_owner;
 reg [31:0] previous_command;
 reg [7:0] previous_opcode;
 reg have_command;
 reg last_was_pcm;
 // Transport holds the entire command stable until ready. Validate the
 // immutable identity/sequence one cycle before the live commit conditions.
 // No other command can alter recording_id or its sequence while checked.
 reg command_checked,duplicate_q,start_identity_q,identity_q,ordered_q;
 always @(posedge clk)begin
  if(rst)begin command_checked<=0;duplicate_q<=0;start_identity_q<=0;identity_q<=0;ordered_q<=0;end
  else begin
   if(!record_cmd_valid||record_cmd_ready)command_checked<=0;
   else if(!command_checked)begin
    command_checked<=1;
    duplicate_q<=have_command&&r54_equal_0&&r54_equal_1&&record_cmd==previous_opcode&&
      (record_cmd!=1||command_mask==record_mask);
    start_identity_q<=command_record_id!=0&&command_record_id>recording_id;
    identity_q<=r54_equal_0&&recording_id!=0;
    ordered_q<=!have_command||command_sequence==last_command_sequence+1'b1||
      (record_cmd==1&&!r54_equal_0);
   end
  end
 end
 wire duplicate=duplicate_q;
 wire start_eligible=!audio_reset && !rec_source_fault && start_identity_q && command_mask!=0 &&
   pcm_start_ready && event_start_ready && observer_idle && tx_owner==0 && cfg_idle;
 // Evaluate START admission once, before requesting the snapshot. An
 // accepted idle reservation cannot acquire work until the atomic START.
 // QUERY/ACK/STOP retain their existing command path and latency.
 reg start_evaluated,start_admitted;
 always @(posedge clk)begin
  if(rst)begin start_evaluated<=0;start_admitted<=0;end
  else if(!record_cmd_valid||record_cmd_ready)begin start_evaluated<=0;start_admitted<=0;end
  else if(command_checked&&record_cmd==1&&!start_evaluated)begin
   start_evaluated<=1;start_admitted<=start_eligible;
  end
 end
 wire can_start=start_admitted && !audio_reset && (!command_mask[1] || snapshot_ready);
 wire valid_identity=identity_q;
 wire ordered=ordered_q;
 // QUERY/ACK use independent transport sequencing and do not advance START/
 // STOP command sequence. ACK still checks immutable block identity below.
 // A legal START waits for the shared-state freeze boundary. Invalid or
 // duplicate commands keep their original immediate handling. No command
 // is executed repeatedly while the transport holds valid under backpressure.
 wire needs_snapshot=record_cmd==1 && start_evaluated && !duplicate && ordered && start_admitted && !audio_reset && command_mask[1];
 assign snapshot_valid=record_cmd_valid && command_checked && needs_snapshot && !rst;
 assign record_cmd_ready=!rst && command_checked && (record_cmd!=1||start_evaluated) && (!needs_snapshot || snapshot_ready);
 wire command_accept=record_cmd_valid && record_cmd_ready;
 assign new_start=command_accept && !duplicate && record_cmd==1 && can_start && ordered;
 assign new_stop=command_accept && !duplicate && record_cmd==2 && valid_identity && ordered;
 // synthesis translate_off
 always @(posedge clk)if(!rst&&record_cmd_valid&&start_evaluated&&start_admitted&&!audio_reset)
  if(!start_eligible)$fatal(1,"TIMING_START_RESERVATION_LOST");
 // synthesis translate_on
 assign record_start_pulse=new_start;
 assign record_stop_pulse=new_stop;
 // Failure in the event recorder retires its passive CFG producer only.
 // PCM failure must not be mistaken for an event-producer cancellation.
 assign cfg_capture_fault=record_mask[1]&&(event_incomplete||exec_incomplete)&&!new_start;
 wire ack=command_accept && record_cmd==3 && valid_identity;
 wire pcm_ack=ack && ack_kind==1;
 wire event_ack=ack && ack_kind==2;
 wire matching_ack=ack && block_valid && ack_kind==block_kind &&
   r54_equal_2;
 wire pcm_available=record_mask[0] && buffered_pcm_pairs!=0 &&
   (buffered_pcm_pairs>=PCM_BLOCK_PAIRS || !pcm_active);
 wire event_available=record_mask[1] && buffered_event_cells!=0;
 wire choose_pcm=block_request && block_kind==0 && pcm_available &&
   (!event_available || buffered_pcm_pairs>=2048 || !last_was_pcm);
 wire choose_event=block_request && block_kind==0 && !choose_pcm &&
   event_available;
 assign block_valid=(block_kind==1)?pcm_block_valid:(block_kind==2)?event_block_valid:1'b0;
 assign block_sequence=(block_kind==1)?pcm_block_sequence:event_block_sequence;
 assign block_first_frame=(block_kind==1)?pcm_block_first:event_block_first;
 assign block_items=(block_kind==1)?pcm_block_items:event_block_items;
 assign block_bytes=(block_kind==1)?pcm_block_items*4:event_block_items*32;
 assign peek_byte_data=(block_kind==1)?pcm_peek:(block_kind==2)?event_peek:8'd0;
 wire incomplete=(record_mask[0] && pcm_incomplete) ||
   (record_mask[1] && (event_incomplete || exec_incomplete));
 // A capture fault is diagnostic immediately, but it is not a transport
 // EOF until both recorder prefixes and all accepted staging have drained.
 assign record_drained=buffered_pcm_pairs==0 && buffered_event_cells==0 &&
   observer_idle && tx_owner==0 && cfg_idle && block_kind==0 &&
   !(record_mask[0] && pcm_active);
 assign capture_caught_up=recording_id!=0&&record_mask[1]&&exec_active&&!incomplete&&
   exec_pipeline_empty&&cfg_quiet&&tx_owner==0&&buffered_event_cells==0&&block_kind==0&&
   !allocator_busy&&!batch_begin&&!publish_ok&&!fact_valid&&!pan_applied;
 assign wire_record_incomplete=incomplete;
 assign wire_record_state=incomplete && !record_drained ? 3'd3 : record_state;
 assign record_error=(record_mask[0] && pcm_incomplete)?{24'd0,pcm_error}:
   (record_mask[1] && event_incomplete)?{24'd0,event_error}:
   (record_mask[1] && exec_incomplete)?{24'd0,exec_error}:0;
 assign record_state=recording_id==0?3'd0:incomplete?3'd5:exec_arming?3'd1:
   ((record_mask[0] && pcm_active)||(record_mask[1] && exec_active))?3'd2:
   (buffered_pcm_pairs!=0 || buffered_event_cells!=0 || !observer_idle || tx_owner!=0 ||
    (record_mask[1] && !cfg_idle))?3'd3:3'd4;
 wire choose_exec=tx_owner==0 && exec_valid;
 wire choose_cfg=tx_owner==0 && !exec_valid && cfg_tx_valid && record_mask[1] && !incomplete && (!exec_arming || cfg_tx_count==16);
 wire event_tx_valid=choose_exec || choose_cfg;
 // Selection depends on ownership/priority, not CFG count eligibility.
 // When idle with no EXEC, an invalid CFG's count is don't-care: choose_cfg
 // still gates acceptance. This removes count -> eligibility -> count mux.
 wire selected_cfg=tx_owner==2 || (tx_owner==0 && !exec_valid);
 wire [5:0] event_tx_count=selected_cfg?cfg_tx_count:exec_count;
 wire [255:0] event_tx_cell=(tx_owner==2 || choose_cfg)?cfg_tx_cell:exec_tx_cell;
 wire [5:0] event_tx_index,event_prefetch_index;
 wire event_prefetch_valid,event_ram_write_enable;
 wire [15:0] prefetch_epoch;
 wire batch_accept=event_tx_valid&&event_tx_ready;
 wire [15:0] request_epoch;
 wire [1:0] request_owner=tx_owner!=0?tx_owner:exec_valid?2'd1:2'd2;
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(event_tx_valid && event_tx_count!==((tx_owner==2||choose_cfg)?cfg_tx_count:exec_count))
   $fatal(1,"MARGIN_BATCH_COUNT_EQ");
  if(event_prefetch_valid && request_owner!==(tx_owner!=0?tx_owner:choose_cfg?2'd2:2'd1))
   $fatal(1,"MARGIN_REQUEST_OWNER_EQ");
 end
 // synthesis translate_on
 wire exec_read_valid=event_prefetch_valid&&request_owner==1;
 wire exec_response_valid;wire [5:0] exec_response_index;wire [15:0] exec_response_epoch;
 assign cfg_tx_read_valid=event_prefetch_valid&&request_owner==2;
 assign cfg_tx_read_epoch=request_epoch;
 wire [1:0] response_owner=(tx_owner==2||choose_cfg)?2'd2:2'd1;
 wire response_pulse=response_owner==2?cfg_tx_response_valid:exec_response_valid;
 wire [5:0] response_index=response_owner==2?cfg_tx_response_index:exec_response_index;
 wire [15:0] response_epoch=response_owner==2?cfg_tx_response_epoch:exec_response_epoch;
 r18_cell_prefetch_control #(.VARIABLE_RESPONSE(SERIAL_EVENTS)) prefetch_control(.clk(clk),.rst(rst),.clear_valid(1'b0),
  .batch_accept(batch_accept),.request_valid(event_prefetch_valid),.request_owner(request_owner),.request_index(event_prefetch_index),
  .response_pulse(response_pulse),.response_owner(response_owner),.response_index(response_index),.response_epoch(response_epoch),
  .consume_valid(event_ram_write_enable),.consume_owner(tx_owner),.consume_index(event_tx_index),.consume_cell(event_tx_cell),
  .request_epoch(request_epoch),.active_epoch(prefetch_epoch));
 // Both passive producers expose the requested immutable cell.

 assign cfg_tx_index=event_prefetch_index;
 assign exec_ready=choose_exec && event_tx_ready;
 assign cfg_tx_ready=choose_cfg && event_tx_ready;
 assign exec_done=event_tx_done && tx_owner==1;
 assign cfg_tx_done=event_tx_done && tx_owner==2;
 always @(posedge clk)begin
  if(rst)begin recording_id<=0;record_mask<=0;last_command_sequence<=0;
   rejected_commands<=0;previous_command<=0;previous_opcode<=0;have_command<=0;
   block_kind<=0;tx_owner<=0;last_was_pcm<=0;end
  else begin
   if(new_start)begin
    recording_id<=command_record_id;record_mask<=command_mask;last_command_sequence<=command_sequence;
    previous_command<=command_sequence;previous_opcode<=record_cmd;have_command<=1;
   end else if(new_stop)begin
    last_command_sequence<=command_sequence;previous_command<=command_sequence;previous_opcode<=record_cmd;
   end else if(command_accept && record_cmd!=0 && record_cmd!=3 && !duplicate)
    rejected_commands<=rejected_commands+1;
   if(choose_pcm)block_kind<=1;
   else if(choose_event)block_kind<=2;
   if(matching_ack)begin block_kind<=0;last_was_pcm<=block_kind==1;end
   if(event_tx_valid && event_tx_ready)tx_owner<=choose_cfg?2'd2:2'd1;
   if(event_tx_done)tx_owner<=0;
  end
 end
 s11_pcm_recorder #(.TRUSTED_ACK(1),.BLOCK_PAIRS(PCM_BLOCK_PAIRS)) u_pcm(.clk(clk),.rst(rst),.audio_reset(audio_reset||rec_source_fault),
  .start_valid(new_start && command_mask[0]),.stop_valid(rec_stop),.clear_valid(1'b0),
  .start_record_id(command_record_id),.start_ready(pcm_start_ready),.observe_load(rec_load),
  .observe_l(rec_l),.observe_r(rec_r),.observe_frame_id(rec_index),
  .active(pcm_active),.incomplete(pcm_incomplete),.error_code(pcm_error),.record_id(pcm_id),
  .first_frame_id(first_pcm_frame),.last_frame_id(last_pcm_frame),
  .captured_pairs(captured_pcm_pairs),.retired_pairs(retired_pcm_pairs),.discarded_pairs(discarded_pcm_pairs),
  .first_missing_frame(first_missing_pcm_frame),.buffered_pairs(buffered_pcm_pairs),
  .block_request(choose_pcm),.block_valid(pcm_block_valid),.block_sequence(pcm_block_sequence),
  .block_first_frame(pcm_block_first),.block_pair_count(pcm_block_items),
  .peek_byte_address(peek_byte_address),.peek_byte_data(pcm_peek),.ack_accepted(matching_ack&&ack_kind==1),.ack_valid(pcm_ack),
  .ack_record_id(command_record_id),.ack_block_sequence(ack_block_sequence),
  .stale_ack_count(pcm_stale_ack),.rejected_start_count(pcm_rejected_start));
 generate if(SERIAL_EVENTS)begin: serial_journal
 r28_execution_observer u_exec(.pan_applied(pan_applied),.pan_applied_slot(pan_applied_slot),.pan_applied_word(pan_applied_word),.clk(clk),.rst(rst),.audio_reset(audio_reset),
  .capture_fault((event_incomplete || cfg_fault_valid) && !new_start),
  .capture_fault_code(cfg_fault_valid?cfg_fault_code:event_error),.stop_delivery_idle(cfg_idle && tx_owner!=2),
  .start_valid(new_start && command_mask[1]),.stop_valid(new_stop),.start_record_id(command_record_id),
  .frame_id(event_frame_id),.subcycle(event_subcycle),.allocator_busy(allocator_busy),
  .batch_begin(batch_begin),.publish_ok(publish_ok),.batch_abort(batch_abort),.batch_timestamp(batch_timestamp),
  .fact_valid(fact_valid),.fact_item(fact_item),.fact_outcome(fact_outcome),.fact_slot(fact_slot),.fact_steal(fact_steal),
  .fact_before(fact_before),.fact_after(fact_after),.fact_frame(fact_frame),.fact_subcycle(fact_subcycle),.reclaim_batch_busy(reclaim_batch_busy),
  .slot_valid(slot_valid),.slot_gate(slot_gate),.allocated_persistent_id(allocated_persistent_id),
  .snapshot_query_valid(snapshot_query_valid),.snapshot_query_ready(snapshot_query_ready),.snapshot_query_slot(snapshot_query_slot),
  .snapshot_response_valid(snapshot_response_valid),.snapshot_response_slot(snapshot_response_slot),.snapshot_response_word(snapshot_response_word),
  .active(exec_active),.arming(exec_arming),.incomplete(exec_incomplete),.error_code(exec_error),.first_missing_frame(exec_missing),
  .tx_valid(exec_valid),.tx_count(exec_count),.tx_index(event_prefetch_index),.tx_cell(exec_tx_cell),
  .tx_read_valid(exec_read_valid),.tx_read_epoch(request_epoch),.tx_response_valid(exec_response_valid),
  .tx_response_index(exec_response_index),.tx_response_epoch(exec_response_epoch),.tx_ready(exec_ready),.tx_done(exec_done),
  .published_batches(published_batches),.aborted_batches(aborted_batches),.applied_items(applied_items),.initial_instances(initial_instances),
  .persistent_id_next(persistent_id_next),.observer_idle(observer_idle),.pipeline_empty(exec_pipeline_empty));
 end else begin: legacy_journal
 assign exec_pipeline_empty=observer_idle;
 r18_execution_observer u_exec(.clk(clk),.rst(rst),.audio_reset(audio_reset),
  .capture_fault((event_incomplete || cfg_fault_valid) && !new_start),
  .capture_fault_code(cfg_fault_valid?cfg_fault_code:event_error),.stop_delivery_idle(cfg_idle && tx_owner!=2),
  .start_valid(new_start && command_mask[1]),.stop_valid(new_stop),.start_record_id(command_record_id),
  .frame_id(event_frame_id),.subcycle(event_subcycle),.allocator_busy(allocator_busy),
  .batch_begin(batch_begin),.publish_ok(publish_ok),.batch_abort(batch_abort),.batch_timestamp(batch_timestamp),
  .fact_valid(fact_valid),.fact_item(fact_item),.fact_outcome(fact_outcome),.fact_slot(fact_slot),.fact_steal(fact_steal),
  .fact_before(fact_before),.fact_after(fact_after),.fact_frame(fact_frame),.fact_subcycle(fact_subcycle),.reclaim_batch_busy(reclaim_batch_busy),
  .slot_valid(slot_valid),.slot_gate(slot_gate),.allocated_persistent_id(allocated_persistent_id),
  .snapshot_query_valid(snapshot_query_valid),.snapshot_query_ready(snapshot_query_ready),.snapshot_query_slot(snapshot_query_slot),
  .snapshot_response_valid(snapshot_response_valid),.snapshot_response_slot(snapshot_response_slot),.snapshot_response_word(snapshot_response_word),
  .active(exec_active),.arming(exec_arming),.incomplete(exec_incomplete),.error_code(exec_error),.first_missing_frame(exec_missing),
  .tx_valid(exec_valid),.tx_count(exec_count),.tx_index(event_prefetch_index),.tx_cell(exec_tx_cell),
  .tx_read_valid(exec_read_valid),.tx_read_epoch(request_epoch),.tx_response_valid(exec_response_valid),
  .tx_response_index(exec_response_index),.tx_response_epoch(exec_response_epoch),.tx_ready(exec_ready),.tx_done(exec_done),
  .published_batches(published_batches),.aborted_batches(aborted_batches),.applied_items(applied_items),.initial_instances(initial_instances),
  .persistent_id_next(persistent_id_next),.observer_idle(observer_idle));
 end endgenerate
 s11_event_recorder #(.TRUSTED_ACK(1),.VARIABLE_RESPONSE(SERIAL_EVENTS)) u_events(.tx_response_valid(response_pulse),.clk(clk),.rst(rst),
  .start_valid(new_start && command_mask[1]),.stop_valid(new_stop),.clear_valid(1'b0),
  .start_record_id(command_record_id),.start_ready(event_start_ready),.active(event_active),
  .incomplete(event_incomplete),.error_code(event_error),.record_id(event_id),
  .tx_valid(event_tx_valid),.tx_count(event_tx_count),.tx_cell(event_tx_cell),.tx_index(event_tx_index),
  .tx_ready(event_tx_ready),.tx_done(event_tx_done),
  .observe_write_enable(event_ram_write_enable),.prefetch_req_valid(event_prefetch_valid),.prefetch_req_index(event_prefetch_index),
  .fault_valid((exec_incomplete || cfg_fault_valid) && record_mask[1] && !new_start),
  .fault_code(cfg_fault_valid?cfg_fault_code:exec_error),
  .captured_cells(captured_event_cells),.retired_cells(retired_event_cells),
  .discarded_cells(discarded_event_cells),.buffered_cells(buffered_event_cells),
  .aborted_transaction_cells(event_aborted_cells),.block_request(choose_event),
  .block_valid(event_block_valid),.block_sequence(event_block_sequence),
  .block_first_frame(event_block_first),.block_cell_count(event_block_items),
  .peek_byte_address(peek_byte_address[8:0]),.peek_byte_data(event_peek),.ack_accepted(matching_ack&&ack_kind==2),.ack_valid(event_ack),
  .ack_record_id(command_record_id),.ack_block_sequence(ack_block_sequence),
  .stale_ack_count(event_stale_ack),.rejected_start_count(event_rejected_start));
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(pcm_block_valid&&(block_kind!=1||pcm_id!=recording_id))$fatal(1,"R54_PCM_PREFIX_OWNER");
  if(event_block_valid&&(block_kind!=2||event_id!=recording_id))$fatal(1,"R54_EVENT_PREFIX_OWNER");
 end
 always @(posedge clk)if(!rst)begin
  if($isunknown({record_cmd_valid,block_request,cfg_tx_valid,cfg_fault_valid}))
   $fatal(1,"S11_SUBSYSTEM_CONTROL_XZ");
  if(cfg_fault_valid && $isunknown({cfg_fault_code,cfg_first_missing_frame}))
   $fatal(1,"S11_SUBSYSTEM_CFG_FAULT_XZ");
  if(record_cmd_valid && $isunknown({record_cmd,command_record_id,command_mask,
      command_sequence,ack_kind,ack_block_sequence}))$fatal(1,"S11_SUBSYSTEM_COMMAND_XZ");
 end
 // synthesis translate_on
 r54_full_equal #(.WIDTH(64)) r54_equal_0_tree(.a(command_record_id),.b(recording_id),.equal(r54_equal_0));
 r54_full_equal #(.WIDTH(32)) r54_equal_1_tree(.a(command_sequence),.b(previous_command),.equal(r54_equal_1));
 r54_full_equal #(.WIDTH(32)) r54_equal_2_tree(.a(ack_block_sequence),.b(block_sequence),.equal(r54_equal_2));
 // synthesis translate_off
 reg command_waiting;reg[139:0] held_command;
 wire[139:0] command_bits={record_cmd,command_record_id,command_mask,ack_kind,command_sequence,ack_block_sequence};
 always @(posedge clk)begin
  if(rst)command_waiting<=0;
  else begin
   if(command_waiting&&(!record_cmd_valid||command_bits!==held_command))$fatal(1,"RECORD_COMMAND_CHANGED_UNDER_BACKPRESSURE");
   command_waiting<=record_cmd_valid&&!record_cmd_ready;
   held_command<=command_bits;
  end
 end
 // synthesis translate_on
endmodule

// The production controller is also used by the independent clear/reset and
// faulty-response fixture. It never drives ready, write-enable or done.
module r18_cell_prefetch_control #(parameter integer VARIABLE_RESPONSE=0)(
 input wire clk,rst,clear_valid,batch_accept,request_valid,
 input wire [1:0] request_owner,input wire [5:0] request_index,
 input wire response_pulse,input wire [1:0] response_owner,input wire [5:0] response_index,
 input wire [15:0] response_epoch,
 input wire consume_valid,input wire [1:0] consume_owner,input wire [5:0] consume_index,
 input wire [255:0] consume_cell,
 output wire [15:0] request_epoch,output reg [15:0] active_epoch
);
 reg cached_response_valid,request_due;
 reg [1:0] cached_owner,due_owner;
 reg [5:0] cached_index,due_index;
 reg [15:0] cached_epoch,due_epoch;
 assign request_epoch=batch_accept?active_epoch+16'd1:active_epoch;
 always @(posedge clk)begin
  if(rst)begin active_epoch<=0;cached_response_valid<=0;request_due<=0;
   cached_owner<=0;cached_index<=0;cached_epoch<=0;due_owner<=0;due_index<=0;due_epoch<=0;end
  else begin
   if(batch_accept)active_epoch<=active_epoch+1'b1;
   if(clear_valid)begin cached_response_valid<=0;request_due<=0;end
   else begin
    if(VARIABLE_RESPONSE)begin
     if(response_pulse)request_due<=0;
     if(request_valid)request_due<=1;
    end else request_due<=request_valid;
    if(request_valid)begin due_owner<=request_owner;due_index<=request_index;due_epoch<=request_epoch;end
    if(response_pulse)begin cached_response_valid<=1;cached_owner<=response_owner;cached_index<=response_index;cached_epoch<=response_epoch;end
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst&&!clear_valid)begin
  if((VARIABLE_RESPONSE?response_pulse:request_due)&&(!response_pulse||!request_due||{response_owner,response_index,response_epoch}!=={due_owner,due_index,due_epoch}))
   $fatal(1,"PREFETCH_WRONG_OR_STALE_RESPONSE");
  if(consume_valid)begin
   if(response_pulse)begin
    if({response_owner,response_index,response_epoch}!=={consume_owner,consume_index,active_epoch})$fatal(1,"PREFETCH_CONSUMER_TAG");
   end else if(!cached_response_valid||{cached_owner,cached_index,cached_epoch}!=={consume_owner,consume_index,active_epoch})
    $fatal(1,"PREFETCH_CONSUMER_NOT_READY");
   if($isunknown(consume_cell))$fatal(1,"PREFETCH_CONSUMER_DATA_XZ");
  end
 end
 // synthesis translate_on
endmodule

module r19_unsigned29_less(input wire[28:0] a,b,output wire less);
 wire[3:0] lt /* synthesis syn_keep=1 */;
 wire[3:0] eq /* synthesis syn_keep=1 */;
 for(genvar c=0;c<4;c++)begin:chunks
  if(c<3)begin assign lt[c]=a[c*8+:8]<b[c*8+:8];assign eq[c]=a[c*8+:8]==b[c*8+:8];end
  else begin assign lt[c]=a[28:24]<b[28:24];assign eq[c]=a[28:24]==b[28:24];end
 end
 assign less=lt[3] || (eq[3] && lt[2]) || (eq[3] && eq[2] && lt[1]) || (eq[3] && eq[2] && eq[1] && lt[0]);
endmodule

module r19_unsigned64_dsp_compare(input wire[63:0] a,b,output wire less,equal);
 wire[65:0] av={2'd0,a},bv={2'd0,b};
 wire[2:0] lt,eq;
 for(genvar k=0;k<3;k++)begin:chunks
  wire[47:0] diff;
  wire[10:0] pairs /* synthesis syn_keep=1 */;
  for(genvar j=0;j<11;j++)begin:equal_bits
   assign pairs[j]=av[k*22+j*2+:2]==bv[k*22+j*2+:2];
  end
  assign eq[k]=&pairs;
  MULTALU27X18 #(.ADD_SUB_0(1'b0),.ADD_SUB_1(1'b1),.C_SEL(1'b1),.CASI_SEL(1'b0),.ACC_SEL(1'b0)) subtract(
   .DOUT(diff),.CASO(),.SOA(),.A({5'd0,av[k*22+:22]}),.B(18'd1),.C({26'd0,bv[k*22+:22]}),
   .D(26'd0),.SIA(27'd0),.CASI(48'd0),.PSEL(1'b0),.ASEL(1'b0),.CSEL(1'b0),.CASISEL(1'b0),
   .PADDSUB(1'b0),.ACCSEL(1'b0),.ADDSUB(2'd0),.CLK(2'd0),.CE(2'd3),.RESET(2'd0));
  assign lt[k]=diff[47];
 end
 assign equal=&eq;assign less=lt[2] || (eq[2] && lt[1]) || (eq[2] && eq[1] && lt[0]);
endmodule

module r22_config_bridge #(parameter integer ENABLE_FIELD=0, DEFER_RESULT_CRC=0)(
 input wire [127:0] ensemble_metrics,
 input wire config_payload_changed,
 output wire id_req_valid,id_req_pan,input wire id_req_ready,
 output wire[7:0] id_req_key,output wire[63:0] id_req_identity,
 output wire[15:0] id_req_generation,id_req_tag,
 input wire id_response_valid,id_response_found,input wire[5:0] id_response_slot,
 input wire[314:0] id_response_word,input wire[15:0] id_response_tag,
 input wire pan_ready,pan_response_valid,input wire[1:0] pan_result,
 input wire[5:0] pan_response_slot,input wire[314:0] pan_response_before,pan_response_after,
 input wire fact_valid,input wire[7:0] fact_outcome,input wire[5:0] fact_slot,
 input wire clk,rst,session_flush,session_ready,input wire[127:0] session_id,
 input wire config_valid,output wire config_ready,input wire[2:0] config_slot,input wire[1535:0] config_bytes,
 input wire sample_tick,input wire[31:0] sample_time,now_ms,
 input wire[3:0] local_glide_code,output reg[3:0] glide_code,output reg[2:0] timbre_id,
 output wire fx_cfg_valid,output wire[351:0] fx_cfg_data,
 input wire[31:0] fx_accepted,fx_frame_version,
 output wire gain_cfg_valid,output wire[15:0] gain_local,gain_external,
 output wire gain_local_mute,gain_external_mute,
 input wire gain_sample,input wire[31:0] gain_frame,gain_frame_version,gain_accepted,
 input wire[15:0] gain_l,gain_e,input wire[6:0] gain_remaining,
 output wire pan_valid,output wire[5:0] pan_slot,output wire[63:0] pan_id,
 output wire[15:0] pan_generation,output wire[8:0] pan_value,
 input wire identity_stable,
 input wire[7:0] local_gate,input wire local_pending,output wire[55:0] keymap,
 output wire[31:0] keymap_version,
 output wire field_valid,field_start,output wire[2:0] field_size,
 input wire field_ready,field_active,field_rejected,field_committed,field_running,
 output wire lookup_valid,input wire lookup_ready,output wire lookup_channel,lookup_echo,
 output wire[31:0] lookup_sequence,input wire lookup_done,input wire signed[15:0] lookup_error,input wire[511:0] lookup_result,
 output reg result_valid,input wire result_ready,output reg[2:0] result_slot,
 output wire[31:0] result_sequence,output wire[511:0] result_bytes,output reg result_final
);
 wire r54_equal_0;
 wire r54_equal_1;
 wire r54_equal_2;

 // 0 immediate,1 Glide,2 Pan,3 Effects,4 Gain,5 keymap,6 query/barrier.
 reg[6:0] valid,dirty;
 reg[31:0] frame[0:6],version[0:6];reg[2:0] slot[0:6],phase[0:6];
 reg signed[4:0] error[0:6];
 reg[63:0] held_pan_id,reply_id;reg[15:0] held_pan_generation,reply_generation;
 reg[5:0] held_pan_slot;reg[8:0] held_pan_value;
 reg[15:0] target_l,target_e;reg[3:0] previous_local_glide;
 reg tick_d,pan_defer_snapshot;reg[31:0] tick_frame;
 wire lookup_is_instance=1'b1;
 
 reg[2:0] result_index,cursor;
 reg[255:0] result_fields;reg[7:0] result_flags;
 reg metrics_pending;reg[127:0] metrics_snapshot;
 reg hello_pending,field_pending,field_target_start;reg[70:0] hello_snapshot;
 wire[7:0] opcode=config_bytes[39:32];
 reg[2:0] index;integer i;
 always @*begin
  case(opcode)33:index=1;34:index=2;35:index=3;36:index=4;37:index=5;39:index=6;default:index=0;endcase
 end
 wire map_accepted,map_rejected,map_applied,map_cancelled,map_pending;
 wire[31:0] map_applied_sequence,map_cancelled_sequence;wire[2:0] map_applied_slot,map_cancelled_slot;
 wire local_idle=local_gate==0&&!local_pending;
 wire replace_gain=index==4&&valid[4]&&phase[4]<5;
 wire replace_map=index==5&&valid[5]&&phase[5]==3&&map_pending&&!local_idle;
 wire replaceable=config_valid&&(replace_gain||replace_map)&&!result_valid;
 wire identity_needed=opcode==34||opcode==39;
 wire command_available=!rst&&!session_flush&&session_ready&&(!valid[index]||replaceable);
 reg pan_request_pending;
 reg id_wait,id_prepared,id_found;reg[5:0] id_slot;reg[314:0] id_word;
 reg[15:0] id_serial,id_active_tag;reg pan_watch_valid;
 assign id_req_valid=config_valid&&!config_payload_changed&&command_available&&identity_needed&&!id_wait&&!id_prepared;
 assign id_req_pan=opcode==34;assign id_req_key=config_bytes[151:144];
 assign id_req_identity=config_bytes[127:64];
 assign id_req_generation=config_bytes[143:128];assign id_req_tag=id_serial;
 assign config_ready=command_available&&(!identity_needed||(identity_stable&&id_prepared))&&
  (opcode!=34||!pan_request_pending)&&(opcode!=86||!ENABLE_FIELD||field_ready);
 wire[63:0] query_id=id_found?id_word[122:59]:64'd0;
 wire[15:0] query_generation=id_found?id_word[58:43]:16'd0;
 wire query_found=id_found,commit_pan_found=id_found;
 always @(posedge clk)begin
  if(rst)begin id_wait<=0;id_prepared<=0;id_found<=0;id_slot<=0;id_word<=0;id_serial<=0;id_active_tag<=0;end
  else begin
   if(!identity_stable)id_prepared<=0;
   if(id_req_valid&&id_req_ready)begin id_wait<=1;id_active_tag<=id_serial;id_serial<=id_serial+16'd1;end
   if(id_response_valid&&id_wait&&id_response_tag==id_active_tag)begin
    id_wait<=0;id_prepared<=1;id_found<=id_response_found;id_slot<=id_response_slot;id_word<=id_response_word;
   end
   if(config_valid&&config_ready)id_prepared<=0;
   if(session_flush||config_payload_changed)begin id_wait<=0;id_prepared<=0;end
  end
 end
 wire accept=config_valid&&config_ready;
 assign field_valid=accept&&opcode==86&&ENABLE_FIELD;
 assign field_start=config_bytes[71:64]==1;
 assign field_size=config_bytes[79:72]==1?0:config_bytes[79:72]==8?1:config_bytes[79:72]==16?2:config_bytes[79:72]==32?3:4;
 assign fx_cfg_valid=accept&&opcode==35;assign fx_cfg_data=config_bytes[415:64];
 assign gain_cfg_valid=accept&&opcode==36;
 assign gain_local=config_bytes[79:64];assign gain_external=config_bytes[95:80];
 assign gain_local_mute=config_bytes[96];assign gain_external_mute=config_bytes[97];
 // Resolve identity once, then own the complete Pan request until the
 // Allocator accepts it. No ready -> command accept -> valid return path.
 assign pan_valid=!rst&&!session_flush&&pan_request_pending;
 assign pan_slot=held_pan_slot;assign pan_id=held_pan_id;
 assign pan_generation=held_pan_generation;assign pan_value=held_pan_value;
 always @(posedge clk)begin
  if(rst||session_flush)pan_request_pending<=0;
  else begin
   if(pan_valid&&pan_ready)pan_request_pending<=0;
   if(accept&&opcode==34)pan_request_pending<=commit_pan_found;
  end
 end
 s9_keymap_config u_map(.clk(clk),.rst(rst),.disconnect(session_flush),
  .cfg_valid(accept&&opcode==37),.cfg_notes(config_bytes[127:64]),.cfg_sequence(32'd0),.cfg_slot(config_slot),
  .local_gate(local_gate),.local_pending(local_pending),.active_notes(keymap),.version(keymap_version),
  .accepted(map_accepted),.rejected(map_rejected),.applied(map_applied),.applied_sequence(map_applied_sequence),.applied_slot(map_applied_slot),
  .cancelled(map_cancelled),.cancelled_sequence(map_cancelled_sequence),.cancelled_slot(map_cancelled_slot),.pending(map_pending));
 assign lookup_valid=0;assign lookup_channel=0;assign lookup_sequence=0;assign lookup_echo=0;
 assign result_sequence=result_fields[31:0];
 assign result_bytes={64'd0,result_fields,session_id,result_flags,8'd0,8'd0,8'd0,32'd0};
 reg found_dirty;reg[2:0] selected;integer n;
 always @*begin
  found_dirty=0;selected=0;
  for(integer k=0;k<7;k=k+1)begin
   n=cursor+k;if(n>=7)n=n-7;
   if(valid[n]&&dirty[n]&&!found_dirty)begin found_dirty=1;selected=n;end
  end
 end
 task prepare_result(input[2:0] which,input[2:0] p);
  begin
   result_valid<=1;result_index<=which;result_slot<=slot[which];result_fields<=0;result_flags<=0;
   result_fields[31:0]<=0;result_fields[39:32]<=1;result_fields[47:40]<=8'h80|{5'd0,p};
   result_fields[63:48]<={{11{error[which][4]}},error[which]};result_fields[95:64]<=frame[which];result_fields[127:96]<=version[which];
   if(p==4||p==5)result_flags<=1;
   if(which==6&&lookup_is_instance&&p==3)begin result_flags<=2;result_fields[191:128]<=reply_id;result_fields[207:192]<=reply_generation;end
   if(which==0&&hello_pending&&p==3)begin
    result_flags<=1;result_fields[159:128]<=hello_snapshot[31:0];
    result_fields[207:192]<=hello_snapshot[47:32];result_fields[223:208]<=hello_snapshot[63:48];
    result_fields[230:224]<=hello_snapshot[70:64];
   end
   if(which==0&&metrics_pending&&p==3)begin result_flags<=8;result_fields[255:128]<=metrics_snapshot;end
   result_final<=p>=6||(which==4?p==5:(p==4||((which==0&&!field_pending||which==6)&&p==3)));
  end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   valid<=0;dirty<=0;glide_code<=0;timbre_id<=0;previous_local_glide<=0;tick_d<=0;tick_frame<=0;pan_defer_snapshot<=0;
   metrics_pending<=0;metrics_snapshot<=0;hello_pending<=0;field_pending<=0;field_target_start<=0;hello_snapshot<=0;
   pan_watch_valid<=0;
   held_pan_id<=0;held_pan_generation<=0;held_pan_slot<=0;held_pan_value<=128;reply_id<=0;reply_generation<=0;
   target_l<=32768;target_e<=32768;
   result_valid<=0;result_final<=0;result_slot<=0;result_index<=0;
   cursor<=0;result_fields<=0;result_flags<=0;
   for(i=0;i<7;i=i+1)begin slot[i]<=0;phase[i]<=0;frame[i]<=0;version[i]<=0;error[i]<=0;end
  end else begin
   tick_d<=sample_tick;if(sample_tick)tick_frame<=sample_time;
   previous_local_glide<=local_glide_code;
   if(result_valid&&result_ready)begin
    result_valid<=0;
    if(result_final&&slot[result_index]==result_slot)begin valid[result_index]<=0;dirty[result_index]<=0;if(result_index==0)field_pending<=0;end
   end
   if(!result_valid&&found_dirty&&!replaceable)begin
    prepare_result(selected,phase[selected]);dirty[selected]<=0;cursor<=selected==6?0:selected+1'b1;
   end
   if(field_pending&&valid[0])begin
    if(field_rejected)begin phase[0]<=7;error[0]<=-3;dirty[0]<=1;end
    else if(field_committed&&phase[0]==2)begin phase[0]<=3;frame[0]<=sample_time;dirty[0]<=1;end
    else if(phase[0]==3&&((field_target_start&&field_running)||(!field_target_start&&!field_active)))begin phase[0]<=4;frame[0]<=sample_time;dirty[0]<=1;end
   end
   // Record real snapshot edges even while an older result is backpressured.
   if(valid[0]&&hello_pending&&phase[0]==2&&gain_sample)begin
    phase[0]<=3;frame[0]<=gain_frame;version[0]<=fx_frame_version;dirty[0]<=1;
    hello_snapshot<={glide_code,timbre_id,gain_e,gain_l,keymap_version};
   end
   if(valid[1]&&phase[1]==3&&sample_tick)begin phase[1]<=4;frame[1]<=sample_time;dirty[1]<=1;end
   // COMMITTED is produced only by the actual Pan write response. Audio
   // ownership prevents a write on sample_tick; the next frame consumes it.
   if(valid[2]&&phase[2]==2&&pan_response_valid)begin
    dirty[2]<=1;
    if(pan_result==0)begin phase[2]<=3;pan_watch_valid<=1;end
    else begin phase[2]<=7;error[2]<=-11;pan_watch_valid<=0;end
   end
   if(valid[2]&&phase[2]==3&&sample_tick&&pan_watch_valid)begin
    phase[2]<=4;frame[2]<=sample_time;dirty[2]<=1;pan_watch_valid<=0;
   end
   // This compact lifetime watch replaces 32 full snapshot identities.
   // OFF/pressure preserve ownership; only allocation or reclaim ends it.
   if(valid[2]&&phase[2]==3&&fact_valid&&(fact_outcome==1||fact_outcome==10)&&fact_slot=={1'b0,held_pan_slot})begin
    phase[2]<=7;error[2]<=-11;dirty[2]<=1;pan_watch_valid<=0;
   end
   if(valid[3]&&phase[3]==3&&tick_d&&r54_equal_0)begin phase[3]<=4;frame[3]<=tick_frame;dirty[3]<=1;end
   if(valid[4]&&phase[4]>=3&&phase[4]<5&&gain_sample&&r54_equal_1)begin
    if(phase[4]==3)begin phase[4]<=4;frame[4]<=gain_frame;dirty[4]<=1;end
    if(gain_remaining==0&&gain_l==target_l&&gain_e==target_e)begin phase[4]<=5;frame[4]<=gain_frame;dirty[4]<=1;end
   end
   if(valid[5]&&phase[5]==3&&sample_tick&&!map_pending&&r54_equal_2)begin phase[5]<=4;frame[5]<=sample_time;dirty[5]<=1;end
   if(local_glide_code!=previous_local_glide&&local_glide_code<=11)begin
    glide_code<=local_glide_code;
    if(valid[1]&&phase[1]==3)begin phase[1]<=6;dirty[1]<=1;end
   end
   if(accept)begin
    if(replaceable)prepare_result(index,3'd6);
    valid[index]<=1;dirty[index]<=1;slot[index]<=config_slot;
    phase[index]<=3;error[index]<=0;frame[index]<=0;version[index]<=0;
    if(index==0)metrics_pending<=0;
    case(opcode)
     1:begin hello_pending<=1;phase[0]<=2;dirty[0]<=0;end
     86:begin hello_pending<=0;if(ENABLE_FIELD)begin field_pending<=1;field_target_start<=field_start;phase[0]<=2;dirty[0]<=0;end else begin phase[0]<=7;error[0]<=-2;end end
     41:begin metrics_pending<=1;metrics_snapshot<=ensemble_metrics;hello_pending<=0;field_pending<=0;frame[0]<=sample_time;end
     32:begin field_pending<=0;timbre_id<=config_bytes[66:64];hello_pending<=0;end
     33:begin
      if(local_glide_code!=previous_local_glide)begin phase[1]<=7;error[1]<=-10;end
      else glide_code<=config_bytes[67:64];
     end
     34:begin
      pan_watch_valid<=0;
      if(!commit_pan_found)begin phase[2]<=7;error[2]<=-11;end
      else begin phase[2]<=2;dirty[2]<=0;end
      held_pan_id<=query_id;held_pan_generation<=query_generation;held_pan_slot<=id_slot;held_pan_value<=config_bytes[160:152];
     end
     35:version[3]<=fx_accepted+1'b1;
     36:begin version[4]<=gain_accepted+1'b1;target_l<=gain_local_mute?0:gain_local;target_e<=gain_external_mute?0:gain_external;end
     37:version[5]<=keymap_version+1'b1;
     39:begin reply_id<=query_id;reply_generation<=query_generation;if(!query_found)begin phase[6]<=7;error[6]<=-11;end end
     // MCU consumes HELLO/KEEP/CLOSE and PLAY, never fabricates their FPGA ACK.
     default:begin phase[0]<=7;error[0]<=-10;end
    endcase
   end
   if(session_flush)begin pan_watch_valid<=0;field_pending<=0;valid<=0;dirty<=0;result_valid<=0;end
  end
 end
 // synthesis translate_off
 reg[1538:0] identity_command_reference;
 always @(posedge clk)if(!rst&&!session_flush)begin
  if(id_req_valid&&id_req_ready)identity_command_reference<={config_slot,config_bytes};
  if((id_wait||id_prepared)&&!config_payload_changed&&{config_slot,config_bytes}!==identity_command_reference)
   $fatal(1,"R18_CONFIG_QUERY_COMMAND_BINDING");
  if(id_response_valid&&id_wait&&id_response_tag!==id_active_tag)$fatal(1,"R18_CONFIG_QUERY_RESPONSE_TAG");
  if(valid[2]&&phase[2]==2&&pan_response_valid&&pan_result==0)
   if(pan_response_slot!==held_pan_slot || pan_response_before[122:59]!==held_pan_id ||
    pan_response_before[58:43]!==held_pan_generation || pan_response_after[12:4]!==held_pan_value)
     $fatal(1,"R18_CONFIG_PAN_RESPONSE_BINDING");
 end
 // synthesis translate_on
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if((^{session_flush,session_ready,config_valid,sample_tick,gain_sample,identity_stable,local_pending,result_ready,lookup_ready,lookup_done,local_glide_code})===1'bx)$fatal(1,"S9_CONFIG_CONTROL_XZ");
  if(config_valid&&(^({config_bytes,config_slot}))===1'bx)$fatal(1,"S9_CONFIG_INPUT_XZ");
  if(gain_sample&&(^({gain_frame,gain_frame_version,gain_l,gain_e,gain_remaining}))===1'bx)$fatal(1,"S9_CONFIG_GAIN_XZ");
 end
 // synthesis translate_on
 r54_full_equal #(.WIDTH(32)) r54_equal_0_tree(.a(fx_frame_version),.b(version[3]),.equal(r54_equal_0));
 r54_full_equal #(.WIDTH(32)) r54_equal_1_tree(.a(gain_frame_version),.b(version[4]),.equal(r54_equal_1));
 r54_full_equal #(.WIDTH(32)) r54_equal_2_tree(.a(keymap_version),.b(version[5]),.equal(r54_equal_2));
endmodule

// Three streaming producers share one 32-bit RAM write port. Committed
// descriptors retain the original five global / eight local batch credits.
module r28_event_pool #(parameter integer LOCAL_BUFFER=1,FAST_READ=0,RAW_SCORE=0)(
 input wire clk,rst,
 input wire[1:0] score_owner,input wire[2:0] score_timbre,
 output wire[2:0] event_timbre,
 input wire[2:0] write_valid,output wire[2:0] write_ready,
 input wire[11:0] write_index,input wire[287:0] write_data,
 input wire[2:0] commit_valid,output wire[2:0] commit_ready,
 input wire[122:0] commit_header,input wire phone_abort,score_urgent,discard_local,
 output wire discarded,output reg rejected,output reg[1:0] rejected_source,output wire event_valid,input wire event_ready,retire,
 output wire[40:0] event_header,output wire[3:0] event_source,
 input wire item_request,input wire[3:0] item_index,output wire item_ready,
 output reg item_response,output wire[95:0] item_data,
 output reg[3:0] local_occupancy,output reg[2:0] occupancy
);
 reg[40:0] headers[0:15] /* synthesis syn_ramstyle="distributed_ram" */;
 reg[2:0] timbres[0:15];
 reg[1:0] sources[0:15] /* synthesis syn_ramstyle="distributed_ram" */;
 reg[15:0] free_rows;reg[2:0] reserved;reg[3:0] producer_rows[0:2];
 reg[8:0] written[0:2],bad[0:2];
 reg[3:0] local_rows[0:7],global_rows[0:4];
 reg[2:0] local_read,local_write,global_read,global_write;
 reg owned;reg[3:0] free_row;reg free_found;
 reg[1:0] write_left;reg[8:0] write_address;reg[95:0] write_buffer;
 reg[2:0] read_phase;reg[8:0] read_address;reg[31:0] ram_q;
 reg[95:0] read_buffer;
 reg[95:0] slow_item_data;wire[95:0] fast_item_data;
 assign item_data=FAST_READ?(occupancy!=0?fast_item_data:96'd0):slow_item_data;
 always @*begin
  free_found=0;free_row=0;
  for(integer s=15;s>=0;s--)if(free_rows[s])begin free_found=1;free_row=4'(s);end
 end
 function bad_item(input[95:0] w);
  bad_item=w[0]||w[27:24]<1||w[27:24]>4||
    (w[27:24]==4&&(w[23:16]!=255||w[15:9]!=0))||(w[27:24]!=4&&w[95:32]==0);
 endfunction
 function[8:0] address(input[3:0] row,input[3:0] index);
  address={row,5'd0}+{5'd0,index}+({5'd0,index}<<1);
 endfunction
 wire[3:0] head=global_rows[global_read];
 assign event_header=occupancy!=0?headers[head]:41'd0;
 assign event_source=occupancy!=0?{2'd0,sources[head]}:4'd0;
 assign event_timbre=RAW_SCORE&&occupancy!=0&&sources[head]==3?timbres[head]:3'd0;
 assign discarded=!rst&&occupancy!=0&&!owned&&discard_local&&event_source==0;
 // Validation is performed once, before a producer descriptor is committed.
 wire first_valid,first_ready,choose_score;
 performance_event_arbiter #(.WIDTH(1)) choice(.clk(clk),.rst(rst),
 .s0_valid(LOCAL_BUFFER?(local_occupancy!=0):(commit_valid[0]&&reserved[0]&&write_left==0&&!write_valid[0]&&!discard_local)),.s0_data(1'b0),.s0_ready(),
 .s1_valid(commit_valid[1]&&reserved[1]&&write_left==0&&!write_valid[1]),.s1_data(1'b1),.s1_ready(),
 .m_valid(first_valid),.m_ready(first_ready),.m_data(choose_score));
 wire choose_phone=!first_valid&&!score_urgent;
 wire space=occupancy<5||retire||discarded;
 wire local_commit=!rst&&commit_valid[0]&&commit_ready[0];
 wire promote=LOCAL_BUFFER&&!rst&&space&&first_valid&&!choose_score;
 wire score_commit=!rst&&space&&first_valid&&choose_score&&!local_commit;
 wire phone_commit=!rst&&space&&choose_phone&&commit_valid[2]&&reserved[2]&&write_left==0&&!write_valid[2]&&!phone_abort&&!local_commit;
 assign commit_ready[0]=!rst&&!discard_local&&reserved[0]&&write_left==0&&!write_valid[0]&&
   (LOCAL_BUFFER?(local_occupancy<8||promote):(space&&first_valid&&!choose_score));
 assign commit_ready[1]=!rst&&space&&first_valid&&choose_score&&!local_commit;
 assign commit_ready[2]=!rst&&space&&choose_phone&&reserved[2]&&write_left==0&&!write_valid[2]&&!phone_abort&&!local_commit;
 wire[2:0] committing={phone_commit,score_commit,local_commit};
 wire[1:0] committer=local_commit?0:score_commit?1:2;
 wire[2:0] malformed;
 generate for(genvar p=0;p<3;p++)begin: validation
  wire[8:0] mask=commit_header[p*41+:9];
  assign malformed[p]=mask==0|||(mask&(~written[p]|bad[p]));
 end endgenerate
 wire malformed_commit=|(committing&malformed);
 wire admit=promote||(!LOCAL_BUFFER&&local_commit&&!malformed[0])||(score_commit&&!malformed[1])||(phone_commit&&!malformed[2]);
 wire local_push=LOCAL_BUFFER&&local_commit&&!malformed[0];
 assign first_ready=promote||score_commit||(!LOCAL_BUFFER&&local_commit);
 wire[3:0] admitted_row=promote?local_rows[local_read]:!LOCAL_BUFFER&&local_commit?producer_rows[0]:phone_commit?producer_rows[2]:producer_rows[1];
 wire release_head=retire||discarded;
 assign event_valid=!rst&&occupancy!=0&&!owned&&!discarded;
 wire storage_idle=!rst&&write_left==0;
 assign write_ready[0]=storage_idle&&!discard_local&&!committing[0]&&(reserved[0]||(free_found&&(!LOCAL_BUFFER||local_occupancy<8)));
 wire w0=write_valid[0]&&write_ready[0];
 assign write_ready[1]=storage_idle&&!w0&&!committing[1]&&(reserved[1]||free_found);
 wire w1=write_valid[1]&&write_ready[1];
 assign write_ready[2]=storage_idle&&!w0&&!w1&&!committing[2]&&!phone_abort&&(reserved[2]||free_found);
 wire w2=write_valid[2]&&write_ready[2];
 wire writing=w0||w1||w2;wire[1:0] writer=w0?0:w1?1:2;
 wire[3:0] wi=write_index[writer*4+:4];wire[95:0] wd=write_data[writer*96+:96];
 wire[3:0] row=reserved[writer]?producer_rows[writer]:free_row;
 wire allocate=writing&&!reserved[writer];
 reg[15:0] freeing;
 always @*begin
  freeing=release_head?(16'h1<<head):16'd0;
  for(integer p=0;p<3;p++)if(committing[p]&&malformed[p])freeing=freeing|(16'h1<<producer_rows[p]);
  if(phone_abort&&reserved[2])freeing=freeing|(16'h1<<producer_rows[2]);
  if(discard_local&&reserved[0])freeing=freeing|(16'h1<<producer_rows[0]);
 end
 // Independent RAM read and write ports never address the same owned row.
 generate if(FAST_READ)begin: wide_memory
  reg[95:0] body[0:255] /* synthesis syn_ramstyle="block_ram" */;
  reg[95:0] q;
  always @(posedge clk)begin
   q<=body[{head,item_index}];
   if(writing)body[{row,wi}]<=wd;
  end
  assign fast_item_data=q;
 end else begin: narrow_memory
  reg[31:0] body[0:511] /* synthesis syn_ramstyle="block_ram" */;
  always @(posedge clk)begin
   ram_q<=body[read_address];
   if(!rst&&write_left!=0)body[write_address]<=write_buffer[31:0];
  end
  assign fast_item_data=0;
 end endgenerate
 assign item_ready=!rst&&owned&&(FAST_READ||read_phase==0)&&!retire;
 always @(posedge clk)begin
  item_response<=0;
  rejected<=malformed_commit;
  if(malformed_commit)rejected_source<=committer;
  if(rst)begin
   rejected<=0;rejected_source<=0;
   free_rows<=16'hffff;reserved<=0;owned<=0;
   local_read<=0;local_write<=0;global_read<=0;global_write<=0;local_occupancy<=0;occupancy<=0;
   write_left<=0;write_address<=0;write_buffer<=0;read_phase<=0;read_address<=0;read_buffer<=0;slow_item_data<=0;
   for(integer p=0;p<3;p++)begin producer_rows[p]<=0;written[p]<=0;bad[p]<=0;end
  end else begin
   free_rows<=(free_rows|freeing)&~(allocate?(16'h1<<free_row):16'd0);
   if(writing)begin
    write_address<=address(row,wi);write_left<=FAST_READ?0:3;write_buffer<=wd;
    reserved[writer]<=1;producer_rows[writer]<=row;
    written[writer]<=(reserved[writer]?written[writer]:9'd0)|(9'b1<<wi);
    bad[writer]<=((reserved[writer]?bad[writer]:9'd0)&~(9'b1<<wi))|(bad_item(wd)?(9'b1<<wi):9'd0);
   end else if(write_left!=0)begin write_left<=write_left-1'b1;write_address<=write_address+1'b1;write_buffer<=write_buffer>>32;end
   if(|committing)begin
    reserved[committer]<=0;
    headers[producer_rows[committer]]<=commit_header[committer*41+:41];sources[producer_rows[committer]]<=RAW_SCORE&&committer==1?score_owner:committer;
    if(RAW_SCORE&&committer==1)timbres[producer_rows[committer]]<=score_timbre;
   end
   if(phone_abort)reserved[2]<=0;
   if(discard_local)reserved[0]<=0;
   if(local_push)begin local_rows[local_write]<=producer_rows[0];local_write<=local_write+1'b1;end
   if(promote)local_read<=local_read+1'b1;
   case({local_push,promote})
    2'b10:local_occupancy<=local_occupancy+1'b1;
    2'b01:local_occupancy<=local_occupancy-1'b1;
    default:begin end
   endcase
   if(admit)begin global_rows[global_write]<=admitted_row;global_write<=global_write==4?0:global_write+1'b1;end
   if(event_valid&&event_ready)owned<=1;
   if(release_head)begin owned<=0;global_read<=global_read==4?0:global_read+1'b1;end
   case({admit,release_head})
    2'b10:occupancy<=occupancy+1'b1;
    2'b01:occupancy<=occupancy-1'b1;
    default:begin end
   endcase
   if(FAST_READ)item_response<=item_request&&item_ready;
   else if(item_request&&item_ready)begin read_phase<=1;read_address<=address(head,item_index);end
   else if(read_phase!=0)begin
    if(read_phase==4)begin slow_item_data<={ram_q,read_buffer[95:32]};item_response<=1;read_phase<=0;end
    else begin
     if(read_phase!=1)read_buffer<={ram_q,read_buffer[95:32]};
     if(read_phase<3)read_address<=read_address+1'b1;
     read_phase<=read_phase+1'b1;
    end
   end
   if(retire||discarded)begin read_phase<=0;item_response<=0;end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(local_occupancy>8||occupancy>5)$fatal(1,"R28_POOL_CAPACITY");
  if(retire&&(!owned||occupancy==0))$fatal(1,"R28_POOL_RETIRE");
  if(allocate&&!free_found)$fatal(1,"R28_POOL_OVERWRITE");
  if(writing&&wi>=9)$fatal(1,"R28_POOL_WRITE_INDEX");
  if(item_request&&item_ready&&(item_index>=9||!event_header[item_index]))$fatal(1,"R28_POOL_READ_INDEX");
 end
 // synthesis translate_on
endmodule

// Capture physical input changes as compact frames, then construct one event
// at a time. Independent key tokens live in a single addressed RAM.
module r28_local_adapter(
 input wire clk,rst,overflow_recover,input wire[31:0] sample_time,
 input wire[7:0] note_gate,note_trigger,vibrato_depth,
 input wire[63:0] pressure_value,input wire[55:0] note_code,
 output wire write_valid,input wire write_ready,output wire[3:0] write_index,output wire[95:0] write_data,
 output wire commit_valid,input wire commit_ready,output wire[40:0] commit_header,
 output reg overflow,output wire pending,output reg[3:0] occupancy
);
 localparam[55:0] BASE={7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
 reg[7:0] previous_gate,previous_vibrato;reg[63:0] previous_pressure;reg[55:0] previous_notes;
 reg[63:0] token_counter;reg[63:0] key_tokens[0:7] /* synthesis syn_ramstyle="distributed_ram" */;
 reg[7:0] token_initialized;
 // Thirteen consecutive input edges fit even before serialization catches
 // up: this preserves the old five global + eight local burst capacity.
 // RAM16 primitives already have sixteen physical rows.
 reg[176:0] frames[0:15] /* synthesis syn_ramstyle="distributed_ram" */;
 reg[3:0] read_pointer,write_pointer;reg[176:0] frame;
 reg[3:0] slot;reg[1:0] state;
 reg[15:0] kinds;reg[8:0] changed;
 always @*begin
  kinds=0;changed=0;
  for(integer s=0;s<8;s++)begin
   if(note_trigger[s]||(note_gate[s]&&!previous_gate[s]))kinds[s*2+:2]=1;
   else if(!note_gate[s]&&previous_gate[s])kinds[s*2+:2]=2;
   else if(note_gate[s]&&(pressure_value[s*8+:8]!=previous_pressure[s*8+:8]||note_code[s*7+:7]!=previous_notes[s*7+:7]))kinds[s*2+:2]=3;
   changed[s]=kinds[s*2+:2]!=0;
  end
  changed[8]=vibrato_depth!=previous_vibrato;
 end
 wire pop=!rst&&state==0&&occupancy!=0&&!overflow;
 wire push=!rst&&|changed&&!overflow&&(occupancy<13||pop);
 wire[1:0] kind=frame[128+slot*2+:2];
 wire[63:0] next_token=token_counter==64'hffffffffffffffff ?64'd1:token_counter+64'd1;
 wire[63:0] selected_token=kind==1?next_token:token_initialized[slot[2:0]]?key_tokens[slot[2:0]]:64'd0;
 wire enabled=slot==8?frame[144]:kind!=0;
 assign write_valid=!rst&&!overflow&&state==1&&enabled;
 assign write_index=slot;
 assign write_data=slot==8?{64'd0,4'd0,4'd4,8'hff,7'd0,frame[7:0],1'b0}:
  {selected_token,4'd0,2'd0,kind,4'd0,slot,frame[72+slot*7+:7],frame[8+slot*8+:8],1'b0};
 reg[8:0] frame_mask;
 assign commit_header={frame[176:145],frame_mask};
 assign commit_valid=!rst&&!overflow&&state==2;
 assign pending=state!=0||occupancy!=0;
 always @(posedge clk)begin
  if(push)frames[write_pointer]<={sample_time,changed[8],kinds,note_code,pressure_value,vibrato_depth};
  if(write_valid&&write_ready&&slot<8&&kind==1)key_tokens[slot[2:0]]<=next_token;
 end
 always @(posedge clk)begin
  if(rst)begin
   previous_gate<=0;previous_vibrato<=0;previous_pressure<=0;previous_notes<=BASE;
   token_counter<=0;token_initialized<=0;read_pointer<=0;write_pointer<=0;occupancy<=0;
   state<=0;slot<=0;frame<=0;frame_mask<=0;overflow<=0;
  end else begin
   previous_gate<=note_gate;previous_vibrato<=vibrato_depth;previous_pressure<=pressure_value;previous_notes<=note_code;
   if(push)write_pointer<=write_pointer+1'b1;
   if(pop)begin read_pointer<=read_pointer+1'b1;frame<=frames[read_pointer];state<=1;slot<=0;frame_mask<=0;end
   case({push,pop})
    2'b10:occupancy<=occupancy+1'b1;
    2'b01:occupancy<=occupancy-1'b1;
    default:begin end
   endcase
   if(state==1&&(!enabled||write_ready))begin
    if(enabled)begin
     frame_mask[slot]<=1;
     if(slot<8&&kind==1)begin token_counter<=next_token;token_initialized[slot[2:0]]<=1;end
    end
    if(slot==8)state<=2;else slot<=slot+1'b1;
   end
   if(commit_valid&&commit_ready)state<=0;
   if(|changed&&!overflow&&occupancy==13&&!pop)overflow<=1;
   if(overflow)begin
    state<=0;occupancy<=0;read_pointer<=0;write_pointer<=0;
    if(overflow_recover&&note_gate==0)overflow<=0;
   end
  end
 end
endmodule

// R28 prototype: transaction state and audio state are different owners.
// Full external identities are retained; only the control computation is shared.
// VOICES slots in LANES=VOICES/8 Lanes. SIW indexes a slot; SW is the
// external slot field, one bit wider when VOICES is a power of two so the
// all-ones "no slot" value never names a real slot.
module r28_serial_control #(parameter integer ID_WIDTH=64,LOOP_ENABLE=0,VOICES=48,
  SIW=$clog2(VOICES),SW=(VOICES==(1<<$clog2(VOICES)))?$clog2(VOICES)+1:$clog2(VOICES),LANES=VOICES/8)(
 input wire loop_cleanup_valid,loop_cleanup_all,loop_abort_batch,input wire[1:0] loop_cleanup_sources,input wire[15:0] loop_cleanup_revision,
 output wire loop_cleanup_ready,output reg loop_cleanup_done,
 input wire clk,rst,frame_tick,audio_retire,hold_publication,panic,
 input wire session_flush,session_ready,
 input wire lookup_valid,input wire[7:0] lookup_key,input wire[63:0] lookup_identity,
 input wire[15:0] lookup_generation,lookup_tag,
 output wire lookup_ready,lookup_response_valid,lookup_found,
 output wire[SW-1:0] lookup_response_slot,output wire[314:0] lookup_response_word,
 output wire[15:0] lookup_response_tag,
 input wire pan_valid,input wire[SW-1:0] pan_slot,input wire[63:0] pan_id,
 input wire[15:0] pan_generation,input wire[8:0] pan_value,
 output wire pan_ready,pan_response_valid,output wire[1:0] pan_result,
 output wire[SW-1:0] pan_response_slot,output wire[314:0] pan_before,pan_after,
 input wire[VOICES-1:0] audio_reclaim,
 output wire[SW-1:0] level_read_slot,input wire[16:0] level_read_value,
 input wire event_valid,output wire event_ready,input wire[95:0] event_item,
 input wire event_last,input wire[2:0] timbre,
 output reg fact_valid,output wire[95:0] fact_item,
 output reg[7:0] fact_outcome,output reg[SW-1:0] fact_slot,
 output reg fact_steal,output wire[314:0] fact_before,fact_after,
 output reg batch_done,batch_abort,published,
 input wire[3*LANES-1:0] audio_read_slots,audio_pan_slots,
 output wire[31*LANES-1:0] audio_read_controls,output wire[9*LANES-1:0] audio_read_pans,
 output wire[4*VOICES-1:0] audio_flags,output reg[7:0] audio_vibrato,
 output wire[31*VOICES-1:0] control_state,
 output wire busy,output reg protocol_error,
 input wire snapshot_valid,output wire snapshot_ready,output reg snapshot_done,
 input wire query_valid,output wire query_ready,input wire[1:0] query_view,
 input wire[SW-1:0] query_slot,output reg query_response_valid,
 output wire[314:0] query_response,
 output reg[31:0] accepted_events,output reg[31:0] max_event_cycles
);
 wire r54_equal_0;

 localparam[63:0] ID_MAX=64'hffffffffffffffff>>(64-ID_WIDTH);
 localparam[7:0] IDLE=0,SCAN_WORK=1,SCAN_AUDIO=2,SELECT=3,BEFORE=4,
   APPLY=5,FINISH=6,COPY_READ=7,COPY_GOT=8,COPY_NEXT=9,
   QUERY_GOT=10,RECLAIM_AUDIO=11,RECLAIM_WORK=12,RECLAIM_DONE=13,
   PREP_READ=14,PREP_GOT=15,RECLAIM_WRITTEN=16,
   LOOKUP_GOT=17,LOOKUP_REPLY=18,PAN_GOT=19,PAN_APPLY=20,PAN_REPLY=21,
   RANK_UPDATE=22,ID_LOW=23,ID_HIGH=24,SELECT_DONE=25,INIT=26,READ_WORDS=250,WRITE_WORDS=251;
 localparam[7:0] LOOP_READ=40,LOOP_GOT=41,LOOP_APPLY=42,LOOP_NEXT=43;
 reg[SW-1:0] loop_scan;reg loop_all;reg[1:0] loop_sources;reg[15:0] loop_revision;
 reg loop_cleanup_pending,loop_wait_output;
 reg[7:0] state,return_state;
 localparam integer AW=2+SIW+3;
 // Banks 0/1 (work/audio) and 2 (frozen snapshot); bank 3 is never addressed.
 // Six words per row: control, metadata, two identity words, two token words.
 localparam integer ROW_WORDS=6,BANK_WORDS=ROW_WORDS*(1<<SIW);
 // Work/audio banks and the frozen bank are separate arrays so each maps to
 // the widest BSRAM shape its depth allows.
 localparam[AW-1:0] FROZEN_BASE=2*BANK_WORDS;
 reg[31:0] live_memory[0:2*BANK_WORDS-1] /* synthesis syn_ramstyle="block_ram" */;
 reg[31:0] frozen_memory[0:BANK_WORDS-1] /* synthesis syn_ramstyle="block_ram" */;
 reg[2:0] init_word;
 reg[AW-1:0] read_address,write_base;
 reg[31:0] live_q,frozen_q;reg frozen_read;
 wire[31:0] memory_q=frozen_read?frozen_q:live_q;
 // R46: stream each aligned word. Only valid reply/fact operands are
 // assembled; scans and bank copies never instantiate a whole-row shifter.
 reg[186:0] record_q;
 wire[155:0] old_metadata=record_q[186:31];
 wire[30:0] old_control=record_q[30:0];
 assign query_response={128'd0,record_q};
 reg[30:0] control_q;
 // R78: read the original key only for the private audio directory.
 // Full allocator facts, snapshots and observed pitch keep the original note.
 reg[2:0] prepared_key;
 reg[SW-1:0] read_slot_q;reg[1:0] read_bank_q,write_mode;
 reg[2:0] read_cycle,write_cycle,write_last;
 reg meta_equal,id_equal,token_equal,id_carry;
 reg[15:0] next_generation;
 wire copying=state==READ_WORDS&&return_state==COPY_GOT&&read_cycle!=0;
 wire memory_write=!rst&&(state==WRITE_WORDS||copying||state==INIT);
 reg[31:0] memory_write_data;
 reg[3:0] audible[0:VOICES-1];
 reg[4*VOICES-1:0] prepared_flags;reg[4*VOICES-1:0] frozen_flags;reg prepared_valid;reg[SW-1:0] prepare_slot;
 reg[SW-1:0] rank[0:VOICES-1] /* synthesis syn_ramstyle="distributed_ram" */;
 reg[SW-1:0] rank_cursor,selected_rank;
 // After reset, INIT writes every row with the empty-slot value (control
 // 2048, other words 0) and rank[s]=s. Reads then need no per-slot
 // row-valid masks; only the audio directory waits for its first publish.
 reg audio_published;
 reg work_bank,audio_bank,dirty,in_batch,copy_snapshot,panic_pending,panic_urgent,publish_due;
 reg[VOICES-1:0] allocated_since_publish;
 reg[VOICES-1:0] phone_owned;reg session_live,lookup_cancelled;
 reg[7:0] lookup_key_q;reg[63:0] control_id;reg[15:0] control_generation,control_tag;
 reg[8:0] control_pan;reg lookup_found_q;reg[1:0] pan_status;
 reg[SW-1:0] copy_slot,scan_slot,selected_slot,query_slot_q;
 reg[1:0] query_view_q;
 reg[7:0] working_vibrato;
 reg[VOICES-1:0] pending_reclaim;
 // The reclaim set, its emptiness and its lowest member are registered from
 // the same next value, so admission and slot selection read flip-flops
 // instead of a VOICES-input reduction and priority encoder.
 reg reclaim_any;reg[SW-1:0] reclaim_first;
 wire[VOICES-1:0] reclaim_clear=(!rst&&state==RECLAIM_WRITTEN)?VOICES'(1)<<selected_slot:VOICES'(0);
 wire[VOICES-1:0] reclaim_next=rst?VOICES'(0):((pending_reclaim|(audio_retire?audio_reclaim:VOICES'(0)))&~reclaim_clear);
 reg[SW-1:0] reclaim_lowest;
 always @*begin reclaim_lowest=0;for(integer s=VOICES-1;s>=0;s--)if(reclaim_next[s])reclaim_lowest=SW'(s);end
 always @(posedge clk)begin pending_reclaim<=reclaim_next;reclaim_any<=reclaim_next!=0;reclaim_first<=reclaim_lowest;end
 reg[95:0] item_q;
 reg last_q;reg[2:0] timbre_q;
 reg[63:0] id_cursor;
 reg collision_mode,collision_hit,retry_scan;
 reg[63:0] search_id;reg[6:0] identity_retries;
 // Victim order is (class, level, rank); the scan is ascending and the
 // comparison strict, so equal keys keep the lowest slot without comparing it.
 localparam integer KW=2+17+SW;
 reg[KW-1:0] best;
 reg[SW-1:0] victim,target;
 reg found;

 reg[63:0] chosen_id,following_id;
 reg[31:0] event_age;
 // R45: item_q remains owned until the valid fact is consumed.
 // Reclaim has no input event. Invalid-cycle residue is not consumed.
 assign fact_item=fact_outcome==10?96'd0:item_q;
 wire[3:0] kind=item_q[27:24];
 wire invalid_item=item_q[0]||kind<1||kind>4||
  (kind==4&&(item_q[23:16]!=255||item_q[15:9]!=0))||
  (kind!=4&&item_q[95:32]==0);
 wire stale=(kind==1&&found)||((kind==2||kind==3)&&!found);
 wire collision_scan=kind==1&&collision_mode;
 wire[30:0] scan_control=work_control(control_q);
 wire[SW-1:0] rank_read_slot=state==RANK_UPDATE?rank_cursor:read_slot_q;
 wire[SW-1:0] rank_read=rank[rank_read_slot];
 wire rank_we=!rst&&state==RANK_UPDATE;
 wire[SW-1:0] rank_next=rank_cursor==selected_slot?SW'(VOICES-1):rank_read>selected_rank?rank_read-1'b1:rank_read;
 always @(posedge clk)begin
  if(rank_we)rank[rank_cursor]<=rank_next;
  else if(!rst&&state==INIT&&write_base<VOICES)rank[SW'(write_base)]<=SW'(write_base);
 end
 wire[KW-1:0] candidate={(!scan_control[1]?2'd0:(!scan_control[2]?2'd1:2'd2)),
   (!scan_control[1]||scan_control[2]||scan_control[0])?17'd0:level_read_value,
   scan_control[1]?rank_read:SW'(0)};
 // Victim choice reads the current envelope level of the scanned slot
 // through the engine's read port instead of a whole-pool snapshot.
 assign level_read_slot=read_slot_q;
 wire matching=scan_control[1]&&scan_control[2]&&meta_equal&&token_equal;
 // One pair of 32-bit operands serves streaming equality, victim ordering,
 // generation increment and both halves of identity increment.
 reg[31:0] alu_a,alu_b;reg alu_sub;
 always @*begin
  alu_a=0;alu_b=0;alu_sub=0;
  if(state==READ_WORDS)begin
   alu_a=memory_q;
   case(read_cycle)
    2:begin
     if(return_state==LOOKUP_GOT)begin alu_a=memory_q&32'h0fffff00;alu_b={4'd0,control_generation,4'd2,8'd0};end
     else if(return_state==PAN_GOT)begin alu_a=memory_q&32'h0ffff000;alu_b={4'd0,control_generation,12'd0};end
     else if(return_state==RECLAIM_DONE)begin alu_a=memory_q&32'h0ffff000;alu_b={4'd0,old_metadata[27:12],12'd0};end
     else begin alu_a={20'd0,memory_q[11:0]};alu_b={20'd0,item_q[31:28],item_q[23:16]};end
    end
    3:alu_b=return_state==RECLAIM_DONE?record_q[90:59]:return_state==PAN_GOT?control_id[31:0]:search_id[31:0];
    4:alu_b=return_state==RECLAIM_DONE?record_q[122:91]:return_state==PAN_GOT?control_id[63:32]:search_id[63:32];
    5:alu_b=return_state==LOOKUP_GOT?control_id[31:0]:item_q[63:32];
    6:alu_b=return_state==LOOKUP_GOT?control_id[63:32]:item_q[95:64];
    default:begin end
   endcase
  end else if(state==SCAN_WORK)begin alu_a=32'(candidate);alu_b=32'(best);alu_sub=1;end
  else if(state==ID_LOW)begin alu_a=search_id[31:0];alu_b=1;end
  else if(state==ID_HIGH)begin alu_a=search_id[63:32];alu_b={31'd0,id_carry};end
  else if(state==BEFORE)begin alu_a={16'd0,old_metadata[27:12]};alu_b=1;end
 end
 wire[32:0] alu_sum={1'b0,alu_a}+{1'b0,alu_b^{32{alu_sub}}}+alu_sub;
 wire alu_equal=r54_equal_0;
 wire candidate_less=!alu_sum[32];
 wire capture_record=return_state==BEFORE||return_state==QUERY_GOT||return_state==LOOKUP_GOT||return_state==PAN_GOT||return_state==RECLAIM_WORK||return_state==LOOP_GOT;
 wire[31:0] record_data=memory_q;
 wire[30:0] record_control=read_bank_q==2?memory_q[30:0]:
   read_bank_q[0]==work_bank?work_control(memory_q[30:0]):{memory_q[30:4],audible[read_slot_q]};
 reg[30:0] new_control;reg[155:0] new_metadata;
 // Fact consumers sample only while fact_valid. These operands already stay
 // registered through that edge; a second pair of wide result registers is redundant.
 assign fact_before=fact_outcome==10?{128'd0,old_metadata,old_control[30:2],1'b1,old_control[0]}:
   {128'd0,old_metadata,old_control};
 assign fact_after=fact_outcome==10?{128'd0,old_metadata,old_control[30:2],1'b0,old_control[0]}:
   {128'd0,(fact_outcome>=1&&fact_outcome<=3)?new_metadata:old_metadata,
           (fact_outcome>=1&&fact_outcome<=3)?new_control:old_control};
 always @*begin
  new_control=old_control;new_metadata=old_metadata;
  if(kind==1)begin
   new_control={timbre_q,item_q[8:1],item_q[15:9],9'd128,4'b1111};
   new_metadata={item_q[95:32],chosen_id,next_generation,item_q[31:28],item_q[23:16]};
  end else if(kind==2)new_control[2]=0;
  else if(kind==3)begin new_control[27:20]=item_q[8:1];new_control[19:13]=item_q[15:9];end
 end
 // bank*BANK_WORDS + slot*6 as explicit shifts and adds: BANK_WORDS is
 // 3<<(SIW+1) and 6 is 4+2.
 function[AW-1:0] row_address(input[1:0] bank,input[SW-1:0] slot);
  reg[AW-1:0] b,s;
  begin
   b={{(AW-2){1'b0}},bank};s={{(AW-SIW){1'b0}},slot[SIW-1:0]};
   row_address=(((b<<1)+b)<<(SIW+1))+(s<<2)+(s<<1);
  end
 endfunction
 // Every per-slot flag read happens while the row of read_slot_q is being
 // read (scan, prepare, copy, query, lookup, reclaim, loop, apply), so all of
 // them share that one index: one VOICES-input selector per flag vector.
 function[30:0] work_control(input[30:0] raw);
  begin
   work_control=raw;
   if(!allocated_since_publish[read_slot_q])begin work_control[0]=0;work_control[3]=0;end
   if(panic_urgent)work_control[3:0]=0;
  end
 endfunction
 task read_row(input[1:0] bank,input[SW-1:0] slot,input[7:0] continuation);
  begin read_address<=row_address(bank,slot);read_cycle<=0;read_slot_q<=slot;read_bank_q<=bank;
   meta_equal<=0;id_equal<=0;token_equal<=0;
   if(continuation==COPY_GOT)write_base<=row_address(copy_snapshot?2'd2:{1'b0,work_bank},slot);
   return_state<=continuation;state<=READ_WORDS;end
 endtask
 task write_words(input[1:0] mode,input[2:0] last_word,input[7:0] continuation);
  begin write_base<=row_address({1'b0,work_bank},selected_slot);write_cycle<=0;write_last<=last_word;write_mode<=mode;
   return_state<=continuation;state<=WRITE_WORDS;end
 endtask
 task next_scan;
  begin
   if(scan_slot==VOICES-1)state<=SELECT;
   else begin scan_slot<=scan_slot+1'b1;read_row({1'b0,work_bank},scan_slot+1'b1,SCAN_WORK);end
  end
 endtask
 always @*begin
  memory_write_data=0;
  if(copying)begin
   memory_write_data=memory_q;
   if(read_cycle==1)memory_write_data={1'b0,memory_q[30:4],
     copy_snapshot?frozen_flags[3:0]:audible[read_slot_q]};
  end else if(state==INIT)memory_write_data=init_word==0?32'd2048:32'd0;
  else if(write_mode==1)memory_write_data={1'b0,old_control[30:13],control_pan,old_control[3:0]};
  else if(write_mode==2)memory_write_data={1'b0,control_q[30:2],1'b0,control_q[0]};
  else if(write_mode==3)memory_write_data={1'b0,old_control[30:4],allocated_since_publish[read_slot_q]?4'd0:(old_control[3:0]&4'b1011)};
  else case(write_cycle)
   0:memory_write_data={1'b0,new_control};
   1:memory_write_data={4'd0,next_generation,item_q[31:28],item_q[23:16]};
   2:memory_write_data=chosen_id[31:0];
   3:memory_write_data=chosen_id[63:32];
   4:memory_write_data=item_q[63:32];
   5:memory_write_data=item_q[95:64];
  endcase
 end
 always @(posedge clk)begin
  frozen_read<=read_address>=FROZEN_BASE;
  live_q<=live_memory[read_address];frozen_q<=frozen_memory[read_address-FROZEN_BASE];
  if(memory_write)begin
   if(write_base>=FROZEN_BASE)frozen_memory[write_base-FROZEN_BASE]<=memory_write_data;
   else live_memory[write_base]<=memory_write_data;
  end
 end
 assign loop_cleanup_ready=LOOP_ENABLE&&!rst&&state==IDLE&&!in_batch&&!loop_cleanup_pending&&!panic&&!panic_pending;
 assign event_ready=!rst&&!(LOOP_ENABLE&&((loop_cleanup_valid&&!in_batch)||loop_cleanup_pending))&&state==IDLE&&
   (in_batch?!(query_valid&&query_view==2):(!snapshot_valid&&!query_valid&&!lookup_valid&&!pan_valid))&&(!reclaim_any||in_batch)&&
   !((frame_tick||publish_due)&&dirty&&!in_batch&&(!hold_publication||panic_urgent||loop_cleanup_pending))&&!panic&&!panic_pending;
 assign snapshot_ready=!rst&&state==IDLE&&!in_batch&&!loop_cleanup_pending&&!dirty&&!reclaim_any&&!panic&&!panic_pending;
 wire publication_service=dirty&&!in_batch&&(!hold_publication||panic_urgent||loop_cleanup_pending)&&(publish_due||frame_tick);
 assign query_ready=!rst&&state==IDLE&&!publication_service&&!snapshot_valid&&!pan_valid&&!lookup_valid&&
   (query_view==2||!in_batch)&&(!reclaim_any||(in_batch&&query_view==2))&&!panic&&!panic_pending;
 assign pan_ready=!rst&&state==IDLE&&!publication_service&&!in_batch&&!snapshot_valid&&!reclaim_any&&!panic&&!panic_pending;
 assign lookup_ready=pan_ready&&!pan_valid;
 assign lookup_response_valid=!rst&&state==LOOKUP_REPLY;
 assign lookup_found=lookup_found_q&&!lookup_cancelled&&!session_flush&&session_ready&&!panic&&!panic_pending;
 assign lookup_response_slot=selected_slot;assign lookup_response_word={128'd0,old_metadata,old_control};
 assign lookup_response_tag=control_tag;
 assign pan_response_valid=!rst&&state==PAN_REPLY;
 assign pan_result=panic||panic_pending?2'd3:pan_status;
 assign pan_response_slot=selected_slot;assign pan_before={128'd0,old_metadata,old_control};
 assign pan_after=pan_status==0?{128'd0,old_metadata,old_control[30:13],control_pan,old_control[3:0]}:pan_before;
 assign busy=state!=IDLE||in_batch;
 generate
 for(genvar s=0;s<VOICES;s++)begin: view
  assign audio_flags[s*4+:4]=audible[s];
 end
 for(genvar l=0;l<LANES;l++)begin: audio_directory
  // Audio has two selected-slot read ports. Display has a parallel timbre
  // snapshot. Keep its observation mirror separate so those parallel reads
  // cannot turn the audio directory into a many-port register file.
  reg[26:0] controls[0:15];
  wire[2:0] rs=audio_read_slots[l*3+:3],ps=audio_pan_slots[l*3+:3];
  wire[27:0] rc;
  wire[11:0] pc;
  wire[SW-1:0] slot=SW'(l*8)+rs,pan_slot=SW'(l*8)+ps;
  wire[30:0] preparing=work_control(control_q);
  wire directory_write=!rst&&state==PREP_GOT&&prepare_slot[SW-1:3]==l;
  wire[26:0] sound_controls=preparing[30:28]==3'd5 ?
   {preparing[30:20],4'd0,prepared_key,preparing[12:4]}:preparing[30:4];
  wire[27:0] write_controls={1'b0,sound_controls};
  wire[11:0] write_pan={3'b0,preparing[12:4]};
  for(genvar w=0;w<7;w++)begin: audio_words
   RAM16SDP4 memory(.CLK(clk),.WRE(directory_write),.WAD({work_bank,prepare_slot[2:0]}),
    .RAD({audio_bank,rs}),.DI(write_controls[w*4+:4]),.DO(rc[w*4+:4]));
  end
  for(genvar w=0;w<3;w++)begin: pan_words
   RAM16SDP4 memory(.CLK(clk),.WRE(directory_write),.WAD({work_bank,prepare_slot[2:0]}),
    .RAD({audio_bank,ps}),.DI(write_pan[w*4+:4]),.DO(pc[w*4+:4]));
  end
  always @(posedge clk)if(!rst&&state==PREP_GOT&&prepare_slot[SW-1:3]==l)
   controls[{work_bank,prepare_slot[2:0]}]<=preparing[30:4];
  assign audio_read_controls[l*31+:31]=audio_published?{rc[26:0],audible[slot]}:31'd2048;
  assign audio_read_pans[l*9+:9]=audio_published?pc[8:0]:9'd128;
  // The board retains the three timbre bits per slot for its visual status;
  // unused note/pressure/Pan observation bits are removed by synthesis.
  for(genvar v=0;v<8;v++)begin: observation
   assign control_state[(l*8+v)*31+:31]=audio_published?
    {controls[{audio_bank,3'(v)}],audible[l*8+v]}:31'd2048;
  end
 end
 endgenerate
 always @(posedge clk)begin
  loop_cleanup_done<=0;fact_valid<=0;batch_done<=0;batch_abort<=0;published<=0;snapshot_done<=0;query_response_valid<=0;
  if(rst)begin
   loop_scan<=0;loop_all<=0;loop_sources<=0;loop_revision<=0;loop_cleanup_done<=0;loop_cleanup_pending<=0;loop_wait_output<=0;
   state<=INIT;init_word<=0;return_state<=IDLE;read_address<=0;write_base<=0;
   record_q<=0;control_q<=0;prepared_key<=0;read_cycle<=0;write_cycle<=0;write_last<=0;write_mode<=0;read_slot_q<=0;read_bank_q<=0;meta_equal<=0;id_equal<=0;token_equal<=0;id_carry<=0;next_generation<=0;
   prepared_flags<=0;frozen_flags<=0;prepared_valid<=0;prepare_slot<=0;
   work_bank<=0;audio_bank<=1;dirty<=0;in_batch<=0;copy_snapshot<=0;copy_slot<=0;
   panic_pending<=0;panic_urgent<=0;allocated_since_publish<=0;publish_due<=0;
   phone_owned<=0;session_live<=0;lookup_cancelled<=0;lookup_key_q<=0;control_id<=0;
   control_generation<=0;control_tag<=0;control_pan<=128;lookup_found_q<=0;pan_status<=0;
   audio_published<=0;
   scan_slot<=0;selected_slot<=0;query_slot_q<=0;query_view_q<=0;
   working_vibrato<=0;audio_vibrato<=0;
   item_q<=0;last_q<=0;timbre_q<=0;id_cursor<=1;collision_mode<=0;collision_hit<=0;retry_scan<=0;search_id<=1;identity_retries<=0;
   best<={31{1'b1}};victim<=0;target<=0;found<=0;
   
   chosen_id<=1;following_id<=2;event_age<=0;max_event_cycles<=0;accepted_events<=0;
   fact_outcome<=0;fact_slot<=0;fact_steal<=0;
   protocol_error<=0;rank_cursor<=0;selected_rank<=0;
   for(integer s=0;s<VOICES;s++)begin audible[s]<=4'd0;end
  end else begin
   if(panic)panic_pending<=1;
   if(frame_tick&&dirty)publish_due<=1;
   // The scan is not an effective fence: wait for the bank swap and the
   // PT8211 load of the resulting mixed frame before acknowledging cleanup.
   if(LOOP_ENABLE&&loop_wait_output&&frame_tick)begin
    loop_wait_output<=0;loop_cleanup_pending<=0;loop_cleanup_done<=1;
   end
   if(state!=IDLE)event_age<=event_age+1'b1;
   if(audio_retire)begin
    if(audio_reclaim!=0)prepared_valid<=0;
    for(integer s=0;s<VOICES;s++)begin
     audible[s][3]<=0;audible[s][0]<=0;
     
     if(audio_reclaim[s]&&!audible[s][2])audible[s][1]<=0;
    end
   end
   case(state)
    IDLE:begin
     // Panic is selected before any bank swap or port operation. Deferring
     // its state assignment until after this case could swap banks and then
     // cancel the required clone on the very same edge.
     if(LOOP_ENABLE&&loop_abort_batch&&in_batch&&item_q[31:28]==3&&(loop_cleanup_all||item_q[95:80]==loop_cleanup_revision))begin
      in_batch<=0;batch_abort<=1;dirty<=1;prepared_valid<=0;
     end else if(LOOP_ENABLE&&loop_cleanup_valid&&loop_cleanup_ready)begin
      loop_scan<=0;loop_all<=loop_cleanup_all;loop_sources<=loop_cleanup_sources;loop_revision<=loop_cleanup_revision;loop_cleanup_pending<=1;loop_wait_output<=0;state<=LOOP_READ;
     end else if(panic_pending||panic)begin
      if(in_batch)batch_abort<=1;
      in_batch<=0;dirty<=1;panic_pending<=0;panic_urgent<=1;prepared_valid<=0;
     end else if(reclaim_any&&!in_batch)begin
      selected_slot<=reclaim_first;
      // The selected slot is registered before the synchronous read.
      state<=RECLAIM_AUDIO;
     end else if(frame_tick&&dirty&&prepared_valid&&!in_batch&&(!hold_publication||panic_urgent||loop_cleanup_pending))begin
      for(integer s=0;s<VOICES;s++)audible[s]<=prepared_flags[s*4+:4];
      audio_vibrato<=working_vibrato;audio_published<=1;
      audio_bank<=work_bank;work_bank<=audio_bank;published<=1;dirty<=0;
      if(LOOP_ENABLE&&loop_cleanup_pending)loop_wait_output<=1;
      allocated_since_publish<=0;panic_urgent<=0;publish_due<=0;prepared_valid<=0;
      copy_snapshot<=0;copy_slot<=0;state<=COPY_READ;
     end else if(dirty&&!prepared_valid&&!in_batch&&(!hold_publication||panic_urgent||loop_cleanup_pending)&&(publish_due||frame_tick))begin
      prepare_slot<=0;state<=PREP_READ;
     end else if(snapshot_valid&&snapshot_ready)begin
      // The audio bank and non-flag controls cannot change while copying.
      // Only retire may clear flags, so freeze those 128 bits at START.
      for(integer s=0;s<VOICES;s++)frozen_flags[s*4+:4]<=audible[s][3:0];
      copy_snapshot<=1;copy_slot<=0;state<=COPY_READ;
     end else if(pan_valid&&pan_ready)begin
      selected_slot<=pan_slot;control_id<=pan_id;control_generation<=pan_generation;control_pan<=pan_value;
      read_row({1'b0,work_bank},pan_slot,PAN_GOT);
     end else if(lookup_valid&&lookup_ready)begin
      selected_slot<=SW'(lookup_key);lookup_key_q<=lookup_key;control_id<=lookup_identity;
      control_generation<=lookup_generation;control_tag<=lookup_tag;lookup_cancelled<=!session_ready;
      read_row({1'b0,work_bank},SW'(lookup_key),LOOKUP_GOT);
     end else if(query_valid&&query_ready)begin
      query_slot_q<=query_slot;query_view_q<=query_view;
      read_row(query_view==2?2'd2:query_view==1?{1'b0,audio_bank}:{1'b0,work_bank},query_slot,QUERY_GOT);
     end else if(event_valid&&event_ready)begin
      item_q<=event_item;last_q<=event_last;timbre_q<=timbre;
      scan_slot<=0;best<={31{1'b1}};victim<=0;target<=0;found<=0;collision_hit<=0;retry_scan<=0;search_id<=id_cursor;identity_retries<=0;
      event_age<=0;accepted_events<=accepted_events+1'b1;in_batch<=1;
      if(!in_batch)session_live<=session_ready;
      read_row({1'b0,work_bank},0,SCAN_WORK);
     end
    end
    READ_WORDS:begin
     if(read_cycle==1)control_q<=memory_q[30:0];
     if(read_cycle==2&&return_state==PREP_GOT)prepared_key<=memory_q[2:0];
     case(read_cycle)
      2:meta_equal<=alu_equal;
      3:id_equal<=alu_equal;
      4:id_equal<=id_equal&&alu_equal;
      5:token_equal<=alu_equal;
      6:token_equal<=token_equal&&alu_equal;
     endcase
     if(capture_record)case(read_cycle)
      1:record_q[30:0]<=record_control;
      2:record_q[58:31]<=record_data[27:0];
      3:record_q[90:59]<=record_data;
      4:record_q[122:91]<=record_data;
      5:record_q[154:123]<=record_data;
      6:record_q[186:155]<=record_data;
     endcase
     if(copying)write_base<=write_base+1'b1;
     if(read_cycle==6)state<=return_state;
     else begin read_cycle<=read_cycle+1'b1;if(read_cycle<5)read_address<=read_address+1'b1;end
    end
    WRITE_WORDS:begin
     write_base<=write_base+1'b1;
     if(write_cycle==write_last)state<=return_state;else write_cycle<=write_cycle+1'b1;
    end
    SCAN_WORK:begin
     if(!retry_scan&&candidate_less)begin best<=candidate;victim<=scan_slot;end
     if(!retry_scan&&matching)begin found<=1;target<=scan_slot;end
     if(collision_scan&&scan_control[1]&&id_equal)collision_hit<=1;
     if(collision_scan&&audible[read_slot_q][1])read_row({1'b0,audio_bank},scan_slot,SCAN_AUDIO);
     else next_scan();
    end
    SCAN_AUDIO:begin
     // Even an un-gated audible tail reserves its identity until it retires.
     if(audible[read_slot_q][1]&&id_equal)collision_hit<=1;
     next_scan();
    end
    SELECT:begin
     selected_slot<=kind==1?victim:target;chosen_id<=search_id;state<=ID_LOW;
    end
    ID_LOW:begin following_id[31:0]<=alu_sum[31:0];id_carry<=alu_sum[32];state<=ID_HIGH;end
    ID_HIGH:begin
     following_id[63:32]<=alu_sum[31:0];
     if(search_id==ID_MAX)following_id<=64'd1;
     state<=SELECT_DONE;
    end
    SELECT_DONE:begin
     if(collision_scan&&collision_hit&&!stale&&!invalid_item)begin
      search_id<=following_id;collision_hit<=0;retry_scan<=1;identity_retries<=identity_retries+1'b1;
      scan_slot<=0;read_row({1'b0,work_bank},0,SCAN_WORK);
     end else read_row({1'b0,work_bank},selected_slot,BEFORE);
    end
    BEFORE:begin next_generation<=alu_sum[15:0];state<=APPLY;end
    APPLY:begin
     fact_valid<=1;
     fact_outcome<=invalid_item?8'd6:stale?8'd5:{4'd0,kind};
     fact_slot<=kind==4||((kind==2||kind==3)&&!found)?{SW{1'b1}}:selected_slot;
     fact_steal<=kind==1&&!stale&&!invalid_item&&old_control[1];
     if(invalid_item)begin protocol_error<=1;batch_abort<=1;in_batch<=0;state<=IDLE;end
     else if(!stale&&kind!=4)begin
      dirty<=1;prepared_valid<=0;
      if(kind==1)begin
       allocated_since_publish[selected_slot]<=1;
       phone_owned[selected_slot]<=item_q[31:28]==2&&session_live&&session_ready;
       id_cursor<=following_id;
       if(following_id<id_cursor)collision_mode<=1;
       // Freeze the old rank before updating any slot. Audio reads the
       // published bank; event/query admission stays closed until FINISH.
       selected_rank<=rank_read;rank_cursor<=0;
       write_words(0,5,RANK_UPDATE);
      end else write_words(0,0,FINISH);
     end else begin
      if(!stale&&kind==4)begin working_vibrato<=item_q[8:1];dirty<=1;end
      state<=FINISH;
     end
    end
    RANK_UPDATE:begin
     if(rank_cursor==VOICES-1)state<=FINISH;else rank_cursor<=rank_cursor+1'b1;
    end
    FINISH:begin
     if(event_age>max_event_cycles)max_event_cycles<=event_age;
     // Even a stale/no-op batch receives a frame publication fence. Phone
     // completion and score group scheduling must not wait forever for a
     // bank change that an all-stale batch would otherwise never request.
     if(last_q)begin in_batch<=0;batch_done<=1;dirty<=1;prepared_valid<=0;end
     state<=IDLE;
    end
    LOOP_READ:begin selected_slot<=loop_scan;read_row({1'b0,work_bank},loop_scan,LOOP_GOT);end
    LOOP_GOT:begin
     if(old_control[1]&&
       ((loop_sources[0]&&old_metadata[11:8]==1)||
        (loop_sources[1]&&old_metadata[11:8]==3&&(loop_all||old_metadata[155:140]==loop_revision))))begin
      item_q<={old_metadata[155:92],old_metadata[11:8],4'd2,old_metadata[7:0],16'd0};state<=LOOP_APPLY;
     end else state<=LOOP_NEXT;
    end
    LOOP_APPLY:begin
     dirty<=1;prepared_valid<=0;phone_owned[selected_slot]<=0;
     if(!allocated_since_publish[read_slot_q]&&old_control[2])begin fact_valid<=1;fact_outcome<=2;fact_slot<=selected_slot;fact_steal<=0;end
     write_words(3,0,LOOP_NEXT);
    end
    LOOP_NEXT:begin
     if(loop_scan==VOICES-1)begin dirty<=1;prepared_valid<=0;publish_due<=1;state<=IDLE;end
     else begin loop_scan<=loop_scan+1'b1;state<=LOOP_READ;end
    end
    COPY_READ:read_row({1'b0,audio_bank},copy_slot,COPY_GOT);
    COPY_GOT:state<=COPY_NEXT;
    COPY_NEXT:begin
     if(copy_snapshot)frozen_flags<=frozen_flags>>4;
     if(copy_slot==VOICES-1)begin state<=IDLE;if(copy_snapshot)snapshot_done<=1;end
     else begin copy_slot<=copy_slot+1'b1;state<=COPY_READ;end
    end
    QUERY_GOT:begin
     if(query_view_q==1)record_q[3:0]<=audible[read_slot_q];
     query_response_valid<=1;state<=IDLE;
    end
    LOOKUP_GOT:begin
     lookup_found_q<=lookup_key_q<VOICES&&phone_owned[read_slot_q]&&
      control_q[1]&&!panic_urgent&&meta_equal&&token_equal;
     state<=LOOKUP_REPLY;
    end
    LOOKUP_REPLY:state<=IDLE;
    PAN_GOT:state<=PAN_APPLY;
    PAN_APPLY:begin
     pan_status<=control_pan>256?2'd1:!old_control[1]||!id_equal||!meta_equal?2'd2:2'd0;
     if(control_pan<=256&&old_control[1]&&id_equal&&meta_equal)begin
      dirty<=1;prepared_valid<=0;
      write_words(1,0,PAN_REPLY);
     end else state<=PAN_REPLY;
    end
    PAN_REPLY:state<=IDLE;
    RECLAIM_AUDIO:read_row({1'b0,audio_bank},selected_slot,RECLAIM_WORK);
    RECLAIM_WORK:begin
     record_q[3:0]<=audible[read_slot_q];
     read_row({1'b0,work_bank},selected_slot,RECLAIM_DONE);
    end
    RECLAIM_DONE:begin
     prepared_valid<=0;
     fact_valid<=1;fact_outcome<=10;fact_slot<=selected_slot;fact_steal<=0;
     if(id_equal&&meta_equal&&!control_q[2])begin
      phone_owned[selected_slot]<=0;
      write_words(2,0,RECLAIM_WRITTEN);
     end else state<=RECLAIM_WRITTEN;
    end
    RECLAIM_WRITTEN:state<=IDLE;
    INIT:begin
     write_base<=write_base+1'b1;init_word<=init_word==ROW_WORDS-1?3'd0:init_word+1'b1;
     if(write_base==AW'(3*BANK_WORDS-1))state<=IDLE;
    end
    PREP_READ:read_row({1'b0,work_bank},prepare_slot,PREP_GOT);
    PREP_GOT:begin
     prepared_flags<={4'(work_control(control_q)),prepared_flags[4*VOICES-1:4]};
     if(prepare_slot==VOICES-1)begin prepared_valid<=1;state<=IDLE;end
     else begin prepare_slot<=prepare_slot+1'b1;state<=PREP_READ;end
    end
    default:begin protocol_error<=1;state<=IDLE;end
   endcase
   if(session_flush)begin phone_owned<=0;session_live<=0;lookup_cancelled<=1;end
  end
 end
 // synthesis translate_off
 initial if(ID_WIDTH<7||ID_WIDTH>64)$fatal(1,"R28_ID_WIDTH");
 reg frame_tick_previous;
 always @(posedge clk)frame_tick_previous<=frame_tick;
 always @(posedge clk)if(!rst)begin
  if(identity_retries>64)$fatal(1,"R28_ID_SEARCH_BOUND");
  if(published&&!frame_tick_previous)$fatal(1,"R28_PUBLICATION_EDGE");
  if(event_valid&&event_ready&&query_valid&&query_ready)$fatal(1,"R28_PORT_OWNER");
  if(fact_valid&&fact_outcome==1&&(fact_after[122:59]==0))$fatal(1,"R28_ZERO_ID");
 end
 // synthesis translate_on
 r54_full_equal #(.WIDTH(32)) r54_equal_0_tree(.a(alu_a),.b(alu_b),.equal(r54_equal_0));
endmodule

module r28_narrow_voice_lane #(parameter integer LANE=0)(
 output wire[72:0] pressure_request,input wire[17:0] pressure_difference_response,input wire[16:0] pressure_gain_response,
 output wire[69:0] timbre_request,input wire[81:0] timbre_response,
 output wire context_write_enable,output wire[2:0] context_write_slot,
 output wire[291:0] context_write_data,input wire[291:0] context_read_data,
 output wire[124:0] advance_request,input wire[101:0] advance_response,
 output wire[90:0] envelope_request,input wire[88:0] envelope_response,
 output wire[113:0] glide_request,input wire[124:0] glide_response,
 output wire[22:0] prepare_pitch,input wire[31:0] prepared_lo,prepared_hi,input wire[16:0] prepared_taper,
 input wire clk,rst,start,
 input wire [7:0] slot_valid,slot_gate,
 input wire[30:0] read_control,output wire[2:0] control_read_slot,
 input wire [7:0] vibrato_depth,
 input wire [3:0] glide_code,
 output reg busy,output wire completion_valid,completion_accept,
 output wire [2:0] completion_slot,output wire signed [17:0] completion_sample,
 output wire [31:0] completion_phase,
 output wire [135:0] envelope_levels,output wire [23:0] envelope_states,
 output wire [7:0] done_mask,output reg deadline_error
);
 localparam integer EW=13;
 localparam integer CW=32+7+8+3+3+17+17+4*EW+23+7+17+17+16+17+1+4+17+17+17;
 localparam integer EPW=3+17+17+4*EW;
 reg [7:0] age;
 reg [11:0] expression_q;
 reg [7:0] initialized;
 wire[7:0] prepare_age=age-8'(LANE);
 wire prepare_active=busy&&age>=LANE&&age<128+LANE;
 wire[2:0] read_slot=prepare_age[6:4];
 assign control_read_slot=read_slot;
 reg [2:0] captured_slot;
 reg captured_valid,captured_gate,captured_trigger,new_owner;
 reg [6:0] captured_note;
 reg [7:0] captured_pressure;
 reg [2:0] captured_timbre;
 reg [31:0] phase_q;
 reg [CW-1:0] state_q;
 wire [CW-1:0] state_read;
 // Normalize a new owner's envelope at context capture, before the ADSR
 // arithmetic stage. This preserves its initial duration=1 without putting
 // the owner-selection mux ahead of the release quotient/remainder path.
 reg[CW-1:0] captured_state;
 always @*begin
  captured_state=initialized[read_slot]?state_read:{CW{1'b0}};
  if(read_control[0] || !initialized[read_slot])
   captured_state[CW-50-EPW+:EPW]={3'd0,17'd0,17'd0,EW'(0),EW'(1),EW'(0),EW'(0)};
 end
 wire [31:0] phase_read;
 reg [16:0] levels[0:7];reg [2:0] states[0:7];
 wire [31:0] old_lfo;
 wire [6:0] old_note,old_target;
 wire [7:0] old_pressure;
 wire [2:0] old_timbre,old_env_state;
 wire [16:0] old_level,old_quotient,old_glide_remaining,old_glide_base,old_glide_error;
 wire [EW-1:0] old_remaining,old_duration,old_remainder,old_error;
 wire [22:0] old_pitch;
 wire [15:0] old_glide_remainder;
 wire old_up;wire [3:0] old_code;
 wire [16:0] old_gain,old_transient,old_body;
 assign {old_lfo,old_note,old_pressure,old_timbre,old_env_state,old_level,old_quotient,
 old_remaining,old_duration,old_remainder,old_error,old_pitch,old_target,
 old_glide_remaining,old_glide_base,old_glide_remainder,old_glide_error,old_up,old_code,
 old_gain,old_transient,old_body}=state_q;
 wire [2:0] env_state_result;
 wire [16:0] env_level_result,env_quotient_result;
 wire [31:0] env_remaining_result,env_duration_result,env_remainder_result,env_error_result;
 assign envelope_request={old_env_state,old_level,old_quotient,old_remaining,old_duration,old_remainder,old_error,captured_gate,captured_trigger};
 reg [EPW-1:0] env_q;
 wire [2:0] next_state;wire [16:0] next_level,next_quotient;
 wire [EW-1:0] next_remaining,next_duration,next_remainder,next_error;
 assign {next_state,next_level,next_quotient,next_remaining,next_duration,next_remainder,next_error}=env_q;
 wire [6:0] effective_note=next_state==4?(new_owner?7'd0:old_note):captured_note;
 wire [124:0] prepared;
 reg [124:0] prepared_q;
 assign glide_request={new_owner,effective_note,expression_q[3:0],old_pitch,old_target,old_glide_remaining,
   old_glide_base,old_glide_remainder,old_glide_error,old_up,old_code};
 assign prepared=glide_response;
 wire [22:0] next_pitch;wire [6:0] next_target;
 wire [16:0] next_glide_remaining,next_glide_base,next_glide_error;
 wire [15:0] next_glide_remainder;wire next_up;wire [3:0] next_code;
 assign advance_request=prepared_q;
 assign {next_pitch,next_target,next_glide_remaining,next_glide_base,next_glide_remainder,next_glide_error,next_up,next_code}=advance_response;
 // Fixed preparation edges break target -> difference -> rounded step -> add.
 // Release holds the gain; a new instance takes its exact initial pressure.
 wire [7:0] effective_pressure=next_state==4?(new_owner?8'd0:old_pressure):captured_pressure;
 reg [16:0] pressure_target,pressure_difference,pressure_step;
 reg pressure_up;
 assign pressure_request={new_owner,next_state,pressure_up,pressure_target,old_gain,pressure_difference,pressure_step};
 wire [16:0] next_gain=pressure_gain_response;
 wire [2:0] timbre=new_owner?captured_timbre:old_timbre;
 wire[16:0] next_transient,next_body;wire[31:0] next_lfo;wire signed[15:0] lfo_sine;
 assign timbre_request={new_owner,timbre,old_transient,old_body,(new_owner?32'd0:old_lfo)};
 assign {next_lfo,lfo_sine,next_transient,next_body}=timbre_response;
 wire [16:0] depth=expression_q[11:4]==255?17'd65536:{1'b0,expression_q[11:4],expression_q[11:4]};
 wire [CW-1:0] state_next={next_lfo,
  7'((captured_trigger||captured_gate)?captured_note:(next_state==0?7'd0:old_note)),
  8'((captured_trigger||captured_gate)?captured_pressure:(next_state==0?8'd0:old_pressure)),
  timbre,next_state,next_level,next_quotient,next_remaining,next_duration,next_remainder,next_error,
  next_pitch,next_target,next_glide_remaining,next_glide_base,next_glide_remainder,next_glide_error,next_up,next_code,
  next_gain,next_transient,next_body};
 wire context_write=!rst && prepare_active && prepare_age[3:0]==6 && captured_valid;
 assign context_write_enable=context_write;
 assign context_write_slot=captured_slot;
 assign context_write_data=state_next;
 assign state_read=context_read_data;
 s3_private_context_store #(.WIDTH(32)) phase_store(.clk(clk),.write_enable(!rst&&completion_valid&&completion_accept),
  .write_slot(completion_slot),.read_slot(read_slot),.write_value(completion_phase),.read_value(phase_read));
 reg [193:0] pending_job;reg [4:0] pending_tag;reg pending;
 wire backend_ready,backend_valid;wire [4:0] backend_tag;
 wire launch=pending && backend_ready;
 assign prepare_pitch=pending_job[160:138];
 r28_prepared_backend backend(.prepared_lo(prepared_lo),.prepared_hi(prepared_hi),.prepared_taper(prepared_taper),.clk(clk),.rst(rst||start),.in_valid(launch),.in_ready(backend_ready),
  .in_tag(pending_tag),.job_in(pending_job),.out_valid(backend_valid),.out_tag(backend_tag),
  .out_sample(completion_sample),.out_phase(completion_phase));
 assign completion_valid=backend_valid;
 assign completion_slot=backend_tag[2:0];
 assign completion_accept=slot_valid[completion_slot];
 assign done_mask=(backend_valid && completion_accept && !slot_gate[completion_slot] &&
  states[completion_slot]==0 && completion_sample==0)?(8'b1<<completion_slot):8'd0;
 generate for(genvar s=0;s<8;s++)begin: visible
  assign envelope_levels[s*17+:17]=(initialized[s] && slot_valid[s])?levels[s]:17'd0;
  assign envelope_states[s*3+:3]=(initialized[s] && slot_valid[s])?states[s]:3'd0;
 end endgenerate
 always @(posedge clk)begin
  if(rst)begin busy<=0;age<=0;initialized<=0;pending<=0;deadline_error<=0;expression_q<=0;
   captured_slot<=0;captured_valid<=0;captured_gate<=0;captured_trigger<=0;new_owner<=0;
   captured_note<=0;captured_pressure<=0;captured_timbre<=0;phase_q<=0;state_q<=0;
   env_q<=0;prepared_q<=0;pending_job<=0;pending_tag<=0;
   pressure_target<=0;pressure_difference<=0;pressure_step<=0;pressure_up<=0;
  end else begin
   if(start)begin
    if(busy)deadline_error<=1;
    busy<=1;age<=0;pending<=0;expression_q<={vibrato_depth,glide_code};
   end else if(busy)begin
    age<=age+1'b1;
    if(launch)pending<=0;
    if(prepare_active)case(prepare_age[3:0])
     0:begin
      captured_slot<=read_slot;captured_valid<=slot_valid[read_slot];captured_gate<=slot_gate[read_slot];
      captured_trigger<=read_control[3]&&slot_valid[read_slot];
      new_owner<=read_control[0]||!initialized[read_slot];
      captured_note<=read_control[19:13];captured_pressure<=read_control[27:20];
      captured_timbre<=read_control[30:28];
      state_q<=captured_state;
      phase_q<=initialized[read_slot]?phase_read:32'd0;
     end
     1:env_q<=envelope_response;
     2:begin prepared_q<=prepared;pressure_target<=effective_pressure==255?17'd65536:{1'b0,effective_pressure,effective_pressure};end
     3:begin pressure_up<=pressure_difference_response[17];pressure_difference<=pressure_difference_response[16:0];end
     4:pressure_step<=pressure_difference==0?17'd1:((pressure_difference+17'd3)>>2);
     6:begin
      pending_job<={32'(new_owner?0:phase_q),captured_trigger,next_pitch,lfo_sine,depth,next_level,next_gain,next_transient,next_body,17'd0,17'd0,timbre};
      pending_tag<={2'b0,captured_slot};pending<=1;
      if(captured_valid)begin initialized[captured_slot]<=1;levels[captured_slot]<=next_level;states[captured_slot]<=next_state;end
     end
     default:begin end
    endcase
    if(backend_valid && backend_tag==7)busy<=0;
    if(age>=191)deadline_error<=1;
   end
  end
 end
 // synthesis translate_off
 reg [15:0] stable_control;
 always @(posedge clk)begin
  if(busy && age==0)begin stable_control<={slot_valid,slot_gate};end
  if(!rst && busy && !start)begin
   if(age>0 && stable_control!=={slot_valid,slot_gate})$fatal(1,"R18_CONTROL_CHANGED_DURING_AUDIO");
   if(prepare_active && prepare_age[3:0]==6 && pending&&!launch)$fatal(1,"R18_PENDING_OVERWRITE");
  end
 end
 // synthesis translate_on
endmodule
module r28_narrow_stereo_sum #(parameter integer COMPLETION_LIMIT=192)(
 input wire clk,rst,sample_tick,
 input wire[3:0] completion_valid,completion_accept,
 input wire[11:0] completion_slot,input wire[71:0] completion_sample,
 input wire[35:0] completion_pan,
 output reg signed[31:0] mix_l_q8,mix_r_q8,output reg mix_valid,
 output reg protocol_error,deadline_error,output reg[7:0] last_complete_cycle
);
 // Four simultaneous results are consumed as two fixed pairs. Products
 // enter the accumulator at +3/+4; final output remains at +5 clocks.
 reg signed[17:0] samples[0:3];reg[8:0] pans[0:3];
 reg[1:0] phase;
 reg signed[17:0] operand[0:1];reg[8:0] coefficient[0:1];
 reg[1:0] right_unity;
 reg op_valid,op_second,product_valid,product_second,last_group,mix_pending;
 reg signed[27:0] product_l[0:1],product_r[0:1];
 wire signed[27:0] variable_product[0:1],unity_product[0:1];
 reg signed[31:0] sum_l,sum_r;
 reg busy;reg[7:0] age;reg[7:0] seen[0:3];
 wire [1:0] pair_base=phase==2?2'd2:2'd0;
 for(genvar k=0;k<2;k++)begin: multiply
  assign variable_product[k]=$signed(operand[k])*$signed({1'b0,coefficient[k]});
  assign unity_product[k]=$signed({{10{operand[k][17]}},operand[k]})<<<8;
 end
 always @(posedge clk)begin
  if(rst)begin
   phase<=0;right_unity<=0;op_valid<=0;op_second<=0;product_valid<=0;product_second<=0;
   last_group<=0;mix_pending<=0;sum_l<=0;sum_r<=0;busy<=0;age<=0;
   mix_l_q8<=0;mix_r_q8<=0;mix_valid<=0;protocol_error<=0;deadline_error<=0;last_complete_cycle<=0;
   for(integer k=0;k<4;k++)begin samples[k]<=0;pans[k]<=128;seen[k]<=0;end
   for(integer k=0;k<2;k++)begin operand[k]<=0;coefficient[k]<=256;product_l[k]<=0;product_r[k]<=0;end
  end else begin
   op_valid<=phase!=0;op_second<=phase==2;
   product_valid<=op_valid;product_second<=op_second;
   mix_pending<=product_valid&&product_second&&last_group;mix_valid<=mix_pending;
   if(busy)begin age<=age+1'b1;if(age>=191)deadline_error<=1;end
   if(sample_tick)begin
    if(busy||phase!=0||op_valid||product_valid||completion_valid!=0)deadline_error<=1;
    busy<=1;age<=0;sum_l<=0;sum_r<=0;
    for(integer k=0;k<4;k++)seen[k]<=0;
   end
   if(completion_valid!=0)begin
    if(completion_valid!=4'b1111||phase!=0)protocol_error<=1;
    phase<=1;last_group<=completion_slot[2:0]==7;
    for(integer k=0;k<4;k++)begin
     if(!busy||seen[k][completion_slot[k*3+:3]])protocol_error<=1;
     if(completion_slot[k*3+:3]==7&&seen[k]!=8'h7f)protocol_error<=1;
     if(completion_slot[k*3+:3]!=completion_slot[2:0])protocol_error<=1;
     seen[k][completion_slot[k*3+:3]]<=1;
     if(completion_pan[k*9+:9]>256)protocol_error<=1;
     samples[k]<=completion_accept[k]?$signed(completion_sample[k*18+:18]):18'sd0;
     pans[k]<=completion_pan[k*9+:9];
    end
   end
   if(phase!=0)begin
    phase<=phase==1?2:0;
    for(integer k=0;k<2;k++)begin
     operand[k]<=samples[pair_base+k];right_unity[k]<=pans[pair_base+k]>128;
     coefficient[k]<=pans[pair_base+k]>128?((9'd256-pans[pair_base+k])<<1):(pans[pair_base+k]<<1);
    end
   end
   if(op_valid)for(integer k=0;k<2;k++)begin
    product_l[k]<=right_unity[k]?variable_product[k]:unity_product[k];
    product_r[k]<=right_unity[k]?unity_product[k]:variable_product[k];
   end
   if(product_valid)begin
    sum_l<=sum_l+{{4{product_l[0][27]}},product_l[0]}+{{4{product_l[1][27]}},product_l[1]};
    sum_r<=sum_r+{{4{product_r[0][27]}},product_r[0]}+{{4{product_r[1][27]}},product_r[1]};
   end
   if(mix_pending)begin
    mix_l_q8<=sum_l;mix_r_q8<=sum_r;busy<=0;last_complete_cycle<=age+1'b1;
    if(!busy||age>=COMPLETION_LIMIT)deadline_error<=1;
   end
  end
 end
endmodule
module r28_frame_audio #(parameter integer BACKENDS=1,parameter integer SHARE_FX=0, SAMPLE_RATE_HZ=48000, LANES=6, EXTERNAL_FRONTEND=0,PITCH_ROM_ROLE=0,
  FE_EPW=37+4*(SAMPLE_RATE_HZ>=128000?15:SAMPLE_RATE_HZ>=72000?14:13))(
 // EXTERNAL_FRONTEND: envelope and timbre/LFO steps come from shared units outside.
 output wire[FE_EPW+7:0] fe_envelope_request,output wire[69:0] fe_timbre_request,output wire[6:0] fe_release,
 input wire[FE_EPW-1:0] fe_envelope_response,input wire[81:0] fe_timbre_response,
 output wire fe_pitch_issue,output wire[6:0] fe_pitch_note,output wire[31:0] fe_pitch_data,
 input wire fe_alt_issue,input wire[6:0] fe_alt_note,input wire[31:0] fe_pitch_data_in,
 output wire [127:0] ensemble_metrics,
 input wire fx_mac_use,input wire signed[35:0] fx_mac_a,input wire signed[17:0] fx_mac_b,
 output wire signed[53:0] fx_mac_q,
 input wire clk,rst,start,test_linear,
 input wire[4*8*LANES-1:0] flags,input wire[31*LANES-1:0] read_controls,input wire[9*LANES-1:0] read_pans,
 output wire[3*LANES-1:0] read_slots,pan_slots,
 input wire[7:0] vibrato_depth,input wire[3:0] glide_code,
 input wire[(LANES>8?7:6)-1:0] level_read_slot,output wire[16:0] level_read_value,
 output reg busy,output wire mix_valid,output reg control_retire,
 output wire signed[31:0] mix_l_q8,mix_r_q8,
 output wire[17*8*LANES-1:0] envelope_levels,output wire[3*8*LANES-1:0] envelope_states,
 output reg[8*LANES-1:0] reclaim_pending,output reg[18*8*LANES-1:0] voice_samples,
 output reg[LANES-1:0] completion_valid,completion_accept,
 output reg[3*LANES-1:0] completion_slot,output reg[18*LANES-1:0] completion_sample,
 output wire protocol_error,output reg deadline_error,output wire[8:0] last_complete_cycle
);
 localparam integer EW=(SAMPLE_RATE_HZ>=128000?15:SAMPLE_RATE_HZ>=72000?14:13),CW=240+4*EW,EPW=37+4*EW;
 // Slot = {Lane, index within Lane}. Each slot takes four issue cycles, so
 // the work window, prefetch end and per-group retire edges scale with LANES.
 localparam integer V=8*LANES,LW=(LANES>8?4:3),SW=LW+3,GROUP=4*LANES,
   ISSUE_END=4*V,WORK_END=4+4*V,RETIRE_AGE=4+9*GROUP+5;
 reg[8:0] age;
 reg[4*V-1:0] frame_flags;
 reg[11:0] expression_q;
 reg[V-1:0] initialized,visible_initialized;
 wire early_read=1'b0;
 wire early_commit=1'b0;
 wire[1:0] early_lane=age[1:0],commit_lane=age[1:0]-2'd2;
 wire[4:0] early_slot={early_lane,age[6:4]},commit_slot={commit_lane,age[6:4]};
 wire work_active=busy&&age>=4&&age<=WORK_END;
 wire[8:0] work_age=age-9'd4;
 wire[1:0] work_step=work_age[1:0];
 reg[SW-1:0] work_slot;
 always @(posedge clk)begin
  if(rst||start)work_slot<=0;
  else if(work_active&&work_step==0&&age<=ISSUE_END)
   work_slot<=work_slot[SW-1:3]==LANES-1 ? {{LW{1'b0}},3'(work_slot[2:0]+1'b1)} : work_slot+SW'(8);
 end
 wire[SW-1:0] read_slot=early_read?SW'(early_slot):work_slot;
 wire[LW-1:0] read_lane=read_slot[SW-1:3];
 // work_slot is reset by start, so the age-0 read is always slot 0.
 wire[3:0] read_flags=age==0?flags[3:0]:frame_flags[read_slot*4+:4];
 // Select one complete Lane field. Constant slices avoid a general barrel
 // selection network for the non-power-of-two 31-bit Lane stride.
 wire[26:0] lane_control[0:LANES-1];
 for(genvar l=0;l<LANES;l++)begin: lane_fields
  assign lane_control[l]=read_controls[l*31+4+:27];
 end
 wire[26:0] selected_control=read_lane<LANES?lane_control[read_lane]:27'bx;
 wire[30:0] read_control={selected_control,read_flags};
 assign read_slots={LANES{read_slot[2:0]}};
 assign pan_slots=completion_slot;
 reg[SW-1:0] captured_slot;
 reg captured_valid,captured_gate,captured_trigger,new_owner;
 reg[6:0] captured_note;reg[7:0] captured_pressure;reg[2:0] captured_timbre;
 reg[31:0] phase_q;reg[CW-1:0] state_q;
 wire[CW-1:0] state_read;
 reg[CW-1:0] captured_state;
 always @*begin
  captured_state=initialized[read_slot]?state_read:{CW{1'b0}};
  if(read_control[0]||!initialized[read_slot])captured_state[153+:EPW]={3'd0,17'd0,17'd0,EW'(0),EW'(1),EW'(0),EW'(0)};
 end
 wire[EPW+7:0] envelope_request;wire[EPW-1:0] envelope_response;
 wire[113:0] glide_request;wire[124:0] glide_response;
 wire[124:0] advance_request;wire[101:0] advance_response;
 wire[72:0] pressure_request;
 wire[16:0] pressure_gain_response;
 wire[69:0] timbre_request;wire[81:0] timbre_response;
  wire [31:0] old_lfo;
 wire [6:0] old_note,old_target;
 wire [7:0] old_pressure;
 wire [2:0] old_timbre,old_env_state;
 wire [16:0] old_level,old_quotient,old_glide_remaining,old_glide_base,old_glide_error;
 wire [EW-1:0] old_remaining,old_duration,old_remainder,old_error;
 wire [22:0] old_pitch;
 wire [15:0] old_glide_remainder;
 wire old_up;wire [3:0] old_code;
 wire [16:0] old_gain,old_transient,old_body;
 assign {old_lfo,old_note,old_pressure,old_timbre,old_env_state,old_level,old_quotient,
 old_remaining,old_duration,old_remainder,old_error,old_pitch,old_target,
 old_glide_remaining,old_glide_base,old_glide_remainder,old_glide_error,old_up,old_code,
 old_gain,old_transient,old_body}=state_q;
 wire [2:0] env_state_result;
 wire [16:0] env_level_result,env_quotient_result;
 wire [31:0] env_remaining_result,env_duration_result,env_remainder_result,env_error_result;
 // Field tests: plain sine, no vibrato, so each oscillator is a single bin.
 wire [2:0] timbre=test_linear?3'd0:new_owner?captured_timbre:old_timbre;
 assign envelope_request={timbre,captured_note[2:0],old_env_state,old_level,old_quotient,old_remaining,old_duration,old_remainder,old_error,captured_gate,captured_trigger};
 reg [EPW-1:0] env_q;
 wire [2:0] next_state;wire [16:0] next_level,next_quotient;
 wire [EW-1:0] next_remaining,next_duration,next_remainder,next_error;
 assign {next_state,next_level,next_quotient,next_remaining,next_duration,next_remainder,next_error}=env_q;
 // The private drum note is a key role, independent of octave/keymap.
 function [6:0] drum_note(input[2:0] role);
  case(role)
   0:drum_note=33; 1:drum_note=50; 2:drum_note=90; 3:drum_note=90;
   4:drum_note=43; 5:drum_note=50; 6:drum_note=74; 7:drum_note=86;
  endcase
 endfunction
 wire [6:0] effective_note=timbre==5?drum_note(captured_note[2:0]):
  next_state==4?(new_owner?7'd0:old_note):captured_note;
 wire [124:0] prepared;
 reg [124:0] prepared_q;
 assign glide_request={new_owner,effective_note,expression_q[3:0],old_pitch,old_target,old_glide_remaining,
   old_glide_base,old_glide_remainder,old_glide_error,old_up,old_code};
 assign prepared=glide_response;
 wire [22:0] next_pitch;wire [6:0] next_target;
 wire [16:0] next_glide_remaining,next_glide_base,next_glide_error;
 wire [15:0] next_glide_remainder;wire next_up;wire [3:0] next_code;
 assign advance_request=prepared_q;
 assign {next_pitch,next_target,next_glide_remaining,next_glide_base,next_glide_remainder,next_glide_error,next_up,next_code}=
  {effective_note,16'd0,effective_note,17'd0,17'd0,16'd0,17'd0,1'b1,4'd0};
 // Fixed preparation edges break target -> difference -> rounded step -> add.
 // Release holds the gain; a new instance takes its exact initial pressure.
 wire [7:0] effective_pressure=next_state==4?(new_owner?8'd0:old_pressure):captured_pressure;
 reg [16:0] pressure_target,pressure_difference,pressure_step;
 reg pressure_up;
 assign pressure_request={new_owner,next_state,pressure_up,pressure_target,old_gain,pressure_difference,pressure_step};
 // A drum hit latches velocity. Pressure updates never restart its one-shot.
 wire [16:0] next_gain=(timbre==5&&!new_owner)?old_gain:pressure_gain_response;
 wire[16:0] next_transient,next_body;wire[31:0] next_lfo;wire signed[15:0] lfo_sine;
 assign timbre_request={new_owner,timbre,old_transient,old_body,(new_owner?32'd0:old_lfo)};
 assign {next_lfo,lfo_sine,next_transient,next_body}=timbre_response;
 wire [16:0] depth=expression_q[11:4]==255?17'd65536:{1'b0,expression_q[11:4],expression_q[11:4]};
 wire [CW-1:0] state_next={next_lfo,
  7'((captured_trigger||captured_gate)?captured_note:(next_state==0?7'd0:old_note)),
  8'((captured_trigger||captured_gate)?captured_pressure:(next_state==0?8'd0:old_pressure)),
  timbre,next_state,next_level,next_quotient,next_remaining,next_duration,next_remainder,next_error,
  next_pitch,next_target,next_glide_remaining,next_glide_base,next_glide_remainder,next_glide_error,next_up,next_code,
  next_gain,next_transient,next_body};

 wire context_write=!rst&&work_active&&work_step==0&&age>=8&&captured_valid;
 // Each slot's context is three 108-bit words in three 36-bit-wide BSRAMs.
 // Word 0 holds bits 216..323 (it includes the envelope level, which the
 // release estimate needs two edges before capture); word 1 bits 0..107;
 // word 2 bits 108..215. Reads for the next slot issue on the three edges
 // before its capture edge; words 0 and 1 are held, word 2 is read directly.
 // A completed slot's new context is buffered and written on the following
 // three edges, so the read and write ports never address the same slot.
 wire context_read_issue=!rst&&!start&&busy&&age>=1&&age<=ISSUE_END-1&&age[1:0]!=0;
 wire[1:0] context_read_word=age[1:0]-2'd1;
 reg[323:0] context_buffer;reg[SW-1:0] context_write_slot;reg[1:0] context_writes_left;
 wire context_write_issue=!rst&&context_writes_left!=0;
 wire[1:0] context_write_word=2'd3-context_writes_left;
 always @(posedge clk)begin
  if(rst||start)context_writes_left<=0;
  else if(context_write)begin
   context_buffer<={{(324-CW){1'b0}},state_next};context_write_slot<=captured_slot;context_writes_left<=3;
  end else if(context_writes_left!=0)context_writes_left<=context_writes_left-1'b1;
 end
 wire[107:0] context_di=context_write_word==0?context_buffer[216+:108]:
   context_write_word==1?context_buffer[0+:108]:context_buffer[108+:108];
 wire[107:0] context_do;
 for(genvar word=0;word<3;word++)begin: context_wide
  SDPX9B #(.BIT_WIDTH_0(36),.BIT_WIDTH_1(36),.READ_MODE(0),.RESET_MODE("SYNC")) memory(
   .CLKA(clk),.CLKB(clk),.CEA(context_write_issue),.CEB(context_read_issue),
   .ADA({(7-SW)'(0),context_write_slot,context_write_word,5'b01111}),.ADB({(7-SW)'(0),work_slot,context_read_word,5'b00000}),
   .DI(context_di[word*36+:36]),.DO(context_do[word*36+:36]),
   .BLKSELA(3'd0),.BLKSELB(3'd0),.OCE(1'b1),.RESET(1'b0));
 end
 reg[107:0] context_word0,context_word1;
 always @(posedge clk)begin
  if(busy&&age[1:0]==2)context_word0<=context_do;
  if(busy&&age[1:0]==3)context_word1<=context_do;
 end
 wire[323:0] context_full={context_word0,context_do,context_word1};
 assign state_read=context_full[CW-1:0];
 // synthesis translate_off
 reg[SW-1:0] context_read_slot_q[0:2];
 always @(posedge clk)begin
  if(context_read_issue)context_read_slot_q[context_read_word]<=work_slot;
  if(!rst&&!start&&busy&&(work_active&&work_step==0&&age<=ISSUE_END))
   if(context_read_slot_q[0]!==read_slot||context_read_slot_q[1]!==read_slot||context_read_slot_q[2]!==read_slot)
    $fatal(1,"R45_CONTEXT_WRONG_PREFETCH");
  if(context_read_issue&&context_write_issue&&work_slot==context_write_slot&&context_read_word==context_write_word)
   $fatal(1,"R45_CONTEXT_READ_WRITE_COLLISION");
  if(context_write&&context_writes_left!=0)$fatal(1,"R45_CONTEXT_WRITE_OVERLAP");
 end
 // synthesis translate_on
 reg[EPW+7:0] observe_request;reg observe_valid;reg[1:0] observe_lane;
 reg[19:0] observe_result[0:3];
 wire main_envelope=work_active&&work_step==1;
 // This schedule has no observer jobs (early_read/early_commit are zero).
 // Its sole envelope consumer is work_step1. Do not gate combinational
 // arithmetic with busy/age; the existing consumer edge still gates capture.
 wire[EPW+7:0] selected_envelope=envelope_request;
 // Same private context and release code, prepared in existing idle slots.
 // Context read moved from capture-1 to capture-3; no extra RAM port.
 wire[16:0] prepare_level=(read_control[0]||!initialized[read_slot])?17'd0:context_do[153+4*EW+17-216+:17];
 wire[18:0] prepare_three={2'b0,prepare_level}+({2'b0,prepare_level}<<1);
 reg[6:0] release_high_q,release_estimate_q;
 wire[2:0] prepare_code=expression_q[3:0]>7?3'd7:expression_q[2:0];
 function[6:0] release_estimate(input[6:0] h,input[2:0] c);
  case(c)
   1:release_estimate=h;2:release_estimate=h>>1;3:release_estimate=h/7'd3;
   4:release_estimate=h>>2;5:release_estimate=h/7'd5;6:release_estimate=h/7'd6;
   7:release_estimate=h/7'd7;default:release_estimate=0;
  endcase
 endfunction
 always @(posedge clk)begin
  if(rst||start)begin release_high_q<=0;release_estimate_q<=0;end
  else if(busy)begin
   if(age>=2&&age<=ISSUE_END-2&&age[1:0]==2)release_high_q<={1'b0,prepare_three[18:13]};
   if(age>=3&&age<=ISSUE_END-1&&age[1:0]==3)release_estimate_q<=release_estimate(release_high_q,prepare_code);
  end
 end
 // synthesis translate_off
 wire[18:0] check_three={2'b0,old_level}+({2'b0,old_level}<<1);
 always @(posedge clk)if(!rst&&SAMPLE_RATE_HZ==128000&&main_envelope)
  if(release_estimate_q!==release_estimate({1'b0,check_three[18:13]},prepare_code))
   $fatal(1,"ENVELOPE_PREPARE_WRONG_CONTEXT");
 // synthesis translate_on

 assign fe_envelope_request=selected_envelope;assign fe_timbre_request=timbre_request;assign fe_release=release_estimate_q;
 if(EXTERNAL_FRONTEND!=0)begin: shared_frontend
  // Glide and advance results are not consumed: pitch changes are direct.
  assign envelope_response=fe_envelope_response;assign timbre_response=fe_timbre_response;
  assign glide_response=0;assign advance_response=0;
 end else begin: own_frontend
 r28_shared_envelope_glide #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),.PREPARED_RELEASE(SAMPLE_RATE_HZ==128000)) frontend(.prepared_release_q(release_estimate_q),.prepared_release_alt(release_estimate_q),.clk(clk),.rst(rst),.start(start),.busy(busy),
  .envelope_requests({4{selected_envelope}}),.envelope_response(envelope_response),
  .glide_requests({4{glide_request}}),.glide_response(glide_response),
  .advance_requests({4{advance_request}}),.advance_response(advance_response));
 r28_shared_timbre_lfo #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)) timbre_prepare(.clk(clk),.rst(rst),.start(start),.busy(busy),.requests({4{timbre_request}}),.response(timbre_response));
 end
 wire signed[17:0] pressure_delta=$signed({1'b0,pressure_request[67:51]})-$signed({1'b0,pressure_request[50:34]});
 wire[16:0] pressure_magnitude=pressure_delta[17]?-pressure_delta:pressure_delta;
 wire[17:0] pressure_difference_response={!pressure_delta[17]&&pressure_delta!=0,pressure_magnitude};
 wire[16:0] gain_target=pressure_request[67:51],gain_old=pressure_request[50:34],gain_difference=pressure_request[33:17],gain_step=pressure_request[16:0];
 wire[16:0] gain_adjusted=gain_old+(gain_step^{17{!pressure_request[68]}})+!pressure_request[68];
 assign pressure_gain_response=pressure_request[72]?gain_target:
  (pressure_request[71:69]==4||gain_target==gain_old)?gain_old:gain_step>=gain_difference?gain_target:gain_adjusted;
 reg[193:0] pending_job;reg[5:0] pending_tag;reg pending;
 wire[63:0] prepared_steps;wire[16:0] prepared_taper;
 // The existing transient state supplies a short pitch drop for tonal drums.
 wire[22:0] drum_sweep=captured_note[2:0]==0?{2'd0,next_transient,4'd0}:
  (captured_note[2:0]==4||captured_note[2:0]==5)?{4'd0,next_transient,2'd0}:23'd0;
 wire[22:0] backend_pitch=timbre==5?next_pitch+drum_sweep:next_pitch;
 // These 17 bits formerly carry FM taper; the drum path carries role+noise.
 wire[16:0] drum_payload={captured_note[2:0],lfo_sine[15:2]};
 osc_ii4_pitch_prepare #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),.ISSUE_END(ISSUE_END),.ROM_ROLE(PITCH_ROM_ROLE)) pitch_prepare(
  .alt_issue(fe_alt_issue),.alt_note(fe_alt_note),.rom_data_in(fe_pitch_data_in),
  .issue_out(fe_pitch_issue),.note_out(fe_pitch_note),.rom_data_out(fe_pitch_data),.clk(clk),.rst(rst),.start(start),.busy(busy),.test_linear(test_linear),.pitch(pending_job[160:138]),.steps(prepared_steps),.taper_out(prepared_taper));
 wire[BACKENDS-1:0] backend_ready,backend_valid;
 wire[BACKENDS*6-1:0] backend_tags;wire[BACKENDS*18-1:0] backend_samples;wire[BACKENDS*32-1:0] backend_phases;
 wire[1:0] selected_backend=BACKENDS==1?2'd0:BACKENDS==4?pending_tag[4:3]:{1'b0,pending_tag[3]};
 wire launch=pending&&backend_ready[selected_backend];
 for(genvar b=0;b<BACKENDS;b++)begin: engines
  osc_ii4_backend backend(.clk(clk),.rst(rst||start),
   .prepared_lo(prepared_steps[31:0]),.prepared_hi(prepared_steps[63:32]),.prepared_taper(prepared_taper),
   .in_valid(launch&&selected_backend==b),.in_ready(backend_ready[b]),.in_tag(pending_tag),.job_in(pending_job),
   .out_valid(backend_valid[b]),.out_tag(backend_tags[b*6+:6]),.out_sample(backend_samples[b*18+:18]),.out_phase(backend_phases[b*32+:32]));
 end
 assign fx_mac_q=54'd0;
 reg result_valid;reg[5:0] result_slot;
 wire[LW-1:0] result_lane=result_slot[SW-1:3];reg[31:0] result_phase;reg[17:0] result_sample;
 always @*begin
  result_valid=0;result_slot=0;result_phase=0;result_sample=0;
  for(integer b=0;b<BACKENDS;b++)if(backend_valid[b])begin
   result_valid=1;result_slot=backend_tags[b*6+:6];result_phase=backend_phases[b*32+:32];result_sample=backend_samples[b*18+:18];
  end
  completion_valid=0;completion_accept=0;completion_slot=0;completion_sample=0;
  if(result_valid)begin
   completion_valid[result_lane]=1;completion_accept[result_lane]=frame_flags[result_slot*4+1];
   completion_slot[result_lane*3+:3]=result_slot[2:0];completion_sample[result_lane*18+:18]=result_sample;
  end
 end
 wire[32*LANES-1:0] phase_reads;wire[31:0] phase_read=phase_reads[read_lane*32+:32];
 for(genvar l=0;l<LANES;l++)begin: phase_banks
  s3_private_context_store #(.WIDTH(32)) phase_store(.clk(clk),.write_enable(!rst&&result_valid&&frame_flags[result_slot*4+1]&&result_lane==l),
   .write_slot(result_slot[2:0]),.read_slot(read_slot[2:0]),.write_value(result_phase),.read_value(phase_reads[l*32+:32]));
 end
 // The whole-pool level/state buses have no consumer; levels are read
 // through level_read_value only.
 assign envelope_levels='0;
 assign envelope_states='0;
 wire mixer_deadline,computed_mix_valid;
 reg mix_prepared,published_mix_valid;
 assign mix_valid=published_mix_valid;
 always @(posedge clk)begin
  if(rst||start)begin mix_prepared<=0;published_mix_valid<=0;end
  else begin
   published_mix_valid<=0;
   if(computed_mix_valid)mix_prepared<=1;
   if(busy&&age==305)begin published_mix_valid<=mix_prepared;mix_prepared<=0;end
  end
 end
 osc_stereo_sum #(.LANES(LANES)) stereo(.clk(clk),.rst(rst),.sample_tick(start),.completion_valid(completion_valid),.completion_accept(completion_accept),
  .completion_slot(completion_slot),.completion_sample(completion_sample),.completion_pan(read_pans),.mix_l_q8(mix_l_q8),.mix_r_q8(mix_r_q8),
  .mix_valid(computed_mix_valid),.protocol_error(protocol_error),.deadline_error(mixer_deadline),.last_complete_cycle(last_complete_cycle));
 osc48_voice_metrics #(.CAPACITY(V)) monitor(.clk(clk),.rst(rst),.start(start),.done(mix_valid),
  .result_valid(result_valid),.result_accepted(frame_flags[result_slot*4+1]),
  .result_gate(frame_flags[result_slot*4+2]),.result_sample(result_sample),
  .complete_cycle(last_complete_cycle),.protocol_error(protocol_error),.deadline_error(deadline_error),.metrics(ensemble_metrics));
 // Group g (index g of every Lane) has retired GROUP*(g+2) cycles after issue start.
 reg original_completion;
 always @*begin original_completion=0;for(integer g=0;g<8;g++)if(busy&&age==4+GROUP*(g+2))original_completion=1;end
 reg[2:0] retire_group;
 // Per-slot envelope level and state live in distributed RAM: one write per
 // slot per frame, one random read for the controller's victim scan, and
 // one read per Lane bank for the retire-time reclaim check.
 reg[16:0] levels[0:V-1] /* synthesis syn_ramstyle="distributed_ram" */;
 wire level_we=!rst&&!start&&work_active&&work_step==1&&captured_valid;
 wire[19:0] level_write=envelope_response[EPW-1-:20];
 always @(posedge clk)if(level_we)levels[captured_slot]<=level_write[16:0];
 wire[2:0] lane_state[0:LANES-1];
 for(genvar l=0;l<LANES;l++)begin: state_banks
  reg[2:0] bank[0:7] /* synthesis syn_ramstyle="distributed_ram" */;
  always @(posedge clk)if(level_we&&captured_slot[SW-1:3]==l)bank[captured_slot[2:0]]<=level_write[19:17];
  assign lane_state[l]=bank[retire_group];
 end
 // synthesis translate_off
 reg[2:0] states_shadow[0:V-1];
 always @(posedge clk)if(level_we)states_shadow[captured_slot]<=level_write[19:17];
 // synthesis translate_on
 assign level_read_value=(visible_initialized[level_read_slot]&&flags[level_read_slot*4+1])?levels[level_read_slot]:17'd0;
 always @(posedge clk)if(rst||start)retire_group<=0;else if(original_completion)retire_group<=retire_group+1'b1;
 always @(posedge clk)begin
  if(rst)begin
   busy<=0;age<=0;frame_flags<=0;expression_q<=0;initialized<=0;visible_initialized<=0;
   captured_slot<=0;captured_valid<=0;captured_gate<=0;captured_trigger<=0;new_owner<=0;captured_note<=0;captured_pressure<=0;captured_timbre<=0;
   phase_q<=0;state_q<=0;env_q<=0;prepared_q<=0;pressure_target<=0;pressure_difference<=0;pressure_step<=0;pressure_up<=0;
   pending_job<=0;pending_tag<=0;pending<=0;observe_request<=0;observe_valid<=0;observe_lane<=0;
   reclaim_pending<=0;voice_samples<=0;control_retire<=0;deadline_error<=0;
  end else begin
   control_retire<=busy&&age==RETIRE_AGE;
   observe_valid<=early_read;
   if(start)begin
    if(busy)deadline_error<=1;
    busy<=1;age<=0;pending<=0;observe_valid<=0;reclaim_pending<=0;control_retire<=0;expression_q<={vibrato_depth,glide_code};
   end else if(busy)begin
    age<=age+1'b1;
    if(age==0)frame_flags<=flags;
    if(early_read)begin observe_request<={read_control[30:28],read_control[15:13],captured_state[153+:EPW],read_control[2],read_control[3]&&read_control[1]};observe_lane<=early_lane;end
    if(observe_valid)observe_result[observe_lane]<=envelope_response[EPW-1-:20];
    if(original_completion)for(integer l=0;l<LANES;l++)begin
     if(frame_flags[(l*8+retire_group)*4+1]&&!frame_flags[(l*8+retire_group)*4+2]&&lane_state[l]==0)
      reclaim_pending[l*8+retire_group]<=1;
    end
    if(launch)pending<=0;
    if(work_active)case(work_step)
     0:begin
      if(age>=8)begin
      pending_job<={32'(new_owner?0:phase_q),captured_trigger,backend_pitch,lfo_sine,
       (timbre==5||test_linear?17'd0:depth),next_level,next_gain,next_transient,next_body,17'd0,
       (timbre==5?drum_payload:17'd0),timbre};
      pending_tag<=6'(captured_slot);pending<=1;if(captured_valid)initialized[captured_slot]<=1;
     end
      if(age<=ISSUE_END)begin
      captured_slot<=read_slot;captured_valid<=read_control[1];captured_gate<=read_control[2];captured_trigger<=read_control[3]&&read_control[1];
      new_owner<=read_control[0]||!initialized[read_slot];captured_note<=read_control[19:13];captured_pressure<=read_control[27:20];captured_timbre<=read_control[30:28];
      state_q<=captured_state;phase_q<=initialized[read_slot]?phase_read:32'd0;
      end
     end
     1:begin
      env_q<=envelope_response;
      pressure_target<=envelope_response[EPW-1-:3]==4 ?
       (new_owner?8'd0:old_pressure)==255?17'd65536:{1'b0,(new_owner?8'd0:old_pressure),(new_owner?8'd0:old_pressure)}:
       captured_pressure==255?17'd65536:{1'b0,captured_pressure,captured_pressure};
      if(captured_valid)visible_initialized[captured_slot]<=1;
     end
     2:begin pressure_up<=pressure_difference_response[17];pressure_difference<=pressure_difference_response[16:0];end
     3:pressure_step<=pressure_difference==0?17'd1:(SAMPLE_RATE_HZ==128000 ? (({2'b0,pressure_difference}+({2'b0,pressure_difference}<<1)+19'd31)>>5) : SAMPLE_RATE_HZ==96000 ? ((pressure_difference+17'd7)>>3) : SAMPLE_RATE_HZ==72000 ? (pressure_difference+17'd5)/17'd6 : ((pressure_difference+17'd3)>>2));

     default:begin end
    endcase
    if(age>=399)deadline_error<=1;
   end
   if(result_valid&&frame_flags[result_slot*4+1])voice_samples[result_slot*18+:18]<=result_sample;
   if(mix_valid)busy<=0;
   if(mixer_deadline)deadline_error<=1;
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(SHARE_FX!=0||BACKENDS!=1)$fatal(1,"II4_UNSUPPORTED_CONFIGURATION");
  if(busy&&age==305&&!mix_prepared)$fatal(1,"II4_MISSED_FX_HANDOFF");
  if(start&&busy)$fatal(1,"R40_OVERLAPPING_FRAME");
  if(work_active&&work_step==0&&age>=8&&pending&&!launch)$fatal(1,"R40_PENDING_OVERWRITE");
  if(observe_valid&&main_envelope)$fatal(1,"R40_ADSR_COLLISION");
  if(work_active&&work_step==1&&(old_glide_remaining!=0||old_glide_base!=0||old_glide_remainder!=0||old_glide_error!=0||old_code!=0))$fatal(1,"II4_DIRECT_PITCH_INVARIANT");
  if((backend_valid&(backend_valid-1'b1))!=0)$fatal(1,"R40_BACKEND_COLLISION");
  if(result_valid&&frame_flags[result_slot*4+1]&&states_shadow[result_slot]==0&&result_sample!=0)$fatal(1,"R40_RECLAIM_PROOF_BROKEN");
 end
 // synthesis translate_on
endmodule


// VOICES <= 64: one engine with VOICES/8 Lanes. VOICES > 64: ENGINES engines
// of 64 slots (8 Lanes) each run the same schedule in parallel; engine e owns
// slots e*64..e*64+63 and the stereo mixes are added.
module r28_control_audio_probe #(parameter integer SAMPLE_RATE_HZ=48000,parameter integer ID_WIDTH=64,parameter integer SHARE_FX=0,LOOP_ENABLE=0,VOICES=48,
  SW=(VOICES==(1<<$clog2(VOICES)))?$clog2(VOICES)+1:$clog2(VOICES))(
 output wire [127:0] ensemble_metrics,
 input wire fx_mac_use,input wire signed[35:0] fx_mac_a,input wire signed[17:0] fx_mac_b,
 output wire signed[53:0] fx_mac_q,
 input wire loop_cleanup_valid,loop_cleanup_all,loop_abort_batch,input wire[1:0] loop_cleanup_sources,input wire[15:0] loop_cleanup_revision,
 output wire loop_cleanup_ready,loop_cleanup_done,
 input wire clk,rst,frame_tick,hold_publication,panic,test_linear,
 input wire session_flush,session_ready,
 input wire lookup_valid,input wire[7:0] lookup_key,input wire[63:0] lookup_identity,
 input wire[15:0] lookup_generation,lookup_tag,
 output wire lookup_ready,lookup_response_valid,lookup_found,
 output wire[SW-1:0] lookup_response_slot,output wire[314:0] lookup_response_word,
 output wire[15:0] lookup_response_tag,
 input wire pan_valid,input wire[SW-1:0] pan_slot,input wire[63:0] pan_id,
 input wire[15:0] pan_generation,input wire[8:0] pan_value,
 output wire pan_ready,pan_response_valid,output wire[1:0] pan_result,
 output wire[SW-1:0] pan_response_slot,output wire[314:0] pan_before,pan_after,
 output wire[VOICES-1:0] audio_reclaim,output wire[17*VOICES-1:0] envelope_levels,
 input wire[3:0] glide_code,output wire mix_valid,output wire signed[31:0] mix_l_q8,mix_r_q8,
 output wire audio_busy,audio_protocol_error,audio_deadline_error,
 output wire[18*VOICES-1:0] voice_samples,output wire[3*VOICES-1:0] envelope_states,
 input wire event_valid,output wire event_ready,input wire[95:0] event_item,
 input wire event_last,input wire[2:0] timbre,
 output wire fact_valid,output wire[95:0] fact_item,
 output wire[7:0] fact_outcome,output wire[SW-1:0] fact_slot,
 output wire fact_steal,output wire[314:0] fact_before,fact_after,
 output wire batch_done,batch_abort,published,

 output wire[4*VOICES-1:0] audio_flags,output wire[7:0] audio_vibrato,
 output wire[31*VOICES-1:0] control_state,
 output wire busy,output wire protocol_error,
 input wire snapshot_valid,output wire snapshot_ready,output wire snapshot_done,
 input wire query_valid,output wire query_ready,input wire[1:0] query_view,
 input wire[SW-1:0] query_slot,output wire query_response_valid,
 output wire[314:0] query_response,
 output wire[31:0] accepted_events,output wire[31:0] max_event_cycles
);
 localparam integer LANES=VOICES/8,ENGINES=VOICES>64?VOICES/64:1,EL=LANES/ENGINES,EV=8*EL,ESW=(EL>8?7:6),
   EPW=37+4*(SAMPLE_RATE_HZ>=128000?15:SAMPLE_RATE_HZ>=72000?14:13);
 // Two engines: engine 1 runs the same schedule two clocks after engine 0.
 // Engine 0 uses the shared envelope in lane slot 0 and the shared timbre/LFO
 // unit in slot 2; engine 1 lands in slots 2 and 0, so neither collides.
 reg[1:0] start_delay;
 always @(posedge clk)start_delay<=rst?2'd0:{start_delay[0],frame_tick};
 wire[EPW+7:0] fe_envelope_request[0:1];wire[69:0] fe_timbre_request[0:1];wire[6:0] fe_release[0:1];
 wire[EPW-1:0] fe_envelope_response;wire[81:0] fe_timbre_response;
 // Engine 0 owns the pitch pROM; engine 1 reads it on engine 0's idle ages.
 wire pitch_issue[0:1];wire[6:0] pitch_note[0:1];wire[31:0] pitch_data[0:1];
 wire[3*LANES-1:0] audio_read_slots,audio_pan_slots;
 wire[31*LANES-1:0] audio_read_controls;wire[9*LANES-1:0] audio_read_pans;
 wire audio_retire;
 wire[SW-1:0] level_read_slot;wire[16:0] level_read_value;
 r28_serial_control #(.ID_WIDTH(ID_WIDTH),.LOOP_ENABLE(LOOP_ENABLE),.VOICES(VOICES)) controller(.*);
 wire[ENGINES-1:0] e_busy,e_mix_valid,e_retire,e_protocol,e_deadline;
 wire signed[31:0] e_mix_l[0:ENGINES-1],e_mix_r[0:ENGINES-1];
 wire[127:0] e_metrics[0:ENGINES-1];
 wire[16:0] e_level[0:ENGINES-1];
 for(genvar e=0;e<ENGINES;e++)begin: engines
  r28_frame_audio #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),.SHARE_FX(SHARE_FX),.LANES(EL),.EXTERNAL_FRONTEND(ENGINES==2),
   .PITCH_ROM_ROLE(ENGINES==2?(e==0?1:2):0)) audio(
   .fe_pitch_issue(pitch_issue[e]),.fe_pitch_note(pitch_note[e]),.fe_pitch_data(pitch_data[e]),
   .fe_alt_issue(ENGINES==2&&e==0?pitch_issue[ENGINES-1]:1'b0),.fe_alt_note(pitch_note[ENGINES-1]),.fe_pitch_data_in(pitch_data[0]),.ensemble_metrics(e_metrics[e]),
   .fx_mac_use(e==0?fx_mac_use:1'b0),.fx_mac_a(fx_mac_a),.fx_mac_b(fx_mac_b),.fx_mac_q(),
   .fe_envelope_request(fe_envelope_request[e]),.fe_timbre_request(fe_timbre_request[e]),.fe_release(fe_release[e]),
   .fe_envelope_response(fe_envelope_response),.fe_timbre_response(fe_timbre_response),
   .control_retire(e_retire[e]),.clk(clk),.rst(rst),.start(e==0?frame_tick:start_delay[1]),.test_linear(test_linear),.flags(audio_flags[e*4*EV+:4*EV]),
   .read_controls(audio_read_controls[e*31*EL+:31*EL]),.read_pans(audio_read_pans[e*9*EL+:9*EL]),
   .read_slots(audio_read_slots[e*3*EL+:3*EL]),.pan_slots(audio_pan_slots[e*3*EL+:3*EL]),
   .vibrato_depth(audio_vibrato),.glide_code(glide_code),.busy(e_busy[e]),.mix_valid(e_mix_valid[e]),.mix_l_q8(e_mix_l[e]),.mix_r_q8(e_mix_r[e]),
   .level_read_slot(ENGINES==1?ESW'(level_read_slot):ESW'(level_read_slot[5:0])),.level_read_value(e_level[e]),
   .envelope_levels(envelope_levels[e*17*EV+:17*EV]),.envelope_states(envelope_states[e*3*EV+:3*EV]),
   .reclaim_pending(audio_reclaim[e*EV+:EV]),.voice_samples(voice_samples[e*18*EV+:18*EV]),
   .completion_valid(),.completion_accept(),.completion_slot(),.completion_sample(),.protocol_error(e_protocol[e]),
   .deadline_error(e_deadline[e]),.last_complete_cycle());
 end
 assign fx_mac_q=54'd0;
 assign level_read_value=ENGINES==1?e_level[0]:e_level[level_read_slot>>6];
 // Engines share one schedule, so retire and publish edges coincide.
 assign audio_retire=e_retire[0];
 if(ENGINES==2)begin: shared_frontends
  r28_shared_envelope_glide #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),.PREPARED_RELEASE(SAMPLE_RATE_HZ==128000)) frontend(
   .prepared_release_q(fe_release[0]),.prepared_release_alt(fe_release[1]),.clk(clk),.rst(rst),.start(frame_tick),.busy(e_busy[0]),
   .envelope_requests({fe_envelope_request[1],fe_envelope_request[1],fe_envelope_request[0],fe_envelope_request[0]}),
   .envelope_response(fe_envelope_response),.glide_requests(456'd0),.glide_response(),.advance_requests(500'd0),.advance_response());
  r28_shared_timbre_lfo #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)) timbre_prepare(.clk(clk),.rst(rst),.start(frame_tick),.busy(e_busy[0]),
   .requests({fe_timbre_request[0],fe_timbre_request[0],fe_timbre_request[1],fe_timbre_request[1]}),.response(fe_timbre_response));
 end else begin: own_frontends
  assign fe_envelope_response=0;assign fe_timbre_response=0;
 end
 // The last engine finishes two clocks later; earlier mixes are held until then.
 assign mix_valid=e_mix_valid[ENGINES-1];
 assign audio_busy=|e_busy;
 assign audio_protocol_error=|e_protocol;
 assign audio_deadline_error=|e_deadline;
 if(ENGINES==1)begin: single
  assign mix_l_q8=e_mix_l[0];assign mix_r_q8=e_mix_r[0];
  assign ensemble_metrics=e_metrics[0];
 end else begin: summed
  // Saturate the engine sum to the existing 32-bit mix width.
  reg signed[33:0] sum_l,sum_r;
  always @*begin sum_l=0;sum_r=0;for(integer e=0;e<ENGINES;e++)begin sum_l=sum_l+e_mix_l[e];sum_r=sum_r+e_mix_r[e];end end
  function signed[31:0] clip(input signed[33:0] v);
   clip=(v[33:31]==3'b000||v[33:31]==3'b111)?v[31:0]:v[33]?32'h80000000:32'h7fffffff;
  endfunction
  assign mix_l_q8=clip(sum_l);assign mix_r_q8=clip(sum_r);
  // Count fields add across engines; flags OR; cycles and frame from engine 0.
  reg[7:0] allocated,gated,nonzero,peak,completed;reg[7:0] faults;
  always @*begin
   allocated=0;gated=0;nonzero=0;peak=0;completed=0;faults=0;
   for(integer e=0;e<ENGINES;e++)begin
    allocated=allocated+e_metrics[e][23:16];gated=gated+e_metrics[e][31:24];nonzero=nonzero+e_metrics[e][39:32];
    peak=peak+e_metrics[e][47:40];completed=completed+e_metrics[e][55:48];faults=faults|e_metrics[e][63:56];
   end
  end
  assign ensemble_metrics={e_metrics[0][127:64],faults,completed,peak,nonzero,gated,allocated,8'(VOICES),e_metrics[0][7:0]};
 end
endmodule

module r28_execution_observer(
 input wire pan_applied,input wire[5:0] pan_applied_slot,input wire[314:0] pan_applied_word,
 input wire clk,rst,audio_reset,start_valid,stop_valid,capture_fault,
 input wire[7:0] capture_fault_code,input wire stop_delivery_idle,
 input wire[63:0] start_record_id,frame_id,input wire[15:0] subcycle,
 input wire allocator_busy,batch_begin,publish_ok,batch_abort,input wire[31:0] batch_timestamp,
 input wire fact_valid,input wire[95:0] fact_item,input wire[7:0] fact_outcome,
 input wire[5:0] fact_slot,input wire fact_steal,input wire[314:0] fact_before,fact_after,
 input wire[63:0] fact_frame,input wire[15:0] fact_subcycle,input wire reclaim_batch_busy,
 input wire[47:0] slot_valid,slot_gate,
 output wire[63:0] allocated_persistent_id,
 output wire snapshot_query_valid,input wire snapshot_query_ready,output wire[5:0] snapshot_query_slot,
 input wire snapshot_response_valid,input wire[5:0] snapshot_response_slot,input wire[314:0] snapshot_response_word,
 output reg active,arming,incomplete,output reg[7:0] error_code,output reg[63:0] first_missing_frame,
 output wire tx_valid,output reg[5:0] tx_count,input wire[5:0] tx_index,output wire[255:0] tx_cell,
 input wire tx_read_valid,input wire[15:0] tx_read_epoch,
 output reg tx_response_valid,output reg[5:0] tx_response_index,output reg[15:0] tx_response_epoch,
 input wire tx_ready,tx_done,output reg[31:0] published_batches,aborted_batches,applied_items,initial_instances,
 output reg[63:0] persistent_id_next,output wire observer_idle,output wire pipeline_empty
);
 // Facts are collected while the unpublished working bank is computed.
 // One frame marker publishes their common audible timestamp. The musical
 // descriptor retains every EVR2 field; external identities stay in Allocator.
 reg[31:0] memory[0:511] /* synthesis syn_ramstyle="block_ram" */;
 reg write_bank,read_bank;reg[1:0] pending;
 reg[7:0] write_count,bank_count[0:1];reg[6:0] offset;
 reg[63:0] bank_frame[0:1];reg[15:0] bank_subcycle[0:1];reg[31:0] bank_timestamp[0:1];
 reg second_write;reg[31:0] write_high;reg[8:0] write_address;
 reg[8:0] read_address;reg[31:0] ram_q,read_low;
 reg[2:0] read_phase;reg[5:0] request_index;reg[15:0] request_epoch;
 reg[63:0] request_frame;reg[15:0] request_subcycle;
 reg inflight,stop_pending,stop_cell;reg[1:0] owner;
 reg[47:0] initial_mask;reg[5:0] snap_index;
 reg[58:0] snap_word;reg snap_loaded,snap_wait;
 reg[63:0] snap_frame,stop_frame;reg[15:0] snap_subcycle,stop_subcycle;
 reg[223:0] response;
 wire starting=start_valid&&!active&&!arming&&pending==0&&!inflight&&!allocator_busy&&start_record_id!=0;
 wire musical=fact_valid&&fact_outcome>=1&&fact_outcome<=4;
 wire capture=(active||stop_pending)&&(musical||pan_applied)&&!batch_abort&&!incomplete;
 wire[314:0] selected=pan_applied?pan_applied_word:fact_outcome==1?fact_after:fact_before;
 wire[63:0] descriptor={pan_applied?1'b0:fact_steal,pan_applied?3'd5:fact_outcome[2:0],
  pan_applied?3'h7:fact_item[30:28],pan_applied?8'hff:fact_item[23:16],
  pan_applied?pan_applied_slot:fact_slot[5:0],selected[58:43],selected[12:4],selected[30:28],
  pan_applied?8'd0:fact_item[8:1],pan_applied?7'd0:fact_item[15:9]};
 wire capture_ok=capture&&!pending[write_bank]&&!second_write&&write_count<128;
 wire publishing=(active||stop_pending)&&publish_ok&&write_count!=0&&!incomplete;
 wire[7:0] remaining=bank_count[read_bank]-{1'b0,offset};
 wire[3:0] chunk=remaining>9?4'd9:remaining[3:0];
 wire[1:0] current=arming?2'd1:pending[read_bank]?2'd2:2'd3;
 wire[1:0] selected_owner=inflight?owner:current;
 assign allocated_persistent_id=0;
 assign pipeline_empty=!arming&&pending==0&&!inflight&&!stop_pending&&!stop_cell&&write_count==0&&!second_write;
 assign observer_idle=!active&&pipeline_empty;
 assign tx_valid=!incomplete&&!inflight&&(arming?(snap_index==0||snap_loaded):(pending[read_bank]||stop_cell));
 always @* tx_count=selected_owner==2?{2'd0,chunk}+6'd1:6'd1;
 assign snapshot_query_valid=arming&&snap_index>0&&!snap_loaded&&!snap_wait&&!incomplete;
 assign snapshot_query_slot=snap_index-1'b1;
 reg[5:0] next_snapshot;
 always @*begin next_snapshot=49;for(integer i=47;i>=0;i--)if(initial_mask[i]&&i+1>snap_index)next_snapshot=i+1;end
 function automatic[223:0] cell_data(input[7:0] typ,flags,src,key,input[63:0] fr,id,p);
  cell_data={p,id,fr,key,src,flags,typ};
 endfunction
 function automatic[223:0] decode(input[63:0] d,fr,input[15:0] sc);
  reg[2:0] kind;reg[7:0] typ,src,key;reg[63:0] id,p;
  begin
   kind=d[62:60];typ=kind==1?4:kind==2?5:kind==3?6:kind==4?7:16;
   src=kind==5?8'hff:{5'd0,d[59:57]};key=d[56:49];
   id=kind==4?0:{41'd0,d[48],1'b1,d[42:27],d[47:43]};
   p=kind==4?{40'd0,d[14:7],sc}:kind==5?{d[47:18],18'd0,sc}:{d[47:0],sc};
   decode=cell_data(typ,(d[63]?8'd32:8'd0)|((kind!=4&&d[48])?8'd64:8'd0),src,key,fr,id,p);
  end
 endfunction
 wire memory_write_enable=!rst&&(capture_ok||second_write);
 wire[8:0] memory_write_address=capture_ok?{write_bank,write_count[6:0],1'b0}:write_address;
 wire[31:0] memory_write_data=capture_ok?descriptor[31:0]:write_high;
 always @(posedge clk)begin
  ram_q<=memory[read_address];
  if(memory_write_enable)memory[memory_write_address]<=memory_write_data;
 end
 assign tx_cell={response[223:32],32'd0,response[31:0]};
 always @(posedge clk)begin
  tx_response_valid<=0;
  if(rst)begin
   read_phase<=0;read_address<=0;read_low<=0;request_index<=0;request_epoch<=0;
   request_frame<=0;request_subcycle<=0;tx_response_index<=0;tx_response_epoch<=0;
  end else begin
   if(tx_read_valid)begin
    request_index<=tx_index;request_epoch<=tx_read_epoch;
    if(selected_owner==2&&tx_index<chunk)begin
     read_address<={read_bank,7'(offset+tx_index),1'b0};read_phase<=1;
     request_frame<=bank_frame[read_bank];request_subcycle<=bank_subcycle[read_bank];
    end else begin
     tx_response_valid<=1;tx_response_index<=tx_index;tx_response_epoch<=tx_read_epoch;
     if(selected_owner==1)begin
      if(snap_index==0)response<=cell_data(1,3,255,255,snap_frame,0,{48'd0,snap_subcycle});
      else response<=cell_data(8,(snap_word[2]?8'd3:8'd19)|(snapshot_query_slot[5]?8'd64:8'd0),{4'd0,snap_word[42:39]},snap_word[38:31],snap_frame,
       {41'd0,snapshot_query_slot[5],1'b1,snap_word[58:43],snapshot_query_slot[4:0]},{snapshot_query_slot[4:0],snap_word[58:43],snap_word[12:4],snap_word[30:28],snap_word[27:20],snap_word[19:13],snap_subcycle});
     end else if(selected_owner==3)response<=cell_data(22,1,255,255,stop_frame,0,{48'd0,stop_subcycle});
     else response<=cell_data(25,1,255,255,bank_frame[read_bank],0,{16'd0,bank_timestamp[read_bank],bank_subcycle[read_bank]});
    end
   end else if(read_phase!=0)begin
    if(read_phase==1)begin read_address<=read_address+1'b1;read_phase<=2;end
    else if(read_phase==2)begin read_low<=ram_q;read_phase<=3;end
    else begin
     response<=decode({ram_q,read_low},request_frame,request_subcycle);
     tx_response_valid<=1;tx_response_index<=request_index;tx_response_epoch<=request_epoch;read_phase<=0;
    end
   end
  end
 end
 always @(posedge clk)begin
  if(rst)begin
   write_bank<=0;read_bank<=0;pending<=0;write_count<=0;offset<=0;
   bank_count[0]<=0;bank_count[1]<=0;bank_frame[0]<=0;bank_frame[1]<=0;
   bank_subcycle[0]<=0;bank_subcycle[1]<=0;bank_timestamp[0]<=0;bank_timestamp[1]<=0;
   second_write<=0;write_high<=0;write_address<=0;
   active<=0;arming<=0;incomplete<=0;error_code<=0;first_missing_frame<=64'hffffffffffffffff;
   inflight<=0;stop_pending<=0;stop_cell<=0;owner<=0;initial_mask<=0;snap_index<=0;snap_word<=0;
   snap_loaded<=0;snap_wait<=0;snap_frame<=0;snap_subcycle<=0;stop_frame<=0;stop_subcycle<=0;
   published_batches<=0;aborted_batches<=0;applied_items<=0;initial_instances<=0;persistent_id_next<=0;
  end else begin
   second_write<=0;
   if(capture_ok)begin
    second_write<=1;write_high<=descriptor[63:32];write_address<={write_bank,write_count[6:0],1'b1};
    write_count<=write_count+1'b1;applied_items<=applied_items+1'b1;
   end
   if(publishing)begin
    pending[write_bank]<=1;bank_count[write_bank]<=write_count;
    bank_frame[write_bank]<=frame_id;bank_subcycle[write_bank]<=subcycle;bank_timestamp[write_bank]<=batch_timestamp;
    write_bank<=~write_bank;write_count<=0;published_batches<=published_batches+1'b1;
   end
   if(snapshot_query_valid&&snapshot_query_ready)snap_wait<=1;
   if(snapshot_response_valid&&snap_wait&&snapshot_response_slot==snapshot_query_slot)begin
    snap_word<=snapshot_response_word[58:0];snap_wait<=0;snap_loaded<=1;
   end
   if(tx_valid&&tx_ready)begin inflight<=1;owner<=current;end
   if(tx_done&&inflight)begin
    inflight<=0;
    if(owner==1)begin
     if(snap_index!=0)initial_instances<=initial_instances+1'b1;
     snap_loaded<=0;snap_wait<=0;snap_index<=next_snapshot;
     if(next_snapshot==49)arming<=0;
    end else if(owner==2)begin
     if(remaining<=9)begin pending[read_bank]<=0;read_bank<=~read_bank;offset<=0;end
     else offset<=offset+chunk;
    end else stop_cell<=0;
   end
   if(starting)begin
    active<=1;arming<=1;incomplete<=0;error_code<=0;first_missing_frame<=64'hffffffffffffffff;
    initial_mask<=slot_valid;snap_frame<=frame_id;snap_subcycle<=subcycle;snap_index<=0;snap_loaded<=0;snap_wait<=0;
    write_bank<=0;read_bank<=0;pending<=0;write_count<=0;offset<=0;stop_pending<=0;stop_cell<=0;
   end
   if(stop_valid&&active)begin active<=0;stop_pending<=1;end
   if(stop_pending&&stop_delivery_idle&&!allocator_busy&&pending==0&&write_count==0&&!inflight&&!arming)begin
    stop_frame<=frame_id;stop_subcycle<=subcycle;stop_cell<=1;stop_pending<=0;
   end
   if(capture&&!capture_ok || publishing&&(second_write||capture||pending[write_bank]))begin
    incomplete<=1;error_code<=2;active<=0;first_missing_frame<=frame_id;
   end
   if(batch_abort&&(active||arming||pending!=0||inflight||stop_pending))begin
    incomplete<=1;error_code<=5;active<=0;first_missing_frame<=frame_id;aborted_batches<=aborted_batches+1'b1;
   end
   if((capture_fault||audio_reset)&&(active||arming||pending!=0||inflight||stop_pending))begin
    incomplete<=1;error_code<=audio_reset?8'd5:capture_fault_code;active<=0;
   end
   if(incomplete&&!inflight&&!starting)begin
    active<=0;arming<=0;pending<=0;write_count<=0;stop_pending<=0;stop_cell<=0;snap_wait<=0;
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(capture&&musical&&fact_item[31:28]>3)$fatal(1,"EVR_SOURCE_RANGE_PROOF");
  if(tx_read_valid&&tx_index>=tx_count)$fatal(1,"R28_JOURNAL_INDEX");
  if(tx_read_valid&&read_phase!=0)$fatal(1,"R28_JOURNAL_OVERLAPPING_READ");
  if(capture&&musical&&pan_applied)$fatal(1,"R28_JOURNAL_TWO_FACTS");
 end
 // synthesis translate_on
endmodule

module r28_instrument_engine #(parameter integer SAMPLE_RATE_HZ=48000,parameter integer LEASED_ITEM=0,NO_UNDO=0,INDEXED_INPUT=0,ID_WIDTH=64,PHONE_LOOKUP=0,CLK_FREQ_HZ=50_000_000,parameter integer SHARE_FX=0,LOOP_ENABLE=0,VOICES=48)(
 output wire [127:0] ensemble_metrics,
 input wire fx_mac_use,input wire signed[35:0] fx_mac_a,input wire signed[17:0] fx_mac_b,
 output wire signed[53:0] fx_mac_q,
 input wire loop_cleanup_valid,loop_cleanup_all,loop_abort_batch,input wire[1:0] loop_cleanup_sources,input wire[15:0] loop_cleanup_revision,
 output wire loop_cleanup_ready,loop_cleanup_done,
 input wire[2:0] event_loop_timbre,
 input wire hold_publication,output wire audible_publish,
 input wire[95:0] indexed_item,input wire[2:0] indexed_occupancy,output wire[3:0] indexed_item_index,
 input wire session_flush,session_ready,input wire[575:0] event_phone_presses,
 input wire lookup_valid,lookup_pan,input wire[7:0] lookup_key,
 input wire[63:0] lookup_identity,input wire[15:0] lookup_generation,lookup_tag,
 output wire lookup_ready,lookup_response_valid,lookup_found,
 output wire[5:0] lookup_response_slot,output wire[314:0] lookup_response_word,
 output wire[15:0] lookup_response_tag,
 input wire clk,rst,sample_tick,panic,test_linear,
 input wire event_valid,output wire event_ready,input wire[904:0] event_packet,
 input wire[2:0] timbre_id,input wire[3:0] glide_code,
 input wire[63:0] frame_id,input wire[15:0] subcycle,input wire[63:0] allocated_persistent_id,
 input wire snapshot_valid,snapshot_record_start,output wire snapshot_ready,
 input wire pan_valid,input wire[5:0] pan_slot,input wire[63:0] pan_id,
 input wire[15:0] pan_generation,input wire[8:0] pan_value,output wire pan_ready,
 output wire pan_response_valid,output wire[1:0] pan_result,
 output wire[5:0] pan_response_slot,output wire[314:0] pan_before,pan_after,
 output wire reclaim_batch_busy,
 input wire query_valid,query_snapshot,input wire[5:0] query_slot,output wire query_ready,
 output wire query_response_valid,output wire[5:0] query_response_slot,output wire[314:0] query_response_word,
 output wire mix_valid,output wire signed[31:0] mix_l_q8,mix_r_q8,
 output wire[815:0] envelope_levels,output wire[143:0] envelope_states,output wire[863:0] voice_samples,
 output wire protocol_error,deadline_error,output wire[2:0] queue_occupancy,
 output wire batch_begin,batch_publish,batch_abort,output wire[31:0] batch_timestamp,
 output wire fact_valid,output wire[3:0] fact_lane,output wire[95:0] fact_item,
 output wire[7:0] fact_outcome,output wire[5:0] fact_slot,output wire fact_steal,
 output wire[314:0] fact_before,fact_after,output wire[63:0] fact_frame,output wire[15:0] fact_subcycle,
 output wire identity_stable,output wire event_busy,audio_busy,
 output wire[47:0] control_valid,control_gate,
 output wire[1487:0] control_state,output wire[3:0] batch_source
);
 reg[2:0] delivery;reg[8:0] mask;reg[3:0] index,source_q;reg[31:0] stamp;
 reg started;reg[2:0] loop_timbre_q;reg[95:0] item_q;reg[5:0] query_slot_q;
 wire controller_ready,controller_busy,controller_error,batch_done,controller_abort,snapshot_done;
 // Ports above keep the 48-slot, 6-bit layout; with more voices the probe's
 // wider slot fields and vectors are truncated or zero-extended here.
 wire[4*VOICES-1:0] audio_flags;wire[7:0] audio_vibrato;
 wire[VOICES-1:0] audio_reclaim;wire audio_protocol;
 function[3:0] next_item(input[8:0] m,input[3:0] begin_at);
  begin next_item=9;for(integer i=8;i>=0;i--)if(i>=begin_at&&m[i])next_item=4'(i);end
 endfunction
 wire[3:0] following=next_item(mask,index+4'd1);
 assign event_ready=delivery==0&&controller_ready;
 assign indexed_item_index=index;
 assign batch_begin=delivery==3&&controller_ready&&!started;
 assign batch_publish=batch_done;
 assign batch_abort=controller_abort||(delivery!=0&&panic&&!started);
 assign batch_source=source_q;assign batch_timestamp=stamp;
 assign fact_lane=index;assign fact_frame=frame_id;assign fact_subcycle=subcycle;
 assign protocol_error=controller_error||audio_protocol;
 assign queue_occupancy=indexed_occupancy;
 assign identity_stable=snapshot_ready&&delivery==0;
 assign event_busy=controller_busy||delivery!=0;
 assign reclaim_batch_busy=fact_valid&&fact_outcome==10;
 assign query_response_slot=query_slot_q;
 for(genvar s=0;s<48;s++)begin
  assign control_valid[s]=audio_flags[s*4+1];assign control_gate[s]=audio_flags[s*4+2];
 end
 always @(posedge clk)begin
  if(rst)begin delivery<=0;mask<=0;index<=0;source_q<=0;stamp<=0;started<=0;loop_timbre_q<=0;item_q<=0;query_slot_q<=0;end
  else begin
   if(query_valid&&query_ready)query_slot_q<=query_slot;
   case(delivery)
    0:if(event_valid&&event_ready)begin mask<=event_packet[872:864];stamp<=event_packet[904:873];source_q<=event_packet[31:28];loop_timbre_q<=event_loop_timbre;index<=next_item(event_packet[872:864],0);delivery<=1;end
    1:delivery<=2;
    2:begin if(!LEASED_ITEM)item_q<=indexed_item;delivery<=3;end
    3:if(controller_ready)begin delivery<=4;started<=1;end
    4:if(fact_valid&&fact_outcome!=10)begin
     if(following==9)delivery<=5;else begin index<=following;delivery<=1;end
    end
    5:begin end
    default:delivery<=0;
   endcase
   if(batch_done||batch_abort)begin delivery<=0;started<=0;end
  end
 end
 // synthesis translate_off
 reg[95:0] leased_reference;
 always @(posedge clk)begin
  if(!rst&&delivery==2)leased_reference<=indexed_item;
  if(!rst&&LEASED_ITEM&&delivery==3&&controller_ready&&indexed_item!==leased_reference)
   $fatal(1,"R45_EVENT_LEASE_CHANGED");
 end
 // synthesis translate_on
 r28_control_audio_probe #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),.ID_WIDTH(ID_WIDTH),.SHARE_FX(SHARE_FX),.LOOP_ENABLE(LOOP_ENABLE),.VOICES(VOICES)) core(.test_linear(test_linear),.ensemble_metrics(ensemble_metrics),.loop_cleanup_valid(loop_cleanup_valid),.loop_cleanup_sources(loop_cleanup_sources),.loop_cleanup_all(loop_cleanup_all),.loop_cleanup_revision(loop_cleanup_revision),.loop_cleanup_ready(loop_cleanup_ready),.loop_cleanup_done(loop_cleanup_done),.loop_abort_batch(loop_abort_batch),.fx_mac_use(fx_mac_use),.fx_mac_a(fx_mac_a),.fx_mac_b(fx_mac_b),.fx_mac_q(fx_mac_q),.clk(clk),.rst(rst),.frame_tick(sample_tick),.hold_publication(hold_publication),.panic(panic),
 .session_flush(PHONE_LOOKUP?session_flush:1'b0),.session_ready(PHONE_LOOKUP?session_ready:1'b1),.lookup_valid(PHONE_LOOKUP?lookup_valid:1'b0),.lookup_key(lookup_key),.lookup_identity(lookup_identity),
 .lookup_generation(lookup_generation),.lookup_tag(lookup_tag),.lookup_ready(lookup_ready),.lookup_response_valid(lookup_response_valid),
 .lookup_found(lookup_found),.lookup_response_slot(lookup_response_slot),.lookup_response_word(lookup_response_word),.lookup_response_tag(lookup_response_tag),
 .pan_valid(pan_valid),.pan_slot(pan_slot),.pan_id(pan_id),.pan_generation(pan_generation),.pan_value(pan_value),.pan_ready(pan_ready),
 .pan_response_valid(pan_response_valid),.pan_result(pan_result),.pan_response_slot(pan_response_slot),.pan_before(pan_before),.pan_after(pan_after),
 .audio_reclaim(audio_reclaim),.envelope_levels(envelope_levels),.glide_code(glide_code),.mix_valid(mix_valid),.mix_l_q8(mix_l_q8),.mix_r_q8(mix_r_q8),
 .audio_busy(audio_busy),.audio_protocol_error(audio_protocol),.audio_deadline_error(deadline_error),.voice_samples(voice_samples),.envelope_states(envelope_states),
 .event_valid(delivery==3),.event_ready(controller_ready),.event_item(LEASED_ITEM?indexed_item:item_q),.event_last(following==9),.timbre(LOOP_ENABLE&&source_q==3?loop_timbre_q:timbre_id),
 .fact_valid(fact_valid),.fact_item(fact_item),.fact_outcome(fact_outcome),.fact_slot(fact_slot),.fact_steal(fact_steal),.fact_before(fact_before),.fact_after(fact_after),
 .batch_done(batch_done),.batch_abort(controller_abort),.published(audible_publish),.audio_flags(audio_flags),.audio_vibrato(audio_vibrato),.control_state(control_state),
 .busy(controller_busy),.protocol_error(controller_error),.snapshot_valid(snapshot_valid),.snapshot_ready(snapshot_ready),.snapshot_done(snapshot_done),
 .query_valid(query_valid),.query_ready(query_ready),.query_view(query_snapshot?2'd2:2'd0),.query_slot(query_slot),.query_response_valid(query_response_valid),.query_response(query_response_word),
 .accepted_events(),.max_event_cycles());
endmodule

module r28_prepared_backend #(parameter DERIVE_FM=1,parameter integer INITIAL_CYCLE=0)(
 input wire[31:0] prepared_lo,prepared_hi,input wire[16:0] prepared_taper,
 input wire clk,rst,in_valid,output wire in_ready,
 input wire [4:0] in_tag,input wire [193:0] job_in,
 output reg out_valid,output reg [4:0] out_tag,
 output reg signed [17:0] out_sample,output reg [31:0] out_phase
);
 reg [4:0] cycle;
 wire [3:0] step=cycle[3:0];wire bank=cycle[4];
 wire prev=~bank,prev2=bank;
 reg [1:0] occupied;
 reg tail_valid;reg [4:0] tail_tag;reg [31:0] tail_phase;
 // Early operands die by offset 12, before the next offset-0 input.
 // Only envelope/gain/taper/timbre cross into the second 16-clock window.
 reg [193:105] early_high;reg [70:37] early_timbre;
 reg [53:0] late_job[0:1];wire [193:0] job[0:1];
 for(genvar j=0;j<2;j++)assign job[j]={early_high,late_job[j][53:20],early_timbre,17'd0,late_job[j][19:0]};reg [4:0] tag[0:1];
 reg [31:0] low_step,delta_step,base_step,adjusted,phase,carrier_phase;
 reg signed [17:0] modulation,wave;
 reg [16:0] taper,raw_index,fm_index,amplitude,w1,w2,w3;
 reg signed [15:0] h1,h2,h3,carrier;
 reg signed [53:0] term1,term3,pressure_product;
 reg signed [35:0] term2,env_product;
 reg signed [35:0] wa,wa_q;reg signed [17:0] wb,wb_q,na,nb,na_q,nb_q;
 reg signed [53:0] wp,wq;
 reg signed [35:0] np,nq;
 wire[31:0] lo=prepared_lo,hi=prepared_hi;
 wire[16:0] input_taper=prepared_taper;
 wire [31:0] harmonic2_phase=phase<<1;
 wire [31:0] harmonic3_phase=phase+(phase<<1);
 reg [7:0] sine_address;
 wire signed [15:0] sine_value;
 reg signed [15:0] fm_sine;
 always @*begin
  case(step)
   13:sine_address=job[bank][2:0]==1 ? harmonic2_phase[31:24]:phase[31:24];
   14:sine_address=phase[31:24];
   15:sine_address=harmonic2_phase[31:24];
   0:sine_address=harmonic3_phase[31:24];
   2:sine_address=carrier_phase[31:24];
   default:sine_address=0;
  endcase
 end
 sine_rom shared_sine(.address(sine_address),.sample(sine_value));
 assign in_ready=!rst && step==0;

 // Rounding is copied from the frozen arithmetic contract; only scheduling
 // and shared operator ownership change. No extra intermediate quantization.
 // Nearest rounding, ties away from zero: keep the signed quotient,
 // increment at/above half for positive, strictly above half for negative.
 // This removes the wide absolute-value and sign-restoration datapaths.
 function signed [17:0] round_mod(input signed [51:0] value);
  round_mod=(value>>>31)+((value[30]&&(!value[51]||(|value[29:0])))?52'sd1:52'sd0);
 endfunction
 function signed [34:0] round_delta(input signed [50:0] value);
  round_delta=(value>>>16)+((value[15]&&(!value[50]||(|value[14:0])))?51'sd1:51'sd0);
 endfunction
 function signed [17:0] round_audio(input signed [53:0] value);
  reg signed [22:0] shifted;
  begin
   shifted=(value>>>32)+((value[31]&&(!value[53]||(|value[30:0])))?54'sd1:54'sd0);
   if(shifted>23'sd131071)round_audio=18'sh1ffff;
   else if(shifted < -23'sd131072)round_audio=18'h20000;
   else round_audio=shifted[17:0];
  end
 endfunction
 wire signed [17:0] carrier_wide={{2{carrier[15]}},carrier};
 wire signed [17:0] shaped=carrier>16'sd16384 ? 
     18'sd16384+((carrier_wide-18'sd16384)>>>1):
     carrier< -16'sd16384 ? -18'sd16384+((carrier_wide+18'sd16384)>>>1):carrier_wide;
 wire signed [35:0] shape_delta=$signed(shaped)-$signed(carrier_wide);
 wire signed [63:0] harmonic_total=$signed(term1)+$signed(term2)+$signed(term3);
 wire signed [63:0] shaped_total=$signed(carrier_wide)+($signed(term1)>>>16);
 wire [48:0] interpolated={17'd0,low_step}+(({1'b0,wq[47:0]}+49'd32768)>>16);
 wire signed [35:0] adjusted_wide=$signed({4'b0,base_step})+$signed(round_delta(wq[50:0]));

 // The wide unit has reserved issue offsets 1,4,8,19,21,27,31.
 // The narrow unit has reserved offsets 1,2,4,5,7,14,22.
 // Modulo-16 residues are distinct within each unit.
 always @* begin
  wa=0;wb=0;na=0;nb=0;
  case(step)
   1:begin
    wa=$signed({4'd0,delta_step});wb=$signed({2'd0,job[bank][153:138]});
    na=$signed(job[bank][137:122]);nb=$signed({1'b0,job[bank][121:105]});
   end
   4:begin
    wa=$signed(nq[33:0]);wb=18'sd655;
    na=$signed({1'b0,job[bank][70:54]});
    nb=job[bank][2:0]==1 ? 18'sd52429:18'sd5000;
   end
   8:begin wa=$signed({4'd0,base_step});wb=modulation;end
   3:begin
    case(job[prev][2:0])
     1:begin wa=$signed(carrier);wb=$signed({1'b0,amplitude});end
     2,3:begin wa=$signed(h1);wb=$signed({1'b0,w1});end
     4:begin wa=shape_delta;wb=$signed({1'b0,job[prev][19:3]});end
     default:begin wa=0;wb=0;end
    endcase
   end
   5:begin
    wa=$signed(h3);wb=$signed({1'b0,w3});
    na=$signed({1'b0,job[bank][70:54]});nb=18'sd2500;
   end
   11:begin wa=$signed(wave);wb=$signed({1'b0,job[prev][104:88]});end
   15:begin wa=$signed(env_product);wb=$signed({1'b0,job[prev][87:71]});end
   default:begin end
  endcase
  case(step)
   2:begin
    na=$signed({1'b0,job[bank][2:0]==1 ? job[bank][70:54]:job[bank][53:37]});
    nb=job[bank][2:0]==1 ? 18'sd20000:18'sd24000;
   end
   7:begin na=$signed({1'b0,raw_index});nb=$signed({1'b0,taper});end
   14:begin na=fm_sine;nb=$signed({1'b0,fm_index});end
   6:begin na=$signed(h2);nb=$signed({1'b0,w2});end
   default:begin end
  endcase
 end

 always @(posedge clk)begin
  if(rst)begin wa_q<=0;wb_q<=0;na_q<=0;nb_q<=0;wp<=0;wq<=0;np<=0;nq<=0;end
  else begin
   wa_q<=wa;wb_q<=wb;na_q<=na;nb_q<=nb;
   wp<=wa_q*wb_q;wq<=wp;np<=na_q*nb_q;nq<=np;
  end
 end
 always @(posedge clk)begin
  if(rst)begin cycle<=5'(INITIAL_CYCLE);occupied<=0;tail_valid<=0;tail_tag<=0;tail_phase<=0;out_valid<=0;out_tag<=0;out_sample<=0;out_phase<=0;end
  else begin
   cycle<=cycle+1'b1;out_valid<=0;
   case(step)
    0:begin
     occupied[bank]<=in_valid;h3<=sine_value;
     if(in_valid)begin
      early_high<=job_in[193:105];early_timbre<=job_in[70:37];late_job[bank]<={job_in[104:71],job_in[19:0]};tag[bank]<=in_tag;low_step<=lo;delta_step<=hi-lo;
      taper<=input_taper;
      if(DERIVE_FM)late_job[bank][19:3]<=input_taper;
      if(!DERIVE_FM)fm_index<=job_in[36:20];
     end
    end
    4:base_step<=interpolated[31:0];
    5:begin
     raw_index<=job[bank][2:0]==1 ? nq[31:16]:job[bank][2:0]==4 ? 17'd10000:17'd0;
     w1<=job[bank][2:0]==2 ? 17'd18000:17'd1000+nq[32:16];
    end
    7:begin
     modulation<=round_mod(wq[51:0]);
     amplitude<=17'd13107+nq[32:16];
     w2<=base_step<32'h40000000 ? (job[bank][2:0]==2 ? 17'd10000:nq[32:16]):17'd0;
    end
    8:begin
     w3<=base_step<32'd715827882 ? (job[bank][2:0]==2 ? 17'd4000:nq[32:16]):17'd0;
     term3<=wq;
    end
    10:begin
     tail_phase<=phase;
     if(DERIVE_FM)fm_index<=nq[32:16];
     case(job[prev][2:0])
      1:wave<=$signed(term1)>>>16;
      2,3:wave<=(harmonic_total+64'sd16384)>>>15;
      4:wave<=shaped_total;
      default:wave<=h1;
     endcase
    end
    11:adjusted<=adjusted_wide[31:0];
    12:phase<=job[bank][161] ? 32'd0:job[bank][193:162]+adjusted;
    13:fm_sine<=sine_value;
    1:carrier_phase<=phase+(nq[31:0]<<1);
    2:begin carrier<=sine_value;pressure_product<=wq;end
    6:term1<=wq;
    9:term2<=nq;
    14:begin env_product<=wq[35:0];h1<=sine_value;end
    15:begin tail_valid<=occupied[prev];tail_tag<=tag[prev];h2<=sine_value;end
    3:if(tail_valid)begin out_valid<=1;out_tag<=tail_tag;out_sample<=round_audio(pressure_product);out_phase<=tail_phase;end
    default:begin end
   endcase
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst && in_valid && !in_ready)$fatal(1,"R18_UNSCHEDULED_INPUT");
 // synthesis translate_on
endmodule

// Pending jobs appear after age6. Capture four lane pitches at ages7..10,
// compute their common tables/taper at ages8..11, launch all backends at16.
// Every lane keeps its own phase, frequency/glide and envelope context.
module r28_shared_pitch_prepare(
 input wire clk,rst,start,busy,input wire[91:0] pitches,
 output reg[255:0] steps,output reg[67:0] tapers
);
 reg[7:0] age;reg[22:0] pitch_q;reg[1:0] lane_q;reg request_valid;
 wire[1:0] next_lane=age[1:0]-2'd3;
 wire[22:0] selected_pitch=pitches[next_lane*23+:23];
 wire[6:0] selected_note=selected_pitch[22:16];
 wire rom_issue=busy&&age<128&&age[3:0]>=7&&age[3:0]<=14;
 wire upper=age[3:0]>=11;
 wire[6:0] rom_note=upper&&selected_note!=127?selected_note+1'b1:selected_note;
 wire[31:0] rom_data;reg rom_valid,upper_q;reg[1:0] rom_lane;
 wire[16:0] taper=pitch_q<=23'd7077888 ? 17'd65536:
   pitch_q>=23'd7864320 ? 17'd0:(23'd7864320-pitch_q)/12;
 // Four lower-note requests at7..10, four upper requests at11..14.
 // Their one-cycle responses finish at15, before all four launches at16.
 pROM #(
  .BIT_WIDTH(32),
  .READ_MODE(1'b0),
  .RESET_MODE("SYNC"),
  .INIT_RAM_00(256'h0010b9a3000fc953000ee681000e1069000d4656000c879a000bd393000b29a6),
  .INIT_RAM_01(256'h001a8cac00190f340017a7260016534c001512860013e3c00012c5f90011b83c),
  .INIT_RAM_02(256'h002a250c0027c78100258bf20023707800217345001f92a7001dcd02001c20d3),
  .INIT_RAM_03(256'h0042e68b003f254e003b9a04003841a60035195800321e69002f4e4b002ca698),
  .INIT_RAM_04(256'h006a32b100643cd2005e9c9600594d3100544a17004f8f01004b17e50046e0f0),
  .INIT_RAM_05(256'h00a8942e009f1e0300962fc9008dc1e10085cd15007e4a9b007734070070834c),
  .INIT_RAM_06(256'h010b9a2b00fc953600ee680f00e1069700d4656200c879a300bd392d00b29a62),
  .INIT_RAM_07(256'h01a8cac30190f347017a725a016534c30151285d013e3c06012c5f93011b83c2),
  .INIT_RAM_08(256'h02a250ba027c780b0258bf26023707830217345601f92a6d01dcd01d01c20d2f),
  .INIT_RAM_09(256'h042e68ac03f254d903b9a03a03841a5d035195860321e68d02f4e4b402ca6987),
  .INIT_RAM_0A(256'h06a32b0d0643cd1b05e9c9680594d30d0544a17304f8f01704b17e4b046e0f07),
  .INIT_RAM_0B(256'h0a8942e709f1e02d0962fc9608dc1e0d085cd15707e4a9b207734075070834ba),
  .INIT_RAM_0C(256'h10b9a2af0fc953640ee680e90e1069740d46561a0c879a350bd392d00b29a61a),
  .INIT_RAM_0D(256'h1a8cac34190f346a17a725a016534c35151285ce13e3c05a12c5f92c11b83c1a),
  .INIT_RAM_0E(256'h2a250b9c27c780b5258bf259237078352173455e1f92a6c81dcd01d31c20d2e8),
  .INIT_RAM_0F(256'h42e68abc3f254d913b9a03a63841a5d135195868321e68d42f4e4b3f2ca6986a)) frequency_table(.CLK(clk),.CE(rom_issue),.OCE(1'b1),.RESET(rst),
  .AD({2'b0,rom_note,5'b0}),.DO(rom_data));

 always @(posedge clk)begin
  if(rst||start)begin age<=0;pitch_q<=0;lane_q<=0;request_valid<=0;steps<=0;tapers<=0;rom_valid<=0;upper_q<=0;rom_lane<=0;end
  else begin
   if(busy)age<=age+1'b1;
   request_valid<=busy&&age<128&&age[3:0]>=7&&age[3:0]<=10;
   if(busy&&age<128&&age[3:0]>=7&&age[3:0]<=10)begin pitch_q<=selected_pitch;lane_q<=next_lane;end
   rom_valid<=rom_issue;
   if(rom_issue)begin upper_q<=upper;rom_lane<=next_lane;end
   for(integer l=0;l<4;l++)begin
    if(request_valid&&lane_q==l)tapers[l*17+:17]<=taper;
    if(rom_valid&&rom_lane==l)begin
     if(upper_q)steps[l*64+32+:32]<=rom_data;
     else steps[l*64+:32]<=rom_data;
    end
   end
  end
 end
endmodule

// Each 16-clock group prepares lane L at offsets L..L+6. All four
// backends still launch together at16. Only combinational operators are shared.
module r28_shared_envelope_glide #(parameter integer SAMPLE_RATE_HZ=48000, PREPARED_RELEASE=0, EW=(SAMPLE_RATE_HZ>=128000?15:SAMPLE_RATE_HZ>=72000?14:13),EPW=37+4*EW)(
 // Release estimate for lanes 0/1 and for lanes 2/3 (a second engine two clocks later).
 input wire[6:0] prepared_release_q,prepared_release_alt,
 input wire[499:0] advance_requests,output wire[101:0] advance_response,
 input wire clk,rst,start,busy,input wire[4*(EPW+8)-1:0] envelope_requests,input wire[455:0] glide_requests,
 output wire[EPW-1:0] envelope_response,output wire[124:0] glide_response
);
 reg[3:0] step;
 always @(posedge clk)if(rst||start)step<=0;else if(busy)step<=step+1'b1;
 wire[1:0] envelope_lane=step[1:0]-2'd1,glide_lane=step[1:0]-2'd2;
 wire[EPW+7:0] e=envelope_requests[envelope_lane*(EPW+8)+:EPW+8];
 wire[2:0] envelope_timbre=e[EPW+7:EPW+5],drum_role=e[EPW+4:EPW+2];
 wire[113:0] g=glide_requests[glide_lane*114+:114];
 wire[2:0] state;wire[16:0] level,quotient;wire[EW-1:0] remaining,duration,remainder,error_acc;wire gate,retrigger;
 assign {state,level,quotient,remaining,duration,remainder,error_acc,gate,retrigger}=e[EPW+1:0];
 wire new_owner,up;wire[6:0] note,target;wire[3:0] code,stored_code;wire[22:0] pitch;
 wire[2:0] state_next;wire[16:0] level_next,quotient_next;
 wire[31:0] remaining_next,duration_next,remainder_next,error_next;
 voice_release_adsr_step #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),.PREPARED_RELEASE(PREPARED_RELEASE)) adsr(.prepared_release_q(envelope_lane[1]?prepared_release_alt:prepared_release_q),.release_code(code),.state(state),.level(level),.quotient(quotient),.remaining({{(32-EW){1'b0}},remaining}),.duration({{(32-EW){1'b0}},duration}),
  .remainder({{(32-EW){1'b0}},remainder}),.error_acc({{(32-EW){1'b0}},error_acc}),.gate(gate),.retrigger(retrigger),
  .state_next(state_next),.level_next(level_next),.quotient_next(quotient_next),.remaining_next(remaining_next),
  .duration_next(duration_next),.remainder_next(remainder_next),.error_next(error_next));
 wire[2:0] drum_state;wire[16:0] drum_level;
 voice_drum_envelope_step #(.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)) drum_envelope(.role(drum_role),.state(state),.level(level),.retrigger(retrigger),
  .state_next(drum_state),.level_next(drum_level));
 assign envelope_response=envelope_timbre==5?
  {drum_state,drum_level,17'd0,EW'(0),EW'(1),EW'(0),EW'(0)}:
  {state_next,level_next,quotient_next,remaining_next[EW-1:0],duration_next[EW-1:0],remainder_next[EW-1:0],error_next[EW-1:0]};
 // code is now release time; pitch changes are direct, with continuous phase.

 wire[16:0] rem,base,err;wire[15:0] fraction;
 assign {new_owner,note,code,pitch,target,rem,base,fraction,err,up,stored_code}=g;
 glide_pitch_prepare glide(.new_owner(new_owner),.note_target(note),.glide_code(4'd0),.current_pitch(pitch),.stored_target(target),
  .remaining(rem),.base_step(base),.remainder(fraction),.error_acc(err),.direction_up(up),.stored_code(stored_code),.prepared(glide_response));
 wire[1:0] advance_lane=step[1:0]-2'd3;
 r28_glide_pipeline advance(.clk(clk),.rst(rst),.prepared(advance_requests[advance_lane*125+:125]),.result(advance_response));

endmodule

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

// Lane L requests at offset5+L; the registered result is consumed at6+L.
// Per-oscillator LFO phase and timbre envelopes remain in independent RAM rows.
module r28_shared_timbre_lfo #(parameter integer SAMPLE_RATE_HZ=48000)(input wire clk,rst,start,busy,input wire[279:0] requests,output reg[81:0] response);
 reg[3:0] step;wire[1:0] lane=step[1:0]-2'd1;
 wire fresh;wire[2:0] timbre;wire[16:0] old_transient,old_body;wire[31:0] lfo;
 assign {fresh,timbre,old_transient,old_body,lfo}=requests[lane*70+:70];
 wire[16:0] transient_value=fresh?17'd65536:old_transient,body_value=fresh?17'd65536:old_body;
 wire[16:0] transient_delta=timbre==3?(SAMPLE_RATE_HZ==128000 ? (({2'b0,transient_value}+({2'b0,transient_value}<<1)+19'd8191)>>13) : SAMPLE_RATE_HZ==96000 ? ((transient_value+17'd2047)>>11) : SAMPLE_RATE_HZ==72000 ? (transient_value+17'd1535)/17'd1536 : ((transient_value+17'd1023)>>10)):(SAMPLE_RATE_HZ==128000 ? (({2'b0,transient_value}+({2'b0,transient_value}<<1)+19'd16383)>>14) : SAMPLE_RATE_HZ==96000 ? ((transient_value+17'd4095)>>12) : SAMPLE_RATE_HZ==72000 ? (transient_value+17'd3071)/17'd3072 : ((transient_value+17'd2047)>>11));
 wire[16:0] body_delta=(SAMPLE_RATE_HZ==128000 ? (({2'b0,body_value}+({2'b0,body_value}<<1)+19'd16383)>>14) : SAMPLE_RATE_HZ==96000 ? ((body_value+17'd4095)>>12) : SAMPLE_RATE_HZ==72000 ? (body_value+17'd3071)/17'd3072 : ((body_value+17'd2047)>>11));
 wire[16:0] drum_delta=(SAMPLE_RATE_HZ==128000 ? (({2'b0,transient_value}+({2'b0,transient_value}<<1)+19'd2047)>>11) : SAMPLE_RATE_HZ==96000 ? ((transient_value+17'd511)>>9) : SAMPLE_RATE_HZ==72000 ? (transient_value+17'd383)/17'd384 : ((transient_value+17'd255)>>8));
 wire[16:0] next_transient=(timbre==5)?(fresh?17'd65536:
  transient_value<=drum_delta?17'd0:transient_value-drum_delta):
  (fresh||(timbre!=1&&timbre!=3))?17'd65536:
  transient_value<=transient_delta?17'd0:transient_value-transient_delta;
 wire[16:0] next_body=(fresh||timbre!=3)?17'd65536:body_value<=body_delta?17'd0:body_value-body_delta;
 // Reuse each oscillator's 32-bit LFO state as its own drum noise state.
 // Xorshift32 advances once per audio sample without a multiplier or table.
 wire[31:0] noise1=lfo^(lfo<<13),noise2=noise1^(noise1>>17);
 wire[31:0] noise_next=fresh?32'h6d2b79f5:(noise2^(noise2<<5));
 wire signed[15:0] sine;sine_rom lfo_table(.address(lfo[31:24]),.sample(sine));
 always @(posedge clk)begin
  if(rst||start)begin step<=0;response<=0;end
  else begin
   if(busy)step<=step+1'b1;
   response<={(timbre==5?noise_next:32'(lfo+(SAMPLE_RATE_HZ==128000?32'd167772:SAMPLE_RATE_HZ==96000?32'd223696:SAMPLE_RATE_HZ==72000?32'd298262:32'd447392))),
    (timbre==5?$signed(noise_next[31:16]):sine),next_transient,next_body};
  end
 end
endmodule


module r40_pitch_prepare #(parameter integer SAMPLE_RATE_HZ=48000)(
 input wire clk,rst,start,busy,input wire[22:0] pitch,
 output reg[63:0] steps,output reg[16:0] taper_out
);
 reg[8:0] age;reg[22:0] pitch_q;reg request_valid;
 wire[22:0] selected_pitch=pitch;
 wire[6:0] selected_note=selected_pitch[22:16];
 wire rom_issue=busy&&age>=11&&age<=260&&(age[2:0]==3||age[2:0]==4);
 wire upper=age[2:0]==4;
 wire[6:0] rom_note=upper&&selected_note!=127?selected_note+1'b1:selected_note;
 wire[31:0] rom_data;reg rom_valid,upper_q;
 wire[16:0] taper=pitch_q<=23'd7077888 ? 17'd65536:
   pitch_q>=23'd7864320 ? 17'd0:(23'd7864320-pitch_q)/12;
 // Four lower-note requests at7..10, four upper requests at11..14.
 // Their one-cycle responses finish at15, before all four launches at16.
 pROM #(
  .BIT_WIDTH(32),
  .READ_MODE(1'b0),
  .RESET_MODE("SYNC"),
  .INIT_RAM_00(SAMPLE_RATE_HZ==128000 ? 256'h0006459d0005eb7f00059670000546280004fa600004b2da00046f5700042f9e : SAMPLE_RATE_HZ==96000 ? 256'h00085cd10007e4aa00077340000708350006a32b000643cd0005e9c9000594d3 : SAMPLE_RATE_HZ==72000 ? 256'h000b266c000a86380009ef01000960460008d98f00085a670007e26200077119 : 256'h0010b9a3000fc953000ee681000e1069000d4656000c879a000bd393000b29a6),
  .INIT_RAM_01(SAMPLE_RATE_HZ==128000 ? 256'h0009f4c1000965b40008deae00085f3d0007e6f20007756800070a3d0006a517 : SAMPLE_RATE_HZ==96000 ? 256'h000d4656000c879a000bd393000b29a6000a89430009f1e0000962fd0008dc1e : SAMPLE_RATE_HZ==72000 ? 256'h0011b31d0010b4ce000fc4c4000ee233000e0c59000d4280000c83fb000bd028 : 256'h001a8cac00190f340017a7260016534c001512860013e3c00012c5f90011b83c),
  .INIT_RAM_02(SAMPLE_RATE_HZ==128000 ? 256'h000fcde4000eead0000e147b000d4a2d000c8b3a000bd6ff000b2ce1000a8c4f : SAMPLE_RATE_HZ==96000 ? 256'h001512860013e3c00012c5f90011b83c0010b9a3000fc953000ee681000e1069 : SAMPLE_RATE_HZ==72000 ? 256'h001c18b2001a8500001907f70017a05000164cd900150c6f0013de010012c08d : 256'h002a250c0027c78100258bf20023707800217345001f92a7001dcd02001c20d3),
  .INIT_RAM_03(SAMPLE_RATE_HZ==128000 ? 256'h001916740017adfd001659c10015189e0013e9810012cb670011bd5c0010be79 : SAMPLE_RATE_HZ==96000 ? 256'h00217345001f92a7001dcd02001c20d3001a8cac00190f340017a7260016534c : SAMPLE_RATE_HZ==72000 ? 256'h002c99b2002a18de0027bc02002581190023663b0021699b001f8987001dc466 : 256'h0042e68b003f254e003b9a04003841a60035195800321e69002f4e4b002ca698),
  .INIT_RAM_04(SAMPLE_RATE_HZ==128000 ? 256'h0027d302002596cf00237ab800217cf2001f9bc9001dd5a1001c28f6001a945a : SAMPLE_RATE_HZ==96000 ? 256'h0035195800321e69002f4e4b002ca698002a250c0027c78100258bf200237078 : SAMPLE_RATE_HZ==72000 ? 256'h0046cc760042d336003f130f003b88cb0038316500350a0100320fee002f40a0 : 256'h006a32b100643cd2005e9c9600594d3100544a17004f8f01004b17e50046e0f0),
  .INIT_RAM_05(SAMPLE_RATE_HZ==128000 ? 256'h003f3791003bab41003851ec003528b400322ce8002f5bfa002cb383002a313c : SAMPLE_RATE_HZ==96000 ? 256'h00544a17004f8f01004b17e50046e0f00042e68b003f254e003b9a04003841a6 : SAMPLE_RATE_HZ==72000 ? 256'h007062ca006a140200641fdc005e814100593364005431bd004f7805004b0232 : 256'h00a8942e009f1e0300962fc9008dc1e10085cd15007e4a9b007734070070834c),
  .INIT_RAM_06(SAMPLE_RATE_HZ==128000 ? 256'h006459d0005eb7f40059670500546279004fa605004b2d9d0046f5710042f9e5 : SAMPLE_RATE_HZ==96000 ? 256'h0085cd15007e4a9b007734070070834c006a32b100643cd2005e9c9600594d31 : SAMPLE_RATE_HZ==72000 ? 256'h00b266c700a8637a009ef00a00960465008d98ec0085a66d007e261e00771196 : 256'h010b9a2b00fc953600ee680f00e1069700d4656200c879a300bd392d00b29a62),
  .INIT_RAM_07(SAMPLE_RATE_HZ==128000 ? 256'h009f4c0900965b3a008deae20085f3c9007e6f23007756820070a3d7006a5169 : SAMPLE_RATE_HZ==96000 ? 256'h00d4656200c879a300bd392d00b29a6200a8942e009f1e0300962fc9008dc1e1 : SAMPLE_RATE_HZ==72000 ? 256'h011b31d7010b4cda00fc4c3c00ee232d00e0c59300d4280400c83fb700bd0281 : 256'h01a8cac30190f347017a725a016534c30151285d013e3c06012c5f93011b83c2),
  .INIT_RAM_08(SAMPLE_RATE_HZ==128000 ? 256'h00fcde4600eead0400e147ae00d4a2d100c8b3a000bd6fe900b2ce0b00a8c4f1 : SAMPLE_RATE_HZ==96000 ? 256'h0151285d013e3c06012c5f93011b83c2010b9a2b00fc953600ee680f00e10697 : SAMPLE_RATE_HZ==72000 ? 256'h01c18b2601a8500801907f6e017a05020164cd8f0150c6f3013de013012c08ca : 256'h02a250ba027c780b0258bf26023707830217345601f92a6d01dcd01d01c20d2f),
  .INIT_RAM_09(SAMPLE_RATE_HZ==128000 ? 256'h01916740017adfd101659c16015189e3013e9812012cb675011bd5c3010be792 : SAMPLE_RATE_HZ==96000 ? 256'h0217345601f92a6d01dcd01d01c20d2f01a8cac30190f347017a725a016534c3 : SAMPLE_RATE_HZ==72000 ? 256'h02c99b1d02a18de6027bc02702581193023663af021699b401f8987801dc465a : 256'h042e68ac03f254d903b9a03a03841a5d035195860321e68d02f4e4b402ca6987),
  .INIT_RAM_0A(SAMPLE_RATE_HZ==128000 ? 256'h027d302502596cea0237ab870217cf2501f9bc8b01dd5a0801c28f5c01a945a2 : SAMPLE_RATE_HZ==96000 ? 256'h035195860321e68d02f4e4b402ca698702a250ba027c780b0258bf2602370783 : SAMPLE_RATE_HZ==72000 ? 256'h046cc75e042d336703f130f003b88cb30383164d0350a00f0320fedd02f40a04 : 256'h06a32b0d0643cd1b05e9c9680594d30d0544a17304f8f01704b17e4b046e0f07),
  .INIT_RAM_0B(SAMPLE_RATE_HZ==128000 ? 256'h03f3791703bab41103851eb803528b450322ce8102f5bfa302cb382c02a313c6 : SAMPLE_RATE_HZ==96000 ? 256'h0544a17304f8f01704b17e4b046e0f07042e68ac03f254d903b9a03a03841a5d : SAMPLE_RATE_HZ==72000 ? 256'h07062c9a06a1401e0641fdb905e814090593363a05431bcc04f7804e04b02327 : 256'h0a8942e709f1e02d0962fc9608dc1e0d085cd15707e4a9b207734075070834ba),
  .INIT_RAM_0C(SAMPLE_RATE_HZ==128000 ? 256'h06459d0205eb7f46059670580546278c04fa604a04b2d9d4046f570e042f9e4a : SAMPLE_RATE_HZ==96000 ? 256'h085cd15707e4a9b207734075070834ba06a32b0d0643cd1b05e9c9680594d30d : SAMPLE_RATE_HZ==72000 ? 256'h0b266c750a86379809ef009c0960464d08d98ebc085a66ce07e261e007711967 : 256'h10b9a2af0fc953640ee680e90e1069740d46561a0c879a350bd392d00b29a61a),
  .INIT_RAM_0D(SAMPLE_RATE_HZ==128000 ? 256'h09f4c0930965b3a808deae1c085f3c9407e6f22d07756822070a3d7106a5168a : SAMPLE_RATE_HZ==96000 ? 256'h0d46561a0c879a350bd392d00b29a61a0a8942e709f1e02d0962fc9608dc1e0d : SAMPLE_RATE_HZ==72000 ? 256'h11b31d7810b4cd9c0fc4c3c00ee232ce0e0c59340d42803c0c83fb730bd02812 : 256'h1a8cac34190f346a17a725a016534c35151285ce13e3c05a12c5f92c11b83c1a),
  .INIT_RAM_0E(SAMPLE_RATE_HZ==128000 ? 256'h0fcde45a0eead0440e147ae10d4a2d140c8b3a030bd6fe8b0b2ce0af0a8c4f17 : SAMPLE_RATE_HZ==96000 ? 256'h151285ce13e3c05a12c5f92c11b83c1a10b9a2af0fc953640ee680e90e106974 : SAMPLE_RATE_HZ==72000 ? 256'h1c18b2681a8500791907f6e617a05023164cd8e9150c6f3013de013712c08c9b : 256'h2a250b9c27c780b5258bf259237078352173455e1f92a6c81dcd01d31c20d2e8),
  .INIT_RAM_0F(SAMPLE_RATE_HZ==128000 ? 256'h1916740617adfd161659c15e15189e2e13e9812712cb675011bd5c3810be7928 : SAMPLE_RATE_HZ==96000 ? 256'h2173455e1f92a6c81dcd01d31c20d2e81a8cac34190f346a17a725a016534c35 : SAMPLE_RATE_HZ==72000 ? 256'h2c99b1d32a18de6127bc026f2581193623663af021699b381f8987801dc4659c : 256'h42e68abc3f254d913b9a03a63841a5d135195868321e68d42f4e4b3f2ca6986a)) frequency_table(.CLK(clk),.CE(rom_issue),.OCE(1'b1),.RESET(rst),
  .AD({2'b0,rom_note,5'b0}),.DO(rom_data));

 always @(posedge clk)begin
  if(rst||start)begin age<=0;pitch_q<=0;request_valid<=0;steps<=0;taper_out<=0;rom_valid<=0;upper_q<=0;end
  else begin
   if(busy)age<=age+1'b1;
   request_valid<=busy&&age>=11&&age<=259&&age[2:0]==3;
   if(busy&&age>=11&&age<=259&&age[2:0]==3)begin pitch_q<=selected_pitch;end
   rom_valid<=rom_issue;
   if(rom_issue)begin upper_q<=upper;end
   if(request_valid)taper_out<=taper;
   if(rom_valid)begin
    if(upper_q)steps[63:32]<=rom_data;else steps[31:0]<=rom_data;
   end
  end
 end
endmodule
module r40_stereo_sum #(parameter integer COMPLETION_LIMIT=400)(
 input wire clk,rst,sample_tick,
 input wire[3:0] completion_valid,completion_accept,
 input wire[11:0] completion_slot,input wire[71:0] completion_sample,
 input wire[35:0] completion_pan,
 output reg signed[31:0] mix_l_q8,mix_r_q8,output reg mix_valid,
 output reg protocol_error,deadline_error,output reg[8:0] last_complete_cycle
);
 // Four simultaneous results are consumed as two fixed pairs. Products
 // enter the accumulator at +3/+4; final output remains at +5 clocks.
 reg signed[17:0] samples[0:3];reg[8:0] pans[0:3];
 reg[1:0] phase;
 reg signed[17:0] operand[0:1];reg[8:0] coefficient[0:1];
 reg[1:0] right_unity;
 reg op_valid,op_second,product_valid,product_second,last_group,mix_pending;
 reg signed[27:0] product_l[0:1],product_r[0:1];
 wire signed[27:0] variable_product[0:1],unity_product[0:1];
 reg signed[31:0] sum_l,sum_r;
 reg busy;reg[8:0] age;reg[7:0] seen[0:3];
 wire [1:0] pair_base=phase==2?2'd2:2'd0;
 for(genvar k=0;k<2;k++)begin: multiply
  assign variable_product[k]=$signed(operand[k])*$signed({1'b0,coefficient[k]});
  assign unity_product[k]=$signed({{10{operand[k][17]}},operand[k]})<<<8;
 end
 always @(posedge clk)begin
  if(rst)begin
   phase<=0;right_unity<=0;op_valid<=0;op_second<=0;product_valid<=0;product_second<=0;
   last_group<=0;mix_pending<=0;sum_l<=0;sum_r<=0;busy<=0;age<=0;
   mix_l_q8<=0;mix_r_q8<=0;mix_valid<=0;protocol_error<=0;deadline_error<=0;last_complete_cycle<=0;
   for(integer k=0;k<4;k++)begin samples[k]<=0;pans[k]<=128;seen[k]<=0;end
   for(integer k=0;k<2;k++)begin operand[k]<=0;coefficient[k]<=256;product_l[k]<=0;product_r[k]<=0;end
  end else begin
   op_valid<=phase!=0;op_second<=phase==2;
   product_valid<=op_valid;product_second<=op_second;
   mix_pending<=product_valid&&product_second&&last_group;mix_valid<=mix_pending;
   if(busy)begin age<=age+1'b1;if(age>=399)deadline_error<=1;end
   if(sample_tick)begin
    if(busy||phase!=0||op_valid||product_valid||completion_valid!=0)deadline_error<=1;
    busy<=1;age<=0;sum_l<=0;sum_r<=0;
    for(integer k=0;k<4;k++)seen[k]<=0;
   end
   if(completion_valid!=0)begin
    if((completion_valid&(completion_valid-1'b1))!=0||phase!=0)protocol_error<=1;
    if(completion_valid[3])begin phase<=1;last_group<=completion_slot[11:9]==7;end
    for(integer k=0;k<4;k++)if(completion_valid[k])begin
     if(!busy||seen[k][completion_slot[k*3+:3]])protocol_error<=1;
     if(completion_slot[k*3+:3]==7&&seen[k]!=8'h7f)protocol_error<=1;

     seen[k][completion_slot[k*3+:3]]<=1;
     if(completion_pan[k*9+:9]>256)protocol_error<=1;
     samples[k]<=completion_accept[k]?$signed(completion_sample[k*18+:18]):18'sd0;
     pans[k]<=completion_pan[k*9+:9];
    end
   end
   if(phase!=0)begin
    phase<=phase==1?2:0;
    
     operand[0]<=samples[pair_base+0];right_unity[0]<=pans[pair_base+0]>128;
     coefficient[0]<=pans[pair_base+0]>128?((9'd256-pans[pair_base+0])<<1):(pans[pair_base+0]<<1);
    
     operand[1]<=samples[pair_base+1];right_unity[1]<=pans[pair_base+1]>128;
     coefficient[1]<=pans[pair_base+1]>128?((9'd256-pans[pair_base+1])<<1):(pans[pair_base+1]<<1);
    
   end
   if(op_valid)for(integer k=0;k<2;k++)begin
    product_l[k]<=right_unity[k]?variable_product[k]:unity_product[k];
    product_r[k]<=right_unity[k]?unity_product[k]:variable_product[k];
   end
   if(product_valid)begin
    sum_l<=sum_l+{{4{product_l[0][27]}},product_l[0]}+{{4{product_l[1][27]}},product_l[1]};
    sum_r<=sum_r+{{4{product_r[0][27]}},product_r[0]}+{{4{product_r[1][27]}},product_r[1]};
   end
   if(mix_pending)begin
    mix_l_q8<=sum_l;mix_r_q8<=sum_r;busy<=0;last_complete_cycle<=age+1'b1;
    if(!busy||age>=COMPLETION_LIMIT)deadline_error<=1;
   end
  end
 end
endmodule

// R46: one II8 arithmetic backend; each voice keeps its independent context.
// Lifetimes and same-edge read-before-write cases: BACKEND_BOUNDARY_PROOF.txt.
module r46_ii8_backend #(parameter DERIVE_FM=1,parameter integer INITIAL_CYCLE=0,parameter integer SHARE_FX=0)(
 input wire fx_mac_use,input wire signed[35:0] fx_mac_a,input wire signed[17:0] fx_mac_b,
 output wire signed[53:0] fx_mac_q,
 input wire[31:0] prepared_lo,prepared_hi,input wire[16:0] prepared_taper,
 input wire clk,rst,in_valid,output wire in_ready,
 input wire[4:0] in_tag,input wire[193:0] job_in,
 output reg out_valid,output reg[4:0] out_tag,
 output reg signed[17:0] out_sample,output reg[31:0] out_phase
);
 reg[5:0] cycle;
 wire[2:0] step=cycle[2:0],j0=cycle[5:3];
 wire[2:0] j1=j0-3'd1,j2=j0-3'd2,j3=j0-3'd3,j4=j0-3'd4;
 reg[7:0] occupied;reg[4:0] tag[0:7];
 reg[32:0] input_phase[0:1];reg[48:0] early_pitch;reg[33:0] early_timbre;
 reg[53:0] late_job[0:3];reg[16:0] supplied_index[0:1];
 reg[31:0] low_step,delta_step,base_step,adjusted,phase[0:3],carrier_phase;
 reg signed[17:0] modulation;
 reg[16:0] taper,raw_index,fm_index,amplitude[0:1],w1[0:1],w2[0:1],w3[0:1];
 reg signed[15:0] h1[0:1],h2,h3,carrier,fm_sine;
 reg signed[53:0] term1,term3,pressure_product;
 reg signed[35:0] term2,env_product;
 reg signed[35:0] wa,wa_q;reg signed[17:0] wb,wb_q,na,nb,na_q,nb_q;
 reg signed[53:0] wp,wq;reg signed[35:0] np,nq;
 reg[7:0] sine_address;wire signed[15:0] sine_value;
 wire[31:0] phase1=phase[j1[1:0]],phase2=phase[j2[1:0]];
 wire[31:0] harmonic2_phase=phase1<<1;
 wire[31:0] harmonic3_phase=phase2+(phase2<<1);
 always @*begin
  case(step)
   5:sine_address=late_job[j1[1:0]][2:0]==1 ? harmonic2_phase[31:24]:phase1[31:24];
   6:sine_address=phase1[31:24];
   7:sine_address=harmonic2_phase[31:24];
   0:sine_address=harmonic3_phase[31:24];
   2:sine_address=carrier_phase[31:24];
   default:sine_address=0;
  endcase
 end
 sine_rom shared_sine(.address(sine_address),.sample(sine_value));
 assign in_ready=!rst&&step==0;
 function signed [17:0] round_mod(input signed [51:0] value);
  round_mod=(value>>>31)+((value[30]&&(!value[51]||(|value[29:0])))?52'sd1:52'sd0);
 endfunction
 function signed [34:0] round_delta(input signed [50:0] value);
  round_delta=(value>>>16)+((value[15]&&(!value[50]||(|value[14:0])))?51'sd1:51'sd0);
 endfunction
 function signed [17:0] round_audio(input signed [53:0] value);
  reg signed [22:0] shifted;
  begin
   shifted=(value>>>32)+((value[31]&&(!value[53]||(|value[30:0])))?54'sd1:54'sd0);
   if(shifted>23'sd131071)round_audio=18'sh1ffff;
   else if(shifted < -23'sd131072)round_audio=18'h20000;
   else round_audio=shifted[17:0];
  end
 endfunction

 wire signed[17:0] carrier_wide={{2{carrier[15]}},carrier};
 wire signed[17:0] shaped=carrier>16'sd16384 ?
  18'sd16384+((carrier_wide-18'sd16384)>>>1):
  carrier< -16'sd16384 ? -18'sd16384+((carrier_wide+18'sd16384)>>>1):carrier_wide;
 wire signed[35:0] shape_delta=$signed(shaped)-$signed(carrier_wide);
 wire signed[63:0] harmonic_total=$signed(term1)+$signed(term2)+$signed(term3);
 wire signed[63:0] shaped_total=$signed(carrier_wide)+($signed(term1)>>>16);
 wire[48:0] interpolated={17'd0,low_step}+(({1'b0,wq[47:0]}+49'd32768)>>16);
 wire signed[35:0] adjusted_wide=$signed({4'b0,base_step})+$signed(round_delta(wq[50:0]));
 wire signed[17:0] drum_noise={{2{late_job[j3[1:0]][16]}},late_job[j3[1:0]][16:3],2'b0};
 wire signed[17:0] drum_sine={{2{h1[j3[0]][15]}},h1[j3[0]]};
 reg signed[17:0] drum_wave;
 always @*begin
  case(late_job[j3[1:0]][19:17])
   0:drum_wave=drum_sine;
   1:drum_wave=(drum_noise>>>1)+(drum_sine>>>2);
   2,3:drum_wave=drum_noise>>>1;
   4,5:drum_wave=drum_sine+(drum_noise>>>4);
   6:drum_wave=drum_noise;
   7:drum_wave=(drum_noise>>>1)+(drum_sine>>>3);
   default:drum_wave=0;
  endcase
 end
 reg signed[17:0] wave_value;
 always @*begin
  case(late_job[j3[1:0]][2:0])
   1:wave_value=$signed(term1)>>>16;
   2,3:wave_value=(harmonic_total+64'sd16384)>>>15;
   4:wave_value=shaped_total;
   5:wave_value=drum_wave;
   default:wave_value=h1[j3[0]];
  endcase
 end
 always @*begin
  wa=0;wb=0;na=0;nb=0;
  case(step)
   1:begin wa=$signed({4'd0,delta_step});wb=$signed({2'd0,early_pitch[48:33]});end
   4:begin wa=$signed(nq[33:0]);wb=18'sd655;end
   0:begin wa=$signed({4'd0,base_step});wb=modulation;end
   3:begin
    case(late_job[j2[1:0]][2:0])
     1:begin wa=$signed(carrier);wb=$signed({1'b0,amplitude[j2[0]]});end
     2,3:begin wa=$signed(h1[j2[0]]);wb=$signed({1'b0,w1[j2[0]]});end
     4:begin wa=shape_delta;wb=$signed({1'b0,late_job[j2[1:0]][19:3]});end
     default:begin end
    endcase
   end
   5:begin wa=$signed(h3);wb=$signed({1'b0,w3[j2[0]]});end
   2:begin wa=$signed(wave_value);wb=$signed({1'b0,late_job[j3[1:0]][53:37]});end
   7:begin wa=$signed(env_product);wb=$signed({1'b0,late_job[j3[1:0]][36:20]});end
   default:begin end
  endcase
  case(step)
   1:begin na=$signed(early_pitch[32:17]);nb=$signed({1'b0,early_pitch[16:0]});end
   2:begin
    na=$signed({1'b0,late_job[j0[1:0]][2:0]==1 ? early_timbre[33:17]:early_timbre[16:0]});
    nb=late_job[j0[1:0]][2:0]==1 ? 18'sd20000:18'sd24000;
   end
   3:begin na=$signed({1'b0,early_timbre[33:17]});nb=late_job[j0[1:0]][2:0]==1 ? 18'sd52429:18'sd5000;end
   5:begin na=$signed({1'b0,early_timbre[33:17]});nb=18'sd2500;end
   7:begin na=$signed({1'b0,raw_index});nb=$signed({1'b0,taper});end
   6:begin na=fm_sine;nb=$signed({1'b0,DERIVE_FM ? fm_index:supplied_index[j1[0]]});end
   4:begin na=$signed(h2);nb=$signed({1'b0,w2[j2[0]]});end
   default:begin end
  endcase
 end
 always @(posedge clk)begin
  if(rst)begin wa_q<=0;wb_q<=0;na_q<=0;nb_q<=0;wp<=0;wq<=0;np<=0;nq<=0;end
  else begin
   wa_q<=(SHARE_FX&&fx_mac_use)?fx_mac_a:wa;wb_q<=(SHARE_FX&&fx_mac_use)?fx_mac_b:wb;na_q<=na;nb_q<=nb;
   wp<=wa_q*wb_q;wq<=wp;np<=na_q*nb_q;nq<=np;
  end
 end
 always @(posedge clk)begin
  if(rst)begin cycle<=6'(INITIAL_CYCLE);occupied<=0;out_valid<=0;out_tag<=0;out_sample<=0;out_phase<=0;end
  else begin
   cycle<=cycle+1'b1;out_valid<=0;
   case(step)
    0:begin
     occupied[j0]<=in_valid;h3<=sine_value;term3<=wq;
     w3[j1[0]]<=base_step<32'd715827882 ? (late_job[j1[1:0]][2:0]==2 ? 17'd4000:nq[32:16]):17'd0;
     if(in_valid)begin
      input_phase[j0[0]]<={job_in[193:162],job_in[161]};
      early_pitch<=job_in[153:105];early_timbre<=job_in[70:37];
      late_job[j0[1:0]]<={job_in[104:71],job_in[19:0]};tag[j0]<=in_tag;
      low_step<=prepared_lo;delta_step<=prepared_hi-prepared_lo;taper<=prepared_taper;
      if(DERIVE_FM)late_job[j0[1:0]][19:3]<=job_in[2:0]==5?job_in[19:3]:prepared_taper;
      else supplied_index[j0[0]]<=job_in[36:20];
     end
    end
    1:carrier_phase<=phase[j2[1:0]]+(nq[31:0]<<1);
    2:begin if(DERIVE_FM)fm_index<=nq[32:16];carrier<=sine_value;pressure_product<=wq;end
    3:begin
     adjusted<=adjusted_wide[31:0];
     if(occupied[j4])begin out_valid<=1;out_tag<=tag[j4];out_sample<=round_audio(pressure_product);out_phase<=phase[j4[1:0]];end
    end
    4:begin base_step<=interpolated[31:0];phase[j1[1:0]]<=input_phase[j1[0]][0] ? 32'd0:input_phase[j1[0]][32:1]+adjusted;end
    5:begin
     raw_index<=late_job[j0[1:0]][2:0]==1 ? nq[31:16]:late_job[j0[1:0]][2:0]==4 ? 17'd10000:17'd0;
     w1[j0[0]]<=late_job[j0[1:0]][2:0]==2 ? 17'd18000:17'd1000+nq[32:16];
     fm_sine<=sine_value;env_product<=wq[35:0];
    end
    6:begin
     amplitude[j0[0]]<=17'd13107+nq[32:16];
     w2[j0[0]]<=base_step<32'h40000000 ? (late_job[j0[1:0]][2:0]==2 ? 17'd10000:nq[32:16]):17'd0;
     h1[j1[0]]<=sine_value;term1<=wq;
    end
    7:begin modulation<=round_mod(wq[51:0]);h2<=sine_value;term2<=nq;end
   endcase
  end
 end
 assign fx_mac_q=wq;
 // synthesis translate_off
 always @(posedge clk)if(!rst&&in_valid&&!in_ready)$fatal(1,"R46_UNSCHEDULED_INPUT");
 reg[5:0] live_count;
 always @(posedge clk)begin
  if(rst)live_count<=0;
  else begin
   if(in_valid)live_count<=35;else if(live_count!=0)live_count<=live_count-1'b1;
   if(SHARE_FX&&fx_mac_use&&(live_count!=0||in_valid))$fatal(1,"R46_FX_VOICE_OVERLAP");
  end
 end
 // synthesis translate_on
endmodule

// Full-width combinational equality. Each LUT4 compares exactly two bits;
// all bits participate. Equality and inequality consumers share one tree.
module r54_full_equal #(parameter integer WIDTH=32)(
 input wire [WIDTH-1:0] a,b,output wire equal);
 localparam integer PAIRS=(WIDTH+1)/2;
 wire [2*PAIRS-1:0] pa={{(2*PAIRS-WIDTH){1'b0}},a};
 wire [2*PAIRS-1:0] pb={{(2*PAIRS-WIDTH){1'b0}},b};
 wire [PAIRS-1:0] pairs;
 for(genvar g=0;g<PAIRS;g=g+1)begin: compare_pairs
  LUT4 #(.INIT(16'h9009)) eq_pair(.I0(pa[2*g]),.I1(pb[2*g]),.I2(pa[2*g+1]),.I3(pb[2*g+1]),.F(pairs[g]));
 end
 assign equal=&pairs;
endmodule

// test_linear: every job's step is the exact FFT-bin multiple (2*note+65)*2^20,
// i.e. (2*note+65)*31.25 Hz at 128 kHz, so each test oscillator lands on its
// own 4096-point bin, two bins from its neighbours.
// ROM_ROLE 0: own pROM. 1: owner, also serves alt_note on alt_issue cycles.
// 2: borrower, reads the owner's pROM output (issues two clocks after it).
module osc_ii4_pitch_prepare #(parameter integer SAMPLE_RATE_HZ=48000,ISSUE_END=192,ROM_ROLE=0)(
 input wire alt_issue,input wire[6:0] alt_note,input wire[31:0] rom_data_in,
 output wire issue_out,output wire[6:0] note_out,output wire[31:0] rom_data_out,
 input wire clk,rst,start,busy,test_linear,input wire[22:0] pitch,
 output wire[63:0] steps,output reg[16:0] taper_out
);
 reg[63:0] table_steps;reg[31:0] exact_step;
 assign steps=test_linear?{exact_step,exact_step}:table_steps;
 reg[8:0] age;reg[22:0] pitch_q;reg request_valid;
 wire[22:0] selected_pitch=pitch;
 wire[6:0] selected_note=selected_pitch[22:16];
 wire rom_issue=busy&&age>=9&&age<=ISSUE_END+6&&(age[1:0]==1||age[1:0]==2);
 wire upper=age[1:0]==2;
 wire[6:0] rom_note=upper&&selected_note!=127?selected_note+1'b1:selected_note;
 wire[31:0] rom_q;wire[31:0] rom_data=ROM_ROLE==2?rom_data_in:rom_q;reg rom_valid,upper_q;
 assign issue_out=rom_issue;assign note_out=rom_note;assign rom_data_out=rom_q;
 wire[16:0] taper=pitch_q<=23'd7077888 ? 17'd65536:
   pitch_q>=23'd7864320 ? 17'd0:(23'd7864320-pitch_q)/12;
 // Four lower-note requests at7..10, four upper requests at11..14.
 // Their one-cycle responses finish at15, before all four launches at16.
 pROM #(
  .BIT_WIDTH(32),
  .READ_MODE(1'b0),
  .RESET_MODE("SYNC"),
  .INIT_RAM_00(SAMPLE_RATE_HZ==128000 ? 256'h0006459d0005eb7f00059670000546280004fa600004b2da00046f5700042f9e : SAMPLE_RATE_HZ==96000 ? 256'h00085cd10007e4aa00077340000708350006a32b000643cd0005e9c9000594d3 : SAMPLE_RATE_HZ==72000 ? 256'h000b266c000a86380009ef01000960460008d98f00085a670007e26200077119 : 256'h0010b9a3000fc953000ee681000e1069000d4656000c879a000bd393000b29a6),
  .INIT_RAM_01(SAMPLE_RATE_HZ==128000 ? 256'h0009f4c1000965b40008deae00085f3d0007e6f20007756800070a3d0006a517 : SAMPLE_RATE_HZ==96000 ? 256'h000d4656000c879a000bd393000b29a6000a89430009f1e0000962fd0008dc1e : SAMPLE_RATE_HZ==72000 ? 256'h0011b31d0010b4ce000fc4c4000ee233000e0c59000d4280000c83fb000bd028 : 256'h001a8cac00190f340017a7260016534c001512860013e3c00012c5f90011b83c),
  .INIT_RAM_02(SAMPLE_RATE_HZ==128000 ? 256'h000fcde4000eead0000e147b000d4a2d000c8b3a000bd6ff000b2ce1000a8c4f : SAMPLE_RATE_HZ==96000 ? 256'h001512860013e3c00012c5f90011b83c0010b9a3000fc953000ee681000e1069 : SAMPLE_RATE_HZ==72000 ? 256'h001c18b2001a8500001907f70017a05000164cd900150c6f0013de010012c08d : 256'h002a250c0027c78100258bf20023707800217345001f92a7001dcd02001c20d3),
  .INIT_RAM_03(SAMPLE_RATE_HZ==128000 ? 256'h001916740017adfd001659c10015189e0013e9810012cb670011bd5c0010be79 : SAMPLE_RATE_HZ==96000 ? 256'h00217345001f92a7001dcd02001c20d3001a8cac00190f340017a7260016534c : SAMPLE_RATE_HZ==72000 ? 256'h002c99b2002a18de0027bc02002581190023663b0021699b001f8987001dc466 : 256'h0042e68b003f254e003b9a04003841a60035195800321e69002f4e4b002ca698),
  .INIT_RAM_04(SAMPLE_RATE_HZ==128000 ? 256'h0027d302002596cf00237ab800217cf2001f9bc9001dd5a1001c28f6001a945a : SAMPLE_RATE_HZ==96000 ? 256'h0035195800321e69002f4e4b002ca698002a250c0027c78100258bf200237078 : SAMPLE_RATE_HZ==72000 ? 256'h0046cc760042d336003f130f003b88cb0038316500350a0100320fee002f40a0 : 256'h006a32b100643cd2005e9c9600594d3100544a17004f8f01004b17e50046e0f0),
  .INIT_RAM_05(SAMPLE_RATE_HZ==128000 ? 256'h003f3791003bab41003851ec003528b400322ce8002f5bfa002cb383002a313c : SAMPLE_RATE_HZ==96000 ? 256'h00544a17004f8f01004b17e50046e0f00042e68b003f254e003b9a04003841a6 : SAMPLE_RATE_HZ==72000 ? 256'h007062ca006a140200641fdc005e814100593364005431bd004f7805004b0232 : 256'h00a8942e009f1e0300962fc9008dc1e10085cd15007e4a9b007734070070834c),
  .INIT_RAM_06(SAMPLE_RATE_HZ==128000 ? 256'h006459d0005eb7f40059670500546279004fa605004b2d9d0046f5710042f9e5 : SAMPLE_RATE_HZ==96000 ? 256'h0085cd15007e4a9b007734070070834c006a32b100643cd2005e9c9600594d31 : SAMPLE_RATE_HZ==72000 ? 256'h00b266c700a8637a009ef00a00960465008d98ec0085a66d007e261e00771196 : 256'h010b9a2b00fc953600ee680f00e1069700d4656200c879a300bd392d00b29a62),
  .INIT_RAM_07(SAMPLE_RATE_HZ==128000 ? 256'h009f4c0900965b3a008deae20085f3c9007e6f23007756820070a3d7006a5169 : SAMPLE_RATE_HZ==96000 ? 256'h00d4656200c879a300bd392d00b29a6200a8942e009f1e0300962fc9008dc1e1 : SAMPLE_RATE_HZ==72000 ? 256'h011b31d7010b4cda00fc4c3c00ee232d00e0c59300d4280400c83fb700bd0281 : 256'h01a8cac30190f347017a725a016534c30151285d013e3c06012c5f93011b83c2),
  .INIT_RAM_08(SAMPLE_RATE_HZ==128000 ? 256'h00fcde4600eead0400e147ae00d4a2d100c8b3a000bd6fe900b2ce0b00a8c4f1 : SAMPLE_RATE_HZ==96000 ? 256'h0151285d013e3c06012c5f93011b83c2010b9a2b00fc953600ee680f00e10697 : SAMPLE_RATE_HZ==72000 ? 256'h01c18b2601a8500801907f6e017a05020164cd8f0150c6f3013de013012c08ca : 256'h02a250ba027c780b0258bf26023707830217345601f92a6d01dcd01d01c20d2f),
  .INIT_RAM_09(SAMPLE_RATE_HZ==128000 ? 256'h01916740017adfd101659c16015189e3013e9812012cb675011bd5c3010be792 : SAMPLE_RATE_HZ==96000 ? 256'h0217345601f92a6d01dcd01d01c20d2f01a8cac30190f347017a725a016534c3 : SAMPLE_RATE_HZ==72000 ? 256'h02c99b1d02a18de6027bc02702581193023663af021699b401f8987801dc465a : 256'h042e68ac03f254d903b9a03a03841a5d035195860321e68d02f4e4b402ca6987),
  .INIT_RAM_0A(SAMPLE_RATE_HZ==128000 ? 256'h027d302502596cea0237ab870217cf2501f9bc8b01dd5a0801c28f5c01a945a2 : SAMPLE_RATE_HZ==96000 ? 256'h035195860321e68d02f4e4b402ca698702a250ba027c780b0258bf2602370783 : SAMPLE_RATE_HZ==72000 ? 256'h046cc75e042d336703f130f003b88cb30383164d0350a00f0320fedd02f40a04 : 256'h06a32b0d0643cd1b05e9c9680594d30d0544a17304f8f01704b17e4b046e0f07),
  .INIT_RAM_0B(SAMPLE_RATE_HZ==128000 ? 256'h03f3791703bab41103851eb803528b450322ce8102f5bfa302cb382c02a313c6 : SAMPLE_RATE_HZ==96000 ? 256'h0544a17304f8f01704b17e4b046e0f07042e68ac03f254d903b9a03a03841a5d : SAMPLE_RATE_HZ==72000 ? 256'h07062c9a06a1401e0641fdb905e814090593363a05431bcc04f7804e04b02327 : 256'h0a8942e709f1e02d0962fc9608dc1e0d085cd15707e4a9b207734075070834ba),
  .INIT_RAM_0C(SAMPLE_RATE_HZ==128000 ? 256'h06459d0205eb7f46059670580546278c04fa604a04b2d9d4046f570e042f9e4a : SAMPLE_RATE_HZ==96000 ? 256'h085cd15707e4a9b207734075070834ba06a32b0d0643cd1b05e9c9680594d30d : SAMPLE_RATE_HZ==72000 ? 256'h0b266c750a86379809ef009c0960464d08d98ebc085a66ce07e261e007711967 : 256'h10b9a2af0fc953640ee680e90e1069740d46561a0c879a350bd392d00b29a61a),
  .INIT_RAM_0D(SAMPLE_RATE_HZ==128000 ? 256'h09f4c0930965b3a808deae1c085f3c9407e6f22d07756822070a3d7106a5168a : SAMPLE_RATE_HZ==96000 ? 256'h0d46561a0c879a350bd392d00b29a61a0a8942e709f1e02d0962fc9608dc1e0d : SAMPLE_RATE_HZ==72000 ? 256'h11b31d7810b4cd9c0fc4c3c00ee232ce0e0c59340d42803c0c83fb730bd02812 : 256'h1a8cac34190f346a17a725a016534c35151285ce13e3c05a12c5f92c11b83c1a),
  .INIT_RAM_0E(SAMPLE_RATE_HZ==128000 ? 256'h0fcde45a0eead0440e147ae10d4a2d140c8b3a030bd6fe8b0b2ce0af0a8c4f17 : SAMPLE_RATE_HZ==96000 ? 256'h151285ce13e3c05a12c5f92c11b83c1a10b9a2af0fc953640ee680e90e106974 : SAMPLE_RATE_HZ==72000 ? 256'h1c18b2681a8500791907f6e617a05023164cd8e9150c6f3013de013712c08c9b : 256'h2a250b9c27c780b5258bf259237078352173455e1f92a6c81dcd01d31c20d2e8),
  .INIT_RAM_0F(SAMPLE_RATE_HZ==128000 ? 256'h1916740617adfd161659c15e15189e2e13e9812712cb675011bd5c3810be7928 : SAMPLE_RATE_HZ==96000 ? 256'h2173455e1f92a6c81dcd01d31c20d2e81a8cac34190f346a17a725a016534c35 : SAMPLE_RATE_HZ==72000 ? 256'h2c99b1d32a18de6127bc026f2581193623663af021699b381f8987801dc4659c : 256'h42e68abc3f254d913b9a03a63841a5d135195868321e68d42f4e4b3f2ca6986a)) frequency_table(.CLK(clk),.CE(rom_issue),.OCE(1'b1),.RESET(rst),
  .AD({2'b0,(ROM_ROLE==1&&alt_issue)?alt_note:rom_note,5'b0}),.DO(rom_q));

 always @(posedge clk)begin
  if(rst||start)begin age<=0;pitch_q<=0;request_valid<=0;table_steps<=0;exact_step<=0;taper_out<=0;rom_valid<=0;upper_q<=0;end
  else begin
   if(busy)age<=age+1'b1;
   request_valid<=busy&&age>=9&&age<=ISSUE_END+5&&age[1:0]==1;
   if(busy&&age>=9&&age<=ISSUE_END+5&&age[1:0]==1)begin pitch_q<=selected_pitch;end
   rom_valid<=rom_issue;
   if(rom_issue)begin upper_q<=upper;end
   if(request_valid)taper_out<=taper;
   if(rom_valid)begin
    if(upper_q)table_steps[63:32]<=rom_data;else begin table_steps[31:0]<=rom_data;exact_step<={3'd0,{1'b0,pitch_q[22:16],1'b0}+9'd65,20'd0};end
   end
  end
 end
endmodule

module osc48_stereo_sum #(parameter integer COMPLETION_LIMIT=400)(
 input wire clk,rst,sample_tick,
 input wire[5:0] completion_valid,completion_accept,
 input wire[17:0] completion_slot,input wire[107:0] completion_sample,
 input wire[53:0] completion_pan,
 output reg signed[31:0] mix_l_q8,mix_r_q8,output reg mix_valid,
 output reg protocol_error,deadline_error,output reg[8:0] last_complete_cycle
);
 // Four simultaneous results are consumed as two fixed pairs. Products
 // enter the accumulator at +3/+4; final output remains at +5 clocks.
 reg signed[17:0] samples[0:5];reg[8:0] pans[0:5];
 reg[1:0] phase;
 reg signed[17:0] operand[0:1];reg[8:0] coefficient[0:1];
 reg[1:0] right_unity;
 reg op_valid,op_second,product_valid,product_second,last_group,mix_pending;
 reg signed[27:0] product_l[0:1],product_r[0:1];
 wire signed[27:0] variable_product[0:1],unity_product[0:1];
 reg signed[31:0] sum_l,sum_r;
 reg busy;reg[8:0] age;reg[7:0] seen[0:5];
 wire [2:0] pair_base=phase==3?3'd4:phase==2?3'd2:3'd0;
 for(genvar k=0;k<2;k++)begin: multiply
  assign variable_product[k]=$signed(operand[k])*$signed({1'b0,coefficient[k]});
  assign unity_product[k]=$signed({{10{operand[k][17]}},operand[k]})<<<8;
 end
 always @(posedge clk)begin
  if(rst)begin
   phase<=0;right_unity<=0;op_valid<=0;op_second<=0;product_valid<=0;product_second<=0;
   last_group<=0;mix_pending<=0;sum_l<=0;sum_r<=0;busy<=0;age<=0;
   mix_l_q8<=0;mix_r_q8<=0;mix_valid<=0;protocol_error<=0;deadline_error<=0;last_complete_cycle<=0;
   for(integer k=0;k<6;k++)begin samples[k]<=0;pans[k]<=128;seen[k]<=0;end
   for(integer k=0;k<2;k++)begin operand[k]<=0;coefficient[k]<=256;product_l[k]<=0;product_r[k]<=0;end
  end else begin
   op_valid<=phase!=0;op_second<=phase==3;
   product_valid<=op_valid;product_second<=op_second;
   mix_pending<=product_valid&&product_second&&last_group;mix_valid<=mix_pending;
   if(busy)begin age<=age+1'b1;if(age>=399)deadline_error<=1;end
   if(sample_tick)begin
    if(busy||phase!=0||op_valid||product_valid||completion_valid!=0)deadline_error<=1;
    busy<=1;age<=0;sum_l<=0;sum_r<=0;
    for(integer k=0;k<6;k++)seen[k]<=0;
   end
   if(completion_valid!=0)begin
    if((completion_valid&(completion_valid-1'b1))!=0||phase!=0)protocol_error<=1;
    if(completion_valid[5])begin phase<=1;last_group<=completion_slot[17:15]==7;end
    for(integer k=0;k<6;k++)if(completion_valid[k])begin
     if(!busy||seen[k][completion_slot[k*3+:3]])protocol_error<=1;
     if(completion_slot[k*3+:3]==7&&seen[k]!=8'h7f)protocol_error<=1;

     seen[k][completion_slot[k*3+:3]]<=1;
     if(completion_pan[k*9+:9]>256)protocol_error<=1;
     samples[k]<=completion_accept[k]?$signed(completion_sample[k*18+:18]):18'sd0;
     pans[k]<=completion_pan[k*9+:9];
    end
   end
   if(phase!=0)begin
    phase<=phase==3?0:phase+1'b1;
    
     operand[0]<=samples[pair_base+0];right_unity[0]<=pans[pair_base+0]>128;
     coefficient[0]<=pans[pair_base+0]>128?((9'd256-pans[pair_base+0])<<1):(pans[pair_base+0]<<1);
    
     operand[1]<=samples[pair_base+1];right_unity[1]<=pans[pair_base+1]>128;
     coefficient[1]<=pans[pair_base+1]>128?((9'd256-pans[pair_base+1])<<1):(pans[pair_base+1]<<1);
    
   end
   if(op_valid)for(integer k=0;k<2;k++)begin
    product_l[k]<=right_unity[k]?variable_product[k]:unity_product[k];
    product_r[k]<=right_unity[k]?unity_product[k]:variable_product[k];
   end
   if(product_valid)begin
    sum_l<=sum_l+{{4{product_l[0][27]}},product_l[0]}+{{4{product_l[1][27]}},product_l[1]};
    sum_r<=sum_r+{{4{product_r[0][27]}},product_r[0]}+{{4{product_r[1][27]}},product_r[1]};
   end
   if(mix_pending)begin
    mix_l_q8<=sum_l;mix_r_q8<=sum_r;busy<=0;last_complete_cycle<=age+1'b1;
    if(!busy||age>=COMPLETION_LIMIT)deadline_error<=1;
   end
  end
 end
endmodule

// One completion per cycle at most; each accepted sample is panned and
// accumulated as it arrives. Integer sums are order-independent, so the
// mix equals the former fixed-pair schedule for any number of Lanes.
module osc_stereo_sum #(parameter integer LANES=6, COMPLETION_LIMIT=400)(
 input wire clk,rst,sample_tick,
 input wire[LANES-1:0] completion_valid,completion_accept,
 input wire[3*LANES-1:0] completion_slot,input wire[18*LANES-1:0] completion_sample,
 input wire[9*LANES-1:0] completion_pan,
 output reg signed[31:0] mix_l_q8,mix_r_q8,output reg mix_valid,
 output reg protocol_error,deadline_error,output reg[8:0] last_complete_cycle
);
 localparam integer LW=LANES>8?4:3;
 reg[LW-1:0] lane;reg any;
 always @*begin lane=0;any=0;for(integer k=0;k<LANES;k++)if(completion_valid[k])begin lane=LW'(k);any=1;end end
 wire signed[17:0] in_sample=completion_accept[lane]?$signed(completion_sample[lane*18+:18]):18'sd0;
 wire[8:0] in_pan=completion_pan[lane*9+:9];
 wire[2:0] in_index=completion_slot[lane*3+:3];
 wire in_last=lane==LANES-1&&in_index==7;
 reg signed[17:0] operand;reg[8:0] coefficient;reg right_unity,op_valid,op_last;
 reg signed[27:0] product_l,product_r;reg product_valid,product_last,mix_pending;
 wire signed[27:0] variable_product=$signed(operand)*$signed({1'b0,coefficient});
 wire signed[27:0] unity_product=$signed({{10{operand[17]}},operand})<<<8;
 reg signed[31:0] sum_l,sum_r;
 reg busy;reg[8:0] age;reg[7:0] seen[0:LANES-1];
 always @(posedge clk)begin
  if(rst)begin
   operand<=0;coefficient<=256;right_unity<=0;op_valid<=0;op_last<=0;
   product_l<=0;product_r<=0;product_valid<=0;product_last<=0;mix_pending<=0;
   sum_l<=0;sum_r<=0;busy<=0;age<=0;
   mix_l_q8<=0;mix_r_q8<=0;mix_valid<=0;protocol_error<=0;deadline_error<=0;last_complete_cycle<=0;
   for(integer k=0;k<LANES;k++)seen[k]<=0;
  end else begin
   op_valid<=any;op_last<=any&&in_last;
   product_valid<=op_valid;product_last<=op_valid&&op_last;
   mix_pending<=product_valid&&product_last;mix_valid<=mix_pending;
   if(busy)begin age<=age+1'b1;if(age>=399)deadline_error<=1;end
   if(sample_tick)begin
    if(busy||op_valid||product_valid||any)deadline_error<=1;
    busy<=1;age<=0;sum_l<=0;sum_r<=0;
    for(integer k=0;k<LANES;k++)seen[k]<=0;
   end else if(product_valid)begin
    sum_l<=sum_l+{{4{product_l[27]}},product_l};
    sum_r<=sum_r+{{4{product_r[27]}},product_r};
   end
   if(any)begin
    if((completion_valid&(completion_valid-1'b1))!=0)protocol_error<=1;
    if(!busy||seen[lane][in_index])protocol_error<=1;
    if(in_index==7&&seen[lane]!=8'h7f)protocol_error<=1;
    seen[lane][in_index]<=1;
    if(in_pan>256)protocol_error<=1;
    operand<=in_sample;right_unity<=in_pan>128;
    coefficient<=in_pan>128?((9'd256-in_pan)<<1):(in_pan<<1);
   end
   if(op_valid)begin
    product_l<=right_unity?variable_product:unity_product;
    product_r<=right_unity?unity_product:variable_product;
   end
   if(mix_pending)begin
    mix_l_q8<=sum_l;mix_r_q8<=sum_r;busy<=0;last_complete_cycle<=age+1'b1;
    if(!busy||age>=COMPLETION_LIMIT)deadline_error<=1;
   end
  end
 end
endmodule

// Passive measurement of completed synthesis work. All inputs are in clk.
// "nonzero" is a pre-effects voice contribution, not an estimate from MIDI.
// The 512-frame peak avoids counting silent allocated slots or summing tracks.
module osc48_voice_metrics #(parameter integer CAPACITY=48)(
 input wire clk,rst,start,done,result_valid,result_accepted,result_gate,
 input wire signed [17:0] result_sample,
 input wire [8:0] complete_cycle,input wire protocol_error,deadline_error,
 output reg [127:0] metrics
);
 reg [7:0] completed,allocated,gated,nonzero,peak;
 reg [8:0] window_frame;
 reg [31:0] frame;
 wire [7:0] peak_next=nonzero>peak?nonzero:peak;
 always @(posedge clk)begin
  if(rst)begin completed<=0;allocated<=0;gated<=0;nonzero<=0;peak<=0;window_frame<=0;frame<=0;metrics<=0;end
  else begin
   if(start)begin completed<=0;allocated<=0;gated<=0;nonzero<=0;end
   if(result_valid)begin
    completed<=completed+1'b1;
    if(result_accepted)begin
     allocated<=allocated+1'b1;
     if(result_gate)gated<=gated+1'b1;
     if(result_sample!=0)nonzero<=nonzero+1'b1;
    end
   end
   if(done)begin
    frame<=frame+1'b1;window_frame<=window_frame+1'b1;
    peak<=window_frame==511?8'd0:peak_next;
    metrics[7:0]<=1;metrics[15:8]<=CAPACITY;
    metrics[23:16]<=allocated;metrics[31:24]<=gated;
    metrics[39:32]<=nonzero;
    if(window_frame==511)metrics[47:40]<=peak_next;
    metrics[55:48]<=completed;
    metrics[63:56]<={6'd0,deadline_error,protocol_error};
    metrics[79:64]<={7'd0,complete_cycle};metrics[95:80]<=512;
    metrics[127:96]<=frame;
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(start&&result_valid)$fatal(1,"R83_METRIC_OVERLAP");
  if(done&&(completed!=CAPACITY||result_valid))$fatal(1,"R83_METRIC_INCOMPLETE_FRAME");
 end
 // synthesis translate_on
endmodule

