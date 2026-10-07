#!/usr/bin/env python3
"""Web version assets (spec docs/superpowers/specs/2026-10-06-web-design.md §6.2).

Reads only committed inputs (never assets/library, which is private):
  Resources/Sprites/<character>/{order.json, outfits.json, <outfit>/<action>/meta.json, fidgets.json}
  Resources/Clips/<id>/{meta.json, NNN.webp}        (content-addressed frames, tools/build_sprites.py)
  Resources/Stickers/{stickers.json, <id>.gif}
  Sources/LuluCore/StickerPanel.swift               (defaultFavorites, StickerGroup order + titles)
and writes web/assets/:
  manifest.json
  sprites/<clipid>-h200.<sha10>.webp     one sprite sheet per clip: distinct frames ("cells"), 200 px tall, 8 columns
  stickers/<id>.<sha10>.webp             animated WebP, longest side 200 px
  stickers/thumbs.<sha10>.webp           every sticker's first frame in a 72 px cell (one request)

File names carry the first 10 hex digits of the file's sha256, so a file never changes under the same
name (cache forever). Output is deterministic (same inputs -> byte-identical files); files under
sprites/ and stickers/ that the new manifest does not reference are deleted.

Size rules (so the budgets hold at 200 px):
  - a sheet stores each distinct frame once; the clip's `seq` lists the cell shown for every frame
    (most idle loops are ping-pong, so this roughly halves them);
  - clips faster than ~8 fps (median delay < 0.09 s, e.g. 蕾丝帽) keep every other frame, delays summed;
  - an outfit over budget is re-encoded at a lower quality step (QUALITY_STEPS), then loses fidgets
    (last first), then its largest one-shot clip (react / happy) keeps every 2nd, then 3rd frame
    (delays summed, so the clip lasts as long); still over = the build fails.

Budgets (§6.2; the build fails when one is exceeded): idle clip <= 200 KB; outfit (core actions +
fidgets, distinct sheet files) <= 600 KB; first screen (largest idle + largest default-outfit idle +
manifest + thumbs) <= 1 MB; sticker <= 400 KB (quality steps down 75 -> 65 -> 55 before failing);
web/assets total <= 40 MB.

usage: nice -n 10 python3 tools/build_web_assets.py
"""
import glob, hashlib, io, json, math, os, re, statistics, sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
SPRITES, CLIPS, STICKERS = 'Resources/Sprites', 'Resources/Clips', 'Resources/Stickers'
OUT = 'web/assets'

CHARACTERS = ('lulu', 'lumei')
FRAME_H = 200
COLS = 8
# (quality, alpha_quality) tried in order per outfit; spec §6.2 asks for quality 80.
QUALITY_STEPS = ((80, 90), (72, 80), (65, 70))
FAST_DELAY = 0.09      # clips whose median frame delay is below this keep every other frame
MAX_THIN = 3           # last resort: a one-shot clip of an outfit still over budget keeps every 2nd / 3rd frame
STICKER_MAX = 200
STICKER_QUALITIES = (75, 65, 55)
THUMB = 72
THUMB_COLS = 10
MAX_FIDGETS = 2
# Actions exported per outfit (missing ones are simply absent; see "modes" in the manifest).
ACTIONS = ('idle', 'happy', 'react', 'sleep', 'quiet', 'run', 'wave')
MODES = {'idle': 'loop', 'sleep': 'loop', 'run': 'loop', 'quiet': 'still',
         'happy': 'once', 'react': 'once', 'wave': 'once', 'fidget': 'once'}

KB = 1024
BUDGET_IDLE = 200 * KB
BUDGET_OUTFIT = 600 * KB
BUDGET_FIRST = 1024 * KB
BUDGET_STICKER = 400 * KB
BUDGET_TOTAL = 40 * 1024 * KB


def fail(msg):
    sys.exit(f'build_web_assets: FAILED: {msg}')


def load_json(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def sha10(data):
    return hashlib.sha256(data).hexdigest()[:10]


def webp_bytes(im, **kw):
    buf = io.BytesIO()
    im.save(buf, 'WEBP', **kw)
    return buf.getvalue()


_written = {}   # relative path -> size


def write(rel, data):
    path = f'{OUT}/{rel}'
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if not (os.path.exists(path) and open(path, 'rb').read() == data):
        with open(path, 'wb') as f:
            f.write(data)
    _written[rel] = len(data)


# ---------------------------------------------------------------- sprites

def clip_use(character, outfit, d):
    """A clip use (`<outfit>/<d>/meta.json`): (store id, delays) or None."""
    p = f'{SPRITES}/{character}/{outfit}/{d}/meta.json'
    if not os.path.exists(p):
        return None
    m = load_json(p)
    cid = m.get('clip')
    if not cid or not re.fullmatch(r'[0-9a-f]+', cid):
        fail(f'{p}: no usable "clip" id (old frame layout is not supported)')
    n = load_json(f'{CLIPS}/{cid}/meta.json')['frames']
    delays = tuple(round(float(m['delays'][i]) if i < len(m['delays']) else 0.1, 4) for i in range(n))
    return cid, delays


_cells = {}   # store id -> (cells resized to FRAME_H, seq, [src w, src h], w)


def source_cells(cid):
    """Distinct frames of stored clip `cid` (scaled to FRAME_H) and the cell index of every frame."""
    if cid not in _cells:
        stored = load_json(f'{CLIPS}/{cid}/meta.json')
        n, sw, sh, ext = stored['frames'], stored['width'], stored['height'], stored.get('ext', 'png')
        w = max(1, round(sw * FRAME_H / sh))
        index, cells, seq = {}, [], []
        for i in range(n):
            fr = Image.open(f'{CLIPS}/{cid}/{i:03d}.{ext}').convert('RGBA')
            if fr.size != (sw, sh):   # never expected; keep the canvas, bottom-centred like the app
                canvas = Image.new('RGBA', (sw, sh), (0, 0, 0, 0))
                canvas.paste(fr, ((sw - fr.width) // 2, sh - fr.height))
                fr = canvas
            raw = fr.tobytes()
            if raw not in index:
                index[raw] = len(cells)
                cells.append(fr.resize((w, FRAME_H), Image.LANCZOS))
            seq.append(index[raw])
        _cells[cid] = (cells, seq, [sw, sh], w)
    return _cells[cid]


_sheets = {}   # (store id, step, level) -> (cell map, sheet bytes, cols, rows)


def variant(use, level, thin=1):
    """The web clip for a use at quality step `level`, keeping every `thin`-th frame (on top of the fast-clip
    rule): manifest entry (without key) + sheet bytes."""
    cid, delays = use
    cells, seq, src, w = source_cells(cid)
    step = (2 if len(delays) > 2 and statistics.median(delays) < FAST_DELAY else 1) * thin
    kept = range(0, len(seq), step)
    new_delays = [round(sum(delays[i:i + step]), 4) for i in kept]
    picked = [seq[i] for i in kept]
    order = list(dict.fromkeys(picked))            # cells in first-use order
    skey = (cid, step, level)
    if skey not in _sheets:
        cols = min(COLS, len(order))
        rows = math.ceil(len(order) / cols)
        sheet = Image.new('RGBA', (cols * w, rows * FRAME_H), (0, 0, 0, 0))
        for j, c in enumerate(order):
            sheet.paste(cells[c], ((j % cols) * w, (j // cols) * FRAME_H))
        q, aq = QUALITY_STEPS[level]
        _sheets[skey] = webp_bytes(sheet, quality=q, alpha_quality=aq, method=6)
    data = _sheets[skey]
    pos = {c: j for j, c in enumerate(order)}
    entry = {'file': f'sprites/{cid}-h{FRAME_H}.{sha10(data)}.webp', 'frames': len(new_delays),
             'cells': len(order), 'cols': min(COLS, len(order)), 'w': w, 'h': FRAME_H, 'src': src,
             'delays': new_delays, 'seq': [pos[c] for c in picked]}
    return entry, data


def outfit_plan(character):
    order_file = load_json(f'{SPRITES}/{character}/order.json')
    index = load_json(f'{SPRITES}/{character}/outfits.json')
    available = sorted(o for o in os.listdir(f'{SPRITES}/{character}')
                       if not o.startswith('_') and os.path.exists(f'{SPRITES}/{character}/{o}/idle/meta.json'))
    order = [o for o in order_file if o in available]
    order += [o for o in available if o not in order]
    outfits = {}
    for o in order:
        actions = {a: u for a in ACTIONS if (u := clip_use(character, o, a))}
        fid = []
        fpath = f'{SPRITES}/{character}/{o}/fidgets.json'
        for e in (load_json(fpath) if os.path.exists(fpath) else []):
            d = e if isinstance(e, str) else e.get('dir')
            if d and (u := clip_use(character, o, d)):
                fid.append(u)
            if len(fid) == MAX_FIDGETS:
                break
        info = index.get(o, {})
        outfits[o] = {'label': info.get('label', o), 'season': info.get('season'), 'actions': actions, 'fidgets': fid}
    return order, outfits


def build_characters():
    chosen = {}     # character -> outfit -> (actions {a: (use, level, thin)}, fidgets [(use, level, thin)])
    report, notes = [], []
    plans = {c: outfit_plan(c) for c in CHARACTERS}
    for c in CHARACTERS:
        order, outfits = plans[c]
        chosen[c] = {}
        for o in order:
            spec = outfits[o]
            fids = list(spec['fidgets'])
            thin = {}   # action -> extra frame thinning (last resort, one-shot clips only)

            def sizes(level, fs):
                vs = [variant(u, level, thin.get(a, 1)) for a, u in spec['actions'].items()]
                vs += [variant(u, level) for u in fs]
                files = {e['file']: len(d) for e, d in vs}
                return len(variant(spec['actions']['idle'], level)[1]), sum(files.values()), files
            level = 0
            while True:
                idle, total, files = sizes(level, fids)
                if idle <= BUDGET_IDLE and total <= BUDGET_OUTFIT:
                    break
                if level + 1 < len(QUALITY_STEPS):
                    level += 1
                elif idle > BUDGET_IDLE:
                    fail(f'{c}/{o} idle is {idle / KB:.0f} KB > {BUDGET_IDLE // KB} KB at the lowest quality step')
                elif fids:
                    notes.append(f'dropped {c}/{o} fidget {fids.pop()[0]} (outfit over {BUDGET_OUTFIT // KB} KB)')
                else:
                    once = [a for a in spec['actions'] if MODES[a] == 'once' and thin.get(a, 1) < MAX_THIN]
                    if not once:
                        fail(f'{c}/{o} is {total / KB:.0f} KB > {BUDGET_OUTFIT // KB} KB with nothing left to cut')
                    big = max(once, key=lambda a: len(variant(spec['actions'][a], level, thin.get(a, 1))[1]))
                    thin[big] = thin.get(big, 1) + 1
            if level:
                notes.append(f'{c}/{o} encoded at quality {QUALITY_STEPS[level][0]} (budget)')
            for a, t in sorted(thin.items()):
                notes.append(f'{c}/{o} {a} keeps 1 frame in {t} (budget)')
            chosen[c][o] = ({a: (u, level, thin.get(a, 1)) for a, u in spec['actions'].items()},
                            [(u, level, 1) for u in fids])
            report.append((f'{c}/{o}', total, idle, len(fids), QUALITY_STEPS[level][0]))

    # Name the clips: "<id>-h200", plus a short hash when one stored clip is used in several ways
    # (another speed or quality step).
    all_uses = sorted({x for ch in chosen.values() for acts, fs in ch.values() for x in list(acts.values()) + fs})
    per_cid = {}
    for (cid, delays), level, thin in all_uses:
        per_cid.setdefault(cid, []).append((delays, level, thin))
    clips, key_of = {}, {}
    for (cid, delays), level, thin in all_uses:
        entry, data = variant((cid, delays), level, thin)
        k = f'{cid}-h{FRAME_H}'
        if len(per_cid[cid]) > 1:
            k += '-' + hashlib.sha256(json.dumps([list(delays), level, thin]).encode()).hexdigest()[:6]
        write(entry['file'], data)
        clips[k] = entry
        key_of[((cid, delays), level, thin)] = k
    characters = {}
    for c in CHARACTERS:
        order, outfits = plans[c]
        out = {}
        for o in order:
            acts, fs = chosen[c][o]
            out[o] = {'label': outfits[o]['label'], 'season': outfits[o]['season'],
                      'actions': {a: key_of[x] for a, x in acts.items()}, 'fidgets': [key_of[x] for x in fs]}
        characters[c] = {'order': order, 'outfits': out}
    return clips, characters, report, notes


# ---------------------------------------------------------------- stickers

def swift_string_list(src, name):
    m = re.search(name + r'\s*=\s*\[(.*?)\]', src, re.S)
    if not m:
        fail(f'StickerPanel.swift: {name} not found')
    return re.findall(r'"([^"]+)"', m.group(1))


def sticker_meta():
    src = open('Sources/LuluCore/StickerPanel.swift', encoding='utf-8').read()
    favorites = swift_string_list(src, 'defaultFavorites')
    cases = re.search(r'enum StickerGroup[^{]*\{\s*case ([^\n]+)', src)
    if not cases:
        fail('StickerPanel.swift: StickerGroup cases not found')
    groups = []
    for g in [s.strip() for s in cases.group(1).split(',')]:
        t = re.search(r'case \.' + g + r': return "([^"]+)"', src)
        if not t:
            fail(f'StickerPanel.swift: no title for group {g}')
        groups.append({'id': g, 'title': t.group(1)})
    return favorites, groups


def gif_frames(path):
    im = Image.open(path)
    frames, durations = [], []
    for i in range(getattr(im, 'n_frames', 1)):
        im.seek(i)
        frames.append(im.convert('RGBA'))
        durations.append(int(im.info.get('duration') or 100))
    return frames, durations


def fit(size, box):
    w, h = size
    s = box / max(w, h)
    return max(1, round(w * s)), max(1, round(h * s))


def build_stickers():
    entries = load_json(f'{STICKERS}/stickers.json')
    favorites, groups = sticker_meta()
    group_ids = {g['id'] for g in groups}
    ids = [e['id'] for e in entries]
    if len(set(ids)) != len(ids):
        fail('Resources/Stickers/stickers.json: duplicate ids')
    for f in favorites:
        if f not in ids:
            fail(f'defaultFavorites names unknown sticker {f}')
    out, thumbs, report, notes = [], [], [], []
    for i, e in enumerate(entries):
        sid = e['id']
        if not re.fullmatch(r'[a-z0-9_]+', sid):
            fail(f'sticker id {sid!r} is not a safe file name')
        if e.get('group') not in group_ids:
            fail(f'sticker {sid}: unknown group {e.get("group")!r}')
        frames, durations = gif_frames(f'{STICKERS}/{e["file"]}')
        size = fit(frames[0].size, STICKER_MAX) if max(frames[0].size) > STICKER_MAX else frames[0].size
        small = [f.resize(size, Image.LANCZOS) for f in frames]
        for q in STICKER_QUALITIES:
            data = webp_bytes(small[0], save_all=True, append_images=small[1:], duration=durations, loop=0,
                              quality=q, alpha_quality=90, method=6)
            if len(data) <= BUDGET_STICKER:
                break
        else:
            fail(f'sticker {sid} is {len(data) / KB:.0f} KB > {BUDGET_STICKER // KB} KB even at quality {q}')
        if q != STICKER_QUALITIES[0]:
            notes.append(f'sticker {sid} encoded at quality {q} (budget)')
        name = f'stickers/{sid}.{sha10(data)}.webp'
        write(name, data)
        thumbs.append(frames[0])
        out.append({'id': sid, 'label': e['label'], 'group': e['group'], 'intimate': bool(e.get('intimate', False)),
                    'file': name, 'w': size[0], 'h': size[1], 'frames': len(frames), 'thumb': i})
        report.append((sid, len(data)))
    rows = math.ceil(len(thumbs) / THUMB_COLS)
    atlas = Image.new('RGBA', (THUMB_COLS * THUMB, rows * THUMB), (0, 0, 0, 0))
    for i, fr in enumerate(thumbs):
        t = fr.resize(fit(fr.size, THUMB), Image.LANCZOS)
        atlas.paste(t, ((i % THUMB_COLS) * THUMB + (THUMB - t.width) // 2,
                        (i // THUMB_COLS) * THUMB + (THUMB - t.height) // 2))
    data = webp_bytes(atlas, quality=80, alpha_quality=90, method=6)
    tname = f'stickers/thumbs.{sha10(data)}.webp'
    write(tname, data)
    thumb_info = {'file': tname, 'size': THUMB, 'cols': THUMB_COLS, 'count': len(thumbs)}
    return out, thumb_info, favorites, groups, report, notes


# ---------------------------------------------------------------- main

def main():
    if not os.path.isdir(CLIPS):
        fail('Resources/Clips missing')
    clips, characters, sprite_report, notes = build_characters()
    stickers, thumbs, favorites, groups, sticker_report, snotes = build_stickers()
    manifest = {
        'version': 1,
        'frameHeight': FRAME_H,
        'modes': MODES,
        'clips': dict(sorted(clips.items())),
        'characters': characters,
        'stickers': stickers,
        'stickerGroups': groups,
        'thumbs': thumbs,
        'defaultFavorites': favorites,
    }
    text = json.dumps(manifest, ensure_ascii=False, indent=1, separators=(',', ': '))
    # Number arrays (delays / seq / src) on one line each: readable diffs, smaller file.
    text = re.sub(r'\[\s*(-?[0-9.]+(?:,\s*-?[0-9.]+)*)\s*\]',
                  lambda m: '[' + ', '.join(x.strip() for x in m.group(1).split(',')) + ']', text)
    mdata = (text + '\n').encode('utf-8')
    write('manifest.json', mdata)

    for path in sorted(glob.glob(f'{OUT}/sprites/*') + glob.glob(f'{OUT}/stickers/*')):
        rel = os.path.relpath(path, OUT)
        if rel not in _written:
            os.remove(path)
            print(f'removed stale {rel}')

    idle_of = {(c, o): _written[clips[of['actions']['idle']]['file']]
               for c, ch in characters.items() for o, of in ch['outfits'].items()}
    worst_mine = max(idle_of.values())
    worst_partner = max(idle_of[(c, characters[c]['order'][0])] for c in CHARACTERS)
    first = worst_mine + worst_partner + len(mdata) + _written[thumbs['file']]
    total = sum(os.path.getsize(p) for p in glob.glob(f'{OUT}/**', recursive=True) if os.path.isfile(p))

    print(f'{"outfit":22} {"KB":>5} {"idle KB":>8} fidgets quality')
    for name, t, idle, nf, q in sprite_report:
        print(f'{name:22} {t / KB:5.0f} {idle / KB:8.0f} {nf:7} {q}')
    sprites_total = sum(v for k, v in _written.items() if k.startswith('sprites/'))
    stickers_total = sum(v for k, v in _written.items() if k.startswith('stickers/'))
    big = max(sticker_report, key=lambda r: r[1])
    print(f'sprites: {sum(1 for k in _written if k.startswith("sprites/"))} sheets, {sprites_total / KB:.0f} KB')
    print(f'stickers: {len(stickers)} + thumbs ({_written[thumbs["file"]] / KB:.0f} KB), {stickers_total / KB:.0f} KB; '
          f'largest {big[0]} {big[1] / KB:.0f} KB')
    print(f'manifest {len(mdata) / KB:.1f} KB; first screen (worst case) {first / KB:.0f} KB; '
          f'web/assets total {total / KB / 1024:.2f} MB')
    for n in notes + snotes:
        print(f'note: {n}')
    if first > BUDGET_FIRST:
        fail(f'first screen {first / KB:.0f} KB > {BUDGET_FIRST // KB} KB')
    if total > BUDGET_TOTAL:
        fail(f'web/assets total {total / KB / 1024:.1f} MB > {BUDGET_TOTAL // KB // 1024} MB')
    print('budgets OK')


if __name__ == '__main__':
    main()
