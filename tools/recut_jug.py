"""tool_W07 (放学, water jug): Vision drops the translucent jug in the middle frames when it cuts the whole frame.
Cut the whole frame as usual (body), cut a tight crop around the jug on its own (Vision finds the jug there in every
frame), and union the two masks; the crop only contributes non-orange pixels (the jug), never body leftovers.
Writes build/cut/tool_W07 (tools/build_sprites.py uses it as is). Re-run after changing the gif.
usage: python3 tools/recut_jug.py"""
import glob, json, os, shutil, subprocess
import numpy as np
from PIL import Image

GIF = 'assets/gifs/tool_W07.gif'
OUT = 'build/cut/tool_W07'
TMP = 'build/cut/_tool_W07_vision'
JUG = (100, 150, 330, 470)   # x0, y0, x1, y1 of the jug region in the gif frame
os.makedirs('build/cut', exist_ok=True)
for d in (TMP, TMP + '_jug'):
    shutil.rmtree(d, ignore_errors=True)
src = Image.open(GIF)
n = src.n_frames
S, crops, dur = [], [], []
for i in range(n):
    src.seek(i)
    f = src.convert('RGB')
    S.append(np.array(f).astype(int))
    crops.append(f.crop(JUG))
    dur.append(src.info.get('duration', 80))
crops[0].save(TMP + '_jug.gif', save_all=True, append_images=crops[1:], duration=dur, loop=0)
subprocess.run(['nice', '-n', '19', 'tools/cutout', GIF, TMP], check=True)
subprocess.run(['nice', '-n', '19', 'tools/cutout', TMP + '_jug.gif', TMP + '_jug'], check=True)
meta = json.load(open(f'{TMP}/meta.json'))
H, W = S[0].shape[:2]


def load(d):
    return [np.array(Image.open(p).convert('RGBA')) for p in sorted(glob.glob(f'{d}/*.png'))]


def offset(frame, cut, region):
    """where the bbox-cropped cutout sits inside `frame` (region = frame size)."""
    ch, cw = cut.shape[:2]
    ys, xs = np.nonzero(cut[..., 3] > 250)
    sel = np.random.RandomState(0).choice(len(ys), min(2000, len(ys)))
    ys, xs = ys[sel], xs[sel]
    return min((np.abs(frame[ys + oy, xs + ox] - cut[ys, xs, :3]).mean(), ox, oy)
               for oy in range(region[0] - ch + 1) for ox in range(region[1] - cw + 1))[1:]


C, J = load(TMP), load(TMP + '_jug')
jw, jh = JUG[2] - JUG[0], JUG[3] - JUG[1]
bx, by = offset(S[0], C[0], (H, W))
jx, jy = offset(S[0][JUG[1]:JUG[3], JUG[0]:JUG[2]], J[0], (jh, jw))
full = []
for i in range(n):
    rgba = np.zeros((H, W, 4), np.uint8)
    rgba[by:by + C[i].shape[0], bx:bx + C[i].shape[1]] = C[i]
    jm = np.zeros((H, W), np.uint8)
    jm[JUG[1] + jy:JUG[1] + jy + J[i].shape[0], JUG[0] + jx:JUG[0] + jx + J[i].shape[1]] = J[i][..., 3]
    r, b = S[i][..., 0], S[i][..., 2]
    jm[b < r - 20] = 0                       # orange body / hand pixels belong to the body mask
    add = jm > rgba[..., 3]
    rgba[add, :3] = S[i][add].astype(np.uint8)
    rgba[add, 3] = jm[add]
    full.append(rgba)
bb = [Image.fromarray(x[..., 3]).point(lambda v: 255 if v > 40 else 0).getbbox() for x in full]
x0 = max(0, min(b[0] for b in bb) - 2); y0 = max(0, min(b[1] for b in bb) - 2)
x1 = min(W, max(b[2] for b in bb) + 2); y1 = min(H, max(b[3] for b in bb) + 2)
shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(OUT)
for i, x in enumerate(full):
    Image.fromarray(x[y0:y1, x0:x1]).save(f'{OUT}/{i:03d}.png')
meta.update(width=x1 - x0, height=y1 - y0, fix='jug')
json.dump(meta, open(f'{OUT}/meta.json', 'w'))
for d in (TMP, TMP + '_jug'):
    shutil.rmtree(d, ignore_errors=True)
os.remove(TMP + '_jug.gif')
print('tool_W07 ->', OUT, x1 - x0, y1 - y0, n, 'frames')
