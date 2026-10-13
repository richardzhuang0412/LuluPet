// The pet's little world (spec §4.1, contract §7 W5): a horizontal desk with my pet (idle / fidget / quiet / doze,
// clicks, drag, resize handle, 勿扰 sign, pomodoro pill), TA's visits (visitor.js), my deliveries, speech bubbles,
// 想 TA / 偷看 clouds and neutral UI sounds. One DOM element that W4 places in the main page or moves whole into the
// Document PiP window; every node is made with the document it currently lives in (mountIn), and every timer runs
// on that document's window.
//
// const world = createWorld({manifest, sound, policy, onReply, onRead, onCompose, onMenu, onPeekDone})
//   world.element / world.mountIn(doc, parent?)
//   setMe({character, outfit, scale, x?, seat?}) · setMood({dnd, focus, pomodoroLabel, hidden}) · setWeather(look)
//   activity() · cheer() · playTool(kind) (ToolClips clip for my own reminders, else happy)
//   incoming(msg, {live}) → Promise<"shown"|"queued"|"dropped"> · card(kind, msgs)
//   goDeliver(msg, verdict) → Promise<"delivered"|"bounced"|"local"|"cooldown"> (sets msg.trip first)
//   think(reason, scene) → bool · peek(scene)
//   bubble({header, line, buttons, tag, replace, autoHide, sound, urgent}) → Promise<button index | null> · closeBubble(tag)
//     (urgent = my own reminder: shown before TA's waiting bubbles, which come back right after)
//   on(event, fn) → off: "pose" (raw pose word) · "clicked" · "dragged" ({x: 0…1}) · "scaled" (scale) ·
//                        "wantThink" (reason: "idle" | "hover") · "collision" ({winner, steps})

import { h, nameOf } from "./dom.js";
import { createTimers } from "./timers.js";
import { createCatalog } from "./catalog.js";
import { Actor } from "./pet.js";
import { createBubbles } from "./bubbles.js";
import { createThink } from "./think.js";
import { Visits } from "./visitor.js";
import { ALWAYS_EVENTS } from "./sound.js";
import {
  IDLE, fidgetDelayMs, restPose, poolPick, pickFidget, derivePose, CLICK_CHANCE, clickClips, VISITS, THINK,
  thinkIdleDelayMs, thinkShouldShow, peekVerdict, toolClipPool,
} from "./rules.js";
import { decodeReply, replyLine } from "../../core/remind.js";
import { summarize, summaryParts } from "../../core/away.js";

export const SCALE = { min: 0.6, max: 1.6, standard: 1 };
/** PetScale.rubberBand: beyond the limits the size resists (at most 0.04 past them). */
export function rubberBand(s, overshoot = 0.04) {
  if (!Number.isFinite(s)) return 1;
  const resist = (x) => overshoot * (1 - 1 / (1 + x / overshoot));
  if (s > SCALE.max) return SCALE.max + resist(s - SCALE.max);
  if (s < SCALE.min) return SCALE.min - resist(SCALE.min - s);
  return s;
}
export const normalizeScale = (s) => Math.round(Math.min(SCALE.max, Math.max(SCALE.min, Number.isFinite(s) ? s : 1)) * 100) / 100;
/**
 * Idle display height (CSS px) × the pet size: about 56 % of a short stage (72–150 px); a tall stage (the wide
 * layout's column, over 300 px) gets a bigger pet, a third of the height but at most half the width (150–190 px).
 */
export function petHeightFor(stageH, scale = 1, stageW = Infinity) {
  const base = stageH > 300 ? Math.min(190, Math.max(150, Math.min(stageH * 0.34, stageW * 0.5))) : Math.min(150, Math.max(72, stageH * 0.56));
  return base * scale;
}
/** The scene's time of day for a local hour (0–23.99): dawn 5–8, day 8–17, dusk 17–19:30, night. */
export function timeOfDay(hour) {
  if (hour >= 5 && hour < 8) return "dawn";
  if (hour >= 8 && hour < 17) return "day";
  if (hour >= 17 && hour < 19.5) return "dusk";
  return "night";
}
/** The card header for a held batch. */
export function cardTitle(kind, count) {
  if (kind === "dnd") return `你勿扰的时候，TA 来找过你 ${count} 次～`;
  if (kind === "focus") return VISITS.focusCardTitle;
  if (kind === "trip") return VISITS.tripCardTitle;
  return VISITS.awayCardTitle;
}

const CSS_URL = new URL("./world.css", import.meta.url).href;
const DEFAULT_ASSETS = new URL("../../../assets/", import.meta.url).href;
const roll = (n) => Math.floor(Math.random() * n);

export function createWorld(opts = {}) {
  const {
    manifest, sound = null, policy = null, onReply, onRead, onCompose, onMenu, onPeekDone,
    assetsBase = DEFAULT_ASSETS, log = null, doc: doc0 = globalThis.document,
  } = opts;
  const listeners = new Map();
  const emit = (name, data) => { for (const fn of listeners.get(name) || []) { try { fn(data); } catch (e) { console.error(e); } } };
  const catalog = createCatalog(manifest, assetsBase);
  const timers = createTimers(doc0.defaultView);

  // ---- the shared context every part works with -------------------------------------------------------------------
  const w = {
    doc: doc0, timers, catalog, url: (f) => catalog.url(f), log,
    width: 360, height: 230, baseH: 120, scale: 1, xFrac: 2 / 3, insets: { top: 0, right: 0 },
    myCharacter: "lulu", mySeat: "lulu", outfit: null,
    mood: { dnd: null, focus: false, pomodoroLabel: null, hidden: false },
    suspended: false, visitorMaxStayMs: opts.visitorMaxStayMs ?? VISITS.visitorMaxStayMs,
    emit,
    policy() {
      const p = (typeof policy === "function" ? policy() : policy) || {};
      return {
        allowsIntimate: p.allowsIntimate !== false, allowsCoupleClips: p.allowsCoupleClips !== false,
        partnerCharacter: p.partnerCharacter ?? null, partnerOutfit: p.partnerOutfit ?? null,
      };
    },
    /** Plays the first key's tone, gated like SoundGate: hidden = silent; 勿扰 / 专注 = cards and reminders only. */
    sound(keys, about) {
      if (!sound) return;
      const key = Array.isArray(keys) ? keys[0] : keys;
      if (w.mood.hidden) return;
      if ((w.mood.dnd || w.mood.focus) && !ALWAYS_EVENTS.has(key)) return;
      if (awayOnlyUntil > Date.now() && key !== "awaySummary" && !ALWAYS_EVENTS.has(key)) return;
      sound.play(keys, { visitor: about ?? null, intimateOK: w.policy().allowsIntimate });
    },
    changed() { bubbles.layout(); refreshPose(); },
    homeX: () => w.xFrac * w.width,
    clampX(x) {
      const half = (me.idleWidth || 60) / 2;
      return Math.min(Math.max(half + 2, x), Math.max(half + 2, w.width - half - 2));
    },
    slideMe(x, done) {
      me.el.style.transition = "transform 250ms ease";
      me.el.style.transform = `translateX(${x.toFixed(1)}px)`;
      me.x = x;
      timers.after(260, () => { me.setX(x); done?.(); });
    },
    showCard: (kind, msgs) => card(kind, msgs),
    visitorClicked: () => clickActor(visits.visitor, visits.visitorCharacter),
  };

  // ---- DOM ---------------------------------------------------------------------------------------------------------
  const layer = h(doc0, "div.lw-stage");
  const element = h(doc0, "div.lw-world", { "aria-label": "噜噜的小世界" }, h(doc0, "div.lw-sky"), h(doc0, "div.lw-ground"), layer);
  function tickTimeOfDay() {
    const d = new Date();
    element.dataset.tod = timeOfDay(d.getHours() + d.getMinutes() / 60);
    timers.after(5 * 60_000, tickTimeOfDay);
  }
  tickTimeOfDay();
  w.layer = layer;
  const me = new Actor(w, "me");
  w.me = me;
  me.el.setAttribute("aria-label", "我的宠物");
  const handle = h(doc0, "div.lw-handle", { title: "拖动改变大小", "aria-hidden": "true" });
  me.fx.append(handle);
  layer.append(me.el);
  // Until my pet's first frame is on the canvas (first visit: the sprite sheet is still downloading): a quiet note.
  const loadingNote = h(doc0, "div.lw-loading-note", "正在赶来…");
  layer.append(loadingNote);
  element.classList.add("lw-loading");
  const sizeClip = me.player.onClip;
  me.player.onClip = (clip) => {
    sizeClip?.(clip);
    if (loadingNote.isConnected) { loadingNote.remove(); element.classList.remove("lw-loading"); }
  };

  const bubbles = createBubbles(w, {
    anchorFor: (item) => (item.atHome || !visits.visitor || visits.state === "absent" || visits.state === "leaving" ? me : visits.visitor),
    onShow: (item) => {
      if (item.sound !== undefined) { if (item.sound) w.sound([item.sound]); } else w.sound([item.card ? "awaySummary" : "bubble"]);
      refreshPose();
    },
    onDismiss: (item) => {
      if (item.msg) onRead?.(item.msg);
      for (const m of item.alsoRead || []) onRead?.(m);
      visits.bubbleDismissed(item);
      scheduleIdle();
    },
  });
  w.bubbles = bubbles;
  const visits = new Visits(w);
  const thinker = createThink(w);

  // ---- idle / quiet / doze -----------------------------------------------------------------------------------------
  let lastActivity = Date.now();
  let dozing = false;
  let restQuiet = false;
  let idleTimer = 0, quietTimer = 0, dozeTimer = 0, focusTimer = 0;
  let lastPlain = null, lastWeather = null, lastClick = null;
  let weatherLook = null;
  let thinkLastShown = null, thinkNextIdle = null;
  let lastPose = null;
  let awayOnlyUntil = 0;
  const lastTool = {};

  const busy = () => me.busy || visits.active || dragging || scaling;

  function applyRest() {
    const pose = restPose({ dozing, quiet: restQuiet || !!w.mood.focus, dnd: !!w.mood.dnd });
    me.setRest(pose);
    me.setSign(w.mood.dnd ? (w.mood.dnd.sign || w.mood.dnd.reason || "🔕 勿扰中") : null);
    me.setPill(w.mood.focus && w.mood.pomodoroLabel ? w.mood.pomodoroLabel : null);
    refreshPose();
  }

  function refreshPose() {
    const pose = derivePose({
      hidden: !!w.mood.hidden, dnd: !!w.mood.dnd, focus: !!w.mood.focus, dozing, quiet: restQuiet,
      weather: weatherLook, hasWeatherClips: catalog.weather(w.myCharacter, weatherLook).length > 0,
    });
    if (pose !== lastPose) { lastPose = pose; emit("pose", pose); }
  }

  /** Re-arms the quiet / doze clocks from the last activity; the fidget clock keeps its own rhythm (like the Mac). */
  function scheduleIdle() {
    timers.cancel(quietTimer);
    timers.cancel(dozeTimer);
    if (w.mood.hidden) { timers.cancel(idleTimer); idleTimer = 0; return; }
    if (!idleTimer) idleTimer = timers.after(opts.fidgetMs ?? fidgetDelayMs(Math.random()), fidgetTick);
    if (!restQuiet && !dozing) quietTimer = timers.after(Math.max(0, lastActivity + (opts.quietMs ?? IDLE.quietAfterMs) - Date.now()), quietTick);
    if (!dozing) dozeTimer = timers.after(Math.max(0, lastActivity + (opts.dozeMs ?? IDLE.dozeAfterMs) - Date.now()), dozeTick);
  }

  function quietTick() {
    if (busy() || bubbles.showing) { quietTimer = timers.after(IDLE.retryMs, quietTick); return; }
    restQuiet = true;
    log?.("idle: quiet");
    applyRest();
  }
  function dozeTick() {
    if (busy() || bubbles.showing) { dozeTimer = timers.after(IDLE.retryMs, dozeTick); return; }
    dozing = true;
    log?.("idle: doze");
    w.sound(["doze"]);
    applyRest();
  }

  function fidgetTick() {
    idleTimer = timers.after(opts.fidgetMs ?? fidgetDelayMs(Math.random()), fidgetTick);
    if (w.mood.hidden || dozing || restQuiet || w.mood.dnd || w.mood.focus) return;
    if (busy() || bubbles.showing || thinker.showing) return;
    if (thinkIdleTick()) return;
    const c = me.clips;
    if (!c) return;
    const wx = catalog.weather(w.myCharacter, weatherLook);
    const pick = pickFidget(c.fidgets.length, wx.length, lastPlain, lastWeather, roll);
    if (!pick) return;
    const clip = pick.kind === "weather" ? wx[pick.index] : c.fidgets[pick.index];
    if (pick.kind === "weather") lastWeather = pick.index; else lastPlain = pick.index;
    log?.(`idle: fidget ${clip.name}${pick.kind === "weather" ? " (weather " + weatherLook + ")" : ""}`);
    me.playClip(clip.clip);
  }

  /** The idle 想 TA (20–40 min of active time): asks W4 for TA's scene via "wantThink". */
  function thinkIdleTick() {
    const now = Date.now();
    if (thinkNextIdle == null) { thinkNextIdle = now + thinkIdleDelayMs(Math.random()); return false; }
    if (now < thinkNextIdle) return false;
    if (!thinkShouldShow("idle", thinkContext(), thinkLastShown, now)) return false;
    thinkNextIdle = null;
    emit("wantThink", "idle");
    return true;
  }

  function focusTick() {
    timers.cancel(focusTimer);
    if (!w.mood.focus) return;
    focusTimer = timers.after(60_000, focusTick);
    if (busy() || bubbles.showing || w.mood.hidden) return;
    const name = (catalog.toolPool("focus", w.myCharacter) ?? toolClipPool("focus", w.myCharacter)).find((n) => me.clips?.has(n));
    if (name) { log?.("focus: clip " + name); me.playNamed(name); }
  }

  /** Something happened: wake up (from quiet / doze with a happy beat) and restart the clocks. */
  function activity(cheerOnWake = true) {
    lastActivity = Date.now();
    const woke = dozing || restQuiet;
    dozing = false;
    restQuiet = false;
    if (woke) {
      applyRest();
      if (cheerOnWake && !busy()) me.playAction("happy");
    }
    scheduleIdle();
  }

  // ---- pointer: click / double click / drag / resize / hover / menu ------------------------------------------------
  let dragging = false, scaling = false, press = null, hoverTimer = 0;

  function clickActor(actor, character) {
    if (!actor || actor.busy) return;
    activity(false);
    const funny = clickClips(catalog.reactions, character).filter((n) => actor.clips?.has(n));
    const name = Math.random() < CLICK_CHANCE ? poolPick(funny, lastClick, roll) : null;
    if (name && actor.playNamed(name)) { lastClick = name; log?.("click: funny clip " + name); } else actor.playAction("react");
    actor.hearts();
    w.sound(["click"]);
  }

  function onPointerDown(e) {
    if (e.button !== 0) return;
    const onHandle = e.target === handle;
    if (!onHandle && !me.sprite.contains(e.target)) return;
    if (visits.homeState !== "home" || me.running) return;
    e.preventDefault();
    press = { id: e.pointerId, x0: e.clientX, y0: e.clientY, petX: me.x, scale0: w.scale, handle: onHandle, moved: false };
    try { (onHandle ? handle : me.sprite).setPointerCapture(e.pointerId); } catch { /* ignore */ }
  }
  function onPointerMove(e) {
    if (!press || e.pointerId !== press.id) return;
    const dx = e.clientX - press.x0, dy = e.clientY - press.y0;
    if (!press.moved && Math.hypot(dx, dy) < 4) return;
    press.moved = true;
    if (press.handle) {
      scaling = true;
      const sw = me.idleWidth, sh = me.height;
      const t = (dx * sw + -dy * sh) / (sw * sw + sh * sh);
      applyScale(rubberBand(press.scale0 * (1 + t)));
    } else {
      if (!dragging) { dragging = true; activity(false); me.el.classList.add("lw-dragging"); }
      me.setX(w.clampX(press.petX + dx));
      bubbles.layout();
    }
  }
  function onPointerUp(e) {
    if (!press || e.pointerId !== press.id) return;
    const p = press;
    press = null;
    if (p.handle) {
      if (scaling) { scaling = false; const s = normalizeScale(w.scale); applyScale(s); emit("scaled", s); }
      return;
    }
    if (!p.moved) { clickActor(me, w.myCharacter); emit("clicked"); return; }
    dragging = false;
    me.el.classList.remove("lw-dragging");
    if (visits.homeDragEnded(p.petX)) return;
    w.xFrac = Math.min(1, Math.max(0, me.x / Math.max(1, w.width)));
    emit("dragged", { x: Math.round(w.xFrac * 1000) / 1000 });
  }

  element.addEventListener("pointerdown", onPointerDown);
  element.addEventListener("pointermove", onPointerMove);
  element.addEventListener("pointerup", onPointerUp);
  element.addEventListener("pointercancel", onPointerUp);
  me.sprite.addEventListener("dblclick", () => { activity(false); onCompose?.("compose"); });
  element.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    onMenu?.({ x: e.clientX, y: e.clientY, doc: w.doc });
  });
  me.sprite.addEventListener("pointerenter", () => {
    me.el.classList.add("lw-hover");
    if (restQuiet && !w.mood.dnd) activity(false);
    timers.cancel(hoverTimer);
    hoverTimer = timers.after(THINK.hoverDelayMs, () => {
      if (!me.el.classList.contains("lw-hover")) return;
      if (thinkShouldShow("hover", thinkContext(), thinkLastShown, Date.now())) emit("wantThink", "hover");
    });
  });
  me.el.addEventListener("pointerleave", () => { me.el.classList.remove("lw-hover"); timers.cancel(hoverTimer); });

  // ---- size ----------------------------------------------------------------------------------------------------------
  function applyScale(s) {
    w.scale = s;
    relayout();
  }
  /**
   * New size (or a new document): pets keep their place in proportion, runs carry on from where they are (an
   * off-stage spot stays just off the new edge), the visitor re-plans where it stands. `prevW` = the old width.
   */
  function relayout(prevW = w.width) {
    const mapX = (x) => (prevW > 0 && Math.abs(prevW - w.width) > 0.5
      ? (x < 0 ? x : x > prevW ? w.width + (x - prevW) : (x * w.width) / prevW) : x);
    w.baseH = petHeightFor(w.height, w.scale, w.width);
    me.setBaseHeight(w.baseH);
    if (visits.homeState === "home" && !me.running && !dragging) me.setX(w.clampX(w.homeX()));
    else if (me.running) me.retarget(mapX(me.running.to), mapX(me.liveX));
    else if (!dragging) me.setX(mapX(me.x));
    visits.resized(mapX);
    bubbles.layout();
  }
  let resizeObs = null;
  function observe(win) {
    resizeObs?.disconnect();
    const RO = win.ResizeObserver;
    if (!RO) return;
    resizeObs = new RO(() => {
      const r = element.getBoundingClientRect();
      if (r.width < 10 || r.height < 10) return;
      if (Math.abs(r.width - w.width) < 0.5 && Math.abs(r.height - w.height) < 0.5) return;
      const prevW = w.width;
      w.width = r.width;
      w.height = r.height;
      relayout(prevW);
    });
    resizeObs.observe(element);
  }

  // ---- think / peek -------------------------------------------------------------------------------------------------
  function thinkContext() {
    return {
      solo: false, hidden: !!w.mood.hidden, dnd: !!w.mood.dnd, focus: !!w.mood.focus, quiet: restQuiet || dozing,
      visitActive: visits.active, bubbleShowing: bubbles.onScreen, petBusy: me.busy || dragging || scaling || thinker.showing,
    };
  }

  function think(reason, scene) {
    if (!thinkShouldShow(reason, thinkContext(), thinkLastShown, Date.now())) return false;
    const ok = thinker.show({ scene: scene || {}, peek: false, durationMs: THINK.durationMs, anchor: me });
    if (ok) { thinkLastShown = Date.now(); log?.(`think: 想 TA (${reason})`); }
    return ok;
  }

  let peekWaiting = false;
  function peek(scene) {
    if (peekWaiting) return;
    const since = Date.now();
    const attempt = () => {
      const v = peekVerdict(thinkContext(), scene?.everSeen !== false);
      if (v.verdict === "wait" && Date.now() - since < 30_000) { peekWaiting = true; timers.after(500, attempt); return; }
      peekWaiting = false;
      if (v.verdict === "show") {
        thinker.close();
        const ok = thinker.show({ scene: scene || {}, peek: true, durationMs: THINK.peekDurationMs, anchor: me, done: () => onPeekDone?.("closed") });
        if (ok) { thinkLastShown = Date.now(); log?.("peek: shown"); onPeekDone?.("shown"); } else onPeekDone?.("ignored");
      } else if (v.verdict === "toast") { me.toast(v.text, 3000); onPeekDone?.("toast"); } else onPeekDone?.("ignored");
    };
    attempt();
  }

  // ---- cards + own bubbles -----------------------------------------------------------------------------------------
  function card(kind, msgs) {
    const list = (msgs || []).filter(Boolean);
    const s = summarize(list, Date.now(), w.mySeat);
    const parts = summaryParts(s);
    if (!parts.length) { list.forEach((m) => onRead?.(m)); return false; }
    const followers = list.filter((m) => m.kind === "text" || m.kind === "sticker");
    const collapse = followers.length > 3;
    // The card sums every message up, so seeing it (on screen) or dismissing it reads them all — the texts / stickers
    // still replay as bubbles after it, but a reload no longer counts them again in 「你不在的时候」.
    const item = {
      header: cardTitle(kind, list.length), atHome: kind === "trip",
      card: { lines: [parts.join(" · ")], preview: collapse ? s.latestText : null, button: "看看", onClick: () => onCompose?.("history") },
      alsoRead: list,
      onShown: () => { if (!w.suspended && !w.doc.hidden) list.forEach((m) => onRead?.(m)); },
    };
    log?.(`card ${kind}: ${parts.join(" / ")}; ${collapse ? "collapsed" : followers.length + " bubble(s) follow"}`);
    activity();
    awayOnlyUntil = Date.now() + 8000;   // only the card's sound, not one per replayed message
    if (kind === "trip") bubbles.enqueue(item);
    else {
      const visit = { kind: "visit", ts: Date.now(), character: w.policy().partnerCharacter ?? undefined };
      const e = visits.event(visit, { live: true, bubble: item });
      visits.partner(e);
    }
    if (!collapse) for (const m of followers) incoming(m, { live: false });
    return true;
  }

  function bubble({ header = "", line = "", buttons = [], tag = null, replace = true, autoHide = null, sound: snd = "remind", urgent = false } = {}) {
    return new Promise((resolve) => {
      let settled = false;
      const done = (v) => { if (!settled) { settled = true; resolve(v); } };
      const item = {
        header, text: line, tag, atHome: true, autoHide, sound: snd, urgent,
        buttons: buttons.map((b) => (typeof b === "string" ? { title: b } : b)),
        onButton: (i) => done(i), onClose: () => done(null), onReplaced: () => done(null),
      };
      activity(false);
      if (tag != null && replace && bubbles.replace(item)) { if (snd) w.sound([snd]); return; }
      bubbles.enqueue(item);
    });
  }

  // ---- incoming --------------------------------------------------------------------------------------------------
  function incoming(msg, { live = true } = {}) {
    return new Promise((resolve) => {
      if (!msg) { resolve("dropped"); return; }
      activity();
      const reply = decodeReply(msg);
      if (reply) {
        me.playAction("happy");
        bubbles.enqueue({ header: nameOf(visits.characterFor(msg)), text: replyLine(reply), atHome: true, autoHide: 4000, tag: msg.id });
        onRead?.(msg);
        resolve("shown");
        return;
      }
      const action = visits.incomingAction(msg);
      if (action === "queueForCard") { visits.queueForCard(msg); log?.(`incoming ${msg.kind}: kept for the trip card`); resolve("queued"); return; }
      const item = visits.bubbleItem(msg, (answer) => onReply?.(msg, answer));
      if (item && msg.id != null) item.tag = msg.id;
      const e = visits.event(msg, { live, bubble: item });
      e.done = (outcome) => { if (!item && outcome !== "dropped") onRead?.(msg); resolve(outcome); };
      if (action === "collision") visits.collide(msg, e);
      else visits.partner(e);
    });
  }

  // ---- mood / me / weather -------------------------------------------------------------------------------------------
  function setMood({ dnd = w.mood.dnd, focus = w.mood.focus, pomodoroLabel = w.mood.pomodoroLabel, hidden = w.mood.hidden } = {}) {
    const wasHidden = w.mood.hidden, wasFocus = !!w.mood.focus;
    w.mood = { dnd: dnd || null, focus: !!focus, pomodoroLabel: pomodoroLabel || null, hidden: !!hidden };
    if (w.mood.hidden && !wasHidden) {
      const back = visits.reset();
      back.forEach((b) => bubbles.enqueue({ ...b, atHome: true }));
      thinker.close();
      w.suspended = true;
      bubbles.render();
      element.classList.add("lw-hidden");
    } else if (!w.mood.hidden && wasHidden) {
      w.suspended = false;
      element.classList.remove("lw-hidden");
      bubbles.render();
    }
    if (w.mood.focus && !wasFocus) focusTimer = timers.after(1500, focusTick);
    if (!w.mood.focus) timers.cancel(focusTimer);
    applyRest();
    scheduleIdle();
  }

  let resizingTimer = 0;
  function setMe({ character, outfit, scale, x, seat } = {}) {
    const c = catalog.characterOf(character ?? w.myCharacter);
    if (seat === "lulu" || seat === "lumei") w.mySeat = seat;
    else if (character) w.mySeat = c;
    const o = catalog.outfitOf(c, outfit ?? w.outfit);
    if (c !== w.myCharacter && visits.active) {
      const back = visits.reset();
      back.forEach((b) => bubbles.enqueue({ ...b, atHome: true }));
    }
    const changed = c !== w.myCharacter || o !== w.outfit;
    w.myCharacter = c;
    w.outfit = o;
    if (Number.isFinite(x)) w.xFrac = Math.min(1, Math.max(0, x));
    if (Number.isFinite(scale) && normalizeScale(scale) !== w.scale) {
      w.scale = normalizeScale(scale);
      // A size picked in the menu / settings grows or shrinks smoothly (a drag on the handle follows the pointer).
      element.classList.add("lw-resizing");
      timers.cancel(resizingTimer);
      resizingTimer = timers.after(320, () => element.classList.remove("lw-resizing"));
    }
    if (changed || !me.clips) me.setClips(catalog.outfit(c, o));
    relayout();
    applyRest();
  }

  function setWeather(look) {
    weatherLook = typeof look === "string" && look ? look : null;
    refreshPose();
  }

  // ---- mounting --------------------------------------------------------------------------------------------------------
  function mountIn(doc, parent) {
    if (parent) parent.append(element);
    w.doc = doc;
    timers.rehome(doc.defaultView);
    if (!doc.querySelector("link[data-lulu-world]")) {
      const link = doc.createElement("link");
      link.rel = "stylesheet";
      link.href = CSS_URL;
      link.dataset.luluWorld = "1";
      doc.head.append(link);
    }
    sound?.unlock?.(doc);
    observe(doc.defaultView);
    const prevW = w.width;
    const r = element.getBoundingClientRect();
    if (r.width > 10 && r.height > 10) { w.width = r.width; w.height = r.height; }
    relayout(prevW);
  }

  setMe({});
  scheduleIdle();

  return {
    element,
    mountIn,
    setMe,
    setMood,
    setWeather,
    activity: () => activity(),
    /** TA came online: a happy beat. */
    cheer() { activity(false); if (!busy()) { me.playAction("happy"); me.hearts(); } },
    /**
     * One of my own tools fired (eyedrops | water | stand | focus | breakTime): a ToolClips clip from the manifest
     * (random, not the same one twice), else `happy`. Skipped while the pet is busy (running / visiting / dragged).
     * → the clip name played, "happy", or null.
     */
    playTool(kind) {
      activity(false);
      if (busy() || w.mood.hidden) return null;
      const pool = (catalog.toolPool(kind, w.myCharacter) ?? toolClipPool(kind, w.myCharacter)).filter((n) => me.clips?.has(n));
      const name = poolPick(pool, lastTool[kind] ?? null, roll);
      if (name && me.playNamed(name)) { lastTool[kind] = name; log?.(`tool ${kind}: clip ${name}`); return name; }
      log?.(`tool ${kind}: happy`);
      return me.playAction("happy") ? "happy" : null;
    },
    incoming,
    card,
    goDeliver(msg, verdict) {
      activity(false);
      thinker.close();
      return visits.goDeliver(msg, verdict).finally(() => { refreshPose(); scheduleIdle(); });
    },
    think,
    peek,
    bubble,
    closeBubble: (tag) => bubbles.close(tag),
    /** The top-right box (px) the page keeps for its own buttons; bubbles stay out of it ({top: 0, right: 0} = none). */
    setInsets({ top = 0, right = 0 } = {}) { w.insets = { top, right }; bubbles.layout(); },
    on(name, fn) {
      if (!listeners.has(name)) listeners.set(name, new Set());
      listeners.get(name).add(fn);
      return () => listeners.get(name)?.delete(fn);
    },
    /** Dev / tests: a peek at the internals. */
    debug: { w, visits, bubbles, thinker, me, get state() { return { dozing, restQuiet, pose: lastPose, visitor: visits.state, home: visits.homeState }; } },
  };
}
