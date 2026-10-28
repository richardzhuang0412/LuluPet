// Test helpers: a tiny synthetic BDF font (no download needed), a recording fetch, the repo paths.
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { readFileSync } from "node:fs";

export const BRIDGE = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const REPO = resolve(BRIDGE, "../..");
export const ASSETS = resolve(REPO, "web/assets");
export const manifest = () => JSON.parse(readFileSync(resolve(ASSETS, "manifest.json"), "utf8"));

/** BDF with: space (dw 5), ASCII letters/digits/punctuation (5×7, dw 6), any CJK passed (9×9, dw 10), … , notdef. */
export function fixtureBDF(cjk = "你好今天吃什么想啦喝水") {
  const glyphs = [];
  const add = (cp, dw, w, h, xo, yo, rowHex) => glyphs.push(
    `STARTCHAR u${cp.toString(16)}\nENCODING ${cp}\nSWIDTH 1000 0\nDWIDTH ${dw} 0\nBBX ${w} ${h} ${xo} ${yo}\nBITMAP\n${Array(h).fill(rowHex).join("\n")}\nENDCHAR`);
  add(65534, 10, 9, 9, 0, -1, "FF80");
  add(0x20, 5, 0, 0, 0, 0, "00");
  for (let c = 0x21; c < 0x7f; c++) add(c, 6, 5, 7, 0, 0, "F8");
  add(0x2026, 10, 8, 2, 1, 2, "DB");
  for (const ch of cjk) add(ch.codePointAt(0), 10, 9, 9, 0, -1, "FF80");
  return `STARTFONT 2.1\nFONT fixture\nSIZE 10 75 75\nFONTBOUNDINGBOX 10 14 0 -3\nSTARTPROPERTIES 3\nFONT_ASCENT 11\nFONT_DESCENT 3\nDEFAULT_CHAR 65534\nENDPROPERTIES\nCHARS ${glyphs.length}\n${glyphs.join("\n")}\nENDFONT\n`;
}

export function recordingFetch(handler = () => new Response("null", { status: 200 })) {
  const calls = [];
  const f = async (url, init = {}) => {
    calls.push({ url: String(url), method: (init.method ?? "GET").toUpperCase(), body: init.body });
    return handler(url, init);
  };
  f.calls = calls;
  return f;
}

export async function waitFor(pred, ms = 5000, step = 20) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await pred()) return true;
    await new Promise((r) => setTimeout(r, step));
  }
  throw new Error("waitFor timed out");
}
