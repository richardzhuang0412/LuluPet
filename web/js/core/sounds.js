// Sound rules (port of SoundEvent / SoundDefaults / SoundManifest / SoundPicker / SoundGate in
// Sources/LuluCore/Sounds.swift). Playing is the world's `sound.js`; this only decides which file and whether.
// Manifest input (assets manifest `sounds`, same as sounds.json): {"<event>": "f.m4a" | {file, visitor?, intimate?} | [...]}.
// Parsed: {entries: {event: [file]}, only: {event: {file: role}}, intimate: {event: [file]}}.

import { poolPick } from "./reactions.js";

export const SOUND_EVENTS = Object.freeze([
  "arrive", "leave", "poke", "hug", "kiss", "nuzzle", "bubble", "angry", "cry", "happy", "doze",
  "awaySummary", "goVisit", "goBack", "notHome", "click",
]);
export const BGM_KEY = "bgm";
export const SOUND_DEFAULTS = Object.freeze({ enabled: true, volume: 0.25, bgmEnabled: false, bgmFactor: 0.5, throttle: 0.3 });
export const VOLUME_PRESETS = Object.freeze([{ title: "小", volume: 0.25 }, { title: "中", volume: 0.5 }, { title: "大", volume: 0.8 }]);

const COUPLE_PREFIXES = [
  ["kiss", "kiss"], ["nuzzle", "nuzzle"], ["hug", "hug"], ["angry", "angry"],
  ["cuddle", "nuzzle"], ["lean", "nuzzle"], ["sniff", "nuzzle"], ["comfort", "hug"],
  ["coldwar", "angry"], ["shout", "angry"], ["bite", "poke"], ["sleep", "doze"],
];

/** Meeting sound for a couple clip name (prefix rules); anything else / none → happy. */
export function forCouple(name) {
  if (name == null) return "happy";
  for (const [p, e] of COUPLE_PREFIXES) if (name.startsWith(p)) return e;
  return "happy";
}

const STICKER_SOUND = {};
for (const id of ["angry", "heng", "heng2", "lengzhan", "xiongni"]) STICKER_SOUND[id] = "angry";
for (const id of ["cry", "anwei", "weiqu", "xinsui", "xiasi", "leitan", "aqi"]) STICKER_SOUND[id] = "cry";
for (const id of ["happy", "celebrate", "haha", "haha2", "xiaosi", "heihei", "heihei2", "wow", "haode", "biye", "ye", "jiayou", "facai", "shengdan"]) {
  STICKER_SOUND[id] = "happy";
}

/** Built-in sound for a sticker's reaction (angry / cry / happy), null = none. */
export function forSticker(id) {
  return (id != null && Object.hasOwn(STICKER_SOUND, id)) ? STICKER_SOUND[id] : null;
}

/** Keys to try for a meeting, in order: reaction pool, the clip's bound sound, the sticker fallback, the category. */
export function meetingKeys(reaction, clipSound, fallback, couple) {
  return [...(reaction ?? []), ...(clipSound != null ? [clipSound] : []), ...(fallback ?? []), forCouple(couple)];
}

/** Index of the preset nearest `volume`. */
export function presetIndex(volume) {
  let best = 0;
  VOLUME_PRESETS.forEach((p, i) => { if (Math.abs(p.volume - volume) < Math.abs(VOLUME_PRESETS[best].volume - volume)) best = i; });
  return best;
}

const ROLES = ["lulu", "lumei"];

/** Tolerant manifest parse (non-strings, empty names and duplicates dropped; keys without files omitted). */
export function parseSoundManifest(obj) {
  const entries = {}, only = {}, intimate = {};
  if (obj === null || typeof obj !== "object" || Array.isArray(obj)) return { entries, only, intimate };
  for (const [key, value] of Object.entries(obj)) {
    const raw = Array.isArray(value) ? value : [value];
    const list = [], filters = {}, intim = [];
    for (const item of raw) {
      let file = null, who = null, isIntimate = false;
      if (typeof item === "string") file = item;
      else if (item && typeof item === "object" && !Array.isArray(item)) {
        file = typeof item.file === "string" ? item.file : null;
        who = ROLES.includes(item.visitor) ? item.visitor : null;
        isIntimate = item.intimate === true;
      }
      if (!file || list.includes(file)) continue;
      list.push(file);
      if (who) filters[file] = who;
      if (isIntimate) intim.push(file);
    }
    if (list.length) {
      entries[key] = list;
      if (Object.keys(filters).length) only[key] = filters;
      if (intim.length) intimate[key] = intim;
    }
  }
  return { entries, only, intimate };
}

/** Files of `key` that may play for `visitor` (null = neutral files only); `allowIntimate` false drops intimate ones. */
export function soundFiles(manifest, key, visitor = null, allowIntimate = true) {
  const filters = manifest.only?.[key] ?? {};
  const blocked = allowIntimate ? [] : manifest.intimate?.[key] ?? [];
  return (manifest.entries?.[key] ?? []).filter((f) => !blocked.includes(f) && (filters[f] == null || filters[f] === visitor));
}

/** Random file per play, never the previous file of that key again when there is a choice. */
export class SoundPicker {
  constructor() { this.last = {}; }
  pick(key, files, rand = Math.random) {
    const f = poolPick(files, this.last[key], rand);
    if (f != null) this.last[key] = f;
    return f;
  }
}

/**
 * Mute / hidden / throttle gate. `decide(event, now)` → "play" | "muted" | "hidden" | "throttled" | "awayOnly"
 * (seconds, any monotonic clock); a "play" records the start.
 */
export class SoundGate {
  constructor(enabled = SOUND_DEFAULTS.enabled, throttle = SOUND_DEFAULTS.throttle) {
    this.enabled = enabled;
    this.hidden = false;
    this.throttle = throttle;
    this.awayOnlyUntil = null;
    this.lastStart = {};
  }
  decide(event, now) {
    if (!this.enabled) return "muted";
    if (this.hidden) return "hidden";
    if (this.awayOnlyUntil != null) {
      if (now >= this.awayOnlyUntil) this.awayOnlyUntil = null;
      else if (event !== "awaySummary") return "awayOnly";
    }
    const last = this.lastStart[event];
    if (last != null && now - last < this.throttle) return "throttled";
    this.lastStart[event] = now;
    return "play";
  }
  get allowsBGM() { return this.enabled && !this.hidden; }
  beginAwayOnly(now, duration) { this.awayOnlyUntil = now + duration; }
  endAwayOnly() { this.awayOnlyUntil = null; }
}
