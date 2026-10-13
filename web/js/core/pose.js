// What my pet looks like, as published in presence `pose` (port of PetPose.derive, ThinkPoseLook, ThinkOutfit in
// Sources/LuluCore/PresenceLook.swift). Parsing an incoming pose word is presence.js `normalizePose`.

export { normalizePose, cleanOutfit } from "./presence.js";

/** Priority: hidden → 勿扰 → focus → doze → quiet → weather (if this character has clips for it) → idle. */
export function derivePose({ hidden = false, dnd = false, focus = false, dozing = false, quiet = false, weather = null, hasWeatherClips = false } = {}) {
  if (hidden) return "hidden";
  if (dnd) return "dnd";
  if (focus) return "focus";
  if (dozing) return "doze";
  if (quiet) return "quiet";
  if (weather && hasWeatherClips) return `weather:${weather}`;
  return "idle";
}

/**
 * What the 想 TA bubble draws for TA's pose → "idleLoop" | "dozeStill" | "quietStill" | "focusClip" | "focusStill" |
 * "dndStill" | "weatherClip:<look>". `hasWeatherClip(look)` → bool.
 */
export function thinkPoseLook(pose, hasFocusClip, hasWeatherClip = () => false) {
  const p = pose ?? "idle";
  switch (p) {
    case "doze": return "dozeStill";
    case "quiet": return "quietStill";
    case "focus": return hasFocusClip ? "focusClip" : "focusStill";
    case "dnd": return "dndStill";
    default:
      if (p.startsWith("weather:")) return hasWeatherClip(p.slice(8)) ? `weatherClip:${p.slice(8)}` : "idleLoop";
      return "idleLoop";
  }
}

const SIGNS = { angry: "😤 生气中", busy: "💼 忙碌中", resting: "😴 休息中" };
/** TA's 勿扰 sign in the bubble: the reason, or 「🔕 勿扰中」. */
export function dndSign(dnd) {
  return SIGNS[dnd?.mood] ?? "🔕 勿扰中";
}

/** The outfit the bubble draws: TA's published → their last message's → preferred; only names in `available`. */
export function thinkOutfit(published, lastMessage, available, preferred) {
  for (const c of [published, lastMessage, preferred]) if (c != null && available.includes(c)) return c;
  return available[0] ?? null;
}
