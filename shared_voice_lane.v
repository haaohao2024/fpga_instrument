// Eight independent state slots, one pipelined arithmetic unit.
// Issue interval is one clk. All eight slots are visited after each tick.
// A generation/instance comparison discards computation from a stolen slot.
module shared_voice_lane #(
    parameter integer ATTACK_MS=10, DECAY_MS=50, SUSTAIN_LEVEL=180,
    parameter integer RELEASE_MS=100, VIBRATO_RATE_HZ=5,
    parameter integer VIBRATO_MAX_PPM=10000
) (
    input wire clk,rst,sample_tick,
    input wire [7:0] slot_valid,slot_gate,slot_trigger,
    input wire [55:0] slot_notes,
    input wire [63:0] slot_pressures,
    input wire [511:0] slot_ids,
    input wire [127:0] slot_generations,
    input wire [7:0] vibrato_depth,
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
    reg [7:0] snap_vibrato;
    reg running;
    reg [3:0] issue_index;
    wire issue=running && issue_index<8;
    wire [2:0] sel=issue_index[2:0];
    reg [63:0] owner_id[0:7];
    reg [15:0] owner_generation[0:7];
    reg [31:0] phase_acc[0:7],lfo_phase[0:7];
    reg [6:0] held_note[0:7];
    reg [7:0] held_pressure[0:7];
    reg [2:0] env_state[0:7];
    reg [16:0] env_level[0:7],env_quotient[0:7];
    reg [31:0] env_remaining[0:7],env_duration[0:7],
               env_remainder[0:7],env_error[0:7];
    wire owner_matches=(owner_id[sel]==snap_ids[sel*64 +:64] &&
                        owner_generation[sel]==snap_generations[sel*16 +:16]);
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
    wire [31:0] note_step;
    phase_step_rom u_pitch(.note_code(effective_note),.phase_step(note_step));
    wire signed [15:0] lfo_sine,wave_sine;
    sine_rom u_lfo(.address(issue_lfo[31:24]),.sample(lfo_sine));
    reg [31:0] phase_value[0:9];
    sine_rom u_wave(.address(phase_value[6][31:24]),.sample(wave_sine));
    function [16:0] gain;
        input [7:0] value;
        begin gain=(value==255)?17'd65536:{1'b0,value,value};end
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
        input signed [51:0] value;
        reg signed [52:0] wide;
        begin
            wide={value[51],value};
            if (wide<0) round_audio=-(((-wide)+53'sd2147483648) >>> 32);
            else round_audio=(wide+53'sd2147483648) >>> 32;
        end
    endfunction
    reg [9:0] valid_pipe;
    reg [2:0] p_slot[0:9];
    reg [63:0] p_id[0:9];
    reg [15:0] p_generation[0:9];
    reg [16:0] p_env[0:9],p_pressure[0:9],p_depth[0:9];
    reg [31:0] p_base_step[0:9],p_base_phase[0:9];
    reg p_restart[0:9],p_gate[0:9];
    reg signed [15:0] p_lfo[0:9],p_wave[0:9];
    reg signed [33:0] lfo_depth,wave_env;
    reg signed [51:0] lfo_max,wave_pressure;
    reg signed [17:0] modulation;
    reg signed [50:0] frequency_product;
    reg [31:0] adjusted_step;
    wire signed [35:0] adjusted_wide=
        $signed({4'b0,p_base_step[4]})+$signed(round_delta(frequency_product));
    wire [31:0] new_phase=p_restart[5]?32'd0:p_base_phase[5]+adjusted_step;
    wire signed [17:0] final_sample=round_audio(wave_pressure);
    wire final_current=(p_id[9]==slot_ids[p_slot[9]*64 +:64] &&
                        p_generation[9]==slot_generations[p_slot[9]*16 +:16] &&
                        slot_valid[p_slot[9]]);
    genvar g;
    generate for (g=0;g<8;g=g+1) begin : levels
        assign envelope_levels[g*17 +:17]=env_level[g];
        assign envelope_states[g*3 +:3]=env_state[g];
    end endgenerate
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            snap_valid<=0;snap_gate<=0;snap_trigger<=0;snap_notes<=0;
            snap_pressures<=0;snap_ids<=0;snap_generations<=0;snap_vibrato<=0;
            running<=0;issue_index<=0;valid_pipe<=0;
            lane_sum<=0;lane_sum_valid<=0;done_mask<=0;done_ids<=0;
            voice_samples<=0;issued_count<=0;completed_count<=0;deadline_error<=0;
            lfo_depth<=0;lfo_max<=0;modulation<=0;frequency_product<=0;
            adjusted_step<=0;wave_env<=0;wave_pressure<=0;
            for (i=0;i<8;i=i+1) begin
                owner_id[i]<=0;owner_generation[i]<=0;
                phase_acc[i]<=0;lfo_phase[i]<=0;
                held_note[i]<=0;held_pressure[i]<=0;
                env_state[i]<=0;env_level[i]<=0;
                env_remaining[i]<=0;env_duration[i]<=1;
                env_remainder[i]<=0;env_error[i]<=0;env_quotient[i]<=0;
            end
            for (i=0;i<10;i=i+1) begin
                p_slot[i]<=0;p_id[i]<=0;p_generation[i]<=0;
                p_env[i]<=0;p_pressure[i]<=0;p_depth[i]<=0;
                p_base_step[i]<=0;p_base_phase[i]<=0;
                p_restart[i]<=0;p_gate[i]<=0;p_lfo[i]<=0;p_wave[i]<=0;
                phase_value[i]<=0;
            end
        end else begin
            lane_sum_valid<=0;done_mask<=0;
            valid_pipe<={valid_pipe[8:0],issue};
            for (i=1;i<10;i=i+1) begin
                p_slot[i]<=p_slot[i-1];p_id[i]<=p_id[i-1];
                p_generation[i]<=p_generation[i-1];
                p_env[i]<=p_env[i-1];p_pressure[i]<=p_pressure[i-1];
                p_depth[i]<=p_depth[i-1];p_base_step[i]<=p_base_step[i-1];
                p_base_phase[i]<=p_base_phase[i-1];
                p_restart[i]<=p_restart[i-1];p_gate[i]<=p_gate[i-1];
                p_lfo[i]<=p_lfo[i-1];p_wave[i]<=p_wave[i-1];
                if (i!=6) phase_value[i]<=phase_value[i-1];
            end
            if (sample_tick) begin
                if (running || valid_pipe!=0) deadline_error<=1;
                snap_valid<=slot_valid;snap_gate<=slot_gate;
                snap_trigger<=slot_trigger;snap_notes<=slot_notes;
                snap_pressures<=slot_pressures;snap_ids<=slot_ids;
                snap_generations<=slot_generations;snap_vibrato<=vibrato_depth;
                running<=1;issue_index<=0;lane_sum<=0;
            end
            if (issue) begin
                issue_index<=issue_index+1'b1;
                if (issue_index==7) running<=0;
                issued_count<=issued_count+1'b1;
                p_slot[0]<=sel;p_id[0]<=snap_ids[sel*64 +:64];
                p_generation[0]<=snap_generations[sel*16 +:16];
                p_env[0]<=level_next;
                p_pressure[0]<=gain((state_next==4)?issue_held_pressure:
                    snap_pressures[sel*8 +:8]);
                p_depth[0]<=gain(snap_vibrato);
                p_base_step[0]<=note_step;p_base_phase[0]<=issue_phase;
                p_restart[0]<=snap_trigger[sel] && snap_valid[sel];
                p_gate[0]<=snap_gate[sel];p_lfo[0]<=lfo_sine;
                owner_id[sel]<=snap_ids[sel*64 +:64];
                owner_generation[sel]<=snap_generations[sel*16 +:16];
                env_state[sel]<=state_next;env_level[sel]<=level_next;
                env_remaining[sel]<=remaining_next;env_duration[sel]<=duration_next;
                env_remainder[sel]<=remainder_next;env_error[sel]<=error_next;
                env_quotient[sel]<=quotient_next;
                lfo_phase[sel]<=issue_lfo+LFO_STEP;
                if (snap_trigger[sel] || snap_gate[sel]) begin
                    held_note[sel]<=snap_notes[sel*7 +:7];
                    held_pressure[sel]<=snap_pressures[sel*8 +:8];
                end else if (state_next==0) begin
                    held_note[sel]<=0;held_pressure[sel]<=0;
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
            if (valid_pipe[6]) p_wave[7]<=wave_sine;
            if (valid_pipe[7])
                wave_env<=p_wave[7]*$signed({1'b0,p_env[7]});
            if (valid_pipe[8])
                wave_pressure<=wave_env*$signed({1'b0,p_pressure[8]});
            if (valid_pipe[9]) begin
                completed_count<=completed_count+1'b1;
                if (final_current) begin
                    phase_acc[p_slot[9]]<=phase_value[9];
                    voice_samples[p_slot[9]*18 +:18]<=final_sample;
                    lane_sum<=lane_sum+{{6{final_sample[17]}},final_sample};
                    if (!p_gate[9] && env_state[p_slot[9]]==0 &&
                        final_sample==0) begin
                        done_mask[p_slot[9]]<=1;
                        done_ids[p_slot[9]*64 +:64]<=p_id[9];
                    end
                end
                if (p_slot[9]==7) lane_sum_valid<=1;
            end
        end
    end
    // synthesis translate_off
    always @(posedge clk) if (!rst && sample_tick && (running || valid_pipe!=0))
        $fatal(1,"shared_voice_lane: frame deadline missed");
    // synthesis translate_on
endmodule
