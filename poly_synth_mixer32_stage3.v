// Stage-3 mono 32-voice renderer. Four one-task-per-clock expressive lanes.
module poly_synth_mixer32_stage3 #(parameter integer SHARED_BACKEND=0, COMPACT_RECLAIM=0) (
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
    wire [3:0] backend_issue,backend_take_sample;
    wire [2:0] backend_write_slot[0:3],backend_sample_slot[0:3],backend_phase_slot[0:3];
    wire [193:0] backend_job[0:3];
    wire signed [17:0] backend_sample[0:3];wire [31:0] backend_phase[0:3];
    genvar i;
    generate for (i=0;i<4;i=i+1) begin : lanes
        shared_voice_lane_stage3 #(.EXTERNAL_BACKEND(SHARED_BACKEND),.COMPACT_RECLAIM(COMPACT_RECLAIM),.DIRECT_BACKEND_SAMPLE(i%2)) u_lane (
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
            .backend_take_sample(backend_take_sample[i]),.backend_issue(backend_issue[i]),.backend_write_slot(backend_write_slot[i]),.backend_job(backend_job[i]),
            .backend_sample_slot(backend_sample_slot[i]),.backend_phase_slot(backend_phase_slot[i]),
            .backend_sample(backend_sample[i]),.backend_phase(backend_phase[i]),
            .completion_valid(completion_valid[i]),.completion_accept(completion_accept[i]),
            .completion_slot(completion_slot[i*3 +:3]),
            .completion_sample(completion_sample[i*18 +:18]),
            .completion_id(completion_id[i*64 +:64]),
            .completion_generation(completion_generation[i*16 +:16])
        );
    end endgenerate
    generate if(SHARED_BACKEND)begin: shared_backend
        reg active,wait_issue;reg [3:0] cursor;
        wire [4:0] result_tag[0:1];wire [1:0] result_valid;
        wire signed [17:0] result_sample[0:1];wire [31:0] result_phase[0:1];
        always @(posedge clk)begin
            if(rst)begin active<=0;wait_issue<=0;cursor<=0;end
            else if(sample_tick)begin active<=1;wait_issue<=1;cursor<=0;end
            else if(wait_issue)wait_issue<=0;
            else if(active)begin if(cursor==15)active<=0;else cursor<=cursor+1'b1;end
        end
        for(genvar e=0;e<2;e=e+1)begin: engines
            localparam integer EVEN=2*e,ODD=2*e+1;
            wire [193:0] delayed_job;
            reg [193:0] first_lane_job;
            always @(posedge clk)begin
                if(rst)first_lane_job<=0;
                else if(backend_issue[EVEN])first_lane_job<=backend_job[EVEN];
            end
            // Capture the original issue result before costly interpolation.
            // First Lane is served C2..C9, second Lane C10..C17. Three
            // registered engine stages make late outputs ready C12..C19;
            // actual consumers retain C13..C20, including reset behavior.
            s3_private_context_store #(.WIDTH(194)) jobs(.clk(clk),
                .write_enable(!rst&&backend_issue[ODD]),.write_slot(backend_write_slot[ODD]),
                .read_slot(cursor[2:0]),.write_value(backend_job[ODD]),.read_value(delayed_job));
            wire [4:0] index={cursor[2:0],1'(e),cursor[3]};
            r8_voice_backend engine(.clk(clk),.rst(rst),.in_valid(active&&!wait_issue),.in_tag(index),
                .job_in(cursor[3]?delayed_job:first_lane_job),
                .out_valid(result_valid[e]),.out_tag(result_tag[e]),
                .out_sample(result_sample[e]),.out_phase(result_phase[e]));
            wire early=result_valid[e]&&!result_tag[e][0];
            wire [49:0] early_result;
            reg [7:0] early_valid;
            s3_private_context_store #(.WIDTH(50)) results(.clk(clk),
                .write_enable(!rst&&early),.write_slot(result_tag[e][4:2]),
                .read_slot(backend_sample_slot[EVEN]),
                .write_value({result_phase[e],result_sample[e]}),.read_value(early_result));
            always @(posedge clk)begin
                if(rst||sample_tick)early_valid<=0;
                else if(early)early_valid[result_tag[e][4:2]]<=1;
            end
            // Late Lane result becomes ready just after C12..C19. Its
            // direct output replaces the old sample register at that same
            // edge; every actual consumer still samples on C13..C20.
            // Hold the last late result when this engine serves the other
            // Lane or becomes idle. No result can cross a reset boundary.
            reg signed [17:0] late_sample_hold;
            reg [31:0] even_phase,late_phase_hold;
            wire late=result_valid[e]&&result_tag[e][0];
            always @(posedge clk)begin
                if(rst)begin even_phase<=0;late_sample_hold<=0;late_phase_hold<=0;end
                else begin
                    if(backend_take_sample[EVEN])even_phase<=early_result[49:18];
                    if(late)begin late_sample_hold<=result_sample[e];late_phase_hold<=result_phase[e];end
                end
            end
            assign backend_sample[EVEN]=early_result[17:0];
            assign backend_sample[ODD]=late?result_sample[e]:late_sample_hold;
            assign backend_phase[EVEN]=even_phase;
            assign backend_phase[ODD]=late?result_phase[e]:late_phase_hold;
            // synthesis translate_off
            always @(posedge clk)if(!rst)begin
                if(backend_take_sample[EVEN]&&!early_valid[backend_sample_slot[EVEN]])
                    $fatal(1,"BURST_BACKEND_EARLY_RESULT_MISSING");
                if(completion_valid[ODD]&&(!result_valid[e]||result_tag[e]!={completion_slot[ODD*3+:3],2'(ODD)}))
                    $fatal(1,"BURST_BACKEND_LATE_RESULT_BINDING");
            end
            // synthesis translate_on
        end
    end else begin: separate_backend
        for(genvar b=0;b<4;b=b+1)begin assign backend_sample[b]=0;assign backend_phase[b]=0;end
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

module r8_shared_audio_probe #(parameter integer SHARED_BACKEND=0, COMPACT_RECLAIM=0) (
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

poly_synth_mixer32_stage3 #(.SHARED_BACKEND(1)) impl(.*);
endmodule
