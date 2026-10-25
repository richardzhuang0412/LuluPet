// 桌宠小窗 — the desktop-pet feel in plain Chrome, nothing installed (work laptops may forbid installing apps).
// A button in the tab opens `?window=pet` in a small Chrome popup (window.open "popup"); script-opened popups may
// resize / move themselves, so that page runs the 桌宠模式 layout (petmode.js) like the installed app did.
//
// One owner at a time — the popup is a full copy of the app and the tab steps aside:
//   · the popup holds the Web Lock PET_LOCK for as long as it is open and says 「pet-open」 on a BroadcastChannel;
//   · every normal tab that hears it (or starts while the lock is held) reloads into the parked page: no world, no
//     channel, no reminders — just 「噜噜在桌宠小窗里」 + 收回来 — so the popup gets the channel's own lock and nothing
//     runs twice;
//   · the parked page queues for PET_LOCK; the moment the popup closes (or crashes, or the user quits it) the lock is
//     free and the tab reloads into the full app.
// `lulupet.petPopup` = the user wants the pet in its own window: set when it opens, cleared when they bring it back
// (收回来, or closing the popup while the tab is still there). Still set at the next start = Chrome was quit with
// the pet out → the tab offers a one-click reopen (a popup needs a click).

import { store } from "./store.js";
import { petPopupUrl, popupFeatures } from "./petwindow-math.js";

export const PET_LOCK = "lulupet-petwindow";
const BC_NAME = "lulupet-petwindow";
const WINDOW_NAME = "lulupet-pet";

export const isPetPopup = () => new URLSearchParams(location.search).get("window") === "pet";
export const popupSupported = () => !!globalThis.navigator?.locks?.request && typeof BroadcastChannel === "function";

const availOf = (s) => ({ left: s.availLeft ?? 0, top: s.availTop ?? 0, width: s.availWidth, height: s.availHeight });

/** From a click: opens (or focuses) the pet popup. → the window, or null when Chrome blocked it. */
export function openPetPopup({ scale }) {
  let w = null;
  try {
    w = window.open(petPopupUrl(location.href), WINDOW_NAME, popupFeatures({ scale, saved: store.get("petWindow", null), avail: availOf(window.screen) }));
  } catch { w = null; }
  if (!w) return null;
  store.set("petPopup", true);
  try { w.focus(); } catch { /* ignore */ }
  return w;
}

/** True while a pet popup is open somewhere in this browser profile. */
export async function petPopupOpen() {
  try {
    const q = await navigator.locks.query();
    return (q.held || []).some((l) => l.name === PET_LOCK);
  } catch { return false; }
}

/** In the popup: hold the lock for life, announce, close when a tab asks for the pet back. */
export function claimPetWindow() {
  return new Promise((resolve) => {
    navigator.locks.request(PET_LOCK, () => { resolve(); return new Promise(() => {}); }).catch(() => resolve());
  }).then(() => {
    const bc = new BroadcastChannel(BC_NAME);
    bc.onmessage = (e) => { if (e.data?.type === "close-pet") window.close(); };
    bc.postMessage({ type: "pet-open" });
  });
}

/** In a normal tab running the app: the popup opened → step aside (fn reloads into the parked page). */
export function onPetOpened(fn) {
  if (!popupSupported()) return;
  const bc = new BroadcastChannel(BC_NAME);
  bc.onmessage = (e) => { if (e.data?.type === "pet-open") fn(); };
}

/** In the parked tab: ask the popup to close itself (script-opened windows may). */
export function askPetBack() {
  store.set("petPopup", false);
  const bc = new BroadcastChannel(BC_NAME);
  bc.postMessage({ type: "close-pet" });
  bc.close();
}

/** In the parked tab: fn() once no popup holds the lock any more (it returns right away if none does). */
export function whenPetGone(fn) {
  navigator.locks.request(PET_LOCK, () => { fn(); }).catch(() => fn());
}
