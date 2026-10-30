// Digital instrument core: already-digitized controls to PT8211 serial pins.
// All logic uses clk; rst is synchronous and HIGH active. No vendor IP.
// Voice tables and ADSR use 48 kHz, so the system audio rate is fixed at 48 kHz.
module instrument_core_stage7 #(
    parameter integer AUDIO_RATE_HZ=48000,
    // 1: native field tests use exact-bin oscillator frequencies (see osc_ii4_pitch_prepare).
    parameter integer TEST_LINEAR_ENABLE=1,
    parameter integer EXTERNAL_SCORE_RX=0,STREAM_PHONE=0,COMM_SEPARATE=0,
 parameter integer VERSIONED_TOKENS=0,
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer PRESSURE_PRENORMALIZED=0,
    parameter integer ADC_ZERO = 0,
    parameter integer ADC_FULL = 1023,
    parameter integer DEADZONE = 8,
    parameter integer PRESS_THRESHOLD = 16,
    parameter integer RELEASE_THRESHOLD = 8,
    parameter integer VIBRATO_STEP = 1,
    parameter integer OCTAVE_MIN = -2,
    parameter integer OCTAVE_MAX = 2,
    parameter integer ENABLE_S10_ROUTE = 0,
    parameter integer ENABLE_S11 = 0,
    parameter integer MIX_SHIFT = 5,
    parameter integer ENABLE_REMOTE = 0
) (
 input wire remote_write_valid,input wire[3:0] remote_write_index,input wire[95:0] remote_write_data,
 output wire remote_write_ready,input wire remote_write_abort,
 input wire  r18_snapshot_valid,
 output wire  r18_snapshot_ready,
 input wire  r18_query_valid,
 input wire [5:0] r18_query_slot,
 output wire  r18_query_ready,
 output wire  r18_response_valid,
 output wire [5:0] r18_response_slot,
 output wire [314:0] r18_response_word,
 input wire [63:0] r18_allocated_pid,
 input wire r18_capture_caught_up,
 input wire [63:0] r18_clock_frame,
 input wire [15:0] r18_clock_subcycle,
 output wire  r18_fact_valid,
 output wire [314:0] r18_fact_before,
 output wire [314:0] r18_fact_after,
 output wire [63:0] r18_fact_frame,
 output wire [15:0] r18_fact_subcycle,
 output wire  r18_reclaim_busy,
 output wire  r18_pan_ready,
 output wire  r18_pan_response_valid,
 output wire [1:0] r18_pan_result,
 output wire [5:0] r18_pan_response_slot,
 output wire [314:0] r18_pan_before,
 output wire [314:0] r18_pan_after,
 input wire  phone_session_flush,
 input wire  phone_session_ready,
 input wire [575:0] phone_presses,
 input wire  phone_lookup_valid,
 input wire  phone_lookup_pan,
 input wire [7:0] phone_lookup_key,
 input wire [63:0] phone_lookup_identity,
 input wire [15:0] phone_lookup_generation,
 input wire [15:0] phone_lookup_tag,
 output wire  phone_lookup_ready,
 output wire  phone_response_valid,
 output wire  phone_found,
 output wire [5:0] phone_response_slot,
 output wire [314:0] phone_response_word,
 output wire [15:0] phone_response_tag,


    input wire score_spi_sck,score_cs_n,score_sd_cs_n,score_spi_mosi,
    output wire score_spi_miso,score_spi_miso_oe,guide_led_dout,
    input wire guide_cfg_valid,guide_cfg_prefix,
    input wire [23:0] guide_cfg_order,
    input wire [13:0] guide_cfg_lead,
    output wire [7:0] score_state,score_error,
    output wire [63:0] score_time,
    output wire [31:0] score_deadline_count,
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
    output wire stream_error,
    output wire [31:0] external_underflow_count,
    input wire fx_cfg_valid,
    input wire [351:0] fx_cfg_data,
    output wire fx_error,
    input wire pan_valid,
    input wire [5:0] pan_slot,
    input wire [63:0] pan_id,
    input wire [15:0] pan_generation,
    input wire [8:0] pan_value,
    input wire comm_clk, input wire clk,
    input wire rst,
    input wire [79:0] pressure_raw,
    input wire pressure_valid,
    input wire step_pulse,
    input wire step_dir,
    input wire [2:0] timbre_id,
    input wire [3:0] glide_code,
    input wire octave_up_pulse,
    input wire octave_down_pulse,
    output wire dac_bck,
    output wire dac_ws,
    output wire dac_din,
    output wire frame_pulse,
    output wire sample_overrun,
    output wire underrun,
    output wire [127:0] observe_audio_metrics,
    output wire observe_load,
    output wire signed [15:0] observe_l,observe_r,
 output wire [47:0] observe_full_slot_valid,observe_full_slot_gate,
    output wire [31:0] observe_slot_valid,observe_slot_gate,
    output wire [95:0] observe_slot_timbres,
    output wire [351:0] observe_fx_config,
    output wire [31:0] observe_fx_version,
    output wire observe_fx_bypass,observe_teach,observe_loop,
    output wire [2:0] observe_stream_state,
    output wire [11:0] observe_stream_buffered,
    output wire [31:0] observe_stream_generation,
    output wire [255:0] observe_score_status,
    // Stage9 optional composition ports; default-zero parameter preserves all
    // existing instantiations without requiring a value on new input ports.
    input wire remote_event_valid,
    input wire [904:0] remote_event_packet,
    output wire remote_event_ready,remote_dispatch_done,
    input wire [55:0] remote_keymap,
    output wire [7:0] observe_local_gate,
    output wire observe_local_pending,
    output wire [55:0] observe_local_notes,
    output wire observe_allocator_publish,
    output wire [31:0] observe_slot_cancel,
    output wire [31:0] observe_sample_time,observe_fx_accepted,
    output wire [31:0] observe_pan_accepted,
    output wire observe_gain_sample,
    output wire [31:0] observe_gain_frame,observe_gain_version,observe_gain_accepted,
    output wire [15:0] observe_gain_l,observe_gain_e,
    output wire [6:0] observe_gain_remaining,
    input wire field_valid,field_start,input wire [2:0] field_size,
    output wire field_ready,field_active,field_rejected,field_committed,field_running,
    output wire observe_test_linear,
    output wire  observe_allocator_busy,
    output wire  observe_batch_begin,
    output wire  observe_publish_ok,
    output wire  observe_batch_abort,
    output wire  observe_apply_valid,
    output wire [31:0] observe_batch_timestamp,
    output wire [3:0] observe_apply_lane,
    output wire [95:0] observe_apply_item,
    output wire [7:0] observe_apply_outcome,
    output wire [5:0] observe_apply_slot,
    output wire [63:0] observe_apply_id,
    output wire [15:0] observe_apply_generation,
    output wire [2:0] observe_apply_timbre,
    output wire  observe_apply_steal,
    output wire [63:0] observe_retired_id,
    output wire [15:0] observe_retired_generation,
    output wire [31:0] observe_reclaim_mask,
    output wire [223:0] observe_slot_notes,
    output wire [255:0] observe_slot_pressures,
    output wire [287:0] observe_current_pan,
    output wire [103:0] observe_gain_state,input wire [540:0] shared_score_rx
);
    wire [7:0] vibrato_depth;
    wire [47:0] slot_valid,slot_gate,slot_trigger;
    wire [31:0] slot_cancel,working_public_equal;
    wire [223:0] slot_notes;
    wire [255:0] slot_pressures;
    wire [2047:0] slot_ids,done_ids;
    wire [511:0] slot_generations;
    wire [95:0] slot_timbres;
    assign observe_full_slot_valid=slot_valid;assign observe_full_slot_gate=slot_gate;
    assign observe_slot_valid=slot_valid[31:0];
    assign observe_slot_gate=slot_gate;
    assign observe_slot_timbres=slot_timbres;
    assign observe_test_linear=TEST_LINEAR_ENABLE!=0&&field_active;
    wire [815:0] envelope_levels;
    wire [143:0] envelope_states;
    wire [31:0] done_mask;
    wire [863:0] voice_samples;
    wire [3:0] lane_deadline_error;
    wire signed [23:0] mix_sample;
    wire mix_valid,mono_mix_valid;
    // The score window is a frame-control boundary, independent of when
    // the deeper arithmetic pipeline delivers PCM. Original stereo lock
    // becomes high after C25 and is consumed on C26, including cold reset.
    reg [5:0] control_frame_age;
    wire stereo_control_locked=control_frame_age==25;
    always @(posedge clk)begin
        if(rst)control_frame_age<=63;
        else if(frame_pulse)control_frame_age<=0;
        else if(control_frame_age<63)control_frame_age<=control_frame_age+1'b1;
    end
    // synthesis translate_off
    reg[10:0] r18_audio_age;
    always @(posedge clk)begin
     if(rst)r18_audio_age<=0;else if(frame_pulse)r18_audio_age<=0;else if(r18_audio_age<1041)r18_audio_age<=r18_audio_age+1'b1;
     // II4 computes early; PCM handoff remains C306 and controller retirement C170.
     if(!rst && mix_valid && r18_audio_age!=306)$fatal(1,"R18_CORE_AUDIO_COMPLETION_EDGE age=%0d",r18_audio_age);
    end
    // synthesis translate_on
    wire [3:0] completion_valid,completion_accept;
    wire [11:0] completion_slot;
    wire [71:0] completion_sample;
    wire [255:0] completion_id;
    wire [63:0] completion_generation;
    wire [287:0] snapshot_pan;
    wire [2047:0] snapshot_ids;
    wire [511:0] snapshot_generations;
    wire signed [31:0] mix_l_q8,mix_r_q8;
    wire [31:0] pan_accepted_count,pan_stale_count,pan_invalid_count;
    wire stereo_protocol_error,stereo_deadline_error;
    wire [5:0] stereo_complete_cycle;

    wire [7:0] local_gate, local_trigger, local_vibrato;
    wire [63:0] local_pressure;
    wire [55:0] local_notes,unmapped_local_notes;
    assign observe_local_gate=local_gate;
    assign observe_local_notes=local_notes;
    assign observe_slot_notes=slot_notes;
    assign observe_slot_pressures=slot_pressures;

    assign observe_slot_cancel=slot_cancel;
    wire signed [8:0] octave_offset=$signed({2'b0,unmapped_local_notes[6:0]})-9'sd60;
    genvar mapped_key;
    generate for(mapped_key=0;mapped_key<8;mapped_key=mapped_key+1)begin: remote_mapping
        if(ENABLE_REMOTE)begin
            wire signed [8:0] mapped_note=$signed({2'b0,remote_keymap[mapped_key*7+:7]})+octave_offset;
            assign local_notes[mapped_key*7+:7]=mapped_note[6:0];
        end else assign local_notes[mapped_key*7+:7]=unmapped_local_notes[mapped_key*7+:7];
    end endgenerate
    wire local_event_valid, local_event_ready, arb_valid, arb_ready;
    wire[3:0] local_buffer_occupancy;
    wire local_adapter_pending,local_write_valid,local_write_ready;
    wire[3:0] local_write_index;wire[95:0] local_write_data;
    wire[40:0] local_header;wire[1:0] pool_rejected_source;
    wire event_valid, event_ready, event_overflow, event_protocol_error;
    wire [904:0] local_event_packet, arb_packet, event_packet;
    wire [2:0] event_queue_occupancy;
    wire pool_rejected,pool_discarded,allocator_abort;
    reg overflow_seen;
    always @(posedge clk)if(rst)overflow_seen<=0;else overflow_seen<=event_overflow;
    wire event_fault = (event_overflow&&!overflow_seen) | event_protocol_error | pool_rejected;
    assign observe_batch_abort=allocator_abort||event_fault;
    reg [31:0] sample_time;
    assign observe_sample_time=sample_time;
    assign observe_pan_accepted=pan_accepted_count;


    // Timestamp metadata only. Events are NEVER gated by this audio tick.
    always @(posedge clk) begin
        if (rst) sample_time<=0;
        else if (frame_pulse) sample_time<=sample_time+1'b1;
    end

    local_performance_control #(
        .HELD_PRESSURE_CYCLES(CLK_FREQ_HZ/250), .INPUT_HOLDS_FRAME(1),
        .PRESSURE_PRENORMALIZED(PRESSURE_PRENORMALIZED), .ADC_ZERO(ADC_ZERO), .ADC_FULL(ADC_FULL), .DEADZONE(DEADZONE),
        .PRESS_THRESHOLD(PRESS_THRESHOLD), .RELEASE_THRESHOLD(RELEASE_THRESHOLD),
        .VIBRATO_STEP(VIBRATO_STEP), .OCTAVE_MIN(OCTAVE_MIN), .OCTAVE_MAX(OCTAVE_MAX)
    ) u_control (
        .clk(clk), .rst(rst), .pressure_raw(pressure_raw), .pressure_valid(pressure_valid),
        .step_pulse(step_pulse), .step_dir(step_dir),
        .octave_up_pulse(octave_up_pulse), .octave_down_pulse(octave_down_pulse),
        .note_gate(local_gate), .note_trigger(local_trigger),
        .pressure_value(local_pressure), .note_code(unmapped_local_notes), .vibrato_depth(local_vibrato)
    );
    generate if(STREAM_PHONE || !ENABLE_REMOTE)begin: compact_local_input
    r28_local_adapter u_event_adapter(.clk(clk),.rst(rst),.overflow_recover(!observe_local_pending),
     .sample_time(sample_time),.note_gate(local_gate),.note_trigger(local_trigger),.vibrato_depth(local_vibrato),
     .pressure_value(local_pressure),.note_code(local_notes),.write_valid(local_write_valid),.write_ready(local_write_ready),
     .write_index(local_write_index),.write_data(local_write_data),.commit_valid(local_event_valid),.commit_ready(local_event_ready),
     .commit_header(local_header),.overflow(event_overflow),.pending(local_adapter_pending),.occupancy(local_buffer_occupancy));
    assign local_event_packet={local_header,864'd0};
    end else begin: legacy_local_input
    local_performance_event_adapter #(.RECOVER_OVERFLOW(1)) u_event_adapter (.overflow_recover(!observe_local_pending),
        .clk(clk), .rst(rst), .sample_time(sample_time),
        .note_gate(local_gate), .note_trigger(local_trigger), .vibrato_depth(local_vibrato),
        .pressure_value(local_pressure), .note_code(local_notes),
        .event_valid(local_event_valid), .event_ready(local_event_ready),
        .event_packet(local_event_packet), .overflow(event_overflow)
    );
    assign local_adapter_pending=local_event_valid;
    assign local_write_valid=0;assign local_write_index=0;assign local_write_data=0;assign local_header=local_event_packet[904:864];
    end endgenerate
    // Stage7 connection only: existing arbiter/queue/allocator algorithms unchanged.
    wire buffered_local_valid,buffered_local_ready,score_event_valid,score_event_ready;
    wire [904:0] buffered_local_packet,score_event_packet;

    wire score_write_valid,score_write_ready;wire[3:0] score_write_index;wire[95:0] score_write_data;
    wire score_dispatch_active,audible_publish;
    wire[1:0] score_owner,raw_cleanup_sources;wire[2:0] score_timbre,pool_timbre;
    wire raw_cleanup_valid,raw_cleanup_ready,raw_cleanup_done,raw_cleanup_all;wire[15:0] raw_cleanup_revision;
    reg allocator_inflight_score;
    wire score_dispatch_done=observe_allocator_publish&&allocator_inflight_score;
    wire[3:0] r18_batch_source;
    always @(posedge clk)begin
     if(rst)allocator_inflight_score<=0;
     else if(observe_batch_begin)allocator_inflight_score<=r18_batch_source==1||r18_batch_source==3;
    end
    score_subsystem #(.AUDIO_RATE_HZ(AUDIO_RATE_HZ),.EXTERNAL_SCORE_RX(EXTERNAL_SCORE_RX),.SERIAL_CONTROL(1),.SHARED_STORE(1),.COMM_SEPARATE(COMM_SEPARATE),.EARLY_DEADLINE(CLK_FREQ_HZ/48000-8),.CLK_FREQ_HZ(CLK_FREQ_HZ),.WATCHDOG_CLOCKS(CLK_FREQ_HZ/10),.ENABLE_S10_ROUTE(ENABLE_S10_ROUTE),.ENABLE_S11(ENABLE_S11),.STREAM_STATUS_CRC(1)) u_score (.raw_frame(r18_clock_frame[31:0]),.capture_caught_up(r18_capture_caught_up),
        .event_owner(score_owner),.event_timbre(score_timbre),.raw_cleanup_valid(raw_cleanup_valid),.raw_cleanup_ready(raw_cleanup_ready),.raw_cleanup_done(raw_cleanup_done),
        .raw_cleanup_sources(raw_cleanup_sources),.raw_cleanup_all(raw_cleanup_all),.raw_cleanup_revision(raw_cleanup_revision),.shared_score_rx(shared_score_rx),.audio_published(audible_publish),.event_write_valid(score_write_valid),.event_write_index(score_write_index),.event_write_data(score_write_data),.event_write_ready(score_write_ready),
        .field_valid(field_valid),.field_start(field_start),.field_size(field_size),.field_ready(field_ready),.field_active(field_active),.field_rejected(field_rejected),.field_committed(field_committed),.field_running(field_running),
        .comm_clk(comm_clk),.clk(clk),.rst(rst),.sample_tick(frame_pulse),.stereo_locked(stereo_control_locked),
        .spi_sck(score_spi_sck),.fpga_cs_n(score_cs_n),.sd_cs_n(score_sd_cs_n),.spi_mosi(score_spi_mosi),
        .spi_miso(score_spi_miso),.spi_miso_oe(score_spi_miso_oe),.local_backlog(local_buffer_occupancy!=0),
        .event_valid(score_event_valid),.event_ready(score_event_ready),.event_packet(score_event_packet),
        .dispatch_done(score_dispatch_done),.local_notes(local_notes),
        .guide_cfg_valid(guide_cfg_valid),.guide_cfg_prefix(guide_cfg_prefix),.guide_cfg_order(guide_cfg_order),.guide_cfg_lead(guide_cfg_lead),
        .led_dout(guide_led_dout),.score_state(score_state),.score_error(score_error),.score_time(score_time),.deadline_count(score_deadline_count),.observe_teach(observe_teach),.observe_loop(observe_loop),.observe_score_status(observe_score_status),.observe_dispatch_active(score_dispatch_active));
    wire queue_source_valid,queue_source_ready;
    wire[40:0] pool_header;wire[3:0] pool_source,pool_item_index;
    wire[95:0] pool_item;wire[2:0] pool_occupancy;
    wire[904:0] queue_source_packet={pool_header,832'd0,pool_source,28'd0};
    reg allocator_inflight_phone,allocator_inflight_local;
    reg [5:0] local_uncommitted;
    reg phone_wait_audible;
    always @(posedge clk)begin
     if(rst)phone_wait_audible<=0;
     else begin
      if(observe_allocator_publish&&allocator_inflight_phone)phone_wait_audible<=1;
      if(audible_publish||allocator_abort)phone_wait_audible<=0;
     end
    end
    assign remote_dispatch_done=(audible_publish&&phone_wait_audible)||(allocator_abort&&allocator_inflight_phone)||(pool_rejected&&pool_rejected_source==2);
    assign observe_local_pending=local_adapter_pending||local_uncommitted!=0;
    always @(posedge clk)begin
        if(rst)begin allocator_inflight_phone<=0;allocator_inflight_local<=0;local_uncommitted<=0;end
        else begin
            if(observe_batch_begin)begin
                allocator_inflight_phone<=r18_batch_source==2;
                allocator_inflight_local<=r18_batch_source==0;
            end
            case({local_event_valid&&local_event_ready,((observe_allocator_publish||allocator_abort)&&allocator_inflight_local)||(pool_rejected&&pool_rejected_source==0)||pool_discarded})
                2'b10:local_uncommitted<=local_uncommitted+1'b1;
                2'b01:local_uncommitted<=local_uncommitted-1'b1;
                default:local_uncommitted<=local_uncommitted;
            endcase
        end
    end
    generate if(STREAM_PHONE || !ENABLE_REMOTE)begin: compact_event_store
    r28_event_pool #(.LOCAL_BUFFER(0),.FAST_READ(1),.RAW_SCORE(1)) event_pool(.score_owner(score_owner),.score_timbre(score_timbre),.event_timbre(pool_timbre),.clk(clk),.rst(rst),
     .write_valid({ENABLE_REMOTE&&remote_write_valid,score_write_valid,local_write_valid}),
     .write_ready({remote_write_ready,score_write_ready,local_write_ready}),
     .write_index({remote_write_index,score_write_index,local_write_index}),.write_data({remote_write_data,score_write_data,local_write_data}),
     .commit_valid({ENABLE_REMOTE&&remote_event_valid,score_event_valid,local_event_valid}),.commit_ready({remote_event_ready,score_event_ready,local_event_ready}),
     .commit_header({remote_event_packet[904:864],score_event_packet[904:864],local_header}),
     .phone_abort(remote_write_abort),.score_urgent(score_dispatch_active),.discard_local(event_overflow),
     .discarded(pool_discarded),.rejected(pool_rejected),.rejected_source(pool_rejected_source),
     .event_valid(queue_source_valid),.event_ready(queue_source_ready),.event_header(pool_header),.event_source(pool_source),
     .retire(observe_allocator_publish||allocator_abort),.item_request(1'b0),.item_index(pool_item_index),.item_ready(),.item_response(),.item_data(pool_item),
     .local_occupancy(),.occupancy(pool_occupancy));
    end else begin: legacy_event_store
    r26_event_pool #(.SHARED_SCORE(1),.SHARED_PHONE(STREAM_PHONE),.VALIDATE(1),.DISCARD_LOCAL(1)) event_pool(.score_write_valid(score_write_valid),.score_write_index(score_write_index),.score_write_data(score_write_data),.score_write_ready(score_write_ready),.clk(clk),.rst(rst),
     .phone_write_valid(remote_write_valid),.phone_write_index(remote_write_index),.phone_write_data(remote_write_data),.phone_write_ready(remote_write_ready),.phone_write_abort(remote_write_abort),
     .local_valid(local_event_valid),.local_ready(local_event_ready),.local_packet(local_event_packet),
     .score_valid(score_event_valid),.score_ready(score_event_ready),.score_packet(score_event_packet),
     .phone_valid(ENABLE_REMOTE&&remote_event_valid),.phone_ready(remote_event_ready),.phone_packet(remote_event_packet),
     .score_urgent(score_dispatch_active),.event_valid(queue_source_valid),.event_ready(queue_source_ready),
     .discard_local(event_overflow),.discarded(pool_discarded),.rejected(pool_rejected),.event_header(pool_header),.event_source(pool_source),.retire(observe_allocator_publish||allocator_abort),
     .item_index(pool_item_index),.item_data(pool_item),.local_occupancy(local_buffer_occupancy),.occupancy(pool_occupancy));
    assign pool_timbre=0;assign local_write_ready=0;assign pool_rejected_source=pool_source[1:0];
    end endgenerate
    wire[1487:0] r18_controls;wire r18_identity_stable,r18_audio_busy,r18_event_busy,r18_deadline;
    wire[7:0] r18_outcome;wire[5:0] r18_slot;wire[95:0] r18_item;wire[3:0] r18_lane;wire r18_steal;
    wire fx_mac_use;wire signed[35:0] fx_mac_a;wire signed[17:0] fx_mac_b;wire signed[53:0] fx_mac_q;
    r28_instrument_engine #(.SAMPLE_RATE_HZ(AUDIO_RATE_HZ),.SHARE_FX(0),.LEASED_ITEM(STREAM_PHONE || !ENABLE_REMOTE),.NO_UNDO(1),.INDEXED_INPUT(1),.PHONE_LOOKUP(ENABLE_REMOTE?2:0),.CLK_FREQ_HZ(CLK_FREQ_HZ),.LOOP_ENABLE(1)) engine(.test_linear(observe_test_linear),
     .loop_cleanup_valid(raw_cleanup_valid),.loop_cleanup_sources(raw_cleanup_sources),.loop_cleanup_all(raw_cleanup_all),.loop_cleanup_revision(raw_cleanup_revision),.loop_cleanup_ready(raw_cleanup_ready),.loop_cleanup_done(raw_cleanup_done),.loop_abort_batch(1'b0),.event_loop_timbre(pool_timbre),.fx_mac_use(fx_mac_use),.fx_mac_a(fx_mac_a),.fx_mac_b(fx_mac_b),.fx_mac_q(fx_mac_q),.hold_publication(score_dispatch_active),.audible_publish(audible_publish),.indexed_item(pool_item),.indexed_occupancy(pool_occupancy),.indexed_item_index(pool_item_index),.clk(clk),.rst(rst),.sample_tick(frame_pulse),.panic(event_fault),
     .event_valid(queue_source_valid),.event_ready(queue_source_ready),.event_packet(queue_source_packet),.timbre_id(timbre_id),.glide_code(glide_code),
     .frame_id(r18_clock_frame),.subcycle(r18_clock_subcycle),.allocated_persistent_id(r18_allocated_pid),
     .session_flush(phone_session_flush),.session_ready(phone_session_ready),.event_phone_presses(phone_presses),
     .lookup_valid(phone_lookup_valid),.lookup_pan(phone_lookup_pan),.lookup_key(phone_lookup_key),.lookup_identity(phone_lookup_identity),
     .lookup_generation(phone_lookup_generation),.lookup_tag(phone_lookup_tag),.lookup_ready(phone_lookup_ready),
     .lookup_response_valid(phone_response_valid),.lookup_found(phone_found),.lookup_response_slot(phone_response_slot),
     .lookup_response_word(phone_response_word),.lookup_response_tag(phone_response_tag),
     .snapshot_valid(r18_snapshot_valid),.snapshot_record_start(1'b1),.snapshot_ready(r18_snapshot_ready),
     .query_valid(r18_query_valid),.query_snapshot(1'b1),.query_slot(r18_query_slot),.query_ready(r18_query_ready),
     .query_response_valid(r18_response_valid),.query_response_slot(r18_response_slot),.query_response_word(r18_response_word),
     .pan_valid(pan_valid),.pan_slot(pan_slot),.pan_id(pan_id),.pan_generation(pan_generation),.pan_value(pan_value),.pan_ready(r18_pan_ready),
     .pan_response_valid(r18_pan_response_valid),.pan_result(r18_pan_result),.pan_response_slot(r18_pan_response_slot),.pan_before(r18_pan_before),.pan_after(r18_pan_after),
     .ensemble_metrics(observe_audio_metrics),.mix_valid(mix_valid),.mix_l_q8(mix_l_q8),.mix_r_q8(mix_r_q8),.envelope_levels(envelope_levels),.envelope_states(envelope_states),.voice_samples(voice_samples),
     .control_state(r18_controls),.control_valid(slot_valid),.control_gate(slot_gate),.batch_source(r18_batch_source),
     .protocol_error(event_protocol_error),.deadline_error(r18_deadline),.queue_occupancy(event_queue_occupancy),
     .batch_begin(observe_batch_begin),.batch_publish(observe_allocator_publish),.batch_abort(allocator_abort),.batch_timestamp(observe_batch_timestamp),
     .fact_valid(r18_fact_valid),.fact_lane(r18_lane),.fact_item(r18_item),.fact_outcome(r18_outcome),.fact_slot(r18_slot),.fact_steal(r18_steal),
     .fact_before(r18_fact_before),.fact_after(r18_fact_after),.fact_frame(r18_fact_frame),.fact_subcycle(r18_fact_subcycle),.reclaim_batch_busy(r18_reclaim_busy),
     .identity_stable(r18_identity_stable),.event_busy(r18_event_busy),.audio_busy(r18_audio_busy));
    assign observe_allocator_busy=!r18_identity_stable;assign observe_publish_ok=audible_publish;
    assign observe_apply_valid=r18_fact_valid&&r18_outcome!=10;
    assign observe_apply_lane=r18_lane;assign observe_apply_item=r18_item;assign observe_apply_outcome=r18_outcome;
    assign observe_apply_slot=r18_slot;assign observe_apply_steal=r18_steal;
    assign observe_apply_id=r18_fact_after[122:59];assign observe_apply_generation=r18_fact_after[58:43];assign observe_apply_timbre=r18_fact_after[30:28];
    assign observe_retired_id=r18_fact_before[122:59];assign observe_retired_generation=r18_fact_before[58:43];
    assign observe_reclaim_mask=r18_fact_valid&&r18_outcome==10?(32'd1<<r18_slot):32'd0;
    assign slot_cancel=r18_fact_valid&&r18_outcome==1?(32'd1<<r18_slot):32'd0;
    assign stereo_protocol_error=event_protocol_error;assign stereo_deadline_error=r18_deadline;
    assign lane_deadline_error={4{r18_deadline}};
    reg[31:0] pan_accepted_reg;
    assign pan_accepted_count=pan_accepted_reg;
    always @(posedge clk)if(rst)pan_accepted_reg<=0;else if(r18_pan_response_valid&&r18_pan_result==0)pan_accepted_reg<=pan_accepted_reg+1'b1;
    generate for(genvar v=0;v<32;v++)begin: public_audio_controls
     assign slot_trigger[v]=r18_controls[v*31+3];assign slot_notes[v*7+:7]=r18_controls[v*31+13+:7];
     assign slot_pressures[v*8+:8]=r18_controls[v*31+20+:8];assign slot_timbres[v*3+:3]=r18_controls[v*31+28+:3];
     assign observe_current_pan[v*9+:9]=r18_controls[v*31+4+:9];
    end endgenerate
    wire signed [31:0] fx_l_q8,fx_r_q8;
    wire fx_valid,fx_bypass;
    assign observe_fx_bypass=fx_bypass;
    wire [31:0] fx_frames,fx_cfg_accepted,fx_cfg_rejected;
    assign observe_fx_accepted=fx_cfg_accepted;
    generate if(AUDIO_RATE_HZ==128000)begin: native128_effects
    assign fx_mac_use=0;assign fx_mac_a=0;assign fx_mac_b=0;
    fx128_multirate #(.MIX_SHIFT(MIX_SHIFT)) u_effects(
        .clk(clk),.rst(rst),.sample_tick(frame_pulse),
        .in_l_q8(mix_l_q8),.in_r_q8(mix_r_q8),.in_valid(mix_valid),
        .cfg_valid(fx_cfg_valid),.cfg_data(fx_cfg_data),
        .out_l_q8(fx_l_q8),.out_r_q8(fx_r_q8),.out_valid(fx_valid),
        .protocol_error(fx_error),.frame_count(fx_frames),
        .cfg_accepted(fx_cfg_accepted),.cfg_rejected(fx_cfg_rejected),.effective_bypass(fx_bypass),
        .observe_config(observe_fx_config),.observe_version(observe_fx_version));
    end else if(AUDIO_RATE_HZ==96000)begin: native96_effects
    assign fx_mac_use=0;assign fx_mac_a=0;assign fx_mac_b=0;
    fx96_multirate #(.MIX_SHIFT(MIX_SHIFT)) u_effects(
        .clk(clk),.rst(rst),.sample_tick(frame_pulse),
        .in_l_q8(mix_l_q8),.in_r_q8(mix_r_q8),.in_valid(mix_valid),
        .cfg_valid(fx_cfg_valid),.cfg_data(fx_cfg_data),
        .out_l_q8(fx_l_q8),.out_r_q8(fx_r_q8),.out_valid(fx_valid),
        .protocol_error(fx_error),.frame_count(fx_frames),
        .cfg_accepted(fx_cfg_accepted),.cfg_rejected(fx_cfg_rejected),.effective_bypass(fx_bypass),
        .observe_config(observe_fx_config),.observe_version(observe_fx_version));
    end else if(AUDIO_RATE_HZ==72000)begin: native72_effects
    assign fx_mac_use=0;assign fx_mac_a=0;assign fx_mac_b=0;
    fx72_multirate #(.MIX_SHIFT(MIX_SHIFT)) u_effects(
        .clk(clk),.rst(rst),.sample_tick(frame_pulse),
        .in_l_q8(mix_l_q8),.in_r_q8(mix_r_q8),.in_valid(mix_valid),
        .cfg_valid(fx_cfg_valid),.cfg_data(fx_cfg_data),
        .out_l_q8(fx_l_q8),.out_r_q8(fx_r_q8),.out_valid(fx_valid),
        .protocol_error(fx_error),.frame_count(fx_frames),
        .cfg_accepted(fx_cfg_accepted),.cfg_rejected(fx_cfg_rejected),.effective_bypass(fx_bypass),
        .observe_config(observe_fx_config),.observe_version(observe_fx_version));
    end else begin: original48_effects
    r46_serial_effects #(.MIX_SHIFT(MIX_SHIFT),.SCHEDULED_CONTROL(1),.SHARED_MAC(0)) u_effects(.fx_mac_use(fx_mac_use),.fx_mac_a(fx_mac_a),.fx_mac_b(fx_mac_b),.fx_mac_q(fx_mac_q),
        .clk(clk),.rst(rst),.sample_tick(frame_pulse),
        .in_l_q8(mix_l_q8),.in_r_q8(mix_r_q8),.in_valid(mix_valid),
        .cfg_valid(fx_cfg_valid),.cfg_data(fx_cfg_data),
        .out_l_q8(fx_l_q8),.out_r_q8(fx_r_q8),.out_valid(fx_valid),
        .protocol_error(fx_error),.frame_count(fx_frames),
        .cfg_accepted(fx_cfg_accepted),.cfg_rejected(fx_cfg_rejected),.effective_bypass(fx_bypass),.observe_config(observe_fx_config),.observe_version(observe_fx_version));
    end endgenerate
    digital_audio_output_master #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .SAMPLE_RATE_HZ(AUDIO_RATE_HZ), .MIX_SHIFT(MIX_SHIFT)
    ) u_output (
        .stream_ctrl_valid(stream_ctrl_valid),.stream_ctrl_ready(stream_ctrl_ready),
        .stream_ctrl_cmd(stream_ctrl_cmd),.stream_ctrl_epoch(stream_ctrl_epoch),.stream_ctrl_rate(stream_ctrl_rate),.stream_ctrl_track(stream_ctrl_track),
        .external_valid(external_valid),.external_ready(external_ready),.external_l(external_l),.external_r(external_r),.external_epoch(external_epoch),
        .gain_cfg_valid(gain_cfg_valid),.gain_cfg_local(gain_cfg_local),.gain_cfg_external(gain_cfg_external),
        .gain_cfg_local_mute(gain_cfg_local_mute),.gain_cfg_external_mute(gain_cfg_external_mute),
        .stream_error(stream_error),.external_underflow_count(external_underflow_count),.deadline_error(),
        .clk(clk), .rst(rst), .mix_l_q8(fx_l_q8),.mix_r_q8(fx_r_q8), .mix_valid(fx_valid),
        .sample_tick(frame_pulse), .dac_bck(dac_bck), .dac_ws(dac_ws), .dac_din(dac_din),
        .sample_overrun(sample_overrun), .dac_underrun(underrun),
        .observe_load(observe_load),.observe_l(observe_l),.observe_r(observe_r),.observe_stream_state(observe_stream_state),.observe_stream_buffered(observe_stream_buffered),.observe_stream_generation(observe_stream_generation),
        .observe_gain_state(observe_gain_state),.observe_gain_sample(observe_gain_sample),.observe_gain_frame(observe_gain_frame),
        .observe_gain_version(observe_gain_version),.observe_gain_accepted(observe_gain_accepted),
        .observe_gain_l(observe_gain_l),.observe_gain_e(observe_gain_e),.observe_gain_remaining(observe_gain_remaining)
    );
endmodule

// One system-clock event per cycle from a latched nine-lane batch.
// NOTE_OFF and expression match source/key/press_token, never pitch.
// Instance zero is invalid. ID_WIDTH can be reduced in TB to exercise wrap.
module r12_owner_audio_probe #(parameter integer ID_WIDTH=64, ONE_RECLAIM_PER_LANE=1, OWNER_DIRECTORY=1) (
    input wire clk, rst, panic, sample_tick,
    input wire event_valid,
    output wire event_ready,
    input wire [904:0] event_packet,
    // Configuration is sampled only when a NOTE_ON actually allocates a slot.
    input wire [2:0] timbre_id,
    output wire [543:0] envelope_levels,
    output wire [31:0] done_mask,
    output wire [2047:0] done_ids,
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
    output wire [511:0] observe_reclaim_generations,
    output wire [23:0] mix_sample,output wire mix_valid,
    output wire [95:0] envelope_states,output wire [575:0] voice_samples,
    output wire [3:0] completion_valid,completion_accept,lane_deadline_error,
    output wire [11:0] completion_slot,output wire [71:0] completion_sample,
    output wire [255:0] completion_id,output wire [63:0] completion_generation
);
voice_allocator32 #(.ID_WIDTH(ID_WIDTH),.ONE_RECLAIM_PER_LANE(1)) allocator(.clk(clk),.rst(rst),.panic(panic),.sample_tick(sample_tick),.event_valid(event_valid),.event_ready(event_ready),.event_packet(event_packet),.timbre_id(timbre_id),.envelope_levels(envelope_levels),.done_mask(done_mask),.done_ids(done_ids),.slot_valid(slot_valid),.slot_gate(slot_gate),.slot_trigger(slot_trigger),.slot_cancel(slot_cancel),.slot_notes(slot_notes),.slot_pressures(slot_pressures),.slot_ids(slot_ids),.slot_generations(slot_generations),.slot_timbres(slot_timbres),.vibrato_depth(vibrato_depth),.protocol_error(protocol_error),.steal_count(steal_count),.stale_count(stale_count),.allocation_count(allocation_count),.reclaim_count(reclaim_count),.id_collision_skip_count(id_collision_skip_count),.id_wrap_count(id_wrap_count),.observe_working_public_equal(observe_working_public_equal),.observe_publish(observe_publish),.observe_sources(observe_sources),.observe_keys(observe_keys),.observe_tokens(observe_tokens),.observe_busy(observe_busy),.observe_batch_begin(observe_batch_begin),.observe_publish_ok(observe_publish_ok),.observe_batch_abort(observe_batch_abort),.observe_apply_valid(observe_apply_valid),.observe_batch_timestamp(observe_batch_timestamp),.observe_apply_lane(observe_apply_lane),.observe_apply_item(observe_apply_item),.observe_apply_outcome(observe_apply_outcome),.observe_apply_slot(observe_apply_slot),.observe_apply_id(observe_apply_id),.observe_apply_generation(observe_apply_generation),.observe_apply_timbre(observe_apply_timbre),.observe_apply_steal(observe_apply_steal),.observe_retired_id(observe_retired_id),.observe_retired_generation(observe_retired_generation),.observe_reclaim_mask(observe_reclaim_mask),.observe_reclaim_generations(observe_reclaim_generations));
generate if(OWNER_DIRECTORY)begin: optimized
poly_synth_mixer32_owner_directory #(.COMPACT_RECLAIM(1),.SHARED_BACKEND(1)) poly(.owner_allocate(observe_apply_valid&&observe_apply_outcome==1),.owner_publish(observe_publish),
 .owner_allocate_slot(observe_apply_slot[5:0]),.owner_allocate_id(observe_apply_id),.owner_allocate_generation(observe_apply_generation),
 .working_public_equal(observe_working_public_equal),.clk(clk),.rst(rst),.sample_tick(sample_tick),.slot_valid(slot_valid),.slot_gate(slot_gate),.slot_trigger(slot_trigger),.slot_cancel(slot_cancel),.slot_notes(slot_notes),.slot_pressures(slot_pressures),.slot_ids(slot_ids),.slot_generations(slot_generations),.slot_timbres(slot_timbres),.vibrato_depth(vibrato_depth),.mix_sample(mix_sample),.mix_valid(mix_valid),.envelope_levels(envelope_levels),.envelope_states(envelope_states),.done_mask(done_mask),.done_ids(done_ids),.voice_samples(voice_samples),.completion_valid(completion_valid),.completion_accept(completion_accept),.completion_slot(completion_slot),.completion_sample(completion_sample),.completion_id(completion_id),.completion_generation(completion_generation),.lane_deadline_error(lane_deadline_error),.glide_code(4'd7));
end else begin: baseline
poly_synth_mixer32_stage3 #(.COMPACT_RECLAIM(1),.SHARED_BACKEND(1)) poly(.clk(clk),.rst(rst),.sample_tick(sample_tick),.slot_valid(slot_valid),.slot_gate(slot_gate),.slot_trigger(slot_trigger),.slot_cancel(slot_cancel),.slot_notes(slot_notes),.slot_pressures(slot_pressures),.slot_ids(slot_ids),.slot_generations(slot_generations),.slot_timbres(slot_timbres),.vibrato_depth(vibrato_depth),.mix_sample(mix_sample),.mix_valid(mix_valid),.envelope_levels(envelope_levels),.envelope_states(envelope_states),.done_mask(done_mask),.done_ids(done_ids),.voice_samples(voice_samples),.completion_valid(completion_valid),.completion_accept(completion_accept),.completion_slot(completion_slot),.completion_sample(completion_sample),.completion_id(completion_id),.completion_generation(completion_generation),.lane_deadline_error(lane_deadline_error),.glide_code(4'd7));
end endgenerate
endmodule

module allocator_indexed_probe (
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
    output wire [7:0] vibrato_depth,
    output wire protocol_error,
    output wire [31:0] steal_count, stale_count, allocation_count,
    output wire [31:0] reclaim_count, id_collision_skip_count, id_wrap_count,
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
voice_allocator32 #(.ID_WIDTH(64),.ONE_RECLAIM_PER_LANE(1),.INDEXED_INPUT(1)) dut(.clk(clk),.rst(rst),.panic(panic),.sample_tick(sample_tick),.event_valid(event_valid),.event_ready(event_ready),.event_packet(event_packet),.event_item(event_item),.event_item_index(event_item_index),.timbre_id(timbre_id),.envelope_levels(envelope_levels),.done_mask(done_mask),.done_ids(done_ids),.slot_valid(slot_valid),.slot_gate(slot_gate),.slot_trigger(slot_trigger),.slot_cancel(slot_cancel),.slot_notes(slot_notes),.slot_pressures(slot_pressures),.slot_ids(slot_ids),.slot_generations(slot_generations),.slot_timbres(slot_timbres),.vibrato_depth(vibrato_depth),.protocol_error(protocol_error),.steal_count(steal_count),.stale_count(stale_count),.allocation_count(allocation_count),.reclaim_count(reclaim_count),.id_collision_skip_count(id_collision_skip_count),.id_wrap_count(id_wrap_count),.observe_working_public_equal(observe_working_public_equal),.observe_publish(observe_publish),.observe_sources(observe_sources),.observe_keys(observe_keys),.observe_tokens(observe_tokens),.observe_busy(observe_busy),.observe_batch_begin(observe_batch_begin),.observe_publish_ok(observe_publish_ok),.observe_batch_abort(observe_batch_abort),.observe_apply_valid(observe_apply_valid),.observe_batch_timestamp(observe_batch_timestamp),.observe_apply_lane(observe_apply_lane),.observe_apply_item(observe_apply_item),.observe_apply_outcome(observe_apply_outcome),.observe_apply_slot(observe_apply_slot),.observe_apply_id(observe_apply_id),.observe_apply_generation(observe_apply_generation),.observe_apply_timbre(observe_apply_timbre),.observe_apply_steal(observe_apply_steal),.observe_retired_id(observe_retired_id),.observe_retired_generation(observe_retired_generation),.observe_reclaim_mask(observe_reclaim_mask),.observe_reclaim_generations(observe_reclaim_generations));
endmodule

module allocator_event_queue_probe (
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
    output wire [7:0] vibrato_depth,
    output wire protocol_error,
    output wire [31:0] steal_count, stale_count, allocation_count,
    output wire [31:0] reclaim_count, id_collision_skip_count, id_wrap_count,
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
wire q_valid,a_ready;wire [904:0] q_header;wire [95:0] q_item;wire [2:0] q_count;
performance_indexed_event_queue queue(.clk(clk),.rst(rst),.s_valid(event_valid),.s_ready(event_ready),.s_data(event_packet),
 .m_valid(q_valid),.m_ready(a_ready && !panic),.m_data(q_header),
 .retire(observe_publish_ok || observe_batch_abort),.item_index(event_item_index),.item_data(q_item),.occupancy(q_count));
voice_allocator32 #(.ID_WIDTH(64),.ONE_RECLAIM_PER_LANE(1),.INDEXED_INPUT(1)) dut(.clk(clk),.rst(rst),.panic(panic),.sample_tick(sample_tick),.event_valid(q_valid),.event_ready(a_ready),.event_packet(q_header),.event_item(q_item),.event_item_index(event_item_index),.timbre_id(timbre_id),.envelope_levels(envelope_levels),.done_mask(done_mask),.done_ids(done_ids),.slot_valid(slot_valid),.slot_gate(slot_gate),.slot_trigger(slot_trigger),.slot_cancel(slot_cancel),.slot_notes(slot_notes),.slot_pressures(slot_pressures),.slot_ids(slot_ids),.slot_generations(slot_generations),.slot_timbres(slot_timbres),.vibrato_depth(vibrato_depth),.protocol_error(protocol_error),.steal_count(steal_count),.stale_count(stale_count),.allocation_count(allocation_count),.reclaim_count(reclaim_count),.id_collision_skip_count(id_collision_skip_count),.id_wrap_count(id_wrap_count),.observe_working_public_equal(observe_working_public_equal),.observe_publish(observe_publish),.observe_sources(observe_sources),.observe_keys(observe_keys),.observe_tokens(observe_tokens),.observe_busy(observe_busy),.observe_batch_begin(observe_batch_begin),.observe_publish_ok(observe_publish_ok),.observe_batch_abort(observe_batch_abort),.observe_apply_valid(observe_apply_valid),.observe_batch_timestamp(observe_batch_timestamp),.observe_apply_lane(observe_apply_lane),.observe_apply_item(observe_apply_item),.observe_apply_outcome(observe_apply_outcome),.observe_apply_slot(observe_apply_slot),.observe_apply_id(observe_apply_id),.observe_apply_generation(observe_apply_generation),.observe_apply_timbre(observe_apply_timbre),.observe_apply_steal(observe_apply_steal),.observe_retired_id(observe_retired_id),.observe_retired_generation(observe_retired_generation),.observe_reclaim_mask(observe_reclaim_mask),.observe_reclaim_generations(observe_reclaim_generations));
endmodule


