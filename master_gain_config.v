// Independent Parameter path. Updates on tick use the previous pending config.
// Mute preserves the user's gain target. Every change reaches its exact target
// in 64 sample ticks; configurations never alter Performance Event identity.
module master_gain_config (
    input wire clk,rst,sample_tick,cfg_valid,
    input wire [15:0] cfg_local_gain,cfg_external_gain,
    input wire cfg_local_mute,cfg_external_mute,
    output reg [15:0] local_gain,external_gain,
    output reg [31:0] accepted_count,rejected_count,
    output reg [31:0] observe_frame_version,
    output wire [6:0] observe_remaining,
    output wire [103:0] observe_state
);
    reg pending;
    reg [15:0] pending_l,pending_e,target_l,target_e;
    reg [6:0] remaining;
    reg signed [31:0] delta_l,delta_e;
    assign observe_remaining=remaining;
    assign observe_state={pending,remaining,observe_frame_version,pending_l,pending_e,target_l,target_e};
    // Read-only identity of the configuration actually consumed on a tick.
    always @(posedge clk)begin
        if(rst)observe_frame_version<=0;
        else if(sample_tick && pending)observe_frame_version<=accepted_count;
    end
    always @(posedge clk)begin
        if(rst)begin
            local_gain<=32768;external_gain<=32768;
            pending<=0;pending_l<=32768;pending_e<=32768;target_l<=32768;target_e<=32768;
            remaining<=0;accepted_count<=0;rejected_count<=0;delta_l<=0;delta_e<=0;
        end else begin
            if(sample_tick)begin
                if(pending)begin
                    target_l<=pending_l;target_e<=pending_e;remaining<=63;pending<=0;
                    delta_l=$signed({1'b0,pending_l})-$signed({1'b0,local_gain});
                    delta_e=$signed({1'b0,pending_e})-$signed({1'b0,external_gain});
                    local_gain<=$signed({1'b0,local_gain})+delta_l/32'sd64;
                    external_gain<=$signed({1'b0,external_gain})+delta_e/32'sd64;
                end else if(remaining!=0)begin
                    delta_l=$signed({1'b0,target_l})-$signed({1'b0,local_gain});
                    delta_e=$signed({1'b0,target_e})-$signed({1'b0,external_gain});
                    local_gain<=$signed({1'b0,local_gain})+delta_l/$signed({1'b0,remaining});
                    external_gain<=$signed({1'b0,external_gain})+delta_e/$signed({1'b0,remaining});
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
