// Board-independent I/O composition. No new physical pin bindings.
// Existing ADC/EC11 and official video PLL logic are unchanged.
module instrument_io #(
    parameter integer AUDIO_RATE_HZ=128000,
 parameter integer COMM_SEPARATE=0,
 parameter integer CLK_FREQ_HZ=50_000_000, SPI_CLK_HZ=1_000_000,
 parameter integer EXTERNAL_VIDEO_REFERENCE=0,
 parameter integer EC11_DEBOUNCE_US=500,GLIDE_EC11_DEBOUNCE_US=1000,
 parameter integer EC11_TRANSITIONS_PER_STEP=4,EC11_DIR_INVERT=0
) (
    input wire spi_sck,score_cs_n,sd_cs_n,spi_mosi,
    output wire spi_miso,spi_miso_oe,guide_led_dout,
    input wire guide_cfg_valid,guide_cfg_prefix,
    input wire [23:0] guide_cfg_order,
    input wire [13:0] guide_cfg_lead,
    output wire [7:0] score_state,score_error,
    output wire [63:0] score_time,
    output wire [31:0] score_deadline_count,
    output wire gain_cfg_valid,
    output wire [15:0] gain_cfg_local,gain_cfg_external,
    output wire gain_cfg_local_mute,gain_cfg_external_mute,
    output wire stream_error,
    output wire [31:0] external_underflow_count,
    output wire fx_cfg_valid,
    output wire [351:0] fx_cfg_data,
    output wire fx_error,
    output wire pan_valid,
    output wire [5:0] pan_slot,
    output wire [63:0] pan_id,
    output wire [15:0] pan_generation,
    output wire [8:0] pan_value,
    input wire comm_clk, input wire clk, input wire video_ref_clk,
    input wire rst,
    input wire adc_dout,
    output wire adc_cs_n,adc_sclk,adc_din,
    input wire ec11_s1,ec11_s2,glide_ec11_s1,glide_ec11_s2,
    output wire [2:0] timbre_id,
    input wire octave_up_pulse,
    input wire octave_down_pulse,
    output wire dac_bck,
    output wire dac_ws,
    output wire dac_din,
    output wire frame_pulse,
    output wire sample_overrun,
    output wire underrun,
    output wire observe_load,
    output wire signed [15:0] observe_l,observe_r,
    output wire [31:0] observe_slot_valid,observe_slot_gate,
    output wire [95:0] observe_slot_timbres,
    output wire [351:0] observe_fx_config,
    output wire [31:0] observe_fx_version,
    output wire observe_fx_bypass,observe_teach,observe_loop,
    output wire [2:0] observe_stream_state,
    input wire display_reset,input wire [1:0] display_scale,input wire display_test_pattern,
    output wire [3:0] video_p,video_n,
    output wire display_error,output wire [31:0] display_published,display_presented,
    output wire [18:0] display_processing_cycles,
 input wire control_cs_n,
 output wire [2:0] phone_link_state,
 output wire [31:0] phone_held_keys,phone_rejected_transactions,phone_cs_conflicts,phone_lease_expirations,phone_cleanup_offs,
 output wire [3:0] glide_code,
 output wire [2:0] record_state,output wire [31:0] record_error,
 output wire [63:0] recording_id,record_captured_pairs,record_retired_pairs,
 output wire [12:0] record_buffered_pairs,output wire [63:0] record_captured_cells

);
    wire [79:0] pressure_raw;
    wire [63:0] pressure_normalized;
    wire [79:0] calibrated_frame;
    generate for(genvar c=0;c<8;c=c+1)begin: normalized_channel
        assign calibrated_frame[c*10+:10]={2'b00,pressure_normalized[c*8+:8]};
    end endgenerate
    wire pressure_valid, step_pulse, step_dir;
    wire ec11_ready, ec11_invalid;
    wire signed [31:0] ec11_position;
    wire glide_step_pulse,glide_step_dir;
    wire [3:0] local_glide_code;
    pressure_input #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .SPI_CLK_HZ(SPI_CLK_HZ)) u_adc (
        .sys_clk(clk), .rst_n(~rst), .adc_cs_n(adc_cs_n),
        .adc_sclk(adc_sclk), .adc_din(adc_din), .adc_dout(adc_dout),
        .pressure_raw(pressure_raw), .pressure_normalized(pressure_normalized), .pressure_valid(pressure_valid)
    );
    ec11_encoder #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_US(EC11_DEBOUNCE_US),
        .TRANSITIONS_PER_STEP(EC11_TRANSITIONS_PER_STEP), .DIR_INVERT(EC11_DIR_INVERT)) u_ec11 (
        .sys_clk(clk), .rst_n(~rst), .s1(ec11_s1), .s2(ec11_s2),
        .ready(ec11_ready), .step_pulse(step_pulse), .step_dir(step_dir),
        .position(ec11_position), .invalid_pulse(ec11_invalid)
    );
    ec11_encoder #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_US(GLIDE_EC11_DEBOUNCE_US),
        .TRANSITIONS_PER_STEP(EC11_TRANSITIONS_PER_STEP), .DIR_INVERT(EC11_DIR_INVERT)) u_glide_ec11 (
        .sys_clk(clk),.rst_n(~rst),.s1(glide_ec11_s1),.s2(glide_ec11_s2),
        .ready(),.step_pulse(glide_step_pulse),.step_dir(glide_step_dir),
        .position(),.invalid_pulse()
    );
    // Legacy glide_code transport now carries the release-time setting.
    release_parameter_control u_release_parameter (
        .clk(clk),.rst(rst),.step_pulse(glide_step_pulse),
        .step_dir(glide_step_dir),.glide_code(local_glide_code)
    );
 wire video_pixel_clk,video_serial_clk,video_pll_locked;
 video_pll_800x600 video_pll(.clkin(EXTERNAL_VIDEO_REFERENCE ? video_ref_clk : clk),.reset(rst),.lock(video_pll_locked),
 .clkout0(video_serial_clk),.clkout1(video_pixel_clk));
 instrument_core #(.AUDIO_RATE_HZ(AUDIO_RATE_HZ),.COMM_SEPARATE(COMM_SEPARATE),.CLK_FREQ_HZ(CLK_FREQ_HZ),.PRESSURE_PRENORMALIZED(1),.VIBRATO_STEP(8)) u_core(
 .spi_sck(spi_sck),
 .score_cs_n(score_cs_n),
 .sd_cs_n(sd_cs_n),
 .spi_mosi(spi_mosi),
 .spi_miso(spi_miso),
 .spi_miso_oe(spi_miso_oe),
 .guide_led_dout(guide_led_dout),
 .guide_cfg_valid(guide_cfg_valid),
 .guide_cfg_prefix(guide_cfg_prefix),
 .guide_cfg_order(guide_cfg_order),
 .guide_cfg_lead(guide_cfg_lead),
 .score_state(score_state),
 .score_error(score_error),
 .score_time(score_time),
 .score_deadline_count(score_deadline_count),
 .gain_cfg_valid(gain_cfg_valid),
 .gain_cfg_local(gain_cfg_local),
 .gain_cfg_external(gain_cfg_external),
 .gain_cfg_local_mute(gain_cfg_local_mute),
 .gain_cfg_external_mute(gain_cfg_external_mute),
 .stream_error(stream_error),
 .external_underflow_count(external_underflow_count),
 .fx_cfg_valid(fx_cfg_valid),
 .fx_cfg_data(fx_cfg_data),
 .fx_error(fx_error),
 .pan_valid(pan_valid),
 .pan_slot(pan_slot),
 .pan_id(pan_id),
 .pan_generation(pan_generation),
 .pan_value(pan_value),
 .comm_clk(comm_clk),.clk(clk),
 .rst(rst),
 .pressure_raw(calibrated_frame),
 .pressure_valid(pressure_valid),
 .step_pulse(step_pulse),
 .step_dir(step_dir),
 .timbre_id(timbre_id),
 .local_glide_code(local_glide_code),
 .octave_up_pulse(octave_up_pulse),
 .octave_down_pulse(octave_down_pulse),
 .dac_bck(dac_bck),
 .dac_ws(dac_ws),
 .dac_din(dac_din),
 .frame_pulse(frame_pulse),
 .sample_overrun(sample_overrun),
 .underrun(underrun),
 .observe_load(observe_load),
 .observe_l(observe_l),
 .observe_r(observe_r),
 .observe_slot_valid(observe_slot_valid),
 .observe_slot_gate(observe_slot_gate),
 .observe_slot_timbres(observe_slot_timbres),
 .observe_fx_config(observe_fx_config),
 .observe_fx_version(observe_fx_version),
 .observe_fx_bypass(observe_fx_bypass),
 .observe_teach(observe_teach),
 .observe_loop(observe_loop),
 .observe_stream_state(observe_stream_state),
 .video_pixel_clk(video_pixel_clk),
 .video_serial_clk(video_serial_clk),
 .video_pll_locked(video_pll_locked),
 .display_reset(display_reset),
 .display_scale(display_scale),
 .display_test_pattern(display_test_pattern),
 .video_p(video_p),
 .video_n(video_n),
 .display_error(display_error),
 .display_published(display_published),
 .display_presented(display_presented),
 .display_processing_cycles(display_processing_cycles),
 .control_cs_n(control_cs_n),
 // Direct field-test controls are not part of this I/O interface. App field
 // commands retain their existing route through the core_mcu_control config bridge.
 .field_valid(1'b0),.field_start(1'b0),.field_size(2'd0),
 .phone_link_state(phone_link_state),
 .phone_held_keys(phone_held_keys),
 .phone_rejected_transactions(phone_rejected_transactions),
 .phone_cs_conflicts(phone_cs_conflicts),
 .phone_lease_expirations(phone_lease_expirations),
 .phone_cleanup_offs(phone_cleanup_offs),
 .glide_code(glide_code),.record_state(record_state),.record_error(record_error),.recording_id(recording_id),
 .record_captured_pairs(record_captured_pairs),.record_retired_pairs(record_retired_pairs),
 .record_buffered_pairs(record_buffered_pairs),.record_captured_cells(record_captured_cells));
endmodule
