#!/usr/bin/env python3
"""Web version assets v2 (spec docs/superpowers/specs/2026-10-12-eyedrops-and-web-v2.md §5; v1 was 2026-10-06 §6.2).

Reads only committed inputs (never assets/library, which is private):
  Resources/Sprites/<character>/{order.json, outfits.json, weather.json, _weather/<dir>/meta.json}
  Resources/Sprites/<character>/<outfit>/{<action>/meta.json, fidgets.json, stay.json, clips.json, <dir>/meta.json}
  Resources/Couples/<name>/meta.json                (two-character clips; facing / sound / heightFactor / intimate)
  Resources/Clips/<id>/{meta.json, NNN.webp}        (content-addressed frames, tools/build_sprites.py)
  Resources/reactions.json, Resources/changelog.json (copied into the manifest as they are)
  Resources/Stickers/{stickers.json, <id>.gif}
  Sources/LuluCore/StickerPanel.swift               (defaultFavorites, StickerGroup order + titles)
  Sources/LuluCore/ToolClips.swift                  (named clip pools of the personal tools)
and writes web/assets/:
  manifest.json                                     (format: web/assets/README.md)
  sprites/<clipid>-h240.<sha10>.webp     one sprite sheet per stored clip: distinct frames ("cells"), 240 px tall, 8 columns
  stickers/<id>.<sha10>.webp             animated WebP, longest side 200 px
  stickers/thumbs.<sha10>.webp           every sticker's first frame in a 72 px cell (one request)

File names carry the first 10 hex digits of the file's sha256, so a file never changes under the same
name (cache forever). Output is deterministic (same inputs -> byte-identical files); files under
sprites/ and stickers/ that the new manifest does not reference are deleted.

v2 rules: every frame is kept (full frame rate, no thinning); every fidget, stay, clips.json, weather and
couple clip is exported. A sheet stores each distinct frame once (`seq` lists the cell of every frame).
When a budget is exceeded the offending sheet is re-encoded one quality step lower (QUALITY_STEPS; for an
outfit over budget, its largest sheet first) until everything fits; still over at the lowest step = the
build fails naming the clip / outfit.

Budgets (§5; the build fails when one is exceeded): idle sheet <= 320 KB; outfit (core actions + all
fidgets, distinct sheet files) <= 2.5 MB; weather sheet <= 600 KB; couple sheet and every clip a
reactions.json `visitor` pool names (click / poke included) <= 900 KB; first screen (manifest + largest
idle + largest default-outfit idle + thumbs) <= 1.5 MB; sticker <= 400 KB; web/assets total <= 150 MB.

usage: nice -n 10 python3 tools/build_web_assets.py
"""
import collections, glob, hashlib, io, json, math, os, re, sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
SPRITES, CLIPS, STICKERS = 'Resources/Sprites', 'Resources/Clips', 'Resources/Stickers'
COUPLES = 'Resources/Couples'
OUT = 'web/assets'

CHARACTERS = ('lulu', 'lumei')
FRAME_H = 240
COLS = 8
# (quality, alpha_quality) tried in order per sheet; step 0 is the normal encoding.
QUALITY_STEPS = ((80, 90), (72, 80), (65, 70), (58, 60), (50, 50), (45, 40))
STICKER_MAX = 200
STICKER_QUALITIES = (75, 65, 55)
THUMB = 72
THUMB_COLS = 10
# Actions exported per outfit (missing ones are simply absent; see "modes" in the manifest).
ACTIONS = ('idle', 'happy', 'react', 'sleep', 'quiet', 'run', 'wave')
MODES = {'idle': 'loop', 'sleep': 'loop', 'run': 'loop', 'quiet': 'still',
         'happy': 'once', 'react': 'once', 'wave': 'once', 'fidget': 'once'}
# ToolClips kinds always present in the manifest (eyedrops: spec §2.5; an empty pool = play `happy`).
TOOL_KINDS = ('water', 'stand', 'focus', 'breakTime', 'eyedrops')

KB = 1024
MB = 1024 * KB
BUDGET_IDLE = 320 * KB
BUDGET_CLIP = 900 * KB        # couple sheets and the visitor clips named by reactions.json (incl. click / poke)
BUDGET_WEATHER = 600 * KB
BUDGET_OUTFIT = 2560 * KB
BUDGET_FIRST = 1536 * KB
BUDGET_STICKER = 400 * KB
BUDGET_TOTAL = 150 * MB


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


def safe_dir(d):
    return isinstance(d, str) and d and '/' not in d and d not in ('.', '..')


# ---------------------------------------------------------------- clips

def clip_use(dirpath):
    """A clip use (`<dirpath>/meta.json`): (store id, delays) or None when the directory has no meta."""
    p = f'{dirpath}/meta.json'
    if not os.path.exists(p):
        return None
    m = load_json(p)
    cid = m.get('clip')
    if not cid or not re.fullmatch(r'[0-9a-f]+', cid):
        fail(f'{p}: no usable "clip" id (old frame layout is not supported)')
    n = load_json(f'{CLIPS}/{cid}/meta.json')['frames']
    delays = tuple(round(float(m['delays'][i]) if i < len(m['delays']) else 0.1, 4) for i in range(n))
    return cid, delays


def clip_index(path, base):
    """fidgets.json / stay.json / clips.json / a weather.json look: [(name, use, sound)] (SpriteCatalog.ClipIndex:
    a bare string is a dir that doubles as the name; unsafe dirs and dirs without a clip are skipped)."""
    out = []
    for e in (load_json(path) if isinstance(path, str) and os.path.exists(path) else path or []):
        if isinstance(e, str):
            name, d, sound = e, e, None
        elif isinstance(e, dict):
            d = e.get('dir')
            name, sound = e.get('name') or d, e.get('sound') or None
        else:
            continue
        if safe_dir(d) and (u := clip_use(f'{base}/{d}')):
            out.append((name, u, sound))
    return out


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


_sheets = {}   # (store id, level) -> sheet bytes


def sheet(cid, level):
    """The sprite sheet of stored clip `cid` at quality step `level` (every distinct frame, in first-use order)."""
    if (cid, level) not in _sheets:
        cells, seq, src, w = source_cells(cid)
        cols = min(COLS, len(cells))
        rows = math.ceil(len(cells) / cols)
        im = Image.new('RGBA', (cols * w, rows * FRAME_H), (0, 0, 0, 0))
        for j, c in enumerate(cells):       # cells are numbered in first-use order already
            im.paste(c, ((j % cols) * w, (j // cols) * FRAME_H))
        q, aq = QUALITY_STEPS[level]
        _sheets[(cid, level)] = webp_bytes(im, quality=q, alpha_quality=aq, method=6)
    return _sheets[(cid, level)]


def entry_for(use, level):
    """Manifest clip entry (the v1 fields) for a use at the sheet's quality step."""
    cid, delays = use
    cells, seq, src, w = source_cells(cid)
    data = sheet(cid, level)
    return {'file': f'sprites/{cid}-h{FRAME_H}.{sha10(data)}.webp', 'frames': len(delays), 'cells': len(cells),
            'cols': min(COLS, len(cells)), 'w': w, 'h': FRAME_H, 'src': src, 'delays': list(delays),
            'seq': list(seq)}, data


# ---------------------------------------------------------------- characters, couples

def outfit_plan(character):
    base = f'{SPRITES}/{character}'
    order_file = load_json(f'{base}/order.json')
    index = load_json(f'{base}/outfits.json')
    available = sorted(o for o in os.listdir(base)
                       if not o.startswith('_') and os.path.exists(f'{base}/{o}/idle/meta.json'))
    order = [o for o in order_file if o in available]
    order += [o for o in available if o not in order]
    outfits = {}
    for o in order:
        d = f'{base}/{o}'
        info = index.get(o, {})
        outfits[o] = {
            'label': info.get('label', o), 'season': info.get('season'),
            'actions': {a: u for a in ACTIONS if (u := clip_use(f'{d}/{a}'))},
            'fidgets': clip_index(f'{d}/fidgets.json', d),
            'stay': clip_index(f'{d}/stay.json', d),
            'extras': clip_index(f'{d}/clips.json', d),
        }
    weather = {}
    wpath = f'{base}/weather.json'
    for look, items in (load_json(wpath) if os.path.exists(wpath) else {}).items():
        if isinstance(items, list) and (entries := clip_index(items, f'{base}/_weather')):
            weather[look] = entries
    return order, outfits, weather


def couple_plan():
    out = {}
    for name in sorted(os.listdir(COUPLES)):
        d = f'{COUPLES}/{name}'
        if not (u := clip_use(d)):
            continue
        m = load_json(f'{d}/meta.json')
        out[name] = (u, {'intimate': m.get('intimate') is True, 'sound': m.get('sound') or None,
                         'heightFactor': min(1.5, max(0.3, float(m.get('heightFactor', 1)))),
                         'luluOnLeft': m.get('facing') != 'lulu-right'})
    return out


def build_clips():
    plans = {c: outfit_plan(c) for c in CHARACTERS}
    couples = couple_plan()

    # reactions.json visitor clip names per character (the `click` / `poke` pools included).
    visitor_names = {c: set() for c in CHARACTERS}
    for r in load_json('Resources/reactions.json').values():
        for c, v in ((r.get('visitor') or {}) if isinstance(r, dict) else {}).items():
            if c in visitor_names:
                visitor_names[c] |= set([v] if isinstance(v, str) else v if isinstance(v, list) else [])

    # Constraints: per-sheet caps (strictest use wins) and per-outfit totals.
    cap = {}

    def limit(use, budget):
        cap[use[0]] = min(cap.get(use[0], budget), budget)
    groups = []    # (label, [store ids]) for outfits: core actions + all fidgets
    for c in CHARACTERS:
        order, outfits, weather = plans[c]
        for o in order:
            spec = outfits[o]
            if 'idle' in spec['actions']:
                limit(spec['actions']['idle'], BUDGET_IDLE)
            for lst in ('fidgets', 'stay', 'extras'):
                for name, u, _ in spec[lst]:
                    if name in visitor_names[c]:
                        limit(u, BUDGET_CLIP)
            groups.append((f'{c}/{o}', sorted({u[0] for u in spec['actions'].values()} |
                                              {u[0] for _, u, _ in spec['fidgets']})))
        for entries in weather.values():
            for _, u, _ in entries:
                limit(u, BUDGET_WEATHER)
    for u, _ in couples.values():
        limit(u, BUDGET_CLIP)

    level = collections.defaultdict(int)   # store id -> quality step (0 unless a budget needs less)
    last = len(QUALITY_STEPS) - 1
    changed = True
    while changed:
        changed = False
        for cid in sorted(cap):
            while len(sheet(cid, level[cid])) > cap[cid]:
                if level[cid] == last:
                    fail(f'clip {cid} is {len(sheet(cid, last)) / KB:.0f} KB > {cap[cid] // KB} KB '
                         f'at the lowest quality step')
                level[cid] += 1
                changed = True
        for label, cids in groups:
            while (total := sum(len(sheet(x, level[x])) for x in cids)) > BUDGET_OUTFIT:
                bumpable = [x for x in cids if level[x] < last]
                if not bumpable:
                    fail(f'{label} is {total / KB:.0f} KB > {BUDGET_OUTFIT // KB} KB at the lowest quality step')
                big = max(bumpable, key=lambda x: (len(sheet(x, level[x])), x))
                level[big] += 1
                changed = True

    # Clip keys: "<id>-h240", plus a short hash of the delays when one stored clip is used at several speeds.
    uses = set()
    for c in CHARACTERS:
        order, outfits, weather = plans[c]
        for spec in outfits.values():
            uses |= set(spec['actions'].values())
            for lst in ('fidgets', 'stay', 'extras'):
                uses |= {u for _, u, _ in spec[lst]}
        for entries in weather.values():
            uses |= {u for _, u, _ in entries}
    uses |= {u for u, _ in couples.values()}
    variants = {}
    for cid, delays in uses:
        variants.setdefault(cid, set()).add(delays)
    clips, key_of = {}, {}
    for use in sorted(uses):
        cid, delays = use
        entry, data = entry_for(use, level[cid])
        k = f'{cid}-h{FRAME_H}'
        if len(variants[cid]) > 1:
            k += '-' + hashlib.sha256(json.dumps(list(delays)).encode()).hexdigest()[:6]
        write(entry['file'], data)
        clips[k] = entry
        key_of[use] = k

    characters, notes = {}, []
    for c in CHARACTERS:
        order, outfits, weather = plans[c]
        out = {}
        for o in order:
            spec = outfits[o]
            named, sounds = {}, {}
            for lst in ('fidgets', 'stay', 'extras'):         # PetWindow: fidgets + stays + extras, first wins
                for name, u, sound in spec[lst]:
                    if name not in named:
                        named[name] = key_of[u]
                        if sound:
                            sounds[name] = sound
            out[o] = {'label': spec['label'], 'season': spec['season'],
                      'actions': {a: key_of[u] for a, u in spec['actions'].items()},
                      'fidgets': [key_of[u] for _, u, _ in spec['fidgets']],
                      'fidgetNames': [n for n, _, _ in spec['fidgets']],
                      'stay': [n for n, _, _ in spec['stay']],
                      'extras': [n for n, _, _ in spec['extras']],
                      'named': named, 'clipSounds': sounds}
        wout = {look: [dict({'name': n, 'clip': key_of[u]}, **({'sound': s} if s else {})) for n, u, s in entries]
                for look, entries in weather.items()}
        characters[c] = {'order': order, 'outfits': out, 'weather': wout}
    couples_out = {name: dict({'clip': key_of[u]}, **extra) for name, (u, extra) in couples.items()}
    for cid, lv in sorted(level.items()):
        if lv:
            notes.append(f'clip {cid} encoded at quality {QUALITY_STEPS[lv][0]} (budget)')
    return clips, characters, couples_out, groups, level, notes


# ---------------------------------------------------------------- tool clips

def tool_clips():
    """ToolClips.pool(kind, for: character) from Sources/LuluCore/ToolClips.swift: {kind: {character: [names]}}.
    `case (.kind, .lulu)`, `case (.kind, _)` and `case (.kind, .lulu), (.kind, .lumei)` are understood; a kind
    without a case (eyedrops before the Mac adds it) is an empty pool for both characters."""
    src = open('Sources/LuluCore/ToolClips.swift', encoding='utf-8').read()
    out = {k: {c: [] for c in CHARACTERS} for k in TOOL_KINDS}
    for m in re.finditer(r'case\s+((?:\(\s*\.\w+\s*,\s*(?:\.\w+|_)\s*\)\s*,?\s*)+):\s*return\s*\[(.*?)\]', src, re.S):
        names = re.findall(r'"([^"]+)"', m.group(2))
        for kind, who in re.findall(r'\(\s*\.(\w+)\s*,\s*(\.\w+|_)\s*\)', m.group(1)):
            for c in (CHARACTERS if who == '_' else (who[1:],)):
                if c in CHARACTERS:
                    out.setdefault(kind, {x: [] for x in CHARACTERS})[c] = names
    return out


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
    clips, characters, couples, groups, level, notes = build_clips()
    stickers, thumbs, favorites, groups_st, sticker_report, snotes = build_stickers()
    tools = tool_clips()
    reactions = load_json('Resources/reactions.json')
    changelog = load_json('Resources/changelog.json') if os.path.exists('Resources/changelog.json') else []

    # Cross-checks (notes only: the Mac skips what an outfit lacks the same way).
    for c, ch in characters.items():
        names = {n for of in ch['outfits'].values() for n in of['named']}
        for kind, pools in tools.items():
            for n in pools.get(c, []):
                if n not in names:
                    notes.append(f'toolClips {kind}/{c}: no outfit has clip {n}')
    for key, r in reactions.items():
        pool = r.get('couple') if isinstance(r, dict) else None
        for n in ([pool] if isinstance(pool, str) else pool or []):
            if n != 'none' and n not in couples:
                notes.append(f'reactions {key}: unknown couple {n}')

    assets_total = sum(_written.values())   # every referenced file (manifest itself excluded)
    manifest = {
        'version': 2,
        'frameHeight': FRAME_H,
        'modes': MODES,
        'clips': dict(sorted(clips.items())),
        'characters': characters,
        'couples': couples,
        'reactions': reactions,
        'toolClips': tools,
        'sounds': {},   # the web plays no character voice files (office use); W5 synthesizes UI tones
        'stickers': stickers,
        'stickerGroups': groups_st,
        'thumbs': thumbs,
        'defaultFavorites': favorites,
        'changelog': changelog,
        'totalBytes': assets_total,
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

    size = lambda k: _written[clips[k]['file']]
    idle_of = {(c, o): size(of['actions']['idle']) for c, ch in characters.items() for o, of in ch['outfits'].items()}
    worst_mine = max(idle_of.values())
    worst_partner = max(idle_of[(c, characters[c]['order'][0])] for c in CHARACTERS)
    first = worst_mine + worst_partner + len(mdata) + _written[thumbs['file']]
    total = sum(os.path.getsize(p) for p in glob.glob(f'{OUT}/**', recursive=True)
                if os.path.isfile(p) and not p.endswith('README.md'))

    def files_of(keys):
        return {clips[k]['file'] for k in keys}

    def kb(files):
        return sum(_written[f] for f in files) / KB

    print(f'{"outfit":22} {"core KB":>8} {"idle KB":>8} {"fidgets":>7} {"stay+extras KB":>15}')
    for c, ch in characters.items():
        for o in ch['order']:
            of = ch['outfits'][o]
            core = files_of(list(of['actions'].values()) + of['fidgets'])
            rest = files_of(of['named'].values()) - core
            print(f'{c + "/" + o:22} {kb(core):8.0f} {idle_of[(c, o)] / KB:8.0f} {len(of["fidgets"]):7} {kb(rest):15.0f}')
    cats = {
        'outfit core (actions + fidgets)': files_of(k for ch in characters.values() for of in ch['outfits'].values()
                                                    for k in list(of['actions'].values()) + of['fidgets']),
        'stay + clips.json (named, not core)': files_of(k for ch in characters.values() for of in ch['outfits'].values()
                                                        for k in of['named'].values()),
        'weather': files_of(e['clip'] for ch in characters.values() for es in ch['weather'].values() for e in es),
        'couples': files_of(x['clip'] for x in couples.values()),
    }
    cats['stay + clips.json (named, not core)'] -= cats['outfit core (actions + fidgets)']
    cats['stickers + thumbs'] = {k for k in _written if k.startswith('stickers/')}
    for name, fs in cats.items():
        print(f'{name:38} {len(fs):4} files {kb(fs) / 1024:7.2f} MB')
    big = max(sticker_report, key=lambda r: r[1])
    print(f'sprites: {sum(1 for k in _written if k.startswith("sprites/"))} sheets; largest sticker {big[0]} '
          f'{big[1] / KB:.0f} KB; sheets below quality {QUALITY_STEPS[0][0]}: {sum(1 for v in level.values() if v)}')
    print(f'manifest {len(mdata) / KB:.1f} KB; first screen (worst case) {first / KB:.0f} KB; '
          f'web/assets total {total / MB:.2f} MB')
    for n in notes + snotes:
        print(f'note: {n}')
    if first > BUDGET_FIRST:
        fail(f'first screen {first / KB:.0f} KB > {BUDGET_FIRST // KB} KB')
    if total > BUDGET_TOTAL:
        fail(f'web/assets total {total / MB:.1f} MB > {BUDGET_TOTAL // MB} MB')
    print('budgets OK')


if __name__ == '__main__':
    main()
