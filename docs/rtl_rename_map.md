# FPGA 模块与文件新旧名称对照

2026-11 对 `fpga/` 做了一次统一改名：去掉开发阶段号（`stage7`～`stage11`、`rev7`）、开发轮次前缀（`r18_`、`r22_`、`r28_` 等）和协议阶段前缀（`s9_`、`s10_`、`s11_`），改成按功能命名，并把多处共用的小模块拆到 `common/`。

只改了模块名与文件名，**实例名和逻辑均未改动**，时序约束中的层次路径（如 `u_instrument/u_core/base/...`）保持不变。报告、旧文档或旧日志中出现的旧名可按下表对照。

## 模块（共 50 个）

路径相对 `fpga/src/`。

| 旧模块名 | 新模块名 | 文件 | 说明 |
|---|---|---|---|
| `instrument_board_stage11_rev7` | `instrument_top` | `top/instrument_board_stage11_rev7.v` → `top/instrument_top.v` |  |
| `instrument_io_stage11` | `instrument_io` | `top/instrument_io_stage11.v` → `top/instrument_io.v` |  |
| `instrument_core_stage11` | `instrument_core` | `top/instrument_core_stage11.v` → `top/instrument_core.v` |  |
| `instrument_core_stage10` | `core_mcu_media` | `top/instrument_core_stage10.v` → `top/core_mcu_media.v` |  |
| `instrument_core_stage9` | `core_mcu_control` | `top/instrument_core_stage9.v` → `top/core_mcu_control.v` |  |
| `instrument_core_stage8` | `core_audio_video` | `top/instrument_core_stage8.v` → `top/core_audio_video.v` |  |
| `instrument_core_stage7` | `core_audio` | `top/instrument_core_stage7.v` → `top/core_audio.v` |  |
| `system_pll_30m` | `system_pll` | `top/system_pll_30m.v` → `top/system_pll.v` |  |
| `pressure_input_top` | `pressure_input` | `input/pressure_input_top.v` → `input/pressure_input.v` |  |
| `r28_local_adapter` | `local_event_adapter` | `event/r28_local_adapter.v` → `event/local_event_adapter.v` |  |
| `r28_event_pool` | `event_pool` | `event/r28_event_pool.v` → `event/event_pool.v` |  |
| `r28_instrument_engine` | `synth_engine` | `synth/r28_instrument_engine.v` → `synth/synth_engine.v` |  |
| `r28_control_audio_probe` | `synth_engine_core` | `synth/r28_control_audio_probe.v` → `synth/synth_engine_core.v` |  |
| `r28_serial_control` | `voice_allocator` | `synth/r28_serial_control.v` → `synth/voice_allocator.v` |  |
| `r28_frame_audio` | `voice_frame_audio` | `synth/r28_frame_audio.v` → `synth/voice_frame_audio.v` |  |
| `r28_shared_envelope_glide` | `envelope_glide_frontend` | `synth/r28_shared_envelope_glide.v` → `synth/envelope_glide_frontend.v` |  |
| `r28_glide_pipeline` | `glide_pipeline` | `synth/r28_glide_pipeline.v` → `synth/glide_pipeline.v` |  |
| `r28_shared_timbre_lfo` | `timbre_lfo` | `synth/r28_shared_timbre_lfo.v` → `synth/timbre_lfo.v` |  |
| `osc_ii4_pitch_prepare` | `osc_pitch_prepare` | `synth/osc_ii4_pitch_prepare.v` → `synth/osc_pitch_prepare.v` |  |
| `osc_ii4_backend` | `osc_backend` | `synth/osc_ii4_backend.v` → `synth/osc_backend.v` |  |
| `osc48_voice_metrics` | `voice_metrics` | `synth/osc48_voice_metrics.v` → `synth/voice_metrics.v` |  |
| `fx128_multirate` | `fx_multirate` | `effects/fx128_multirate.v` → `effects/fx_multirate.v` |  |
| `fx128_downsample` | `fx_downsample` | （文件不变） | 同文件内的辅助模块 |
| `r46_serial_effects` | `fx_engine` | `effects/r46_serial_effects.v` → `effects/fx_engine.v` |  |
| `r32_reverb_history` | `fx_reverb_history` | （文件不变） | 同文件内的辅助模块 |
| `r32_ram18_sdp` | `ram18_sdp` | `effects/fx_history18.v` → `common/ram18_sdp.v` | 拆分为独立文件 |
| `r32_ram18_dp` | `ram18_dp` | `effects/fx_history18.v` → `common/ram18_dp.v` | 拆分为独立文件 |
| `r54_full_equal` | `wide_equal` | `common/r54_full_equal.v` → `common/wide_equal.v` |  |
| `r22_control_link` | `mcu_control_link` | `mcu_link/r22_control_link.v` → `mcu_link/mcu_control_link.v` |  |
| `r22_event_endpoint` | `mcu_event_endpoint` | `mcu_link/r22_event_endpoint.v` → `mcu_link/mcu_event_endpoint.v` |  |
| `r22_config_bridge` | `mcu_config_bridge` | `mcu_link/r22_config_bridge.v` → `mcu_link/mcu_config_bridge.v` |  |
| `s9_session_control` | `mcu_session_control` | `mcu_link/s9_session_control.v` → `mcu_link/mcu_session_control.v` |  |
| `s9_keymap_config` | `keymap_config` | `mcu_link/s9_keymap_config.v` → `mcu_link/keymap_config.v` |  |
| `s10_pcm_transport` | `mcu_pcm_transport` | `mcu_link/s10_pcm_transport.v` → `mcu_link/mcu_pcm_transport.v` |  |
| `s11_spi_response` | `mcu_spi_response` | `mcu_link/s11_spi_response.v` → `mcu_link/mcu_spi_response.v` |  |
| `r24_spi_edges` | `spi_edge_sampler` | `score/score_spi_transport.v` → `common/spi_edge_sampler.v` | 拆分为独立文件 |
| `r18_recording_subsystem` | `recording_subsystem` | `record/r18_recording_subsystem.v` → `record/recording_subsystem.v` |  |
| `r18_cell_prefetch_control` | `rec_prefetch_control` | `record/r18_cell_prefetch_control.v` → `record/rec_prefetch_control.v` |  |
| `r18_config_observer` | `rec_config_observer` | `record/r18_config_observer.v` → `record/rec_config_observer.v` |  |
| `r28_execution_observer` | `rec_execution_observer` | `record/r28_execution_observer.v` → `record/rec_execution_observer.v` |  |
| `s11_event_recorder` | `rec_event_recorder` | `record/s11_event_recorder.v` → `record/rec_event_recorder.v` |  |
| `s11_pcm_recorder` | `rec_pcm_recorder` | `record/s11_pcm_recorder.v` → `record/rec_pcm_recorder.v` |  |
| `rec48_downsample` | `rec_downsample` | `record/rec48_downsample.v` → `record/rec_downsample.v` |  |
| `r28_borrowed_score_parser` | `score_page_parser` | `score/r28_borrowed_score_parser.v` → `score/score_page_parser.v` |  |
| `r28_serial_guide` | `score_led_guide` | `score/r28_serial_guide.v` → `score/score_led_guide.v` |  |
| `r28_palette_serializer` | `ws2812_serializer` | （文件不变） | 同文件内的辅助模块 |
| `s11_field_test_source` | `field_test_source` | `score/s11_field_test_source.v` → `score/field_test_source.v` |  |
| `margin_spectrum_code` | `spectrum_level_code` | （文件不变） | 同文件内的辅助模块 |
| `margin_spectrum_decode` | `spectrum_level_decode` | （文件不变） | 同文件内的辅助模块 |
| `margin_spectrum_bars_core` | `spectrum_bars_core` | （文件不变） | 同文件内的辅助模块 |

## 其他文件

路径相对 `fpga/`。

| 旧文件 | 新文件 |
|---|---|
| `constraints/instrument_board_stage11_rev7.cst` | `constraints/instrument_top.cst` |
| `constraints/instrument_board_stage11_rev7.sdc` | `constraints/instrument_top.sdc` |
| `src/mcu_link/s9_constants.vh` | `src/mcu_link/mcu_protocol_constants.vh` |
| `src/record/rec48_ram.mem` | `src/record/rec_downsample_coeff.mem` |
| `src/video/r30_cosine_init.vh` | `src/video/visual_cosine_init.vh` |
| `src/video/r30_text_init.vh` | `src/video/visual_text_init.vh` |
| `tools/r30_generate_rom_init.py` | `tools/generate_rom_init.py` |

`mcu_protocol_constants.vh` 内的宏名（`S9_*`）未改，与固件 `s9_constants.h` 保持一致。
