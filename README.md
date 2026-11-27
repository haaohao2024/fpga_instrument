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

- **FPGA**：64 路合成引擎，128 kHz 输出；比特流 `fpga/impl/pnr/formal_one.bin` SHA256 `94ce681a…`（2026-11-24 模块改名后由本目录源码重新构建，与 11-02 写入板上的版本逐字节相同；`pnr/` 不纳入 git，需本地构建）。
  已写入板上 Flash，并完成上板录音延迟实测（发布到出声平均 0.687 ms）。
  资源：逻辑 41785/59904（70%）、寄存器 26393/60780（44%）、BSRAM 108/118（92%）、DSP 33.5/118（29%）。
  时序：system_clk 约束 40 MHz，Fmax 43.40 MHz；全部时钟 setup/hold 违例 0。
- **BL616**：64 路赛题测试放行；镜像 SHA256 `c20add42…`，2026-10-31 写入 Flash 偏移 0x40000。
- **App**：2.0 演奏台（安卓 versionName `2.0-stage`）；横屏电子琴面板 + 可滑动钢琴键盘，iOS 26 液态玻璃。

## 构建

### FPGA
用 Gowin IDE（V1.9.12.04）打开 `fpga/formal_one.gprj`，顶层模块 `instrument_top`，布局选项 3、布线选项 2，Verilog 标准 SystemVerilog-2017。
RTL 中的 ROM 文件以 `src/<子目录>/xxx.mem` 相对 `fpga/` 引用，请保持 `fpga/` 内的相对位置不变。
`.vh` 头文件与引用它的 `.v` 放在同一目录，综合器按引用文件所在目录查找，无需设置 Include Path；`.mem` 路径相对于 `fpga/` 工程目录。工程可整体复制到任意位置直接打开构建。

### BL616
环境（与当前镜像所用版本相同）：
- Bouffalo SDK 2.3.35（官方原版，对应 GitHub 提交 `63784aa0`，无需任何修改），环境变量 `BL_SDK_BASE` 指向 SDK 根目录；
- 玄铁 Xuantie-900 RISC-V 工具链 V2.6.1（`riscv64-unknown-elf-gcc` 10.2.0）；
- SDK 自带的 `tools/cmake`、`tools/make/mingw32-make.exe` 与 Kconfig 脚本，另需 Python 3。

固件需要的 4 处 SDK 修改（蓝牙伴奏的 L2CAP 观察回调、SBC 解码修正）已放在 `firmware/bl616/sdk_patch/`，编译时由 `CMakeLists.txt` 自动替换 SDK 中的同名文件，说明见该目录下的 README。

在 `firmware/bl616/project` 目录下执行（Windows；`%SDK%` 为 SDK 根目录，`%TC%` 为工具链的 `bin` 目录，`%P%` 为本目录的绝对路径）：

1. 由 `defconfig` 生成配置（先建好输出目录 `mkdir build\generated`）：
   ```
   python %SDK%/tools/kconfig/config_seed.py --defconfig defconfig --kconfig %SDK%/Kconfig --def-out build/generated/autoconfig.def --cmake-out build/generated/autoconfig.cmake --header-out build/generated/autoconfig.h --make-out build/generated/autoconfig.mk
   ```
2. CMake 配置：
   ```
   %SDK%/tools/cmake/bin/cmake -S . -B build -G "MinGW Makefiles" -DBUILD_DIR=build -DSDK_DEMO_PATH=%P% -DCMAKE_MAKE_PROGRAM=%SDK%/tools/make/mingw32-make.exe -DCMAKE_C_COMPILER_FORCED=TRUE -DCMAKE_CXX_COMPILER_FORCED=TRUE -DCROSS_COMPILE=%TC%/riscv64-unknown-elf-
   ```
3. 编译并导出原始镜像：
   ```
   %SDK%/tools/cmake/bin/cmake --build build --target instrument_neo_r59_bl616.elf --parallel 8
   %TC%/riscv64-unknown-elf-objcopy -O binary build/build_out/instrument_neo_r59_bl616.elf build/build_out/instrument_neo_r59_bl616.bin
   ```
4. 后处理生成可烧录镜像（工具会就地改写 `--imgfile` 指定的文件，原始 `.bin` 不能直接烧录）：
   ```
   %SDK%/tools/bflb_tools/bflb_fw_post_proc/bflb_fw_post_proc.exe --chipname=bl616 --imgfile=build/build_out/instrument_neo_r59_bl616.bin --dtsfile=%SDK%/bsp/board/bl616dk/config/bl_factory_params_IoTKitA_auto.dts
   ```
5. 烧录：板子进入下载模式（保持供电，SW6 拨到 OFF、SW5 拨到 ON；按住 UPDATE 再把 SW6 拨到 ON，1～2 秒后松开），用 Bouffalo 烧录工具（如 Flash Cube）把第 4 步得到的 `.bin` 写到 Flash 偏移 `0x40000`。只写应用区，不要改写 bootloader 与 eFuse。烧录后 SW6 拨到 OFF、SW5 拨到 OFF，再把 SW6 拨到 ON，正常启动。

镜像中嵌入了编译时间，每次编译得到的文件 SHA256 都不同，属正常现象。

### iOS / iPadOS
需要 macOS 与 Xcode 26（代码用到 iOS 26 SDK 的液态玻璃接口，旧版 Xcode 无法编译）。最低系统 iOS 15，iOS 26 上启用液态玻璃效果。

本地编译：用 Xcode 打开 `app/ios/InstrumentIOS.xcodeproj`，选择 scheme `InstrumentIOS`，在 Signing & Capabilities 中选自己的开发团队后运行到真机或模拟器。也可在 `app/ios/` 下用命令行：
```
swift test --package-path InstrumentCore
xcodebuild -project InstrumentIOS.xcodeproj -scheme InstrumentIOS -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```
第一条运行协议层测试；第二条生成未签名的 `build/Build/Products/Release-iphoneos/InstrumentIOS.app`，把它放进 `Payload/` 目录压缩为 `.ipa` 后，可用签名工具（如 Sideloadly）安装。

云端编译：仓库推送到 GitHub 后，`app/ios/` 的改动会触发 `.github/workflows/ios.yml`（`macos-26` 运行器），执行上述测试与编译，输出未签名 IPA 与 iPhone、11 寸 iPad 截图，在 Actions 运行详情页底部的 Artifacts 下载。

### 安卓
在 `app/android/` 下执行 `gradlew assembleDebug`，单元测试为 `gradlew testDebugUnitTest`（JDK 17、compileSdk 37、Android SDK Build-Tools 36.0.0，首次编译需联网下载 Gradle 与依赖，下载的依赖按 `gradle/verification-metadata.xml` 校验；Android SDK 位置写在 `local.properties` 的 `sdk.dir`，或设置环境变量 `ANDROID_HOME`）。构建输出默认在工程内的 `build/` 目录，可用 `-PinstrumentBuildRoot=<目录>` 改到源码目录以外。最低系统 Android 8.0。

## FPGA 模块结构

顶层模块：`instrument_top`（`fpga/src/top/instrument_top.v`）。
一个文件放一个主模块，文件名与模块名相同；少数文件附带只供本文件使用的小模块（如 `voice_adsr_step.v` 中的两种包络步进、`visual_spectrum_bars.v` 中的电平编码/解码）。

### 实例层次（实例名: 模块名）

```
instrument_top                                              板级顶层：引脚、复位、八度按键
├── system_pll: system_pll                                  系统 PLL：40 MHz 系统时钟、80 MHz 通信时钟
├── u_octave_up / u_octave_down: button_debounce_onepulse   E1/E2 按压去抖
└── u_instrument: instrument_io                             板级输入与核心的连接
    ├── u_adc: pressure_input                               8 路压力采集
    │   ├── u_spi: mcp3008_spi                              MCP3008 SPI 读数
    │   └── u_scanner: pressure_scanner                     CH0~CH7 轮询，整帧发布
    ├── u_ec11 / u_glide_ec11: ec11_encoder                 E1 颤音深度、E2 释音时长
    ├── u_release_parameter: release_parameter_control      释音档位 0~7
    ├── video_pll: video_pll_800x600                        视频 PLL：40 MHz 像素、200 MHz 串行
    └── u_core: instrument_core                             核心最外层：在下层基础上加入录音
        ├── base: core_mcu_media                            加入 BL616 手机音频（伴奏 PCM）与录音应答 SPI
        │   ├── transport: mcu_pcm_transport                手机音频（伴奏）SPI 接收
        │   │   └── response_encoder: mcu_spi_response      录音数据应答编码
        │   └── base: core_mcu_control                      加入 BL616 控制链路：手机演奏事件与参数
        │       ├── control: mcu_control_link               BL616 控制命令 SPI 链路
        │       │   └── session: mcu_session_control        手机会话与租约
        │       ├── events: mcu_event_endpoint              手机演奏事件入口
        │       ├── parameters: mcu_config_bridge           手机参数（音色/效果/音量/键位）下发
        │       │   └── u_map: keymap_config                键位映射
        │       └── core: core_audio_video                  音频通路 + HDMI 可视化
        │           ├── u_audio: core_audio                 完整音频通路：输入 → 事件 → 合成 → 效果 → DAC
        │           │   ├── u_control: local_performance_control  压力/旋钮 → 演奏控制
        │           │   ├── u_event_adapter: local_event_adapter  本地按键 → 演奏事件
        │           │   ├── u_score: score_subsystem        乐谱与教学
        │           │   │   ├── field: field_test_source    赛题测试源（1~64 路）
        │           │   │   ├── transport: score_spi_transport  曲谱页 SPI 接收
        │           │   │   ├── parser: score_page_parser   曲谱页校验与解析
        │           │   │   ├── records: score_record_fifo  曲谱记录缓冲
        │           │   │   ├── player: score_sequencer     按音乐时间发出事件
        │           │   │   ├── guide: score_led_guide      教学模式：音 → 灯珠颜色
        │           │   │   └── leds: ws2812_serializer     WS2812 时序输出
        │           │   ├── event_pool: event_pool          多来源事件仲裁与排队
        │           │   │   └── choice: performance_event_arbiter
        │           │   ├── engine: synth_engine            64 路合成引擎
        │           │   │   └── core: synth_engine_core     声部控制器与逐声部运算的组合
        │           │   │       ├── controller: voice_allocator  声部分配与抢占
        │           │   │       └── audio: voice_frame_audio  每帧逐声部计算
        │           │   │           ├── frontend: envelope_glide_frontend  包络、滑音
        │           │   │           │   ├── adsr: voice_release_adsr_step  ADSR（可调释音）
        │           │   │           │   ├── drum_envelope: voice_drum_envelope_step  鼓组包络
        │           │   │           │   ├── glide: glide_pitch_prepare
        │           │   │           │   └── advance: glide_pipeline
        │           │   │           ├── timbre_prepare: timbre_lfo  5 Hz 颤音 LFO
        │           │   │           ├── pitch_prepare: osc_pitch_prepare  相位步进、高音 FM 递减
        │           │   │           ├── backend: osc_backend  6 种音色波形运算
        │           │   │           ├── stereo: osc_stereo_sum  声像与立体声累加
        │           │   │           └── monitor: voice_metrics  发声路数统计
        │           │   ├── u_effects: fx_multirate         效果器：干声 128k，湿声 48k
        │           │   │   ├── converter: fx_downsample
        │           │   │   └── engine: fx_engine           回声、合唱、混响
        │           │   └── u_output: digital_audio_output_master  主混音与 DAC 输出
        │           │       ├── u_input: pcm_stream_input   手机伴奏 PCM 缓冲
        │           │       ├── u_gain: master_gain_config  主音量
        │           │       ├── u_master: stereo_master_mixer  本地 + 伴奏混音
        │           │       ├── u_pcm: master_pcm_stream    最终 16 位 PCM 转换
        │           │       └── u_pt8211: pt8211_audio_out
        │           │           └── u_serializer: pt8211_serializer  PT8211 日本格式（LSBJ）串行输出
        │           └── display: visual_display             HDMI 800×600 可视化（只读 DAC 样本）
        │               ├── observer: visual_dac_observer
        │               ├── timing: video_timing_800x600
        │               ├── snapshots: visual_snapshot_engine
        │               │   ├── fft: visual_fft4096         4096 点 FFT
        │               │   ├── bars: visual_spectrum_bars  频谱柱
        │               │   └── wave_ram / xy_ram / spectrum_ram: visual_plot_memory
        │               ├── renderer: visual_pixel_renderer  波形、李萨如、频谱、文字
        │               └── tx: video_dvi_tx                TMDS 编码 + OSER10 串化
        ├── recorder: recording_subsystem                   录音（只读 DAC 样本与演奏事件）
        │   ├── downsample: rec_downsample                  128k → 48k FIR
        │   ├── u_pcm: rec_pcm_recorder                     3072 对样本环形缓冲
        │   ├── u_exec: rec_execution_observer              演奏事件 → EVR 单元
        │   └── u_events: rec_event_recorder                EVR 事件缓冲
        └── configs: rec_config_observer                    录音期间的参数变化日志
```

`common/` 下是多处复用的小模块，未在树中逐一列出：宽位比较器 `wide_equal`；18 位块 RAM 封装 `ram18_sdp` / `ram18_dp`（效果器延迟线与 FFT 使用）；SPI 时钟沿采样 `spi_edge_sampler`（曲谱与 BL616 的三条 SPI 链路共用）。

### 目录与文件

- `top/`：顶层与核心各层包装。`instrument_top.v`、`instrument_io.v`、`instrument_core.v`、`core_mcu_media.v`、`core_mcu_control.v`、`core_audio_video.v`、`core_audio.v`、`system_pll.v`
- `input/`：压力采集与旋钮按键。`pressure_input.v`、`mcp3008_spi.v`、`pressure_scanner.v`、`ec11_encoder.v`、`button_debounce_onepulse.v`、`release_parameter_control.v`
- `event/`：演奏事件的产生与仲裁。`local_performance_control.v`、`local_event_adapter.v`、`event_pool.v`、`performance_event_arbiter.v`
- `synth/`：64 路合成引擎。`synth_engine.v`、`synth_engine_core.v`、`voice_allocator.v`、`voice_frame_audio.v`、`envelope_glide_frontend.v`、`glide_pipeline.v`、`glide_pitch_prepare.v`、`voice_adsr_step.v`、`timbre_lfo.v`、`osc_pitch_prepare.v`、`osc_backend.v`、`osc_stereo_sum.v`、`voice_metrics.v`、`sine_rom.v`
- `effects/`：效果器。`fx_multirate.v`、`fx_engine.v`、`fx_history18.v`、`fx_config_frame.v`、`fx_frame_control.v`
- `audio_out/`：主混音与 PT8211 输出。`digital_audio_output_master.v`、`pcm_stream_input.v`、`pcm_pair_fifo.v`、`master_gain_config.v`、`stereo_master_mixer.v`、`master_pcm_stream.v`、`pt8211_audio_out.v`、`pt8211_serializer.v`
- `video/`：HDMI 可视化。`visual_*.v`、`video_*.v`、ROM 初始化 `visual_cosine_init.vh`、`visual_text_init.vh`（由 `fpga/tools/generate_rom_init.py` 生成）与 `visual_*.mem`
- `score/`：乐谱、教学灯珠、赛题测试源。`score_subsystem.v`、`score_spi_transport.v`、`score_page_parser.v`、`score_record_fifo.v`、`score_sequencer.v`、`score_led_guide.v`（含 `ws2812_serializer`）、`field_test_source.v`
- `record/`：录音。`recording_subsystem.v`、`rec_prefetch_control.v`、`rec_downsample.v`（系数 `rec_downsample_coeff.mem`）、`rec_pcm_recorder.v`、`rec_event_recorder.v`、`rec_execution_observer.v`、`rec_config_observer.v`
- `mcu_link/`：与 BL616 的 SPI 通信。`mcu_pcm_transport.v`、`mcu_spi_response.v`、`mcu_control_link.v`、`mcu_session_control.v`、`mcu_event_endpoint.v`、`mcu_config_bridge.v`、`keymap_config.v`、`mcu_protocol_constants.vh`
- `common/`：多处复用的小模块。`wide_equal.v`、`ram18_sdp.v`、`ram18_dp.v`、`spi_edge_sampler.v`

### 名称说明

- 核心分层：`core_audio` 是完整音频通路，外面依次包上 `core_audio_video`（HDMI）、`core_mcu_control`（手机控制）、`core_mcu_media`（手机音频与录音应答）、`instrument_core`（录音），每层只加一类功能。实例名（`u_core`、`base`、`core` 等）沿用原名，时序约束中的层次路径不变。
- 前缀：`mcu_` 为与 BL616 的通信，`rec_` 为录音，`fx_` 为效果器，`osc_` 为振荡器后端，`visual_` / `video_` 为 HDMI 可视化。
- `mcu_protocol_constants.vh` 中的宏仍以 `S9_` 开头，与固件 `firmware/bl616/src/s9_constants.h` 的命名保持一致。
- 2026-11 统一改过一次名。报告或旧文档中出现的旧模块名（如 `r28_serial_control`、`instrument_core_stage7`）与新名的对照见 `docs/rtl_rename_map.md`。

## 文档
- `docs/rtl_rename_map.md`：FPGA 模块与文件的新旧名称对照。
- `docs/app_reserved_notices.md`：App 已预留、等待板端实现的通知（教学提示、实体琴键状态、板上参数同步）。
