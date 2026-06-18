#!/usr/bin/env python3
"""
Showcase Image Generator
Creates a preview image showing up to 3 final App Store screenshots
side-by-side on a white background with an optional GitHub link at the bottom.
"""

import argparse
import os
from PIL import Image, ImageDraw, ImageFont

# ── Layout ──────────────────────────────────────────────────────────
PADDING = 60
GAP = 40
BOTTOM_BAR_H = 100
FONT_SIZE_MAX = 48
FONT_SIZE_MIN = 16
TEXT_COLOUR = "#000000"
BG_COLOUR = (255, 255, 255)

# ── Fonts ───────────────────────────────────────────────────────────
# Bundled OFL fonts (see compose.py for the headline registry). The
# footer uses a regular weight for legibility.
FONTS_DIR = os.path.join(os.path.dirname(__file__), "assets", "fonts")
FONT_REGISTRY = {
    "inter":      "Inter-Black.ttf",
    "montserrat": "Montserrat-Black.ttf",
    "poppins":    "Poppins-Black.ttf",
    "oswald":     "Oswald-Bold.ttf",
    "bebas":      "BebasNeue-Regular.ttf",
    "archivo":    "ArchivoBlack-Regular.ttf",
    "playfair":   "PlayfairDisplay-Black.ttf",
}
DEFAULT_FONT = os.path.join(FONTS_DIR, "Inter-Regular.ttf")
SF_PRO_REGULAR = "/Library/Fonts/SF-Pro-Display-Regular.otf"

# Resolved at runtime in main(). None => PIL default.
FONT_PATH = DEFAULT_FONT


def resolve_font(spec):
    """Resolve a --font value (bundled key, file path, or None) to a usable
    font path. Default footer font is bundled Inter Regular."""
    if spec:
        key = spec.lower().strip()
        if key in FONT_REGISTRY:
            path = os.path.join(FONTS_DIR, FONT_REGISTRY[key])
            if os.path.isfile(path):
                return path
        if os.path.isfile(spec):
            return spec
    if os.path.isfile(DEFAULT_FONT):
        return DEFAULT_FONT
    if os.path.isfile(SF_PRO_REGULAR):
        return SF_PRO_REGULAR
    return None


def fit_text_font(text, max_w, size_max, size_min):
    """Return the largest font size where text fits within max_w."""
    dummy = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    for size in range(size_max, size_min - 1, -2):
        if not FONT_PATH:
            return ImageFont.load_default()
        try:
            font = ImageFont.truetype(FONT_PATH, size)
        except OSError:
            return ImageFont.load_default()
        bbox = dummy.textbbox((0, 0), text, font=font)
        if (bbox[2] - bbox[0]) <= max_w:
            return font
    return ImageFont.truetype(FONT_PATH, size_min)


def create_showcase(screenshots, output_path, github_url=None):
    # Load screenshots
    images = [Image.open(p).convert("RGBA") for p in screenshots]

    # Scale all to same height
    target_h = 800
    scaled = []
    for img in images:
        ratio = target_h / img.height
        scaled.append(img.resize((int(img.width * ratio), target_h), Image.LANCZOS))

    # Calculate canvas size
    total_w = sum(s.width for s in scaled) + GAP * (len(scaled) - 1) + PADDING * 2
    total_h = target_h + PADDING * 2 + (BOTTOM_BAR_H if github_url else 0)

    canvas = Image.new("RGB", (total_w, total_h), BG_COLOUR)

    # Place screenshots
    x = PADDING
    for s in scaled:
        canvas.paste(s, (x, PADDING), s if s.mode == "RGBA" else None)
        x += s.width + GAP

    # Add GitHub URL text
    if github_url:
        draw = ImageDraw.Draw(canvas)
        max_text_w = total_w - PADDING * 2
        font = fit_text_font(github_url, max_text_w, FONT_SIZE_MAX, FONT_SIZE_MIN)

        text_y = PADDING + target_h + (BOTTOM_BAR_H // 2)
        draw.text(
            (total_w // 2, text_y),
            github_url,
            fill=TEXT_COLOUR,
            font=font,
            anchor="mm",
        )

    canvas.save(output_path, "PNG")
    print(f"✓ {output_path} ({total_w}×{total_h})")


def main():
    global FONT_PATH
    p = argparse.ArgumentParser(description="Generate showcase image")
    p.add_argument(
        "--screenshots",
        nargs="+",
        required=True,
        help="Paths to final screenshot PNGs (up to 3)",
    )
    p.add_argument("--output", required=True, help="Output file path")
    p.add_argument("--github", default=None, help="Footer text / handle to display at bottom")
    p.add_argument(
        "--font",
        default=None,
        help="Footer font: a bundled key (%s) or a path. Defaults to bundled "
        "Inter Regular." % "|".join(FONT_REGISTRY),
    )
    args = p.parse_args()

    FONT_PATH = resolve_font(args.font)
    create_showcase(args.screenshots, args.output, args.github)


if __name__ == "__main__":
    main()
