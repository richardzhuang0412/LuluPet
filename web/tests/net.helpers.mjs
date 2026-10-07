// Shared helpers for web/tests/net.*.test.mjs: a fake Firebase (tools/fake_firebase.py --cors) on a random port,
// a fetch-based EventSource (Node has none without a flag), a fetch wrapper for fault injection, waitFor.
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { fileURLToPath } from "node:url";
import path from "node:path";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const FAKE = path.join(ROOT, "tools/fake_firebase.py");

export function freePort() {
  return new Promise((resolve, reject) => {
    const s = createServer();
    s.once("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

/** Starts the fake; resolves {url, port, stop(), restart()} once it listens. */
export async function startFake({ port, args = ["--cors"] } = {}) {
  port ??= await freePort();
  let proc;
  const launch = () => new Promise((resolve, reject) => {
    proc = spawn("python3", [FAKE, "--port", String(port), ...args], { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    const timer = setTimeout(() => reject(new Error("fake firebase did not start: " + out)), 5000);
    proc.stdout.on("data", (d) => {
      out += d;
      if (out.includes("fake firebase on")) { clearTimeout(timer); resolve(); }
    });
    proc.stderr.on("data", (d) => { out += d; });
    proc.once("exit", (code) => { clearTimeout(timer); if (!out.includes("fake firebase on")) reject(new Error(`fake exited ${code}: ${out}`)); });
  });
  const stop = () => new Promise((resolve) => {
    if (!proc || proc.exitCode !== null) return resolve();
    proc.once("exit", () => resolve());
    proc.kill("SIGKILL");
  });
  await launch();
  return {
    port,
    url: `http://127.0.0.1:${port}`,
    stop,
    async restart() { await stop(); await launch(); },
  };
}

export const testPairCode = () => "TESTWEB" + Math.random().toString(36).slice(2, 12).toUpperCase().padEnd(10, "X");

/** Raw REST helpers against the fake (test setup / assertions). */
export function rest(base, code) {
  const u = (p) => `${base}/pairs/${code}/${p}.json`;
  return {
    get: async (p) => (await fetch(u(p))).json(),
    put: async (p, v) => (await fetch(u(p), { method: "PUT", body: JSON.stringify(v) })).json(),
  };
}

/**
 * Minimal EventSource over fetch (named events, `data:` lines, onerror on failure / end; no auto-reconnect —
 * the feed never relies on it). `opened` records every URL, for asserting startAt.
 */
export function makeEventSource(opened = []) {
  return class FetchEventSource {
    constructor(url) {
      this.url = url;
      this.readyState = 0;
      this.listeners = new Map();
      this.onerror = null;
      this.ac = new AbortController();
      opened.push(url);
      this.run();
    }
    addEventListener(type, fn) {
      if (!this.listeners.has(type)) this.listeners.set(type, []);
      this.listeners.get(type).push(fn);
    }
    dispatch(type, data) {
      for (const fn of this.listeners.get(type) ?? []) fn({ type, data });
    }
    close() { this.readyState = 2; this.ac.abort(); }
    async run() {
      try {
        const res = await fetch(this.url, { headers: { Accept: "text/event-stream" }, signal: this.ac.signal });
        if (!res.ok || !(res.headers.get("content-type") || "").includes("text/event-stream")) throw new Error("bad response");
        this.readyState = 1;
        const dec = new TextDecoder();
        let buf = "", event = "message", data = [];
        for await (const chunk of res.body) {
          buf += dec.decode(chunk, { stream: true });
          let i;
          while ((i = buf.search(/\r?\n/)) >= 0) {
            const line = buf.slice(0, i);
            buf = buf.slice(i + (buf[i] === "\r" ? 2 : 1));
            if (line === "") {
              if (data.length && this.readyState !== 2) this.dispatch(event, data.join("\n"));
              event = "message"; data = [];
            } else if (line.startsWith("event:")) event = line.slice(6).trim();
            else if (line.startsWith("data:")) data.push(line.slice(5).replace(/^ /, ""));
          }
        }
        throw new Error("stream ended");
      } catch {
        if (this.readyState === 2) return;
        this.readyState = 2;
        this.onerror?.({ type: "error" });
      }
    }
  };
}

/** An EventSource that connects but never delivers anything (a proxy buffering SSE). */
export function makeSilentEventSource(opened = []) {
  return class SilentEventSource {
    constructor(url) { this.url = url; this.readyState = 1; this.onerror = null; opened.push(url); }
    addEventListener() {}
    close() { this.readyState = 2; }
  };
}

/**
 * fetch wrapper: `rule(url, init)` may return a Response / throw / return undefined (= real fetch).
 * `calls` records {method, url, body, keepalive}.
 */
export function faultyFetch(rule = () => undefined) {
  const calls = [];
  const f = async (url, init = {}) => {
    calls.push({ method: init.method ?? "GET", url: String(url), body: init.body, keepalive: !!init.keepalive });
    const r = await rule(String(url), init);
    if (r !== undefined) return r;
    return fetch(url, init);
  };
  f.calls = calls;
  f.setRule = (r) => { rule = r; };
  return f;
}

export async function waitFor(pred, { timeout = 5000, step = 20, what = "condition" } = {}) {
  const end = Date.now() + timeout;
  for (;;) {
    const v = await pred();
    if (v) return v;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, step));
  }
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Records every channel event as {type, detail}. */
export function record(ch, types = ["connection", "message", "backlog", "folded", "partner", "mySeat", "parked", "sent", "own"]) {
  const log = [];
  for (const t of types) ch.addEventListener(t, (e) => log.push({ type: t, detail: e.detail }));
  log.of = (t) => log.filter((x) => x.type === t).map((x) => x.detail);
  return log;
}

/** Fast timings for tests. */
export const FAST = {
  seatCheckMs: 150,
  heartbeatMs: 300,
  partnerPollMs: 150,
  outboxRetryMs: 150,
  cursorWriteMs: 600,
  feed: { backoffMinMs: 100, backoffMaxMs: 400, misconfiguredRetryMs: 500, firstPutTimeoutMs: 2000, pollVisibleMs: 150, pollHiddenMs: 300, sseRetryMs: 60_000, idleTimeoutMs: 10_000 },
};

/** A message as Mac 0.16.0 writes it (Message.firebasePayload). */
export const macMsg = (from, ts, extra = {}) => ({ from, kind: "text", text: "hi " + ts, ts, v: 1, character: from, trip: "local", ...extra });
