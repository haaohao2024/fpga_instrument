# FPGA 电子乐器

基于 Gowin GW5AT-60 FPGA 的 64 路独立振荡器电子乐器：128 kHz 音频输出、效果器、SD 卡录音、乐谱与教学、循环叠录、自动伴奏、蓝牙伴奏，配套 BL616 主控固件与 iOS / iPadOS / 安卓 App。

## 目录结构

```
.
├── fpga/                     FPGA 工程（Gowin）
│   ├── formal_one.gprj       工程文件，用 Gowin IDE 直接打开
│   ├── impl/                 综合/布局布线设置（formal_one_process_config.json）；构建后生成 gwsynthesis/、pnr/
│   ├── src/                  RTL（.v/.vh）与 ROM 初始化数据（.mem）
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

- **FPGA**：64 路合成引擎，128 kHz 输出；比特流 `fpga/impl/pnr/formal_one.bin` SHA256 `210f7d2c…`，2026-11-01 写入板上 Flash。
  资源：逻辑 41788/59904（70%）、寄存器 26393/60780（44%）、BSRAM 108/118（92%）、DSP 33.5/118（29%）。
  时序：system_clk 约束 40 MHz，Fmax 45.73 MHz；全部时钟 setup/hold 违例 0。
- **BL616**：64 路赛题测试放行；镜像 SHA256 `c20add42…`，2026-10-31 写入 Flash 偏移 0x40000。
- **App**：2.0 演奏台（安卓 versionName `2.0-stage`）；横屏电子琴面板 + 可滑动钢琴键盘，iOS 26 液态玻璃。

## 构建

### FPGA
用 Gowin IDE（V1.9.12.04）打开 `fpga/formal_one.gprj`，顶层模块 `instrument_board_stage11_rev7`，布局选项 3、布线选项 2。
RTL 中的 ROM 文件以 `src/xxx.mem` 相对工程目录引用，请保持 `fpga/` 内的相对位置不变。

### BL616
需要 Bouffalo SDK（环境变量 `BL_SDK_BASE`）与 RISC-V 工具链。`firmware/bl616/project/CMakeLists.txt` 通过 `../src` 引用源码。
应用镜像写入 Flash 偏移 `0x40000`；不要改写 bootloader 与 eFuse。

### iOS / iPadOS
推送 `app/ios/` 的改动后，GitHub Actions（`macos-26`，Xcode 26）自动编译未签名 IPA，并生成 iPhone 与 11 寸 iPad 截图；在 Actions 运行详情页底部的 Artifacts 下载，签名后安装。最低系统 iOS 15，iOS 26 上启用液态玻璃效果。

### 安卓
在 `app/android/` 下执行 `gradlew assembleDebug`（JDK 17、compileSdk 37）。最低系统 Android 8.0。

## 文档
- `docs/app_reserved_notices.md`：App 已预留、等待板端实现的通知（教学提示、实体琴键状态、板上参数同步）。
