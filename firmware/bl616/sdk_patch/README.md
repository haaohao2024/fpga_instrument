# Bouffalo SDK 补丁

固件基于 Bouffalo SDK 2.3.35（GitHub 提交 `63784aa0d14a4d67b081f91a4fa7ed18331c7470`）。下列 SDK 文件需要修改，
修改后的完整文件放在本目录，由 `../project/CMakeLists.txt` 在编译时替换 SDK 中的同名文件，**无需改动已安装的 SDK**。

| 本目录文件 | 对应 SDK 文件 | 修改内容 |
|---|---|---|
| `blestack/src/include/bluetooth/s10_host_observer.h` | （新增） | 蓝牙伴奏用的 L2CAP 观察回调声明（弱符号） |
| `blestack/src/host/l2cap.c` | `components/wireless/bluetooth/blestack/src/host/l2cap.c` | 在通道断开、BR/EDR 发送处调用观察回调 |
| `blestack/src/host/l2cap_br.c` | `components/wireless/bluetooth/blestack/src/host/l2cap_br.c` | 在通道连接、接收处调用观察回调 |
| `blestack/src/sbc/dec/decoder-private.c` | `components/wireless/bluetooth/blestack/src/sbc/dec/decoder-private.c` | SBC 比例因子按 4 位逐个读取，修正解码错误 |

观察回调只在定义 `S10_PROFILE_HOST_OBSERVER` 时编译进来（`CMakeLists.txt` 已定义），用于 `../src/s10_profile.c` 跟踪 A2DP 媒体链路。

`diff/` 下是相对官方原文件的差异，便于审阅。这些文件沿用 SDK 原有许可（Apache-2.0，见 `LICENSE.Apache-2.0.txt`），文件头的版权声明保持不变。
