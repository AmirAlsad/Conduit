#!/usr/bin/env python3
"""
edit.py — image-to-image enhancement using OpenAI's gpt-image-2 model.

This is the AI-enhancement stage of the ASO screenshot pipeline: it takes a
deterministic scaffold (from compose.py) and turns it into a polished App Store
screenshot. It supports 1–10 input images (pass the scaffold first; optionally
add an already-approved screenshot as a style reference) and can produce up to 4
variants in a single call (--n).

Adapted from `dshark3y/gpt-image-2-skill` (edit.py), MIT licensed — the OpenAI
SDK call, the .env loader, and the gpt-image-2 size validator come from there.
Changes here: plain `python3` + pip (no `uv`/PEP 723), ASO-tuned defaults
(9:16 portrait, high quality), v1/v2/v3 output naming, and friendlier auth
errors. See the repo NOTICE for attribution.

Requires: `pip install -r requirements.txt` (the `openai` package) and an
OPENAI_API_KEY (exported, or in a `.env` file in the project root).

Usage:
    python3 edit.py --prompt "..." --images scaffold.png [style-ref.png ...] \
        --output screenshots/01-slug/v.png --n 3 --size 1440x2560 --quality high

With --n > 1 the output stem gets an index appended, e.g. --output .../v.png
writes .../v1.png, .../v2.png, .../v3.png.
"""

import argparse
import base64
import os
import sys


def load_env(env_path):
    """Load key=value pairs from a .env file into os.environ (existing env wins)."""
    if not env_path or not os.path.exists(env_path):
        return
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip("'\"")
            os.environ.setdefault(key, value)


def validate_size(size_str):
    """Validate size meets gpt-image-2 constraints. Passes 'auto' through unchanged."""
    if size_str.strip().lower() == "auto":
        return "auto"
    try:
        w, h = map(int, size_str.lower().split("x"))
    except ValueError:
        raise ValueError(f"Invalid size format '{size_str}'. Use WxH (e.g. 1440x2560) or 'auto'.")

    errors = []
    if w % 16 != 0 or h % 16 != 0:
        errors.append(f"Both dimensions must be multiples of 16. Got {w}x{h}.")
    if max(w, h) > 3840:
        errors.append(f"Max edge must be ≤ 3840px. Got {max(w, h)}.")
    if max(w, h) / min(w, h) > 3:
        errors.append(f"Aspect ratio must be ≤ 3:1. Got {w}:{h}.")
    total = w * h
    if total > 8_294_400:
        errors.append(f"Total pixels must be ≤ 8,294,400. Got {total:,}.")
    if total < 655_360:
        errors.append(f"Total pixels must be ≥ 655,360. Got {total:,}.")
    if errors:
        raise ValueError("Size validation failed:\n  " + "\n  ".join(errors))
    if total > 3_686_400:
        print(f"⚠  Size {w}x{h} ({total:,}px) exceeds 2K — results may be more variable.", file=sys.stderr)
    return f"{w}x{h}"


def main():
    parser = argparse.ArgumentParser(description="Enhance a scaffold into an App Store screenshot with gpt-image-2")
    parser.add_argument("--prompt", required=True, help="Enhancement instruction prompt")
    parser.add_argument("--images", required=True, nargs="+",
                        help="Input image path(s), 1-10 files. Scaffold first; optional style reference(s) after.")
    parser.add_argument("--output", default=None, help="Output file path (default: output.<format>)")
    parser.add_argument("--size", default="1440x2560",
                        help="Output size WxH or 'auto' (default: 1440x2560, a legal 9:16 portrait). "
                             "Apple's exact dimensions (e.g. 1290x2796) are NOT valid here — crop.py resizes after.")
    parser.add_argument("--quality", default="high", choices=["low", "medium", "high", "auto"],
                        help="Output quality (default: high)")
    parser.add_argument("--output-format", default="png", choices=["png", "jpeg", "webp"], help="Output file format")
    parser.add_argument("--output-compression", type=int, default=None, help="Compression 0-100 (jpeg/webp only)")
    parser.add_argument("--n", type=int, default=1, choices=[1, 2, 3, 4], help="Number of variants (1-4)")
    parser.add_argument("--env-file", default=None, help="Path to .env file (default: ./.env in the project root)")
    args = parser.parse_args()

    # Validate size early (no API key needed)
    try:
        size = validate_size(args.size)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    # Validate output_compression
    if args.output_compression is not None:
        if args.output_format == "png":
            print("ERROR: --output-compression only valid with jpeg or webp (not png).", file=sys.stderr)
            sys.exit(1)
        if not 0 <= args.output_compression <= 100:
            print(f"ERROR: --output-compression must be 0-100. Got {args.output_compression}.", file=sys.stderr)
            sys.exit(1)

    # Validate image count + existence
    if len(args.images) > 10:
        print("ERROR: Maximum 10 input images allowed.", file=sys.stderr)
        sys.exit(1)
    for img_path in args.images:
        if not os.path.exists(img_path):
            print(f"ERROR: Image not found: {img_path}", file=sys.stderr)
            sys.exit(1)

    # Default --output to output.<format> if not provided
    if args.output is None:
        ext_map = {"png": "png", "jpeg": "jpg", "webp": "webp"}
        args.output = f"output.{ext_map[args.output_format]}"

    # Load .env (default: ./.env in the current working directory, i.e. the project root)
    env_path = args.env_file or os.path.join(os.getcwd(), ".env")
    load_env(env_path)

    if not os.environ.get("OPENAI_API_KEY"):
        print("ERROR: OPENAI_API_KEY not found.\n"
              "  Set it with:  export OPENAI_API_KEY=sk-...\n"
              "  or add a line `OPENAI_API_KEY=sk-...` to a .env file in your project root.\n"
              "  Note: OpenAI requires organization verification to use GPT Image models\n"
              "  (https://help.openai.com/en/articles/10910291-api-organization-verification).",
              file=sys.stderr)
        sys.exit(1)

    from openai import OpenAI
    client = OpenAI()

    print(f"Enhancing with {len(args.images)} input image(s) at {size}, quality={args.quality}, n={args.n}...")
    for i, p in enumerate(args.images, 1):
        label = "scaffold" if i == 1 else "style reference"
        print(f"  Image {i} ({label}): {p}")

    image_files = [open(p, "rb") for p in args.images]
    try:
        kwargs = {
            "model": "gpt-image-2",
            "image": image_files,
            "prompt": args.prompt,
            "size": size,
            "quality": args.quality,
            "output_format": args.output_format,
        }
        if args.output_compression is not None:
            kwargs["output_compression"] = args.output_compression
        if args.n > 1:
            kwargs["n"] = args.n
        try:
            result = client.images.edit(**kwargs)
        except Exception as e:  # noqa: BLE001 — surface a friendly hint, then re-raise detail
            msg = str(e)
            if "403" in msg or "verif" in msg.lower() or "permission" in msg.lower():
                print("ERROR: OpenAI rejected the request (403 / permission).\n"
                      "  GPT Image models require organization verification:\n"
                      "  https://help.openai.com/en/articles/10910291-api-organization-verification",
                      file=sys.stderr)
            elif "401" in msg or "api key" in msg.lower() or "authentication" in msg.lower():
                print("ERROR: OpenAI authentication failed — check that OPENAI_API_KEY is valid.", file=sys.stderr)
            else:
                print(f"ERROR: image edit failed: {msg}", file=sys.stderr)
            sys.exit(1)
    finally:
        for fh in image_files:
            fh.close()

    base, ext = os.path.splitext(args.output)
    if not ext:
        ext_map = {"png": ".png", "jpeg": ".jpg", "webp": ".webp"}
        ext = ext_map[args.output_format]

    os.makedirs(os.path.dirname(os.path.abspath(args.output)) or ".", exist_ok=True)

    saved = []
    for i, item in enumerate(result.data):
        # n==1 -> v.png ; n>1 -> v1.png, v2.png, ... (index appended to the stem)
        out_path = f"{base}{ext}" if args.n == 1 else f"{base}{i + 1}{ext}"
        with open(out_path, "wb") as f:
            f.write(base64.b64decode(item.b64_json))
        saved.append(out_path)
        print(f"  ✓ Saved: {out_path}")

    return saved


if __name__ == "__main__":
    main()
