// Stage-3 mono 32-voice renderer. Four one-task-per-clock expressive lanes.
module poly_synth_mixer32_stage3 (
    input wire clk,rst,sample_tick,
    input wire [31:0] slot_valid,slot_gate,slot_trigger,slot_cancel,
    input wire [223:0] slot_notes,
    input wire [255:0] slot_pressures,
    input wire [2047:0] slot_ids,
    input wire [511:0] slot_generations,
    input wire [95:0] slot_timbres,
    input wire [7:0] vibrato_depth,
    input wire [3:0] glide_code,
    output reg signed [23:0] mix_sample,
    output reg mix_valid,
    output wire [543:0] envelope_levels,
    output wire [95:0] envelope_states,
    output wire [31:0] done_mask,
    output wire [2047:0] done_ids,
    output wire [575:0] voice_samples,
    output wire [3:0] completion_valid,completion_accept,
    output wire [11:0] completion_slot,
    output wire [71:0] completion_sample,
    output wire [255:0] completion_id,
    output wire [63:0] completion_generation,
    output wire [3:0] lane_deadline_error
);
    wire signed [23:0] lane_sum[0:3];
    wire [3:0] lane_valid;
    genvar i;
    generate for (i=0;i<4;i=i+1) begin : lanes
        shared_voice_lane_stage3 u_lane (
            .clk(clk),.rst(rst),.sample_tick(sample_tick),
            .slot_valid(slot_valid[i*8 +:8]),
            .slot_gate(slot_gate[i*8 +:8]),
            .slot_trigger(slot_trigger[i*8 +:8]),
            .slot_cancel(slot_cancel[i*8 +:8]),
            .slot_notes(slot_notes[i*56 +:56]),
            .slot_pressures(slot_pressures[i*64 +:64]),
            .slot_ids(slot_ids[i*512 +:512]),
            .slot_generations(slot_generations[i*128 +:128]),
            .slot_timbres(slot_timbres[i*24 +:24]),
            .vibrato_depth(vibrato_depth),.glide_code(glide_code),
            .lane_sum(lane_sum[i]),.lane_sum_valid(lane_valid[i]),
            .envelope_levels(envelope_levels[i*136 +:136]),
            .envelope_states(envelope_states[i*24 +:24]),
            .done_mask(done_mask[i*8 +:8]),
            .done_ids(done_ids[i*512 +:512]),
            .voice_samples(voice_samples[i*144 +:144]),
            .issued_count(),.completed_count(),
            .deadline_error(lane_deadline_error[i]),
            .completion_valid(completion_valid[i]),.completion_accept(completion_accept[i]),
            .completion_slot(completion_slot[i*3 +:3]),
            .completion_sample(completion_sample[i*18 +:18]),
            .completion_id(completion_id[i*64 +:64]),
            .completion_generation(completion_generation[i*16 +:16])
        );
    end endgenerate
    reg signed [23:0] pair01,pair23;
    reg pair_valid;
    always @(posedge clk) begin
        if (rst) begin
            pair01<=0;pair23<=0;pair_valid<=0;
            mix_sample<=0;mix_valid<=0;
        end else begin
            pair_valid<=&lane_valid;
            mix_valid<=pair_valid;
            if (&lane_valid) begin
                pair01<=lane_sum[0]+lane_sum[1];
                pair23<=lane_sum[2]+lane_sum[3];
            end
            if (pair_valid) mix_sample<=pair01+pair23;
        end
    end
    // synthesis translate_off
    always @(posedge clk) if (!rst && lane_valid!=0 && lane_valid!=4'b1111)
        $fatal(1,"poly_synth_mixer32_stage3: lane completion misaligned");
    // synthesis translate_on
endmodule
