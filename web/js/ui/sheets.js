// Sheets over the window (WhatsNewWindow's two pages): 🧰 待设置 and 🍊 更新日志, plus the generic sheet frame.
// 待设置 (spec §4.3 SetupTodos 改): the web's own items; 「不用了」 → `setupTodoDismissed`. 更新日志: manifest v2
// `changelog` (W6 copies assets/changelog.json); a new web version → 「🆕 网页版更新了」 once (`whatsNewSeen`).

import { h, setChildren } from "./dom.js";
import { store } from "./store.js";
import * as notify from "./notify.js";
import * as activity from "./activity.js";
import { getManifest } from "./assets.js";

let open = null;

export function closeSheet() {
  if (!open) return;
  const { el, onKey, restore } = open;
  open = null;
  document.removeEventListener("keydown", onKey, true);
  el.classList.add("out");
  setTimeout(() => el.remove(), 160);
  restore?.focus?.({ preventScroll: true });
}

/** A modal card: icon + title + subtitle, body nodes, close button. */
export function openSheet({ icon, title, subtitle, body }) {
  closeSheet();
  const card = h("div.sheet-card", { role: "dialog", "aria-modal": "true", "aria-label": title },
    h("div.sheet-head",
      h("span.sheet-icon", { "aria-hidden": "true" }, icon),
      h("div.sheet-titles", h("div.sheet-title", title), subtitle ? h("div.sheet-sub", subtitle) : null),
      h("button.icon-btn.sheet-close", { type: "button", "aria-label": "关闭", onclick: closeSheet }, "✕")),
    h("div.sheet-body", body));
  const el = h("div.sheet", card);
  el.addEventListener("pointerdown", (e) => { if (e.target === el) closeSheet(); });
  const onKey = (e) => { if (e.key === "Escape") { e.preventDefault(); closeSheet(); } };
  document.addEventListener("keydown", onKey, true);
  open = { el, onKey, restore: document.activeElement };
  document.body.append(el);
  card.querySelector("button")?.focus({ preventScroll: true });
  return { el: card, set: (nodes) => setChildren(card.querySelector(".sheet-body"), nodes) };
}

// ---- 待设置 -----------------------------------------------------------------------------------------------------

let installPrompt = null;
window.addEventListener("beforeinstallprompt", (e) => { e.preventDefault(); installPrompt = e; });
export const isStandalone = () => matchMedia("(display-mode: standalone)").matches || matchMedia("(display-mode: window-controls-overlay)").matches;

const verLess = (a, b) => {
  const pa = String(a).split(".").map(Number), pb = String(b).split(".").map(Number);
  for (let i = 0; i < 3; i++) if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) < (pb[i] || 0);
  return false;
};

/** macApp() → my Mac's presence `app` version or null. → [{id, icon, title, detail, button?, go?}]. */
export async function setupTodos({ macApp }) {
  const dismissed = new Set(store.get("setupTodoDismissed", []) || []);
  const out = [];
  if (notify.permission() === "default") {
    out.push({ id: "notify", icon: "🔔", title: "允许通知", detail: "页面在后台时，TA 来消息、该喝水 / 滴眼药水了也能弹出来。", button: "允许", go: () => notify.requestPermission() });
  }
  if (await activity.idlePermission() === "prompt") {
    out.push({ id: "idle", icon: "🪑", title: "允许检测我在不在电脑前", detail: "提醒只在你真的在用电脑时出现；你离开了就等你回来。", button: "允许", go: () => activity.requestIdle() });
  }
  if (!isStandalone()) {
    out.push({ id: "install", icon: "🪟", title: "装成 App 窗口", detail: installPrompt ? "像桌面版一样有自己的小窗口和图标，没有地址栏。" : "Chrome 地址栏右边的「安装」图标 → 安装。公司电脑不让装也没关系，标签页里功能一样。",
      button: installPrompt ? "安装" : null, go: async () => { await installPrompt?.prompt(); installPrompt = null; } });
  }
  out.push({ id: "keepAlive", icon: "⚡️", title: "让 Chrome 别把它睡掉", detail: "Chrome 设置 → 性能 →「始终保持这些网站处于活动状态」→ 添加这个网站，后台也一直在线。", button: "设置好了", go: () => dismiss("keepAlive") });
  const app = macApp();
  if (app && verLess(app, "0.18.0")) {
    out.push({ id: "mac018", icon: "🍊", title: "家里的 Mac 升级到 0.18", detail: `家里的 Mac 还是 v${app}。升级后眼药水的设置和打卡会和网页同步。`, button: null });
  }
  return out.filter((t) => !dismissed.has(t.id));
}

function dismiss(id) {
  const d = new Set(store.get("setupTodoDismissed", []) || []);
  d.add(id);
  store.set("setupTodoDismissed", [...d]);
}

export async function openTodos(ctx, onChange) {
  const sheet = openSheet({ icon: "🧰", title: "待设置", subtitle: "几件还没设置的小事，不急着做", body: [] });
  async function render() {
    const todos = await setupTodos(ctx);
    onChange?.(todos.length);
    sheet.set(!todos.length ? h("div.todo-done", "都设置好啦 ✓") : todos.map((t) =>
      h("div.todo",
        h("span.todo-icon", { "aria-hidden": "true" }, t.icon),
        h("div.todo-text", h("div.todo-title", t.title), h("div.todo-detail", t.detail)),
        h("div.todo-actions",
          t.button ? h("button.pill-btn.filled", { type: "button", onclick: async () => { await t.go(); render(); } }, t.button) : null,
          h("button.pill-btn", { type: "button", onclick: () => { dismiss(t.id); render(); } }, "不用了")))));
  }
  render();
}

// ---- 更新日志 ---------------------------------------------------------------------------------------------------

const changelog = () => (Array.isArray(getManifest()?.changelog) ? getManifest().changelog : []);

export function openChangelog(current, seenBefore = null) {
  const list = changelog();
  openSheet({ icon: "🍊", title: "更新日志", subtitle: current ? `当前版本 v${current}` : "噜噜的新变化",
    body: !list.length ? h("div.muted", "暂时没有更新记录")
      : list.slice(0, 12).map((e) => h("div.log-entry",
        h("div.log-head", h("span.log-ver", `v${e.version}`), h("span.log-date", e.date ?? ""), seenBefore && verLess(seenBefore, e.version) ? h("span.log-new", "新") : null),
        h("ul.log-items", (e.items || []).map((t) => h("li", t))))) });
}

/** On start: a version newer than the one last seen → the 「🆕 网页版更新了」 card (not on the very first run). */
export function whatsNew(version, show) {
  if (!version) return;
  const seen = store.get("whatsNewSeen", null);
  store.set("whatsNewSeen", version);
  if (typeof seen === "string" && seen !== version) show(seen);
}
