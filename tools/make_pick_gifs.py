"""Re-cut the user-picked 2026-10-04 tools/weather clips into assets/gifs (v0.12).

Specs are the exact ones reviewed in design/review/2026-10-04-tools-weather/_work (items_vid.py / items_lib.py):
video items are cropped from design/review/2026-10-04-tools-weather/raw/<BV>.mp4 with ffmpeg (12 fps, <=480 px high,
palette gif), library items with frames/pingpong are re-saved from assets/library|gifs. Output: assets/gifs/<name>.gif.
Run once from the repo root; the sprite build then cuts them out (tools/build_sprites.py).
usage: python3 tools/make_pick_gifs.py [name ...]
"""
import os, subprocess, sys
from PIL import Image

R = 'design/review/2026-10-04-tools-weather'
R2 = 'design/review/2026-10-07-lumei'
FF = f'{R}/_work/ffmpeg'


def vid(name, bv, t, crop, pingpong=False, erase=None, erase_color=(185, 170, 200), root=R):
    return dict(name=name, kind='vid', bv=bv, t=t, crop=crop, pingpong=pingpong, erase=erase, erase_color=erase_color, root=root)


def lib(name, src, frames=None, pingpong=False):
    return dict(name=name, kind='lib', src=src, frames=frames, pingpong=pingpong)


ITEMS = [
    vid('tool_W04', 'BV1i63x6cE1s', [2.1, 5.0], [250, 90, 720, 920]),
    vid('tool_W05', 'BV1i63x6cE1s', [2.1, 5.0], [990, 70, 680, 940]),
    vid('tool_W06', 'BV1H5uj6gE2g', [2.5, 4.6], [390, 110, 640, 860]),
    vid('tool_W07', 'BV19PrhBLEeE', [0.0, 1.45], [0, 170, 1080, 765]),
    vid('tool_W09', 'BV17HDABYEhU', [0.3, 3.6], [0, 280, 425, 660]),
    vid('tool_S07', 'BV1Md3q6SEh8', [1.15, 2.9], [840, 130, 680, 840]),
    vid('tool_S08', 'BV1TjtQ6hEFk', [8.5, 11.0], [90, 400, 960, 1380]),
    lib('tool_F01', 'sohu_004', [0, 18], True),
    vid('wx_R04', 'BV1138z6AESp', [2.05, 3.75], [10, 110, 1010, 960]),
    # wx_R03 (sohu_088 frames 26-31, rain coat) dropped: puddle splash / torn coat edge in several frames
    vid('wx_H08', 'BV1jA3D6YEJ3', [12.5, 14.5], [290, 50, 820, 670]),
    vid('wx_H09', 'BV1heRDBeEkZ', [1.3, 2.7], [130, 125, 790, 885], erase=[(0, 0), (136, 0), (132, 72), (94, 74), (64, 45), (0, 42)]),
    vid('wx_C01', 'BV1LMrZBtEUm', [0.0, 0.85], [140, 140, 900, 1180]),
    vid('wx_C02', 'BV1LMrZBtEUm', [5.0, 7.9], [120, 250, 850, 930]),
    vid('wx_C05', 'BV18N6uBGE4f', [0.0, 1.8], [40, 170, 380, 450]),
    vid('wx_C06', 'BV1maz4BXEdR', [0.0, 1.8], [90, 320, 930, 1190]),
    vid('wx_C10', 'BV1sqkaBiEGH', [7.6, 9.8], [225, 130, 740, 800], erase=[(318, 352), (444, 352), (444, 480), (318, 480)], erase_color=(236, 240, 247)),
    vid('wx_G01', 'BV1jxzdBnEX7', [2.0, 4.0], [175, 335, 410, 632]),
    vid('wx_G02', 'BV131CXByEx5', [0.0, 0.9], [0, 0, 1080, 1420], pingpong=True),
    # v0.12.2: 噜妹 rain clips (design/review/2026-10-07-lumei: LR02 lotus-leaf umbrella, LR04 clover-leaf umbrella, ping-pong)
    vid('wx_LR02', 'BV1YN8u6dEaf', [0.0, 5.3], [600, 160, 600, 520], root=R2),
    vid('wx_LR04', 'BV1YN8u6dEaf', [7.4, 7.95], [680, 20, 540, 700], pingpong=True, root=R2),
]


def prep_vid(it, out, fps=12):
    x, y, w, h = it['crop']
    H = min(480, h)
    base = f'crop={w}:{h}:{x}:{y},fps={fps},scale=-2:{H}:flags=lanczos'
    if it['pingpong']:
        vf = base + ',split[a][b];[b]reverse,trim=start_frame=1,setpts=PTS-STARTPTS[r];[a][r]concat=n=2:v=1,split[c][d]'
    else:
        vf = base + ',split[c][d]'
    vf += ';[c]palettegen=max_colors=250:stats_mode=full[p];[d][p]paletteuse=dither=sierra2_4a'
    # erase happens on the cropped source resolution in the review build (after scaling): same here, on the gif.
    subprocess.run(['nice', '-n', '19', FF, '-nostdin', '-v', 'error', '-y', '-threads', '2', '-ss', str(it['t'][0]),
                    '-t', str(it['t'][1] - it['t'][0]), '-i', f"{it['root']}/raw/{it['bv']}.mp4", '-filter_complex', vf, out], check=True)
    if it['erase']:
        from PIL import ImageDraw
        im = Image.open(out)
        fr, du = [], []
        for k in range(im.n_frames):
            im.seek(k)
            f = im.convert('RGB')
            ImageDraw.Draw(f).polygon(it['erase'], fill=tuple(it['erase_color']))
            fr.append(f)
            du.append(im.info.get('duration', 83))
        fr[0].save(out, save_all=True, append_images=fr[1:], duration=du, loop=0)


def prep_lib(it, out):
    p = next(q for q in (f"assets/gifs/{it['src']}.gif", f"assets/library/{it['src']}.gif") if os.path.exists(q))
    im = Image.open(p)
    a, b = it['frames'] or [0, im.n_frames - 1]
    fr, du = [], []
    for k in range(a, b + 1):
        im.seek(k)
        fr.append(im.convert('RGB'))
        du.append(im.info.get('duration', 80))
    if it['pingpong']:
        fr += fr[-2:0:-1]
        du += du[-2:0:-1]
    fr[0].save(out, save_all=True, append_images=fr[1:], duration=du, loop=0, optimize=False)


if __name__ == '__main__':
    only = set(sys.argv[1:])
    for it in ITEMS:
        if only and it['name'] not in only:
            continue
        out = f"assets/gifs/{it['name']}.gif"
        (prep_vid if it['kind'] == 'vid' else prep_lib)(it, out)
        print(out, flush=True)
