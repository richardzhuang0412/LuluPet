// One character on the stage (my pet or TA's visitor): a canvas sprite standing on the ground at x (its centre), with
// a rest pose (idle loop / quiet still / doze / a stay clip), one-shot clips, running, hearts, a toast, a mood sign,
// the pomodoro pill and Zzz. Port of PetWindow's drawing side; the world decides what it does.

import { h, removeLater } from "./dom.js";
import { SpritePlayer } from "./sprite.js";

export class Actor {
  /** `world` = {doc, timers, url}; `kind` = "me" | "visitor". */
  constructor(world, kind) {
    this.world = world;
    this.kind = kind;
    const doc = world.doc;
    this.canvas = h(doc, "canvas.lw-canvas", { "aria-hidden": "true" });
    this.sprite = h(doc, "div.lw-sprite", this.canvas);
    this.fx = h(doc, "div.lw-fx");
    this.shadow = h(doc, "div.lw-shadow", { "aria-hidden": "true" });
    this.el = h(doc, "div.lw-actor", { dataset: { kind } }, this.shadow, this.sprite, this.fx);
    this.player = new SpritePlayer(this.canvas, world.timers, world.url);
    this.player.onClip = (clip) => this.#size(clip);
    this.clips = null;          // catalog outfit
    this.baseH = 120;           // display height of the idle clip, CSS px
    this.x = 0;
    this.rest = "idle";
    this.busy = false;          // one-shot clip / run / couple
    this.running = null;        // {from, to, start, ms, done}
    this.runTimer = 0;
    this.restSpeed = 1;
    this.signEl = null;
    this.pillEl = null;
    this.zzzEl = null;
  }

  // ---- look ------------------------------------------------------------------------------------------------------

  setClips(clips) {
    this.clips = clips;
    this.el.style.setProperty("--shadow-w", (this.idleWidth * 0.62).toFixed(0) + "px");
    if (!this.busy) this.returnToRest();
  }

  setBaseHeight(px) {
    this.baseH = px;
    this.el.style.setProperty("--base-h", px + "px");
    this.el.style.setProperty("--shadow-w", (this.idleWidth * 0.62).toFixed(0) + "px");
    if (this.player.current) this.#size(this.player.current.clip);
    if (this.pillEl) this.layoutPill();
  }

  #size(clip) {
    const k = clip?.src?.[1] && this.clips ? clip.src[1] / this.clips.idleHeight : 1;
    const hgt = this.baseH * k * (this.heightFactor || 1);
    this.canvas.style.height = hgt.toFixed(1) + "px";
    this.canvas.style.width = (hgt * (clip?.w || 1) / (clip?.h || 1)).toFixed(1) + "px";
  }

  /** Visible idle width in CSS px (for stand positions). */
  get idleWidth() {
    const c = this.clips?.idle;
    return c ? this.baseH * (c.w / c.h) : this.baseH * 0.7;
  }
  get height() { return this.baseH; }

  setX(x) {
    this.x = x;
    this.el.style.transition = "none";
    this.el.style.transform = `translateX(${x.toFixed(1)}px)`;
    if (this.pillEl) this.layoutPill();
  }

  setHidden(hidden) { this.el.classList.toggle("lw-gone", !!hidden); }
  get hidden() { return this.el.classList.contains("lw-gone"); }
  setMirrored(on) { this.sprite.classList.toggle("lw-mirror", !!on); }

  // ---- rest + clips -----------------------------------------------------------------------------------------------

  /** "idle" | "quiet" | "doze" | {stay: name} — applied now unless busy (busy things come back to it). */
  setRest(rest) {
    const same = JSON.stringify(rest) === JSON.stringify(this.rest);
    this.rest = rest;
    if (!same && !this.busy) this.returnToRest();
  }

  returnToRest() {
    const c = this.clips;
    if (!c) return;
    this.busy = false;
    this.setMirrored(false);
    this.sprite.classList.remove("lw-bob", "lw-dim");
    this.#zzz(false);
    const r = this.rest;
    if (r === "quiet") this.player.play(c.action("quiet") || c.idle, { still: true });
    else if (r === "doze") {
      const sleep = c.action("sleep");
      if (sleep) this.player.play(sleep, { loop: true });
      else { this.player.play(c.idle, { still: true }); this.sprite.classList.add("lw-dim"); }
      this.#zzz(true);
    } else if (r && typeof r === "object" && r.stay) {
      const n = c.named(r.stay);
      this.player.play(n?.clip || c.idle, { loop: true });
    } else this.player.play(c.idle, { loop: true });
  }

  /** Plays a clip once, then back to rest. */
  playClip(clip, onEnd, opts = {}) {
    if (!clip) { onEnd?.(); return false; }
    this.busy = true;
    this.#zzz(false);
    this.sprite.classList.remove("lw-dim");
    this.player.play(clip, { ...opts, onEnd: () => { this.returnToRest(); onEnd?.(); } });
    return true;
  }

  /** An action ("happy", "react", "wave") once; false (and onEnd soon) when the outfit has none. */
  playAction(name, onEnd) {
    const clip = this.clips?.action(name);
    if (!clip) { if (onEnd) this.world.timers.after(300, onEnd); return false; }
    return this.playClip(clip, onEnd);
  }

  /** A named clip of the outfit (reactions.json / ToolClips names, or a web clip id); false when it has none. */
  playNamed(name, onEnd) {
    const n = this.clips?.named(name);
    if (!n) return false;
    return this.playClip(n.clip, onEnd);
  }

  // ---- running ----------------------------------------------------------------------------------------------------

  /** Runs to `toX` at `speed` px/s (run clip facing the way, else idle + bob), then `done()`. */
  run(toX, speed, done) {
    this.stopRunning();
    const from = this.x;
    const ms = Math.max(50, (Math.abs(toX - from) / Math.max(1, speed)) * 1000);
    const runClip = this.clips?.action("run");
    this.busy = true;
    this.#zzz(false);
    this.sprite.classList.remove("lw-dim");
    if (runClip) {
      this.player.play(runClip, { loop: true });
      this.setMirrored(toX < from);
    } else {
      this.player.play(this.clips?.idle, { loop: true });
      this.sprite.classList.add("lw-bob");
    }
    this.running = { from, to: toX, start: Date.now(), ms, done };
    // Force the start position before the transition (one frame), then glide.
    this.el.style.transition = "none";
    this.el.style.transform = `translateX(${from.toFixed(1)}px)`;
    void this.el.offsetWidth;
    this.el.style.transition = `transform ${ms}ms linear`;
    this.el.style.transform = `translateX(${toX.toFixed(1)}px)`;
    this.x = toX;
    this.runTimer = this.world.timers.after(ms, () => this.#finishRun());
    return ms;
  }

  /**
   * A run in progress continues from `fromX` to `toX` at the same speed with the same completion (the stage was
   * resized, or the world moved to another document, where the CSS transition would otherwise jump to its end).
   */
  retarget(toX, fromX = this.liveX) {
    const r = this.running;
    if (!r) { this.setX(toX); return; }
    const speed = (Math.abs(r.to - r.from) / Math.max(1, r.ms)) * 1000 || 1;
    this.world.timers.cancel(this.runTimer);
    this.running = null;
    this.x = fromX;
    this.run(toX, speed, r.done);
  }

  /** Where the actor is right now (mid-run too). */
  get liveX() {
    const r = this.running;
    if (!r) return this.x;
    const f = Math.min(1, (Date.now() - r.start) / r.ms);
    return r.from + (r.to - r.from) * f;
  }

  #finishRun() {
    const r = this.running;
    this.running = null;
    this.sprite.classList.remove("lw-bob");
    this.returnToRest();
    r?.done?.();
  }

  /** Stops a run in place (no completion). */
  stopRunning() {
    if (!this.running) return;
    const x = this.liveX;
    this.world.timers.cancel(this.runTimer);
    this.running = null;
    this.sprite.classList.remove("lw-bob");
    this.setX(x);
    this.returnToRest();
  }

  // ---- effects ----------------------------------------------------------------------------------------------------

  hearts() {
    const doc = this.world.doc;
    const box = h(doc, "div.lw-hearts", h(doc, "span", "❤️"), h(doc, "span", "💕"), h(doc, "span", "❤️"));
    box.style.bottom = (this.baseH * 0.72).toFixed(0) + "px";
    this.fx.append(box);
    removeLater(box, this.world.timers.win, 2200);
  }

  /** A small line over the head for a few seconds (「送到啦 ❤️」). */
  toast(text, ms = 2600) {
    const doc = this.world.doc;
    this.fx.querySelector(".lw-toast")?.remove();
    const t = h(doc, "div.lw-toast", text);
    t.style.bottom = (this.baseH + 6).toFixed(0) + "px";
    t.style.animationDuration = ms + "ms";
    this.fx.append(t);
    removeLater(t, this.world.timers.win, ms + 200);
  }

  /** The 勿扰 mood sign above the head (null = none). */
  setSign(text) {
    if (!text) { this.signEl?.remove(); this.signEl = null; return; }
    if (!this.signEl) { this.signEl = h(this.world.doc, "div.lw-sign"); this.fx.append(this.signEl); }
    this.signEl.textContent = text;
    this.signEl.style.bottom = (this.baseH + 2).toFixed(0) + "px";
  }

  /** The pomodoro pill by the feet (「🍅 12」; null = none): beside the pet, on whichever side has room. */
  setPill(text) {
    if (!text) { this.pillEl?.remove(); this.pillEl = null; return; }
    if (!this.pillEl) { this.pillEl = h(this.world.doc, "div.lw-pill"); this.fx.append(this.pillEl); }
    this.pillEl.textContent = text;
    this.layoutPill();
  }

  layoutPill() {
    const p = this.pillEl;
    if (!p) return;
    const reach = this.idleWidth * 0.42;
    const room = (this.world.width ?? Infinity) - (this.x + reach);
    const left = room < p.offsetWidth + 6;
    p.classList.toggle("left", left);
    p.style.left = (left ? -reach : reach).toFixed(0) + "px";
  }

  #zzz(on) {
    if (!on) { this.zzzEl?.remove(); this.zzzEl = null; return; }
    if (this.zzzEl) return;
    this.zzzEl = h(this.world.doc, "div.lw-zzz", "z", h(this.world.doc, "span", "z"), h(this.world.doc, "span", "Z"));
    this.zzzEl.style.bottom = (this.baseH * 0.8).toFixed(0) + "px";
    this.fx.append(this.zzzEl);
  }

  /** The sprite's rect in stage coordinates (x centre based). */
  rect() {
    const w = this.idleWidth;
    return { left: this.liveX - w / 2, right: this.liveX + w / 2, top: this.baseH, width: w };
  }

  stop() {
    this.stopRunning();
    this.player.stop();
    this.busy = false;
  }
}
