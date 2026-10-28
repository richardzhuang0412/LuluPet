#!/usr/bin/env node
// Downloads the pixel font used for Chinese text (not committed to the repo):
//   Fusion Pixel Font 10px proportional, zh_hans, BDF — https://github.com/TakWolf/fusion-pixel-font
//   License: SIL Open Font License 1.1 (OFL.txt is saved next to the font, as the license asks).
// The release is pinned and its SHA-256 checked, so every install gets the same glyphs.
//
//   node scripts/fetch-font.js [--zip already-downloaded.zip]

import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { unzipSync } from "fflate";

const VERSION = "2026.10.25";
const ZIP = `fusion-pixel-font-10px-proportional-bdf-v${VERSION}.zip`;
const URL_ = `https://github.com/TakWolf/fusion-pixel-font/releases/download/${VERSION}/${ZIP}`;
const SHA256 = "2e99179e2e9cd1f1cf20f3a0c312ea4d1144a71aa5f020cc57894c398dc0573b";
const WANT = {
  "fusion-pixel-10px-proportional-zh_hans.bdf": "fusion-pixel-10px-proportional-zh_hans.bdf",
  "OFL.txt": "OFL.txt",
  "LICENSES/ark-pixel/OFL.txt": "LICENSES/ark-pixel/OFL.txt",
  "LICENSES/boutique-bitmap-9x9/OFL.txt": "LICENSES/boutique-bitmap-9x9/OFL.txt",
  "LICENSES/galmuri/LICENSE.txt": "LICENSES/galmuri/LICENSE.txt",
};

const outDir = join(dirname(fileURLToPath(import.meta.url)), "..", "fonts");

async function main() {
  const i = process.argv.indexOf("--zip");
  let zip;
  if (i > 0) zip = readFileSync(process.argv[i + 1]);
  else {
    if (existsSync(join(outDir, "fusion-pixel-10px-proportional-zh_hans.bdf"))) {
      console.log("字体已经在 fonts/ 里了 / font already present");
      return;
    }
    console.log(`下载 / downloading ${URL_}`);
    const res = await fetch(URL_, { redirect: "follow", signal: AbortSignal.timeout(300_000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    zip = Buffer.from(await res.arrayBuffer());
  }
  const sum = createHash("sha256").update(zip).digest("hex");
  if (sum !== SHA256) throw new Error(`SHA-256 不对 / mismatch: ${sum}`);
  const files = unzipSync(new Uint8Array(zip), { filter: (f) => f.name in WANT });
  for (const [name, dest] of Object.entries(WANT)) {
    if (!files[name]) throw new Error(`压缩包里没有 / missing in zip: ${name}`);
    const p = join(outDir, dest);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, files[name]);
  }
  console.log(`好了 / done: ${outDir}`);
}

main().catch((e) => { console.error(`字体下载失败 / font download failed: ${e.message}`); process.exit(1); });
