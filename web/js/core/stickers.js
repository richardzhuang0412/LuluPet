// 快捷栏 / 常用 / 全部表情. Port of StickerPanel (Sources/LuluCore/StickerPanel.swift). Pure; the stored inputs are the
// localStorage keys `stickerQuickBar` (array of ids), `stickerSendCounts` ({id: n}), `stickerRecent` ({id: ms}).
// `visible` = ids the current mode may show (friend mode hides intimate ones) and this build has.

export const MAX_QUICK_BAR = 8;
export const MAX_FREQUENT = 16;
export const MAX_RECENT = 200;

/** The 24 stickers that existed before v0.15, in their old order. */
export const DEFAULT_FAVORITES = Object.freeze([
  "missyou", "hug", "kiss", "nuzzle", "flower", "night", "morning", "run", "heart", "shy", "angry", "cry",
  "happy", "dance", "eat", "milktea", "holdhands", "sleeptogether", "whatsup", "goodgirl", "celebrate", "bleh",
  "hi", "wink",
]);

/** 「全部表情」 sections in order (StickerGroup). */
export const STICKER_GROUPS = Object.freeze([
  { id: "love", title: "爱意 · 撒娇" },
  { id: "happy", title: "开心 · 得意 · 加油" },
  { id: "sad", title: "委屈 · 生气 · 难过" },
  { id: "wow", title: "无语 · 惊讶 · 疑问" },
  { id: "daily", title: "作息 · 日常" },
  { id: "reply", title: "回应 · 招呼" },
  { id: "season", title: "天气 · 节日" },
]);
export const OTHER_GROUP_TITLE = "其他";

const own = (obj, k) => (obj != null && Object.prototype.hasOwnProperty.call(obj, k) ? obj[k] : undefined);
const count = (counts, id) => { const v = own(counts, id); return typeof v === "number" ? v : 0; };
const stamp = (recent, id) => { const v = own(recent, id); return typeof v === "number" ? v : 0; };

function dedupe(ids) {
  const seen = new Set();
  return ids.filter((id) => !seen.has(id) && seen.add(id));
}

/** The sticker ids I sent (my seat's sticker messages only) → {id: n}. */
export function sendCounts(messages, me) {
  const out = Object.create(null);
  for (const m of messages) {
    if (m.from === me && m.kind === "sticker" && typeof m.stickerId === "string" && m.stickerId !== "") {
      out[m.stickerId] = (out[m.stickerId] ?? 0) + 1;
    }
  }
  return { ...out };
}

/** Order for stickers nobody sent: the original 24 first, then library order. */
function baseOrder(library) {
  const order = new Map();
  for (const id of [...DEFAULT_FAVORITES, ...library]) if (!order.has(id)) order.set(id, order.size);
  return order;
}

/** All `visible` ids ranked: more sends first, ties by newest `recent`, then the default order. */
export function ranked(counts, recent, visible) {
  const order = baseOrder(visible);
  return dedupe(visible).sort((a, b) => {
    const ca = count(counts, a), cb = count(counts, b);
    if (ca !== cb) return cb - ca;
    const ra = stamp(recent, a), rb = stamp(recent, b);
    if (ra !== rb) return rb - ra;
    return order.get(a) - order.get(b);
  });
}

/** The 快捷栏 to show: the stored ids limited to `visible`, deduped, at most 8. */
export function quickBar(stored, visible) {
  const ok = new Set(visible);
  return dedupe(stored.filter((id) => ok.has(id))).slice(0, MAX_QUICK_BAR);
}

/** How many of the first 8 stored slots hold ids the current mode hides. */
export function hiddenOnBar(stored, visible) {
  const ok = new Set(visible);
  return dedupe(stored).slice(0, MAX_QUICK_BAR).filter((id) => !ok.has(id)).length;
}

/** The 快捷栏 as drawn: `quickBar`, with slots taken by hidden ids filled from the ranking (display only). */
export function shownBar(stored, visible, counts, recent) {
  const bar = quickBar(stored, visible);
  const gap = Math.min(hiddenOnBar(stored, visible), MAX_QUICK_BAR - bar.length);
  if (gap <= 0) return bar;
  const have = new Set(bar);
  return [...bar, ...ranked(counts, recent, visible).filter((id) => !have.has(id)).slice(0, gap)];
}

/** The automatic 常用: `ranked` minus the quick bar, at most 16. */
export function frequent(bar, counts, recent, visible) {
  const on = new Set(bar);
  return ranked(counts, recent, visible).filter((id) => !on.has(id)).slice(0, MAX_FREQUENT);
}

/**
 * First run (no stored bar): a customized `favorites` (Mac `stickerFavorites`; null on the web) seeds the bar, then the
 * most-sent stickers, then the default order. `library` = every catalog id (not policy-filtered).
 */
export function seedQuickBar(favorites, counts, recent, library) {
  const ok = new Set(library);
  const bar = [];
  const add = (id) => { if (bar.length < MAX_QUICK_BAR && ok.has(id) && !bar.includes(id)) bar.push(id); };
  const isDefault = favorites && favorites.length === DEFAULT_FAVORITES.length && favorites.every((id, i) => id === DEFAULT_FAVORITES[i]);
  if (favorites && !isDefault) favorites.forEach(add);
  for (const id of ranked(counts, recent, library)) if (count(counts, id) > 0) add(id);
  for (const id of [...DEFAULT_FAVORITES, ...library]) add(id);
  return bar;
}

/** 装上 `id` → {list, replaced}. On the bar → unchanged. Full → the last visible slot is replaced. */
export function equipped(id, stored, visible) {
  if (stored.includes(id)) return { list: stored.slice(), replaced: null };
  if (stored.length < MAX_QUICK_BAR) return { list: [...stored, id], replaced: null };
  const ok = new Set(visible);
  let i = -1;
  for (let k = stored.length - 1; k >= 0; k--) if (ok.has(stored[k])) { i = k; break; }
  if (i < 0) return { list: stored.slice(), replaced: null };
  const list = stored.slice();
  const replaced = list[i];
  list[i] = id;
  return { list, replaced };
}

/** 拿下 `id` (other slots shift left). */
export function removed(id, stored) {
  return stored.filter((x) => x !== id);
}

/** Stamp a use of a sticker; keeps the newest 200. */
export function recorded(id, ts, recent) {
  const r = { ...recent, [id]: ts };
  const keys = Object.keys(r);
  if (keys.length > MAX_RECENT) {
    keys.sort((a, b) => r[a] - r[b]).slice(0, keys.length - MAX_RECENT).forEach((k) => delete r[k]);
  }
  return r;
}

/** Intimate stickers hidden unless `allowsIntimate`; returns the visible ids of `catalog` ([{id, intimate}]). */
export function visibleIds(catalog, allowsIntimate) {
  return catalog.filter((s) => allowsIntimate || !s.intimate).map((s) => s.id);
}

/** 「全部表情」: [{group, title, stickers}] in STICKER_GROUPS order; unknown / missing group last as 「其他」 (group null). */
export function grouped(stickers) {
  const out = [];
  for (const g of STICKER_GROUPS) {
    const list = stickers.filter((s) => s.group === g.id);
    if (list.length) out.push({ group: g.id, title: g.title, stickers: list });
  }
  const known = new Set(STICKER_GROUPS.map((g) => g.id));
  const rest = stickers.filter((s) => !known.has(s.group));
  if (rest.length) out.push({ group: null, title: OTHER_GROUP_TITLE, stickers: rest });
  return out;
}
