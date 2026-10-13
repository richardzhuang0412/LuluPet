// Per-message reactions (port of Reaction / ReactionTable / PoolPick in Sources/LuluCore/Reactions.swift).
// reactions.json: {"<stickerId | kind | * | click | remind_water…>": {"couple": names, "visitor": names | {lulu, lumei},
// "sound": names}}; names = a string or a list (a pool). Parsed entry: {couples: [], visitor: {"*"|role: []}, sounds: []}.
// `rand()` → [0, 1); a pick of n is floor(rand() × n).

export const DEFAULT_KEY = "*";
export const CLICK_KEY = "click";
export const CLICK_CHANCE = 0.2;
export const NO_COUPLE = "none";

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

function names(v) {
  const list = typeof v === "string" ? [v] : Array.isArray(v) ? v.filter((x) => typeof x === "string") : [];
  const out = [];
  for (const s of list) if (s !== "" && !out.includes(s)) out.push(s);
  return out.length ? out : null;
}

/** Tolerant parse of the reactions.json object (bad entries / names ignored; empty entries dropped). */
export function parseReactions(obj) {
  const out = {};
  if (!isObj(obj)) return out;
  for (const [key, d] of Object.entries(obj)) {
    if (!isObj(d)) continue;
    const visitor = {};
    const v = names(d.visitor);
    if (v) visitor["*"] = v;
    else if (isObj(d.visitor)) for (const [c, x] of Object.entries(d.visitor)) { const n = names(x); if (n) visitor[c] = n; }
    const r = { couples: names(d.couple) ?? [], visitor, sounds: names(d.sound) ?? [] };
    if (r.couples.length || Object.keys(r.visitor).length || r.sounds.length) out[key] = r;
  }
  return out;
}

/** The visitor clip pool for the visiting character (its own list, else "*"). */
export function visitorClips(reaction, character) {
  return reaction?.visitor?.[character] ?? reaction?.visitor?.["*"] ?? [];
}

/** Field by field: the sticker's entry, then the kind's, then "*"; null when none exists. */
export function reactionFor(entries, kind, stickerId) {
  const layers = [stickerId != null ? entries[stickerId] : null, entries[kind], entries[DEFAULT_KEY]].filter(Boolean);
  if (!layers.length) return null;
  const visitor = {};
  for (const layer of layers.slice().reverse()) Object.assign(visitor, layer.visitor);
  return {
    couples: layers.find((l) => l.couples.length)?.couples ?? [],
    visitor,
    sounds: layers.find((l) => l.sounds.length)?.sounds ?? [],
  };
}

/** The funny click pool for `character` (pseudo-entry "click"). */
export function clickClips(entries, character) {
  return visitorClips(entries[CLICK_KEY], character);
}

/** reactions.json key of the visitor clips for 叫你喝水 / 起来动动. */
export const remindReactionKey = (kind) => `remind_${kind}`;

/** Random pick avoiding `last` when the pool has another choice; null for an empty pool. */
export function poolPick(pool, last, rand = Math.random) {
  if (!pool?.length) return null;
  const fresh = pool.filter((p) => p !== last);
  const from = fresh.length ? fresh : pool;
  return from[Math.floor(rand() * from.length)];
}
