#!/usr/bin/env node
// LuluPet → Divoom Pixoo-64 bridge. See ../README.md.
//
//   node bin/pixoo-bridge.js [--config FILE]            run: Firebase (read-only) → Pixoo
//   node bin/pixoo-bridge.js --dry-run                  run, but only log what would be sent to the Pixoo
//   node bin/pixoo-bridge.js --preview [--out DIR]      render sample scenes to GIFs + contact-sheet.png (no device, no Firebase)
//   node bin/pixoo-bridge.js --preview --live [--out DIR]   real messages → GIF files instead of the device
//   node bin/pixoo-bridge.js --demo                     play the sample scenes on the Pixoo once (no Firebase)
//   node bin/pixoo-bridge.js --discover                 list Pixoo devices Divoom's cloud sees on this network

import { parseArgs } from "node:util";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { loadConfig, describe, secretsOf, ConfigError, BRIDGE_DIR } from "../src/config.js";
import { createLogger, makeRedactor } from "../src/log.js";
import { AssetStore } from "../src/assets.js";
import { PixelFont } from "../src/font.js";
import { Renderer } from "../src/render.js";
import { PixooClient, DryRunPixoo, endpointFor, discover } from "../src/pixoo.js";
import { FileDevice } from "../src/file-device.js";
import { createReadOnlyFirebase } from "../src/readonly.js";
import { Inbox } from "../src/inbox.js";
import { loadCursor, saveCursor } from "../src/cursor-file.js";
import { Bridge } from "../src/bridge.js";
import { sampleScenes } from "../src/samples.js";
import { writeGif, writeContactSheet } from "../src/preview.js";

const HELP = `用法 / usage:
  node bin/pixoo-bridge.js [--config 文件]          正式运行（只读 Firebase → Pixoo）
  node bin/pixoo-bridge.js --dry-run               正式运行，但不连 Pixoo，只在日志里打印要发的内容
  node bin/pixoo-bridge.js --preview [--out 目录]   用假消息把每种画面渲染成 GIF + contact-sheet.png（不需要 Pixoo 和 Firebase）
  node bin/pixoo-bridge.js --preview --live         真实消息，但写成 GIF 文件而不是发给 Pixoo
  node bin/pixoo-bridge.js --demo                  把示例画面在 Pixoo 上轮流放一遍（不需要 Firebase）
  node bin/pixoo-bridge.js --discover              列出 Divoom 云端看到的、和这台机器同一网络的 Pixoo
其他：--log-level debug|info|warn|error  --help`;

let redact = (s) => s;   // set once the config (and its secrets) is known

async function main() {
  const { values: a } = parseArgs({
    options: {
      config: { type: "string" }, preview: { type: "boolean" }, live: { type: "boolean" }, out: { type: "string" },
      "dry-run": { type: "boolean" }, demo: { type: "boolean" }, discover: { type: "boolean" },
      "log-level": { type: "string" }, help: { type: "boolean", short: "h" },
    },
  });
  if (a.help) { console.log(HELP); return 0; }

  const needFirebase = !a.discover && !a.demo && !(a.preview && !a.live);
  let cfg;
  try { cfg = loadConfig({ file: a.config, needFirebase }); }
  catch (e) {
    if (e instanceof ConfigError) { console.error(`配置有误：${e.message}`); return 2; }
    throw e;
  }
  redact = makeRedactor(secretsOf(cfg));
  const log = createLogger({ level: a["log-level"] ?? cfg.logLevel, secrets: secretsOf(cfg) });

  if (a.discover) {
    const list = await discover();
    if (!list.length) log.warn("Divoom 云端没有看到同一网络里的设备（设备要先在 Divoom App 里联网绑定）");
    for (const d of list) console.log(`${d.name}\t${d.ip}\tid=${d.id}`);
    return 0;
  }

  if (!existsSync(cfg.fontFile)) {
    log.error(`找不到字体 ${cfg.fontFile}：先运行 npm run fetch-font`);
    return 2;
  }
  const font = PixelFont.load(cfg.fontFile);
  const assets = new AssetStore({ assetsDir: cfg.assetsDir, cacheDir: cfg.cacheDir, log });
  const renderer = new Renderer({ assets, font, cfg });
  const outDir = resolve(a.out ?? join(BRIDGE_DIR, "out"));

  if (a.preview && !a.live) {
    const rows = [];
    for (const { name, title, scene } of sampleScenes(assets.manifest, cfg)) {
      const t0 = Date.now();
      const { segments } = await renderer.render(scene);
      writeGif(join(outDir, `${name}.gif`), segments);
      rows.push({ title: `${name} · ${title}`, segments });
      log.info(`preview: ${name}.gif (${segments.length} segment(s), ${segments.map((s) => s.frames.length).join("+")} frames, ${Date.now() - t0} ms)`);
    }
    await writeContactSheet(join(outDir, "contact-sheet.png"), rows, font);
    log.info(`preview: ${join(outDir, "contact-sheet.png")}`);
    return 0;
  }

  log.info("config:", describe(cfg));
  let device;
  if (a.preview && a.live) device = new FileDevice({ outDir, log });
  else if (a["dry-run"]) device = new DryRunPixoo({ log });
  else {
    const endpoint = endpointFor(cfg.pixoo);
    device = new PixooClient({ endpoint, deviceName: cfg.pixoo.deviceName, timeoutMs: cfg.pixoo.requestTimeoutMs, retries: cfg.pixoo.retries,
      requestGapMs: cfg.pixoo.requestGapMs, minAnimationGapMs: cfg.pixoo.minAnimationGapMs, log });
    try { await device.ping(); log.info("pixoo: reachable"); }
    catch (e) { log.warn(`pixoo: not reachable yet (${e.message}); will keep trying`); }
  }

  if (a.demo) {
    await device.setScreen(true);
    await device.setBrightness(cfg.brightness);
    for (const { name, scene } of sampleScenes(assets.manifest, cfg)) {
      const { segments } = await renderer.render(scene);
      for (const seg of segments) {
        await device.playAnimation(seg.frames, seg.frameMs, `${name}:${seg.label}`);
        await new Promise((r) => setTimeout(r, Number.isFinite(seg.holdMs) ? Math.min(seg.holdMs, 6000) : 5000));
      }
    }
    return 0;
  }

  const now = Date.now();
  const cur = loadCursor(cfg.stateFile, now);
  if (cur.fresh) { saveCursor(cfg.stateFile, cur.ts, now); log.info("cursor: first start (or unreadable file) → starting from now, no history replay"); }
  const inbox = new Inbox({ watchSeat: cfg.watchSeat, cursor: cur.ts, maxBacklog: cfg.maxBacklog });
  const fb = createReadOnlyFirebase({
    databaseURL: cfg.databaseURL,
    pairCode: cfg.pairCode,
    onViolation: (e) => log.error(`BUG: ${e.message} — blocked, nothing was written`),
  });
  const bridge = new Bridge({ cfg, fb, device, renderer, manifest: assets.manifest, inbox, log,
    persistCursor: (ts) => saveCursor(cfg.stateFile, ts, Date.now()) });

  let stopping = false;
  const stop = async (sig) => {
    if (stopping) return;
    stopping = true;
    log.info(`${sig}: stopping`);
    await bridge.stop();
    process.exit(0);
  };
  process.on("SIGINT", () => stop("SIGINT"));
  process.on("SIGTERM", () => stop("SIGTERM"));
  await bridge.start();
  log.info(`watching seat "${cfg.watchSeat}"`);
  return null;   // keep running
}

main().then((code) => { if (code != null) process.exit(code); }, (e) => {
  console.error(redact(e?.stack ?? String(e)));
  process.exit(1);
});
