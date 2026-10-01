module score_subsystem #(parameter integer TOKEN_WIDTH=64, WATCHDOG_CLOCKS=5000000)(
 input wire clk,rst,sample_tick,stereo_locked,
 input wire spi_sck,fpga_cs_n,sd_cs_n,spi_mosi,output wire spi_miso,spi_miso_oe,
 input wire local_backlog,output wire event_valid,input wire event_ready,output wire [904:0] event_packet,
 input wire dispatch_done,input wire [55:0] local_notes,
 input wire guide_cfg_valid,guide_cfg_prefix,input wire [23:0] guide_cfg_order,input wire [13:0] guide_cfg_lead,
 output wire led_dout,output wire [7:0] score_state,score_error,
 output wire [63:0] score_time,output wire [31:0] deadline_count
);
 wire cv,cr,pv,pr,pdone,pok,pc,pe,rv,rr,hv,eof;
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
 wire clear=pc||(cv&&cr&&(cmd==3||cmd==6||cmd==7));
 score_spi_transport #(.WATCHDOG_CLOCKS(WATCHDOG_CLOCKS)) transport(
  .clk(clk),.rst(rst),.spi_sck(spi_sck),.fpga_cs_n(fpga_cs_n),.sd_cs_n(sd_cs_n),.spi_mosi(spi_mosi),
  .spi_miso(spi_miso),.spi_miso_oe(spi_miso_oe),.ctrl_valid(cv),.ctrl_ready(cr),.ctrl_cmd(cmd),.ctrl_epoch(ep),.ctrl_arg(arg),
  .page_valid(pv),.page_ready(pr),.page_sequence(seq),.page_done(pdone),.page_ok(pok),.page_addr(addr),.page_data(data),
  .player_state(score_state),.player_error(score_error),.reload_request(reload_request),.active_epoch(active_epoch),
  .accepted_pages(accepted_pages),.rejected_transactions(rejected_transactions),.cs_conflicts(cs_conflicts),.link_timeout(link_timeout));
 score_file_parser parser(
  .clk(clk),.rst(rst),.clear(clear),.enable(pe),.page_valid(pv),.page_ready(pr),.page_sequence(seq),
  .page_done(pdone),.page_ok(pok),.page_addr(addr),.page_data(data),
  .record_valid(rv),.record_ready(rr),.record_data(record_in),.header_valid(hv),.eof_seen(eof),
  .end_time(end_time),.last_verified_time(last_time),.total_records(total_records),.parsed_records(parsed_records),.error_code(parser_error));
 score_record_fifo records(
  .clk(clk),.rst(rst),.clear(clear),.s_valid(rv),.s_ready(rr),.s_record(record_in),
  .m_valid(mvalid),.m_ready(mready),.m_record(record_out),.occupancy(occupancy),.visible_records(visible),
  .inserted(inserted),.consumed(consumed),.preview_valid(preview_valid),.preview_time(preview_time),.preview_notes(preview_notes));
 score_sequencer #(.TOKEN_WIDTH(TOKEN_WIDTH)) player(
  .clk(clk),.rst(rst),.sample_tick(sample_tick),.stereo_locked(stereo_locked),.ctrl_valid(cv),.ctrl_ready(cr),
  .ctrl_cmd(cmd),.ctrl_epoch(ep),.ctrl_arg(arg),.header_valid(hv),.eof_seen(eof),.last_verified_time(last_time),.parser_error(parser_error),
  .parser_clear(pc),.parser_enable(pe),.record_valid(mvalid),.record_ready(mready),.record_data(record_out),.visible_records(visible),
  .local_backlog(local_backlog),.event_valid(event_valid),.event_ready(event_ready),.event_packet(event_packet),.dispatch_done(dispatch_done),
  .state(score_state),.error_code(score_error),.music_time(score_time),.epoch(player_epoch),
  .logical_held(logical_held),.logical_notes(logical_notes),.logical_pressures(logical_pressures),.guide_held(guide_held),.guide_notes(guide_notes),.reload_request(reload_request),
  .records_consumed(records_consumed),.events_offered(events_offered),.events_accepted(events_accepted),.events_completed(events_completed),
  .deadline_count(deadline_count),.token_exhaustions(token_exhaustions),.stops(stops),.last_group_cycles(last_group_cycles));
 wire prefix,led_busy;wire [215:0] colors;wire [5:0] unmapped;wire [31:0] invalid_guide,led_frames;
 score_guide guide(
  .clk(clk),.rst(rst),.cfg_valid(guide_cfg_valid),.cfg_prefix(guide_cfg_prefix),.cfg_order(guide_cfg_order),.cfg_lead(guide_cfg_lead),
  .local_notes(local_notes),.held(guide_held),.notes(guide_notes),.preview_valid(preview_valid),.preview_time(preview_time),.music_time(score_time),
  .preview_notes(preview_notes),.player_state(score_state),.error_code(score_error),.prefix(prefix),.colors(colors),.unmapped_count(unmapped),.invalid_config_count(invalid_guide));
 ws2812_guide_serializer leds(.clk(clk),.rst(rst),.prefix(prefix),.colors(colors),.led_dout(led_dout),.busy(led_busy),.completed_frames(led_frames));
endmodule
