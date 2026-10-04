"""v0.9 review sheet: every new couple / solo clip as it appears in the app (from Resources/ after build_sprites.py).
usage: python3 tools/review_sheet.py [out_dir=design/v090]
Couples are drawn at the pet's display height (340 px = 170 pt @2x) x heightFactor; solo clips relative to the
character's idle (same rule as scale_check.py). 6 evenly spaced frames per clip on a checker background."""
import json, os, sys
from PIL import Image, ImageDraw
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, 'Resources')
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'design/v090')
os.makedirs(OUT, exist_ok=True)
H = 340

def frames(d):
    m = json.load(open(f'{d}/meta.json'))
    st = f"{RES}/Clips/{m['clip']}"
    sm = json.load(open(f'{st}/meta.json'))
    return [f"{st}/{i:03d}.{sm.get('ext','png')}" for i in range(sm['frames'])], m, sm

def checker(w, h, s=14):
    im = Image.new('RGB', (w, h), (232, 232, 232)); d = ImageDraw.Draw(im)
    for y in range(0, h, s):
        for x in range(0, w, s):
            if (x // s + y // s) % 2: d.rectangle((x, y, x + s - 1, y + s - 1), fill=(210, 210, 210))
    return im

def sheet(rows, path, n=6):
    cw = max(r[1][0] for r in rows) * n + 10 * n
    ch = sum(r[1][1] + 28 for r in rows)
    img = Image.new('RGB', (cw, ch), (255, 255, 255)); d = ImageDraw.Draw(img); y = 0
    for label, (w, h), fr in rows:
        d.text((4, y + 6), label, fill=(0, 0, 0)); y += 24
        idx = [round(i * (len(fr) - 1) / (n - 1)) for i in range(n)] if len(fr) > 1 else [0]
        for k, i in enumerate(idx):
            tile = checker(w, h); im = Image.open(fr[i]).convert('RGBA')
            s = h / im.height if False else None
            tile.paste(im.resize((w, h), Image.LANCZOS) if im.size != (w, h) else im, (0, 0), im.resize((w, h), Image.LANCZOS) if im.size != (w, h) else im)
            img.paste(tile, (k * (w + 10), y))
        y += h + 4
    img.save(path)

couples = json.load(open(os.path.join(ROOT, 'assets/couples.json')))
new = ['sleep', 'cuddle_bed', 'coldwar', 'comfort', 'hug_bed', 'sniff', 'bite', 'shout', 'lean']
rows = []
for name in new:
    fr, m, sm = frames(f'{RES}/Couples/{name}')
    hf = m.get('heightFactor', 1); h = int(H * hf); w = int(sm['width'] * h / sm['height'])
    snd = m.get('sound')
    rows.append((f"{name}  facing {m.get('facing')}  heightFactor {hf}  sound {snd}  ({sm['width']}x{sm['height']}px stored, {len(fr)} frames)", (w, h), fr))
sheet(rows, f'{OUT}/couples_new.png')

rows = []
for ch, outfit, names in (('lulu', 'classic', None), ('lumei', 'lace', None)):
    base = f'{RES}/Sprites/{ch}/{outfit}'
    _, _, im = frames(f'{base}/idle'); idleh = im['height']
    for ent in json.load(open(f'{base}/clips.json')):
        if not any(k in ent['name'] for k in ('tenor', 'stomp', 'icecream', 'fart', 'comein')): continue
        fr, m, sm = frames(f"{base}/{ent['dir']}")
        h = int(H * sm['height'] / idleh); w = int(sm['width'] * h / sm['height'])
        rows.append((f"{ch}/{ent['name']}  sound {ent.get('sound')}  ({sm['width']}x{sm['height']}px, idle {idleh}px)", (w, h), fr))
sheet(rows, f'{OUT}/solo_new.png')
print('ok')
