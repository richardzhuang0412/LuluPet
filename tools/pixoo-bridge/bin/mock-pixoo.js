#!/usr/bin/env node
// A fake Pixoo-64 on this machine, for trying the bridge without the device:
//   node bin/mock-pixoo.js [--port 8090] [--out DIR]
// then set "pixoo": {"ip": "127.0.0.1:8090"} in the config. Every complete animation is logged (and saved as a GIF
// with --out).

import { parseArgs } from "node:util";
import { join } from "node:path";
import { MockPixoo } from "../src/mock-pixoo.js";
import { writeGif } from "../src/preview.js";

const { values: a } = parseArgs({ options: { port: { type: "string", default: "8090" }, out: { type: "string" } } });
const dev = await new MockPixoo().listen(Number(a.port));
console.log(`mock Pixoo on ${dev.url}`);
let n = 0;
dev.on("command", (c) => { if (c.Command !== "Draw/SendHttpGif") console.log(new Date().toISOString(), c.Command, JSON.stringify({ ...c, Command: undefined })); });
dev.on("violation", (v) => console.log(new Date().toISOString(), "PROTOCOL VIOLATION:", v));
dev.on("animation", (anim) => {
  n++;
  console.log(new Date().toISOString(), `animation #${n}: ${anim.frames.length} frames × ${anim.speed} ms`);
  if (a.out) {
    const frames = anim.frames.map((b) => new Uint8Array(b));
    writeGif(join(a.out, `mock-${String(n).padStart(4, "0")}.gif`), [{ frames, frameMs: anim.speed, holdMs: frames.length * anim.speed * 2 }]);
  }
});
process.on("SIGINT", async () => { await dev.close(); process.exit(0); });
process.on("SIGTERM", async () => { await dev.close(); process.exit(0); });
