// End to end without hardware: tools/fake_firebase.py (the repo's fake database) → bridge (real eventsource
// polyfill, read-only client) → MockPixoo. Checks that lulu's messages reach the device, lumei's do not, the
// cursor is saved locally, and the database is never written by the bridge.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startFake } from "../../../web/tests/net.helpers.mjs";
import { createReadOnlyFirebase } from "../src/readonly.js";
import { Bridge } from "../src/bridge.js";
import { Inbox } from "../src/inbox.js";
import { AssetStore } from "../src/assets.js";
import { Renderer } from "../src/render.js";
import { PixelFont } from "../src/font.js";
import { PixooClient } from "../src/pixoo.js";
import { MockPixoo } from "../src/mock-pixoo.js";
import { loadCursor, saveCursor } from "../src/cursor-file.js";
import { DEFAULTS } from "../src/config.js";
import { silentLogger } from "../src/log.js";
import { ASSETS, fixtureBDF, waitFor } from "./helpers.mjs";

let fake, dev;
before(async () => { fake = await startFake(); dev = await new MockPixoo().listen(); });
after(async () => { await fake?.stop(); await dev?.close(); });

const CODE = "TESTPXBRDGE234567ABCDEFG".slice(0, 24);
const put = (path, v) => fetch(`${fake.url}/pairs/${CODE}/${path}.json`, { method: "PUT", body: JSON.stringify(v) });
const get = async (path) => (await fetch(`${fake.url}/pairs/${CODE}/${path}.json`)).json();

test("lulu's poke and text reach the Pixoo; lumei's message is ignored; only GETs; cursor saved", async () => {
  const start = Date.now();
  await put("presence/lulu", { lastSeen: start, character: "lulu", outfit: "classic" });
  const stateFile = join(mkdtempSync(join(tmpdir(), "pixoo-e2e-")), "cursor.json");
  const cfg = structuredClone(DEFAULTS);
  Object.assign(cfg, { databaseURL: fake.url, pairCode: CODE, presencePollMs: 200, quietHours: { ...cfg.quietHours, enabled: false } });
  cfg.durations = { ...cfg.durations, pokeMs: 300, textMinMs: 300, textPageMs: 300, unknownMs: 300 };
  const methods = [];
  const spyFetch = (url, init = {}) => { methods.push((init.method ?? "GET").toUpperCase()); return fetch(url, init); };
  const fb = createReadOnlyFirebase({ databaseURL: fake.url, pairCode: CODE, fetch: spyFetch });
  const assets = new AssetStore({ assetsDir: ASSETS, cacheDir: mkdtempSync(join(tmpdir(), "pixoo-cache-")) });
  const renderer = new Renderer({ assets, font: new PixelFont(fixtureBDF()), cfg });
  const device = new PixooClient({ endpoint: dev.url, requestGapMs: 0, minAnimationGapMs: 0, log: silentLogger });
  saveCursor(stateFile, start - 1, start);
  const inbox = new Inbox({ watchSeat: "lulu", cursor: loadCursor(stateFile, start).ts, maxBacklog: 10 });
  const bridge = new Bridge({ cfg, fb, device, renderer, manifest: assets.manifest, inbox, log: silentLogger,
    persistCursor: (ts) => saveCursor(stateFile, ts, Date.now()) });
  await bridge.start();
  try {
    await waitFor(() => dev.animations.length >= 1, 8000);              // idle (online) appears
    assert.ok(dev.brightness === cfg.brightness);
    const before = dev.animations.length;
    await put("messages/-m1", { from: "lumei", kind: "text", text: "我自己发的", ts: start + 10, v: 1 });
    await put("messages/-m2", { from: "lulu", kind: "poke", ts: start + 20, v: 1, character: "lulu" });
    await put("messages/-m3", { from: "lulu", kind: "text", text: "你好", ts: start + 30, v: 1 });
    await waitFor(() => loadCursor(stateFile, Date.now()).ts === start + 30, 15000);
    await waitFor(() => dev.animations.length >= before + 3, 8000);     // poke, text, idle again
    assert.deepEqual(dev.errors, []);
    assert.equal(inbox.size, 0);
    assert.ok(methods.length > 0 && methods.every((m) => m === "GET"), `methods: ${[...new Set(methods)]}`);
    // nothing written by the bridge: no read cursor, presence of the other seat, devices
    assert.equal(await get("read"), null);
    assert.equal(await get("presence/lumei"), null);
    assert.equal(await get("devices"), null);
  } finally {
    await bridge.stop();
  }
});
