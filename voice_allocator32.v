// One system-clock event per cycle from a latched nine-lane batch.
// NOTE_OFF and expression match source/key/press_token, never pitch.
// Instance zero is invalid. ID_WIDTH can be reduced in TB to exercise wrap.
module voice_allocator32 #(parameter integer ID_WIDTH=64, ONE_RECLAIM_PER_LANE=0) (
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
    // Four-state equality, factored into independent four-bit groups.
    // A known mismatch in any group still resolves the result to zero even
    // when another group is unknown, exactly as Verilog logical equality.
    function equal64(input [63:0] a,b);
        reg [15:0] matched;integer c;
        begin for(c=0;c<16;c=c+1)matched[c]=(a[c*4+:4]==b[c*4+:4]);equal64=&matched;end
    endfunction
    function equal16(input [15:0] a,b);
        reg [3:0] matched;integer c;
        begin for(c=0;c<4;c=c+1)matched[c]=(a[c*4+:4]==b[c*4+:4]);equal16=&matched;end
    endfunction
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
    // Exact ordering index for all 32 stored {age,slot} pairs. Full ages are
    // retained for insertion and 64-bit wrap; only the winner tree uses rank.
    reg [4:0] age_rank[0:31];
    // Exact numeric frontier of the monotonically incremented age counter.
    // All full ages are retained; equality handles arbitrary 64-bit reuse.
    reg [31:0] age_before_counter;
    wire age_counter_wrap=&age_counter;
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
    reg [4:0] victim, target;
    reg found_free, found_release, found_target, id_collision, token_collision;
    reg [16:0] lowest_level;
    reg [63:0] oldest_age;
    reg [5:0] reclaim_delta;
    integer i,j;
    wire [543:0] current_levels;
    wire [ID_WIDTH-1:0] after_id=(next_id=={ID_WIDTH{1'b1}}) ?
        {{(ID_WIDTH-1){1'b0}},1'b1} : next_id+1'b1;
    wire [15:0] allocation_generation=generation_r[victim]+1'b1;
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
    assign observe_apply_generation=kind==1?allocation_generation:
        ((kind==4 || !found_target)?16'd0:generation_r[target]);
    assign observe_apply_timbre=kind==1?timbre_id:
        ((kind==4 || !found_target)?3'd0:timbre_r[target]);
    assign observe_apply_steal=observe_apply_valid && !observed_invalid && observed_allocation && !found_free;
    assign observe_retired_id={{(64-ID_WIDTH){1'b0}},id_r[victim]};
    assign observe_retired_generation=generation_r[victim];
    wire [31:0] working_reclaim_match,visible_reclaim_match;
    generate if(ONE_RECLAIM_PER_LANE)begin: lane_reclaim_queries
        for(genvar l=0;l<4;l=l+1)begin: lane
            reg [2:0] selected;
            always @*begin selected=0;for(integer s=0;s<8;s=s+1)if(done_mask[l*8+s])selected=s;end
            wire [63:0] event_id=done_ids[(l*8+selected)*64+:64];
            wire work_match=equal64(event_id,{{(64-ID_WIDTH){1'b0}},id_r[l*8+selected]});
            wire public_match=equal64(event_id,{{(64-ID_WIDTH){1'b0}},visible_id[l*8+selected]});
            assign working_reclaim_match[l*8+:8]={8{work_match}};
            assign visible_reclaim_match[l*8+:8]={8{public_match}};
            // synthesis translate_off
            always @(posedge clk)if(!rst && !$onehot0(done_mask[l*8+:8]))
                $fatal(1,"ALLOCATOR_RECLAIM_MULTI_PER_LANE");
            // synthesis translate_on
        end
    end else begin: arbitrary_reclaim_queries
        for(genvar s=0;s<32;s=s+1)begin: slot
            assign working_reclaim_match[s]=equal64(done_ids[s*64+:64],{{(64-ID_WIDTH){1'b0}},id_r[s]});
            assign visible_reclaim_match[s]=equal64(done_ids[s*64+:64],{{(64-ID_WIDTH){1'b0}},visible_id[s]});
        end
    end endgenerate
    generate for(genvar observe_g=0;observe_g<32;observe_g=observe_g+1) begin: observe_reclaims
        assign observe_reclaim_mask[observe_g]=!rst && done_mask[observe_g] &&
            valid_r[observe_g] && !gate_r[observe_g] &&
            working_reclaim_match[observe_g];
        assign observe_reclaim_generations[observe_g*16+:16]=generation_r[observe_g];
    end endgenerate
    // Exact ascending-slot winner: free first, then lowest release
    // envelope/oldest age, then oldest sustained age. Ties use the lowest slot.
    // Full 64-bit ages and identities remain intact. A balanced tree shares
    // the same age comparison for release and sustained candidates.
    wire [28:0] choice_key[0:62];
    wire [5:0] reclaim_sum[0:62];
    wire [31:0] matching_target,matching_id;
    generate for(genvar c=0;c<32;c=c+1)begin: select_leaf
        localparam [4:0] SLOT=c;
        wire [1:0] priority_class=!valid_r[c]?2'd0:(!gate_r[c]?2'd1:2'd2);
        assign choice_key[c+31]={priority_class,
            (!valid_r[c] || gate_r[c])?17'd0:current_levels[c*17+:17],
            valid_r[c]?age_rank[c]:5'd0,SLOT};
        assign reclaim_sum[c+31]={5'd0,observe_reclaim_mask[c]};
        assign matching_target[c]=valid_r[c] && gate_r[c] && source_r[c]==source &&
            key_r[c]==key && equal64(token_r[c],item_token);
        assign matching_id[c]=valid_r[c] && equal64(id_r[c],next_id);
    end
    for(genvar c=0;c<31;c=c+1)begin: select_node
        assign choice_key[c]=(choice_key[c*2+1]<=choice_key[c*2+2])?
            choice_key[c*2+1]:choice_key[c*2+2];
        assign reclaim_sum[c]=reclaim_sum[c*2+1]+reclaim_sum[c*2+2];
    end endgenerate
    always @*begin
        victim=choice_key[0][4:0];found_free=choice_key[0][28:27]==0;
        found_release=!found_free && choice_key[0][28:27]==1;
        lowest_level=choice_key[0][26:10];oldest_age=age_r[victim];
        target=0;found_target=|matching_target;id_collision=|matching_id;
        token_collision=(kind==1) && found_target;reclaim_delta=reclaim_sum[0];
        // The original matching loop used the last matching slot.
        for(integer c=0;c<32;c=c+1)if(matching_target[c])target=c;
    end
    genvar g;
    generate for (g=0;g<32;g=g+1) begin : pack_slots
        // A working-bank allocation may not yet be published. Its envelope
        // starts at zero; feedback for the previous visible owner is unrelated.
        assign current_levels[g*17 +:17]=
            (equal64(id_r[g],visible_id[g]) &&
             equal16(generation_r[g],visible_generation[g])) ?
            envelope_levels[g*17 +:17] : 17'd0;
        // Same-edge allocation wins over old issue/writeback in the synth.
        assign slot_cancel[g]=!rst && busy && lane==9 &&
            (!equal64(id_r[g],visible_id[g]) ||
             !equal16(generation_r[g],visible_generation[g]));
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
    wire allocation_fire=observe_apply_valid && !observed_invalid && observed_allocation;
    wire off_fire=observe_apply_valid && !observed_invalid && kind==2 && found_target;
    wire expression_fire=observe_apply_valid && !observed_invalid && kind==3 && found_target;
    // Remove victim from the old total order, insert the new exact age,
    // then compact ranks. This holds across age-counter wrap and duplicate
    // age values; equal ages retain ascending-slot priority.
    wire [31:0] before_new_age;
    wire [5:0] insertion_count[0:62];
    wire [4:0] removed_rank=age_rank[victim];
    generate for(genvar a=0;a<32;a=a+1)begin: age_order_leaf
        wire age_at_counter=equal64(age_r[a],age_counter);
        assign before_new_age[a]=age_before_counter[a] || (age_at_counter && a<victim);
        always @(posedge clk)begin
            if(rst)age_before_counter[a]<=0;
            else if(allocation_fire)begin
                if(age_counter_wrap)age_before_counter[a]<=0;
                else age_before_counter[a]<=a==victim || age_before_counter[a] || age_at_counter;
            end
        end
        assign insertion_count[a+31]={5'd0,before_new_age[a] && a!=victim};
        always @(posedge clk)begin
            if(rst)age_rank[a]<=a;
            else if(allocation_fire)begin
                if(a==victim)age_rank[a]<=insertion_count[0][4:0];
                else age_rank[a]<=age_rank[a]-(age_rank[a]>removed_rank?5'd1:5'd0)+
                    (before_new_age[a]?5'd0:5'd1);
            end
        end
    end
    for(genvar a=0;a<31;a=a+1)begin: age_order_sum
        assign insertion_count[a]=insertion_count[a*2+1]+insertion_count[a*2+2];
    end endgenerate
    // Fixed slot ownership and write enables. These priorities match the original
    // working/visible nonblocking updates, including publication/reclaim/tick races.
    generate for(genvar s=0;s<32;s=s+1)begin: update_slots
        wire publish_new=busy && lane==9 &&
            (!equal64(id_r[s],visible_id[s]) || !equal16(generation_r[s],visible_generation[s]));
        always @(posedge clk)begin
            if(rst)begin
                valid_r[s]<=0;gate_r[s]<=0;trigger_r[s]<=0;
                timbre_r[s]<=0;visible_timbre[s]<=0;
                note_r[s]<=0;pressure_r[s]<=0;source_r[s]<=0;key_r[s]<=0;
                token_r[s]<=0;id_r[s]<=0;generation_r[s]<=0;age_r[s]<=0;
                visible_valid[s]<=0;visible_gate[s]<=0;visible_trigger[s]<=0;
                visible_note[s]<=0;visible_pressure[s]<=0;
                visible_source[s]<=0;visible_key[s]<=0;
                visible_id[s]<=0;visible_generation[s]<=0;visible_token_observe[s]<=0;
            end else begin
                if(busy && lane==9)begin
                    visible_valid[s]<=valid_r[s];visible_gate[s]<=gate_r[s];
                    visible_trigger[s]<=trigger_r[s];visible_note[s]<=note_r[s];
                    visible_pressure[s]<=pressure_r[s];visible_source[s]<=source_r[s];
                    visible_key[s]<=key_r[s];visible_id[s]<=id_r[s];
                    visible_generation[s]<=generation_r[s];visible_timbre[s]<=timbre_r[s];
                    visible_token_observe[s]<=token_r[s];
                end
                if(sample_tick)begin
                    if(!publish_new)visible_trigger[s]<=0;
                    if(equal64(id_r[s],visible_id[s]) && equal16(generation_r[s],visible_generation[s]))trigger_r[s]<=0;
                end
                if(observe_reclaim_mask[s])valid_r[s]<=0;
                if(done_mask[s] && visible_valid[s] && !visible_gate[s] &&
                   visible_reclaim_match[s] && !publish_new)
                    visible_valid[s]<=0;
                if(panic || protocol_error)begin
                    gate_r[s]<=0;trigger_r[s]<=0;visible_gate[s]<=0;visible_trigger[s]<=0;
                end else begin
                    if(allocation_fire && victim==s)begin
                        valid_r[s]<=1;gate_r[s]<=1;trigger_r[s]<=1;
                        source_r[s]<=source;key_r[s]<=key;token_r[s]<=item_token;
                        note_r[s]<=note;pressure_r[s]<=value;id_r[s]<=next_id;
                        timbre_r[s]<=timbre_id;generation_r[s]<=allocation_generation;age_r[s]<=age_counter;
                    end
                    if(off_fire && target==s)gate_r[s]<=0;
                    if(expression_fire && target==s)begin note_r[s]<=note;pressure_r[s]<=value;end
                end
            end
        end
    end endgenerate
    always @(posedge clk)begin
        if(rst)begin
            busy<=0;lane<=0;packet<=0;next_id<=1;wrap_holdoff<=0;age_counter<=0;
            vibrato_depth<=0;vib_work<=0;protocol_error<=0;
            steal_count<=0;stale_count<=0;allocation_count<=0;reclaim_count<=0;
            id_collision_skip_count<=0;id_wrap_count<=0;
        end else begin
            if(wrap_holdoff!=0)wrap_holdoff<=wrap_holdoff-1'b1;
            if(busy && lane==9)begin busy<=0;vibrato_depth<=vib_work;end
            if(reclaim_delta!=0)reclaim_count<=reclaim_count+reclaim_delta;
            if(panic || protocol_error)busy<=0;
            else if(!busy)begin
                if(event_valid)begin
                    if(event_packet[872:864]==0)protocol_error<=1;
                    else begin packet<=event_packet;busy<=1;lane<=first_set(event_packet[872:864],0);end
                end
            end else if(lane==9)begin end
            else if(!lane_enabled)lane<=next_lane;
            else if(observed_invalid)begin protocol_error<=1;busy<=0;end
            else if(kind==1)begin
                if(token_collision)begin stale_count<=stale_count+1'b1;lane<=next_lane;end
                else if(wrap_holdoff!=0)begin end
                else if(next_id==0 || id_collision)begin
                    next_id<=after_id;id_collision_skip_count<=id_collision_skip_count+1'b1;
                    if(next_id=={ID_WIDTH{1'b1}})begin id_wrap_count<=id_wrap_count+1'b1;wrap_holdoff<=6'd40;end
                end else begin
                    age_counter<=age_counter+1'b1;allocation_count<=allocation_count+1'b1;
                    if(!found_free)steal_count<=steal_count+1'b1;
                    next_id<=after_id;
                    if(next_id=={ID_WIDTH{1'b1}})begin id_wrap_count<=id_wrap_count+1'b1;wrap_holdoff<=6'd40;end
                    lane<=next_lane;
                end
            end else if(kind==4)begin vib_work<=value;lane<=next_lane;end
            else begin if(!found_target)stale_count<=stale_count+1'b1;lane<=next_lane;end
        end
    end
    // synthesis translate_off
    initial if (ID_WIDTH<6 || ID_WIDTH>64) $fatal(1,"ID_WIDTH must be 6..64");
    always @(posedge clk) if (!rst && busy && lane<9 && lane_enabled &&
        kind==1 && !id_collision && next_id!=0 && !token_collision &&
        valid_r[victim] && found_free) $fatal(1,"allocator free-slot selection invalid");
    // synthesis translate_on
endmodule
