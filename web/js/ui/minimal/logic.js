// 极简模式 (work mode) — the pure rules, no DOM / storage (tested in web/tests/minimal.test.mjs).
// The mode is per device (`lulupet.minimal` = {on, chime, thumbs, hideContent, discreet}); phones always run the full
// pet. Desktop browsers that never chose are asked once (完整宠物 / 极简（适合上班）).

export const DEFAULT_PREFS = Object.freeze({ on: false, chime: true, thumbs: false, hideContent: false, discreet: false });

/** Stored value → full prefs (bad data = defaults). `chosen` = the user picked a mode at least once. */
export function decodePrefs(raw) {
  const x = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  const b = (k) => (typeof x[k] === "boolean" ? x[k] : DEFAULT_PREFS[k]);
  return { on: b("on"), chime: b("chime"), thumbs: b("thumbs"), hideContent: b("hideContent"), discreet: b("discreet"), chosen: typeof x.on === "boolean" };
}

/** Run the minimal panel here? Never on a phone. */
export const useMinimal = (prefs, { phone }) => !phone && prefs.on === true;

/** Ask 完整宠物 / 极简 first? Only on a desktop (fine pointer, not a phone), never in the pet popup, once. */
export const shouldOffer = (prefs, { phone, fine, popup }) => !prefs.chosen && !phone && !!fine && !popup;

/** Window / tab title: 「(2) 噜噜 · 👁️ 1/4」, or with 低调标题 「(2) 提醒」 (no names, no emoji). */
export function titleText({ unread = 0, eye = "", discreet = false }) {
  const n = unread > 0 ? `(${unread}) ` : "";
  if (discreet) return `${n}提醒`;
  return `${n}噜噜${eye ? " · " + eye : ""}`;
}

/** TA's name as shown: the character name, or 「TA」 with 低调标题. */
export const shownName = (name, discreet) => (discreet ? "TA" : name);

/**
 * Notification text for TA's message / reminder. kind: "message" | "partner-remind" | "reply".
 * hideContent → 「TA 发来一条消息」 (reminders keep their buttons but say only 「TA 发来一个提醒」).
 * discreet → no character names in the title.
 */
export function partnerNotice(kind, { name, line, isText = false }, { hideContent = false, discreet = false } = {}) {
  const who = shownName(name, discreet);
  if (hideContent) {
    return kind === "partner-remind" ? { title: "提醒", body: `${who} 发来一个提醒` } : { title: "新消息", body: `${who} 发来一条消息` };
  }
  let body = String(line ?? "");
  if (body.length > 80) body = body.slice(0, 79) + "…";
  if (kind === "partner-remind") return { title: `${who}说：`, body };
  return { title: isText ? `${who}说：` : who, body };
}

/** A sticker as text: 「［表情］么么哒」. */
export const stickerText = (label) => (label ? `［表情］${label}` : "［表情］");

/** Seconds → 「24:05」 (or 「1:02:05」); null / bad → 「--:--」. */
export function clock(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "--:--";
  const s = Math.ceil(seconds);
  const hh = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60), ss = s % 60;
  const p = (v) => String(v).padStart(2, "0");
  return hh ? `${hh}:${p(mm)}:${p(ss)}` : `${p(mm)}:${p(ss)}`;
}

/** Messages that should be marked read now: TA's unread ones, only while the panel is really in front of me. */
export function readable(unreadKeys, { visible, focused }) {
  return visible && focused ? [...unreadKeys] : [];
}

/** Should TA's message pop a system notification? Not while I look at the panel; not during my 勿扰 / 专注 (held). */
export const notifyPartner = ({ visible, focused, held }) => !held && !(visible && focused);

/**
 * The compact 小工具 strip, one short bit per tool that is on: [{id, text}].
 * water / stand: {on, phase, left (s)} (reminder status); eye: {on, done, total, showing}; pomo: {phase, left (s) | null, paused}.
 */
export function toolBits({ water, stand, eye, pomo }) {
  const out = [];
  const rem = (id, icon, r) => {
    if (!r?.on) return;
    const text = r.phase === "showing" ? `该${id === "water" ? "喝水" : "动动"}了`
      : r.phase === "away" ? "暂停"
        : Number.isFinite(r.left) ? `${Math.max(1, Math.ceil(r.left / 60))} 分` : "开";
    out.push({ id, text: `${icon} ${text}`, due: r.phase === "showing" });
  };
  if (pomo && pomo.phase && pomo.phase !== "idle") {
    out.push({ id: "pomo", text: `🍅 ${pomo.phase === "focus" ? "专注" : "休息"} ${clock(pomo.left)}${pomo.paused ? " 暂停" : ""}` });
  }
  rem("water", "💧", water);
  rem("stand", "🧍", stand);
  if (eye?.on) out.push({ id: "eye", text: eye.showing ? "👁️ 该滴了" : `👁️ ${eye.done}/${eye.total}`, due: !!eye.showing });
  return out;
}
