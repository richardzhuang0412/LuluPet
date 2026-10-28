// Fake presence / messages for `--preview` and `--demo` (neutral sample content, no real data).

import { idleScene, messageScene, nightScene } from "./scenes.js";

const T = 1_760_000_000_000;

function presence(extra = {}) {
  return { lastSeen: T - 5_000, character: "lulu", outfit: "classic", ...extra };
}

function msg(kind, extra = {}) {
  return { id: `-sample-${kind}-${Math.random().toString(36).slice(2, 8)}`, from: "lulu", kind, ts: T, v: 1, character: "lulu", outfit: "classic", ...extra };
}

/** → [{name, title, scene}] for every scene type (manifest decides the clips). */
export function sampleScenes(manifest, cfg) {
  const opts = { watchSeat: cfg.watchSeat, durations: cfg.durations, rand: () => 0 };
  const lumeiOutfit = manifest.characters?.lumei?.order?.find((o) => !manifest.characters.lumei.outfits[o].actions?.sleep) ?? null;
  const list = [
    ["idle-online", "待机：在线", idleScene(manifest, presence(), T, opts)],
    ["idle-dnd", "待机：勿扰 🔕", idleScene(manifest, presence({ dnd: { mood: "busy", until: 0 } }), T, opts)],
    ["idle-focus", "待机：专注 🍅", idleScene(manifest, presence({ focus: { phase: "focus", until: T + 600_000 } }), T, opts)],
    ["idle-offline-sleep", "待机：离线（睡觉）", idleScene(manifest, presence({ lastSeen: 0 }), T, opts)],
    ["idle-offline-zzz", "离线：无睡觉片段", idleScene(manifest, presence({ lastSeen: 0, character: "lumei", outfit: lumeiOutfit }), T, { ...opts, watchSeat: "lumei" })],
    ["night-dim", "夜间：调暗", nightScene(manifest, presence(), opts)],
    ["poke", "戳一下 ❤", messageScene(manifest, msg("poke"), presence(), opts)],
    ["text-short", "文字：短", messageScene(manifest, msg("text", { text: "想你啦～今天吃什么？" }), presence(), opts)],
    ["text-long", "文字：长（分页）", messageScene(manifest, msg("text", { text: "今天下班路上看到一只小猫 🐱 在晒太阳，特别像你！晚上一起吃火锅好不好？I miss you 😊" }), presence(), opts)],
    ["sticker", "表情", messageScene(manifest, msg("sticker", { stickerId: manifest.stickers?.[0]?.id, text: "[表情] 想你了" }), presence(), opts)],
    ["visit", "串门", messageScene(manifest, msg("visit"), presence(), opts)],
    ["remind-water", "叫你喝水", messageScene(manifest, msg("remind", { remind: "water" }), presence(), opts)],
    ["remind-stand", "叫你起来动动", messageScene(manifest, msg("remind", { remind: "stand" }), presence(), opts)],
    ["reply-now", "回复：马上喝", messageScene(manifest, msg("remind", { remind: "water", ackOf: "-x", answer: "now" }), presence(), opts)],
    ["reply-later", "回复：等会儿", messageScene(manifest, msg("remind", { remind: "stand.later", ackOf: "-x", answer: "later" }), presence(), opts)],
    ["lumei-text", "噜妹造型的文字", messageScene(manifest, msg("text", { character: "lumei", outfit: manifest.characters?.lumei?.order?.[0], text: "晚安，好梦 🌙" }), presence(), opts)],
    ["unknown", "新版本消息", messageScene(manifest, msg("hug2"), presence(), opts)],
  ];
  return list.map(([name, title, scene]) => ({ name, title, scene }));
}
