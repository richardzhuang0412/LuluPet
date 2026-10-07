// The web client's connection to the pair (port of LuluSync/PairChannel.swift, spec §2, §4.2, §5.2, §10 W2).
//
//   const ch = createChannel({config: {databaseURL, pairCode, seat}, store, deviceId});
//   ch.addEventListener("message", (e) => e.detail.msg);
//   await ch.start();
//
// Methods: start() → Promise, stop(), send(msg) → msg (as queued), markRead(msg), signOff() → Promise<boolean>.
// Events (CustomEvent, payload in `event.detail`) — see EVENT SHAPES at the bottom of this file.

import {
  decodeChild, encodePayload, generatePushKey, isValidPushKey, clampCursor, isFuture, queueFold, outboxVerdict,
  decodePresence, isOnline, heartbeatPayload, signOffPayload, seatYield, isWebDevice, adoptIdentity, ReadCursor,
} from "./_shim_core.js";   // TEMP → ../core/{message,pushkey,wire,presence,seat,cursor}.js (see _shim_core.js)
import { createFirebase, MessageFeed, SEND_TIMEOUT_MS, PRESENCE_TIMEOUT_MS } from "./firebase.js";
import { createScheduler } from "./scheduler.js";

export const LOCK_NAME = "lulupet-channel";
const MAX_FAILED_KEPT = 200;   // OutboxStore.maxFailedKept
const SENT_KEYS_KEPT = 200;    // keys this browser sent, so their stream echo is never reported as `own`

/** Channel timing (ms). Tests shorten these; `feed` overrides FEED_TIMING in firebase.js. */
export const CHANNEL_TIMING = Object.freeze({
  seatCheckMs: 10_000,     // §4.2: read my own seat every 10 s …
  heartbeatMs: 20_000,     // … and heartbeat when ≥ 20 s since my last PUT (unless yielding to my Mac)
  partnerPollMs: 15_000,   // Presence.pollInterval
  outboxRetryMs: 5_000,    // PairChannel.outboxRetryInterval
  cursorWriteMs: 10_000,   // §5.2: shared read cursor written at most every 10 s
  sendTimeoutMs: SEND_TIMEOUT_MS,
  presenceTimeoutMs: PRESENCE_TIMEOUT_MS,
  signOffTimeoutMs: 2_000,
});

export function createChannel(opts) {
  return new Channel(opts);
}

const otherSeat = (seat) => (seat === "lulu" ? "lumei" : "lulu");
const same = (a, b) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);

export class Channel extends EventTarget {
  /**
   * @param {object} o
   * @param {{databaseURL: string, pairCode: string, seat: "lulu"|"lumei"}} o.config
   * @param {{get(k), set(k, v), remove(k)}} o.store   values are JSON (see store.js)
   * @param {string} o.deviceId   "web-<uuid>"
   * Optional (tests): fetch, EventSource, scheduler, timing {…, feed: {…}}, lock (false = no Web Lock),
   * lockName, lifecycle (false = no pagehide / visibility listeners), isHidden, now.
   */
  constructor({ config, store, deviceId, fetch, EventSource, scheduler, timing = {}, lock = true, lockName = LOCK_NAME,
                lifecycle, isHidden, now } = {}) {
    super();
    if (config?.seat !== "lulu" && config?.seat !== "lumei") throw new Error("config.seat must be lulu or lumei");
    this.config = config;
    this.store = store;
    this.deviceId = deviceId;
    this.seat = config.seat;
    this.partnerSeat = otherSeat(config.seat);
    this.t = { ...CHANNEL_TIMING, ...timing };
    this.feedTiming = timing.feed ?? {};
    this.useLock = lock;
    this.lockName = lockName;
    this.lifecycle = lifecycle ?? (typeof window !== "undefined" && typeof document !== "undefined");
    this.isHidden = isHidden;
    this.clock = now ?? (() => Date.now());
    this.givenScheduler = scheduler ?? null;
    this.fb = createFirebase({ databaseURL: config.databaseURL, pairCode: config.pairCode, fetch, EventSource });

    this.session = null;       // token of the running start(); async continuations of an older one are dropped
    this.active = false;       // started and owning the lock
    this.timers = new Set();
    this._state = null;
    this._reason = null;

    this.identity = adoptIdentity(null, this.seat);
    this.mySeatPresence = undefined;   // undefined = not read yet; null = never written
    this.yielding = false;
    this.partnerPresence = undefined;
    this.partnerOnline = null;
    this.lastBeatAt = 0;
    this.lastSeatReadAt = 0;
    this.beaten = false;
    this.signedOff = false;

    this.delivered = new Set();
    this.ownSeen = new Set();
    this.sentIds = new Set();
    const stored = Number(store.get("lastReadTs"));
    this.lastReadTs = Number.isInteger(stored) && stored > 0 ? stored : 0;
    this.sharedReadTs = 0;      // last value read from / written to read/{seat}
    this.sharedWritten = 0;
    this.lastCursorWriteAt = 0;
    this.cursorTimer = null;

    // Outbox (§2.1, OutboxStore): same pair code and seat only, anything else is dropped.
    this.outbox = [];
    this.failed = [];
    const saved = store.get("outbox");
    if (saved && saved.pairCode === config.pairCode && saved.seat === this.seat) {
      this.outbox = (Array.isArray(saved.messages) ? saved.messages : []).filter((m) => m && isValidPushKey(m.id));
      this.failed = (Array.isArray(saved.failed) ? saved.failed : []).filter((x) => typeof x === "string");
    }
    const sentKeys = store.get("sentKeys");
    for (const k of Array.isArray(sentKeys) ? sentKeys : []) if (typeof k === "string") this.sentIds.add(k);
    for (const m of this.outbox) this.sentIds.add(m.id);
    this.lastSentTs = this.outbox.reduce((a, m) => Math.max(a, Number(m.ts) || 0), 0);
    this.persistOutbox();
    this.flushing = false;
    this.retryTimer = null;

    this.onPageHide = (e) => {
      this.writeCursor({ keepalive: true });
      this.signOff();
      if (e?.persisted) this.frozen = true;
    };
    this.onPageShow = (e) => {
      if (e?.persisted && this.frozen && this.session) { this.frozen = false; this.start(); }
    };
    this.onVisible = () => {
      if (typeof document !== "undefined" && document.visibilityState === "visible") this.feed?.nudge();
    };
    this.onOnline = () => this.feed?.nudge();
  }

  // ---- public state ----

  /** "connecting" | "connected" | "polling" | "offline" | "misconfigured" | "elsewhere" | null (not started) */
  get state() { return this._state; }
  get reason() { return this._reason; }
  get running() { return this.session !== null; }
  /** Unsent messages, oldest first (copies). */
  get pending() { return this.outbox.map((m) => ({ ...m })); }

  // ---- lifecycle ----

  /**
   * Takes the Web Lock (another tab holding it → state "elsewhere" until it closes), reads the shared read cursor
   * and my seat's presence, then opens the message feed, the presence loops and the outbox. Resolves once running
   * (or once stop() cancelled a wait for the lock).
   */
  async start() {
    if (this.session) this.stop();
    const s = (this.session = {});
    this.signedOff = false;
    this.frozen = false;
    this.setState("connecting");
    if (this.lifecycle) this.listen(true);

    if (!(await this.acquireLock(s)) || s !== this.session) return;
    this.sched = this.givenScheduler ?? createScheduler();
    this.ownsScheduler = !this.givenScheduler;
    this.active = true;
    this.setState("connecting");

    // prelaunch-A: a cursor poisoned by a far-future value must not stall the stream.
    if (isFuture(this.lastReadTs, this.clock())) this.setLastRead(this.clock());
    await Promise.all([this.loadSharedCursor(s), this.seatTick(s, false)]);
    if (s !== this.session) return;

    this.feed = new MessageFeed({
      fb: this.fb,
      since: () => this.lastReadTs,
      onBatch: (children, backlog) => { if (s === this.session) this.handleBatch(children, backlog); },
      onState: (state, reason) => { if (s === this.session) this.feedState(state, reason); },
      sched: this.sched,
      timing: this.feedTiming,
      isHidden: this.isHidden,
    });
    this.feed.start();
    this.later(() => this.seatTick(s, true), this.t.seatCheckMs);
    this.partnerTick(s);
    this.flush();
    if (this.lastReadTs > this.sharedReadTs) this.scheduleCursorWrite();
  }

  /** Stops everything (feed, loops, retries) and releases the lock. Safe to call more than once. Writes nothing. */
  stop() {
    this.session = null;
    this.active = false;
    this.feed?.stop();
    this.feed = null;
    for (const h of this.timers) this.sched?.clearTimeout(h);
    this.timers.clear();
    this.cursorTimer = null;
    this.retryTimer = null;
    if (this.ownsScheduler) this.sched?.dispose();
    this.sched = null;
    this.lockWait?.abort();
    this.lockWait = null;
    this.releaseLock?.();
    this.releaseLock = null;
    if (this.lifecycle) this.listen(false);
    this.setState(null);
  }

  listen(on) {
    const w = globalThis;
    if (typeof w.addEventListener !== "function") return;
    const m = on ? "addEventListener" : "removeEventListener";
    w[m]("pagehide", this.onPageHide);
    w[m]("pageshow", this.onPageShow);
    w[m]("online", this.onOnline);
    if (typeof document !== "undefined") document[m]("visibilitychange", this.onVisible);
  }

  /** One leader tab per browser (§4.2). Resolves true once this tab holds the lock, false if stopped first. */
  acquireLock(s) {
    const locks = this.useLock ? globalThis.navigator?.locks : null;
    if (!locks?.request) return Promise.resolve(true);
    return new Promise((resolve) => {
      const hold = () => {
        if (s !== this.session) { resolve(false); return undefined; }
        resolve(true);
        return new Promise((release) => { this.releaseLock = release; });
      };
      locks.request(this.lockName, { ifAvailable: true }, (lock) => {
        if (lock) return hold();
        if (s !== this.session) { resolve(false); return undefined; }
        this.setState("elsewhere");
        const ac = new AbortController();
        this.lockWait = ac;
        locks.request(this.lockName, { signal: ac.signal }, () => { this.lockWait = null; return hold(); })
          .catch(() => resolve(false));
        return undefined;
      }).catch(() => resolve(false));
    });
  }

  later(fn, ms) {
    if (!this.sched) return null;
    const h = this.sched.setTimeout(() => { this.timers.delete(h); fn(); }, ms);
    this.timers.add(h);
    return h;
  }

  cancel(h) {
    if (h == null) return;
    this.sched?.clearTimeout(h);
    this.timers.delete(h);
  }

  emit(type, detail) { this.dispatchEvent(new CustomEvent(type, { detail })); }

  setState(state, reason = null) {
    if (state === this._state && reason === this._reason) return;
    this._state = state;
    this._reason = reason;
    if (state !== null) this.emit("connection", { state, reason });
  }

  feedState(state, reason) {
    this.setState(state, reason);
    // Reads work again: don't make a waiting outbox sit out its retry delay.
    if ((state === "connected" || state === "polling") && this.retryTimer != null) {
      this.cancel(this.retryTimer);
      this.retryTimer = null;
      this.flush();
    }
  }

  get readsWork() { return this._state === "connected" || this._state === "polling"; }

  // ---- receiving ----

  handleBatch(children, backlog) {
    const now = this.clock();
    const msgs = [];
    for (const [key, value] of Object.entries(children)) {
      const m = decodeChild(key, value, now);
      if (m) msgs.push(m);
    }
    msgs.sort((a, b) => a.ts - b.ts || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    const fresh = [];
    for (const m of msgs) {
      if (m.from === this.seat) {
        // My seat (home Mac / another web / my own echo): never shown; keeps my timestamps strictly increasing.
        this.lastSentTs = Math.max(this.lastSentTs, m.ts);
        if (!this.sentIds.has(m.id) && !this.ownSeen.has(m.id)) {
          this.ownSeen.add(m.id);
          this.emit("own", { msg: m });
        }
        continue;
      }
      if (this.delivered.has(m.id)) continue;
      this.delivered.add(m.id);
      fresh.push(m);
    }
    const { folded, kept } = queueFold(fresh);
    for (const m of folded) { this.cursor().delivered(m.id, m.ts); this.markRead(m); }
    if (folded.length) this.emit("folded", { count: folded.length });
    for (const m of kept) this.cursor().delivered(m.id, m.ts);
    if (!kept.length) return;
    if (backlog) this.emit("backlog", { msgs: kept });
    else for (const m of kept) this.emit("message", { msg: m, live: true });
  }

  cursor() {
    if (!this.readCursor) this.readCursor = new ReadCursor(this.lastReadTs);
    return this.readCursor;
  }

  /**
   * The message has been shown / dismissed. The cursor never passes a delivered message that is still unread
   * (PairChannel.markRead); it only moves forward. The shared cursor read/{seat} follows, throttled.
   */
  markRead(msg) {
    if (!msg || typeof msg.id !== "string" || !Number.isInteger(msg.ts)) return;
    const c = this.cursor().markRead(msg.id, msg.ts, this.clock());
    if (c > this.lastReadTs) {
      this.setLastRead(c);
      this.scheduleCursorWrite();
    }
  }

  setLastRead(ts) {
    this.lastReadTs = ts;
    this.store.set("lastReadTs", ts);
  }

  async loadSharedCursor(s) {
    try {
      const v = await this.fb.get(`read/${this.seat}`, { timeoutMs: this.t.presenceTimeoutMs });
      if (s !== this.session) return;
      const ts = Number.isInteger(v?.ts) ? v.ts : 0;
      this.sharedReadTs = Math.max(this.sharedReadTs, ts);
      const c = clampCursor(Math.max(this.lastReadTs, ts), this.clock());
      if (c > this.lastReadTs) this.setLastRead(c);
    } catch {
      // Unreachable: the local cursor alone (at worst a few repeats).
    }
  }

  scheduleCursorWrite() {
    if (!this.active || this.cursorTimer != null) return;
    const wait = Math.max(0, this.lastCursorWriteAt + this.t.cursorWriteMs - this.clock());
    this.cursorTimer = this.later(() => { this.cursorTimer = null; this.writeCursor(); }, wait);
  }

  /** PUT read/{seat} = {ts, device, at} when the cursor moved past what is there. */
  async writeCursor({ keepalive = false } = {}) {
    const value = Math.max(this.lastReadTs, this.sharedReadTs);
    if (value <= Math.max(this.sharedWritten, this.sharedReadTs)) return;
    if (!keepalive && !this.active) return;
    const now = this.clock();
    this.lastCursorWriteAt = now;
    const before = this.sharedWritten;
    this.sharedWritten = value;
    try {
      await this.fb.put(`read/${this.seat}`, { ts: value, device: this.deviceId, at: now },
        { timeoutMs: keepalive ? this.t.signOffTimeoutMs : this.t.presenceTimeoutMs, keepalive });
    } catch {
      if (this.sharedWritten === value) this.sharedWritten = before;
      if (!keepalive) this.scheduleCursorWrite();
    }
  }

  // ---- sending ----

  /**
   * Queues the message (persisted) and sends it as an idempotent PUT to its own push key; retried every 5 s until
   * it succeeds or is parked (400 / 413 / 422; 401 / 403 while reads work). `from` is my seat; `character` /
   * `outfit` default to my seat's identity, `trip` to "local"; `ts` is made strictly increasing. Returns the
   * message as queued (with its `id` = Firebase key). Messages queued before start() go out once started.
   */
  send(msg) {
    const m = { ...msg };
    delete m.localId;
    m.from = this.seat;
    if (m.character == null) m.character = this.identity.character;
    if (m.outfit == null && this.identity.outfit) m.outfit = this.identity.outfit;
    if (m.trip == null) m.trip = "local";
    const now = this.clock();
    m.ts = Math.max(Number.isInteger(m.ts) ? m.ts : now, this.lastSentTs + 1);
    this.lastSentTs = m.ts;
    if (!isValidPushKey(m.id)) m.id = generatePushKey(m.ts);
    this.sentIds.add(m.id);
    this.store.set("sentKeys", [...this.sentIds].slice(-SENT_KEYS_KEPT));
    this.outbox.push(m);
    this.persistOutbox();
    this.flush();
    return { ...m };
  }

  persistOutbox() {
    if (!this.outbox.length && !this.failed.length) { this.store.remove("outbox"); return; }
    this.store.set("outbox", {
      pairCode: this.config.pairCode, seat: this.seat, messages: this.outbox, failed: this.failed.slice(-MAX_FAILED_KEPT),
    });
  }

  async flush() {
    if (this.flushing || !this.active || this.retryTimer != null) return;
    this.flushing = true;
    const s = this.session;
    try {
      while (s === this.session && this.outbox.length) {
        const next = this.outbox[0];
        try {
          await this.fb.put(`messages/${next.id}`, encodePayload(next), { timeoutMs: this.t.sendTimeoutMs });
          if (this.outbox[0]?.id === next.id) this.outbox.shift();
          this.persistOutbox();
          if (s === this.session) this.emit("sent", { msg: { ...next } });
        } catch (e) {
          if (s !== this.session) break;
          const status = e?.kind === "http" ? e.status : null;
          if (outboxVerdict(status, this.readsWork) === "park") {
            // The server refuses this very message for good: park it, carry on with the rest.
            if (this.outbox[0]?.id === next.id) this.outbox.shift();
            if (!this.failed.includes(next.id)) this.failed.push(next.id);
            this.persistOutbox();
            this.emit("parked", { msg: { ...next }, status });
          } else {
            this.retryTimer = this.later(() => { this.retryTimer = null; this.flush(); }, this.t.outboxRetryMs);
            break;
          }
        }
      }
    } finally {
      this.flushing = false;
    }
  }

  // ---- presence (§4.2 seat yield) ----

  /** Read my seat; adopt my Mac's identity; heartbeat unless my Mac is online there. */
  async seatTick(s, reschedule) {
    if (s !== this.session) return;
    let mine, ok = false;
    try {
      mine = decodePresence(await this.fb.get(`presence/${this.seat}`, { timeoutMs: this.t.presenceTimeoutMs }));
      ok = true;
    } catch {
      // Network trouble: not a read; keep the last decision.
    }
    if (s !== this.session) return;
    const now = this.clock();
    if (ok) {
      this.lastSeatReadAt = now;
      const before = { presence: this.mySeatPresence, yielding: this.yielding, identity: this.identity };
      this.mySeatPresence = mine ?? null;
      // §4.3: copy my Mac's identity; a seat written by a web client (which copied it earlier) only until a Mac's is known.
      if (mine && !isWebDevice(mine.device)) { this.identity = adoptIdentity(mine, this.seat); this.identityFromMac = true; }
      else if (mine && !this.identityFromMac) this.identity = adoptIdentity(mine, this.seat);
      this.yielding = seatYield({ mine: mine ?? null, myDevice: this.deviceId, now }) === "yield";
      if (before.presence === undefined || !same(before.presence, this.mySeatPresence) || before.yielding !== this.yielding || !same(before.identity, this.identity)) {
        this.emit("mySeat", { presence: this.mySeatPresence, yielding: this.yielding, identity: { ...this.identity } });
      }
    }
    if (!this.yielding && !this.signedOff && now - this.lastBeatAt >= this.t.heartbeatMs) await this.beat(s);
    if (reschedule && s === this.session) this.later(() => this.seatTick(s, true), this.t.seatCheckMs);
  }

  async beat(s) {
    const now = this.clock();
    this.lastBeatAt = now;
    this.beaten = true;
    try {
      await this.fb.put(`presence/${this.seat}`, heartbeatPayload({ ...this.identity, device: this.deviceId }, now),
        { timeoutMs: this.t.presenceTimeoutMs });
    } catch {
      // Next tick tries again.
    }
  }

  /**
   * Clean sign-off (pagehide; also callable): `lastSeen: 0`, only when the last writer of my seat is this tab
   * (my Mac online there must never be signed off). No heartbeat after it until start() again.
   * Resolves true when the sign-off was written.
   */
  async signOff() {
    this.signedOff = true;
    const lastWriterIsMe = this.mySeatPresence?.device === this.deviceId || (this.beaten && this.lastBeatAt >= this.lastSeatReadAt);
    if (!this.beaten || this.yielding || !lastWriterIsMe) return false;
    try {
      await this.fb.put(`presence/${this.seat}`, signOffPayload({ ...this.identity, device: this.deviceId }),
        { keepalive: true, timeoutMs: this.t.signOffTimeoutMs });
      return true;
    } catch {
      return false;
    }
  }

  async partnerTick(s) {
    if (s !== this.session) return;
    try {
      const p = decodePresence(await this.fb.get(`presence/${this.partnerSeat}`, { timeoutMs: this.t.presenceTimeoutMs })) ?? null;
      if (s !== this.session) return;
      const online = isOnline(p?.lastSeen, this.clock());
      if (!same(p, this.partnerPresence) || online !== this.partnerOnline) {
        this.partnerPresence = p;
        this.partnerOnline = online;
        this.emit("partner", { presence: p, online });
      }
    } catch {
      // Network trouble: keep the last known presence.
    }
    if (s === this.session) this.later(() => this.partnerTick(s), this.t.partnerPollMs);
  }
}

/*
 * EVENT SHAPES (event.detail). `Msg` = W1's decodeChild() result: {id, from, kind, ts, text?, stickerId?, remind?,
 * ackOf?, answer?, character?, outfit?, trip?, v?, …}; `Presence` = W1's decodePresence() result.
 *
 *   connection {state, reason}   state: "connecting" | "connected" (stream) | "polling" (SSE fallback, reads work) |
 *                                "offline" (retrying) | "misconfigured" (reason: Chinese text, e.g.
 *                                "数据库规则拒绝访问 (HTTP 401)") | "elsewhere" (another tab owns the connection);
 *                                reason is null except for "misconfigured".
 *   backlog    {msgs: Msg[]}     partner messages that arrived while away (first put of a connection / first poll),
 *                                oldest first, at most 50, only ones not delivered before. For the summary card.
 *   message    {msg: Msg, live: true}   one live partner message (never repeated).
 *   folded     {count}           older backlog messages beyond the newest 50: already marked read, only counted.
 *   partner    {presence: Presence|null, online: boolean}   on every change of the partner's presence (null = never written).
 *   mySeat     {presence: Presence|null, yielding: boolean, identity: {character, mode, outfit?, place?}}
 *                                my seat as last read; yielding = my Mac is online there, so this tab does not heartbeat.
 *   parked     {msg: Msg, status: number|null}   the server refused this message for good (「有一条消息没发出去」).
 *   sent       {msg: Msg}        (extra) the message reached the server.
 *   own        {msg: Msg}        (extra) a message from MY seat written elsewhere (home Mac / another web): not shown,
 *                                for sticker send counts.
 */
