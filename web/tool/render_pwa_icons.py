#!/usr/bin/env python3
"""Render Recall PWA icons from the shared geometric R mark.

Mirrors health_exercise_flutter/web/tool/render_pwa_icons.py (same indigo, same
tile/bar radii, same outputs) but draws an "R" — vertical stem + closed bowl
(top/right/waist bars) + a diagonal leg — to match the H/L family.

Produces:
  icons/Icon-192.png, Icon-512.png            -- rounded-tile, transparent corners
  icons/Icon-maskable-192.png, -512.png       -- full-bleed maskable icons
  icons/apple-touch-icon.png                  -- opaque full-bleed iOS icon
  favicon.png                                 -- 64px rounded tile

Run from health-apps/health_anki_flutter:
  python3 web/tool/render_pwa_icons.py
"""
from __future__ import annotations

import os

from PIL import Image, ImageDraw

WEB = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
ICONS = os.path.join(WEB, "icons")
SS = 4
START = (0x8A, 0x90, 0xFF)  # indigo — identical to Lift
END = (0x5B, 0x5F, 0xE0)
INK = (0x1B, 0x1B, 0x29)
# Rounded ink bars in the shared 512 viewBox (stem matches L's stem).
BARS = [
    (164, 128, 220, 384),   # stem (full height)
    (164, 128, 320, 184),   # top bar
    (294, 128, 350, 252),   # bowl right (top -> waist)
    (164, 232, 320, 288),   # waist bar (closes the bowl)
]
# Diagonal leg: thick bar from the waist down to the bottom-right.
LEG = ((250, 270), (344, 378), 56)  # (start, end, thickness) in 512 viewBox
TILE_RADIUS_512 = 120
BAR_RADIUS_512 = 28


def _lerp(a: int, b: int, t: float) -> int:
    return round(a + (b - a) * t)


def _gradient(size: int) -> Image.Image:
    img = Image.new("RGB", (size, size))
    px = img.load()
    denom = max(1, 2 * (size - 1))
    for y in range(size):
        for x in range(size):
            t = (x + y) / denom
            px[x, y] = (
                _lerp(START[0], END[0], t),
                _lerp(START[1], END[1], t),
                _lerp(START[2], END[2], t),
            )
    return img


def _leg_polygon(scale: float):
    (ax, ay), (bx, by), thick = LEG
    ax, ay, bx, by = ax * scale, ay * scale, bx * scale, by * scale
    dx, dy = bx - ax, by - ay
    length = max(1.0, (dx * dx + dy * dy) ** 0.5)
    # unit perpendicular * half-thickness
    px, py = (dy / length) * (thick * scale / 2), (-dx / length) * (thick * scale / 2)
    return [(ax + px, ay + py), (bx + px, by + py), (bx - px, by - py), (ax - px, ay - py)]


def _draw_r(img: Image.Image, size: int) -> None:
    draw = ImageDraw.Draw(img)
    scale = size / 512.0
    radius = BAR_RADIUS_512 * scale
    for x0, y0, x1, y1 in BARS:
        draw.rounded_rectangle(
            [x0 * scale, y0 * scale, x1 * scale, y1 * scale], radius=radius, fill=INK
        )
    draw.polygon(_leg_polygon(scale), fill=INK)


def render_rounded(size: int) -> Image.Image:
    scaled = size * SS
    grad = _gradient(scaled)
    mask = Image.new("L", (scaled, scaled), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, scaled - 1, scaled - 1], radius=TILE_RADIUS_512 * scaled / 512.0, fill=255
    )
    tile = Image.new("RGBA", (scaled, scaled), (0, 0, 0, 0))
    tile.paste(grad, (0, 0), mask)
    _draw_r(tile, scaled)
    return tile.resize((size, size), Image.LANCZOS)


def render_fullbleed(size: int, opaque: bool) -> Image.Image:
    scaled = size * SS
    img = _gradient(scaled)
    _draw_r(img, scaled)
    img = img.resize((size, size), Image.LANCZOS)
    return img if opaque else img.convert("RGBA")


def main() -> None:
    os.makedirs(ICONS, exist_ok=True)
    render_rounded(192).save(os.path.join(ICONS, "Icon-192.png"))
    render_rounded(512).save(os.path.join(ICONS, "Icon-512.png"))
    render_fullbleed(192, opaque=False).save(os.path.join(ICONS, "Icon-maskable-192.png"))
    render_fullbleed(512, opaque=False).save(os.path.join(ICONS, "Icon-maskable-512.png"))
    render_fullbleed(180, opaque=True).save(os.path.join(ICONS, "apple-touch-icon.png"))
    render_rounded(64).save(os.path.join(WEB, "favicon.png"))
    print("wrote Recall PWA icons:", sorted(os.listdir(ICONS)), "+ favicon.png")


if __name__ == "__main__":
    main()
