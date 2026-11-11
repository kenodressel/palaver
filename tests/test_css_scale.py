"""The window's stylesheet keeps to its scale (the comment at the top of
app.css): a size or a space off it is a design decision made by accident."""
from __future__ import annotations

import re
from pathlib import Path

CSS = (Path(__file__).resolve().parent.parent / "web" / "app.css").read_text()
TYPE = {8, 10, 11, 12, 13, 14, 15, 17, 20, 24, 64}  # 8, 10: the letters in small avatars; 64: the big number
SPACE = {0, 1, 1.5, 2, 4, 6, 8, 12, 16, 20, 24, 28, 32, 40, 48, 64, 80}


def _px(text: str) -> list[float]:
    return [float(n) for n in re.findall(r"(?<![\w.])-?(\d+(?:\.\d+)?)px", text)]


def test_font_sizes_are_on_the_type_scale():
    found = [*re.findall(r"font-size:\s*([\d.]+)px", CSS), *re.findall(r"font:\s*(?:\d{3}\s+)?([\d.]+)px", CSS)]
    off = sorted({float(n) for n in found} - TYPE)
    assert not off, f"font sizes off the scale: {off}"


def test_spacing_is_on_the_grid():
    values = re.findall(r"\b(?:padding|margin)(?:-[a-z-]+)?\s*:\s*([^;{}]+)|\b(?:row-|column-)?gap\s*:\s*([^;{}]+)", CSS)
    off = sorted({v for a, b in values for v in _px(a or b)} - SPACE)
    assert not off, f"spaces off the 4 px grid: {off}"


def test_three_text_tiers_are_told_apart():
    tiers = {name: re.search(rf"--{name}:\s*light-dark\((#[0-9a-f]{{6}}),", CSS).group(1) for name in ("ink", "ink-2", "ink-3")}

    def luminance(color: str) -> float:
        channels = [int(color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
        lin = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
        return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]

    def contrast(a: str, b: str) -> float:
        hi, lo = sorted((luminance(a), luminance(b)), reverse=True)
        return (hi + 0.05) / (lo + 0.05)

    paper = re.search(r"--paper:\s*light-dark\((#[0-9a-f]{6}),", CSS).group(1)
    ink, ink2, ink3 = (contrast(tiers[t], paper) for t in ("ink", "ink-2", "ink-3"))
    assert ink > ink2 > ink3 >= 4.5
    assert ink2 - ink3 >= 2  # a tier you can see, not just a name
