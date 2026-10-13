// 记录 tab (HistoryPane, spec §4.5): W3's IndexedDB copy of the pair's messages, newest at the bottom, 100 rows per
// page, day separators and 勿扰 dividers (W1 history.js rows), sticker thumbnails, reminder / reply lines.
// First open: backfill the latest 300 from Firebase; later opens: only newer. 「更早的 ↑」 pages back locally, then
// one older backfill page at a time until the server has nothing older.

import { h, setChildren } from "./dom.js";
import { v2, TZ, openHistory, messagesFetcher, decodeReply, replyLine, reminderKind, UNKNOWN_KIND, unknownStickerText } from "./deps.js";
import { stickerById, thumbEl } from "./assets.js";
import { store } from "./store.js";

const PAGE = 100;
const hhmm = (ts) => new Intl.DateTimeFormat("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(ts));

export function createHistoryTab({ config, me, partnerName }) {
  const list = h("div.history-list", { role: "log", "aria-label": "聊天记录" });
  const older = h("button.pill-btn.older", { type: "button", hidden: true, onclick: () => loadOlder() }, "更早的 ↑");
  const status = h("div.history-status", { role: "status" });
  const el = h("section.history", older, list, status);

  let db = null;
  let msgs = [];          // shown, oldest first
  let localMore = true;
  let complete = false;
  let opened = false;
  const fetcher = messagesFetcher(config);
  const pending = [];     // messages that arrived before the db opened

  const ready = openHistory({ pairCode: config.pairCode, seat: config.seat }).then((d) => {
    db = d;
    complete = d.meta?.oldestComplete ?? false;
    if (pending.length) return db.put(pending.splice(0));
  }).catch((e) => { console.warn("[lulu] history db", e); });

  function line(m) {
    const mine = m.from === me;
    const name = partnerName();
    if (m.kind === "text") return { text: m.text ?? "" };
    if (m.kind === "sticker") {
      const s = stickerById(m.stickerId);
      return s ? { sticker: s, text: s.label } : { text: unknownStickerText(m) };
    }
    if (m.kind === "poke") return { chip: "❤️", text: mine ? "送出一颗爱心" : `${name}送来一颗爱心` };
    if (m.kind === "visit") return { chip: "🏃", text: mine ? `去找${name}玩` : `${name}来找你玩` };
    const k = reminderKind(m);
    if (k) return { chip: k === "water" ? "💧" : "🧍", text: mine ? (k === "water" ? `叫${name}喝水` : `叫${name}起来动动`) : (k === "water" ? `${name}叫你喝水` : `${name}叫你起来动动`) };
    const r = decodeReply(m);
    if (r) {
      const mac = v2.history.remindHistoryLine(m, mine);     // late (终于…) / later (说等会儿) wording from the Mac
      if (mac) { const [chip, ...rest] = mac.split(" "); return { chip, text: rest.join(" ") }; }
      return { chip: r.kind === "water" ? "💧" : "🧍", text: mine ? replyLine(r).replace(/^TA /, "我") : replyLine(r) };
    }
    return { text: "［新版本消息］", faint: true, unknown: UNKNOWN_KIND };
  }

  function row(m) {
    const mine = m.from === me;
    const l = line(m);
    const body = l.chip
      ? h("div.h-chip", h("span.h-chip-icon", { "aria-hidden": "true" }, l.chip), l.text)
      : h("div.h-bubble", { class: l.faint ? "faint" : null },
        l.sticker ? thumbEl(l.sticker, 64) : null,
        l.sticker ? null : l.text);
    return h("div.h-row", { class: mine ? "mine" : "theirs", title: hhmm(m.ts) }, body, h("span.h-time", hhmm(m.ts)));
  }

  function render(keepScroll = null) {
    const spans = (store.get("dndLog", []) || []).filter((s) => Number.isFinite(s?.start) && Number.isFinite(s?.end));
    const rows = v2.history.rows(msgs, spans, complete && !localMore, Date.now(), TZ);
    setChildren(list, !msgs.length
      ? h("div.history-empty", `还没有记录，给${partnerName()}发第一条吧～`)
      : rows.map((r) => r.type === "day" ? h("div.h-day", h("span", r.label))
        : r.type === "dnd" ? h("div.h-dnd", h("span", r.label))
          : row(r.message)));
    older.hidden = !(localMore || !complete) || !msgs.length;
    if (keepScroll != null) list.scrollTop = list.scrollHeight - keepScroll;
    else list.scrollTop = list.scrollHeight;
  }

  async function loadOlder() {
    if (!db) return;
    older.disabled = true;
    const keep = list.scrollHeight - list.scrollTop;
    let page = msgs.length ? await db.page({ beforeTs: msgs[0].ts, beforeId: msgs[0].id, limit: PAGE }) : [];
    if (page.length < PAGE && !complete) {
      status.textContent = "正在读更早的记录…";
      try {
        const r = await db.backfill(fetcher, { older: true });
        complete = r.complete;
        page = msgs.length ? await db.page({ beforeTs: msgs[0].ts, beforeId: msgs[0].id, limit: PAGE }) : page;
        status.textContent = "";
      } catch { status.textContent = "读不到更早的记录，等会儿再试"; }
    }
    localMore = page.length >= PAGE;
    msgs = page.concat(msgs);
    older.disabled = false;
    render(keep);
  }

  async function open() {
    await ready;
    if (!db) { status.textContent = "这个浏览器存不了记录（隐私模式？）"; return; }
    if (!opened) {
      opened = true;
      msgs = await db.page({ limit: PAGE });
      render();
    }
    status.textContent = msgs.length ? "" : "正在读记录…";
    try {
      const r = await db.backfill(fetcher);
      complete = r.complete;
      status.textContent = "";
    } catch { status.textContent = "现在连不上，先显示存在这台电脑上的"; }
    msgs = await db.page({ limit: Math.max(PAGE, msgs.length) });
    localMore = msgs.length >= PAGE;
    render();
  }

  return {
    el,
    open,
    /** Live / backlog / own / sent messages: stored, and shown when the tab is open. */
    async add(newMsgs) {
      const list2 = (newMsgs || []).filter((m) => m && m.id);
      if (!list2.length) return;
      if (!db) { pending.push(...list2); return; }
      await db.put(list2);
      if (opened) {
        const seen = new Set(msgs.map((m) => m.id));
        msgs = msgs.concat(list2.filter((m) => !seen.has(m.id))).sort((a, b) => a.ts - b.ts);
        const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 40;
        render(atBottom ? null : list.scrollHeight - list.scrollTop);
      }
    },
  };
}
