"""Build app sounds (v0.5): assets/sounds.json -> Resources/Sounds/{sounds.json, <files>}.

  assets/sounds.json = {"<event>": "file.m4a" | ["file1.m4a", "file2.m4a"], ..., "bgm": [...]}
  v0.9: a list entry may be {"file": "v4/S01.m4a", "visitor": "lulu"} (or "lumei"): a character-specific
  voice line that only plays when the pet the event is about (arrive: the visitor; goVisit / goBack: our
  own pet) is that character. A plain file name is neutral. Plain-only events compile as before.
  Events: arrive leave poke hug kiss nuzzle bubble angry cry happy doze awaySummary goVisit goBack
  notHome click (+ optional "bgm"; any other key is a custom event a reactions.json "sound" can name).
  Files are looked up in assets/sounds/ and copied as is; a missing file prints a warning and is left
  out (an event with no file left is silently skipped by the app). A missing or empty manifest builds
  an empty Resources/Sounds/sounds.json = no sounds.

Needs only the Python standard library (no Pillow), so scripts/build_app.sh can run it on its own.
build_sprites.py runs it at the end.
usage: python3 tools/build_sounds.py [--manifest assets/sounds.json] [--src assets/sounds] [--out Resources/Sounds]
"""
import argparse, json, os, shutil

EVENTS = ['arrive', 'leave', 'poke', 'hug', 'kiss', 'nuzzle', 'bubble', 'angry', 'cry', 'happy', 'doze',
          'awaySummary', 'goVisit', 'goBack', 'notHome', 'click']
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def build(manifest='assets/sounds.json', src='assets/sounds', out='Resources/Sounds'):
    data = json.load(open(manifest)) if os.path.exists(manifest) else {}
    assert isinstance(data, dict), 'sounds.json must be an object {"<event>": "file" | ["file", ...]}'
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    compiled, copied = {}, set()
    for key, value in data.items():
        files = value if isinstance(value, list) else [value]
        if key not in EVENTS and key != 'bgm':
            print(f'note: sound "{key}" is not a built-in event (usable from reactions.json / couples.json "sound")')
        kept, filters, intimate = [], {}, set()
        for entry in files:
            f = entry.get('file') if isinstance(entry, dict) else entry
            who = entry.get('visitor') if isinstance(entry, dict) else None
            is_intimate = isinstance(entry, dict) and entry.get('intimate') is True   # v0.11: skipped in friend mode
            if who is not None and who not in ('lulu', 'lumei'):
                print(f'warning: sound {key}: visitor {who!r} must be lulu or lumei (treated as neutral)')
                who = None
            if not isinstance(f, str) or not f:
                print(f'warning: sound {key}: bad entry {entry!r} (skipped)')
                continue
            path = os.path.join(src, f)
            if not os.path.isfile(path):
                print(f'warning: sound {key}: {path} not found (skipped)')
                continue
            if f not in copied:
                os.makedirs(os.path.dirname(os.path.join(out, f)), exist_ok=True)
                shutil.copyfile(path, os.path.join(out, f))
                copied.add(f)
            if f not in kept:
                kept.append(f)
                if who:
                    filters[f] = who
                if is_intimate:
                    intimate.add(f)
        if kept:
            items = []
            for f in kept:
                if f in filters or f in intimate:
                    item = {'file': f}
                    if f in filters:
                        item['visitor'] = filters[f]
                    if f in intimate:
                        item['intimate'] = True
                    items.append(item)
                else:
                    items.append(f)
            compiled[key] = items if len(items) > 1 or filters or intimate else items[0]
            print(f'sound {key} <- {kept}' + (f' (only for {filters})' if filters else '') + (f' (intimate {sorted(intimate)})' if intimate else ''))
    json.dump(compiled, open(os.path.join(out, 'sounds.json'), 'w'), ensure_ascii=False, indent=1)
    print(f'sounds: {len(compiled)} event(s), {len(copied)} file(s)')


if __name__ == '__main__':
    os.chdir(ROOT)
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--manifest', default='assets/sounds.json')
    ap.add_argument('--src', default='assets/sounds')
    ap.add_argument('--out', default='Resources/Sounds')
    a = ap.parse_args()
    build(a.manifest, a.src, a.out)
