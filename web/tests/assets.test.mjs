// web/assets integrity (tools/build_web_assets.py output, manifest v2 — spec 2026-10-12 §5): files exist, names
// carry their content hash, sheet geometry matches the manifest, every reference resolves, and the budgets hold.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ASSETS = join(dirname(fileURLToPath(import.meta.url)), '..', 'assets');
const KB = 1024;
const MB = 1024 * KB;
const BUDGET = {
  idle: 320 * KB, clip: 900 * KB, weather: 600 * KB, outfit: 2560 * KB, firstScreen: 1536 * KB,
  sticker: 400 * KB, total: 150 * MB,
};
const DIRS = ['sprites', 'stickers'];
const CHARACTERS = ['lulu', 'lumei'];

const manifestBytes = readFileSync(join(ASSETS, 'manifest.json'));
const manifest = JSON.parse(manifestBytes.toString('utf8'));
const sizeCache = new Map();

function file(rel) {
  assert.match(rel, /^(sprites|stickers)\/[A-Za-z0-9_.-]+\.webp$/, `safe relative path: ${rel}`);
  const data = readFileSync(join(ASSETS, rel));
  sizeCache.set(rel, data.length);
  return data;
}

function size(rel) {
  if (!sizeCache.has(rel)) file(rel);
  return sizeCache.get(rel);
}

/** WebP canvas size from the RIFF header (VP8X, VP8L or VP8). */
function webpSize(buf) {
  assert.equal(buf.toString('ascii', 0, 4), 'RIFF');
  assert.equal(buf.toString('ascii', 8, 12), 'WEBP');
  const chunk = buf.toString('ascii', 12, 16);
  if (chunk === 'VP8X') return [1 + buf.readUIntLE(24, 3), 1 + buf.readUIntLE(27, 3)];
  if (chunk === 'VP8L') {
    const b = buf.readUInt32LE(21);
    return [1 + (b & 0x3fff), 1 + ((b >> 14) & 0x3fff)];
  }
  if (chunk === 'VP8 ') return [buf.readUInt16LE(26) & 0x3fff, buf.readUInt16LE(28) & 0x3fff];
  throw new Error(`unknown WebP chunk ${chunk}`);
}

function hashOK(rel, data) {
  const m = rel.match(/\.([0-9a-f]{10})\.webp$/);
  assert.ok(m, `content hash in name: ${rel}`);
  assert.equal(createHash('sha256').update(data).digest('hex').slice(0, 10), m[1], `hash matches content: ${rel}`);
}

const clip = (k, where) => {
  assert.ok(typeof k === 'string' && manifest.clips[k], `${where} -> clip ${k}`);
  return manifest.clips[k];
};
const asList = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);

test('manifest shape (v2)', () => {
  assert.equal(manifest.version, 2);
  assert.equal(manifest.frameHeight, 240);
  for (const k of ['modes', 'clips', 'characters', 'couples', 'reactions', 'toolClips', 'sounds', 'stickers',
    'stickerGroups', 'thumbs', 'defaultFavorites', 'changelog', 'totalBytes']) {
    assert.ok(k in manifest, k);
  }
  assert.deepEqual(Object.keys(manifest.characters).sort(), CHARACTERS);
  assert.ok(Array.isArray(manifest.changelog) && manifest.changelog.length > 0, 'changelog');
});

test('clips: files, hashes, sheet geometry, timing (full frame rate)', () => {
  for (const [key, c] of Object.entries(manifest.clips)) {
    assert.match(key, /^[0-9a-f]+-h240(-[0-9a-f]{6})?$/, key);
    const data = file(c.file);
    hashOK(c.file, data);
    assert.equal(c.h, 240, key);
    assert.ok(c.cols >= 1 && c.cols <= 8 && c.cols <= c.cells, key);
    assert.deepEqual(webpSize(data), [c.cols * c.w, Math.ceil(c.cells / c.cols) * c.h], `${key} sheet size`);
    assert.equal(c.delays.length, c.frames, `${key} delays`);
    assert.equal(c.seq.length, c.frames, `${key} seq`);
    assert.ok(c.delays.every((d) => typeof d === 'number' && d > 0), `${key} positive delays`);
    assert.ok(c.seq.every((i) => Number.isInteger(i) && i >= 0 && i < c.cells), `${key} seq in range`);
    assert.equal(new Set(c.seq).size, c.cells, `${key} every cell is shown`);
    assert.ok(Array.isArray(c.src) && c.src.length === 2 && c.src.every((v) => v > 0), `${key} src`);
  }
});

const used = new Set();

test('characters: order, outfits, actions, all fidgets, named clips, weather', () => {
  for (const [name, ch] of Object.entries(manifest.characters)) {
    assert.deepEqual([...ch.order].sort(), Object.keys(ch.outfits).sort(), `${name} order lists every outfit`);
    assert.ok(ch.order.length > 0);
    for (const [o, of] of Object.entries(ch.outfits)) {
      const where = `${name}/${o}`;
      assert.equal(typeof of.label, 'string');
      assert.ok(of.season === null || typeof of.season === 'string');
      assert.ok(of.actions.idle, `${where} has idle`);
      for (const [a, k] of Object.entries(of.actions)) {
        assert.ok(a in manifest.modes, `${where} action ${a} has a mode`);
        clip(k, `${where}/${a}`);
        used.add(k);
      }
      if (of.actions.quiet) assert.equal(manifest.clips[of.actions.quiet].frames, 1, `${where} quiet is a still`);
      assert.equal(of.fidgetNames.length, of.fidgets.length, `${where} fidgetNames parallel to fidgets`);
      of.fidgets.forEach((k, i) => { clip(k, `${where} fidget ${i}`); used.add(k); });
      for (const n of [...of.fidgetNames, ...of.stay, ...of.extras]) {
        assert.ok(Object.hasOwn(of.named, n), `${where} named has ${n}`);
      }
      for (const [n, k] of Object.entries(of.named)) { clip(k, `${where} named ${n}`); used.add(k); }
      of.fidgetNames.forEach((n, i) => {
        if (of.fidgetNames.indexOf(n) === i) assert.equal(of.named[n], of.fidgets[i], `${where} fidget ${n}`);
      });
      for (const [n, s] of Object.entries(of.clipSounds)) {
        assert.ok(Object.hasOwn(of.named, n), `${where} clipSounds ${n} is a named clip`);
        assert.equal(typeof s, 'string', `${where} clip sound key`);
      }
    }
    for (const [look, entries] of Object.entries(ch.weather)) {
      assert.ok(entries.length > 0, `${name} weather ${look}`);
      for (const e of entries) {
        assert.equal(typeof e.name, 'string');
        clip(e.clip, `${name} weather ${look}/${e.name}`);
        used.add(e.clip);
        assert.ok(e.sound === undefined || typeof e.sound === 'string', `${name} weather sound key`);
      }
    }
  }
});

test('couples, reactions, toolClips resolve', () => {
  for (const [n, c] of Object.entries(manifest.couples)) {
    clip(c.clip, `couple ${n}`);
    used.add(c.clip);
    assert.equal(typeof c.intimate, 'boolean');
    assert.equal(typeof c.luluOnLeft, 'boolean');
    assert.ok(c.heightFactor >= 0.3 && c.heightFactor <= 1.5, `couple ${n} heightFactor`);
    assert.ok(c.sound === null || typeof c.sound === 'string', `couple ${n} sound key`);
  }
  const namedOf = (c) => new Set(Object.values(manifest.characters[c].outfits).flatMap((of) => Object.keys(of.named)));
  const names = Object.fromEntries(CHARACTERS.map((c) => [c, namedOf(c)]));
  for (const [key, r] of Object.entries(manifest.reactions)) {
    for (const n of asList(r.couple)) assert.ok(n === 'none' || manifest.couples[n], `reactions ${key} couple ${n}`);
    for (const [c, v] of Object.entries(r.visitor || {})) {
      for (const n of asList(v)) assert.ok(names[c].has(n), `reactions ${key} visitor ${c}: some outfit has ${n}`);
    }
  }
  assert.deepEqual(Object.keys(manifest.toolClips).sort(), ['breakTime', 'eyedrops', 'focus', 'stand', 'water']);
  for (const [kind, pools] of Object.entries(manifest.toolClips)) {
    assert.deepEqual(Object.keys(pools).sort(), CHARACTERS, `toolClips ${kind}`);
    for (const c of CHARACTERS) for (const n of pools[c]) assert.ok(names[c].has(n), `toolClips ${kind}/${c} ${n}`);
  }
  assert.deepEqual([...used].sort(), Object.keys(manifest.clips).sort(), 'no unreferenced clip entries');
});

test('sounds: none on the web (office use; W5 synthesizes UI tones)', () => {
  assert.deepEqual(manifest.sounds, {});
  assert.ok(!existsSync(join(ASSETS, 'sounds')), 'no web/assets/sounds');
});

test('stickers: files, hashes, metadata, thumbs, favorites', () => {
  const groups = new Set(manifest.stickerGroups.map((g) => g.id));
  const ids = new Set();
  for (const s of manifest.stickers) {
    assert.match(s.id, /^[a-z0-9_]+$/);
    assert.ok(!ids.has(s.id), `unique ${s.id}`);
    ids.add(s.id);
    assert.equal(typeof s.label, 'string');
    assert.ok(groups.has(s.group), `${s.id} group`);
    assert.equal(typeof s.intimate, 'boolean');
    const data = file(s.file);
    hashOK(s.file, data);
    assert.deepEqual(webpSize(data), [s.w, s.h], `${s.id} size`);
    assert.ok(Math.max(s.w, s.h) <= 200, `${s.id} longest side <= 200`);
    assert.ok(Number.isInteger(s.thumb) && s.thumb >= 0 && s.thumb < manifest.thumbs.count, `${s.id} thumb`);
  }
  assert.equal(new Set(manifest.stickers.map((s) => s.thumb)).size, manifest.stickers.length, 'distinct thumbs');
  const t = manifest.thumbs;
  const data = file(t.file);
  hashOK(t.file, data);
  assert.deepEqual(webpSize(data), [t.cols * t.size, Math.ceil(t.count / t.cols) * t.size]);
  for (const f of manifest.defaultFavorites) assert.ok(ids.has(f), `favorite ${f}`);
  assert.equal(manifest.defaultFavorites.length, 24);
});

function referencedFiles() {
  return new Set([
    ...Object.values(manifest.clips).map((c) => c.file),
    ...manifest.stickers.map((s) => s.file),
    manifest.thumbs.file,
  ]);
}

test('no stray files; totalBytes matches', () => {
  const referenced = referencedFiles();
  for (const dir of DIRS) {
    for (const f of readdirSync(join(ASSETS, dir))) assert.ok(referenced.has(`${dir}/${f}`), `stray ${dir}/${f}`);
  }
  for (const rel of referenced) assert.ok(existsSync(join(ASSETS, rel)), rel);
  for (const f of readdirSync(ASSETS)) assert.ok(['manifest.json', 'README.md', ...DIRS].includes(f), `stray ${f}`);
  assert.equal(manifest.totalBytes, [...referenced].reduce((n, f) => n + size(f), 0), 'totalBytes');
});

test('budgets (spec §5)', () => {
  const idleOf = new Map();
  for (const [name, ch] of Object.entries(manifest.characters)) {
    for (const [o, of] of Object.entries(ch.outfits)) {
      const idle = size(manifest.clips[of.actions.idle].file);
      assert.ok(idle <= BUDGET.idle, `${name}/${o} idle ${idle} B`);
      idleOf.set(`${name}/${o}`, idle);
      const core = new Set([...Object.values(of.actions), ...of.fidgets].map((k) => manifest.clips[k].file));
      const total = [...core].reduce((n, f) => n + size(f), 0);
      assert.ok(total <= BUDGET.outfit, `${name}/${o} outfit ${total} B`);
      for (const k of [...Object.values(of.actions), ...Object.values(of.named)]) {
        assert.ok(size(manifest.clips[k].file) <= BUDGET.clip, `${name}/${o} clip ${k}`);
      }
    }
    for (const es of Object.values(ch.weather)) {
      for (const e of es) assert.ok(size(manifest.clips[e.clip].file) <= BUDGET.weather, `${name} weather ${e.name}`);
    }
  }
  for (const [n, c] of Object.entries(manifest.couples)) assert.ok(size(manifest.clips[c.clip].file) <= BUDGET.clip, `couple ${n}`);
  for (const s of manifest.stickers) assert.ok(size(s.file) <= BUDGET.sticker, `sticker ${s.id} ${size(s.file)} B`);
  const worstMine = Math.max(...idleOf.values());
  const worstPartner = Math.max(...Object.entries(manifest.characters).map(([n, ch]) => idleOf.get(`${n}/${ch.order[0]}`)));
  const first = worstMine + worstPartner + manifestBytes.length + size(manifest.thumbs.file);
  assert.ok(first <= BUDGET.firstScreen, `first screen ${first} B`);
  const total = manifestBytes.length + [...referencedFiles()].reduce((n, f) => n + size(f), 0);
  assert.ok(total <= BUDGET.total, `total ${total} B`);
});
