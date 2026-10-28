// Divoom Pixoo-64 local HTTP API client.
//
// Verified (2026-10-27) against Divoom's official API doc (ShowDoc at http://docin.divoom-gz.com/web/#/5/…, read via
// its JSON API: POST http://docin.divoom-gz.com/server/index.php?s=/api/page/info, page_id below) and two widely used
// open-source clients — SomethingWithComputers/pixoo (src/pixoo/objects/pixoo.py) and 4ch1m/pixoo-rest
// (pixoo_rest/helpers.py):
//   - Every command: HTTP POST of a JSON body {"Command": "...", …} to http://<ip>:80/post (doc page 24 "command
//     format"; the doc adds: hardware version 96 uses http://<ip>:9000/divoom_api instead → `pixoo.url`).
//     Reply: {"error_code": 0, …}; non-zero = failure.
//   - Draw/SendHttpGif (page 57): one request per frame. PicNum = frame count, "smaller than 60"; PicWidth 16/32/64;
//     PicOffset 0…PicNum-1, sent in order; PicID = animation id; PicSpeed = ms per frame (one speed for the whole
//     animation); PicData = base64 of the raw RGB bytes, left→right, top→bottom (64*64*3 = 12288 bytes → 16384 chars).
//     The device loops the animation once all frames arrived.
//   - Draw/GetHttpGifId (page 55): {"PicId": n} = the next id (firmware ≥ 90095).
//   - Draw/ResetHttpGifId (page 56): ids start again at 1.
//   - Channel/SetBrightness (page 36): {"Brightness": 0…100}. Channel/OnOffScreen (page 41): {"OnOff": 1 | 0}.
//   - Channel/GetAllConf (page 37): used as a cheap "are you there" (SomethingWithComputers does the same).
//   - Discovery (page 25): POST https://app.divoom-gz.com/Device/ReturnSameLANDevice (no body) →
//     {"ReturnCode": 0, "DeviceList": [{"DeviceName", "DeviceId", "DevicePrivateIP", "DeviceMac"}]}: Divoom's cloud
//     lists the devices that registered from the same public IP.
// Known limits from those clients: SomethingWithComputers' README — the display stops responding after ~300 pushes
// unless the gif id is reset ("refresh_connection_automatically" resets every 32 ids), and it warns not to push more
// than about once per second. pixoo-rest resets (Draw/ResetHttpGifId) before every animation, sends PicID 1 and caps
// GIFs at 59 frames. We do the same: reset before every animation, PicID 1, ≤ 40 frames, one request at a time
// with a small gap, ≥ 1 s between animations.

export const PIC_WIDTH = 64;
export const FRAME_BYTES = PIC_WIDTH * PIC_WIDTH * 3;
export const MAX_PIC_NUM = 59;
export const DISCOVERY_URL = "https://app.divoom-gz.com/Device/ReturnSameLANDevice";

export class PixooError extends Error {
  constructor(message, { code = null, status = null } = {}) {
    super(message);
    this.name = "PixooError";
    this.code = code;
    this.status = status;
  }
}

export function frameToBase64(frame) {
  if (!(frame instanceof Uint8Array) || frame.length !== FRAME_BYTES) {
    throw new PixooError(`frame must be ${FRAME_BYTES} RGB bytes, got ${frame?.length}`);
  }
  return Buffer.from(frame.buffer, frame.byteOffset, frame.length).toString("base64");
}

/** The Draw/SendHttpGif bodies for one animation, in send order. */
export function buildGifPayloads(frames, frameMs, picId = 1) {
  if (!frames.length) throw new PixooError("no frames");
  if (frames.length > MAX_PIC_NUM) throw new PixooError(`too many frames (${frames.length} > ${MAX_PIC_NUM})`);
  const speed = Math.max(1, Math.round(frameMs));
  return frames.map((f, i) => ({
    Command: "Draw/SendHttpGif",
    PicNum: frames.length,
    PicWidth: PIC_WIDTH,
    PicOffset: i,
    PicID: picId,
    PicSpeed: speed,
    PicData: frameToBase64(f),
  }));
}

export function endpointFor({ url, ip }) {
  if (url) return url;
  if (!ip) return null;
  return /^https?:\/\//.test(ip) ? ip : `http://${ip}/post`;
}

/** Summary of a command for logs (never the pixel data). */
export function describeCommand(body) {
  if (body.Command === "Draw/SendHttpGif") return `SendHttpGif ${body.PicOffset + 1}/${body.PicNum} id=${body.PicID} speed=${body.PicSpeed}ms data=${body.PicData.length}b64`;
  const { Command, ...rest } = body;
  return `${Command}${Object.keys(rest).length ? " " + JSON.stringify(rest) : ""}`;
}

/** Ask Divoom's cloud for Pixoo devices on this LAN. → [{name, id, ip, mac}] */
export async function discover({ fetch: fetchImpl = globalThis.fetch, timeoutMs = 8000 } = {}) {
  const res = await fetchImpl(DISCOVERY_URL, { method: "POST", signal: AbortSignal.timeout(timeoutMs) });
  if (!res.ok) throw new PixooError(`discovery HTTP ${res.status}`, { status: res.status });
  const data = await res.json();
  if (data?.ReturnCode !== 0) throw new PixooError(`discovery ReturnCode ${data?.ReturnCode}`, { code: data?.ReturnCode });
  return (data.DeviceList ?? []).map((d) => ({ name: d.DeviceName, id: d.DeviceId, ip: d.DevicePrivateIP, mac: d.DeviceMac }));
}

export function pickDevice(list, deviceName = "") {
  const want = deviceName.toLowerCase();
  return list.find((d) => want && String(d.name ?? "").toLowerCase().includes(want))
    ?? list.find((d) => /pixoo\s*-?64/i.test(String(d.name ?? "")))
    ?? list[0] ?? null;
}

const sleep = (ms, signal) => new Promise((resolve) => {
  if (ms <= 0) return resolve();
  const t = setTimeout(resolve, ms);
  signal?.addEventListener?.("abort", () => { clearTimeout(t); resolve(); }, { once: true });
});

/**
 * One Pixoo. All requests go through one queue (the device's HTTP server is small: never two at once).
 * `endpoint` may be null with `discover: true` (looked up on first use and again after repeated failures).
 */
export class PixooClient {
  constructor({ endpoint = null, deviceName = "", timeoutMs = 5000, retries = 2, requestGapMs = 30, minAnimationGapMs = 1000,
    fetch: fetchImpl = globalThis.fetch, discoverFn = discover, log }) {
    this.endpoint = endpoint;
    this.autoDiscover = !endpoint;
    this.deviceName = deviceName;
    this.timeoutMs = timeoutMs;
    this.retries = retries;
    this.requestGapMs = requestGapMs;
    this.minAnimationGapMs = minAnimationGapMs;
    this.fetch = fetchImpl;
    this.discoverFn = discoverFn;
    this.log = log;
    this.chain = Promise.resolve();
    this.lastAnimationEnd = 0;
    this.failures = 0;
    this.gen = 0;
    this.stats = { requests: 0, failures: 0, animations: 0 };
  }

  /** Serializes `fn` after everything queued before it. */
  enqueue(fn) {
    const run = this.chain.then(fn, fn);
    this.chain = run.catch(() => {});
    return run;
  }

  async ensureEndpoint() {
    if (this.endpoint) return this.endpoint;
    if (!this.autoDiscover) throw new PixooError("no Pixoo address");
    const list = await this.discoverFn({ fetch: this.fetch });
    const dev = pickDevice(list, this.deviceName);
    if (!dev?.ip) throw new PixooError(`discovery found no device${list.length ? ` (saw ${list.map((d) => d.name).join(", ")})` : ""}`);
    this.endpoint = `http://${dev.ip}/post`;
    this.log?.info(`pixoo: discovered "${dev.name}" at ${dev.ip}`);
    return this.endpoint;
  }

  /** One command with timeout + retries. → reply JSON. Not queued: callers inside the queue use it. */
  async rawCommand(body) {
    let lastErr;
    for (let attempt = 0; attempt <= this.retries; attempt++) {
      if (attempt) await sleep(300 * 2 ** (attempt - 1));
      const t0 = Date.now();
      try {
        const url = await this.ensureEndpoint();
        this.stats.requests++;
        const res = await this.fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(this.timeoutMs),
        });
        if (!res.ok) throw new PixooError(`HTTP ${res.status}`, { status: res.status });
        const text = await res.text();
        let data;
        try { data = JSON.parse(text); } catch { throw new PixooError(`bad reply: ${text.slice(0, 80)}`); }
        if (data?.error_code !== 0 && data?.error_code !== undefined) throw new PixooError(`error_code ${data.error_code}`, { code: data.error_code });
        this.log?.debug(`pixoo ← ${describeCommand(body)} ok (${Date.now() - t0} ms)`);
        this.failures = 0;
        return data;
      } catch (e) {
        lastErr = e instanceof PixooError ? e : new PixooError(e?.name === "TimeoutError" ? `timeout after ${this.timeoutMs} ms` : (e?.cause?.code ?? e?.message ?? String(e)));
        this.stats.failures++;
        this.log?.warn(`pixoo ✗ ${describeCommand(body)} attempt ${attempt + 1}/${this.retries + 1}: ${lastErr.message}`);
      }
    }
    this.failures++;
    if (this.autoDiscover && this.failures >= 3) {
      this.log?.warn("pixoo: repeated failures, will look the device up again");
      this.endpoint = null;
      this.failures = 0;
    }
    throw lastErr;
  }

  command(body) { return this.enqueue(() => this.rawCommand(body)); }

  setBrightness(value) { return this.command({ Command: "Channel/SetBrightness", Brightness: Math.max(0, Math.min(100, Math.round(value))) }); }
  setScreen(on) { return this.command({ Command: "Channel/OnOffScreen", OnOff: on ? 1 : 0 }); }
  getHttpGifId() { return this.command({ Command: "Draw/GetHttpGifId" }); }
  ping() { return this.command({ Command: "Channel/GetAllConf" }); }

  /**
   * Uploads one animation: ResetHttpGifId, then PicNum SendHttpGif requests (PicID 1). A newer `playAnimation`
   * call supersedes an upload still waiting in the queue (it is skipped) or in progress (it stops between frames).
   * → true when fully uploaded, false when superseded.
   */
  playAnimation(frames, frameMs, label = "") {
    const gen = ++this.gen;
    const payloads = buildGifPayloads(frames, frameMs, 1);
    return this.enqueue(async () => {
      if (gen !== this.gen) { this.log?.debug(`pixoo: skip superseded "${label}"`); return false; }
      const wait = this.lastAnimationEnd + this.minAnimationGapMs - Date.now();
      if (wait > 0) await sleep(wait);
      const t0 = Date.now();
      try {
        await this.rawCommand({ Command: "Draw/ResetHttpGifId" });
        for (const p of payloads) {
          if (gen !== this.gen) { this.log?.info(`pixoo: "${label}" superseded after ${p.PicOffset}/${p.PicNum} frames`); return false; }
          await this.rawCommand(p);
          if (this.requestGapMs) await sleep(this.requestGapMs);
        }
        this.stats.animations++;
        this.log?.info(`pixoo: showing "${label}" (${payloads.length} frames × ${payloads[0].PicSpeed} ms, upload ${Date.now() - t0} ms)`);
        return true;
      } finally {
        this.lastAnimationEnd = Date.now();
      }
    });
  }
}

/** Same interface, no network: logs what it would send (`--dry-run`). */
export class DryRunPixoo {
  constructor({ log }) { this.log = log; this.sent = []; }
  async setBrightness(v) { this.log?.info(`dry-run: Channel/SetBrightness ${v}`); this.sent.push(["brightness", v]); }
  async setScreen(on) { this.log?.info(`dry-run: Channel/OnOffScreen ${on ? 1 : 0}`); this.sent.push(["screen", on]); }
  async ping() { return { error_code: 0 }; }
  async playAnimation(frames, frameMs, label = "") {
    const payloads = buildGifPayloads(frames, frameMs, 1);
    this.log?.info(`dry-run: Draw/ResetHttpGifId + ${payloads.length}× Draw/SendHttpGif (${payloads[0].PicSpeed} ms/frame, ${payloads[0].PicData.length} b64 chars each) "${label}"`);
    this.sent.push(["animation", label, payloads.length]);
    return true;
  }
}
