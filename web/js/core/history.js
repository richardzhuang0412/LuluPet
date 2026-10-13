// 记录 tab (port of HistoryTimeline in Sources/LuluCore/AwaySummary.swift, Visits.remindHistoryLine in VisitsRemind.swift).
// Messages are decoded children (message.js `decodeChild`); spans are dnd.js spans {start, end, mood} (ms).
// Rows: {type: "day", label, key} | {type: "message", message} | {type: "dnd", label, key}.

import { localParts, dayString } from "./tz.js";
import { spanLabel } from "./dnd.js";
import { decodeReply } from "./remind.js";

export const PAGE_SIZE = 100;

/** Oldest first, ties on ts broken by id (HistoryStore order). */
export function compareMessages(a, b) {
  if (a.ts !== b.ts) return a.ts - b.ts;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

/** The newest `limit` messages older than `before` (all when null), oldest first → {messages, hasMore}. */
export function page(sorted, limit, before = null) {
  let end = sorted.length;
  if (before) {
    const i = sorted.findIndex((m) => compareMessages(m, before) >= 0);
    end = i < 0 ? sorted.length : i;
  }
  const start = Math.max(0, end - Math.max(0, limit));
  return { messages: sorted.slice(start, end), hasMore: start > 0 };
}

/** 今天 / 昨天 / 9月26日 / 2025年9月26日. */
export function dayLabel(ms, nowMs, tz) {
  const d = dayString(ms, tz), today = dayString(nowMs, tz);
  if (d === today) return "今天";
  const p = localParts(ms, tz);
  // "yesterday" = the calendar day before today (Swift: Calendar date(byAdding: .day, -1)).
  const [ty, tm, td] = today.split("-").map(Number);
  const prev = new Date(Date.UTC(ty, tm - 1, td - 1));
  if (p.year === prev.getUTCFullYear() && p.month === prev.getUTCMonth() + 1 && p.day === prev.getUTCDate()) return "昨天";
  const md = `${p.month}月${p.day}日`;
  return p.year === ty ? md : `${p.year}年${md}`;
}

/** "14:05". */
export function timeLabel(ms, tz) {
  const p = localParts(ms, tz);
  return `${String(p.hour).padStart(2, "0")}:${String(p.minute).padStart(2, "0")}`;
}

const dayKeyOf = (ms, tz) => {
  const p = localParts(ms, tz);
  return `${p.year}-${p.month}-${p.day}`;
};

/**
 * Rows with day separators and 勿扰 dividers: each span starting within the loaded page (at or after its first
 * message; any time when `complete`, i.e. no older page) goes before the first message at or after its start.
 */
export function rows(messages, spans, complete, nowMs, tz) {
  const from = complete ? -Infinity : (messages[0]?.ts ?? Infinity);
  const pending = (spans ?? []).filter((s) => s.start >= from).sort((a, b) => a.start - b.start);
  const out = [];
  let lastDay = null;
  const dayRow = (ts) => {
    const k = dayKeyOf(ts, tz);
    if (k !== lastDay) {
      out.push({ type: "day", label: dayLabel(ts, nowMs, tz), key: k });
      lastDay = k;
    }
  };
  const flush = (ts) => {
    while (pending.length && (ts == null || pending[0].start <= ts)) {
      const s = pending.shift();
      dayRow(s.start);
      out.push({ type: "dnd", label: spanLabel(s, tz), key: String(s.start) });
    }
  };
  for (const m of messages) {
    flush(m.ts);
    dayRow(m.ts);
    out.push({ type: "message", message: m });
  }
  flush(null);
  return out;
}

/** A remind message's history line (`fromMe` = I sent it); null = not a known remind. */
export function remindHistoryLine(m, fromMe) {
  const reply = decodeReply(m);
  if (reply) {
    const line = replyHistoryLine(reply, fromMe);
    if (line) return line;
  }
  if (m.kind !== "remind" || !["water", "stand"].includes(m.remind)) return null;
  const icon = m.remind === "water" ? "💧" : "🧍";
  if (m.ackOf != null) {
    if (m.remind === "water") return `${icon} ${fromMe ? "你喝啦" : "TA 喝啦"}`;
    return `${icon} ${fromMe ? "你站起来啦" : "TA 站起来啦"}`;
  }
  if (m.remind === "water") return `${icon} ${fromMe ? "叫 TA 喝水" : "TA 叫你喝水"}`;
  return `${icon} ${fromMe ? "叫 TA 起来动动" : "TA 叫你起来动动"}`;
}

/** RemindReply.historyLine (Sources/LuluCore/RemindReply.swift): late / later replies; null for a plain "now". */
function replyHistoryLine(r, fromMe) {
  const icon = r.kind === "water" ? "💧" : "🧍";
  if (r.late) {
    return `${icon} ${fromMe ? (r.kind === "water" ? "你终于喝啦" : "你终于起来动啦") : (r.kind === "water" ? "TA 终于喝啦" : "TA 终于起来动啦")}`;
  }
  if (r.answer === "later") return `⏰ ${fromMe ? "你说等会儿" : "TA 说等会儿"}`;
  return null;
}
