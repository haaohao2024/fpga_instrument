"""Regenerate every App icon from the artwork in this folder.

The App 2.0 icon is the user-supplied artwork (`app_icon_source.png`): a chip
badge with piano keys and a rising amber waveform on dark navy. It is a raster
image, so this script derives every size instead of drawing vector paths.

Inputs
    app_icon_source.png    original artwork (1254x1254, opaque RGB)

Outputs
    app_icon_1024.png      normalised 1024x1024 master (also used by iOS)
    ../ios/InstrumentIOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
    ../android/app/src/main/res/mipmap-*/ic_launcher.png            legacy
    ../android/app/src/main/res/mipmap-*/ic_launcher_round.png      legacy round
    ../android/app/src/main/res/mipmap-*/ic_launcher_foreground.png adaptive

The adaptive foreground fills the whole 108dp canvas: the artwork is already
centred with the chip inside the central ~66dp, which is the safe zone of the
adaptive-icon mask, so no extra padding is needed.

Usage
    python make_icons.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
APP = HERE.parent
SOURCE = HERE / "app_icon_source.png"
MASTER = HERE / "app_icon_1024.png"
IOS_SET = APP / "ios" / "InstrumentIOS" / "Assets.xcassets" / "AppIcon.appiconset"
ANDROID_RES = APP / "android" / "app" / "src" / "main" / "res"

# Adaptive icons: 108dp canvas, one file per density bucket.
ADAPTIVE_DP = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
# Legacy launcher icons, still used where an adaptive icon cannot be resolved.
LEGACY_DP = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def _save(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, "PNG", optimize=True)
    print(f"{path.relative_to(APP)}  {image.size[0]}x{image.size[1]}")


def _round_icon(square: Image.Image) -> Image.Image:
    """Circle-cropped copy with a transparent margin, for android:roundIcon."""
    size = square.size[0]
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
    rounded = square.convert("RGBA")
    rounded.putalpha(mask.resize((size, size), Image.LANCZOS))
    return rounded


def main() -> None:
    # iOS icons must be opaque; the artwork has no alpha channel to begin with.
    master = Image.open(SOURCE).convert("RGB").resize((1024, 1024), Image.LANCZOS)
    _save(master, MASTER)
    _save(master, IOS_SET / "AppIcon-1024.png")

    for bucket, size in LEGACY_DP.items():
        square = master.resize((size, size), Image.LANCZOS)
        _save(square, ANDROID_RES / f"mipmap-{bucket}" / "ic_launcher.png")
        _save(_round_icon(square), ANDROID_RES / f"mipmap-{bucket}" / "ic_launcher_round.png")

    for bucket, size in ADAPTIVE_DP.items():
        _save(master.resize((size, size), Image.LANCZOS),
              ANDROID_RES / f"mipmap-{bucket}" / "ic_launcher_foreground.png")


if __name__ == "__main__":
    main()
