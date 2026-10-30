#!/usr/bin/env python3
"""Place two actual keyboard captures side by side without resampling or retouching.

python3 Scripts/compare_keyboard_crops.py apple.png oliv.png \
  --output comparison.png --scale 3 --top-pt 500 \
  --caption 'iPhone 17 Simulator · iOS 27 · portrait · light'

EXIF orientation is applied losslessly before cropping. The crop starts at
the same full-screen coordinate in both images. A JSON
sidecar records source hashes and panel rectangles so the original pixels can
be checked independently. Requires Pillow, as does measure_keyboard.py.
"""

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps, PngImagePlugin


def font(size):
    for path in ("/System/Library/Fonts/Supplemental/Arial.ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size=size)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("native", type=Path)
    parser.add_argument("oliv", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scale", type=float, required=True, help="Source pixels per logical point")
    parser.add_argument("--top-pt", type=float, default=500, help="Shared crop origin in full-screen points")
    parser.add_argument("--caption", default="Same device and host · original screenshot pixels")
    parser.add_argument("--note", default="Unscaled crops; positions and colors are preserved.")
    args = parser.parse_args()
    if args.scale <= 0:
        parser.error("--scale must be positive")
    if args.output.resolve() in (args.native.resolve(), args.oliv.resolve()):
        parser.error("Output must not replace either source screenshot")

    with Image.open(args.native) as native_file, Image.open(args.oliv) as oliv_file:
        profile = native_file.info.get("icc_profile")
        srgb = native_file.info.get("srgb")
        if profile != oliv_file.info.get("icc_profile") or srgb != oliv_file.info.get("srgb"):
            parser.error("Source color profiles differ; capture both from the same environment")
        orientations = [native_file.getexif().get(274, 1), oliv_file.getexif().get(274, 1)]
        native = ImageOps.exif_transpose(native_file).convert("RGB")
        oliv = ImageOps.exif_transpose(oliv_file).convert("RGB")
        if native.size != oliv.size:
            parser.error("Screenshots must have identical pixel dimensions after EXIF orientation")

    width, height = native.size
    top = round(args.top_pt * args.scale)
    if not 0 <= top < height:
        parser.error("--top-pt must fall inside the source screenshot")
    gap, header, footer = 36, 110, 58
    crop_height = height - top
    output = Image.new("RGB", (width * 2 + gap, header + crop_height + footer), "#f4f4f4")
    draw = ImageDraw.Draw(output)
    panels = []
    for index, (title, source, path) in enumerate((("Apple keyboard", native, args.native),
                                                  ("OLIV keyboard", oliv, args.oliv))):
        left = index * (width + gap)
        rectangle = [left, header, left + width, header + crop_height]
        output.paste(source.crop((0, top, width, height)), (left, header))
        draw.text((left + 24, 15), title, font=font(40), fill="#151515")
        draw.text((left + 24, 68), args.caption, font=font(25), fill="#505050")
        panels.append({"title": title, "source": str(path.resolve()),
                       "source_exif_orientation": orientations[index],
                       "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                       "source_crop_px": [0, top, width, height], "output_panel_px": rectangle})
    draw.text((24, header + crop_height + 17), args.note, font=font(24), fill="#505050")

    png_info = PngImagePlugin.PngInfo()
    if srgb is not None:
        png_info.add(b"sRGB", bytes([srgb]))
    output.save(args.output, icc_profile=profile, pnginfo=png_info)
    metadata = {"source_size_px": [width, height], "output_size_px": list(output.size),
                "coordinate_system": "display pixels after lossless EXIF orientation",
                "scale": args.scale, "caption": args.caption, "note": args.note,
                "resampled": False, "panels": panels}
    args.output.with_suffix(".json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
