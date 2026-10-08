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
    parameter integer VIBRATO_MAX_PPM=10000, EXTERNAL_BACKEND=0, COMPACT_RECLAIM=0, DIRECT_BACKEND_SAMPLE=0
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
    assign backend_job={issue_phase,snap_trigger[sel] && snap_valid[sel],next_pitch,lfo_sine,gain(snap_vibrato),level_next,next_pressure,next_transient,next_body,(EXTERNAL_BACKEND?17'd0:issue_fm_index),(EXTERNAL_BACKEND?17'd0:fm_taper),issue_timbre};
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
    assign context_write=!rst && issue && issue_current;
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
