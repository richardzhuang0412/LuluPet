// What to show (pure): presence → idle scene, message → message scene. The renderer turns a scene into frames.
// Message / presence rules come from the web client's core modules (not forked).
//
// Scene = {kind, character, outfit, clip?, still?, dim?, badge?, zzz?, hearts?, text?, line?, sticker?, durationMs}

import { dndActive, focusActive, isOnline } from "../../../web/js/core/presence.js";
import { stickerFallbackLabel, unknownStickerText } from "../../../web/js/core/message.js";
import { decodeReply, replyLine, reminderKind } from "../../../web/js/core/remind.js";
import { VISIT_GREETING } from "../../../web/js/core/visits.js";

export const REMIND_LINES = Object.freeze({ water: "喝水啦 💧", stand: "起来动动 🧍" });
export const UNKNOWN_LINE = "有新消息～";

/** {character, outfit} for the seat: the message's own look first, then presence, then the defaults. */
export function pickLook(manifest, { msg = null, presence = null, watchSeat = "lulu" } = {}) {
  const chars = manifest.characters ?? {};
  const want = [msg?.character, presence?.character, watchSeat, "lulu", ...Object.keys(chars)];
  const character = want.find((c) => c && chars[c]);
  const ch = chars[character];
  const outfits = ch?.outfits ?? {};
  const presOutfit = presence && (presence.character ?? watchSeat) === character ? presence.outfit : null;
  const outfit = [msg?.outfit, presOutfit, ch?.order?.[0], Object.keys(outfits)[0]].find((o) => o && outfits[o]);
  return { character, outfit };
}

function outfitOf(manifest, look) {
  return manifest.characters?.[look.character]?.outfits?.[look.outfit] ?? null;
}

/** Clip key of an action ("idle" | "happy" | "react" | "sleep" | "quiet"), or null. */
export function actionClip(manifest, look, action) {
  return outfitOf(manifest, look)?.actions?.[action] ?? null;
}

/** First clip of the toolClips pool for `kind` that this outfit has (Mac: pick from the pool); null = none. */
export function toolClip(manifest, look, kind, rand = Math.random) {
  const pool = manifest.toolClips?.[kind]?.[look.character] ?? [];
  const named = outfitOf(manifest, look)?.named ?? {};
  const usable = pool.map((n) => named[n]).filter(Boolean);
  if (!usable.length) return null;
  return usable[Math.min(usable.length - 1, Math.floor(rand() * usable.length))];
}

/** "online" | "dnd" | "focus" | "offline" for the watched seat's presence at `now`. */
export function presenceState(presence, now) {
  if (!presence) return "offline";
  if (dndActive(presence.dnd, now)) return "dnd";
  if (focusActive(presence.focus, now)) return "focus";
  return isOnline(presence.lastSeen, now) ? "online" : "offline";
}

/**
 * Idle scene for the presence. online → idle loop; 勿扰 / 专注 → quiet still frame + 🔕 / 🍅 badge (also while
 * offline: a running 勿扰 stays visible after sign-off); offline → the sleep clip if the outfit has one, else idle frame
 * 0 dimmed + Zzz. `key` changes exactly when the picture should change.
 */
export function idleScene(manifest, presence, now, { watchSeat = "lulu" } = {}) {
  const look = pickLook(manifest, { presence, watchSeat });
  const state = presenceState(presence, now);
  const idle = actionClip(manifest, look, "idle");
  let scene;
  if (state === "online") scene = { kind: "idle", clip: idle };
  else if (state === "dnd" || state === "focus") {
    scene = { kind: "idle", clip: actionClip(manifest, look, "quiet") ?? idle, still: true, badge: state };
  } else {
    const sleep = actionClip(manifest, look, "sleep");
    scene = sleep ? { kind: "idle", clip: sleep, dim: 0.75 } : { kind: "idle", clip: idle, still: true, dim: 0.45, zzz: true };
  }
  Object.assign(scene, look, { state, refClip: idle });
  scene.key = ["idle", state, look.character, look.outfit, scene.clip].join(":");
  return scene;
}

/** The still frame shown during quiet hours in "dim" mode. */
export function nightScene(manifest, presence, { watchSeat = "lulu" } = {}) {
  const look = pickLook(manifest, { presence, watchSeat });
  const idle = actionClip(manifest, look, "idle");
  return { kind: "idle", ...look, clip: idle, refClip: idle, still: true, dim: 0.5, state: "night", key: `night:${look.character}:${look.outfit}` };
}

/**
 * Scene for a message from the watched seat. `durations` = config.durations.
 * poke → happy + hearts; text → character + paged text; sticker → full-screen sticker; visit → runs in, then idle
 * + greeting; remind → tool clip + 「喝水啦 💧」; a reply to my reminder → 「TA 说马上喝 💧」…; unknown → happy + line.
 */
export function messageScene(manifest, msg, presence, { watchSeat = "lulu", durations = {}, rand = Math.random } = {}) {
  const look = pickLook(manifest, { msg, presence, watchSeat });
  const idle = actionClip(manifest, look, "idle");
  const happy = actionClip(manifest, look, "happy") ?? idle;
  const base = { ...look, refClip: idle, msgId: msg.id };
  const d = (k, dflt) => durations[k] ?? dflt;
  switch (msg.kind) {
    case "poke":
      return { ...base, kind: "poke", clip: happy, hearts: true, durationMs: d("pokeMs", 20_000) };
    case "text":
      return { ...base, kind: "text", clip: idle, text: msg.text ?? "", durationMs: d("textMinMs", 20_000) };
    case "sticker": {
      const st = (manifest.stickers ?? []).find((s) => s.id === msg.stickerId);
      if (st) return { ...base, kind: "sticker", sticker: st.id, label: st.label ?? stickerFallbackLabel(msg), durationMs: d("stickerMs", 25_000) };
      return { ...base, kind: "text", clip: idle, text: unknownStickerText(msg), durationMs: d("textMinMs", 20_000) };
    }
    case "visit":
      return { ...base, kind: "visit", clip: idle, line: VISIT_GREETING, durationMs: d("visitMs", 25_000) };
    case "remind": {
      const reply = decodeReply(msg);
      if (reply) {
        const clip = reply.answer === "later" ? (actionClip(manifest, look, "react") ?? idle) : (toolClip(manifest, look, reply.kind, rand) ?? happy);
        return { ...base, kind: "remind", clip, line: replyLine(reply), reply, durationMs: d("remindMs", 25_000) };
      }
      const kind = reminderKind(msg);
      if (kind) return { ...base, kind: "remind", clip: toolClip(manifest, look, kind, rand) ?? happy, line: REMIND_LINES[kind], remind: kind, durationMs: d("remindMs", 25_000) };
      return { ...base, kind: "unknown", clip: happy, line: UNKNOWN_LINE, durationMs: d("unknownMs", 15_000) };
    }
    default:
      return { ...base, kind: "unknown", clip: happy, line: UNKNOWN_LINE, durationMs: d("unknownMs", 15_000) };
  }
}
