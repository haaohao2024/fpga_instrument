# FPGA 电子乐器

基于 Gowin GW5AT-60 FPGA 的 48 路独立振荡器电子乐器：128 kHz 音频输出、效果器、SD 卡录音、乐谱与教学、循环叠录、自动伴奏、蓝牙伴奏，配套 BL616 主控固件与 iOS / iPadOS / 安卓 App。

## 目录结构

```
.
├── fpga/                     FPGA 工程（Gowin）
│   ├── formal_one.gprj       工程文件，用 Gowin IDE 直接打开
│   ├── impl/                 综合/布局布线设置（formal_one_process_config.json）
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
├── legacy/                   历史版本源码，仅供对照，不参与当前构建
└── .github/workflows/        iOS 云端编译（GitHub Actions）
```

## 当前版本

| 部分 | 版本 | 说明 |
|---|---|---|
| FPGA | r3f，比特流 SHA256 `0754b973…` | 效果器加强一 + 48 路赛题测试 + HDMI 标注按 128 kHz 修正；setup/hold 违例 0，最差 setup +0.032 ns；已写入板上 Flash |
| BL616 | 镜像 SHA256 `e84ba20f…` | 蓝牙伴奏修复、手机音量键（AVRCP 绝对音量）、48 路测试放行；SD 卡读卡等待空闲并重试、单次出错不再锁死（修复普通录音偶发错误码 -12）；已上板，连续 8 段录音全部保存成功 |
| App | 2.0 演奏台 | 横屏电子琴面板 + 可滑动钢琴键盘；iOS 26 液态玻璃 |

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
