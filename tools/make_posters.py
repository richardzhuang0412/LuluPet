#!/usr/bin/env python3
"""Poster PNGs for the README / features.md demos: docs/demo/posters/<name>.png, one per GIF.

The README keeps only the hero GIF (plus a couple of small ones) so the page loads fast; every other demo is a small
poster (a frame ~1/3 into the clip, 720 px wide, with a play badge) that links to the same-named MP4.

    build/demo-venv/bin/python tools/make_posters.py            # all GIFs in docs/demo
    build/demo-venv/bin/python tools/make_posters.py daily dnd  # just these

Needs Pillow (build/demo-venv has it).
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
DEMO = ROOT / "docs" / "demo"
OUT = DEMO / "posters"
WIDTH = 720


def poster(gif: Path, out: Path) -> None:
    im = Image.open(gif)
    n = getattr(im, "n_frames", 1)
    im.seek(min(n - 1, max(0, n // 3)))
    frame = im.convert("RGBA")
    h = round(frame.height * WIDTH / frame.width)
    frame = frame.resize((WIDTH, h), Image.LANCZOS)
    # play badge, bottom-right
    badge = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(badge)
    r = 34
    cx, cy = WIDTH - r - 22, h - r - 22
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(0, 0, 0, 150))
    d.polygon([(cx - 11, cy - 20), (cx - 11, cy + 20), (cx + 21, cy)], fill=(255, 255, 255, 235))
    frame = Image.alpha_composite(frame, badge).convert("RGB")
    frame = frame.quantize(colors=160, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    frame.save(out, optimize=True)


def main() -> None:
    OUT.mkdir(exist_ok=True)
    names = sys.argv[1:] or sorted(p.stem for p in DEMO.glob("*.gif"))
    for name in names:
        out = OUT / f"{name}.png"
        poster(DEMO / f"{name}.gif", out)
        print(f"{out.relative_to(ROOT)}  {out.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
