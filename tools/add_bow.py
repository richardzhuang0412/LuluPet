"""Overlay the pink bow on every frame of a 噜噜 cutout sequence (covering the orange).
usage: python3 tools/add_bow.py <cut_dir> <out_dir>"""
import sys, os, glob, json, shutil
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
bow = Image.open('build/lumei/bow.png').convert('RGBA')
for f in sorted(glob.glob(src + '/*.png')):
    im = Image.open(f).convert('RGBA'); a = im.split()[3].load(); w, h = im.size
    rows = [y for y in range(h) if any(a[x, y] > 128 for x in range(0, w, 2))]
    y0 = rows[0]
    band = [x for y in range(y0, min(h, y0 + int(h * 0.07))) for x in range(w) if a[x, y] > 128]
    cx = sum(band) / len(band)
    ow = max(band) - min(band) + 1                       # orange width near head top
    bw = int(ow * 1.9); bh = int(bow.height * bw / bow.width)
    b = bow.resize((bw, bh), Image.LANCZOS)
    # grow canvas upward if the bow would stick out of the top
    top = int(y0 + ow * 0.55 - bh / 2)
    pad = max(0, -top)
    canvas = Image.new('RGBA', (w, h + pad), (0, 0, 0, 0)); canvas.alpha_composite(im, (0, pad))
    canvas.alpha_composite(b, (int(cx - bw / 2), top + pad))
    canvas.save(os.path.join(dst, os.path.basename(f)))
shutil.copy(os.path.join(src, 'meta.json'), os.path.join(dst, 'meta.json'))
