// FPGA-only observer -> DSP/charts -> pixel renderer -> TMDS -> OSER10/TLVDS.
// Pixel/serial clocks are the outputs of the native 40/200 MHz PLL wrapper.
module visual_display #(
 parameter COS_FILE="src/visual_cos_q16.mem",BOUNDS_FILE="src/visual_band_bounds.mem",FONT_FILE="src/visual_font.mem"
)(
 input wire clk,audio_rst,display_reset,pixel_clk,serial_clk,pll_locked,
 input wire observe_load,input wire signed [15:0] observe_l,observe_r,
 input wire [511:0] status,input wire [1:0] display_scale,input wire test_pattern,
 output wire [3:0] tmds_p,tmds_n,
 output wire [63:0] dac_observed_count,visual_captured,visual_skipped,
 output wire [31:0] snapshots_published,snapshots_presented,
 output wire [18:0] last_processing_cycles,output wire display_error
);
 wire process_rst,pixel_rst,sv;wire signed [15:0] sl,sr;wire [63:0] sid;
 visual_reset_bridge rb(.audio_clk(clk),.pixel_clk(pixel_clk),.reset_request(audio_rst||display_reset),.pll_locked(pll_locked),
  .process_rst(process_rst),.pixel_rst(pixel_rst));
 visual_dac_observer observer(.clk(clk),.audio_rst(audio_rst),.observe_load(observe_load),.observe_l(observe_l),.observe_r(observe_r),
  .sample_valid(sv),.sample_l(sl),.sample_r(sr),.sample_id(sid),.observed_count(dac_observed_count));
 wire [10:0] x;wire [9:0] y;wire de,hs,vs,vblank,frame_start;
 video_timing_800x600 timing(.pixel_clk(pixel_clk),.rst(pixel_rst),.x(x),.y(y),.de(de),.hs(hs),.vs(vs),.vblank(vblank),.frame_start(frame_start));
 wire wre,xre,sre,fv;wire [9:0] wa,xa;wire [7:0] sa;wire [15:0] wd,xd,sd;
 wire [1023:0] metadata;wire [63:0] observed,waiting;wire [31:0] windows;
 visual_snapshot_engine #(.COS_FILE(COS_FILE),.BOUNDS_FILE(BOUNDS_FILE)) snapshots(
  .clk(clk),.pixel_clk(pixel_clk),.rst(process_rst),.pixel_rst(pixel_rst),.audio_rst(audio_rst),.sample_valid(sv),.sample_l(sl),.sample_r(sr),.sample_id(sid),
  .status(status),.display_scale(display_scale),.vblank(vblank),
  .wave_read_enable(wre),.xy_read_enable(xre),.spectrum_read_enable(sre),.wave_read_address(wa),.xy_read_address(xa),.spectrum_read_address(sa),
  .wave_read_data(wd),.xy_read_data(xd),.spectrum_read_data(sd),.front_valid(fv),.front_metadata(metadata),
  .observed(observed),.captured(visual_captured),.skipped(visual_skipped),.completed_windows(windows),
  .published(snapshots_published),.presented(snapshots_presented),.waiting_cycles(waiting),.error(display_error),.last_processing_cycles(last_processing_cycles),.total_observed(),.total_captured(),.total_skipped(),.cancelled_samples(),.cancelled_windows(),.delivered_windows(),.outstanding_pairs(),.skipped_reset(),.skipped_processing(),.skipped_waiting());
 wire [23:0] rgb;wire tx_de,tx_hs,tx_vs;
 (* ASYNC_REG="TRUE" *) reg [1:0] test_sync;
 reg test_latched;
 reg [15:0] age_frames;
 reg [31:0] last_sequence;
 reg fresh_snapshot;
 always @(posedge pixel_clk or posedge pixel_rst)begin
  if(pixel_rst)begin test_sync<=0;test_latched<=0;end
  else begin test_sync<={test_sync[0],test_pattern};if(vblank)test_latched<=test_sync[1];end
 end
 always @(posedge pixel_clk or posedge pixel_rst)begin
  if(pixel_rst)begin age_frames<=0;last_sequence<=0;fresh_snapshot<=1;end
  else if(!fv||metadata[159:128]!=last_sequence)begin
   age_frames<=0;last_sequence<=metadata[159:128];fresh_snapshot<=1;
  end else if(frame_start)begin
   if(fresh_snapshot)fresh_snapshot<=0;
   else if(age_frames!=65535)age_frames<=age_frames+1'b1;
  end
 end
 visual_pixel_renderer #(.FONT_FILE(FONT_FILE)) renderer(.pixel_clk(pixel_clk),.rst(pixel_rst),.x(x),.y(y),.de(de),.hs(hs),.vs(vs),
  .test_pattern(test_latched),.front_valid(fv),.metadata(metadata),.age_frames(age_frames),.wave_re(wre),.xy_re(xre),.spectrum_re(sre),
  .wave_addr(wa),.xy_addr(xa),.spectrum_addr(sa),.wave_data(wd),.xy_data(xd),.spectrum_data(sd),.rgb(rgb),.out_de(tx_de),.out_hs(tx_hs),.out_vs(tx_vs));
 video_dvi_tx tx(.pixel_clk(pixel_clk),.serial_clk(serial_clk),.rst(pixel_rst),.rgb(rgb),.de(tx_de),.hs(tx_hs),.vs(tx_vs),.tmds_p(tmds_p),.tmds_n(tmds_n));
endmodule
