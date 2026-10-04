// Stage6 output boundary; PT8211 remains the ONLY source of sample_tick.
module digital_audio_output_master #(
    parameter integer MIX_SHIFT=5,CLK_FREQ_HZ=50_000_000,SAMPLE_RATE_HZ=48_000
) (
    input wire clk,rst,
    input wire signed [31:0] mix_l_q8,mix_r_q8,
    input wire mix_valid,
    input wire stream_ctrl_valid,
    output wire stream_ctrl_ready,
    input wire [1:0] stream_ctrl_cmd,
    input wire [63:0] stream_ctrl_epoch,
    input wire [31:0] stream_ctrl_rate,
    input wire stream_ctrl_track,
    input wire external_valid,
    output wire external_ready,
    input wire signed [15:0] external_l,external_r,
    input wire [63:0] external_epoch,
    input wire gain_cfg_valid,
    input wire [15:0] gain_cfg_local,gain_cfg_external,
    input wire gain_cfg_local_mute,gain_cfg_external_mute,
    output wire sample_tick,dac_bck,dac_ws,dac_din,
    output wire sample_overrun,dac_underrun,
    output wire stream_error,
    output wire [31:0] external_underflow_count,
    output reg deadline_error,
    output wire observe_load,
    output wire signed [15:0] observe_l,observe_r,
    output wire [2:0] observe_stream_state,
    output wire [11:0] observe_stream_buffered,
    output wire [31:0] observe_stream_generation,
    output wire observe_gain_sample,
    output wire [31:0] observe_gain_frame,observe_gain_version,observe_gain_accepted,
    output wire [15:0] observe_gain_l,observe_gain_e,
    output wire [6:0] observe_gain_remaining,
    output wire [103:0] observe_gain_state
);
    wire signed [15:0] pcm_l,pcm_r;
    wire pcm_valid,pcm_ready;
    wire [31:0] pcm_frame,clip_l_count,clip_r_count;
    wire signed [31:0] external_l_q16,external_r_q16;
    wire [15:0] stream_gain,local_gain,external_gain;
    wire external_sample_valid;
    wire [31:0] external_frame,external_generation;
    wire [63:0] sample_epoch;
    wire [2:0] stream_state;
    assign observe_stream_state=stream_state;
    wire [11:0] buffered;
    assign observe_stream_buffered=buffered;
    wire [32:0] rate_q32;
    wire [31:0] phase_q32,accepted_count,consumed_count,discard_count,stale_count,conceal_count,backpressure_count,rejected_control_count;
    wire [31:0] gain_accepted,gain_rejected;
    wire input_error,master_error;
    assign observe_gain_sample=external_sample_valid;
    assign observe_gain_accepted=gain_accepted;
    assign observe_gain_l=local_gain;assign observe_gain_e=external_gain;
    reg [31:0] frame_number,active_frame;
    assign observe_gain_frame=active_frame;
    reg [10:0] age;
    reg frame_active,have_external,have_local,have_pcm;
    reg signed [31:0] cached_l,cached_r;
    reg [15:0] cached_local_gain,cached_external_gain;
    wire [31:0] combined_gain=$unsigned(external_gain)*$unsigned(stream_gain);
    assign stream_error=input_error | master_error | deadline_error;
    pcm_stream_input u_input(.clk(clk),.rst(rst),.sample_tick(sample_tick),
        .ctrl_valid(stream_ctrl_valid),.ctrl_ready(stream_ctrl_ready),.ctrl_cmd(stream_ctrl_cmd),
        .ctrl_epoch(stream_ctrl_epoch),.ctrl_rate(stream_ctrl_rate),.ctrl_track(stream_ctrl_track),
        .pcm_valid(external_valid),.pcm_ready(external_ready),.pcm_l(external_l),.pcm_r(external_r),.pcm_epoch(external_epoch),
        .sample_l_q16(external_l_q16),.sample_r_q16(external_r_q16),.stream_gain(stream_gain),
        .sample_valid(external_sample_valid),.sample_frame(external_frame),.sample_epoch(sample_epoch),.sample_generation(external_generation),
        .state(stream_state),.buffered(buffered),.observe_generation(observe_stream_generation),.rate_q32(rate_q32),.phase_q32(phase_q32),
        .accepted_count(accepted_count),.consumed_count(consumed_count),.discard_count(discard_count),
        .stale_count(stale_count),.underflow_count(external_underflow_count),.conceal_count(conceal_count),
        .backpressure_count(backpressure_count),.rejected_control_count(rejected_control_count),.protocol_error(input_error));
    master_gain_config u_gain(.clk(clk),.rst(rst),.sample_tick(sample_tick),.cfg_valid(gain_cfg_valid),
        .cfg_local_gain(gain_cfg_local),.cfg_external_gain(gain_cfg_external),
        .cfg_local_mute(gain_cfg_local_mute),.cfg_external_mute(gain_cfg_external_mute),
        .local_gain(local_gain),.external_gain(external_gain),.accepted_count(gain_accepted),.rejected_count(gain_rejected),
        .observe_state(observe_gain_state),.observe_frame_version(observe_gain_version),.observe_remaining(observe_gain_remaining));
    wire signed [63:0] master_l,master_r;
    wire master_valid;
    wire [31:0] master_frame;
    stereo_master_mixer #(.MIX_SHIFT(MIX_SHIFT)) u_master(.clk(clk),.rst(rst),.in_valid(mix_valid),
        .local_l(mix_l_q8),.local_r(mix_r_q8),.external_l(cached_l),.external_r(cached_r),
        .local_gain(cached_local_gain),.external_gain(cached_external_gain),.in_frame(active_frame),
        .out_l(master_l),.out_r(master_r),.out_valid(master_valid),.out_frame(master_frame),.protocol_error(master_error));
    master_pcm_stream #(.MIX_SHIFT(MIX_SHIFT)) u_pcm(.clk(clk),.rst(rst),.in_valid(master_valid),
        .in_l(master_l),.in_r(master_r),.in_frame(master_frame),.sample_l(pcm_l),.sample_r(pcm_r),
        .sample_valid(pcm_valid),.sample_ready(pcm_ready),.sample_frame(pcm_frame),.overrun(sample_overrun),
        .clip_l_count(clip_l_count),.clip_r_count(clip_r_count));
    pt8211_audio_out #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)) u_pt8211(
        .sys_clk(clk),.rst_n(~rst),.sample_l(pcm_l),.sample_r(pcm_r),.sample_valid(pcm_valid),.sample_ready(pcm_ready),
        .dac_bck(dac_bck),.dac_ws(dac_ws),.dac_din(dac_din),.frame_pulse(sample_tick),.underrun(dac_underrun),.observe_load(observe_load),.observe_l(observe_l),.observe_r(observe_r));
    always @(posedge clk)begin
        if(rst)begin
            frame_number<=0;active_frame<=0;age<=0;frame_active<=0;
            have_external<=0;have_local<=0;have_pcm<=0;cached_l<=0;cached_r<=0;
            cached_local_gain<=32768;cached_external_gain<=0;deadline_error<=0;
        end else begin
            if(frame_active && age<1023)age<=age+1'b1;
            if(sample_tick)begin
                if(frame_active && !have_pcm)deadline_error<=1;
                frame_active<=1;age<=0;active_frame<=frame_number;frame_number<=frame_number+1;
                have_external<=0;have_local<=0;have_pcm<=0;
            end
            if(external_sample_valid)begin
                if(!frame_active || external_frame!=active_frame || have_external)deadline_error<=1;
                cached_l<=external_l_q16;cached_r<=external_r_q16;
                cached_local_gain<=local_gain;cached_external_gain<=combined_gain>>15;have_external<=1;
            end
            if(mix_valid)begin
                if(!frame_active || !have_external || have_local)deadline_error<=1;
                have_local<=1;
            end
            if(pcm_valid && pcm_ready)begin
                if(!frame_active || pcm_frame!=active_frame || have_pcm)deadline_error<=1;
                have_pcm<=1;
            end
            if(frame_active && age==999 && !have_pcm)deadline_error<=1;
        end
    end
endmodule
