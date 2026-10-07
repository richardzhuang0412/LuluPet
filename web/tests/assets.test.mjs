// web/assets integrity (tools/build_web_assets.py output): files exist, names carry their content hash,
// sheet geometry matches the manifest, references resolve, and the §6.2 budgets hold.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ASSETS = join(dirname(fileURLToPath(import.meta.url)), '..', 'assets');
const KB = 1024;
const BUDGET = { idle: 200 * KB, outfit: 600 * KB, firstScreen: 1024 * KB, sticker: 400 * KB, total: 40 * 1024 * KB };

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

test('manifest shape', () => {
  assert.equal(manifest.version, 1);
  assert.equal(manifest.frameHeight, 200);
  for (const k of ['modes', 'clips', 'characters', 'stickers', 'stickerGroups', 'thumbs', 'defaultFavorites']) {
    assert.ok(k in manifest, k);
  }
  assert.deepEqual(Object.keys(manifest.characters).sort(), ['lulu', 'lumei']);
});

test('clips: files, hashes, sheet geometry, timing', () => {
  for (const [key, c] of Object.entries(manifest.clips)) {
    assert.match(key, /^[0-9a-f]+-h200(-[0-9a-f]{6})?$/, key);
    const data = file(c.file);
    hashOK(c.file, data);
    assert.equal(c.h, 200, key);
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

test('characters: order, outfits, actions, fidgets', () => {
  const used = new Set();
  for (const [name, ch] of Object.entries(manifest.characters)) {
    assert.deepEqual([...ch.order].sort(), Object.keys(ch.outfits).sort(), `${name} order lists every outfit`);
    assert.ok(ch.order.length > 0);
    for (const [o, of] of Object.entries(ch.outfits)) {
      assert.equal(typeof of.label, 'string');
      assert.ok(of.season === null || typeof of.season === 'string');
      assert.ok(of.actions.idle, `${name}/${o} has idle`);
      for (const [a, k] of Object.entries(of.actions)) {
        assert.ok(a in manifest.modes, `${name}/${o} action ${a} has a mode`);
        assert.ok(manifest.clips[k], `${name}/${o}/${a} -> ${k}`);
        used.add(k);
      }
      assert.ok(of.fidgets.length <= 2, `${name}/${o} at most 2 fidgets`);
      for (const k of of.fidgets) { assert.ok(manifest.clips[k], `${name}/${o} fidget ${k}`); used.add(k); }
      if (of.actions.quiet) assert.equal(manifest.clips[of.actions.quiet].frames, 1, `${name}/${o} quiet is a still`);
    }
  }
  assert.deepEqual([...used].sort(), Object.keys(manifest.clips).sort(), 'no unreferenced clip entries');
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

test('no stray files in sprites/ and stickers/', () => {
  const referenced = new Set([
    ...Object.values(manifest.clips).map((c) => c.file),
    ...manifest.stickers.map((s) => s.file),
    manifest.thumbs.file,
  ]);
  for (const dir of ['sprites', 'stickers']) {
    for (const f of readdirSync(join(ASSETS, dir))) assert.ok(referenced.has(`${dir}/${f}`), `stray ${dir}/${f}`);
  }
  for (const rel of referenced) assert.ok(existsSync(join(ASSETS, rel)), rel);
});

test('budgets (spec §6.2)', () => {
  const idleOf = new Map();
  for (const [name, ch] of Object.entries(manifest.characters)) {
    for (const [o, of] of Object.entries(ch.outfits)) {
      const idle = size(manifest.clips[of.actions.idle].file);
      assert.ok(idle <= BUDGET.idle, `${name}/${o} idle ${idle} B`);
      idleOf.set(`${name}/${o}`, idle);
      const files = new Set([...Object.values(of.actions), ...of.fidgets].map((k) => manifest.clips[k].file));
      const total = [...files].reduce((n, f) => n + size(f), 0);
      assert.ok(total <= BUDGET.outfit, `${name}/${o} outfit ${total} B`);
    }
  }
  for (const s of manifest.stickers) assert.ok(size(s.file) <= BUDGET.sticker, `sticker ${s.id} ${size(s.file)} B`);
  const worstMine = Math.max(...idleOf.values());
  const worstPartner = Math.max(...Object.entries(manifest.characters).map(([n, ch]) => idleOf.get(`${n}/${ch.order[0]}`)));
  const first = worstMine + worstPartner + manifestBytes.length + size(manifest.thumbs.file);
  assert.ok(first <= BUDGET.firstScreen, `first screen ${first} B`);
  let total = manifestBytes.length;
  for (const dir of ['sprites', 'stickers']) {
    for (const f of readdirSync(join(ASSETS, dir))) total += size(`${dir}/${f}`);
  }
  assert.ok(total <= BUDGET.total, `total ${total} B`);
});
