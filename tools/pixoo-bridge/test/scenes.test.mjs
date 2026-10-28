// Scene mapping against the real web/assets manifest, and rendering every scene to valid frames.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { idleScene, messageScene, pickLook, presenceState, toolClip, REMIND_LINES, UNKNOWN_LINE } from "../src/scenes.js";
import { AssetStore } from "../src/assets.js";
import { Renderer } from "../src/render.js";
import { PixelFont } from "../src/font.js";
import { DEFAULTS } from "../src/config.js";
import { sampleScenes } from "../src/samples.js";
import { FRAME_BYTES } from "../src/pixoo.js";
import { manifest as loadManifest, ASSETS, fixtureBDF } from "./helpers.mjs";

const M = loadManifest();
const NOW = 1_760_000_000_000;
const online = { lastSeen: NOW - 1000, character: "lulu", outfit: "classic" };
const msg = (kind, extra = {}) => ({ id: "-k1", from: "lulu", kind, ts: NOW, ...extra });
const opts = { watchSeat: "lulu", durations: DEFAULTS.durations, rand: () => 0 };

test("presence → idle state", () => {
  assert.equal(presenceState(null, NOW), "offline");
  assert.equal(presenceState(online, NOW), "online");
  assert.equal(presenceState({ ...online, lastSeen: NOW - 80_000 }, NOW), "offline");
  assert.equal(presenceState({ ...online, dnd: { mood: "", until: 0 } }, NOW), "dnd");
  assert.equal(presenceState({ ...online, dnd: { mood: "", until: NOW - 1 } }, NOW), "online");
  assert.equal(presenceState({ ...online, focus: { phase: "focus", until: NOW + 1 } }, NOW), "focus");
});

test("idle scenes: loop / quiet still + badge / sleep clip / dim + Zzz", () => {
  const out = M.characters.lulu.outfits.classic.actions;
  const on = idleScene(M, online, NOW);
  assert.equal(on.clip, out.idle);
  assert.ok(!on.still);
  const dnd = idleScene(M, { ...online, dnd: { mood: "busy", until: 0 } }, NOW);
  assert.deepEqual([dnd.clip, dnd.still, dnd.badge], [out.quiet, true, "dnd"]);
  const focus = idleScene(M, { ...online, focus: { phase: "focus", until: NOW + 5 } }, NOW);
  assert.equal(focus.badge, "focus");
  const off = idleScene(M, { ...online, lastSeen: 0 }, NOW);
  assert.equal(off.clip, out.sleep);
  const noSleep = M.characters.lulu.order.find((o) => !M.characters.lulu.outfits[o].actions.sleep);
  const off2 = idleScene(M, { ...online, lastSeen: 0, outfit: noSleep }, NOW);
  assert.deepEqual([off2.clip, off2.still, off2.zzz], [M.characters.lulu.outfits[noSleep].actions.idle, true, true]);
  assert.notEqual(on.key, off.key);
  assert.equal(on.key, idleScene(M, { ...online, lastSeen: NOW - 500 }, NOW).key);
});

test("look: message character / outfit first, then presence, then defaults; unknown outfit falls back", () => {
  assert.deepEqual(pickLook(M, { msg: { character: "lumei", outfit: "maid" }, presence: online }), { character: "lumei", outfit: "maid" });
  assert.deepEqual(pickLook(M, { msg: { character: "lumei" }, presence: online }), { character: "lumei", outfit: M.characters.lumei.order[0] });
  assert.deepEqual(pickLook(M, { msg: { outfit: "nope" }, presence: { ...online, outfit: "bear" } }), { character: "lulu", outfit: "bear" });
  assert.deepEqual(pickLook(M, {}), { character: "lulu", outfit: "classic" });
});

test("message scenes", () => {
  const happy = M.characters.lulu.outfits.classic.actions.happy;
  const poke = messageScene(M, msg("poke"), online, opts);
  assert.deepEqual([poke.kind, poke.clip, poke.hearts], ["poke", happy, true]);
  const text = messageScene(M, msg("text", { text: "你好" }), online, opts);
  assert.deepEqual([text.kind, text.text], ["text", "你好"]);
  const st = messageScene(M, msg("sticker", { stickerId: M.stickers[0].id }), online, opts);
  assert.deepEqual([st.kind, st.sticker, st.label], ["sticker", M.stickers[0].id, M.stickers[0].label]);
  const unknownSticker = messageScene(M, msg("sticker", { stickerId: "zzz", text: "[表情] 抱抱" }), online, opts);
  assert.deepEqual([unknownSticker.kind, unknownSticker.text], ["text", "［表情：抱抱］"]);
  const visit = messageScene(M, msg("visit"), online, opts);
  assert.equal(visit.kind, "visit");
  assert.equal(visit.line, "来看看你～想你啦");
  const water = messageScene(M, msg("remind", { remind: "water" }), online, opts);
  assert.equal(water.line, REMIND_LINES.water);
  assert.equal(water.clip, toolClip(M, { character: "lulu", outfit: "classic" }, "water", () => 0));
  assert.equal(messageScene(M, msg("remind", { remind: "stand" }), online, opts).line, "起来动动 🧍");
  const now = messageScene(M, msg("remind", { remind: "water", ackOf: "-a", answer: "now" }), online, opts);
  assert.equal(now.line, "TA 说马上喝 💧");
  const later = messageScene(M, msg("remind", { remind: "stand.later", ackOf: "-a", answer: "later" }), online, opts);
  assert.equal(later.line, "TA 说等会儿再动");
  const late = messageScene(M, msg("remind", { remind: "water", ackOf: "-a", late: true }), online, opts);
  assert.equal(late.line, "TA 终于喝啦 💧");
  assert.equal(messageScene(M, msg("hologram"), online, opts).line, UNKNOWN_LINE);
  assert.equal(messageScene(M, msg("remind", { remind: "yoga" }), online, opts).kind, "unknown");
  // an outfit without the tool clip falls back to happy
  const bear = messageScene(M, msg("remind", { remind: "water", outfit: "bear" }), online, opts);
  assert.equal(bear.clip, M.characters.lulu.outfits.bear.actions.happy);
});

test("every sample scene renders to valid 64×64 RGB segments (≤ 40 frames, uniform speed)", async () => {
  const cache = mkdtempSync(join(tmpdir(), "pixoo-cache-"));
  const assets = new AssetStore({ assetsDir: ASSETS, cacheDir: cache });
  const cfg = { ...structuredClone(DEFAULTS) };
  const r = new Renderer({ assets, font: new PixelFont(fixtureBDF()), cfg });
  for (const { name, scene } of sampleScenes(M, cfg)) {
    const { segments, totalMs } = await r.render(scene);
    assert.ok(segments.length >= 1, name);
    for (const s of segments) {
      assert.ok(s.frames.length >= 1 && s.frames.length <= 40, `${name}: ${s.frames.length} frames`);
      assert.ok(s.frames.every((f) => f.length === FRAME_BYTES), name);
      assert.ok(s.frameMs >= 50 && s.frameMs <= 2000, `${name}: ${s.frameMs}`);
      assert.ok(s.holdMs > 0, name);
      assert.ok(s.frames.some((f) => f.some((b) => b > 0)), `${name} is not blank`);
    }
    if (scene.kind !== "idle") assert.ok(totalMs >= scene.durationMs - 1, `${name}: ${totalMs}`);
  }
  // second store reads the disk cache
  const again = new AssetStore({ assetsDir: ASSETS, cacheDir: cache });
  const key = M.characters.lulu.outfits.classic.actions.idle;
  const a = await assets.clipFrames(key, { boxW: 64, boxH: 60 });
  const b = await again.clipFrames(key, { boxW: 64, boxH: 60 });
  assert.equal(b.frames.length, a.frames.length);
  assert.deepEqual(Buffer.from(b.frames[3].data), Buffer.from(a.frames[3].data));
});

test("text pages: one segment per page, total ≥ page count × page time", async () => {
  const assets = new AssetStore({ assetsDir: ASSETS, cacheDir: mkdtempSync(join(tmpdir(), "pixoo-cache-")) });
  const cfg = structuredClone(DEFAULTS);
  const r = new Renderer({ assets, font: new PixelFont(fixtureBDF()), cfg });
  const scene = messageScene(M, msg("text", { text: "你好".repeat(15) }), online, { ...opts, durations: cfg.durations });   // 30 chars → 5 lines → 3 pages
  const { segments, totalMs } = await r.render(scene);
  assert.equal(segments.length, 3);
  assert.ok(segments.every((s) => s.frames.length <= cfg.textFrames));
  assert.equal(totalMs, Math.max(cfg.durations.textMinMs, 3 * cfg.durations.textPageMs));
  assert.equal(segments.reduce((a, s) => a + s.holdMs, 0), totalMs);
});
