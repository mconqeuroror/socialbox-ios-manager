#!/usr/bin/env python3
"""Render SocialBox SpringBoard icons from a single 1024px master.

Dark charcoal field matches SBInk / SBPanel. The mark is a stacked
container pair (the product) with a bold S on the front box. iOS applies
the rounded-rect mask; this artwork stays square.
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

INK = (14, 17, 20, 255)
PANEL = (23, 28, 31, 255)
CYAN = (46, 230, 214, 255)
CYAN_DEEP = (18, 92, 108, 255)
CYAN_MID = (32, 168, 176, 255)
GLOW = (20, 110, 124, 255)

SIZES = (
    ("AppIcon.png", 60),
    ("AppIcon@2x.png", 120),
    ("AppIcon@3x.png", 180),
    ("AppIcon20x20@2x.png", 40),
    ("AppIcon20x20@3x.png", 60),
    ("AppIcon29x29@2x.png", 58),
    ("AppIcon29x29@3x.png", 87),
    ("AppIcon40x40@2x.png", 80),
    ("AppIcon40x40@3x.png", 120),
    ("AppIcon60x60@2x.png", 120),
    ("AppIcon60x60@3x.png", 180),
    ("AppIcon76x76@2x.png", 152),
    ("AppIcon83.5x83.5@2x.png", 167),
    ("iTunesArtwork@2x.png", 1024),
)

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "lucid" / "Manager" / "Resources"
MASTER = 1024


def _font(size: int) -> ImageFont.FreeTypeFont:
    candidates = (
        ("/System/Library/Fonts/SFNS.ttf", 0),
        ("/System/Library/Fonts/HelveticaNeue.ttc", 1),
        ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 0),
        ("/Library/Fonts/Arial Unicode.ttf", 0),
    )
    for path, index in candidates:
        try:
            return ImageFont.truetype(path, size=size, index=index)
        except OSError:
            continue
    return ImageFont.load_default()


def _lerp(a: tuple[int, ...], b: tuple[int, ...], t: float) -> tuple[int, ...]:
    return tuple(int(round(x + (y - x) * t)) for x, y in zip(a, b))


def _background() -> Image.Image:
    img = Image.new("RGBA", (MASTER, MASTER), INK)
    px = img.load()
    for y in range(MASTER):
        t = y / (MASTER - 1)
        row = _lerp(INK, PANEL, t * 0.85)
        for x in range(MASTER):
            px[x, y] = row
    glow = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    cx = cy = MASTER / 2
    for radius, alpha in ((420, 70), (300, 90), (180, 70)):
        color = (GLOW[0], GLOW[1], GLOW[2], alpha)
        draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=color)
    return Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(48)))


def _rounded(draw: ImageDraw.ImageDraw, box, radius: float, fill, outline=None, width: int = 0) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def _master() -> Image.Image:
    img = _background()
    layer = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    back = (338, 228, 848, 698)
    front = (176, 326, 686, 796)
    radius = 118

    shadow = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow)
    _rounded(sdraw, tuple(v + 18 for v in front), radius, (0, 0, 0, 110))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(22)))

    _rounded(draw, back, radius, CYAN_DEEP, CYAN_MID, 22)
    lid = (back[0] + 36, back[1] + 28, back[2] - 36, back[1] + 86)
    _rounded(draw, lid, 28, CYAN_MID)

    _rounded(draw, front, radius, CYAN)
    inner = (front[0] + 28, front[1] + 28, front[2] - 28, front[3] - 28)
    _rounded(draw, inner, 92, (38, 238, 222, 255), (14, 17, 20, 36), 10)

    font = _font(390)
    s = "S"
    bbox = draw.textbbox((0, 0), s, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    fx = (front[0] + front[2]) / 2 - tw / 2 - bbox[0]
    fy = (front[1] + front[3]) / 2 - th / 2 - bbox[1] - 8
    draw.text((fx + 6, fy + 10), s, font=font, fill=(8, 12, 14, 70))
    draw.text((fx, fy), s, font=font, fill=INK)

    return Image.alpha_composite(img, layer)


def write_icons(out_dir: Path = OUT_DIR) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    master = _master()
    written = []
    for name, size in SIZES:
        path = out_dir / name
        resized = master.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(path, "PNG", optimize=True)
        written.append(path)
    return written


def main() -> None:
    for path in write_icons():
        with Image.open(path) as img:
            print(f"{path.name:28} {img.size[0]:4}x{img.size[1]:<4} {path.stat().st_size:7} bytes")


if __name__ == "__main__":
    main()
