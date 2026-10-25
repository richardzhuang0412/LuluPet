// 设置 → 「手机 / 后台提醒」 (Web Push, spec docs/superpowers/specs/2026-10-22-web-push.md §4). Self-contained:
// settings-tab.js calls initPush once at start (re-stores a renewed subscription, phones report page visibility)
// and pushSection(rerender) while it renders.

import { h, toast } from "./dom.js";
import { store, deviceId } from "./store.js";
import { toggle } from "./tools-tab.js";
import { segmented } from "./settings-tab.js";
import { createPush } from "../net/push.js";

let push = null;
let busy = false;

/** Once per page: needs the pair config (paired modes only). */
export function initPush(config) {
  if (push || !config?.pairCode || (config.seat !== "lulu" && config.seat !== "lumei")) return;
  try {
    push = createPush({ config, deviceId: deviceId(), store });
    if (push.support() === "ok") push.refresh().then((r) => { if (r === "lost") toast("手机 / 后台提醒断开了，到 设置 里重新打开", 6000); });
  } catch (e) {
    console.warn("[lulu] push", e);
    push = null;
  }
}

const NOTES = {
  "no-key": "推送服务还没开通。",
  "ios-install": "iPhone / iPad：先在 Safari 里点 分享 → 「添加到主屏幕」，再从主屏幕打开噜噜，回到这里打开（需要 iOS 16.4 以上）。",
  unsupported: "这个浏览器不支持推送通知。",
};

export function pushSection(rerender) {
  if (!push) return null;
  const sup = push.support();
  const st = push.status();
  const run = async (fn, ok) => {
    if (busy) return;
    busy = true;
    try { await fn(); if (ok) toast(ok); } catch (e) { toast(e?.message || "没弄好，稍后再试", 6000); }
    busy = false;
    rerender();
  };
  const check = (label, on, onChange) => h("label.set-row.check-row", h("span.set-label", label), toggle(on, label, onChange));
  const pref = (k) => (v) => run(() => push.setPrefs({ [k]: v }));
  const p = st.prefs;
  return h("section.set-section", h("h3.set-title", "手机 / 后台提醒"),
    sup !== "ok" ? h("div.set-note", NOTES[sup]) : [
      check("手机 / 后台也提醒我", st.on, (v) => run(() => (v ? push.enable() : push.disable()), v ? "打开啦：页面关着也能收到 ✓" : "关掉了")),
      h("div.set-note", st.on
        ? "这台设备会收到推送，页面关着也行。你在 Mac 或开着的噜噜页面前时不重复提醒。iPhone 上通知没有按钮，点一下就打开噜噜。"
        : "打开后，TA 的消息、TA 叫你喝水，还有眼药水提醒，页面关着时也会推到这台设备（手机要先添加到主屏幕）。"),
      st.on ? [
        check("TA 的消息（文字、表情、爱心）", p.messages, pref("messages")),
        check("TA 叫我喝水 / 起来动动，和 TA 的回复", p.reminders, pref("reminders")),
        check("眼药水（我的设备都不在线时）", p.eyedrops, pref("eyedrops")),
        check("只在我不在电脑前时推送", p.onlyWhenAway, pref("onlyWhenAway")),
        h("div.set-row", h("span.set-label", "我开着勿扰 / 专注时"),
          h("span.set-right", segmented("勿扰时", [{ value: "silent", label: "静音推送" }, { value: "skip", label: "不推送" }], p.dnd, pref("dnd")))),
      ] : null,
    ]);
}
