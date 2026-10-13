// Reads W6's web/assets/manifest.json (spec §5) into what the world draws. Manifest v2 (W6, merged):
//
//   clips: {key: {file, frames, cells, cols, w, h, src: [w, h], delays, seq}}           (keys opaque)
//   characters.<c>: {order, outfits: {<o>: {label, season, actions: {idle, happy, react, sleep, quiet, run?, wave?},
//                      fidgets: [key], fidgetNames: [name] (aligned), stay: [name], extras: [name],
//                      named: {name: key} (fidgets → stay → extras, first wins), clipSounds: {name: soundKey}}},
//                    weather: {<look>: [{name, clip, sound?}]}}
//   couples: {<name>: {clip, intimate, sound|null, heightFactor, luluOnLeft}}
//   reactions: Resources/reactions.json as is (clip NAMES, resolved through the visitor outfit's `named`)
//   toolClips: {water|stand|focus|breakTime|eyedrops: {lulu: [name], lumei: [name]}}
//   sounds: {} on the web (neutral synthesized tones, sound.js); sound keys on couples / clipSounds / weather pick one.
// Manifest v1 still works (no couples / weather / named clips: those features simply don't happen).
//
// Ids from the wire (outfit / stickerId) are only ever looked up here, never used to build a path.

import { parseReactions, clipLooks } from "./rules.js";

const cleanId = (s) => (typeof s === "string" && s.length > 0 && s.length <= 64 && !s.includes("/") && !s.includes("..") ? s : null);
const own = (o, k) => o != null && typeof o === "object" && Object.prototype.hasOwnProperty.call(o, k);

/** → [{name, id, sound}] from a list of ids / {name, clip} objects, or a {name: id} map. */
function namedList(v, sounds) {
  const out = [];
  const push = (name, id, sound) => { if (typeof id === "string" && id) out.push({ name: typeof name === "string" && name ? name : id, id, sound: sound || sounds?.[name] || null }); };
  if (Array.isArray(v)) {
    for (const x of v) {
      if (typeof x === "string") push(x, x);
      else if (x && typeof x === "object") push(x.name, x.clip ?? x.id, typeof x.sound === "string" ? x.sound : null);
    }
  } else if (v && typeof v === "object") {
    for (const [name, x] of Object.entries(v)) {
      if (typeof x === "string") push(name, x);
      else if (x && typeof x === "object") push(name, x.clip ?? x.id, typeof x.sound === "string" ? x.sound : null);
    }
  }
  return out;
}

export function createCatalog(manifest, base) {
  const m = manifest || {};
  const clips = m.clips || {};
  const clip = (id) => (typeof id === "string" && own(clips, id) ? clips[id] : null);
  const resolved = (list) => list.map((n) => ({ ...n, clip: clip(n.id) })).filter((n) => n.clip);
  const outfitCache = new Map();

  const characterOf = (c) => (own(m.characters, c) ? c : own(m.characters, "lulu") ? "lulu" : Object.keys(m.characters || {})[0] || null);

  /** The outfit to draw: the first of `wanted` this build has, else the character's default (order[0]). */
  function outfitOf(character, ...wanted) {
    const ch = m.characters?.[characterOf(character)];
    if (!ch) return null;
    for (const w of wanted) {
      const id = cleanId(w);
      if (id && own(ch.outfits, id)) return id;
    }
    return ch.order?.[0] ?? Object.keys(ch.outfits || {})[0] ?? null;
  }

  /** One outfit's clips (null when the character / outfit is unknown). */
  function outfit(character, outfitId) {
    const c = characterOf(character);
    const o = outfitOf(c, outfitId);
    if (!c || !o) return null;
    const key = c + "/" + o;
    if (outfitCache.has(key)) return outfitCache.get(key);
    const raw = m.characters[c].outfits[o] || {};
    const actions = raw.actions || {};
    const sounds = raw.clipSounds && typeof raw.clipSounds === "object" ? raw.clipSounds : raw.sounds && typeof raw.sounds === "object" ? raw.sounds : null;
    const namedMap = raw.named && typeof raw.named === "object" && !Array.isArray(raw.named) ? raw.named : null;
    // v2: fidgets are keys with fidgetNames aligned; stay / extras are names looked up in `named`.
    const fidgetList = Array.isArray(raw.fidgets) && Array.isArray(raw.fidgetNames)
      ? raw.fidgets.map((id, i) => ({ name: raw.fidgetNames[i], clip: id })) : raw.fidgets;
    const byName = (list) => (Array.isArray(list) && namedMap ? list.map((x) => (typeof x === "string" && own(namedMap, x) ? { name: x, clip: namedMap[x] } : x)) : list);
    const fidgets = resolved(namedList(fidgetList, sounds));
    const stays = resolved(namedList(byName(raw.stay ?? raw.stays), sounds));
    const extras = resolved(namedList(byName(raw.extras ?? raw.clips), sounds));
    const all = [...fidgets, ...stays, ...extras];
    const idle = clip(actions.idle);
    const action = (name) => clip(actions[name]);
    /** An action name, a fidget / stay / extra clip name, or a web clip id of this outfit. */
    const named = (name) => {
      if (typeof name !== "string") return null;
      const a = action(name);
      if (a) return { name, clip: a, sound: null };
      if (namedMap && own(namedMap, name) && clip(namedMap[name])) return { name, clip: clip(namedMap[name]), sound: sounds?.[name] || null };
      const n = all.find((x) => x.name === name) || all.find((x) => x.id === name);
      return n ? { name: n.name, clip: n.clip, sound: n.sound } : null;
    };
    const out = {
      character: c, outfit: o, label: raw.label ?? "",
      idle, idleHeight: idle?.src?.[1] || idle?.h || 200,
      action, fidgets, stays, extras, named, has: (name) => !!named(name),
    };
    outfitCache.set(key, out);
    return out;
  }

  /** Weather clips of a character for a look (snow falls back to cold): [{name, clip}]. */
  function weather(character, look) {
    const w = m.characters?.[characterOf(character)]?.weather;
    if (!w || !look) return [];
    for (const l of clipLooks(look)) {
      const list = resolved(namedList(w[l]));
      if (list.length) return list;
    }
    return [];
  }
  const hasWeather = (character) => {
    const w = m.characters?.[characterOf(character)]?.weather;
    return !!w && Object.keys(w).some((l) => resolved(namedList(w[l])).length > 0);
  };

  const couples = {};
  for (const [name, c] of Object.entries(m.couples || {})) {
    const cl = clip(typeof c === "string" ? c : c?.clip);
    if (!cl) continue;
    const hf = Number(c?.heightFactor);
    couples[name] = {
      name, clip: cl, intimate: c?.intimate === true, sound: typeof c?.sound === "string" && c.sound ? c.sound : null,
      heightFactor: Number.isFinite(hf) ? Math.min(1.5, Math.max(0.3, hf)) : 1,
      luluOnLeft: c?.facing !== "lulu-right" && c?.luluOnLeft !== false,
    };
  }

  const sounds = {};
  for (const [key, v] of Object.entries(m.sounds || {})) {
    const list = [];
    for (const x of Array.isArray(v) ? v : [v]) {
      const e = typeof x === "string" ? { file: x } : x && typeof x === "object" && typeof x.file === "string" ? x : null;
      if (!e || !e.file || e.file.includes("..") || list.some((y) => y.file === e.file)) continue;
      list.push({ file: e.file, visitor: e.visitor === "lulu" || e.visitor === "lumei" ? e.visitor : null, intimate: e.intimate === true });
    }
    if (list.length) sounds[key] = list;
  }

  const toolClips = m.toolClips && typeof m.toolClips === "object" ? m.toolClips : null;
  const stickers = Array.isArray(m.stickers) ? m.stickers : [];
  const prefix = base ? String(base) : "";

  return {
    version: m.version ?? 1,
    characterOf, outfitOf, outfit, weather, hasWeather,
    couples, couple: (name) => (typeof name === "string" && own(couples, name) ? couples[name] : null),
    reactions: parseReactions(m.reactions),
    sounds,
    /** ToolClips pool (manifest v2 toolClips; null = not in this manifest, the caller falls back). */
    toolPool: (kind, character) => (toolClips ? (Array.isArray(toolClips[kind]?.[character]) ? toolClips[kind][character] : []) : null),
    totalBytes: m.totalBytes ?? null,
    stickerById: (id) => { const c = cleanId(id); return c ? stickers.find((s) => s.id === c) || null : null; },
    url: (file) => prefix + file,
  };
}
