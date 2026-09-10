#!/usr/bin/env python3
"""Generate the dmg installer background (assets/dmg/).

Produces bg.png (660x400 @1x), bg@2x.png (1320x800), and combines them into
bg.tiff (multi-resolution, via macOS `tiffutil -cathidpicheck`) — the file
scripts/dmg_settings.py points dmgbuild at, so the drag-to-install window is
crisp on both Retina and non-Retina displays.

Design: flat cream canvas matching the app icon set (oliv_logo_assets), the
olive+waveform mark centered at the top, a muted arrow between the two icon
slots (OLIV.app at x=165, Applications at x=495, both y=240 with 128px icons —
keep in sync with dmg_settings.py), and a small install caption at the bottom.

Run manually after changing the design, then commit the three outputs:
    python3 scripts/make_dmg_background.py
Uses Pillow + the system Helvetica; run with any python3 that has PIL.
"""

import pathlib
import subprocess

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "dmg"
MARK = ROOT / "oliv_logo_assets" / "oliv-mark-transparent.png"

W, H = 660, 400          # window content size @1x (dmg_settings.py window_rect)
ICON_Y = 240             # icon-slot center row (dmg_settings.py icon_locations)
APP_X, APPS_X = 165, 495 # icon-slot center columns

CREAM = (251, 248, 237, 255)   # matches the icon exports' background
DARK = (51, 50, 31, 255)       # dark olive, the mark's own color
MUTED = (167, 164, 133, 255)   # low-contrast olive-gray for arrow + caption


def render(scale: int) -> Image.Image:
    s = scale
    img = Image.new("RGBA", (W * s, H * s), CREAM)
    draw = ImageDraw.Draw(img)

    # Mark, centered near the top.
    mark = Image.open(MARK).convert("RGBA")
    mh = 84 * s
    mw = round(mark.width * mh / mark.height)
    mark = mark.resize((mw, mh), Image.LANCZOS)
    img.alpha_composite(mark, (W * s // 2 - mw // 2, 36 * s))

    # Arrow between the two icon slots (icons are 128px wide, centered at
    # APP_X / APPS_X, so the gap runs ~229..431; inset a little from both).
    y = ICON_Y * s
    x0, x1 = 258 * s, 402 * s
    lw = 7 * s
    head = 22 * s
    draw.line([(x0, y), (x1 - head, y)], fill=MUTED, width=lw)
    draw.polygon(
        [(x1, y), (x1 - head, y - head // 2 - lw // 2), (x1 - head, y + head // 2 + lw // 2)],
        fill=MUTED,
    )

    # Caption under everything.
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 15 * s, index=0)
    text = "Drag OLIV into the Applications folder to install"
    tw = draw.textlength(text, font=font)
    draw.text(((W * s - tw) // 2, 356 * s), text, font=font, fill=MUTED)

    return img


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    p1 = OUT / "bg.png"
    p2 = OUT / "bg@2x.png"
    render(1).save(p1)
    render(2).save(p2)
    # Multi-resolution TIFF: Finder picks the right representation per display.
    subprocess.run(
        ["tiffutil", "-cathidpicheck", str(p1), str(p2), "-out", str(OUT / "bg.tiff")],
        check=True,
    )
    print(f"wrote {p1}, {p2}, {OUT / 'bg.tiff'}")


if __name__ == "__main__":
    main()
