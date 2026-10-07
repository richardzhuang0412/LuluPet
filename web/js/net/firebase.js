// Firebase Realtime Database REST client for one pair (port of LuluSync/FirebaseClient.swift) plus the message
// feed: an EventSource stream with our own reconnect backoff, a watchdog and a polling fallback (spec §2.3).
// Paths are relative to /pairs/<code>/ ("messages", "messages/<key>", "presence/lulu", "read/lulu").

import { backoffAfter } from "./_shim_core.js";   // TEMP → ../core/wire.js

export const SEND_TIMEOUT_MS = 20_000;       // FirebaseClient.sendTimeout
export const PRESENCE_TIMEOUT_MS = 10_000;   // FirebaseClient.presenceTimeout

export class FirebaseError extends Error {
  /** kind: "http" (status set) | "network" | "timeout" | "cancelled" (stream cancel / auth_revoked) | "badURL" */
  constructor(kind, status = null) {
    super(status ? `HTTP ${status}` : kind);
    this.name = "FirebaseError";
    this.kind = kind;
    this.status = status;
  }
}

/** `<base>/pairs/<code>/<path>.json?<query>`; `query` must already be percent-encoded. */
export function buildURL(databaseURL, pairCode, path, query) {
  let base = String(databaseURL ?? "").trim();
  while (base.endsWith("/")) base = base.slice(0, -1);
  if (!/^https?:\/\/[^/?#]+$/.test(base)) throw new FirebaseError("badURL");
  const segs = String(path).split("/").filter(Boolean).map(encodeURIComponent).join("/");
  let s = `${base}/pairs/${encodeURIComponent(pairCode)}/${segs}.json`;
  if (query) s += "?" + query;
  return s;
}

/** `orderBy="ts"&startAt=<cursor+1>` (numbers unquoted), like `FirebaseClient.messageStreamURL`. */
export const messagesQuery = (cursor) => `orderBy=%22ts%22&startAt=${Math.trunc(cursor) + 1}`;

/** Chinese reason when retrying quickly is pointless (same wording as `PairChannel.misconfigurationReason`), else null. */
export function misconfigurationReason(err) {
  if (!(err instanceof FirebaseError)) return null;
  if (err.kind === "http") {
    if (err.status === 401 || err.status === 403) return `数据库规则拒绝访问 (HTTP ${err.status})`;
    if (err.status === 404) return "数据库地址有误 (HTTP 404)";
    if (err.status === 400) return "数据库规则缺少 ts 索引 (HTTP 400)";
    return null;
  }
  if (err.kind === "cancelled") return "数据库规则拒绝访问";
  if (err.kind === "badURL") return "数据库地址格式有误";
  return null;
}

/**
 * REST client. `fetch` / `EventSource` are injectable (tests; Node has no EventSource).
 *   get(path, {query, timeoutMs})            → parsed JSON (null = nothing there)
 *   put(path, body, {timeoutMs, keepalive})  → echoed body
 *   patch(path, body, {timeoutMs, keepalive})
 *   openEventSource(path, query)             → EventSource
 * Errors are FirebaseError.
 */
export function createFirebase({ databaseURL, pairCode, fetch: fetchImpl, EventSource: ESImpl } = {}) {
  const doFetch = fetchImpl ?? globalThis.fetch?.bind(globalThis);
  const ES = ESImpl ?? globalThis.EventSource;
  const url = (path, query) => buildURL(databaseURL, pairCode, path, query);

  async function request(method, path, { body, query, timeoutMs = PRESENCE_TIMEOUT_MS, keepalive = false } = {}) {
    const u = url(path, query);
    const init = {
      method,
      cache: "no-store",
      credentials: "omit",
      referrerPolicy: "no-referrer",
      signal: AbortSignal.timeout(timeoutMs),
    };
    if (keepalive) init.keepalive = true;
    if (body !== undefined) {
      init.headers = { "Content-Type": "application/json" };
      init.body = JSON.stringify(body);
    }
    let res, text;
    try {
      res = await doFetch(u, init);
      text = await res.text();
    } catch (e) {
      throw new FirebaseError(e?.name === "TimeoutError" || e?.name === "AbortError" ? "timeout" : "network");
    }
    if (!res.ok) throw new FirebaseError("http", res.status);
    if (!text) return null;
    try { return JSON.parse(text); } catch { throw new FirebaseError("network"); }
  }

  return {
    url,
    get: (path, opts = {}) => request("GET", path, opts),
    put: (path, body, opts = {}) => request("PUT", path, { ...opts, body }),
    patch: (path, body, opts = {}) => request("PATCH", path, { ...opts, body }),
    openEventSource(path, query) {
      if (typeof ES !== "function") throw new FirebaseError("network");
      return new ES(url(path, query));
    },
  };
}

/** Feed timing (ms). Tests shorten these. */
export const FEED_TIMING = Object.freeze({
  backoffMinMs: 1000,          // StreamBackoff: 1 s, doubling …
  backoffMaxMs: 30_000,        // … up to 30 s
  misconfiguredRetryMs: 60_000,
  idleTimeoutMs: 90_000,       // watchdog: no event at all for 90 s → reconnect
  firstPutTimeoutMs: 20_000,   // stream open but no first `put` (proxy buffering SSE) → polling
  pollVisibleMs: 15_000,
  pollHiddenMs: 30_000,
  sseRetryMs: 600_000,         // while polling, try the stream again every 10 min
  failedOpensBeforePolling: 3, // stream fails at once N times in a row while a plain GET works → polling
});

/**
 * The partner's messages, as batches of raw children (`{key: value}`, undecoded):
 *   onBatch(children, backlog)  backlog = true for a path-"/" put/patch (first put of a connection = what arrived
 *                               while away) and for the first poll; false for single live children / later polls.
 *   onState(state, reason)      "connected" | "polling" | "offline" | "misconfigured" (reason = Chinese text)
 * `since()` gives the read cursor at each (re)connect / poll, so a reconnect never replays what was read.
 * EventSource's own auto-reconnect is never used (it would reuse the old startAt): on error we close and reopen.
 */
export class MessageFeed {
  constructor({ fb, since, onBatch, onState, sched, timing = {}, isHidden }) {
    this.fb = fb;
    this.since = since;
    this.onBatch = onBatch;
    this.onState = onState;
    this.sched = sched;
    this.t = { ...FEED_TIMING, ...timing };
    this.isHidden = isHidden ?? (() => typeof document !== "undefined" && document.visibilityState === "hidden");
    this.running = false;
    this.mode = "stream";   // "stream" | "polling"
    this.gen = 0;
    this.es = null;
    this.timers = new Set();
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.mode = "stream";
    this.backoffMs = this.t.backoffMinMs;
    this.failedOpens = 0;
    this.connect(false);
  }

  stop() {
    this.running = false;
    this.gen++;
    this.closeES();
    for (const h of this.timers) this.sched.clearTimeout(h);
    this.timers.clear();
  }

  /** Something changed (tab visible again, network back): poll now / reconnect now instead of waiting. */
  nudge() {
    if (!this.running) return;
    if (this.mode === "polling" && !this.es) { this.clearTimers(); this.pollNow(); this.armTrial(); }
    else if (!this.es) { this.clearTimers(); this.connect(false); }
  }

  get state() { return this.lastState ?? null; }

  // ---- internals ----

  later(fn, ms) {
    const h = this.sched.setTimeout(() => { this.timers.delete(h); fn(); }, ms);
    this.timers.add(h);
    return h;
  }
  cancel(h) { if (h != null) { this.sched.clearTimeout(h); this.timers.delete(h); } }
  clearTimers() { for (const h of this.timers) this.sched.clearTimeout(h); this.timers.clear(); }

  setState(state, reason = null) {
    if (this.lastState === state && this.lastReason === reason) return;
    this.lastState = state;
    this.lastReason = reason;
    this.onState?.(state, reason);
  }

  closeES() {
    if (!this.es) return;
    const es = this.es;
    this.es = null;
    es.onerror = null;
    try { es.close(); } catch { /* ignore */ }
  }

  /** One stream connection. `trial` = an attempt to leave polling mode (failure goes back to polling quietly). */
  connect(trial) {
    if (!this.running) return;
    this.closeES();
    const gen = ++this.gen;
    const c = { began: this.sched.now(), gotEvent: false, gotPut: false, trial, idle: null, firstPut: null };
    let es;
    try {
      es = this.fb.openEventSource("messages", messagesQuery(this.since()));
    } catch (e) {
      this.ended(gen, c, e instanceof FirebaseError && e.kind === "badURL" ? e : new FirebaseError("network"));
      return;
    }
    this.es = es;
    const alive = () => gen === this.gen && this.running;
    const activity = () => {
      c.gotEvent = true;
      this.cancel(c.idle);
      c.idle = this.later(() => alive() && this.ended(gen, c, new FirebaseError("timeout")), this.t.idleTimeoutMs);
    };
    const onData = (name) => (ev) => {
      if (!alive()) return;
      activity();
      let env;
      try { env = JSON.parse(ev.data); } catch { return; }
      if (!env || typeof env.path !== "string") return;
      if (!c.gotPut && name === "put") {
        c.gotPut = true;
        this.cancel(c.firstPut);
        this.mode = "stream";
        this.failedOpens = 0;
        this.setState("connected");
      }
      const parts = env.path.split("/").filter(Boolean);
      const data = env.data;
      if (parts.length === 0) {
        this.onBatch(data && typeof data === "object" && !Array.isArray(data) ? data : {}, true);
      } else if (parts.length === 1 && data && typeof data === "object" && !Array.isArray(data)) {
        this.onBatch({ [parts[0]]: data }, false);
      }
      // deeper paths: nested field updates, never written by any client → ignored
    };
    es.addEventListener("put", onData("put"));
    es.addEventListener("patch", onData("patch"));
    es.addEventListener("keep-alive", () => alive() && activity());
    const revoked = () => alive() && this.ended(gen, c, new FirebaseError("cancelled"));
    es.addEventListener("cancel", revoked);
    es.addEventListener("auth_revoked", revoked);
    es.onerror = () => alive() && this.ended(gen, c, new FirebaseError("network"));
    c.firstPut = this.later(() => alive() && !c.gotPut && this.noFirstPut(gen, c), this.t.firstPutTimeoutMs);
    c.idle = this.later(() => alive() && this.ended(gen, c, new FirebaseError("timeout")), this.t.idleTimeoutMs);
  }

  /** The stream is open but silent: something (a corporate proxy) buffers it. */
  noFirstPut(gen, c) {
    this.gen++;
    this.closeES();
    this.cancel(c.idle);
    this.enterPolling();
  }

  async ended(gen, c, err) {
    if (gen !== this.gen) return;
    const mine = ++this.gen;
    this.closeES();
    this.cancel(c.idle);
    this.cancel(c.firstPut);
    if (!this.running) return;
    if (c.trial) { this.enterPolling(); return; }
    let reason = misconfigurationReason(err);
    if (!reason && !c.gotEvent && err.kind === "network") {
      // EventSource hides the HTTP status: ask a plain GET why (cheap: at most one child).
      try {
        await this.fb.get("messages", { query: messagesQuery(this.since()) + "&limitToFirst=1", timeoutMs: 10_000 });
        this.failedOpens++;   // GET works but the stream does not: SSE blocked on the way?
      } catch (e) {
        reason = misconfigurationReason(e);
      }
      if (!this.running || mine !== this.gen) return;   // stopped / restarted / nudged meanwhile
      if (!reason && this.failedOpens >= this.t.failedOpensBeforePolling) { this.enterPolling(); return; }
    }
    if (reason) {
      this.setState("misconfigured", reason);
      this.later(() => this.connect(false), this.t.misconfiguredRetryMs);
      return;
    }
    const lived = this.sched.now() - c.began;
    this.backoffMs = backoffAfter(this.backoffMs / 1000, lived / 1000) * 1000;   // seconds, like StreamBackoff
    const wait = this.backoffMs;
    this.backoffMs = Math.min(this.backoffMs * 2, this.t.backoffMaxMs);
    this.setState("offline");
    this.later(() => this.connect(false), wait);
  }

  // ---- polling fallback ----

  enterPolling() {
    if (!this.running) return;
    this.clearTimers();
    this.mode = "polling";
    this.firstPoll = true;
    this.pollNow();
    this.armTrial();
  }

  armTrial() {
    this.cancel(this.trialTimer);
    this.trialTimer = this.later(() => {
      if (!this.running || this.mode !== "polling") return;
      this.cancel(this.pollTimer);
      this.connect(true);
    }, this.t.sseRetryMs);
  }

  async pollNow() {
    if (!this.running || this.mode !== "polling") return;
    this.cancel(this.pollTimer);
    const gen = this.gen;
    let wait;
    try {
      const data = await this.fb.get("messages", { query: messagesQuery(this.since()), timeoutMs: this.t.pollVisibleMs });
      if (!this.running || this.mode !== "polling" || gen !== this.gen) return;
      this.setState("polling");
      const backlog = this.firstPoll;
      this.firstPoll = false;
      this.onBatch(data && typeof data === "object" && !Array.isArray(data) ? data : {}, backlog);
    } catch (e) {
      if (!this.running || this.mode !== "polling" || gen !== this.gen) return;
      const reason = misconfigurationReason(e);
      if (reason) { this.setState("misconfigured", reason); wait = this.t.misconfiguredRetryMs; }
      else this.setState("offline");
    }
    if (this.es) return;   // a trial stream took over meanwhile
    this.pollTimer = this.later(() => this.pollNow(), wait ?? (this.isHidden() ? this.t.pollHiddenMs : this.t.pollVisibleMs));
  }
}
