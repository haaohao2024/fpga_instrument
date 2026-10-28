// One independent voice, 50MHz clk, 48kHz sample enable. Portable Verilog-2001.
// Inputs synchronous to clk. Trigger is captured on EVERY clk, not only ticks.
// E0 accepts sample_tick; E10 publishes the sample. Min tick spacing: 11 clks.
module synth_voice #(
    parameter integer ATTACK_MS = 10,
    parameter integer DECAY_MS = 50,
    parameter integer SUSTAIN_LEVEL = 180,
    parameter integer RELEASE_MS = 100,
    parameter integer VIBRATO_RATE_HZ = 5,
    parameter integer VIBRATO_MAX_PPM = 10000
) (
    input wire clk, rst, sample_tick,
    input wire [6:0] note_code,
    input wire gate, trigger,
    input wire [7:0] pressure, vibrato_depth,
    input wire [1:0] timbre_id, // Reserved: all values select sine in this version.
    output reg signed [17:0] voice_sample,
    output reg sample_valid
);
    localparam [2:0] IDLE=0, RELEASE=4;
    localparam [31:0] LFO_STEP = (64'd4294967296*VIBRATO_RATE_HZ+24000)/48000;
    localparam signed [17:0] MAX_MOD_Q16 =
        (64'd65536*VIBRATO_MAX_PPM+500000)/1000000;
    reg pending_trigger;
    wire retrigger = pending_trigger || trigger;
    reg [7:0] held_pressure;
    reg [6:0] held_note_code;
    wire [2:0] env_state, env_state_next;
    wire [16:0] envelope, envelope_next;
    voice_adsr #(.ATTACK_MS(ATTACK_MS), .DECAY_MS(DECAY_MS),
        .SUSTAIN_LEVEL(SUSTAIN_LEVEL), .RELEASE_MS(RELEASE_MS)) u_adsr (
        .clk(clk), .rst(rst), .sample_tick(sample_tick), .gate(gate),
        .retrigger(retrigger), .state(env_state), .level(envelope),
        .state_next(env_state_next), .level_next(envelope_next)
    );

    // Q0.16 gain including exact unity, with exact zero and monotonic mapping.
    function [16:0] gain;
        input [7:0] value;
        begin gain=(value==255) ? 17'd65536 : {1'b0,value,value}; end
    endfunction
    function signed [17:0] round_mod;
        input signed [51:0] value;
        reg signed [52:0] wide;
        begin
            wide={value[51],value};
            if (wide < 0) round_mod=-(((-wide)+53'sd1073741824) >>> 31);
            else round_mod=(wide+53'sd1073741824) >>> 31;
        end
    endfunction
    function signed [34:0] round_delta;
        input signed [50:0] value;
        reg signed [51:0] wide;
        begin
            wide={value[50],value};
            if (wide < 0) round_delta=-(((-wide)+52'sd32768) >>> 16);
            else round_delta=(wide+52'sd32768) >>> 16;
        end
    endfunction
    function signed [17:0] round_audio;
        input signed [51:0] value;
        reg signed [52:0] wide;
        begin
            wide={value[51],value};
            if (wide < 0) round_audio=-(((-wide)+53'sd2147483648) >>> 32);
            else round_audio=(wide+53'sd2147483648) >>> 32;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin pending_trigger<=0; held_pressure<=0; held_note_code<=0; end
        else begin
            // A trigger on E0 is consumed immediately. Others wait for E0.
            if (sample_tick) pending_trigger<=0;
            else if (trigger) pending_trigger<=1;
            // Preserve the LAST high-gate pressure, including between ticks.
            // Never sample the low-gate pressure at the falling edge.
            if (trigger || gate) begin
                held_pressure<=pressure;
                held_note_code<=note_code;
            end else if (sample_tick && env_state_next==IDLE) begin
                held_pressure<=0;
                held_note_code<=0;
            end
        end
    end

    wire [31:0] note_step;
    // Use next state to cover the very FIRST release sample. A simultaneous
    // trigger selects Attack/Sustain instead, immediately adopting the new note.
    // Only the base pitch is held; LFO modulation and main phase keep advancing.
    wire [6:0] effective_note_code =
        (env_state_next==RELEASE) ? held_note_code : note_code;
    phase_step_rom u_pitch(.note_code(effective_note_code), .phase_step(note_step));
    reg [31:0] lfo_phase, phase_acc;
    wire signed [15:0] lfo_sine;
    sine_rom u_lfo_rom(.address(lfo_phase[31:24]), .sample(lfo_sine));
    reg [7:0] wave_address;
    wire signed [15:0] wave_rom;
    sine_rom u_wave_rom(.address(wave_address), .sample(wave_rom));

    reg [9:0] valid_pipe;
    // Sample context remains stable until the next request (>=11 clks later).
    reg [31:0] base_step;
    reg [16:0] env_gain, pressure_gain, depth_gain;
    reg restart_phase;
    reg signed [15:0] lfo_sample, wave_sample;
    reg signed [33:0] lfo_times_depth;
    reg signed [51:0] lfo_times_max;
    reg signed [17:0] modulation_q16;
    reg signed [50:0] frequency_product;
    reg [31:0] adjusted_step;
    wire signed [35:0] adjusted_wide =
        $signed({4'b0,base_step}) + $signed(round_delta(frequency_product));
    wire [31:0] next_phase = restart_phase ? 32'd0 : phase_acc+adjusted_step;
    reg signed [33:0] wave_times_env;
    reg signed [51:0] wave_times_gain;

    always @(posedge clk) begin
        if (rst) begin
            valid_pipe<=0; sample_valid<=0; voice_sample<=0;
            lfo_phase<=0; phase_acc<=0; wave_address<=0;
            base_step<=0; env_gain<=0; pressure_gain<=0; depth_gain<=0;
            restart_phase<=0; lfo_sample<=0; wave_sample<=0;
            lfo_times_depth<=0; lfo_times_max<=0; modulation_q16<=0;
            frequency_product<=0; adjusted_step<=0;
            wave_times_env<=0; wave_times_gain<=0;
        end else begin
            valid_pipe<={valid_pipe[8:0],sample_tick};
            sample_valid<=valid_pipe[9];
            if (sample_tick) begin // E0: atomic control snapshot + ADSR advance
                base_step<=note_step; env_gain<=envelope_next;
                pressure_gain<=gain((env_state_next==RELEASE) ? held_pressure : pressure);
                depth_gain<=gain(vibrato_depth); restart_phase<=retrigger;
                lfo_sample<=lfo_sine; lfo_phase<=lfo_phase+LFO_STEP;
            end
            if (valid_pipe[0]) // E1
                lfo_times_depth<=$signed(lfo_sample)*$signed({1'b0,depth_gain});
            if (valid_pipe[1]) // E2
                lfo_times_max<=lfo_times_depth*MAX_MOD_Q16;
            if (valid_pipe[2]) modulation_q16<=round_mod(lfo_times_max); // E3
            if (valid_pipe[3]) // E4
                frequency_product<=$signed({1'b0,base_step})*modulation_q16;
            if (valid_pipe[4]) adjusted_step<=adjusted_wide[31:0]; // E5
            if (valid_pipe[5]) begin // E6: one main DDS update per request
                phase_acc<=next_phase; wave_address<=next_phase[31:24];
            end
            if (valid_pipe[6]) wave_sample<=wave_rom; // E7
            if (valid_pipe[7]) // E8
                wave_times_env<=wave_sample*$signed({1'b0,env_gain});
            if (valid_pipe[8]) // E9
                wave_times_gain<=wave_times_env*$signed({1'b0,pressure_gain});
            if (valid_pipe[9]) voice_sample<=round_audio(wave_times_gain); // E10
        end
    end

    // synthesis translate_off
    initial begin
        if (ATTACK_MS<0 || ATTACK_MS>60000 || DECAY_MS<0 || DECAY_MS>60000 ||
            RELEASE_MS<0 || RELEASE_MS>60000 || SUSTAIN_LEVEL<0 || SUSTAIN_LEVEL>255)
            $fatal(1,"Invalid ADSR: times 0..60000 ms; sustain 0..255");
        if (VIBRATO_RATE_HZ<0 || VIBRATO_RATE_HZ>100 ||
            VIBRATO_MAX_PPM<0 || VIBRATO_MAX_PPM>100000)
            $fatal(1,"Invalid vibrato: rate 0..100 Hz; maximum 0..100000 ppm");
    end
    always @(posedge clk) begin
        if (!rst && sample_tick && (|valid_pipe))
            $fatal(1,"sample_tick spacing must be at least 11 clk cycles");
    end
    // synthesis translate_on
endmodule
