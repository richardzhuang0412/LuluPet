// Frame sampling, font paging, quiet hours, inbox / cursor, log redaction, config.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sampleClip, sampleWindow, pingPong } from "../src/frames.js";
import { PixelFont, tokenize, wrap, paginate, layoutPages, width, drawLine } from "../src/font.js";
import { inQuietHours, minutesOfDay } from "../src/quiet.js";
import { Inbox } from "../src/inbox.js";
import { loadCursor, saveCursor } from "../src/cursor-file.js";
import { createLogger } from "../src/log.js";
import { loadConfig, ConfigError, describe as describeCfg } from "../src/config.js";
import { newFrame } from "../src/canvas.js";
import { fixtureBDF, BRIDGE } from "./helpers.mjs";

// ---- frames

test("sampleClip: short uniform clip unchanged", () => {
  const r = sampleClip({ seq: [0, 1, 2, 1], delays: [0.1, 0.1, 0.1, 0.1] }, 40);
  assert.deepEqual(r, { cells: [0, 1, 2, 1], frameMs: 100 });
});

test("sampleClip: long clip capped at 40, frames dropped evenly, total duration kept", () => {
  const seq = [...Array(100).keys()];
  const r = sampleClip({ seq, delays: seq.map(() => 0.05) }, 40);
  assert.equal(r.cells.length, 40);
  assert.equal(r.frameMs, 125);                    // 100 × 50 ms = 5 s = 40 × 125 ms
  assert.equal(r.cells[0], 1);
  for (let i = 1; i < 40; i++) assert.ok(r.cells[i] - r.cells[i - 1] >= 2 && r.cells[i] - r.cells[i - 1] <= 3);
  assert.equal(r.cells.at(-1), 98);
});

test("sampleClip: uneven delays → even timing, long frames repeated", () => {
  const r = sampleClip({ seq: [7, 8], delays: [0.3, 0.1] }, 40);
  assert.equal(r.cells.length, 2);
  assert.equal(r.frameMs, 200);
  assert.deepEqual(r.cells, [7, 8]);
  const r2 = sampleClip({ seq: [0, 1, 2], delays: [0.5, 0.05, 0.05] }, 3);
  assert.equal(r2.frameMs, 200);
  assert.deepEqual(r2.cells, [0, 0, 1]);   // samples at 100, 300, 500 ms
});

test("sampleClip: single frame, tiny delays clamp to ≥ 50 ms, missing delays", () => {
  assert.deepEqual(sampleClip({ seq: [3], delays: [1] }, 40), { cells: [3], frameMs: 1000 });
  const r = sampleClip({ seq: [0, 1, 2, 3, 4, 5], delays: [0.01, 0.01, 0.01, 0.01, 0.01, 0.01] }, 40);
  assert.equal(r.cells.length, 1);
  assert.ok(r.frameMs >= 50);
  assert.equal(sampleClip({ seq: [0, 1] }, 40).frameMs, 100);
});

test("sampleWindow + pingPong: first n frames at their own pace, smooth loop", () => {
  const seq = [...Array(30).keys()];
  const w = sampleWindow({ seq, delays: seq.map(() => 0.11) }, 8);
  assert.deepEqual(w, { cells: [0, 1, 2, 3, 4, 5, 6, 7], frameMs: 110 });
  assert.deepEqual(pingPong([1, 2, 3, 4]), [1, 2, 3, 4, 3, 2]);
  assert.deepEqual(pingPong([1, 2]), [1, 2]);
});

// ---- font

const font = new PixelFont(fixtureBDF());

test("BDF parse: metrics and bits", () => {
  assert.equal(font.ascent, 11);
  assert.equal(font.glyph(0x4f60).dw, 10);
  assert.equal(font.glyph(0x41).dw, 6);
  assert.equal(PixelFont.bit(font.glyph(0x4f60), 0, 0), 1);
  assert.equal(PixelFont.bit(font.glyph(0x4f60), 8, 0), 1);
  assert.equal(PixelFont.bit(font.glyph(0x4f60), 9, 0), 0);
});

test("tokenize: emoji with an icon, unknown emoji dropped, missing glyph → default box, FE0F ignored", () => {
  const t = tokenize(font, "你💧🐱❤️字");
  assert.deepEqual(t.map((x) => x.type), ["glyph", "icon", "icon", "glyph"]);
  assert.equal(t[1].name, "drop");
  assert.equal(t[2].name, "heart9");
  assert.equal(t[3].cp, 65534);
});

test("wrap: 6 CJK per 62 px line, latin words kept whole, newlines", () => {
  const lines = wrap(tokenize(font, "你好你好你好你好"), 62);
  assert.deepEqual(lines.map((l) => l.length), [6, 2]);
  const latin = wrap(tokenize(font, "AB CDEFG HI"), 40);
  assert.deepEqual(latin.map((l) => l.map((i) => i.ch ?? " ").join("")), ["AB", "CDEFG", "HI"]);
  assert.equal(wrap(tokenize(font, "你\n好"), 62).length, 2);
  for (const l of wrap(tokenize(font, "想你啦想你啦想你啦 I miss you 💧💧"), 62)) assert.ok(width(l) <= 62);
});

test("paginate: 2 lines per page, cut at maxPages with …", () => {
  const text = "你好".repeat(30);   // 60 chars → 10 lines → 5 pages
  const all = layoutPages(font, text, { maxWidth: 62, perPage: 2, maxPages: 12 });
  assert.equal(all.pages.length, 5);
  assert.equal(all.truncated, false);
  const cut = layoutPages(font, text, { maxWidth: 62, perPage: 2, maxPages: 2 });
  assert.equal(cut.pages.length, 2);
  assert.equal(cut.truncated, true);
  const last = cut.pages[1][1];
  assert.equal(last.at(-1).cp, 0x2026);
  assert.ok(width(last) <= 62);
  assert.equal(layoutPages(font, "", {}).pages.length, 1);
});

test("drawLine sets pixels inside the frame only", () => {
  const f = newFrame();
  drawLine(f, font, tokenize(font, "你"), 60, 62, [255, 0, 0]);
  let lit = 0;
  for (let i = 0; i < f.data.length; i += 3) if (f.data[i] === 255) lit++;
  assert.equal(lit, 4 * 9);    // 4 columns of the 9×9 box fit (x 60…63)
});

test("real font (if downloaded): CJK 9 px tall, 10 px advance", { skip: !existsSync(join(BRIDGE, "fonts/fusion-pixel-10px-proportional-zh_hans.bdf")) }, () => {
  const real = PixelFont.load(join(BRIDGE, "fonts/fusion-pixel-10px-proportional-zh_hans.bdf"));
  assert.equal(real.glyph(0x4f60).dw, 10);
  const { pages } = layoutPages(real, "想你啦～今天吃什么？", { maxWidth: 62 });
  assert.equal(pages.length, 1);
  assert.equal(pages[0].length, 2);
});

// ---- quiet hours

test("quiet hours wrap past midnight, in the configured zone", () => {
  const q = { enabled: true, start: "23:00", end: "08:00" };
  const at = (iso) => Date.parse(iso);
  assert.equal(inQuietHours(at("2026-10-27T23:30:00Z"), q, "UTC"), true);
  assert.equal(inQuietHours(at("2026-10-27T07:59:00Z"), q, "UTC"), true);
  assert.equal(inQuietHours(at("2026-10-27T08:00:00Z"), q, "UTC"), false);
  assert.equal(inQuietHours(at("2026-10-27T22:59:00Z"), q, "UTC"), false);
  assert.equal(inQuietHours(at("2026-10-27T16:00:00Z"), q, "Asia/Shanghai"), true);   // 00:00 in Shanghai
  assert.equal(inQuietHours(at("2026-10-27T13:00:00Z"), { enabled: true, start: "12:00", end: "14:00" }, "UTC"), true);
  assert.equal(inQuietHours(at("2026-10-27T23:30:00Z"), { ...q, enabled: false }, "UTC"), false);
  assert.equal(inQuietHours(at("2026-10-27T23:30:00Z"), { enabled: true, start: "08:00", end: "08:00" }, "UTC"), false);
  assert.equal(minutesOfDay(at("2026-10-27T00:05:00Z"), "UTC"), 5);
});

// ---- inbox + cursor

const m = (id, ts, from = "lulu", kind = "text") => ({ id, ts, from, kind });

test("inbox: only the watched seat, deduped, ordered", () => {
  const ib = new Inbox({ watchSeat: "lulu", cursor: 100 });
  const r = ib.add([m("b", 120), m("a", 110), m("x", 115, "lumei"), m("old", 90)]);
  assert.deepEqual(r.added.map((x) => x.id), ["a", "b"]);
  assert.equal(r.ignored, 1);
  assert.equal(ib.add([m("a", 110)]).added.length, 0);
  assert.equal(ib.peek().id, "a");
});

test("cursor never passes a waiting message; moves after it is done; first start = now", () => {
  const ib = new Inbox({ watchSeat: "lulu", cursor: 100 });
  ib.add([m("a", 110), m("x", 130, "lumei"), m("b", 120)]);
  assert.equal(ib.commit(), true);
  assert.equal(ib.cursor, 109);           // lumei's 130 is ignored, but "a" (110) still waits
  ib.done(ib.peek());
  ib.commit();
  assert.equal(ib.cursor, 119);
  ib.done(ib.peek());
  ib.commit();
  assert.equal(ib.cursor, 130);
  assert.equal(ib.commit(), false);
});

test("backlog fold keeps the newest N, skipAll drops everything", () => {
  const ib = new Inbox({ watchSeat: "lulu", cursor: 0, maxBacklog: 3 });
  const r = ib.add([1, 2, 3, 4, 5].map((i) => m(`m${i}`, i)));
  assert.equal(r.folded, 2);
  assert.deepEqual(ib.pending.map((x) => x.id), ["m3", "m4", "m5"]);
  ib.commit();
  assert.equal(ib.cursor, 2);
  assert.equal(ib.skipAll(), 3);
  ib.commit();
  assert.equal(ib.cursor, 5);
});

test("cursor file: first start → now, persisted value read back, future value reset", () => {
  const dir = mkdtempSync(join(tmpdir(), "pixoo-cursor-"));
  const p = join(dir, "state", "cursor.json");
  assert.deepEqual(loadCursor(p, 5000), { ts: 5000, fresh: true });
  saveCursor(p, 1234, 5000);
  assert.deepEqual(loadCursor(p, 5000), { ts: 1234, fresh: false });
  assert.equal(JSON.parse(readFileSync(p, "utf8")).ts, 1234);
  saveCursor(p, 5000 + 2 * 86_400_000, 5000);
  assert.deepEqual(loadCursor(p, 5000), { ts: 5000, fresh: true });
  writeFileSync(p, "garbage");
  assert.deepEqual(loadCursor(p, 7), { ts: 7, fresh: true });
});

// ---- logging / config

test("logger never prints the pair code or database URL", () => {
  const lines = [];
  const code = "ABCDEFGHJKLMNPQRSTUVWXYZ";
  const db = "https://example-project-default-rtdb.example.com";
  const log = createLogger({ secrets: [code, db], sink: (l) => lines.push(l), level: "debug" });
  log.info(`GET ${db}/pairs/${code}/messages.json`);
  log.error(new Error(`fetch failed for ${encodeURIComponent(code)} at example-project-default-rtdb.example.com`));
  const all = lines.join("\n");
  assert.ok(!all.includes(code) && !all.includes("example-project-default-rtdb"));
  assert.ok(all.includes("***"));
});

test("config: validation, env overrides, secrets masked in describe()", () => {
  const dir = mkdtempSync(join(tmpdir(), "pixoo-cfg-"));
  const file = join(dir, "c.json");
  writeFileSync(file, JSON.stringify({ databaseURL: "https://x.example.com/", pairCode: "abcd efgh jkmn pqrs tuvw xyz2", quietHours: { start: "22:30" } }));
  const c = loadConfig({ file, env: { PIXOO_IP: "192.0.2.10" } });
  assert.equal(c.pairCode, "ABCDEFGHJKMNPQRSTUVWXYZ2");
  assert.equal(c.databaseURL, "https://x.example.com");
  assert.equal(c.quietHours.start, "22:30");
  assert.equal(c.quietHours.end, "08:00");
  assert.equal(c.pixoo.ip, "192.0.2.10");
  const d = JSON.stringify(describeCfg(c));
  assert.ok(!d.includes("ABCDEFGH") && !d.includes("x.example.com"));
  writeFileSync(file, JSON.stringify({ databaseURL: "https://x.example.com", pairCode: "short" }));
  assert.throws(() => loadConfig({ file, env: {} }), ConfigError);
  assert.doesNotThrow(() => loadConfig({ file, env: {}, needFirebase: false }));
});
