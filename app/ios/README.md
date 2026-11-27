# iOS / iPadOS App

原生 SwiftUI + CoreBluetooth，版本 2.0（build 89），最低 iOS 15，iOS 26 上启用液态玻璃效果。所有音频由 FPGA 合成，App 只发送演奏事件与控制命令。

## 构建与安装

需要 macOS 与 Xcode 26（代码用到 iOS 26 SDK 的液态玻璃接口）。

- **本地编译**：用 Xcode 打开 `InstrumentIOS.xcodeproj`，scheme 选 `InstrumentIOS`，在 Signing & Capabilities 中选自己的开发团队，运行到真机或模拟器。命令行方式见仓库根目录 README 的“iOS / iPadOS”一节。
- **云端编译**：仓库推送到 GitHub 后，`app/ios/` 的改动会触发 `.github/workflows/ios.yml`：先执行 `swift test --package-path InstrumentCore`，再构建 arm64 真机 App，输出未签名的 `FPGA-Instrument-iOS-unsigned.ipa`、编译日志和 iPhone / 11 寸 iPad 模拟器截图（iOS 26），在 Actions 运行详情页底部的 Artifacts 下载。工作流不需要 Apple ID、证书或仓库密钥。

未签名 IPA 不能直接安装，可用 Windows 上的 Sideloadly 等工具在本机签名安装，Apple 账户只在本机输入。首次安装按提示信任开发者；iOS 16 及以上还需按提示开启“开发者模式”。免费账户签名需定期续签，参考 [Sideloadly 官方说明](https://sideloadly.io/faq.html)。

## 功能

- 加密 BLE 扫描、连接、状态订阅、会话校验、自动保活与诊断导出。
- 16 键多指和弦、八度与力度控制；全 64 位音符身份；离开演奏页松键。
- 六种音色、松手衰减、颤音、合成/外部伴奏音量与效果预设。
- 实体 8 键音高映射；SD 曲谱播放/暂停/继续/停止，教学模式；上传 `SCORE.EVT` 曲谱到乐器。
- Live Looping 四层叠录、撤销、停止、恢复、清空。
- 规则智能合奏设置、启停及来自 FPGA 的实际声部计数。
- SD 声音/事件录音、状态查询、逐块下载与整文件 CRC 校验后分享；事件录音可转换为曲谱。
- 赛题测试模式：多路不同频率的持续发声测试，48 / 64 路使用 FPGA 原生测试源，30 秒自动结束。
- 手机音乐伴奏：手机经蓝牙音频（A2DP）连接 `BTBLE-DEV` 播放音乐，App 中调节外部伴奏音量。

需要配套本仓库的 FPGA 比特流与 BL616 固件。App 只在前台运行，进入后台会主动断开，设备会清理手机按住的音。实体琴键不依赖手机。循环、曲谱、合奏与录音之间有固件规定的互斥，以设备执行反馈为准。

## 协议与验证

`InstrumentCore` 为可独立测试的 Swift 包（协议层）。`Tests/InstrumentCoreTests/Fixtures` 与安卓工程 `app/android/app/src/test/resources` 中的文件相同，含 21 个字节黄金向量和 1062 个语义边界向量。其他测试覆盖 CRC、分包、重复/缺包/超时、Loop/合奏通知、旧会话隔离、配置屏障、执行反馈、持音身份与录音下载。`StageLogic` 是演奏台界面用到的采样率测量逻辑，App 直接编译同一源文件，可用 `swift test --package-path StageLogic` 单独测试。

GATT 写入确认只代表传输完成；界面的成功反馈来自设备 STATUS 执行阶段。消息按实际 `maximumWriteValueLength`（不超过 244 字节）分包，同时最多一个 ATT 操作在途。
