"""Build app resources from source GIFs.

  Frames live once each in a content-addressed store, Resources/Clips/<id>/{000.webp..., meta.json
  {"frames", "width", "height", "ext"}} (id = hash of the encoded frames, so a clip used by several
  outfits / characters / couples is stored once). Every use below is a directory holding only
  meta.json = {"clip": <id>, "frames", "delays", "width", "height"[, "facing"]}; delays (speed) are
  per use, so e.g. the same GIF at two speeds still shares its frames.

  assets/sprites.json  -> Resources/Sprites/<character>/<outfit>/<action>/meta.json
                          (v0.12: an optional top-level "weather": {rain|snow|hot|cold|windy: [clip specs]} per character ->
                          Resources/Sprites/<character>/weather.json + _weather/<look>_<i>/; empty / missing = nothing written)
                          Resources/Sprites/<character>/order.json (outfit names in manifest order =
                          preference order; the first one is shown at launch)
                          Actions: idle / react / happy (required), run / wave (optional, v0.2 visits;
                          the app falls back to idle + bob / happy). `run` must face right; give
                          {"gif": ..., "facing": "left"} for a left-facing source and it is flipped here.
                          v0.3 optional: `sleep` (action, looped while the pet dozes), and the clip
                          lists `fidgets` (random one-shots while idle) and `stay` (the visitor's pose
                          beside the host): arrays of the same specs (name or {"gif", "speed", "name", "frames"}),
                          built to <outfit>/fidget_<i>/ and <outfit>/stay_<i>/ with an index
                          <outfit>/fidgets.json / stay.json = [{"name": <spec name or gif>, "dir": ...}].
                          v0.5 per-outfit settings: "label" (中文名), "season" ("springFestival" = only
                          from 15 days before to 15 days after 春节, "christmas" = only in December; the
                          app gives an in-season outfit priority) and "reactionClips": true (the outfit
                          gets all reactions.json visitor clips; other outfits only those made of their
                          own GIFs) -> Resources/Sprites/<character>/outfits.json
                          {"<outfit>": {"season": ..., "label": ...}}. Fidgets / stay may be empty lists.
                          `doze`: {"gif": ..., "frame": N, "period": 3.2, "depth": 0.02} synthesises the
                          `sleep` clip from one (eyes-closed) frame with a slow breathing scale, when no
                          real `sleep` clip is given.
                          v0.8 `quiet`: {"gif": ..., "frame": N} one still frame (calm, eyes open, facing
                          front) held in quiet mode / 勿扰 -> <outfit>/quiet/ (a 1-frame clip, sized like
                          the whole source clip). Review sheet: design/v08/quiet_frames.png.
                          Size: every sprite clip is scaled so the character's body height (median
                          over frames of the opaque bbox height) matches the first outfit's idle, so
                          fidgets / stay / doze show the character at idle's size. Any spec (and
                          `doze`) may add "scale": 1.05 as a manual fix on top
                          (check with python3 tools/scale_check.py).
  assets/couples.json  -> Resources/Couples/<name>/meta.json   (hug / kiss / nuzzle; canvas fitted in MAX_H)
                          {"hug": {"gif": "couple_hug_01", "speed": 0.7, "facing": "lulu-left"}, ...}
                          Any spec may add "frames": [first, last] (inclusive) to cut jump cuts.
                          v0.11: "intimate": true = a kiss / hug / cuddle, hidden in friend mode (written into meta.json)
                          v0.9: "sound": "<sounds.json key>" binds a sound to the clip (played with it
                          instead of the category sound, SoundEvent.forCouple); "heightFactor": 0.7
                          draws a half-body clip smaller (fraction of the pet's height, default 1).
                          "facing" (where 噜噜 stands in the clip) is copied into meta.json; the app
                          mirrors the clip at render time to match the pets' actual sides.
  assets/stickers.json -> Resources/Stickers/{<id>.gif, stickers.json}
  assets/reactions.json (optional, v0.3) -> Resources/reactions.json
                          {"<stickerId, kind or *>": {"couple": "<couples.json key or none>" | [<pool>],
                                                   "visitor": "<action or clip name>" | [<pool>] |
                                                              {"lulu": <name, clip spec, list of them, or null>, "lumei": ...}}}
                          A list is a pool the app picks from at random (no immediate repeat); "*" is
                          the default entry for messages without their own value.
                          Visitor clip specs are built into every outfit of that character as
                          <outfit>/clip_<i>/ (index clips.json) unless the outfit already has that GIF
                          in fidgets / stay; the resource file refers to clips by name.
                          v0.5: an entry may add "sound": "<sounds.json key>" | [<pool>] = the sound
                          played at the meeting instead of the couple clip's (copied as is).
                          v0.9: a visitor clip spec may add "sound": "<sounds.json key>" (played as the
                          clip starts; written into the outfit's clips.json / fidgets.json entry), and an
                          entry named "click" (visitor per character) lists funny clips a single click on
                          the pet sometimes plays instead of `react` (ReactionTable.clickClips).
  assets/changelog.json (v0.13) -> Resources/changelog.json  (the 更新日志 window)
  assets/sounds.json (v0.5) -> Resources/Sounds/  (tools/build_sounds.py, run at the end; see there)

Source GIFs (sprites, couples and stickers) are looked up in assets/gifs/ then assets/library/.
Cutouts are cached in build/cut/<gif>/ (made by tools/cutout, compiled on demand).
usage: python3 tools/build_sprites.py
"""
import glob, hashlib, json, math, os, shutil, statistics, subprocess
from PIL import Image

MAX_H = 480   # v0.7: cap only; every sprite / couple clip is now built at its source's native height (≤ 400 px)
# v0.9: couple clips are drawn at the pet's display height whatever their size, so their cap is higher
# (a petScale 1.6 pet is 544 px tall on a 2x screen); sprites keep MAX_H (their size comes from the idle body).
COUPLE_MAX_H = 720
STICKER_W = 240
# Frames are lossy WebP (RGB quality 85, lossless alpha so edges keep no halo); ImageIO/NSImage
# decode it natively on macOS 11+. Bump FORMAT when the encoding changes (it is part of the clip id).
WEBP = dict(quality=85, method=5, alpha_quality=100)   # method 6: ~1% smaller, 100x slower
FORMAT = 'webp-q85'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
CLIPS = 'Resources/Clips'


def source_gif(gif):
    src = next((p for p in (f'assets/gifs/{gif}.gif', f'assets/library/{gif}.gif') if os.path.exists(p)), None)
    if src is None:
        raise SystemExit(f'error: {gif}.gif not found in assets/gifs/ or assets/library/')
    return src


def ensure_cutout(gif):
    out = f'build/cut/{gif}'
    if not os.path.exists(f'{out}/meta.json'):
        src = source_gif(gif)
        if not os.path.exists('tools/cutout'):
            subprocess.run(['swiftc', '-O', 'tools/cutout.swift', '-o', 'tools/cutout'], check=True)
        subprocess.run(['tools/cutout', src, out], check=True)
    apply_cutout_fix(gif, out)
    return out


# v0.9 optional per-GIF cutout clean-up: assets/cutout_fixes.json = {"<gif>": {"keep": "largest" | <fraction>, "open": <px radius, optional>}}.
# Drops the mask's small leftovers (props, sticks, cushion crumbs): keeps only the connected alpha components
# whose area is at least that fraction of the biggest one ("largest" = only the biggest), then re-crops all
# frames to their shared bounding box. Applied once per cache (recorded in meta.json "fix").
_fixes = json.load(open('assets/cutout_fixes.json')) if os.path.exists('assets/cutout_fixes.json') else {}


def apply_cutout_fix(gif, out):
    fix = _fixes.get(gif)
    meta = json.load(open(f'{out}/meta.json'))
    key = json.dumps(fix, sort_keys=True) if fix else None
    if key is None or meta.get('fix') == key:
        return
    import numpy as np
    from scipy import ndimage
    keep = fix.get('keep', 'largest')
    frac = 1.0 if keep == 'largest' else float(keep)
    paths = sorted(glob.glob(f'{out}/*.png'))
    imgs = []
    for p in paths:
        a = np.array(Image.open(p).convert('RGBA'))
        lab, n = ndimage.label(a[..., 3] > 40, structure=np.ones((3, 3)))
        if n and fix.get('open'):   # morphological opening removes thin sticks / strings (radius in px)
            r = int(fix['open'])
            yy, xx = np.ogrid[-r:r + 1, -r:r + 1]
            opened = ndimage.binary_opening(a[..., 3] > 40, structure=(xx * xx + yy * yy) <= r * r)
            a[..., 3] = np.where(ndimage.binary_dilation(opened, iterations=1), a[..., 3], 0)
            lab, n = ndimage.label(a[..., 3] > 40, structure=np.ones((3, 3)))
        if n:
            areas = ndimage.sum(np.ones_like(lab), lab, range(1, n + 1))
            big = max(areas)
            ok = [i + 1 for i, ar in enumerate(areas) if ar >= big * frac - 0.5]
            a[~np.isin(lab, ok)] = 0
        imgs.append(a)
    boxes = [Image.fromarray(a[..., 3]).point(lambda v: 255 if v > 40 else 0).getbbox() for a in imgs]
    boxes = [b for b in boxes if b]
    x0, y0 = max(0, min(b[0] for b in boxes) - 4), max(0, min(b[1] for b in boxes) - 4)
    x1 = min(imgs[0].shape[1], max(b[2] for b in boxes) + 4)
    y1 = min(imgs[0].shape[0], max(b[3] for b in boxes) + 4)
    for p, a in zip(paths, imgs):
        Image.fromarray(a[y0:y1, x0:x1]).save(p)
    meta.update(width=x1 - x0, height=y1 - y0, fix=key)
    json.dump(meta, open(f'{out}/meta.json', 'w'))
    print(f'cutout fix {gif}: {key} -> {x1 - x0}x{y1 - y0}')


def parse_spec(spec):
    """A GIF name, or {"gif": name, "speed": 0.5, "facing": ...} (speed 1.0 = original)."""
    if isinstance(spec, str):
        return spec, 1.0, None
    return spec['gif'], spec.get('speed', 1.0), spec.get('facing')


def frame_range(spec):
    """Optional {"frames": [first, last]} (inclusive, 0-based; last may be omitted) to drop jump cuts."""
    r = spec.get('frames') if isinstance(spec, dict) else None
    return (r[0], r[1] if len(r) > 1 else None) if r else None


def spec_scale(spec):
    """Optional manual size fix {"scale": 1.05} on top of the automatic body-height match."""
    return float(spec.get('scale', 1.0)) if isinstance(spec, dict) else 1.0


# Per-outfit clip lists (v0.3): manifest key -> directory prefix.
CLIP_LISTS = {'fidgets': 'fidget', 'stay': 'stay', 'clips': 'clip'}
# v0.5 per-outfit settings (not clips): "label" (display name), "season" (see SEASONS) and
# "reactionClips" (true = this outfit gets every reactions.json visitor clip of its character).
OUTFIT_META = ('label', 'season', 'reactionClips')
# LuluCore OutfitSeason raw values: springFestival = 春节 ±15 days, christmas = December.
SEASONS = ('springFestival', 'christmas')


def load_frames(src, frames_range=None):
    meta = json.load(open(f'{src}/meta.json'))
    frames = [Image.open(f).convert('RGBA') for f in sorted(glob.glob(f'{src}/*.png'))]
    delays = meta['delays'][:len(frames)]
    if frames_range:
        first, last = frames_range
        last = len(frames) - 1 if last is None else last
        assert 0 <= first <= last < len(frames), f'{src}: frames {frames_range} out of range (0..{len(frames) - 1})'
        frames, delays = frames[first:last + 1], delays[first:last + 1]
    return frames, delays


def body_height(frames):
    """How tall the character stands in these frames: the median over frames of the opaque bounding
    box height. The median ignores the odd jump / raised-arm frame, unlike the canvas (union) height."""
    hs = []
    for f in frames:
        box = f.getchannel('A').point(lambda v: 255 if v > 100 else 0).getbbox()
        if box:
            hs.append(box[3] - box[1])
    return statistics.median(hs) if hs else max(f.height for f in frames)


# ---- content-addressed clip store: Resources/Clips/<id>/{000.webp..., meta.json} ----
_built = {}        # render key -> clip id (skip re-rendering identical specs within a run)
store_stats = {'refs': 0, 'clips': 0}


def store_clip(key, render):
    """Returns the id of the clip whose frames `render()` makes. The id is a hash of the encoded
    frames, so identical frames used by several outfits / characters / couples are stored once."""
    store_stats['refs'] += 1
    if key in _built:
        return _built[key]
    tmp = f'{CLIPS}/.tmp'
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    images = render()
    W, H = images[0].size
    h = hashlib.sha256(f'{FORMAT} {W}x{H} {len(images)}'.encode())
    for i, im in enumerate(images):
        path = f'{tmp}/{i:03d}.webp'
        im.save(path, 'WEBP', **WEBP)
        h.update(open(path, 'rb').read())
    cid = h.hexdigest()[:16]
    json.dump({'frames': len(images), 'width': W, 'height': H, 'ext': 'webp'}, open(f'{tmp}/meta.json', 'w'))
    if os.path.exists(f'{CLIPS}/{cid}'):
        shutil.rmtree(tmp)
    else:
        os.rename(tmp, f'{CLIPS}/{cid}')
        store_stats['clips'] += 1
    _built[key] = cid
    return cid


def write_ref(dst, cid, delays, extra=None):
    """A use of a stored clip: `<dst>/meta.json` = {"clip": id, "frames", "delays", "width", "height", ...}."""
    smeta = json.load(open(f'{CLIPS}/{cid}/meta.json'))
    os.makedirs(dst, exist_ok=True)
    out = {'clip': cid, 'frames': smeta['frames'], 'delays': delays, 'width': smeta['width'], 'height': smeta['height']}
    out.update(extra or {})
    json.dump(out, open(f'{dst}/meta.json', 'w'))


def build_clip(src, dst, speed=1.0, flip=False, extra=None, frames_range=None, body=None, scale=1.0, max_h=MAX_H):
    """`body`: target body height in output pixels (sprites: the character's size, see body_height);
    None = fit the canvas into MAX_H (couples, which the app sizes on their own). `scale` multiplies."""
    frames, delays = load_frames(src, frames_range)
    w, h = max(f.width for f in frames), max(f.height for f in frames)
    s = (body / body_height(frames) if body else min(1.0, max_h / h)) * scale
    W, H = round(w * s), round(h * s)

    def render():
        out = []
        for f in frames:
            canvas = Image.new('RGBA', (w, h), (0, 0, 0, 0))
            canvas.alpha_composite(f, ((w - f.width) // 2, h - f.height))   # bottom-aligned
            if flip:
                canvas = canvas.transpose(Image.FLIP_LEFT_RIGHT)
            out.append(canvas.resize((W, H), Image.LANCZOS))
        return out

    cid = store_clip(('clip', src, frames_range, flip, W, H), render)
    write_ref(dst, cid, [round(d / speed, 4) for d in delays], extra)
    return cid


def build_breath(src, dst, frame, period=3.2, depth=0.02, n=32, body=None, scale=1.0):
    """A looping "doze" clip from one frame: slow breathing (a little shorter and wider on each breath).
    Sized like the whole source clip (not the one frame, which may be crouched or mid-jump)."""
    frames, _ = load_frames(src)
    assert 0 <= frame < len(frames), f'{src}: frame {frame} out of range (0..{len(frames) - 1})'
    f = frames[frame]
    w, h = f.width, f.height
    cw = round(w * (1 + depth))                   # room for the widening
    s = (body / body_height(frames) if body else min(1.0, MAX_H / h)) * scale
    W, H = round(cw * s), round(h * s)

    def render():
        out = []
        for i in range(n):
            b = (1 - math.cos(2 * math.pi * i / n)) / 2   # 0 → 1 → 0
            fw, fh = round(w * (1 + depth * 0.5 * b)), round(h * (1 - depth * b))
            canvas = Image.new('RGBA', (cw, h), (0, 0, 0, 0))
            canvas.alpha_composite(f.resize((fw, fh), Image.LANCZOS), ((cw - fw) // 2, h - fh))
            out.append(canvas.resize((W, H), Image.LANCZOS))
        return out

    cid = store_clip(('breath', src, frame, period, depth, n, W, H), render)
    write_ref(dst, cid, [round(period / n, 4)] * n)


def build_still(src, dst, frame, body=None, scale=1.0):
    """v0.8 quiet pose: one frame of `src` as a 1-frame clip, sized like the whole source clip."""
    frames, _ = load_frames(src)
    assert 0 <= frame < len(frames), f'{src}: frame {frame} out of range (0..{len(frames) - 1})'
    w, h = max(f.width for f in frames), max(f.height for f in frames)
    s = (body / body_height(frames) if body else min(1.0, MAX_H / h)) * scale
    W, H = round(w * s), round(h * s)
    f = frames[frame]

    def render():
        canvas = Image.new('RGBA', (w, h), (0, 0, 0, 0))
        canvas.alpha_composite(f, ((w - f.width) // 2, h - f.height))   # bottom-aligned like build_clip
        return [canvas.resize((W, H), Image.LANCZOS)]

    cid = store_clip(('still', src, frame, W, H), render)
    write_ref(dst, cid, [1.0])
    return cid


def build_sticker(gif, dst):
    im = Image.open(source_gif(gif))
    frames, durations = [], []
    for i in range(im.n_frames):
        im.seek(i)
        f = im.convert('RGB')
        s = min(1.0, STICKER_W / f.width)
        frames.append(f.resize((round(f.width * s), round(f.height * s)), Image.LANCZOS))
        durations.append(im.info.get('duration', 100) or 100)
    frames[0].save(dst, save_all=True, append_images=frames[1:], duration=durations, loop=0, optimize=True)


# v0.3 reactions: visitor clip specs become named `clips` of every outfit of that character.
reactions = json.load(open('assets/reactions.json')) if os.path.exists('assets/reactions.json') else {}
assert isinstance(reactions, dict), 'reactions.json must be an object {"<stickerId or kind>": {...}}'
reaction_clips = {}   # character -> [spec]
compiled_reactions = {}


def reaction_names(v, character=None):
    """One name / clip spec, or a list of them (v0.3.1 pools) -> list of names; clip specs are
    collected into reaction_clips[character] (character None = a plain name, no spec allowed)."""
    out = []
    for spec in (v if isinstance(v, list) else [v]):
        if not spec:
            continue
        if isinstance(spec, dict):
            assert character, 'visitor clip specs must be given per character'
            reaction_clips.setdefault(character, [])
            if all(parse_spec(x)[0] != spec['gif'] for x in reaction_clips[character]):
                reaction_clips[character].append(spec)
            spec = spec.get('name', spec['gif'])
        assert isinstance(spec, str), f'bad reaction name {spec!r}'
        if spec not in out:
            out.append(spec)
    return out


for key, r in reactions.items():
    assert isinstance(r, dict) and set(r) <= {'couple', 'visitor', 'sound', 'note'}, f'reaction {key}: only "couple" / "visitor" / "sound" (/ "note")'
    out = {}
    couple = reaction_names(r.get('couple'))
    if couple:
        out['couple'] = couple[0] if len(couple) == 1 else couple
    v = r.get('visitor')
    if isinstance(v, (str, list)):
        names = reaction_names(v)
        if names:
            out['visitor'] = names[0] if len(names) == 1 else names
    elif isinstance(v, dict):
        per = {}
        for character, spec in v.items():
            names = reaction_names(spec, character)
            if names:
                per[character] = names[0] if len(names) == 1 else names
        if per:
            out['visitor'] = per
    sound = reaction_names(r.get('sound'))
    if sound:
        out['sound'] = sound[0] if len(sound) == 1 else sound
    if out:
        compiled_reactions[key] = out

shutil.rmtree('Resources/Sprites', ignore_errors=True)
shutil.rmtree(CLIPS, ignore_errors=True)
os.makedirs(CLIPS)
WEATHER_LOOKS = ('rain', 'snow', 'hot', 'cold', 'windy', 'cloudy')
for character, outfits in json.load(open('assets/sprites.json')).items():
    # v0.12: an optional per-character "weather": {look: [clip specs]} block sits next to the outfits (it is not one).
    weather_specs = outfits.pop('weather', None) or {}
    assert isinstance(weather_specs, dict) and set(weather_specs) <= set(WEATHER_LOOKS), \
        f'{character}: "weather" must be an object keyed by {WEATHER_LOOKS}'
    # One body height per character, so every clip of every outfit shows the character at the same
    # size: the first outfit's idle keeps its v0.2 size (canvas fitted into MAX_H) and sets it.
    first_idle = next(iter(outfits.values()))['idle']
    idle_frames, _ = load_frames(ensure_cutout(parse_spec(first_idle)[0]), frame_range(first_idle))
    body = min(1.0, MAX_H / max(f.height for f in idle_frames)) * body_height(idle_frames)
    print(f'body {character}: {body:.1f} px')
    meta = {}
    for outfit, actions in outfits.items():
        actions = dict(actions)
        info = {k: actions.pop(k) for k in OUTFIT_META if k in actions}
        assert info.get('season') in (None,) + SEASONS, f'{character}/{outfit}: unknown season {info.get("season")!r} (one of {SEASONS})'
        if 'season' in info or 'label' in info:
            meta[outfit] = {k: info[k] for k in ('season', 'label') if k in info}
        have = {parse_spec(x)[0] for k in CLIP_LISTS if k != 'clips' for x in actions.get(k) or []}
        # Reaction clips are the default costume's: only outfits with "reactionClips": true get them
        # all; any other outfit only those made of its own GIFs (never another costume's clips).
        own = {parse_spec(x)[0] for v in actions.values() for x in (v if isinstance(v, list) else [v])}
        # "reactionClips": true, or {"exclude": [gif, ...]} to keep other costumes' clips out of this outfit
        rc = info.get('reactionClips')
        rc_exclude = set(rc.get('exclude', [])) if isinstance(rc, dict) else set()
        actions['clips'] = list(actions.get('clips') or []) + [
            x for x in reaction_clips.get(character, [])
            if x['gif'] not in have and (x['gif'] in own or (rc and x['gif'] not in rc_exclude))]
        if 'doze' in actions and 'sleep' not in actions:
            d = actions['doze']
            build_breath(ensure_cutout(d['gif']), f'Resources/Sprites/{character}/{outfit}/sleep', d.get('frame', 0),
                         d.get('period', 3.2), d.get('depth', 0.02), body=body, scale=spec_scale(d))
            print(f'sprite {character}/{outfit}/sleep <- {d["gif"]} frame {d.get("frame", 0)} (breathing doze)')
        if 'quiet' in actions:
            q = actions['quiet']
            cid = build_still(ensure_cutout(q['gif']), f'Resources/Sprites/{character}/{outfit}/quiet', q.get('frame', 0),
                              body=body, scale=spec_scale(q))
            print(f'sprite {character}/{outfit}/quiet <- {q["gif"]} frame {q.get("frame", 0)} (still) [{cid}]')
        for action, spec in actions.items():
            if action in CLIP_LISTS or action in ('doze', 'quiet'):
                continue
            gif, speed, facing = parse_spec(spec)
            flip = action == 'run' and facing == 'left'   # the app expects run clips to face right
            cid = build_clip(ensure_cutout(gif), f'Resources/Sprites/{character}/{outfit}/{action}', speed, flip,
                             frames_range=frame_range(spec), body=body, scale=spec_scale(spec))
            print(f'sprite {character}/{outfit}/{action} <- {gif} x{speed}{" (flipped)" if flip else ""} [{cid}]')
        for key, prefix in CLIP_LISTS.items():
            specs = actions.get(key) or []
            assert isinstance(specs, list), f'{character}/{outfit}: "{key}" must be a list of clip specs'
            index = []
            for i, spec in enumerate(specs):
                gif, speed, _ = parse_spec(spec)
                name = spec.get('name', gif) if isinstance(spec, dict) else gif
                cid = build_clip(ensure_cutout(gif), f'Resources/Sprites/{character}/{outfit}/{prefix}_{i}', speed,
                                 frames_range=frame_range(spec), body=body, scale=spec_scale(spec))
                entry = {'name': name, 'dir': f'{prefix}_{i}'}
                if isinstance(spec, dict) and spec.get('sound'):   # v0.9 clip-bound sound (sounds.json key)
                    entry['sound'] = spec['sound']
                index.append(entry)
                print(f'sprite {character}/{outfit}/{prefix}_{i} ({name}) <- {gif} x{speed} [{cid}]')
            if index:
                json.dump(index, open(f'Resources/Sprites/{character}/{outfit}/{key}.json', 'w'), ensure_ascii=False)
    # Weather clips (v0.12): Resources/Sprites/<character>/_weather/<look>_<i>/ + weather.json
    # {"rain": [{"name", "dir", "sound"?}], ...}. Empty / missing lists write nothing (no weather.json).
    weather_index = {}
    for look, specs in weather_specs.items():
        assert isinstance(specs, list), f'{character}/weather/{look} must be a list of clip specs'
        entries = []
        for i, spec in enumerate(specs):
            gif, speed, _ = parse_spec(spec)
            name = spec.get('name', gif) if isinstance(spec, dict) else gif
            d = f'{look}_{i}'
            cid = build_clip(ensure_cutout(gif), f'Resources/Sprites/{character}/_weather/{d}', speed,
                             frames_range=frame_range(spec), body=body, scale=spec_scale(spec))
            entry = {'name': name, 'dir': d}
            if isinstance(spec, dict) and spec.get('sound'):
                entry['sound'] = spec['sound']
            entries.append(entry)
            print(f'weather {character}/{look}/{d} ({name}) <- {gif} x{speed} [{cid}]')
        if entries:
            weather_index[look] = entries
    if weather_index:
        json.dump(weather_index, open(f'Resources/Sprites/{character}/weather.json', 'w'), ensure_ascii=False)
    json.dump(list(outfits), open(f'Resources/Sprites/{character}/order.json', 'w'))
    json.dump(meta, open(f'Resources/Sprites/{character}/outfits.json', 'w'), ensure_ascii=False, indent=1)
    print(f'order {character}: {list(outfits)}')

sound_keys = set(json.load(open('assets/sounds.json'))) if os.path.exists('assets/sounds.json') else set()
shutil.rmtree('Resources/Couples', ignore_errors=True)
os.makedirs('Resources/Couples')
couples = json.load(open('assets/couples.json')) if os.path.exists('assets/couples.json') else {}
for name, spec in couples.items():
    gif, speed, facing = parse_spec(spec)
    facing = facing or 'lulu-left'
    assert facing in ('lulu-left', 'lulu-right'), f'couple {name}: facing must be lulu-left or lulu-right'
    extra = {'facing': facing}
    sound = spec.get('sound') if isinstance(spec, dict) else None
    if sound:   # v0.9 clip-bound sound: a sounds.json key played with this clip instead of the category sound
        assert isinstance(sound, str), f'couple {name}: "sound" must be a sounds.json key'
        extra['sound'] = sound
        if sound not in sound_keys:
            print(f'warning: couple {name}: sound "{sound}" is not in sounds.json (the category sound plays instead)')
    hf = spec.get('heightFactor') if isinstance(spec, dict) else None
    if hf is not None:   # v0.9: drawn at this fraction of the pet's height (half-body clips); default 1
        assert 0.3 <= float(hf) <= 1.5, f'couple {name}: heightFactor must be 0.3..1.5'
        extra['heightFactor'] = float(hf)
    if isinstance(spec, dict) and spec.get('intimate'):   # v0.11: filtered out in friend mode (ContentPolicy)
        extra['intimate'] = True
    cid = build_clip(ensure_cutout(gif), f'Resources/Couples/{name}', speed, extra=extra, frames_range=frame_range(spec),
                     max_h=COUPLE_MAX_H)
    print(f'couple {name} <- {gif} x{speed} ({facing}){" sound " + sound if sound else ""} [{cid}]')
print(f"clip store: {store_stats['clips']} clips for {store_stats['refs']} uses")

shutil.rmtree('Resources/Stickers', ignore_errors=True)
os.makedirs('Resources/Stickers')
index = []
for s in json.load(open('assets/stickers.json')):
    build_sticker(s['gif'], f"Resources/Stickers/{s['id']}.gif")
    index.append({'id': s['id'], 'label': s['label'], 'file': f"{s['id']}.gif", **({'intimate': True} if s.get('intimate') else {})})
    print(f"sticker {s['id']} <- {s['gif']}")
json.dump(index, open('Resources/Stickers/stickers.json', 'w'), ensure_ascii=False, indent=1)

# v0.3 per-message reactions (optional), with visitor clips referred to by name.
if os.path.exists('Resources/reactions.json'):
    os.remove('Resources/reactions.json')
if compiled_reactions:
    for key, r in compiled_reactions.items():
        for c in reaction_names(r.get('couple')):
            if c != 'none' and c not in couples:
                print(f'warning: reaction {key}: couple "{c}" is not in couples.json (skipped from its pool)')
    json.dump(compiled_reactions, open('Resources/reactions.json', 'w'), ensure_ascii=False, indent=1)
    print(f'reactions: {len(compiled_reactions)} entries')

# v0.13 update log (read-only resource; scripts/build_app.sh also refreshes this copy on every build).
if os.path.exists('assets/changelog.json'):
    json.load(open('assets/changelog.json'))   # must at least be valid JSON
    shutil.copyfile('assets/changelog.json', 'Resources/changelog.json')
    print('changelog: assets/changelog.json -> Resources/changelog.json')

# v0.5 sounds (stdlib only, also run on its own by scripts/build_app.sh).
import build_sounds
build_sounds.build()
