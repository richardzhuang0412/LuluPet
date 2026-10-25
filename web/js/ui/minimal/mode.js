// 极简模式 prefs in `lulupet.minimal` (per device), plus the neutral title / favicon (低调标题).

import { store } from "../store.js";
import { decodePrefs } from "./logic.js";

export const minimalPrefs = {
  get: () => decodePrefs(store.get("minimal", null)),
  /** patch any of {on, chime, thumbs, hideContent, discreet}. */
  set(patch) {
    const { chosen, ...cur } = minimalPrefs.get();
    void chosen;
    store.set("minimal", { ...cur, ...patch });
  },
};

export const isPhone = () => matchMedia("(pointer: coarse) and (max-width: 479px)").matches;
export const finePointer = () => matchMedia("(pointer: fine)").matches;

/** Switch modes: saved, then the page reloads into the other layout. */
export function switchMode(on) {
  minimalPrefs.set({ on: !!on });
  location.reload();
}

const ICONS = { normal: "icons/favicon-32.png", discreet: "icons/bell-32.png" };
/** The tab icon: the orange or a plain bell (低调标题). */
export function setFavicon(discreet) {
  const link = document.querySelector('link[rel="icon"]');
  if (!link) return;
  const href = new URL("../../../" + (discreet ? ICONS.discreet : ICONS.normal), import.meta.url).href;
  if (link.href !== href) link.href = href;
}
export const notifyIcon = (discreet) => (discreet ? new URL("../../../icons/bell-192.png", import.meta.url).href : null);
