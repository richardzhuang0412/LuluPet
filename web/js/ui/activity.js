// "Is the user at the computer?" (spec §2.4 rule 4, §13.4 of v1): IdleDetector once the user allowed it (threshold
// 300 s, userState active and screen unlocked); without it, the page being visible or input in the last 5 minutes.
// Input is watched on the main document and on the PiP document (watchInput(doc) once per document).

import { reminders as R } from "./deps.js";

const INPUT_WINDOW_MS = 5 * 60_000;
let lastInput = Date.now();
let detector = null;
const watched = new WeakSet();
const listeners = new Set();

export function watchInput(doc) {
  if (watched.has(doc)) return;
  watched.add(doc);
  for (const t of ["pointerdown", "keydown", "pointermove", "wheel", "touchstart"]) {
    doc.addEventListener(t, () => { lastInput = Date.now(); }, { passive: true, capture: true });
  }
}

export const idleSupported = () => "IdleDetector" in window;

export async function idlePermission() {
  if (!idleSupported()) return "unsupported";
  try { return (await navigator.permissions.query({ name: "idle-detection" })).state; } catch { return "prompt"; }
}

/** Needs a user gesture the first time. */
export async function requestIdle() {
  if (!idleSupported()) return "unsupported";
  try {
    const p = await window.IdleDetector.requestPermission();
    if (p === "granted") await startIdle();
    return p;
  } catch { return "denied"; }
}

export async function startIdle() {
  if (detector || !idleSupported()) return;
  try {
    const d = new window.IdleDetector();
    d.addEventListener("change", () => { for (const fn of listeners) fn(isActive()); });
    await d.start({ threshold: R.awayThreshold * 1000 });
    detector = d;
  } catch { detector = null; }
}

export function isActive() {
  if (detector) return detector.userState === "active" && detector.screenState === "unlocked";
  return !document.hidden || Date.now() - lastInput < INPUT_WINDOW_MS;
}

/** fn(active) when the IdleDetector reports a change (only with the permission). */
export function onActiveChange(fn) { listeners.add(fn); }
