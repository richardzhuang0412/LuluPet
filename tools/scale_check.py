"""Render how big each clip of an outfit appears in the app, next to idle.

The app shows every clip of an outfit with one point scale (idle = 170 pt tall), bottom-aligned,
so this strip draws each clip's middle frame at that same scale. Use it after
`python3 tools/build_sprites.py` to check that fidgets / stay / sleep keep the character's size.

usage: python3 tools/scale_check.py [character/outfit ...]
       (default: every outfit's first-listed outfit per character -> design/scale_check_<character>.png)
"""
import json, os, sys
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, 'Resources')
DISPLAY_H = 170 * 2          # 170 pt at 2x
LABEL_H = 22


def load(clip_dir):
    """(frame paths, width, height) for a clip dir: `meta.json` with a "clip" id into Resources/Clips."""
    meta = json.load(open(os.path.join(clip_dir, 'meta.json')))
    if 'clip' in meta:
        store = os.path.join(RES, 'Clips', meta['clip'])
        smeta = json.load(open(os.path.join(store, 'meta.json')))
        ext = smeta.get('ext', 'png')
        return [os.path.join(store, f'{i:03d}.{ext}') for i in range(smeta['frames'])], smeta['width'], smeta['height']
    return [os.path.join(clip_dir, f'{i:03d}.png') for i in range(meta['frames'])], meta['width'], meta['height']


def clips(outfit_dir):
    out = [('idle', os.path.join(outfit_dir, 'idle'))]
    for a in ('react', 'happy', 'sleep'):
        if os.path.exists(os.path.join(outfit_dir, a, 'meta.json')):
            out.append((a, os.path.join(outfit_dir, a)))
    for key in ('fidgets', 'stay', 'clips'):
        p = os.path.join(outfit_dir, f'{key}.json')
        for e in json.load(open(p)) if os.path.exists(p) else []:
            out.append((f"{key[:5]}:{e['name']}", os.path.join(outfit_dir, e['dir'])))
    return out


def strip(character, outfit, dst):
    outfit_dir = os.path.join(RES, 'Sprites', character, outfit)
    items = clips(outfit_dir)
    _, _, idle_h = load(items[0][1])
    scale = DISPLAY_H / idle_h
    tiles = []
    for name, d in items:
        frames, w, h = load(d)
        im = Image.open(frames[len(frames) // 2]).convert('RGBA')
        im = im.resize((round(w * scale), round(h * scale)), Image.LANCZOS)
        tiles.append((name, im))
    COLS = 5
    top = max(t.height for _, t in tiles)
    cw = max(max(t.width for _, t in tiles), 120) + 8
    rows = (len(tiles) + COLS - 1) // COLS
    rh = top + LABEL_H + 8
    sheet = Image.new('RGBA', (cw * COLS + 8, rh * rows), (236, 240, 246, 255))
    draw = ImageDraw.Draw(sheet)
    idle_top = tiles[0][1].getchannel('A').getbbox()[1] - tiles[0][1].height   # idle's head, from the base
    for k, (name, t) in enumerate(tiles):
        x, base = 4 + (k % COLS) * cw, (k // COLS) * rh + top + 4
        if k % COLS == 0:   # guides: idle's head top (red) and the ground (grey)
            draw.line([(0, base + idle_top), (sheet.width, base + idle_top)], fill=(230, 60, 60, 255), width=1)
            draw.line([(0, base), (sheet.width, base)], fill=(120, 120, 120, 255), width=1)
        sheet.alpha_composite(t, (x + (cw - 8 - t.width) // 2, base - t.height))
        draw.text((x + 2, base + 4), name[:30], fill=(40, 40, 40, 255))
    sheet.convert('RGB').save(dst)
    print(f'{character}/{outfit}: {len(tiles)} clips -> {dst}')


if __name__ == '__main__':
    targets = sys.argv[1:]
    if not targets:
        for character in ('lulu', 'lumei'):
            order = json.load(open(os.path.join(RES, 'Sprites', character, 'order.json')))
            strip(character, order[0], os.path.join(ROOT, 'design', f'scale_check_{character}.png'))
    for t in targets:
        character, outfit = t.split('/')
        strip(character, outfit, os.path.join(ROOT, 'design', f'scale_check_{character}_{outfit}.png'))
