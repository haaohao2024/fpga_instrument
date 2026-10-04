// One system-clock event per cycle from a latched nine-lane batch.
// NOTE_OFF and expression match source/key/press_token, never pitch.
// Instance zero is invalid. ID_WIDTH can be reduced in TB to exercise wrap.
module voice_allocator32 #(parameter integer ID_WIDTH=64) (
    input wire clk, rst, panic, sample_tick,
    input wire event_valid,
    output wire event_ready,
    input wire [904:0] event_packet,
    // Configuration is sampled only when a NOTE_ON actually allocates a slot.
    input wire [2:0] timbre_id,
    input wire [543:0] envelope_levels,
    input wire [31:0] done_mask,
    input wire [2047:0] done_ids,
    output wire [31:0] slot_valid, slot_gate, slot_trigger,
    output wire [31:0] slot_cancel,
    output wire [223:0] slot_notes,
    output wire [255:0] slot_pressures,
    output wire [2047:0] slot_ids,
    output wire [511:0] slot_generations,
    output wire [95:0] slot_timbres,
    output reg [7:0] vibrato_depth,
    output reg protocol_error,
    output reg [31:0] steal_count, stale_count, allocation_count,
    output reg [31:0] reclaim_count, id_collision_skip_count, id_wrap_count,
    // Read-only publication/identity export. No observer feeds allocator state.
    output wire observe_publish,
    output wire [127:0] observe_sources,
    output wire [255:0] observe_keys,
    output wire [2047:0] observe_tokens,
    // Stage11: passive decision taps, sampled on the ORIGINAL apply edge.
    // outcome: 1 allocate, 2 off, 3 pitch/pressure, 4 vibrato, 5 stale,
    // 6 invalid item. A working batch is durable only after publish_ok.
    output wire observe_busy, observe_batch_begin, observe_publish_ok,
    output wire observe_batch_abort, observe_apply_valid,
    output wire [31:0] observe_batch_timestamp,
    output wire [3:0] observe_apply_lane,
    output wire [95:0] observe_apply_item,
    output wire [7:0] observe_apply_outcome,
    output wire [5:0] observe_apply_slot,
    output wire [63:0] observe_apply_id,
    output wire [15:0] observe_apply_generation,
    output wire [2:0] observe_apply_timbre,
    output wire observe_apply_steal,
    output wire [63:0] observe_retired_id,
    output wire [15:0] observe_retired_generation,
    output wire [31:0] observe_reclaim_mask,
    output wire [511:0] observe_reclaim_generations
);
    reg valid_r[0:31], gate_r[0:31], trigger_r[0:31];
    // Working bank is updated one event lane per clock. Only the visible bank
    // drives synthesis, so all events in one packet take effect atomically.
    reg visible_valid[0:31],visible_gate[0:31],visible_trigger[0:31];
    reg [6:0] visible_note[0:31];
    reg [7:0] visible_pressure[0:31];
    reg [3:0] visible_source[0:31];
    reg [7:0] visible_key[0:31];
    reg [ID_WIDTH-1:0] visible_id[0:31];
    reg [15:0] visible_generation[0:31];
    reg [2:0] visible_timbre[0:31];
    reg [63:0] visible_token_observe[0:31];
    reg [3:0] source_r[0:31];
    reg [7:0] key_r[0:31], pressure_r[0:31];
    reg [6:0] note_r[0:31];
    reg [63:0] token_r[0:31], age_r[0:31];
    reg [ID_WIDTH-1:0] id_r[0:31], next_id;
    // On ID wrap, quarantine all retired/in-flight IDs for longer than the
    // 20-clock issue-to-writeback window before reusing any number.
    reg [5:0] wrap_holdoff;
    reg [15:0] generation_r[0:31];
    reg [2:0] timbre_r[0:31];
    reg [63:0] age_counter;
    reg [7:0] vib_work;
    reg busy;
    reg [3:0] lane;
    reg [904:0] packet;
    function [3:0] first_set;
        input [8:0] mask;
        input [3:0] from_lane;
        integer t;
        begin
            first_set=9;
            for (t=8;t>=0;t=t-1)
                if (t>=from_lane && mask[t]) first_set=t;
        end
    endfunction
    wire lane_enabled=packet[864+lane];
    wire [3:0] next_lane=first_set(packet[872:864],lane+1'b1);
    wire [95:0] item=packet[lane*96 +: 96];
    wire [63:0] item_token=item[95:32];
    wire [31:0] event_word=item[31:0];
    wire [3:0] source=event_word[31:28], kind=event_word[27:24];
    wire [7:0] key=event_word[23:16], value=event_word[8:1];
    wire [6:0] note=event_word[15:9];
    reg [5:0] victim, target;
    reg found_free, found_release, found_target, id_collision, token_collision;
    reg [16:0] lowest_level;
    reg [63:0] oldest_age;
    reg [5:0] reclaim_delta;
    integer i,j;
    wire [543:0] current_levels;
    wire [ID_WIDTH-1:0] after_id=(next_id=={ID_WIDTH{1'b1}}) ?
        {{(ID_WIDTH-1){1'b0}},1'b1} : next_id+1'b1;
    assign event_ready=!rst && !busy;
    assign observe_publish=!rst && busy && lane==9;
    wire observed_invalid=event_word[0] || (kind<1 || kind>4) ||
        (kind==4 && (key!=8'hff || note!=0)) ||
        (kind!=4 && item_token==0);
    wire observed_allocation=kind==1 && !token_collision &&
        wrap_holdoff==0 && next_id!=0 && !id_collision;
    assign observe_busy=busy;
    assign observe_batch_begin=!rst && !panic && !protocol_error && !busy &&
        event_valid && event_packet[872:864]!=0;
    assign observe_publish_ok=observe_publish && !panic && !protocol_error;
    assign observe_batch_abort=!rst && busy &&
        (panic || protocol_error || (lane<9 && lane_enabled && observed_invalid));
    assign observe_apply_valid=!rst && !panic && !protocol_error && busy &&
        lane<9 && lane_enabled && (observed_invalid || kind!=1 ||
                                 token_collision || observed_allocation);
    assign observe_batch_timestamp=packet[904:873];
    assign observe_apply_lane=lane;
    assign observe_apply_item=item;
    assign observe_apply_outcome=observed_invalid?8'd6:
        ((kind==1 && token_collision) || (kind!=1 && kind!=4 && !found_target))?8'd5:
        {4'd0,kind};
    assign observe_apply_slot=kind==1?victim:((kind==4 || !found_target)?6'd63:target);
    assign observe_apply_id=kind==1?{{(64-ID_WIDTH){1'b0}},next_id}:
        ((kind==4 || !found_target)?64'd0:{{(64-ID_WIDTH){1'b0}},id_r[target]});
    assign observe_apply_generation=kind==1?generation_r[victim]+1'b1:
        ((kind==4 || !found_target)?16'd0:generation_r[target]);
    assign observe_apply_timbre=kind==1?timbre_id:
        ((kind==4 || !found_target)?3'd0:timbre_r[target]);
    assign observe_apply_steal=observe_apply_valid && !observed_invalid && observed_allocation && !found_free;
    assign observe_retired_id={{(64-ID_WIDTH){1'b0}},id_r[victim]};
    assign observe_retired_generation=generation_r[victim];
    generate for(genvar observe_g=0;observe_g<32;observe_g=observe_g+1) begin: observe_reclaims
        assign observe_reclaim_mask[observe_g]=!rst && done_mask[observe_g] &&
            valid_r[observe_g] && !gate_r[observe_g] &&
            done_ids[observe_g*64 +:64]=={{(64-ID_WIDTH){1'b0}},id_r[observe_g]};
        assign observe_reclaim_generations[observe_g*16+:16]=generation_r[observe_g];
    end endgenerate
    always @* begin
        victim=0;found_free=0;found_release=0;
        lowest_level=17'h1ffff;oldest_age={64{1'b1}};
        target=0;found_target=0;id_collision=0;token_collision=0;
        reclaim_delta=0;
        // Fixed ascending slot order resolves otherwise exact ties.
        for (j=0;j<32;j=j+1) begin
            if (!valid_r[j] && !found_free) begin victim=j;found_free=1;end
            if (valid_r[j] && id_r[j]==next_id) id_collision=1;
            if (done_mask[j] && valid_r[j] && !gate_r[j] &&
                done_ids[j*64 +:64]=={{(64-ID_WIDTH){1'b0}},id_r[j]})
                reclaim_delta=reclaim_delta+1'b1;
            if (valid_r[j] && gate_r[j] && source_r[j]==source &&
                key_r[j]==key && token_r[j]==item_token) begin
                target=j;found_target=1;
                if (kind==1) token_collision=1;
            end
        end
        if (!found_free) begin
            for (j=0;j<32;j=j+1)
                if (valid_r[j] && !gate_r[j] &&
                    (!found_release || current_levels[j*17 +:17]<lowest_level ||
                    (current_levels[j*17 +:17]==lowest_level && age_r[j]<oldest_age))) begin
                    victim=j;found_release=1;
                    lowest_level=current_levels[j*17 +:17];oldest_age=age_r[j];
                end
            if (!found_release) begin
                oldest_age={64{1'b1}};
                for (j=0;j<32;j=j+1)
                    if (valid_r[j] && age_r[j]<oldest_age) begin
                        victim=j;oldest_age=age_r[j];
                    end
            end
        end
    end
    genvar g;
    generate for (g=0;g<32;g=g+1) begin : pack_slots
        // A working-bank allocation may not yet be published. Its envelope
        // starts at zero; feedback for the previous visible owner is unrelated.
        assign current_levels[g*17 +:17]=
            (id_r[g]==visible_id[g] &&
             generation_r[g]==visible_generation[g]) ?
            envelope_levels[g*17 +:17] : 17'd0;
        // Same-edge allocation wins over old issue/writeback in the synth.
        assign slot_cancel[g]=!rst && busy && lane==9 &&
            (id_r[g]!=visible_id[g] ||
             generation_r[g]!=visible_generation[g]);
        assign slot_valid[g]=visible_valid[g];
        assign slot_gate[g]=visible_gate[g];
        assign slot_trigger[g]=visible_trigger[g];
        assign slot_notes[g*7 +:7]=visible_note[g];
        assign slot_pressures[g*8 +:8]=visible_pressure[g];
        assign slot_ids[g*64 +:64]={{(64-ID_WIDTH){1'b0}},visible_id[g]};
        assign slot_generations[g*16 +:16]=visible_generation[g];
        assign slot_timbres[g*3 +:3]=visible_timbre[g];
        assign observe_sources[g*4 +:4]=visible_source[g];
        assign observe_keys[g*8 +:8]=visible_key[g];
        assign observe_tokens[g*64 +:64]=visible_token_observe[g];
    end endgenerate
    always @(posedge clk) begin
        if (rst) begin
            busy<=0;lane<=0;packet<=0;next_id<=1;wrap_holdoff<=0;age_counter<=0;
            vibrato_depth<=0;vib_work<=0;protocol_error<=0;
            steal_count<=0;stale_count<=0;allocation_count<=0;reclaim_count<=0;
            id_collision_skip_count<=0;id_wrap_count<=0;
            for (i=0;i<32;i=i+1) begin
                valid_r[i]<=0;gate_r[i]<=0;trigger_r[i]<=0;
                timbre_r[i]<=0;visible_timbre[i]<=0;
                note_r[i]<=0;pressure_r[i]<=0;source_r[i]<=0;key_r[i]<=0;
                token_r[i]<=0;id_r[i]<=0;generation_r[i]<=0;age_r[i]<=0;
                visible_valid[i]<=0;visible_gate[i]<=0;visible_trigger[i]<=0;
                visible_note[i]<=0;visible_pressure[i]<=0;
                visible_source[i]<=0;visible_key[i]<=0;
                visible_id[i]<=0;visible_generation[i]<=0;
                visible_token_observe[i]<=0;
            end
        end else begin
            if (wrap_holdoff!=0) wrap_holdoff<=wrap_holdoff-1'b1;
            if (busy && lane==9) begin
                busy<=0;
                vibrato_depth<=vib_work;
                for (i=0;i<32;i=i+1) begin
                    visible_valid[i]<=valid_r[i];visible_gate[i]<=gate_r[i];
                    visible_trigger[i]<=trigger_r[i];
                    visible_note[i]<=note_r[i];
                    visible_pressure[i]<=pressure_r[i];
                    visible_source[i]<=source_r[i];
                    visible_key[i]<=key_r[i];
                    visible_id[i]<=id_r[i];
                    visible_generation[i]<=generation_r[i];
                    visible_timbre[i]<=timbre_r[i];
                    visible_token_observe[i]<=token_r[i];
                end
            end
            if (sample_tick) for (i=0;i<32;i=i+1) begin
                // A just-committed new instance missed this tick's snapshot;
                // preserve its trigger for the following tick.
                if (!(busy && lane==9 &&
                      (id_r[i]!=visible_id[i] ||
                       generation_r[i]!=visible_generation[i])))
                    visible_trigger[i]<=0;
                if (id_r[i]==visible_id[i] &&
                    generation_r[i]==visible_generation[i])
                    trigger_r[i]<=0;
            end
            if (reclaim_delta!=0) reclaim_count<=reclaim_count+reclaim_delta;
            for (i=0;i<32;i=i+1)
                if (done_mask[i] && valid_r[i] && !gate_r[i] &&
                    done_ids[i*64 +:64]=={{(64-ID_WIDTH){1'b0}},id_r[i]}) begin
                    valid_r[i]<=0;
                end
            for (i=0;i<32;i=i+1)
                if (done_mask[i] && visible_valid[i] && !visible_gate[i] &&
                    done_ids[i*64 +:64]=={{(64-ID_WIDTH){1'b0}},visible_id[i]} &&
                    !(busy && lane==9 &&
                      (id_r[i]!=visible_id[i] ||
                       generation_r[i]!=visible_generation[i])))
                    visible_valid[i]<=0;
            if (panic || protocol_error) begin
                for (i=0;i<32;i=i+1) begin
                    gate_r[i]<=0;trigger_r[i]<=0;
                    visible_gate[i]<=0;visible_trigger[i]<=0;
                end
                busy<=0;
            end else if (!busy) begin
                if (event_valid) begin
                    if (event_packet[872:864]==0) protocol_error<=1;
                    else begin
                        packet<=event_packet;busy<=1;
                        lane<=first_set(event_packet[872:864],0);
                    end
                end
            end else if (lane==9) begin end
            else if (!lane_enabled) lane<=next_lane;
            else if (event_word[0] || (kind<1 || kind>4) ||
                     (kind==4 && (key!=8'hff || note!=0)) ||
                     (kind!=4 && item_token==0)) begin
                protocol_error<=1;busy<=0;
            end else if (kind==1) begin
                if (token_collision) begin
                    stale_count<=stale_count+1'b1;lane<=next_lane;
                end else if (wrap_holdoff!=0) begin
                    // No new ID is issued until every old pipeline task drains.
                end else if (next_id==0 || id_collision) begin
                    next_id<=after_id;
                    id_collision_skip_count<=id_collision_skip_count+1'b1;
                    if (next_id=={ID_WIDTH{1'b1}}) begin
                        id_wrap_count<=id_wrap_count+1'b1;wrap_holdoff<=6'd40;
                    end
                end else begin
                    valid_r[victim]<=1;gate_r[victim]<=1;trigger_r[victim]<=1;
                    source_r[victim]<=source;key_r[victim]<=key;
                    token_r[victim]<=item_token;note_r[victim]<=note;
                    pressure_r[victim]<=value;id_r[victim]<=next_id;
                    timbre_r[victim]<=timbre_id;
                    generation_r[victim]<=generation_r[victim]+1'b1;
                    age_r[victim]<=age_counter;age_counter<=age_counter+1'b1;
                    allocation_count<=allocation_count+1'b1;
                    if (!found_free) steal_count<=steal_count+1'b1;
                    next_id<=after_id;
                    if (next_id=={ID_WIDTH{1'b1}}) begin
                        id_wrap_count<=id_wrap_count+1'b1;wrap_holdoff<=6'd40;
                    end
                    lane<=next_lane;
                end
            end else if (kind==4) begin
                vib_work<=value;lane<=next_lane;
            end else begin
                if (found_target) begin
                    if (kind==2) gate_r[target]<=0;
                    else begin note_r[target]<=note;pressure_r[target]<=value;end
                end else stale_count<=stale_count+1'b1;
                lane<=next_lane;
            end
        end
    end
    // synthesis translate_off
    initial if (ID_WIDTH<6 || ID_WIDTH>64) $fatal(1,"ID_WIDTH must be 6..64");
    always @(posedge clk) if (!rst && busy && lane<9 && lane_enabled &&
        kind==1 && !id_collision && next_id!=0 && !token_collision &&
        valid_r[victim] && found_free) $fatal(1,"allocator free-slot selection invalid");
    // synthesis translate_on
endmodule
