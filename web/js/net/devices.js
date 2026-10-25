// This device's activity record, /pairs/{code}/devices/{seat}/{deviceId} (schema: js/core/devices.js; spec
// docs/superpowers/specs/2026-10-22-web-push.md §2.1). The push functions read it to send notifications to the device
// I'm actually using: an idle-but-awake home Mac no longer swallows the phone's pushes, and an open phone app / a work
// laptop in use don't get a duplicate push.
//
//   startDeviceActivity({config, deviceId})   once, from app.js run() → {watch(doc), stop(), writer}
//
// Writes (PUT the whole record): on real input at most once per 60 s (plus a trailing write so activeAt catches up),
// immediately on visibilitychange (keepalive when hiding: iOS freezes the page right after), and a heartbeat every
// 5 minutes while the page is open. With the IdleDetector permission (granted in 设置 for the reminders), input
// anywhere on the computer counts too, so a background tab on a laptop in use still says "in use".

import { createFirebase } from "./firebase.js";
import { isIOS } from "./push.js";
import { deviceRecord, HEARTBEAT_MS, INPUT_WRITE_MS } from "../core/devices.js";

export const INPUT_EVENTS = Object.freeze(["pointerdown", "keydown", "pointermove", "wheel", "touchstart"]);
/** Trailing-write / IdleDetector poll / heartbeat check interval (hidden tabs get ~1 timer a minute anyway). */
export const TICK_MS = 60_000;
/** IdleDetector's smallest threshold: userState "active" = input within the last minute. */
export const IDLE_THRESHOLD_MS = 60_000;

/** "phone": an iOS home-screen app, or a coarse pointer on a small screen; else "web" (a desktop browser). */
export function deviceKind({ nav, matchMedia, screen, standalone }) {
  if (isIOS(nav) && standalone) return "phone";
  const coarse = typeof matchMedia === "function" && !!matchMedia("(pointer: coarse)")?.matches;
  const small = !!screen && Math.min(screen.width || Infinity, screen.height || Infinity) <= 600;
  return coarse && small ? "phone" : "web";
}

/**
 * The throttling, without DOM or network. write(record, keepalive) is called with the record to PUT.
 *   input()            real user input (throttled)
 *   visibility(vis)    "visible" | "hidden" (writes at once; becoming visible counts as input)
 *   tick()             every TICK_MS: trailing write for throttled input, else the heartbeat when due
 *   start()            the first write
 */
export function createActivityWriter({ kind, write, now, visible = true }) {
  let vis = visible ? "visible" : "hidden";
  let lastInput = visible ? now() : 0;
  let lastWrite = -Infinity;
  let writtenActiveAt = -1;
  const send = (keepalive = false) => {
    lastWrite = now();
    writtenActiveAt = lastInput;
    write(deviceRecord({ kind, activeAt: lastInput, at: lastWrite, vis }), keepalive);
  };
  return {
    start() { send(); },
    input() {
      lastInput = now();
      if (lastInput - lastWrite >= INPUT_WRITE_MS) send();
    },
    visibility(v) {
      vis = v === "hidden" ? "hidden" : "visible";
      if (vis === "visible") lastInput = now();
      send(vis === "hidden");
    },
    tick() {
      const t = now();
      if ((lastInput > writtenActiveAt && t - lastWrite >= INPUT_WRITE_MS) || t - lastWrite >= HEARTBEAT_MS) send();
    },
    state: () => ({ kind, vis, lastInput, lastWrite }),
  };
}

async function idleDetector(win, nav) {
  if (typeof win?.IdleDetector !== "function") return null;
  try {
    if ((await nav.permissions.query({ name: "idle-detection" })).state !== "granted") return null;
    const d = new win.IdleDetector();
    await d.start({ threshold: IDLE_THRESHOLD_MS });
    return d;
  } catch {
    return null;
  }
}

export function startDeviceActivity({
  config, deviceId, fetch,
  doc = globalThis.document, win = globalThis.window, nav = globalThis.navigator, now = () => Date.now(),
  setInterval: setIv = globalThis.setInterval, clearInterval: clearIv = globalThis.clearInterval,
} = {}) {
  const fb = createFirebase({ databaseURL: config.databaseURL, pairCode: config.pairCode, fetch });
  const path = `devices/${config.seat}/${deviceId}`;
  const mm = typeof win?.matchMedia === "function" ? (q) => win.matchMedia(q) : null;
  const standalone = !!mm?.("(display-mode: standalone)")?.matches || nav?.standalone === true;
  const kind = deviceKind({ nav, matchMedia: mm, screen: win?.screen, standalone });
  const writer = createActivityWriter({
    kind, now, visible: doc.visibilityState !== "hidden",
    write: (rec, keepalive) => { fb.put(path, rec, { keepalive }).catch(() => {}); },
  });

  const onInput = () => writer.input();
  const docs = new Set();
  const watch = (d) => {
    if (!d || docs.has(d)) return;
    docs.add(d);
    for (const t of INPUT_EVENTS) d.addEventListener(t, onInput, { passive: true, capture: true });
  };
  watch(doc);
  const onPip = (e) => watch(e?.window?.document);   // 画中画 window: its input counts too
  win?.documentPictureInPicture?.addEventListener?.("enter", onPip);
  const onVis = () => writer.visibility(doc.visibilityState === "hidden" ? "hidden" : "visible");
  doc.addEventListener("visibilitychange", onVis);

  let idle = null;
  const idleActive = () => !!idle && idle.userState === "active" && idle.screenState === "unlocked";
  idleDetector(win, nav).then((d) => {
    idle = d;
    d?.addEventListener("change", () => { if (idleActive()) writer.input(); });
  });
  const timer = setIv(() => { if (idleActive()) writer.input(); writer.tick(); }, TICK_MS);
  writer.start();

  return {
    writer,
    watch,
    stop() {
      clearIv(timer);
      doc.removeEventListener("visibilitychange", onVis);
      for (const d of docs) for (const t of INPUT_EVENTS) d.removeEventListener(t, onInput, { capture: true });
      win?.documentPictureInPicture?.removeEventListener?.("enter", onPip);
    },
  };
}
