#!/usr/bin/env python3
"""Generate assets/AppIcon.icns from the 噜噜 idle sprite.

Centers frame 0 of the lulu/classic idle clip (Resources/Clips/<id>/000.webp) on a soft-peach rounded
square (1024x1024), writes an .iconset with all standard sizes, then runs
`iconutil -c icns`.

Usage: python3 tools/make_icon.py [sprite.png] [out.icns]
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent


def idle_frame0() -> Path:
    """Frame 0 of lulu/classic idle, via its clip id in the shared store (see tools/build_sprites.py)."""
    import json
    meta = ROOT / "Resources/Sprites/lulu/classic/idle/meta.json"
    if not meta.exists():
        return meta
    store = ROOT / "Resources/Clips" / json.loads(meta.read_text())["clip"]
    return store / f"000.{json.loads((store / 'meta.json').read_text()).get('ext', 'png')}"


SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else idle_frame0()
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "assets/AppIcon.icns"

CANVAS = 1024
MARGIN = 100          # transparent margin around the tile (macOS icon grid ~ 824px tile)
RADIUS = 185          # corner radius of the tile
PEACH = (255, 222, 196, 255)
PEACH_EDGE = (246, 200, 170, 255)
SPRITE_FRAC = 0.78    # sprite height as a fraction of the tile


def make_master() -> Image.Image:
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    box = (MARGIN, MARGIN, CANVAS - MARGIN, CANVAS - MARGIN)
    draw.rounded_rectangle(box, radius=RADIUS, fill=PEACH_EDGE)
    inner = (box[0] + 8, box[1] + 8, box[2] - 8, box[3] - 8)
    draw.rounded_rectangle(inner, radius=RADIUS - 8, fill=PEACH)

    sprite = Image.open(SRC).convert("RGBA")
    bbox = sprite.getbbox()
    if bbox:
        sprite = sprite.crop(bbox)
    tile = CANVAS - 2 * MARGIN
    scale = min(tile * SPRITE_FRAC / sprite.height, tile * SPRITE_FRAC / sprite.width)
    size = (max(1, round(sprite.width * scale)), max(1, round(sprite.height * scale)))
    sprite = sprite.resize(size, Image.LANCZOS)
    x = (CANVAS - size[0]) // 2
    y = (CANVAS - size[1]) // 2 + int(tile * 0.03)  # sit slightly low, looks grounded
    img.alpha_composite(sprite, (x, y))
    return img


def main() -> None:
    if not SRC.exists():
        sys.exit(f"make_icon: sprite not found: {SRC}")
    master = make_master()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for base in (16, 32, 128, 256, 512):
            for mult in (1, 2):
                px = base * mult
                name = f"icon_{base}x{base}{'@2x' if mult == 2 else ''}.png"
                master.resize((px, px), Image.LANCZOS).save(iconset / name)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True)
    print(f"make_icon: wrote {OUT}")


if __name__ == "__main__":
    main()
