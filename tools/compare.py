"""Render an animated comparison GIF of several cutout sequences.
usage: python3 tools/compare.py out.gif "Label:dir" ..."""
import sys, glob, json
from PIL import Image, ImageDraw, ImageFont

out = sys.argv[1]; items = [a.split(':', 1) for a in sys.argv[2:]]
PW, PH, FPS, SECS = 220, 250, 12, 4
font = ImageFont.truetype('/System/Library/Fonts/Hiragino Sans GB.ttc', 16)
seqs = []
for label, d in items:
    frames = [Image.open(f).convert('RGBA') for f in sorted(glob.glob(d + '/*.png'))]
    delays = json.load(open(d + '/meta.json'))['delays'][:len(frames)]
    H = max(f.height for f in frames); W = max(f.width for f in frames)
    s = min((PW - 20) / W, (PH - 50) / H)
    seqs.append((label, frames, delays, s))
cols = min(4, len(seqs)); rows = (len(seqs) + cols - 1) // cols
outs = []
for k in range(FPS * SECS):
    t = k / FPS
    canvas = Image.new('RGBA', (cols * PW, rows * PH), (236, 229, 244, 255))
    d = ImageDraw.Draw(canvas)
    for i, (label, frames, delays, s) in enumerate(seqs):
        total = sum(delays); tt = t % total; j = 0
        while tt > delays[j] and j < len(delays) - 1: tt -= delays[j]; j += 1
        f = frames[j]; f = f.resize((int(f.width * s), int(f.height * s)), Image.LANCZOS)
        x0, y0 = (i % cols) * PW, (i // cols) * PH
        sh = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
        ImageDraw.Draw(sh).ellipse((x0 + PW/2 - 55, y0 + PH - 42, x0 + PW/2 + 55, y0 + PH - 30), fill=(80, 50, 90, 40))
        canvas.alpha_composite(sh)
        canvas.alpha_composite(f, (int(x0 + (PW - f.width) / 2), int(y0 + PH - 36 - f.height)))
        d.text((x0 + 8, y0 + 6), label, font=font, fill=(90, 60, 110, 255))
    outs.append(canvas.convert('RGB').quantize(colors=255, method=Image.Quantize.MEDIANCUT))
outs[0].save(out, save_all=True, append_images=outs[1:], duration=int(1000 / FPS), loop=0, optimize=True)
