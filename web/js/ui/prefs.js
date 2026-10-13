// Display / sound preferences (spec §4.2, §4.6): `lulupet.sound` = {on, volume, bgm} (default on / 0.25 / off, like
// the Mac), `lulupet.petScale` (0.6…1.6, two decimals; 小 0.75 / 标准 1.0 / 大 1.3). Bad data = defaults.

import { store } from "./store.js";

export const SIZES = [{ label: "小", value: 0.75 }, { label: "标准", value: 1 }, { label: "大", value: 1.3 }];
export const VOLUMES = [{ label: "小", value: 0.25 }, { label: "中", value: 0.5 }, { label: "大", value: 0.8 }];

const clampScale = (v) => (Number.isFinite(v) ? Math.round(Math.min(1.6, Math.max(0.6, v)) * 100) / 100 : 1);

export const prefs = {
  get() {
    const s = store.get("sound", null) || {};
    return {
      petScale: clampScale(store.get("petScale", 1)),
      sound: {
        on: typeof s.on === "boolean" ? s.on : true,
        volume: Number.isFinite(s.volume) ? Math.min(1, Math.max(0, s.volume)) : 0.25,
        bgm: s.bgm === true,
      },
    };
  },
  set(patch) {
    if (patch.petScale != null) store.set("petScale", clampScale(patch.petScale));
    if (patch.sound) store.set("sound", { ...prefs.get().sound, ...patch.sound });
  },
};
