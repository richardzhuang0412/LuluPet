// The bridge: the watched seat's messages (MessageFeed, read-only) + presence (GET every 15 s) → scenes → Pixoo.
//
// Main loop, one thing at a time:
//   quiet hours → screen off (or dim still frame); waiting messages stay queued ("morning") or are dropped ("skip")
//   a message waiting → play its segments (each held for its time), mark it done, save the cursor
//   otherwise → make sure the idle animation for the current presence is on screen (re-upload only on change,
//               and every `idleRefreshMs` in case the device was power-cycled and lost it)

import { MessageFeed } from "../../../web/js/net/firebase.js";
import { decodeChildren } from "../../../web/js/core/message.js";
import { decodePresence } from "../../../web/js/core/presence.js";
import { idleScene, messageScene, nightScene } from "./scenes.js";
import { inQuietHours } from "./quiet.js";

export const LOOP_TICK_MS = 30_000;
export const IDLE_REFRESH_MS = 30 * 60_000;

export class Bridge {
  /**
   * fb: read-only Firebase (createReadOnlyFirebase). device: PixooClient-like. renderer: Renderer.
   * inbox: Inbox. persistCursor(ts): saves the local cursor. sched: {now, setTimeout, clearTimeout}.
   */
  constructor({ cfg, fb, device, renderer, manifest, inbox, persistCursor, log, sched, feedTiming }) {
    this.cfg = cfg;
    this.fb = fb;
    this.device = device;
    this.renderer = renderer;
    this.manifest = manifest;
    this.inbox = inbox;
    this.persistCursor = persistCursor;
    this.log = log;
    this.sched = sched ?? { now: () => Date.now(), setTimeout: (f, ms) => setTimeout(f, ms), clearTimeout: (h) => clearTimeout(h) };
    this.feedTiming = feedTiming;
    this.presence = null;
    this.running = false;
    this.shownKey = null;          // what is on the device now (idle key / "night" / "off")
    this.shownAt = 0;
    this.lastBrightness = null;
    this.screenOn = null;
    this.wakeFn = null;
    this.feedState = null;
  }

  now() { return this.sched.now(); }

  async start() {
    this.running = true;
    this.feed = new MessageFeed({
      fb: this.fb,
      since: () => this.inbox.cursor,
      onBatch: (children, backlog) => this.onBatch(children, backlog),
      onState: (state, reason) => {
        this.feedState = state;
        const msg = `firebase: ${state}${reason ? ` (${reason})` : ""}`;
        if (state === "misconfigured") this.log.error(msg); else this.log.info(msg);
      },
      sched: this.sched,
      timing: this.feedTiming,
      isHidden: () => false,
    });
    this.feed.start();
    this.pollPresence();
    this.loopDone = this.loop();
  }

  async stop() {
    this.running = false;
    this.feed?.stop();
    if (this.presenceTimer) this.sched.clearTimeout(this.presenceTimer);
    this.wake();
    await this.loopDone;
  }

  onBatch(children, backlog) {
    const msgs = decodeChildren(children, this.now());
    const { added, ignored, folded } = this.inbox.add(msgs);
    if (added.length || folded) {
      this.log.info(`messages: +${added.length}${backlog ? " (backlog)" : ""}${folded ? `, ${folded} older skipped` : ""}: ${added.map((m) => `${m.kind}#${m.id.slice(-6)}`).join(" ")}`);
    }
    if (ignored) this.log.debug(`messages: ${ignored} from the other seat ignored`);
    this.saveCursor();
    this.wake();
  }

  saveCursor() {
    if (!this.inbox.commit()) return;
    try { this.persistCursor(this.inbox.cursor); }
    catch (e) { this.log.warn("could not save the cursor:", e.message); }
  }

  async pollPresence() {
    if (!this.running) return;
    try {
      const raw = await this.fb.get(`presence/${this.cfg.watchSeat}`, { timeoutMs: 10_000 });
      const p = decodePresence(raw);
      const before = JSON.stringify(this.presence);
      this.presence = p;
      if (JSON.stringify(p) !== before) { this.log.debug("presence changed"); this.wake(); }
    } catch (e) {
      this.log.warn(`presence: ${e.message}`);
    }
    if (this.running) this.presenceTimer = this.sched.setTimeout(() => this.pollPresence(), this.cfg.presencePollMs);
  }

  wake() { const f = this.wakeFn; this.wakeFn = null; f?.(); }

  sleep(ms) {
    return new Promise((resolve) => {
      const h = this.sched.setTimeout(() => { if (this.wakeFn === done) this.wakeFn = null; resolve(); }, ms);
      const done = () => { this.sched.clearTimeout(h); resolve(); };
      this.wakeFn = done;
    });
  }

  /** Waits `ms` without being woken by new messages (a message's display time); stop() still ends it. */
  hold(ms) {
    return new Promise((resolve) => {
      const end = this.now() + ms;
      const tick = () => {
        if (!this.running || this.now() >= end) return resolve();
        this.sched.setTimeout(tick, Math.min(1000, end - this.now()));
      };
      tick();
    });
  }

  async loop() {
    while (this.running) {
      let wait = LOOP_TICK_MS;
      try {
        wait = await this.step();
      } catch (e) {
        this.log.error("loop:", e);
        this.shownKey = null;
        wait = 10_000;
      }
      if (this.running && wait > 0) await this.sleep(wait);
    }
  }

  /** One decision. → ms to wait before the next one (a new message / presence change wakes earlier). */
  async step() {
    const now = this.now();
    const q = this.cfg.quietHours;
    if (inQuietHours(now, q, this.cfg.timezone)) {
      if (q.messages === "skip" && this.inbox.size) {
        this.log.info(`quiet hours: skipping ${this.inbox.skipAll()} message(s)`);
        this.saveCursor();
      }
      await this.showNight();
      return LOOP_TICK_MS;
    }
    await this.ensureScreen(true, this.cfg.brightness);
    const msg = this.inbox.peek();
    if (msg) {
      await this.playMessage(msg);
      return 0;
    }
    await this.showIdle();
    return LOOP_TICK_MS;
  }

  async ensureScreen(on, brightness) {
    try {
      if (this.screenOn !== on) { await this.device.setScreen(on); this.screenOn = on; }
      if (on && this.lastBrightness !== brightness) { await this.device.setBrightness(brightness); this.lastBrightness = brightness; }
    } catch (e) {
      this.log.warn("pixoo: screen/brightness:", e.message);
    }
  }

  async showNight() {
    const q = this.cfg.quietHours;
    if (q.mode === "off" || q.dimBrightness === 0) {
      if (this.shownKey !== "off") { this.log.info("quiet hours: screen off"); this.shownKey = "off"; }
      await this.ensureScreen(false);
      return;
    }
    await this.ensureScreen(true, q.dimBrightness);
    const scene = nightScene(this.manifest, this.presence, { watchSeat: this.cfg.watchSeat });
    if (this.shownKey === scene.key) return;
    this.log.info("quiet hours: dim still frame");
    await this.playScene(scene);
    this.shownKey = scene.key;
    this.shownAt = this.now();
  }

  async showIdle() {
    const scene = idleScene(this.manifest, this.presence, this.now(), { watchSeat: this.cfg.watchSeat });
    const stale = this.now() - this.shownAt > (this.cfg.idleRefreshMs ?? IDLE_REFRESH_MS);
    if (this.shownKey === scene.key && !stale) return;
    this.log.info(`idle: ${scene.state} (${scene.character}/${scene.outfit})${stale && this.shownKey === scene.key ? " refresh" : ""}`);
    const ok = await this.playScene(scene);
    this.shownKey = ok ? scene.key : null;
    this.shownAt = this.now();
  }

  async playScene(scene) {
    const { segments } = await this.renderer.render(scene);
    let ok = true;
    for (const seg of segments) {
      try {
        ok = (await this.device.playAnimation(seg.frames, seg.frameMs, seg.label)) && ok;
      } catch (e) {
        this.log.warn(`pixoo: could not show "${seg.label}": ${e.message}`);
        ok = false;
      }
      if (Number.isFinite(seg.holdMs)) await this.hold(seg.holdMs);
      if (!this.running) break;
    }
    return ok;
  }

  async playMessage(msg) {
    const busy = this.inbox.size > 1;
    const durations = { ...this.cfg.durations };
    if (busy) for (const k of ["pokeMs", "stickerMs", "remindMs", "visitMs", "unknownMs", "textMinMs"]) durations[k] = Math.round((durations[k] ?? 20_000) / 2);
    const scene = messageScene(this.manifest, msg, this.presence, { watchSeat: this.cfg.watchSeat, durations });
    this.log.info(`show: ${scene.kind} #${msg.id.slice(-6)} (${scene.character}/${scene.outfit})${busy ? `, ${this.inbox.size - 1} more waiting` : ""}`);
    this.shownKey = null;
    try {
      await this.playScene(scene);
    } catch (e) {
      this.log.error(`could not render ${msg.kind} #${msg.id.slice(-6)}:`, e);
    }
    this.inbox.done(msg);
    this.saveCursor();
  }
}
