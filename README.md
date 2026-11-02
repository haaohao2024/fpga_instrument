# FPGA 电子乐器

基于 Gowin GW5AT-60 FPGA 的 64 路独立振荡器电子乐器：128 kHz 音频输出、效果器、SD 卡录音、乐谱与教学、循环叠录、自动伴奏、蓝牙伴奏，配套 BL616 主控固件与 iOS / iPadOS / 安卓 App。

## 目录结构

```
.
├── fpga/                     FPGA 工程（Gowin）
│   ├── formal_one.gprj       工程文件，用 Gowin IDE 直接打开
│   ├── impl/                 综合/布局布线设置（formal_one_process_config.json）；构建后生成 gwsynthesis/、pnr/
│   ├── src/                  RTL（.v/.vh）与 ROM 初始化数据（.mem），按子系统分目录，见下方“FPGA 模块结构”
│   ├── constraints/          引脚约束（.cst）与时序约束（.sdc）
│   └── tools/                ROM 初始化数据生成脚本
├── firmware/bl616/           BL616 主控固件
│   ├── src/                  C 源码与头文件
│   └── project/              CMakeLists.txt、defconfig、链接脚本模板
├── app/
│   ├── ios/                  iOS / iPadOS App（SwiftUI；InstrumentCore 为协议层 Swift 包）
│   └── android/              安卓 App（Kotlin，Gradle 工程）
├── docs/                     协议与接口说明
└── .github/workflows/        iOS 云端编译（GitHub Actions）
```

## 当前版本

- **FPGA**：64 路合成引擎，128 kHz 输出；比特流 `fpga/impl/pnr/formal_one.bin` SHA256 `94ce681a…`（2026-11-02 由本目录源码构建）。
  板上 Flash 目前仍是 2026-11-01 写入的上一版（SHA256 `210f7d2c…`），两版只差已删除的备选分支，电路功能相同；本版尚未上板。
  资源：逻辑 41785/59904（70%）、寄存器 26393/60780（44%）、BSRAM 108/118（92%）、DSP 33.5/118（29%）。
  时序：system_clk 约束 40 MHz，Fmax 43.40 MHz；全部时钟 setup/hold 违例 0。
- **BL616**：64 路赛题测试放行；镜像 SHA256 `c20add42…`，2026-10-31 写入 Flash 偏移 0x40000。
- **App**：2.0 演奏台（安卓 versionName `2.0-stage`）；横屏电子琴面板 + 可滑动钢琴键盘，iOS 26 液态玻璃。

## 构建

### FPGA
用 Gowin IDE（V1.9.12.04）打开 `fpga/formal_one.gprj`，顶层模块 `instrument_board_stage11_rev7`，布局选项 3、布线选项 2，Verilog 标准 SystemVerilog-2017。
RTL 中的 ROM 文件以 `src/<子目录>/xxx.mem` 相对 `fpga/` 引用，请保持 `fpga/` 内的相对位置不变。
`.vh` 头文件与引用它的 `.v` 放在同一目录，综合器按引用文件所在目录查找，无需设置 Include Path；`.mem` 路径相对于 `fpga/` 工程目录。工程可整体复制到任意位置直接打开构建。

## FPGA 模块结构

顶层模块：`instrument_board_stage11_rev7`（`fpga/src/top/instrument_board_stage11_rev7.v`）。
一个文件放一个主模块，文件名与模块名相同；少数文件附带只供本文件使用的小模块（如 `fx_history18.v` 中的 RAM 封装）。

### 实例层次（实例名: 模块名）

```
instrument_board_stage11_rev7              板级顶层：引脚、复位、八度按键
├── system_pll: system_pll_30m             系统 PLL：40 MHz 系统时钟、80 MHz 通信时钟
├── u_octave_up / u_octave_down: button_debounce_onepulse   E1/E2 按压去抖
└── u_instrument: instrument_io_stage11    板级输入与核心的连接
    ├── u_adc: pressure_input_top          8 路压力采集
    │   ├── u_spi: mcp3008_spi             MCP3008 SPI 读数
    │   └── u_scanner: pressure_scanner    CH0~CH7 轮询，整帧发布
    ├── u_ec11 / u_glide_ec11: ec11_encoder        E1 颤音深度、E2 释音时长
    ├── u_release_parameter: release_parameter_control   释音档位 0~7
    ├── video_pll: video_pll_800x600       视频 PLL：40 MHz 像素、200 MHz 串行
    └── u_core: instrument_core_stage11    核心第 11 层：加入录音与配置日志
        ├── base: instrument_core_stage10  第 10 层：加入 BL616 PCM/应答 SPI
        │   ├── transport: s10_pcm_transport       手机音频（伴奏）SPI 接收
        │   │   └── response_encoder: s11_spi_response   录音数据应答编码
        │   └── base: instrument_core_stage9       第 9 层：加入手机控制链路
        │       ├── control: r22_control_link      BL616 控制命令 SPI 链路
        │       │   └── session: s9_session_control    手机会话与租约
        │       ├── events: r22_event_endpoint     手机演奏事件入口
        │       ├── parameters: r22_config_bridge  手机参数（音色/效果/音量/键位）下发
        │       │   └── u_map: s9_keymap_config    键位映射
        │       └── core: instrument_core_stage8   第 8 层：加入 HDMI 可视化
        │           ├── u_audio: instrument_core_stage7   第 7 层：完整音频通路
        │           │   ├── u_control: local_performance_control   压力/旋钮 → 演奏控制
        │           │   ├── u_event_adapter: r28_local_adapter     本地按键 → 演奏事件
        │           │   ├── u_score: score_subsystem               乐谱与教学
        │           │   │   ├── field: s11_field_test_source       赛题测试源（1~64 路）
        │           │   │   ├── transport: score_spi_transport     曲谱页 SPI 接收
        │           │   │   ├── parser: r28_borrowed_score_parser  曲谱页校验与解析
        │           │   │   ├── records: score_record_fifo         曲谱记录缓冲
        │           │   │   ├── player: score_sequencer            按音乐时间发出事件
        │           │   │   ├── guide: r28_serial_guide            教学模式：音 → 灯珠颜色
        │           │   │   └── leds: r28_palette_serializer       WS2812 时序输出
        │           │   ├── event_pool: r28_event_pool             多来源事件仲裁与排队
        │           │   │   └── choice: performance_event_arbiter
        │           │   ├── engine: r28_instrument_engine          64 路合成引擎
        │           │   │   └── core: r28_control_audio_probe
        │           │   │       ├── controller: r28_serial_control     声部分配与抢占
        │           │   │       └── audio: r28_frame_audio             每帧逐声部计算
        │           │   │           ├── frontend: r28_shared_envelope_glide   包络、滑音
        │           │   │           │   ├── adsr: voice_release_adsr_step     ADSR（可调释音）
        │           │   │           │   ├── drum_envelope: voice_drum_envelope_step   鼓组包络
        │           │   │           │   ├── glide: glide_pitch_prepare
        │           │   │           │   └── advance: r28_glide_pipeline
        │           │   │           ├── timbre_prepare: r28_shared_timbre_lfo     5 Hz 颤音 LFO
        │           │   │           ├── pitch_prepare: osc_ii4_pitch_prepare      相位步进、高音 FM 递减
        │           │   │           ├── backend: osc_ii4_backend                  6 种音色波形运算
        │           │   │           ├── stereo: osc_stereo_sum                    声像与立体声累加
        │           │   │           └── monitor: osc48_voice_metrics              发声路数统计
        │           │   ├── u_effects: fx128_multirate             效果器：干声 128k，湿声 48k
        │           │   │   ├── converter: fx128_downsample
        │           │   │   └── engine: r46_serial_effects         回声、合唱、混响
        │           │   └── u_output: digital_audio_output_master  主混音与 DAC 输出
        │           │       ├── u_input: pcm_stream_input          手机伴奏 PCM 缓冲
        │           │       ├── u_gain: master_gain_config         主音量
        │           │       ├── u_master: stereo_master_mixer      本地 + 伴奏混音
        │           │       ├── u_pcm: master_pcm_stream           最终 16 位 PCM 转换
        │           │       └── u_pt8211: pt8211_audio_out
        │           │           └── u_serializer: pt8211_serializer   PT8211 日本格式（LSBJ）串行输出
        │           └── display: visual_display    HDMI 800×600 可视化（只读 DAC 样本）
        │               ├── observer: visual_dac_observer
        │               ├── timing: video_timing_800x600
        │               ├── snapshots: visual_snapshot_engine
        │               │   ├── fft: visual_fft4096             4096 点 FFT
        │               │   ├── bars: visual_spectrum_bars      频谱柱
        │               │   └── wave_ram / xy_ram / spectrum_ram: visual_plot_memory
        │               ├── renderer: visual_pixel_renderer     波形、李萨如、频谱、文字
        │               └── tx: video_dvi_tx                    TMDS 编码 + OSER10 串化
        ├── recorder: r18_recording_subsystem      录音（只读 DAC 样本与演奏事件）
        │   ├── downsample: rec48_downsample       128k → 48k FIR
        │   ├── u_pcm: s11_pcm_recorder            3072 对样本环形缓冲
        │   ├── u_exec: r28_execution_observer     演奏事件 → EVR 单元
        │   └── u_events: s11_event_recorder       EVR 事件缓冲
        └── configs: r18_config_observer           录音期间的参数变化日志
```

`r54_full_equal`（`common/`）是多处复用的宽位比较器，未在树中逐一列出。

### 目录与文件

- `top/`：顶层与逐层包装。`instrument_board_stage11_rev7.v`、`instrument_io_stage11.v`、`instrument_core_stage7.v`～`instrument_core_stage11.v`、`system_pll_30m.v`
- `input/`：压力采集与旋钮按键。`pressure_input_top.v`、`mcp3008_spi.v`、`pressure_scanner.v`、`ec11_encoder.v`、`button_debounce_onepulse.v`、`release_parameter_control.v`
- `event/`：演奏事件的产生与仲裁。`local_performance_control.v`、`r28_local_adapter.v`、`r28_event_pool.v`、`performance_event_arbiter.v`
- `synth/`：64 路合成引擎。`r28_instrument_engine.v`、`r28_control_audio_probe.v`、`r28_serial_control.v`、`r28_frame_audio.v`、`r28_shared_envelope_glide.v`、`r28_glide_pipeline.v`、`r28_shared_timbre_lfo.v`、`osc_ii4_pitch_prepare.v`、`osc_ii4_backend.v`、`osc_stereo_sum.v`、`osc48_voice_metrics.v`、`voice_adsr_step.v`、`glide_pitch_prepare.v`、`sine_rom.v`
- `effects/`：效果器。`fx128_multirate.v`、`r46_serial_effects.v`、`fx_history18.v`、`fx_config_frame.v`、`fx_frame_control.v`
- `audio_out/`：主混音与 PT8211 输出。`digital_audio_output_master.v`、`pcm_stream_input.v`、`pcm_pair_fifo.v`、`master_gain_config.v`、`stereo_master_mixer.v`、`master_pcm_stream.v`、`pt8211_audio_out.v`、`pt8211_serializer.v`
- `video/`：HDMI 可视化。`visual_*.v`、`video_*.v`、ROM 初始化 `r30_cosine_init.vh`、`r30_text_init.vh` 与 `visual_*.mem`
- `score/`：乐谱、教学灯珠、赛题测试源。`score_subsystem.v`、`score_spi_transport.v`、`r28_borrowed_score_parser.v`、`score_record_fifo.v`、`score_sequencer.v`、`r28_serial_guide.v`、`s11_field_test_source.v`
- `record/`：录音。`r18_recording_subsystem.v`、`r18_cell_prefetch_control.v`、`rec48_downsample.v`（系数 `rec48_ram.mem`）、`s11_pcm_recorder.v`、`s11_event_recorder.v`、`r28_execution_observer.v`、`r18_config_observer.v`
- `mcu_link/`：与 BL616 的 SPI 通信。`s10_pcm_transport.v`、`s11_spi_response.v`、`r22_control_link.v`、`s9_session_control.v`、`r22_event_endpoint.v`、`r22_config_bridge.v`、`s9_keymap_config.v`、`s9_constants.vh`
- `common/`：通用小模块。`r54_full_equal.v`

### 名称说明

- `instrument_core_stage7`～`stage11`：开发时每个阶段在外面包一层新功能，层号即阶段号。第 7 层是完整音频通路，第 8 层加 HDMI，第 9 层加手机控制，第 10 层加手机音频与应答，第 11 层加录音。
- `r18_`、`r22_`、`r28_` 等前缀是该模块定型时的开发轮次编号；`s9_`、`s10_`、`s11_` 是 BL616 通信协议的阶段号；`osc_ii4_` 表示每 4 个时钟发起一个声部的运算后端。前缀只是历史编号，不表示层次。

### BL616
需要 Bouffalo SDK（环境变量 `BL_SDK_BASE`）与 RISC-V 工具链。`firmware/bl616/project/CMakeLists.txt` 通过 `../src` 引用源码。
应用镜像写入 Flash 偏移 `0x40000`；不要改写 bootloader 与 eFuse。

### iOS / iPadOS
推送 `app/ios/` 的改动后，GitHub Actions（`macos-26`，Xcode 26）自动编译未签名 IPA，并生成 iPhone 与 11 寸 iPad 截图；在 Actions 运行详情页底部的 Artifacts 下载，签名后安装。最低系统 iOS 15，iOS 26 上启用液态玻璃效果。

### 安卓
在 `app/android/` 下执行 `gradlew assembleDebug`（JDK 17、compileSdk 37）。最低系统 Android 8.0。

## 文档
- `docs/app_reserved_notices.md`：App 已预留、等待板端实现的通知（教学提示、实体琴键状态、板上参数同步）。
