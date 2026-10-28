// Eight-bank, four-row event search followed by registered winner reduction.
// NOTE_OFF and expression match source/key/press_token, never pitch.
// Instance zero is invalid. ID_WIDTH can be reduced in TB to exercise wrap.
module voice_allocator32 #(parameter integer ID_WIDTH=64, ONE_RECLAIM_PER_LANE=0, INDEXED_INPUT=0, VERSIONED_TOKENS=0) (

    input wire token_snapshot_capture,token_snapshot_read,
    input wire [4:0] token_snapshot_slot,
    output wire [63:0] token_snapshot_data,
    input wire clk, rst, panic, sample_tick,
    input wire event_valid,
    output wire event_ready,
    input wire [904:0] event_packet,
    input wire [95:0] event_item,
    output wire [3:0] event_item_index,
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
    output wire [31:0] observe_working_public_equal,
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
    // Four-state equality, factored into explicitly retained two-bit groups.
    // A known mismatch in any group still resolves the result to zero even
    // when another group is unknown, exactly as Verilog logical equality.
    function equal64(input [63:0] a,b);
        reg [31:0] matched /* synthesis syn_keep=1 */;integer c;
        begin for(c=0;c<32;c=c+1)matched[c]=(a[c*2+:2]==b[c*2+:2]);equal64=&matched;end
    endfunction
    function equal16(input [15:0] a,b);
        reg [7:0] matched /* synthesis syn_keep=1 */;integer c;
        begin for(c=0;c<8;c=c+1)matched[c]=(a[c*2+:2]==b[c*2+:2]);equal16=&matched;end
    endfunction
    reg [31:0] working_visible_equal;
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
    reg [63:0] token_r[0:31];
    wire [63:0] age_r[0:31];
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
    // The synchronous word read is requested on the accept/apply edge.
    // Thus phase0 already owns the current word, including first/sparse cells.
    assign event_item_index=!busy?first_set(event_packet[872:864],0):
        ((observe_apply_valid && next_lane<9)?next_lane:lane);
    wire [95:0] item=INDEXED_INPUT ? event_item:packet[lane*96 +: 96];
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
    // State preparation stage: full generation remains in generation_r.
    // Prefix carries describe THAT exact generation and are updated on its
    // original write edge. Parallel four-bit increments precede slot selection.
    wire allocation_fire;
    wire decision_ready,early_collision_retry;
    reg [2:0] generation_carry[0:31];
    wire [15:0] generation_increment[0:31];
    generate for(genvar s=0;s<32;s=s+1)begin: prepare_generation
        assign generation_increment[s]={
            4'(generation_r[s][15:12]+generation_carry[s][2]),
            4'(generation_r[s][11:8]+generation_carry[s][1]),
            4'(generation_r[s][7:4]+generation_carry[s][0]),
            4'(generation_r[s][3:0]+4'd1)};
        always @(posedge clk)begin
            if(rst)generation_carry[s]<=0;
            else if(allocation_fire&&victim==s)begin
                generation_carry[s][0]<=generation_r[s][3:0]==4'he;
                generation_carry[s][1]<=generation_r[s][7:0]==8'hfe;
                generation_carry[s][2]<=generation_r[s][11:0]==12'hffe;
            end
        end
        // synthesis translate_off
        always @(posedge clk)begin #1;if(!rst)begin
            if(generation_carry[s]!=={&generation_r[s][11:0],&generation_r[s][7:0],&generation_r[s][3:0]} ||
               generation_increment[s]!==16'(generation_r[s]+16'd1))
                $fatal(1,"ALLOCATOR_PREPARED_GENERATION slot=%0d",s);
        end end
        // synthesis translate_on
    end endgenerate
    wire [15:0] allocation_generation=generation_increment[victim];
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
        (panic || protocol_error || (lane<9 && lane_enabled && decision_ready && observed_invalid));
    assign observe_apply_valid=!rst && !panic && !protocol_error && busy &&
        lane<9 && lane_enabled && decision_ready && (observed_invalid || kind!=1 ||
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
    // Each event captures one coherent envelope view. Working ownership
    // cannot change except for reclaim while this search is in flight.
    // Reclaim is serviced immediately and restarts the bounded search;
    // no retired owner can survive into an apply decision.
    reg [3:0] decision_phase;
    reg [543:0] decision_levels;
    wire restart_search=|observe_reclaim_mask;
    // Local key directory is a validated lookup cache, never an identity
    // replacement. Full64-bit gesture tokens remain in working slot state.
    // A miss (including a historical gesture) uses the complete bank search.
    reg [68:0] local_target_cache[0:7] /* synthesis syn_ramstyle="distributed_ram" */;
    reg [7:0] local_target_valid;
    wire [68:0] local_lookup=local_target_cache[key[2:0]];
    wire [4:0] local_lookup_slot=local_lookup[4:0];
    wire local_target_hit=(kind==2 || kind==3) && source==0 && key<8 &&
        local_target_valid[key[2:0]] && valid_r[local_lookup_slot] &&
        gate_r[local_lookup_slot] && equal64(local_lookup[68:5],item_token);
    always @(posedge clk)
        if(!rst && allocation_fire && source==0 && key<8)
            local_target_cache[key[2:0]]<={item_token,victim};
    generate for(genvar k=0;k<8;k=k+1)begin: local_target_entry
        always @(posedge clk)begin
            if(rst)local_target_valid[k]<=0;
            else if(allocation_fire)begin
                if(local_target_cache[k][4:0]==victim)local_target_valid[k]<=0;
                if(source==0 && key==k)local_target_valid[k]<=1;
            end

        end
        // synthesis translate_off
        always @(posedge clk)begin #1;
            if(!rst && local_target_valid[k] && valid_r[local_target_cache[k][4:0]] &&
               gate_r[local_target_cache[k][4:0]] &&
               (source_r[local_target_cache[k][4:0]]!=0 ||
                key_r[local_target_cache[k][4:0]]!=k ||
                token_r[local_target_cache[k][4:0]]!==local_target_cache[k][68:5]))
                $fatal(1,"ALLOCATOR_LOCAL_CACHE_OWNER");
        end
        // synthesis translate_on
    end endgenerate
    // Only NOTE_ON needs victim ranking and ID collision reduction.
    // OFF/expression require all four target-search rows, but no victim tree.
    // Vibrato consumes no slot state; phase0 supplies the indexed-read fence.
    assign decision_ready=early_collision_retry || (!restart_search &&
        ((kind==4 && decision_phase==0) ||
         (local_target_hit && decision_phase==0) ||
         ((kind==2 || kind==3) && decision_phase==5) ||
         ((kind!=2 && kind!=3 && kind!=4) && decision_phase==8)));
    // At phase5 the complete identity and token lookup is already valid.
    // A colliding ID cannot allocate, so victim reduction has no consumer.
    // Retry before that reduction; do not change token/invalid precedence.
    assign early_collision_retry=!rst && !panic && !protocol_error && busy &&
        lane<9 && lane_enabled && !restart_search && decision_phase==5 &&
        kind==1 && !observed_invalid && !token_collision && wrap_holdoff==0 &&
        (next_id==0 || id_collision);
    wire [1:0] search_row=decision_phase[1:0]-2'd1;
    wire [511:0] token_search;
    generate if(VERSIONED_TOKENS)begin: shared_token_versions
        r13_token_version_bram_store store(.read_snapshot(token_snapshot_read),.clk(clk),.rst(rst),.allocate(allocation_fire),
            .publish(busy&&lane==9),.capture(token_snapshot_capture),
            .write_slot(victim),.snapshot_slot(token_snapshot_slot),.write_token(item_token),
            .search_row(search_row),.search_tokens(token_search),.snapshot_token(token_snapshot_data));
        // Existing copy-state below becomes an independent simulation oracle;
        // all formal consumers use RAM queries, so no redundant payload flops
        // survive synthesis. The legacy wide observe_tokens tap is constant.
        // synthesis translate_off
        reg [63:0] frozen_token_oracle[0:31];reg frozen_token_valid;
        reg [63:0] expected_token_response;
        always @(posedge clk)begin
            if(rst)frozen_token_valid<=0;
            else if(token_snapshot_capture)begin
                frozen_token_valid<=1;
                for(integer s=0;s<32;s=s+1)frozen_token_oracle[s]<=visible_token_observe[s];
            end
            if(!rst && token_snapshot_read)
                expected_token_response<=frozen_token_valid?frozen_token_oracle[token_snapshot_slot]:64'd0;
            #1;if(!rst)begin
                for(integer b=0;b<8;b=b+1)
                    if(token_search[b*64+:64]!==token_r[b*4+search_row])$fatal(1,"TOKEN_REAL_ALLOCATOR_SEARCH b=%0d",b);
                if(token_snapshot_read && token_snapshot_data!==expected_token_response)
                    $fatal(1,"TOKEN_REAL_START_HISTORY slot=%0d",token_snapshot_slot);
            end
        end
        // synthesis translate_on
    end else begin: legacy_token_copies
        assign token_search=0;assign token_snapshot_data=0;
    end endgenerate
    reg [87:0] bank_best[0:7];
    // The eight search comparators also perform the three reduction rounds.
    // Phase5 merges 0/1,2/3,4/5,6/7; phase6 merges0/2 and4/6; phase7 merges0/4.
    // Winners replace the left bank in place. No extra clocks or rank truncation.
    reg [87:0] reduce_one;
    always @*reduce_one=bank_best[0];
    reg [7:0] bank_target_found,bank_id_found;
    reg [4:0] bank_target[0:7];
    wire [5:0] reclaim_sum[0:62];
    generate for(genvar b=0;b<8;b=b+1)begin: search_bank
        reg [63:0] ages[0:3] /* synthesis syn_ramstyle="distributed_ram" */;
        reg [3:0] initialized;
        wire [4:0] slot={3'(b),search_row};
        wire [1:0] priority_class=!valid_r[slot]?2'd0:(!gate_r[slot]?2'd1:2'd2);
        wire [63:0] selected_age=initialized[search_row]?ages[search_row]:64'd0;
        wire [87:0] key_value={priority_class,
            (!valid_r[slot] || gate_r[slot])?17'd0:decision_levels[slot*17+:17],
            valid_r[slot]?selected_age:64'd0,slot};
        wire [87:0] comparison_key;
        if(b==0)begin
            assign comparison_key=decision_phase==5?bank_best[1]:decision_phase==6?bank_best[2]:decision_phase==7?bank_best[4]:key_value;
        end else if(b==4)begin
            assign comparison_key=decision_phase==5?bank_best[5]:decision_phase==6?bank_best[6]:key_value;
        end else if(b==2 || b==6)begin
            assign comparison_key=decision_phase==5?bank_best[b+1]:key_value;
        end else assign comparison_key=key_value;
        wire compare_enable=(decision_phase>=1 && decision_phase<=4) ||
            (decision_phase==5 && (b%2)==0) ||
            (decision_phase==6 && (b%4)==0) || (decision_phase==7 && b==0);
        wire take_rhs;
        r14_unsigned88_dsp_less compare(.a(comparison_key),.b(bank_best[b]),.less(take_rhs));
        wire target_match=valid_r[slot] && gate_r[slot] && source_r[slot]==source &&
                          key_r[slot]==key && equal64(VERSIONED_TOKENS?token_search[b*64+:64]:token_r[slot],item_token);
        wire id_match=valid_r[slot] && equal64(id_r[slot],next_id);
        for(genvar r=0;r<4;r=r+1)begin: view
            assign age_r[b*4+r]=initialized[r]?ages[r]:64'd0;
        end
        always @(posedge clk)begin
            if(rst)initialized<=0;
            else if(allocation_fire && victim[4:2]==b)initialized[victim[1:0]]<=1;
            if(!rst && allocation_fire && victim[4:2]==b)ages[victim[1:0]]<=age_counter;
            if(rst || !busy || lane==9 || restart_search || decision_phase==0)begin
                bank_best[b]<={88{1'b1}};bank_target_found[b]<=0;
                bank_id_found[b]<=0;bank_target[b]<=0;
            end else begin
                if(compare_enable && take_rhs)bank_best[b]<=comparison_key;
                if(decision_phase>=1 && decision_phase<=4)begin
                    if(target_match)begin bank_target_found[b]<=1;bank_target[b]<=slot;end
                    if(id_match)bank_id_found[b]<=1;
                end
            end
        end
    end
    for(genvar s=0;s<32;s=s+1)begin: reclaim_leaf
        assign reclaim_sum[s+31]={5'd0,observe_reclaim_mask[s]};
    end
    for(genvar s=0;s<31;s=s+1)begin: reclaim_node
        assign reclaim_sum[s]=reclaim_sum[s*2+1]+reclaim_sum[s*2+2];
    end endgenerate
    always @(posedge clk)begin
        if(rst || panic || protocol_error || !busy || lane==9 || restart_search)begin
            decision_phase<=0;decision_levels<=0;

        end else if(observe_apply_valid || early_collision_retry)begin
            decision_phase<=0;
        end else begin
            case(decision_phase)
                0:begin decision_levels<=current_levels;decision_phase<=1;end
                1,2,3,4:decision_phase<=decision_phase+1'b1;
                5:decision_phase<=6;
                6:decision_phase<=7;
                7:decision_phase<=8;
                8:if(observe_apply_valid || (kind==1 && wrap_holdoff==0))decision_phase<=0;
            endcase
        end
    end
    always @*begin
        victim=reduce_one[4:0];found_free=reduce_one[87:86]==0;
        found_release=reduce_one[87:86]==1;
        lowest_level=reduce_one[85:69];oldest_age=reduce_one[68:5];
        target=0;found_target=|bank_target_found;id_collision=|bank_id_found;
        reclaim_delta=reclaim_sum[0];
        for(integer b=0;b<8;b++)if(bank_target_found[b])target=bank_target[b];
        if(local_target_hit)begin found_target=1;target=local_lookup_slot;end
        token_collision=(kind==1) && found_target;
    end
    // Independent full-state oracle at the decision edge. It uses the
    // captured envelope view, full 64-bit ages and original ascending tie
    // semantics; it does not use the bank winners or their reductions.
    // synthesis translate_off
    reg [87:0] oracle_best,oracle_key;
    reg [4:0] oracle_target;reg oracle_found,oracle_collision;
    always @(posedge clk)if(!rst && busy && decision_ready && lane<9 && !panic && !protocol_error)begin
        oracle_best={88{1'b1}};oracle_target=0;oracle_found=0;oracle_collision=0;
        for(integer s=0;s<32;s++)begin
            oracle_key={!valid_r[s]?2'd0:(!gate_r[s]?2'd1:2'd2),
              (!valid_r[s] || gate_r[s])?17'd0:decision_levels[s*17+:17],
              valid_r[s]?age_r[s]:64'd0,5'(s)};
            if(oracle_key<oracle_best)oracle_best=oracle_key;
            if(valid_r[s] && gate_r[s] && source_r[s]==source && key_r[s]==key && token_r[s]==item_token)begin oracle_found=1;oracle_target=s;end
            if(valid_r[s] && id_r[s]==next_id)oracle_collision=1;
        end
        if((kind==1 && ((!early_collision_retry && reduce_one!==oracle_best) || id_collision!==oracle_collision)) ||
           ((kind==1 || kind==2 || kind==3) &&
            (found_target!==oracle_found || (oracle_found && target!==oracle_target))))
            $fatal(1,"ALLOC_BANKED_DECISION_ORACLE");
    end
    always @(posedge clk)if(early_collision_retry)begin: check_early_collision
        bit collision,duplicate;
        collision=next_id==0;duplicate=0;
        for(integer s=0;s<32;s++)begin
            if(valid_r[s] && id_r[s]==next_id)collision=1;
            if(valid_r[s] && gate_r[s] && source_r[s]==source &&
               key_r[s]==key && token_r[s]==item_token)duplicate=1;
        end
        if(!collision || duplicate || observe_apply_valid)
            $fatal(1,"ALLOCATOR_EARLY_COLLISION_ORACLE");
    end
    // synthesis translate_on
    genvar g;
    generate for (g=0;g<32;g=g+1) begin : pack_slots
        // A working-bank allocation may not yet be published. Its envelope
        // starts at zero; feedback for the previous visible owner is unrelated.
        assign observe_working_public_equal[g]=working_visible_equal[g];
        assign current_levels[g*17 +:17]=
            (working_visible_equal[g]) ?
            envelope_levels[g*17 +:17] : 17'd0;
        // Same-edge allocation wins over old issue/writeback in the synth.
        assign slot_cancel[g]=!rst && busy && lane==9 &&
            (!working_visible_equal[g]);
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
        assign observe_tokens[g*64 +:64]=VERSIONED_TOKENS?64'd0:visible_token_observe[g];
    end endgenerate
    assign allocation_fire=observe_apply_valid && !observed_invalid && observed_allocation;
    // Working/public identity equality changes only at allocation, publish
    // and reset. Compute it once at the allocating slot's original write
    // edge, retaining exact full ID+generation matching even on wrap.
    // Thirty-two cached predicates replace thirty-two full comparators.
    // Speculate the equality DATA independently for every possible owner.
    // The late winner controls only the original slot write enable, avoiding
    // a winner -> 80-bit read mux -> full comparison feedback chain.
    generate for(genvar s=0;s<32;s=s+1)begin: version_match_state
        always @(posedge clk)begin
            if(rst)working_visible_equal[s]<=1;
            else begin
                if(busy&&lane==9)working_visible_equal[s]<=1;
                if(allocation_fire&&victim==s)working_visible_equal[s]<=equal64(next_id,visible_id[s]) && equal16(generation_increment[s],visible_generation[s]);
            end
        end
        // synthesis translate_off
        always @(posedge clk)begin #1;if(!rst && working_visible_equal[s] !==
            (equal64(id_r[s],visible_id[s])&&equal16(generation_r[s],visible_generation[s])))
             $fatal(1,"ALLOCATOR_VERSION_PREDICATE_MISMATCH slot=%0d",s);
        end
        // synthesis translate_on
    end endgenerate

    wire off_fire=observe_apply_valid && !observed_invalid && kind==2 && found_target;
    wire expression_fire=observe_apply_valid && !observed_invalid && kind==3 && found_target;
    // Fixed slot ownership and write enables. These priorities match the original
    // working/visible nonblocking updates, including publication/reclaim/tick races.
    generate for(genvar s=0;s<32;s=s+1)begin: update_slots
        wire publish_new=busy && lane==9 &&
            (!working_visible_equal[s]);
        always @(posedge clk)begin
            if(rst)begin
                valid_r[s]<=0;gate_r[s]<=0;trigger_r[s]<=0;
                timbre_r[s]<=0;visible_timbre[s]<=0;
                note_r[s]<=0;pressure_r[s]<=0;source_r[s]<=0;key_r[s]<=0;
                token_r[s]<=0;id_r[s]<=0;generation_r[s]<=0;
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
                    if(working_visible_equal[s])trigger_r[s]<=0;
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
                        timbre_r[s]<=timbre_id;generation_r[s]<=generation_increment[s];
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
                    else begin packet<=INDEXED_INPUT?{event_packet[904:864],864'd0}:event_packet;busy<=1;lane<=first_set(event_packet[872:864],0);end
                end
            end else if(lane==9)begin end
            else if(!lane_enabled)lane<=next_lane;
            else if(!decision_ready)begin end
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
        decision_ready && kind==1 && !id_collision && next_id!=0 && !token_collision &&
        valid_r[victim] && found_free) $fatal(1,"allocator free-slot selection invalid");
    // synthesis translate_on
endmodule

// Three independently pinned full-token versions. Eight existing search banks,
// two physical read mirrors; no payload copying at public/START boundaries.
module r13_token_version_store(
 input wire clk,rst,allocate,publish,capture,
 input wire [4:0] write_slot,snapshot_slot,
 input wire [63:0] write_token,
 input wire [1:0] search_row,
 output wire [511:0] search_tokens,
 output wire [63:0] snapshot_token
);
 reg [1:0] working[0:31],published[0:31],frozen[0:31];
 reg [31:0] working_valid,published_valid,frozen_valid;
 wire [1:0] public_write_version=published[write_slot];
 wire [1:0] frozen_write_version=frozen[write_slot];
 wire [1:0] free_version=(public_write_version!=0 && frozen_write_version!=0)?2'd0:
                         (public_write_version!=1 && frozen_write_version!=1)?2'd1:2'd2;
 always @(posedge clk)begin
  if(rst)begin
   working_valid<=0;published_valid<=0;frozen_valid<=0;
   for(integer s=0;s<32;s=s+1)begin working[s]<=0;published[s]<=0;frozen[s]<=0;end
  end else begin
   if(allocate)begin working[write_slot]<=free_version;working_valid[write_slot]<=1;end
   if(publish)begin
    published_valid<=working_valid;
    for(integer s=0;s<32;s=s+1)published[s]<=working[s];
   end
   if(capture)begin
    frozen_valid<=published_valid;
    for(integer s=0;s<32;s=s+1)frozen[s]<=published[s];
   end
  end
 end
 wire [63:0] frozen_words[0:7];
 generate for(genvar b=0;b<8;b=b+1)begin: bank
  wire wen=!rst && allocate && write_slot[4:2]==b;
  wire [3:0] wad={free_version,write_slot[1:0]};
  wire [4:0] search_slot={3'(b),search_row};
  wire [4:0] read_slot={3'(b),snapshot_slot[1:0]};
  wire [3:0] work_address={working[search_slot],search_row};
  wire [3:0] snapshot_address={frozen[read_slot],snapshot_slot[1:0]};
  wire [63:0] work_value,frozen_value;
  for(genvar n=0;n<16;n=n+1)begin: nibble
   RAM16SDP4 search_memory(.CLK(clk),.WRE(wen),.WAD(wad),.RAD(work_address),.DI(write_token[n*4+:4]),.DO(work_value[n*4+:4]));
   RAM16SDP4 snapshot_memory(.CLK(clk),.WRE(wen),.WAD(wad),.RAD(snapshot_address),.DI(write_token[n*4+:4]),.DO(frozen_value[n*4+:4]));
  end
  assign search_tokens[b*64+:64]=working_valid[search_slot]?work_value:64'd0;
  assign frozen_words[b]=frozen_valid[read_slot]?frozen_value:64'd0;
 end endgenerate
 assign snapshot_token=frozen_words[snapshot_slot[4:2]];
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(allocate && publish)$fatal(1,"TOKEN_ALLOCATE_PUBLISH_OVERLAP");
  if(allocate && (free_version==public_write_version || free_version==frozen_write_version))
   $fatal(1,"TOKEN_PINNED_VERSION_OVERWRITE");
 end
 // synthesis translate_on
endmodule

// Matched old data ownership, only the actual consumers exported.
module r13_token_copy_reference(
 input wire clk,rst,allocate,publish,capture,
 input wire [4:0] write_slot,snapshot_slot,
 input wire [63:0] write_token,
 input wire [1:0] search_row,
 output wire [511:0] search_tokens,
 output wire [63:0] snapshot_token
);
 reg [63:0] working[0:31],published[0:31],frozen[0:31];
 reg frozen_valid;
 always @(posedge clk)begin
  if(rst)begin
   frozen_valid<=0;
   for(integer s=0;s<32;s=s+1)begin working[s]<=0;published[s]<=0;end
  end else begin
   if(allocate)working[write_slot]<=write_token;
   if(publish)for(integer s=0;s<32;s=s+1)published[s]<=working[s];
   if(capture)begin frozen_valid<=1;for(integer s=0;s<32;s=s+1)frozen[s]<=published[s];end
  end
 end
 generate for(genvar b=0;b<8;b=b+1)begin: query
  assign search_tokens[b*64+:64]=working[{3'(b),search_row}];
 end endgenerate
 assign snapshot_token=frozen_valid?frozen[snapshot_slot]:64'd0;
endmodule

module r13_token_version_bram_store(
 input wire clk,rst,allocate,publish,capture,read_snapshot,
 input wire [4:0] write_slot,snapshot_slot,
 input wire [63:0] write_token,
 input wire [1:0] search_row,
 output wire [511:0] search_tokens,
 output wire [63:0] snapshot_token
);
 reg [1:0] working[0:31],published[0:31],frozen[0:31];
 reg [31:0] working_valid,published_valid,frozen_valid;
 wire [1:0] public_write_version=published[write_slot];
 wire [1:0] frozen_write_version=frozen[write_slot];
 wire [1:0] free_version=(public_write_version!=0 && frozen_write_version!=0)?2'd0:
                         (public_write_version!=1 && frozen_write_version!=1)?2'd1:2'd2;
 always @(posedge clk)begin
  if(rst)begin
   working_valid<=0;published_valid<=0;frozen_valid<=0;
   for(integer s=0;s<32;s=s+1)begin working[s]<=0;published[s]<=0;frozen[s]<=0;end
  end else begin
   if(allocate)begin working[write_slot]<=free_version;working_valid[write_slot]<=1;end
   if(publish)begin
    published_valid<=working_valid;
    for(integer s=0;s<32;s=s+1)published[s]<=working[s];
   end
   if(capture)begin
    frozen_valid<=published_valid;
    for(integer s=0;s<32;s=s+1)frozen[s]<=published[s];
   end
  end
 end
 reg [63:0] snapshot_memory[0:127] /* synthesis syn_ramstyle="block_ram" */;
 reg [63:0] snapshot_q;
 wire [6:0] snapshot_read_address={snapshot_slot[4:2],frozen[snapshot_slot],snapshot_slot[1:0]};
 wire [6:0] snapshot_write_address={write_slot[4:2],free_version,write_slot[1:0]};
 always @(posedge clk)begin
  if(!rst && allocate)snapshot_memory[snapshot_write_address]<=write_token;
  if(!rst && read_snapshot)snapshot_q<=frozen_valid[snapshot_slot]?snapshot_memory[snapshot_read_address]:64'd0;
 end
 generate for(genvar b=0;b<8;b=b+1)begin: bank
  wire wen=!rst && allocate && write_slot[4:2]==b;
  wire [3:0] wad={free_version,write_slot[1:0]};
  wire [4:0] search_slot={3'(b),search_row};
  wire [3:0] work_address={working[search_slot],search_row};
  wire [63:0] work_value;
  for(genvar n=0;n<16;n=n+1)begin: nibble
   RAM16SDP4 search_memory(.CLK(clk),.WRE(wen),.WAD(wad),.RAD(work_address),.DI(write_token[n*4+:4]),.DO(work_value[n*4+:4]));
  end
  assign search_tokens[b*64+:64]=working_valid[search_slot]?work_value:64'd0;

 end endgenerate
 assign snapshot_token=snapshot_q;
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(allocate && publish)$fatal(1,"TOKEN_ALLOCATE_PUBLISH_OVERLAP");
  if(allocate && (free_version==public_write_version || free_version==frozen_write_version))
   $fatal(1,"TOKEN_PINNED_VERSION_OVERWRITE");
 end
 // synthesis translate_on
endmodule

// Four parallel 22-bit unsigned subtractions in native DSP ALUs, followed
// by lexicographic selection. All88bits remain significant. No CASI/SIA
// fabric connection: those pins are reserved for dedicated DSP cascades.
module r14_unsigned88_dsp_less(input wire [87:0] a,b,output wire less);
 wire [3:0] lt,eq;
 for(genvar k=0;k<4;k=k+1)begin: chunk
  wire [47:0] difference;
  wire [10:0] equal_pairs /* synthesis syn_keep=1 */;
  for(genvar j=0;j<11;j=j+1)begin: equal_bits
   assign equal_pairs[j]=a[k*22+j*2+:2]==b[k*22+j*2+:2];
  end
  assign eq[k]=&equal_pairs;
  MULTALU27X18 #(.ADD_SUB_0(1'b0),.ADD_SUB_1(1'b1),.C_SEL(1'b1),.CASI_SEL(1'b0),.ACC_SEL(1'b0)) subtract(
   .DOUT(difference),.CASO(),.SOA(),.A({5'd0,a[k*22+:22]}),.B(18'd1),.C({26'd0,b[k*22+:22]}),
   .D(26'd0),.SIA(27'd0),.CASI(48'd0),.PSEL(1'b0),.ASEL(1'b0),.CSEL(1'b0),.CASISEL(1'b0),
   .PADDSUB(1'b0),.ACCSEL(1'b0),.ADDSUB(2'd0),.CLK(2'd0),.CE(2'd3),.RESET(2'd0));
  assign lt[k]=difference[47];
 end
 assign less=lt[3]|(eq[3]&lt[2])|(eq[3]&eq[2]&lt[1])|(eq[3]&eq[2]&eq[1]&lt[0]);
endmodule
