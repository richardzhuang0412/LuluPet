// The backlog card 「你不在的时候 TA 来过：💬 3 · 🧸 2 · ❤️ 1 · 💧 叫你喝水」 (spec §5.2). Counting follows
// AwaySummary.build (Sources/LuluCore/AwaySummary.swift); pokes and reminder replies older than 5 minutes are left out
// (the Mac's stalePokeMs: replayed old ones aren't news).

import { decodeReply, isRemindAck, REMINDER_KINDS } from "./remind.js";

export const STALE_POKE_MS = 5 * 60 * 1000;
export const CARD_TITLE = "你不在的时候 TA 来过";

/** A poke or reminder reply that is too old to show. */
export function isStale(msg, now) {
  return (msg.kind === "poke" || isRemindAck(msg)) && now - msg.ts >= STALE_POKE_MS;
}

/**
 * → {text, sticker, poke, remind, later, other, water, stand, acks, visits, unknown, stickers: [{id, count}],
 *    latestText, total}. `remind` = water + stand calls; `later` = 「等会儿」 replies; `acks` = other replies / receipts;
 * `other` = visits + newer-version messages. Messages from `me` (optional) are ignored.
 */
export function summarize(messages, now, me = null) {
  const s = { text: 0, sticker: 0, poke: 0, remind: 0, later: 0, other: 0, water: 0, stand: 0, acks: 0, visits: 0,
    unknown: 0, stickers: [], latestText: null, total: 0 };
  for (const m of messages) {
    if (me != null && m.from === me) continue;
    if (isStale(m, now)) continue;
    switch (m.kind) {
      case "poke": s.poke++; break;
      case "text": {
        s.text++;
        const t = typeof m.text === "string" ? m.text.trim() : "";
        if (t) s.latestText = t;
        break;
      }
      case "visit": s.visits++; break;
      case "remind": {
        const reply = decodeReply(m);
        if (reply) { if (reply.answer === "later") s.later++; else s.acks++; }
        else if (!REMINDER_KINDS.includes(m.remind)) s.unknown++;
        else if (m.ackOf != null) s.acks++;
        else if (m.remind === "water") s.water++;
        else s.stand++;
        break;
      }
      case "sticker": {
        const id = m.stickerId ?? "?";
        const e = s.stickers.find((x) => x.id === id);
        if (e) e.count++; else s.stickers.push({ id, count: 1 });
        s.sticker++;
        break;
      }
      default: s.unknown++;
    }
  }
  s.remind = s.water + s.stand;
  s.other = s.visits + s.unknown;
  s.total = s.text + s.sticker + s.poke + s.remind + s.later + s.acks + s.other;
  return s;
}

const times = (n) => (n > 1 ? ` ×${n}` : "");

/** The card's short parts, e.g. ["💬 3", "🧸 2", "❤️ 1", "💧 叫你喝水"]; join with " · ". */
export function summaryParts(s) {
  const out = [];
  if (s.text) out.push(`💬 ${s.text}`);
  if (s.sticker) out.push(`🧸 ${s.sticker}`);
  if (s.poke) out.push(`❤️ ${s.poke}`);
  if (s.water) out.push("💧 叫你喝水" + times(s.water));
  if (s.stand) out.push("🧍 叫你起来动动" + times(s.stand));
  if (s.acks) out.push("✅ TA 回应了提醒" + times(s.acks));
  if (s.later) out.push("⏰ TA 说等会儿" + times(s.later));
  if (s.visits) out.push(`🏃 来找过你 ${s.visits} 次`);
  if (s.unknown) out.push(`✨ ${s.unknown} 条新版本消息`);
  return out;
}
