# App 图标源文件（App 2.0）

本目录是 iOS 和安卓图标的唯一来源。图标使用用户提供的图片：深蓝色底上是一块
芯片轮廓，内部为黑白琴键，另有一条蓝到琥珀色的波形线。没有文字、没有商标。

| 文件 | 说明 |
| --- | --- |
| `app_icon_source.png` | 用户提供的原图（1254×1254，不透明 RGB）。**只作存档，不要直接改。** |
| `app_icon_1024.png` | 归一化后的 1024×1024 主图，iOS 和安卓所有尺寸都由它生成。 |
| `app_icon.svg` | 1024×1024 画布，引用主图，便于以后换成真正的矢量重绘。 |
| `make_icons.py` | 重新生成本目录和两个平台的全部图标文件。 |

## 生成

```bash
python make_icons.py
```

需要 Pillow 和 numpy。脚本会写回：

- `../ios/InstrumentIOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
  （Xcode 14 起的单尺寸 App Icon，`Contents.json` 里是 `universal` + `ios` + `1024x1024`）
- `../android/app/src/main/res/mipmap-<密度>/ic_launcher.png`、`ic_launcher_round.png`
  （mdpi 48 / hdpi 72 / xhdpi 96 / xxhdpi 144 / xxxhdpi 192）
- `../android/app/src/main/res/mipmap-<密度>/ic_launcher_foreground.png`
  （自适应图标前景，108dp：108 / 162 / 216 / 324 / 432）

## 约定

- iOS 图标必须**不透明**，不能带 alpha 通道；原图是 RGB，脚本不做透明处理。
- 安卓 minSdk 是 26，只用自适应图标：`mipmap-anydpi-v26/ic_launcher.xml` 引用
  `@color/ic_launcher_background`（`#000C2C`，与原图边缘同色）和前景位图。
- 原图里的芯片连同引脚约占画面 66%，引脚正好顶到自适应图标 72dp 安全区边缘，
  圆形遮罩会切掉上下引脚。所以脚本把前景按画布的 86% 绘制、居中，并把外圈 6%
  羽化到背景色，引脚就完整落在遮罩内，接缝也看不出来。
- 改图时请同时更新 `res/values/ic_launcher_background.xml` 里的取色，保持边缘无缝。
