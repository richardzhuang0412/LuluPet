// A stand-in Pixoo-64 HTTP server for tests and `npm run mock-pixoo` (no device needed). It checks every request
// the way the docs describe the real one (see pixoo.js) and collects complete animations.

import { createServer } from "node:http";
import { EventEmitter } from "node:events";

const KNOWN = new Set(["Draw/SendHttpGif", "Draw/ResetHttpGifId", "Draw/GetHttpGifId", "Channel/SetBrightness",
  "Channel/OnOffScreen", "Channel/GetAllConf"]);

export class MockPixoo extends EventEmitter {
  constructor({ failFirst = 0, delayMs = 0, path = "/post" } = {}) {
    super();
    this.failFirst = failFirst;
    this.delayMs = delayMs;
    this.path = path;
    this.commands = [];      // every accepted command, PicData replaced by its decoded length
    this.errors = [];        // protocol violations seen
    this.animations = [];    // [{picId, speed, frames: [Buffer]}]
    this.brightness = null;
    this.screenOn = true;
    this.nextId = 1;
    this.current = null;
    this.server = createServer((req, res) => this.handle(req, res));
  }

  listen(port = 0, host = "127.0.0.1") {
    return new Promise((resolve) => this.server.listen(port, host, () => {
      this.port = this.server.address().port;
      this.url = `http://${host}:${this.port}${this.path}`;
      resolve(this);
    }));
  }

  close() { return new Promise((r) => { this.server.closeAllConnections?.(); this.server.close(() => r()); }); }

  violation(msg) { this.errors.push(msg); this.emit("violation", msg); }

  handle(req, res) {
    let body = "";
    req.on("data", (c) => { body += c; });
    req.on("end", async () => {
      if (this.delayMs) await new Promise((r) => setTimeout(r, this.delayMs));
      const reply = (obj, status = 200) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(JSON.stringify(obj)); };
      if (req.method !== "POST" || req.url !== this.path) { this.violation(`${req.method} ${req.url}`); return reply({ error_code: 1 }, 404); }
      if (this.failFirst > 0) { this.failFirst--; return reply({ error_code: 1 }, 500); }
      let cmd;
      try { cmd = JSON.parse(body); } catch { this.violation("body is not JSON"); return reply({ error_code: 1 }); }
      if (!KNOWN.has(cmd.Command)) { this.violation(`unknown command ${cmd.Command}`); return reply({ error_code: 1 }); }
      const logged = { ...cmd };
      if (typeof cmd.PicData === "string") logged.PicData = Buffer.from(cmd.PicData, "base64").length;
      this.commands.push(logged);
      this.emit("command", logged);
      switch (cmd.Command) {
        case "Draw/ResetHttpGifId": this.nextId = 1; this.current = null; return reply({ error_code: 0 });
        case "Draw/GetHttpGifId": return reply({ error_code: 0, PicId: this.nextId });
        case "Channel/SetBrightness":
          if (!(cmd.Brightness >= 0 && cmd.Brightness <= 100)) this.violation(`brightness ${cmd.Brightness}`);
          this.brightness = cmd.Brightness; return reply({ error_code: 0 });
        case "Channel/OnOffScreen":
          if (cmd.OnOff !== 0 && cmd.OnOff !== 1) this.violation(`OnOff ${cmd.OnOff}`);
          this.screenOn = cmd.OnOff === 1; return reply({ error_code: 0 });
        case "Channel/GetAllConf": return reply({ error_code: 0, Brightness: this.brightness ?? 50, LightSwitch: this.screenOn ? 1 : 0 });
        case "Draw/SendHttpGif": return reply(this.frame(cmd));
      }
    });
  }

  frame(cmd) {
    const { PicNum, PicWidth, PicOffset, PicID, PicSpeed, PicData } = cmd;
    if (!(Number.isInteger(PicNum) && PicNum >= 1 && PicNum < 60)) this.violation(`PicNum ${PicNum}`);
    if (PicWidth !== 64) this.violation(`PicWidth ${PicWidth}`);
    if (!(Number.isInteger(PicSpeed) && PicSpeed > 0)) this.violation(`PicSpeed ${PicSpeed}`);
    if (!(Number.isInteger(PicID) && PicID >= this.nextId - 1 && PicID >= 1)) this.violation(`PicID ${PicID} (next ${this.nextId})`);
    const data = Buffer.from(String(PicData ?? ""), "base64");
    if (data.length !== 64 * 64 * 3) this.violation(`PicData ${data.length} bytes`);
    if (PicOffset === 0) this.current = { picId: PicID, num: PicNum, speed: PicSpeed, frames: [] };
    const cur = this.current;
    if (!cur || cur.picId !== PicID || cur.num !== PicNum || PicOffset !== cur.frames.length) {
      this.violation(`out of order: offset ${PicOffset}, id ${PicID}, expected ${cur ? cur.frames.length : 0}`);
      return { error_code: 1 };
    }
    cur.frames.push(data);
    if (cur.frames.length === cur.num) {
      this.animations.push(cur);
      this.nextId = Math.max(this.nextId, PicID + 1);
      this.current = null;
      this.emit("animation", cur);
    }
    return { error_code: 0 };
  }
}
