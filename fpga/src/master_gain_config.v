// Independent Parameter path. Updates on tick use the previous pending config.
// Mute preserves the user's gain target. Every change reaches its exact target
// in 64 sample ticks; configurations never alter Performance Event identity.
module master_gain_config #(parameter integer SAMPLE_RATE_HZ=48000) (
    input wire clk,rst,sample_tick,cfg_valid,
    input wire [15:0] cfg_local_gain,cfg_external_gain,
    input wire cfg_local_mute,cfg_external_mute,
    output reg [15:0] local_gain,external_gain,
    output reg [31:0] accepted_count,rejected_count,
    output reg [31:0] observe_frame_version,
    output wire [6:0] observe_remaining,
    output wire [103:0] observe_state
);
    localparam integer FADE_FRAMES=SAMPLE_RATE_HZ>=96000?128:SAMPLE_RATE_HZ==72000?96:64;
    reg[1:0] fade_phase;
    wire fade_step=SAMPLE_RATE_HZ!=128000||fade_phase!=3;
    always @(posedge clk)if(rst)fade_phase<=0;else if(sample_tick)fade_phase<=fade_phase+1'b1;
    reg pending;
    reg [15:0] pending_l,pending_e,target_l,target_e;
    reg [6:0] remaining;
    // For |target-current|=64*q+r, the original successive truncated
    // divisions take q for the first64-r ticks and q+1 for the last r.
    // Each new pending configuration captures a fresh exact recurrence.
    reg [9:0] step_l,step_e;
    reg [6:0] extra_l,extra_e;
    reg up_l,up_e;
    wire [15:0] distance_l=pending_l>=local_gain?pending_l-local_gain:local_gain-pending_l;
    wire [15:0] distance_e=pending_e>=external_gain?pending_e-external_gain:external_gain-pending_e;
    wire [15:0] advance_l={6'd0,step_l}+{15'd0,remaining<=extra_l};
    wire [15:0] advance_e={6'd0,step_e}+{15'd0,remaining<=extra_e};
    assign observe_remaining=remaining;
    assign observe_state={pending,remaining,observe_frame_version,pending_l,pending_e,target_l,target_e};
    // Read-only identity of the configuration actually consumed on a tick.
    always @(posedge clk)begin
        if(rst)observe_frame_version<=0;
        else if(sample_tick && fade_step && pending)observe_frame_version<=accepted_count;
    end
    always @(posedge clk)begin
        if(rst)begin
            local_gain<=32768;external_gain<=32768;
            pending<=0;pending_l<=32768;pending_e<=32768;target_l<=32768;target_e<=32768;
            remaining<=0;accepted_count<=0;rejected_count<=0;step_l<=0;step_e<=0;extra_l<=0;extra_e<=0;up_l<=0;up_e<=0;
        end else begin
            if(sample_tick && fade_step)begin
                if(pending)begin
                    target_l<=pending_l;target_e<=pending_e;remaining<=FADE_FRAMES-1;pending<=0;
                    step_l<=(distance_l/FADE_FRAMES);extra_l<=(distance_l%FADE_FRAMES);up_l<=pending_l>=local_gain;
                    step_e<=(distance_e/FADE_FRAMES);extra_e<=(distance_e%FADE_FRAMES);up_e<=pending_e>=external_gain;
                    local_gain<=pending_l>=local_gain?local_gain+(distance_l/FADE_FRAMES):local_gain-(distance_l/FADE_FRAMES);
                    external_gain<=pending_e>=external_gain?external_gain+(distance_e/FADE_FRAMES):external_gain-(distance_e/FADE_FRAMES);
                end else if(remaining!=0)begin
                    local_gain<=up_l?local_gain+advance_l:local_gain-advance_l;
                    external_gain<=up_e?external_gain+advance_e:external_gain-advance_e;
                    remaining<=remaining-1'b1;
                end
            end
            if(cfg_valid)begin
                if(cfg_local_gain>32768 || cfg_external_gain>32768)rejected_count<=rejected_count+1;
                else begin
                    pending<=1;pending_l<=cfg_local_mute ? 0:cfg_local_gain;
                    pending_e<=cfg_external_mute ? 0:cfg_external_gain;accepted_count<=accepted_count+1;
                end
            end
        end
    end
endmodule
