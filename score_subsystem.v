module score_subsystem #(parameter integer RAW_ONLY=1,AUDIO_RATE_HZ=48000,EXTERNAL_SCORE_RX=0,SERIAL_CONTROL=0,SHARED_STORE=0,COMM_SEPARATE=0,
 parameter integer CLK_FREQ_HZ=50_000_000,TOKEN_WIDTH=64, WATCHDOG_CLOCKS=5000000, ENABLE_S10_ROUTE=0, ENABLE_S11=0, STREAM_STATUS_CRC=0, EARLY_DEADLINE=960)(
 output wire event_write_valid,output wire[3:0] event_write_index,output wire[95:0] event_write_data,input wire event_write_ready,
 input wire comm_clk, input wire clk,rst,sample_tick,stereo_locked,
 input wire spi_sck,fpga_cs_n,sd_cs_n,spi_mosi,output wire spi_miso,spi_miso_oe,
 input wire local_backlog,output wire event_valid,input wire event_ready,output wire [904:0] event_packet,
 input wire audio_published,
 input wire [31:0] raw_frame,input wire capture_caught_up,
 output wire [1:0] event_owner,output wire [2:0] event_timbre,
 output wire raw_cleanup_valid,input wire raw_cleanup_ready,raw_cleanup_done,
 output wire [1:0] raw_cleanup_sources,output wire raw_cleanup_all,output wire [15:0] raw_cleanup_revision,
 input wire dispatch_done,input wire [55:0] local_notes,
 input wire guide_cfg_valid,guide_cfg_prefix,input wire [23:0] guide_cfg_order,input wire [13:0] guide_cfg_lead,
 output wire led_dout,output wire [7:0] score_state,score_error,
 output wire [63:0] score_time,output wire [31:0] deadline_count,
 output wire [255:0] observe_score_status,
 output wire observe_dispatch_active,
 output wire observe_teach,observe_loop,
 input wire field_valid,field_start,input wire [1:0] field_size,
 output wire field_ready,field_active,field_rejected,field_committed,field_running,input wire [540:0] shared_score_rx
);
 wire cv,cr,pv,pr,pdone,pok,pc,pe,rv,rr,hv,eof;
 wire ctrl_raw,raw_mode,raw_fifo_clear,raw_published_valid,raw_barrier_busy;
 wire [31:0] raw_last_audible,raw_completed_barrier;
 wire [7:0] cmd,parser_error;wire [63:0] ep,arg,active_epoch,end_time,last_time;
 wire [31:0] seq,accepted_pages,rejected_transactions,cs_conflicts,total_records,parsed_records;
 wire [8:0] addr,occupancy,visible;wire [7:0] data;wire [127:0] record_in,record_out;
 wire mvalid,mready;wire link_timeout;wire [31:0] logical_held;wire [223:0] logical_notes;
 wire [255:0] logical_pressures;wire reload_request;
 wire [31:0] guide_held;wire [223:0] guide_notes;
 wire [31:0] records_consumed,events_offered,events_accepted,events_completed,token_exhaustions,stops;
 wire [15:0] last_group_cycles;wire [63:0] player_epoch;
 wire [31:0] inserted,consumed;
 wire preview_valid;wire [63:0] preview_time;wire [127:0] preview_notes;
 wire field_cv,field_cr,field_rv,field_rr,field_hv,field_eof,field_internal_ready;
 assign field_ready=field_internal_ready&&!cv;
 wire [7:0] field_cmd;wire [63:0] field_ep,field_arg,field_verified;
 wire [127:0] field_record;wire [8:0] field_visible;wire [5:0] field_voices;
 wire player_cv=field_active?field_cv:cv;
 wire [7:0] player_cmd=field_active?field_cmd:cmd;
 wire [63:0] player_ep=field_active?field_ep:ep,player_arg=field_active?field_arg:arg;
 wire player_cr;
 assign cr=player_cr&&!field_active;
 assign field_cr=player_cr&&field_active;
 assign field_rr=mready&&field_active;
 wire fifo_ready=mready&&!field_active;
 generate if(ENABLE_S11)begin: field_enabled
  s11_field_test_source #(.AUDIO_RATE_HZ(AUDIO_RATE_HZ)) field(.raw_frame(raw_frame),.clk(clk),.rst(rst),.request_valid(field_valid&&!cv),
   .request_start(field_start),.request_size(field_size),.request_ready(field_internal_ready),
   .player_state(score_state),.player_epoch(player_epoch),.player_ctrl_ready(field_cr),.parser_clear(pc),
   .active(field_active),.rejected(field_rejected),.committed(field_committed),.running(field_running),.ctrl_valid(field_cv),.ctrl_cmd(field_cmd),
   .ctrl_epoch(field_ep),.ctrl_arg(field_arg),.header_valid(field_hv),.eof_seen(field_eof),
   .last_verified_time(field_verified),.record_valid(field_rv),.record_ready(field_rr),
   .record_data(field_record),.visible_records(field_visible),.voice_count(field_voices));
 end else begin: no_field
  assign field_internal_ready=0;assign field_committed=0;assign field_running=0;assign field_active=0;assign field_rejected=0;
  assign field_cv=0;assign field_cmd=0;assign field_ep=0;assign field_arg=0;
  assign field_hv=0;assign field_eof=0;assign field_verified=0;
  assign field_rv=0;assign field_record=0;assign field_visible=0;assign field_voices=0;
 end endgenerate
 wire clear=pc||(cv&&cr&&!ctrl_raw&&(cmd==3||cmd==6||cmd==7));
 wire fifo_clear=raw_mode?raw_fifo_clear:clear;
 score_spi_transport #(.RAW_ONLY(RAW_ONLY),.EXTERNAL_SCORE_RX(EXTERNAL_SCORE_RX),.COMM_SEPARATE(COMM_SEPARATE),.WATCHDOG_CLOCKS(WATCHDOG_CLOCKS),.ENABLE_S10_ROUTE(ENABLE_S10_ROUTE),.ENABLE_FIELD(ENABLE_S11),.STREAM_STATUS_CRC(STREAM_STATUS_CRC)) transport(.shared_score_rx(shared_score_rx),.ctrl_raw(ctrl_raw),.raw_mode(raw_mode),
  .raw_frame(raw_frame),.capture_caught_up(capture_caught_up),.raw_published_valid(raw_published_valid),
  .raw_last_audible(raw_last_audible),.raw_completed_barrier(raw_completed_barrier),.raw_barrier_busy(raw_barrier_busy),
  .comm_clk(comm_clk),.clk(clk),.rst(rst),.spi_sck(spi_sck),.fpga_cs_n(fpga_cs_n),.sd_cs_n(sd_cs_n),.spi_mosi(spi_mosi),
  .spi_miso(spi_miso),.spi_miso_oe(spi_miso_oe),.observe_status_bytes(observe_score_status),.ctrl_valid(cv),.ctrl_ready(cr),.ctrl_cmd(cmd),.ctrl_epoch(ep),.ctrl_arg(arg),
  .page_valid(pv),.page_ready(pr),.page_sequence(seq),.page_done(pdone),.page_ok(pok),.page_addr(addr),.page_data(data),
  .player_state(score_state),.player_error(score_error),.reload_request(reload_request),.active_epoch(active_epoch),
  .accepted_pages(accepted_pages),.rejected_transactions(rejected_transactions),.cs_conflicts(cs_conflicts),.link_timeout(link_timeout),.field_busy(field_active));
 r28_borrowed_score_parser parser(
  .clk(clk),.rst(rst),.clear(clear),.enable(pe),.raw_mode(raw_mode),.page_valid(pv),.page_ready(pr),.page_sequence(seq),
  .page_done(pdone),.page_ok(pok),.page_addr(addr),.page_data(data),
  .record_valid(rv),.record_ready(rr),.record_data(record_in),.header_valid(hv),.eof_seen(eof),
  .end_time(end_time),.last_verified_time(last_time),.total_records(total_records),.parsed_records(parsed_records),.error_code(parser_error));
 score_record_fifo records(
  .clk(clk),.rst(rst),.clear(fifo_clear),.raw_mode(raw_mode),.raw_time(score_time),.s_valid(rv),.s_ready(rr),.s_record(record_in),
  .m_valid(mvalid),.m_ready(fifo_ready),.m_record(record_out),.occupancy(occupancy),.visible_records(visible),
  .inserted(inserted),.consumed(consumed),.preview_valid(preview_valid),.preview_time(preview_time),.preview_notes(preview_notes));
 score_sequencer #(.RAW_ONLY(RAW_ONLY),.PARALLEL_PRESSURE_VIEW(0),.SERIAL_CONTROL(SERIAL_CONTROL),.SHARED_STORE(SHARED_STORE),.TOKEN_WIDTH(TOKEN_WIDTH),.EARLY_DEADLINE(EARLY_DEADLINE)) player(.audio_published(audio_published),.ctrl_raw(field_active?1'b1:ctrl_raw),.raw_frame(raw_frame),
  .raw_mode(raw_mode),.raw_fifo_clear(raw_fifo_clear),.event_owner(event_owner),.event_timbre(event_timbre),
  .raw_cleanup_valid(raw_cleanup_valid),.raw_cleanup_ready(raw_cleanup_ready),.raw_cleanup_done(raw_cleanup_done),
  .raw_cleanup_sources(raw_cleanup_sources),.raw_cleanup_all(raw_cleanup_all),.raw_cleanup_revision(raw_cleanup_revision),
  .raw_last_audible(raw_last_audible),.raw_completed_barrier(raw_completed_barrier),.raw_published_valid(raw_published_valid),.raw_barrier_busy(raw_barrier_busy),.event_write_valid(event_write_valid),.event_write_index(event_write_index),.event_write_data(event_write_data),.event_write_ready(event_write_ready),
  .clk(clk),.rst(rst),.sample_tick(sample_tick),.stereo_locked(stereo_locked),.ctrl_valid(player_cv),.ctrl_ready(player_cr),
  .ctrl_cmd(player_cmd),.ctrl_epoch(player_ep),.ctrl_arg(player_arg),.header_valid(field_active?field_hv:hv),.eof_seen(field_active?field_eof:eof),.last_verified_time(field_active?field_verified:last_time),.parser_error(field_active?8'd0:parser_error),
  .parser_clear(pc),.parser_enable(pe),.record_valid(field_active?field_rv:mvalid),.record_ready(mready),.record_data(field_active?field_record:record_out),.visible_records(field_active?field_visible:visible),
  .local_backlog(local_backlog),.event_valid(event_valid),.event_ready(event_ready),.event_packet(event_packet),.dispatch_done(dispatch_done),
  .state(score_state),.error_code(score_error),.music_time(score_time),.epoch(player_epoch),
  .logical_held(logical_held),.logical_notes(logical_notes),.logical_pressures(logical_pressures),.guide_held(guide_held),.guide_notes(guide_notes),.reload_request(reload_request),
  .records_consumed(records_consumed),.events_offered(events_offered),.events_accepted(events_accepted),.events_completed(events_completed),
  .deadline_count(deadline_count),.token_exhaustions(token_exhaustions),.stops(stops),.last_group_cycles(last_group_cycles),.observe_dispatch_active(observe_dispatch_active),.observe_teach(observe_teach),.observe_loop(observe_loop));
 wire[26:0] palette;wire prefix,led_busy;wire [215:0] colors;wire [5:0] unmapped;wire [31:0] invalid_guide,led_frames;
 r28_serial_guide guide(.raw_mode(raw_mode),.palette(palette),.palette_valid(),
  .clk(clk),.rst(rst),.cfg_valid(guide_cfg_valid),.cfg_prefix(guide_cfg_prefix),.cfg_order(guide_cfg_order),.cfg_lead(guide_cfg_lead),
  .local_notes(local_notes),.held(guide_held),.notes(guide_notes),.preview_valid(preview_valid),.preview_time(preview_time),.music_time(score_time),
  .preview_notes(preview_notes),.player_state(score_state),.error_code(score_error),.prefix(prefix),.colors(colors),.unmapped_count(unmapped),.invalid_config_count(invalid_guide));
 r28_palette_serializer #(.T0H(16*(CLK_FREQ_HZ/1_000_000)/50),.T0L(48*(CLK_FREQ_HZ/1_000_000)/50),.T1H(34*(CLK_FREQ_HZ/1_000_000)/50),.T1L(30*(CLK_FREQ_HZ/1_000_000)/50),.RESET_CLOCKS(CLK_FREQ_HZ/3125),.REFRESH_CLOCKS(CLK_FREQ_HZ/200)) leds(.clk(clk),.rst(rst),.prefix(prefix),.palette(palette),.led_dout(led_dout),.busy(led_busy),.completed_frames(led_frames));
endmodule

module scheduled_score_probe (
 input wire clk,rst,sample_tick,stereo_locked,
 input wire spi_sck,fpga_cs_n,sd_cs_n,spi_mosi,output wire spi_miso,spi_miso_oe,
 input wire local_backlog,output wire event_valid,input wire event_ready,output wire [904:0] event_packet,
 input wire dispatch_done,input wire [55:0] local_notes,
 input wire guide_cfg_valid,guide_cfg_prefix,input wire [23:0] guide_cfg_order,input wire [13:0] guide_cfg_lead,
 output wire led_dout,output wire [7:0] score_state,score_error,
 output wire [63:0] score_time,output wire [31:0] deadline_count,
 output wire [255:0] observe_score_status,
 output wire observe_dispatch_active,
 output wire observe_teach,observe_loop,
 input wire field_valid,field_start,input wire [1:0] field_size,
 output wire field_ready,field_active,field_rejected,field_committed,field_running
);
score_subsystem #(.STREAM_STATUS_CRC(1),.ENABLE_S10_ROUTE(1),.ENABLE_S11(1)) dut(.clk(clk),.rst(rst),.sample_tick(sample_tick),.stereo_locked(stereo_locked),.spi_sck(spi_sck),.fpga_cs_n(fpga_cs_n),.sd_cs_n(sd_cs_n),.spi_mosi(spi_mosi),.spi_miso(spi_miso),.spi_miso_oe(spi_miso_oe),.local_backlog(local_backlog),.event_valid(event_valid),.event_ready(event_ready),.event_packet(event_packet),.dispatch_done(dispatch_done),.local_notes(local_notes),.guide_cfg_valid(guide_cfg_valid),.guide_cfg_prefix(guide_cfg_prefix),.guide_cfg_order(guide_cfg_order),.guide_cfg_lead(guide_cfg_lead),.led_dout(led_dout),.score_state(score_state),.score_error(score_error),.score_time(score_time),.deadline_count(deadline_count),.observe_score_status(observe_score_status),.observe_dispatch_active(observe_dispatch_active),.observe_teach(observe_teach),.observe_loop(observe_loop),.field_valid(field_valid),.field_start(field_start),.field_size(field_size),.field_ready(field_ready),.field_active(field_active),.field_rejected(field_rejected),.field_committed(field_committed),.field_running(field_running));
endmodule
