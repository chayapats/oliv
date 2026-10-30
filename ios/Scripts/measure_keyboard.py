#!/usr/bin/env python3
"""Measure visible key fills in an unmodified keyboard screenshot (Pillow only).

Example, for raw @3x screenshots of the same device/host/state:
  python3 Scripts/measure_keyboard.py apple.png --scale 3 --top 1700 --rows 4 --output /tmp/apple.json
  python3 Scripts/measure_keyboard.py oliv.png --scale 3 --top 1700 --rows 4 --compare /tmp/apple.json

--top is a display pixel coordinate after EXIF orientation; omit it to inspect
the lower half. For landscape, choose an earlier crop to include every row.
Colors are
encoded RGB values, so compare screenshots with matching color profiles.
Detection uses flat-fill connected components and is deliberately conservative:
inspect the reported counts/bounds against the originals before treating them
as keys. It does not infer characters or generate replacement keyboard images.
"""

import argparse
import json
import math
import re
import statistics
from pathlib import Path

from PIL import Image, ImageChops, ImageOps


def components(mask):
    """Connected components via scanline runs, without NumPy/SciPy dependencies."""
    width, height = mask.size
    raw = mask.tobytes()
    parents, runs, previous = [], [], []

    def find(index):
        while parents[index] != index:
            parents[index] = parents[parents[index]]
            index = parents[index]
        return index

    for y in range(height):
        current = []
        cursor = 0
        for match in re.finditer(b"\xff+", raw[y * width:(y + 1) * width]):
            left, right = match.span()
            index = len(parents)
            parents.append(index)
            while cursor < len(previous) and previous[cursor][1] <= left:
                cursor += 1
            j = cursor
            while j < len(previous) and previous[j][0] < right:
                parents[find(previous[j][2])] = find(index)
                j += 1
            current.append((left, right, index))
            runs.append((index, left, y, right))
        previous = current
    bounds = {}
    for index, left, y, right in runs:
        root = find(index)
        if root not in bounds:
            bounds[root] = [left, y, right, y + 1, right - left]
        else:
            b = bounds[root]
            b[:] = [min(b[0], left), min(b[1], y), max(b[2], right), y + 1, b[4] + right - left]
    return list(bounds.values())


def color_difference(image, color):
    diff = ImageChops.difference(image, Image.new("RGB", image.size, tuple(color)))
    r, g, b = diff.split()
    return ImageChops.lighter(ImageChops.lighter(r, g), b)


def iou(a, b):
    overlap = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
    return overlap / max(1, (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - overlap)


def measure(path, scale, top, wanted_rows, tolerance):
    with Image.open(path) as source:
        profile = bool(source.info.get("icc_profile"))
        source_size = list(source.size)
        orientation = source.getexif().get(274, 1)
        # XCUIScreen can store landscape pixels in portrait order with an EXIF
        # orientation. Transpose losslessly so coordinates match UIKit points.
        image = ImageOps.exif_transpose(source).convert("RGB")
    width, height = image.size
    top = height // 2 if top is None else top
    if not 0 <= top < height:
        raise ValueError("--top must be inside the screenshot")
    crop = image.crop((0, top, width, height))
    palette = [(color, count) for count, color in sorted(crop.getcolors(crop.width * crop.height), reverse=True)[:16]]
    candidates = []
    for color, count in palette:
        if count < crop.width * crop.height * 0.003:
            continue
        mask = color_difference(crop, color).point(lambda value: 255 if value <= tolerance else 0)
        for left, y, right, bottom, area in components(mask):
            w, h = right - left, bottom - y
            fill = area / max(1, w * h)
            if not (10 * scale <= w < width * 0.8 and 20 * scale <= h <= 90 * scale and fill >= 0.65):
                continue
            rect = [left, y + top, right, bottom + top]
            candidates.append({"rect_px": rect, "fill_rgb": list(color), "fill_fraction": round(fill, 4)})
    keys = []
    for key in sorted(candidates, key=lambda key: key["fill_fraction"], reverse=True):
        if not any(iou(key["rect_px"], prior["rect_px"]) > 0.85 for prior in keys):
            keys.append(key)
    groups = []
    for key in sorted(keys, key=lambda key: key["rect_px"][1]):
        y = key["rect_px"][1]
        group = next((g for g in groups if abs(statistics.median(k["rect_px"][1] for k in g) - y) < 5 * scale), None)
        if group is None:
            groups.append([key])
        else:
            group.append(key)
    groups = [group for group in groups if len(group) >= 3]
    if wanted_rows:
        groups = groups[-wanted_rows:]
    rows = []
    for group in groups:
        group.sort(key=lambda key: key["rect_px"][0])
        for index, key in enumerate(group):
            l, t, r, b = key["rect_px"]
            key["index"] = index
            key["frame_pt"] = [round(value / scale, 3) for value in (l, t, r - l, b - t)]
            key["fill_hex"] = "#" + "".join(f"{c:02x}" for c in key["fill_rgb"])
            if index == 0:
                # A curve profile is more reliable than asserting a private
                # UIKit corner implementation. Circle-fit radius is an estimate.
                scan, radii = [], []
                for dy in sorted({max(1, round(scale * points)) for points in (1, 2, 3)}):
                    if t + dy >= b:
                        continue
                    matching = [x - l for x in range(l, r)
                                if max(abs(a - c) for a, c in zip(image.getpixel((x, t + dy)), key["fill_rgb"])) <= tolerance]
                    if matching:
                        dx = min(matching)
                        scan.append({"depth_px": dy, "left_inset_px": dx})
                        radii.append((dx + dy + math.sqrt(2 * dx * dy)) / scale)
                key["corner_scan"] = scan
                if radii:
                    key["circular_radius_estimate_pt"] = round(statistics.median(radii), 3)
            glyph_mask = color_difference(image.crop((l, t, r, b)), key["fill_rgb"])
            glyphs = [box for box in components(glyph_mask.point(lambda value: 255 if value > 64 else 0))
                      if box[0] > 0 and box[1] > 0 and box[2] < r - l and box[3] < b - t and box[4] > 2]
            if glyphs:
                ink_box = (min(g[0] for g in glyphs), min(g[1] for g in glyphs),
                           max(g[2] for g in glyphs), max(g[3] for g in glyphs))
                key["glyph_bounds_pt"] = [round(value / scale, 3) for value in ink_box]
                # Bounds alone cannot detect an incorrect typeface/weight. Sum
                # antialiased ink coverage with two pixels of margin, excluding
                # key corners. This is an optical measurement, not font identity.
                ink = glyph_mask.crop((max(1, ink_box[0] - 2), max(1, ink_box[1] - 2),
                                       min(r - l - 1, ink_box[2] + 2), min(b - t - 1, ink_box[3] + 2)))
                contrast = max(max(key["fill_rgb"]), 255 - min(key["fill_rgb"]))
                coverage = sum(value * count for value, count in enumerate(ink.histogram())) / contrast
                key["glyph_ink_area_pt2"] = round(coverage / scale ** 2, 4)
            key["below_center_rgb"] = [list(image.getpixel(((l + r) // 2, y))) for y in range(b, min(height, b + 4))]
        rows.append({"key_count": len(group), "top_pt": statistics.median(key["frame_pt"][1] for key in group),
                     "height_pt": statistics.median(key["frame_pt"][3] for key in group),
                     "gaps_pt": [round((nxt["rect_px"][0] - prev["rect_px"][2]) / scale, 3)
                                 for prev, nxt in zip(group, group[1:])], "keys": group})
    return {"source": str(path.resolve()), "image_px": [width, height], "scale": scale,
            "source_image_px": source_size, "source_exif_orientation": orientation,
            "crop_top_px": top, "icc_profile_present": profile,
            "warnings": ["A detected key touches the crop boundary; reduce --top before trusting its height."]
            if any(key["rect_px"][1] == top for row in rows for key in row["keys"]) else [],
            "dominant_colors": [{"rgb": list(color), "pixels": count} for color, count in palette],
            "row_gaps_pt": [round(nxt["top_pt"] - prev["top_pt"] - prev["height_pt"], 3)
                            for prev, nxt in zip(rows, rows[1:])], "rows": rows}


def compare(measured, reference):
    output = {"reference": reference["source"], "same_pixel_size": measured["image_px"] == reference["image_px"],
              "row_counts": [len(measured["rows"]), len(reference["rows"])], "rows": []}
    for ours, native in zip(measured["rows"], reference["rows"]):
        row = {"key_counts": [ours["key_count"], native["key_count"]],
               "top_delta_pt": round(ours["top_pt"] - native["top_pt"], 3),
               "height_delta_pt": round(ours["height_pt"] - native["height_pt"], 3)}
        if ours["key_count"] == native["key_count"]:
            row["keys"] = [{"index": a["index"],
                            "frame_delta_pt": [round(x - y, 3) for x, y in zip(a["frame_pt"], b["frame_pt"])],
                            "fill_rgb_delta": [x - y for x, y in zip(a["fill_rgb"], b["fill_rgb"])],
                            "glyph_present": ["glyph_bounds_pt" in a, "glyph_bounds_pt" in b],
                            "glyph_ink_area_ratio": round(a["glyph_ink_area_pt2"] / b["glyph_ink_area_pt2"], 4)
                            if a.get("glyph_ink_area_pt2") and b.get("glyph_ink_area_pt2") else None,
                            "glyph_bounds_delta_pt": [round(x - y, 3) for x, y in
                                                      zip(a["glyph_bounds_pt"], b["glyph_bounds_pt"])]
                            if "glyph_bounds_pt" in a and "glyph_bounds_pt" in b else None}
                           for a, b in zip(ours["keys"], native["keys"])]
        output["rows"].append(row)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", type=Path)
    parser.add_argument("--scale", type=float, required=True, help="Screenshot pixels per logical point")
    parser.add_argument("--top", type=int, help="Keyboard-region top in screenshot pixels")
    parser.add_argument("--rows", type=int, help="Keep the last N detected rows")
    parser.add_argument("--tolerance", type=int, default=3, help="Maximum per-channel deviation from a fill color")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--compare", type=Path, help="Previously measured native-reference JSON")
    args = parser.parse_args()
    if args.scale <= 0 or not 0 <= args.tolerance <= 16 or (args.rows is not None and args.rows < 1):
        parser.error("Require positive scale/row count and tolerance between 0 and 16")
    result = measure(args.image, args.scale, args.top, args.rows, args.tolerance)
    if args.compare:
        result["comparison"] = compare(result, json.loads(args.compare.read_text()))
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded)
    else:
        print(encoded, end="")


if __name__ == "__main__":
    main()
