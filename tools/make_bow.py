"""Extract the bow from a 噜妹 cutout frame and recolor it pink.
usage: python3 tools/make_bow.py  (writes build/lumei/bow.png)"""
from PIL import Image, ImageFilter
import colorsys, collections

src = Image.open('build/cut/lumei_01/000.png').convert('RGBA').crop((200, 30, 330, 100))
px = src.load(); w, h = src.size
m = Image.new('L', (w, h), 0); mp = m.load()
for y in range(h):
    for x in range(w):
        r, g, b, a = px[x, y]
        if a < 100: continue
        hh, s, v = colorsys.rgb_to_hsv(r/255, g/255, b/255)
        if (hh < 0.045 or hh > 0.9) and s > 0.3: mp[x, y] = 255
m = m.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.MaxFilter(3))  # drop thin outline arc
m = m.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.MinFilter(5))  # fill holes
mp = m.load(); seen = set(); best = []
for y in range(h):
    for x in range(w):
        if mp[x, y] > 128 and (x, y) not in seen:
            comp = []; q = collections.deque([(x, y)]); seen.add((x, y))
            while q:
                cx, cy = q.popleft(); comp.append((cx, cy))
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = cx+dx, cy+dy
                    if 0 <= nx < w and 0 <= ny < h and (nx, ny) not in seen and mp[nx, ny] > 128:
                        seen.add((nx, ny)); q.append((nx, ny))
            if len(comp) > len(best): best = comp
vals = []
sm = src.filter(ImageFilter.GaussianBlur(0.7)).load()
for x, y in best:
    r, g, b, a = sm[x, y]; vals.append(colorsys.rgb_to_hsv(r/255, g/255, b/255)[2])
lo, hi = sorted(vals)[len(vals)//20], sorted(vals)[-len(vals)//20]
out = Image.new('RGBA', (w, h), (0, 0, 0, 0)); o = out.load()
for x, y in best:
    r, g, b, a = sm[x, y]; v = colorsys.rgb_to_hsv(r/255, g/255, b/255)[2]
    t = min(1, max(0, (v - lo) / (hi - lo + 1e-6)))           # normalized shading
    nr, ng, nb = colorsys.hsv_to_rgb(0.94, 0.55 - 0.2*t, 0.72 + 0.28*t)
    o[x, y] = (int(nr*255), int(ng*255), int(nb*255), 255)
out.putalpha(out.split()[3].filter(ImageFilter.GaussianBlur(0.8)))
out = out.crop(out.getbbox()); out.save('build/lumei/bow.png')
