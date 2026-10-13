// 积压卡片 (spec §5.2): what TA sent while this page was closed, summed up instead of replayed one by one.
// Pokes / replies older than 5 minutes are not shown (they still count as read). Reminders younger than 2 hours that
// I haven't answered keep their 马上 / 等会儿 buttons. Closing the card = everything read.

import { h, setChildren } from "./dom.js";
import { describe } from "./describe.js";
import { thumbEl, stickerById } from "./assets.js";
import { awayParts, isStaleAway, isReplyable, msgKey } from "./deps.js";

const hhmm = (ts) => new Intl.DateTimeFormat("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(ts));

export function createAwayCard({ onReply, onDone }) {
  const el = h("section.away", { hidden: true, "aria-label": "你不在的时候" });
  let msgs = [];
  let folded = 0;
  let open = false;
  const answered = new Set();

  const shown = (now) => msgs.filter((m) => !isStaleAway(m, now));
  const chips = (list) => awayParts(list, Date.now());

  function item(m, now) {
    const d = describe(m);
    const sticker = m.kind === "sticker" ? stickerById(m.stickerId) : null;
    const key = msgKey(m);
    const canAnswer = isReplyable(m, now) && !answered.has(key);
    return h("li.away-item",
      h("span.away-time", hhmm(m.ts)),
      sticker ? thumbEl(sticker, 32) : null,
      h("span.away-text", d.line),
      canAnswer ? h("span.away-actions",
        h("button.btn.primary.small", { type: "button", onclick: () => answer(m, "now") }, "马上"),
        h("button.btn.small", { type: "button", onclick: () => answer(m, "later") }, "等会儿")) : null);
  }

  function answer(m, a) {
    answered.add(msgKey(m));
    onReply(m, a);
    render();
  }

  function close() {
    const all = msgs;
    msgs = [];
    folded = 0;
    open = false;
    el.hidden = true;
    onDone(all);
  }

  function render() {
    const now = Date.now();
    const list = shown(now);
    if (!list.length && !folded) {
      if (msgs.length) close();    // only stale pokes: nothing to show, just mark them read
      return;
    }
    el.hidden = false;
    const c = chips(list);
    setChildren(el,
      h("div.away-head", h("span.away-title", "🍊 你不在的时候，TA来过～")),
      h("div.away-chips", c.map((t) => h("span.chip", t))),
      folded ? h("div.away-folded", `还有 ${folded} 条更早的，已经算看过了`) : null,
      open ? h("ul.away-list", list.slice().sort((a, b) => a.ts - b.ts).map((m) => item(m, now))) : null,
      h("div.away-foot",
        h("button.btn.small", { type: "button", "aria-expanded": String(open), onclick: () => { open = !open; render(); } },
          open ? "收起" : "展开看看"),
        h("button.btn.primary.small", { type: "button", onclick: close }, "知道啦")));
  }

  return {
    el,
    add(newMsgs) {
      const seen = new Set(msgs.map(msgKey));
      msgs = msgs.concat(newMsgs.filter((m) => !seen.has(msgKey(m))));
      render();
    },
    fold(count) { folded += count; render(); },
    /** Answered elsewhere (notification button). */
    resolved(key) { answered.add(key); if (!el.hidden) render(); },
    hasUnanswered(key) { return msgs.some((m) => msgKey(m) === key) && !answered.has(key); },
  };
}
