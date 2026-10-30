"""Draw Palaver's icons into palaver/assets/ (run: make icons).

The "Tonspur" mark: three speakers' lanes as pills, as the Meetings window
draws them. The app icon is the coloured mark on violet in macOS's icon
grid (a 824 px rounded square on a 1024 px canvas, with its shadow); the
menu bar icon is a black template image macOS tints itself. Needs Pillow.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ASSETS = Path(__file__).resolve().parent.parent / "palaver" / "assets"

VIOLET = "#5b3df5"
# On a 100 × 100 square: x, y, width, colour; every pill is 12 high.
PILLS = [(16, 24, 34, "#ffffff"), (70, 24, 14, "#ffffff"), (34, 44, 34, "#ff7a5c"),
         (16, 64, 14, "#3fd49a"), (50, 64, 34, "#3fd49a")]
# The menu bar's own drawing on an 18 × 18 grid, wider for its small size: x, y, width; 3 high.
GLYPH = [(1, 2.5, 7), (10.5, 2.5, 6.5), (4.5, 7.5, 9), (1, 12.5, 4), (7.5, 12.5, 9.5)]

SUPERSAMPLE = 4


def app_icon(size: int = 1024) -> Image.Image:
    big = size * SUPERSAMPLE
    unit = big / 1024
    body, left = 824 * unit, 100 * unit
    image = Image.new("RGBA", (big, big), (0, 0, 0, 0))

    shadow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (left, left + 12 * unit, left + body, left + body + 12 * unit), radius=185 * unit, fill=(20, 18, 58, 80))
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14 * unit)))

    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((left, left, left + body, left + body), radius=185 * unit, fill=VIOLET)
    scale = body / 100
    for x, y, width, colour in PILLS:
        box = (left + x * scale, left + y * scale, left + (x + width) * scale, left + (y + 12) * scale)
        draw.rounded_rectangle(box, radius=6 * scale, fill=colour)
    return image.resize((size, size), Image.LANCZOS)


def menubar_icon(points: int = 20, scale: int = 2) -> Image.Image:
    """Black on transparent, ``points`` square at ``scale``×; the glyph's
    18-point grid sits in the middle."""
    size = points * scale
    big = size * SUPERSAMPLE * 2
    unit = big / points
    pad = (points - 18) / 2
    image = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    for x, y, width in GLYPH:
        box = ((pad + x) * unit, (pad + y) * unit, (pad + x + width) * unit, (pad + y + 3) * unit)
        draw.rounded_rectangle(box, radius=1.5 * unit, fill=(0, 0, 0, 255))
    return image.resize((size, size), Image.LANCZOS)


def write_icns(master: Image.Image, path: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "Palaver.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
                master.resize((points * scale,) * 2, Image.LANCZOS).save(iconset / name)
        subprocess.run(["iconutil", "-c", "icns", "-o", str(path), str(iconset)], check=True)


def main() -> int:
    if not shutil.which("iconutil"):
        print("iconutil (macOS) is needed for the .icns", file=sys.stderr)
        return 1
    ASSETS.mkdir(exist_ok=True)
    master = app_icon()
    master.save(ASSETS / "icon.png")
    write_icns(master, ASSETS / "Palaver.icns")
    menubar_icon().save(ASSETS / "menubar.png")
    for name in ("icon.png", "Palaver.icns", "menubar.png"):
        print(ASSETS / name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
