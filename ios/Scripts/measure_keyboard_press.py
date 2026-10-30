#!/usr/bin/env python3
"""Compare one real key before and during a press, without altering images.

Example (point coordinates from measure_keyboard.py):
  python3 Scripts/measure_keyboard_press.py before.png held.png --scale 3 \
      --frame 144.667,652,33.333,43 --output /tmp/pressed-f.json

Use screenshots from the same device, host, appearance and keyboard state.
Decoded video frames retain compression/color-range error: do not treat their
RGB samples as exact source colors. This script measures no touch-event time.
"""

import argparse
import hashlib
import json
import statistics
from pathlib import Path

from PIL import Image, ImageOps


def frame_argument(value):
    try:
        values = tuple(float(item) for item in value.split(","))
    except ValueError as error:
        raise argparse.ArgumentTypeError("Use x,y,width,height in points") from error
    if len(values) != 4 or values[2] <= 0 or values[3] <= 0:
        raise argparse.ArgumentTypeError("Use x,y,positive width,positive height")
    return values


def median_rgb(image, coordinates):
    values = [image.getpixel(point) for point in coordinates]
    return [round(statistics.median(pixel[channel] for pixel in values), 2)
            for channel in range(3)]


def measure(path, frame, scale, ink):
    with Image.open(path) as source:
        orientation = source.getexif().get(274, 1)
        image = ImageOps.exif_transpose(source).convert("RGB")
    x, y, width, height = frame
    left, top = round(x * scale), round(y * scale)
    right, bottom = round((x + width) * scale), round((y + height) * scale)
    if not (0 <= left < right <= image.width and 0 <= top < bottom <= image.height):
        raise ValueError(f"Key frame is outside {path}")
    w, h = right - left, bottom - top
    # Side lanes avoid the central glyph. Inspect the source to ensure its
    # particular glyph does not reach these lanes before interpreting color.
    lanes = list(range(left + round(w * 0.14), left + round(w * 0.25)))
    lanes += list(range(left + round(w * 0.75), left + round(w * 0.86)))
    vertical = [{"height_fraction": fraction,
                 "rgb": median_rgb(image, [(xx, top + min(h - 1, round(fraction * h)))
                                           for xx in lanes])}
                for fraction in (0.06, 0.10, 0.16, 0.25, 0.35, 0.50, 0.65, 0.80, 0.90, 0.95)]
    horizontal = list(range(left + round(w * 0.3), left + round(w * 0.7)))
    top_edge = [{"depth_px": depth,
                 "rgb": median_rgb(image, [(xx, top + depth) for xx in horizontal])}
                for depth in (-2, -1, 0, 1, 2, 3, 4, 6, 9)
                if 0 <= top + depth < image.height]
    inset = min(round(3 * scale), (w - 1) // 2, (h - 1) // 2)
    glyph = image.crop((left + inset, top + inset, right - inset, bottom - inset)).convert("L")
    mask = glyph.point(lambda value: 255 if (value < 100 if ink == "dark" else value > 220) else 0)
    bounds = mask.getbbox()
    glyph_bounds = None if bounds is None else [round((value + inset) / scale, 4) for value in bounds]
    return {"source": str(path.resolve()), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "display_dimensions_px": list(image.size), "source_exif_orientation": orientation,
            "key_frame_pt": list(frame), "key_frame_px": [left, top, right, bottom],
            "glyph_bounds_relative_key_pt": glyph_bounds,
            "vertical_fill_profile": vertical, "top_edge_profile": top_edge}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("before", type=Path)
    parser.add_argument("pressed", type=Path)
    parser.add_argument("--scale", type=float, required=True)
    parser.add_argument("--frame", type=frame_argument, required=True)
    parser.add_argument("--pressed-frame", type=frame_argument, help="Defaults to --frame")
    parser.add_argument("--ink", choices=("dark", "light"), default="dark")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.scale <= 0:
        parser.error("--scale must be positive")
    before = measure(args.before, args.frame, args.scale, args.ink)
    pressed = measure(args.pressed, args.pressed_frame or args.frame, args.scale, args.ink)
    before_ink, pressed_ink = before["glyph_bounds_relative_key_pt"], pressed["glyph_bounds_relative_key_pt"]
    result = {"scale": args.scale, "ink": args.ink, "before": before, "pressed": pressed,
              "glyph_bounds_delta_pt": [round(b - a, 4) for a, b in zip(before_ink, pressed_ink)]
              if before_ink is not None and pressed_ink is not None else None,
              "caveats": ["RGB values are encoded screenshot/frame values, not inferred UIKit source colors.",
                          "Video compression can alter RGB values, edge positions and antialiasing.",
                          "This comparison establishes no touch-down, release or animation duration."]}
    encoded = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded)
    else:
        print(encoded, end="")


if __name__ == "__main__":
    main()
