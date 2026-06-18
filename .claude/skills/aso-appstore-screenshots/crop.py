#!/usr/bin/env python3
"""
Cross-platform crop + resize to exact App Store / Play Store dimensions.

AI image models (e.g. OpenAI gpt-image-2) output at preset aspect ratios
(e.g. 9:16), which are WIDER than Apple's required ratio. This trims the
excess — sides cropped equally, top edge preserved so the headline stays
put — then resizes to the exact target pixel size.

Replaces the old macOS-only `sips` loop, so it runs on macOS, Linux, and
Windows (anywhere Pillow is installed).

Usage:
    python3 crop.py --target 1290x2796 v1.jpg v2.jpg v3.jpg
    # -> writes v1-resized.jpg, v2-resized.jpg, v3-resized.jpg

Common targets:
    iPhone 6.5"        1242x2688
    iPhone 6.7" (def)  1290x2796
    iPhone 6.9"        1320x2868
"""

import argparse
import os
import sys

from PIL import Image


def parse_target(spec):
    try:
        w, h = spec.lower().split("x")
        return int(w), int(h)
    except Exception:
        raise argparse.ArgumentTypeError(
            f"--target must look like WIDTHxHEIGHT (e.g. 1290x2796), got '{spec}'"
        )


def crop_resize(input_path, target_w, target_h, suffix="-resized"):
    img = Image.open(input_path)
    w, h = img.size
    target_ratio = target_w / target_h
    img_ratio = w / h

    if img_ratio > target_ratio:
        # Too wide: trim width, keep full height, centre horizontally.
        crop_w = round(h * target_ratio)
        offset_x = round((w - crop_w) / 2)
        box = (offset_x, 0, offset_x + crop_w, h)
    else:
        # Too tall: trim height, keep full width, preserve the top edge
        # (headline lives at the top) so it crops from the bottom.
        crop_h = round(w / target_ratio)
        box = (0, 0, w, crop_h)

    cropped = img.crop(box).resize((target_w, target_h), Image.LANCZOS)

    stem, ext = os.path.splitext(input_path)
    out_path = f"{stem}{suffix}{ext}"
    save_kwargs = {}
    if ext.lower() in (".jpg", ".jpeg"):
        cropped = cropped.convert("RGB")
        save_kwargs = {"quality": 95}
    cropped.save(out_path, **save_kwargs)
    print(f"✓ {out_path} ({target_w}×{target_h})")
    return out_path


def main():
    p = argparse.ArgumentParser(description="Crop + resize images to exact dimensions")
    p.add_argument(
        "--target",
        type=parse_target,
        default=(1290, 2796),
        help="Target size WIDTHxHEIGHT (default 1290x2796, iPhone 6.7\")",
    )
    p.add_argument(
        "--suffix",
        default="-resized",
        help="Suffix appended to output filenames (default '-resized')",
    )
    p.add_argument("inputs", nargs="+", help="One or more image files to process")
    args = p.parse_args()

    target_w, target_h = args.target
    failures = 0
    for path in args.inputs:
        if not os.path.isfile(path):
            print(f"✗ not found: {path}", file=sys.stderr)
            failures += 1
            continue
        try:
            crop_resize(path, target_w, target_h, args.suffix)
        except Exception as e:  # noqa: BLE001 — report and continue the batch
            print(f"✗ {path}: {e}", file=sys.stderr)
            failures += 1

    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
