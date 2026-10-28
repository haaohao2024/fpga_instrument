// Atomic 11-word configuration; updates on a tick take effect NEXT tick.
// word0: enable[2:0], bypass[3], clear pulses[6:4]. Other bits reserved.
// words1..10: D, feedbackD, chorusB, chorusA, phaseStep, g, a, wetD/C/R.
module fx_config_frame(
    input wire clk,rst,sample_tick,
    input wire cfg_valid,
    input wire [351:0] cfg_data,
    output reg [351:0] frame_config,
    output reg [2:0] frame_clear,
    output reg [31:0] frame_version,
    output reg [31:0] accepted_count,rejected_count
);
    localparam [351:0] DEFAULT_CONFIG={32'd4096,32'd4096,32'd6144,
        32'd16384,32'd24576,32'd71583,32'd192,32'd576,
        32'd12288,32'd11520,32'd8};
    reg [351:0] shadow;
    reg [2:0] pending_clear;
    reg [31:0] version;
    wire [31:0] base=cfg_data[127:96],depth=cfg_data[159:128];
    wire legal = cfg_data[31:7]==0 && cfg_data[63:32]>=1 && cfg_data[63:32]<=16383 &&
        cfg_data[95:64]<=24576 && base>=96 && base<=1440 && depth<=480 &&
        base>=depth+2 && base+depth<=1920 &&
        (cfg_data[191:160]==0 || (cfg_data[191:160]>=4474 && cfg_data[191:160]<=447392)) &&
        cfg_data[223:192]<=28672 && cfg_data[255:224]<=28672 &&
        cfg_data[287:256]<=8192 && cfg_data[319:288]<=8192 && cfg_data[351:320]<=8192;
    always @(posedge clk) begin
        if(rst)begin
            shadow<=DEFAULT_CONFIG;frame_config<=DEFAULT_CONFIG;
            pending_clear<=0;frame_clear<=0;version<=0;frame_version<=0;
            accepted_count<=0;rejected_count<=0;
        end else begin
            if(sample_tick)begin
                frame_config<=shadow;frame_clear<=pending_clear;
                frame_version<=version;pending_clear<=0;
            end
            if(cfg_valid)begin
                if(legal)begin
                    shadow<={cfg_data[351:7],3'b0,cfg_data[3:0]};
                    pending_clear<=(sample_tick?3'b0:pending_clear)|cfg_data[6:4];
                    version<=version+1'b1;accepted_count<=accepted_count+1'b1;
                end else rejected_count<=rejected_count+1'b1;
            end
        end
    end
endmodule
