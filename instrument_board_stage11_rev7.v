// Tang Mega 60K NEO Dock 31004, REV7 physical board binding.
// E1 rotation: Vibrato (500 us). E2 rotation: release duration (1000 us).
// E1 press: octave up. E2 press: octave down. KEY2: reset.
// The complete, frozen Stage11 system remains the sole instrument instance.
module instrument_board_stage11_rev7 #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer SYSTEM_DIVIDE = 2,
    parameter integer ADC_SPI_CLK_HZ = 1_000_000,
    parameter integer BUTTON_DEBOUNCE_US = 2_000,
    parameter integer BUTTON_RELEASE_DEBOUNCE_US = 20_000
) (
    input wire sys_clk,
    input wire rst_n,
    input wire adc_miso,
    output wire adc_cs_n, adc_sclk, adc_mosi,
    input wire enc1_a, enc1_b, enc1_sw_n,
    input wire enc2_a, enc2_b, enc2_sw_n,
    input wire mcu_spi_sck, mcu_spi_mosi,
    input wire mcu_sd_cs_n, mcu_cs1_n, mcu_cs2_n,
    output wire mcu_spi_miso,
    output wire ws2812_data,
    output wire audio_bclk, audio_lrck, audio_din,
    output wire pa_disable,
    output wire [3:0] video_p, video_n
);
    // Free-running divide-by-two: reset must not truncate clock pulses.
    // Physical global-clock routing still requires target-device P&R verification.
    (* syn_keep = 1 *) reg system_clk_div2 = 1'b0;
    always @(posedge sys_clk) system_clk_div2 <= ~system_clk_div2;
    wire system_clk = SYSTEM_DIVIDE == 2 ? system_clk_div2 : sys_clk;
    localparam integer SYSTEM_CLK_HZ = CLK_FREQ_HZ / SYSTEM_DIVIDE;
    // Reuse the existing board reset contract: asynchronous assertion,
    // two-clock release, and an initialized power-on reset request.
    reg [1:0] reset_release = 2'b11;
    always @(posedge system_clk or negedge rst_n) begin
        if (!rst_n) reset_release <= 2'b11;
        else reset_release <= {reset_release[0], 1'b0};
    end
    wire rst = reset_release[1];
    assign pa_disable = !rst_n || rst;

    wire octave_up_pulse, octave_down_pulse;
    button_debounce_onepulse #(
        .CLK_FREQ_HZ(SYSTEM_CLK_HZ), .DEBOUNCE_US(BUTTON_DEBOUNCE_US),
        .RELEASE_DEBOUNCE_US(BUTTON_RELEASE_DEBOUNCE_US)
    ) u_octave_up (
        .clk(system_clk), .rst(rst), .key_n(enc1_sw_n),
        .press_pulse(octave_up_pulse)
    );
    button_debounce_onepulse #(
        .CLK_FREQ_HZ(SYSTEM_CLK_HZ), .DEBOUNCE_US(BUTTON_DEBOUNCE_US),
        .RELEASE_DEBOUNCE_US(BUTTON_RELEASE_DEBOUNCE_US)
    ) u_octave_down (
        .clk(system_clk), .rst(rst), .key_n(enc2_sw_n),
        .press_pulse(octave_down_pulse)
    );

    wire reply_bit, protocol_oe, guide_wave;
    reg miso_ready = 1'b0;
    always @(posedge system_clk or negedge rst_n) begin
        if (!rst_n) miso_ready <= 1'b0;
        else if (rst) miso_ready <= 1'b0;
        else miso_ready <= 1'b1;
    end
    // Raw deselection/conflict/reset suppresses the physical driver immediately,
    // even before the protocol synchronizers observe the changed chip selects.
    wire miso_oe = miso_ready && rst_n && !rst && mcu_sd_cs_n &&
                   (mcu_cs1_n ^ mcu_cs2_n) && protocol_oe;
    assign mcu_spi_miso = miso_oe ? reply_bit : 1'bz;

    // REV8 J13-1 / E14 drives eight external LEDs directly.
    // No Dock Q16 inversion or U15 prefix on this connection.
    assign ws2812_data = (!rst_n || rst) ? 1'b0 : guide_wave;

    instrument_io_stage11 #(
        .CLK_FREQ_HZ(SYSTEM_CLK_HZ), .SPI_CLK_HZ(ADC_SPI_CLK_HZ), .EXTERNAL_VIDEO_REFERENCE(1), .COMM_SEPARATE(1),
        .EC11_DEBOUNCE_US(500), .GLIDE_EC11_DEBOUNCE_US(1000),
        .EC11_TRANSITIONS_PER_STEP(4), .EC11_DIR_INVERT(0)
    ) u_instrument (
        .clk(system_clk), .video_ref_clk(sys_clk), .comm_clk(sys_clk), .rst(rst),
        .adc_dout(adc_miso), .adc_cs_n(adc_cs_n),
        .adc_sclk(adc_sclk), .adc_din(adc_mosi),
        .ec11_s1(enc1_a), .ec11_s2(enc1_b),
        .glide_ec11_s1(enc2_a), .glide_ec11_s2(enc2_b),
        .octave_up_pulse(octave_up_pulse),
        .octave_down_pulse(octave_down_pulse),
        .spi_sck(mcu_spi_sck), .spi_mosi(mcu_spi_mosi),
        .sd_cs_n(mcu_sd_cs_n), .score_cs_n(mcu_cs1_n),
        .control_cs_n(mcu_cs2_n), .spi_miso(reply_bit),
        .spi_miso_oe(protocol_oe), .guide_led_dout(guide_wave),
        .guide_cfg_valid(1'b1), .guide_cfg_prefix(1'b0),
        .guide_cfg_order(24'hfac688), .guide_cfg_lead(14'd4800),
        .display_reset(1'b0), .display_scale(2'd0),
        .display_test_pattern(1'b0), .video_p(video_p), .video_n(video_n),
        .dac_bck(audio_bclk), .dac_ws(audio_lrck), .dac_din(audio_din),
        // Read-only diagnostics remain internal rather than becoming package IO.
        .score_state(), .score_error(), .score_time(), .score_deadline_count(),
        .gain_cfg_valid(), .gain_cfg_local(), .gain_cfg_external(),
        .gain_cfg_local_mute(), .gain_cfg_external_mute(),
        .stream_error(), .external_underflow_count(), .fx_cfg_valid(),
        .fx_cfg_data(), .fx_error(), .pan_valid(), .pan_slot(), .pan_id(),
        .pan_generation(), .pan_value(), .timbre_id(), .glide_code(),
        .frame_pulse(), .sample_overrun(), .underrun(),
        .observe_load(), .observe_l(), .observe_r(), .observe_slot_valid(),
        .observe_slot_gate(), .observe_slot_timbres(), .observe_fx_config(),
        .observe_fx_version(), .observe_fx_bypass(), .observe_teach(),
        .observe_loop(), .observe_stream_state(), .display_error(),
        .display_published(), .display_presented(), .display_processing_cycles(),
        .phone_link_state(), .phone_held_keys(), .phone_rejected_transactions(),
        .phone_cs_conflicts(), .phone_lease_expirations(), .phone_cleanup_offs(),
        .record_state(), .record_error(), .recording_id(),
        .record_captured_pairs(), .record_retired_pairs(),
        .record_buffered_pairs(), .record_captured_cells()
    );
endmodule
