// `--preview --live`: the device interface, but every animation is written as a GIF into a folder.

import { join } from "node:path";
import { writeGif } from "./preview.js";

export class FileDevice {
  constructor({ outDir, log }) {
    this.outDir = outDir;
    this.log = log;
    this.n = 0;
  }
  async setBrightness(v) { this.log?.info(`file-device: brightness ${v}`); }
  async setScreen(on) { this.log?.info(`file-device: screen ${on ? "on" : "off"}`); }
  async ping() { return { error_code: 0 }; }
  async playAnimation(frames, frameMs, label = "") {
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    const name = `${String(++this.n).padStart(4, "0")}-${stamp}-${label.replace(/[^\w.-]+/g, "_").slice(0, 40)}.gif`;
    const path = join(this.outDir, name);
    writeGif(path, [{ frames, frameMs, holdMs: frames.length * frameMs * 2 }]);
    this.log?.info(`file-device: wrote ${path} (${frames.length} frames × ${frameMs} ms)`);
    return true;
  }
}
