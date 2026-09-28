// Per-instance pan configuration, independent of the performance event path.
module voice_pan_config (
    input wire clk,rst,sample_tick,
    input wire [31:0] slot_valid,slot_cancel,
    input wire [2047:0] slot_ids,
    input wire [511:0] slot_generations,
    input wire pan_valid,
    input wire [4:0] pan_slot,
    input wire [63:0] pan_id,
    input wire [15:0] pan_generation,
    input wire [8:0] pan_value,
    output reg [287:0] snapshot_pan,
    output reg [2047:0] snapshot_ids,
    output reg [511:0] snapshot_generations,
    output reg [31:0] accepted_count,stale_count,invalid_count
);
    reg [31:0] owned;
    reg [8:0] value[0:31];
    reg [63:0] owner[0:31];
    reg [15:0] generation[0:31];
    wire [31:0] current;
    genvar g;
    generate for(g=0;g<32;g=g+1) begin: tags
        assign current[g]=owned[g] && slot_valid[g] &&
            owner[g]==slot_ids[g*64 +:64] && generation[g]==slot_generations[g*16 +:16];
    end endgenerate
    integer i;
    always @(posedge clk) begin
        if(rst) begin
            owned<=0;snapshot_pan<={32{9'd128}};snapshot_ids<=0;snapshot_generations<=0;
            accepted_count<=0;stale_count<=0;invalid_count<=0;
            for(i=0;i<32;i=i+1)begin value[i]<=128;owner[i]<=0;generation[i]<=0;end
        end else begin
            for(i=0;i<32;i=i+1)if(!current[i] || slot_cancel[i])owned[i]<=0;
            if(sample_tick) begin
                snapshot_ids<=slot_ids;snapshot_generations<=slot_generations;
                // Like Voice snapshot: pre-edge state, even on a publication edge.
                // Cancellation belongs to the frozen issue/writeback authority.
                for(i=0;i<32;i=i+1)snapshot_pan[i*9 +:9]<=current[i]?value[i]:9'd128;
            end
            if(pan_valid)begin
                if(pan_value>256)invalid_count<=invalid_count+1'b1;
                else if(!slot_valid[pan_slot] || slot_cancel[pan_slot] ||
                        slot_ids[pan_slot*64 +:64]!=pan_id ||
                        slot_generations[pan_slot*16 +:16]!=pan_generation)
                    stale_count<=stale_count+1'b1;
                else begin
                    owned[pan_slot]<=1;owner[pan_slot]<=pan_id;
                    generation[pan_slot]<=pan_generation;value[pan_slot]<=pan_value;
                    accepted_count<=accepted_count+1'b1;
                end
            end
        end
    end
endmodule
