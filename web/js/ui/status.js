// Status lines, worded like the Mac menu (docs/firebase-setup.md 常见问题) and PartnerBadge.

import { ago } from "./dom.js";
import { dndActive, focusActive, focusMinutesLeft } from "./deps.js";

const MOODS = { angry: ["😤", "生气中"], busy: ["💼", "忙碌中"], resting: ["😴", "休息中"] };

/** The `connection` event → one line. `reason` may be a sentence, an HTTP status or a short code. */
export function connectionLine(state, reason) {
  switch (state) {
    case "connecting": return { text: "连接中…", tone: "wait" };
    case "connected": return { text: "已连接", tone: "ok" };
    case "polling": return { text: "已连接（轮询模式）", tone: "ok" };
    case "offline": return { text: "未连接：网络断开，正在重试", tone: "bad" };
    default: return { text: "未连接：" + reasonText(reason), tone: "bad" };
  }
}

function reasonText(reason) {
  if (typeof reason === "string" && /[一-鿿]/.test(reason)) return reason;
  const code = typeof reason === "number" ? reason : Number(reason?.status ?? reason?.code ?? NaN);
  if (code === 404) return "数据库地址有误 (HTTP 404)";
  if (code === 401 || code === 403) return `数据库规则拒绝访问 (HTTP ${code})`;
  if (code === 400) return "数据库规则缺少 ts 索引 (HTTP 400)";
  if (reason === "badURL" || reason === "url") return "数据库地址格式有误";
  if (reason === "cancel" || reason === "auth_revoked") return "数据库规则拒绝访问";
  if (Number.isFinite(code)) return `HTTP ${code}`;
  return "网络断开，正在重试";
}

/** PartnerBadge.make: {dot, text}. presence null = TA never came. */
export function partnerBadge(p, online, now = Date.now()) {
  if (!p || !(typeof p.lastSeen === "number" || p.dnd || online)) return { dot: "⚪️", text: "还没上线过" };
  if (online) {
    if (dndActive(p.dnd, now)) {
      const m = MOODS[p.dnd.mood];
      return m ? { dot: m[0], text: m[1] } : { dot: "🔕", text: "勿扰中" };
    }
    if (focusActive(p.focus, now)) {
      return { dot: "🍅", text: `专注中 · 还剩 ${focusMinutesLeft(p.focus, now)} 分钟` };
    }
    return { dot: "🟢", text: "在线" };
  }
  if (!(p.lastSeen > 0) || p.lastSeen > now) return { dot: "⚪️", text: "离线" };
  return { dot: "⚪️", text: "离线 · " + ago(p.lastSeen, now) };
}

/** Compose hint while TA can't take it right now (messages are still sent). */
export function partnerNote(p, online, now = Date.now()) {
  if (!p || !online) return null;
  if (dndActive(p.dnd, now)) return "TA 开了勿扰，消息会先放在 TA 那儿";
  if (focusActive(p.focus, now)) return "TA 在专注，消息会先放在 TA 那儿";
  return null;
}

/** The headline about TA in the main page header. */
export function partnerHeadline(p, online) {
  if (!p || !(typeof p.lastSeen === "number" || p.dnd || online)) return "等 TA 配对中…";
  return online ? "对方在线" : "对方离线";
}
