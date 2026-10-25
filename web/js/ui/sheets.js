// Sheets over the window (WhatsNewWindow's two pages): 🧰 待设置 and 🍊 更新日志, plus the generic sheet frame.
// 待设置 (spec §4.3 SetupTodos 改): the web's own items; 「不用了」 → `setupTodoDismissed`. 更新日志: manifest v2
// `changelog` (W6 copies assets/changelog.json); a new web version → 「🆕 网页版更新了」 once (`whatsNewSeen`).

import { h, setChildren } from "./dom.js";
import { store } from "./store.js";
import * as notify from "./notify.js";
import * as activity from "./activity.js";
import { getManifest } from "./assets.js";

let open = null;
let sheetDoc = null;
/** Sheets open in this document while the panel has its own window (null = the main page). */
export function setSheetDoc(doc) { sheetDoc = doc; }

export function closeSheet() {
  if (!open) return;
  const { el, onKey, restore, doc } = open;
  open = null;
  doc.removeEventListener("keydown", onKey, true);
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
  const doc = sheetDoc || document;
  doc.addEventListener("keydown", onKey, true);
  open = { el, onKey, restore: doc.activeElement, doc };
  doc.body.append(el);
  card.querySelector("button")?.focus({ preventScroll: true });
  return { el: card, set: (nodes) => setChildren(card.querySelector(".sheet-body"), nodes) };
}

// ---- 待设置 -----------------------------------------------------------------------------------------------------

// Installing (Chrome 「安装」) gives the best pet: a window with no address bar (桌宠模式). It is a friendly suggestion
// (the landing + 待设置), never a nag; Chrome's own mini banner is held back and offered from our button instead.
// Without installing, the 桌宠小窗 popup (js/ui/petpopup.js) is the fallback.
let installPrompt = null;
const installListeners = new Set();
window.addEventListener("beforeinstallprompt", (e) => { e.preventDefault(); installPrompt = e; for (const fn of installListeners) fn(); });
window.addEventListener("appinstalled", () => { installPrompt = null; for (const fn of installListeners) fn(); });
/** Chrome offered to install (the button can show its dialog). */
export const canInstall = () => !!installPrompt;
export function onInstallable(fn) { installListeners.add(fn); }
/** Shows Chrome's install dialog. → true when it was shown. */
export async function promptInstall() {
  if (!installPrompt) return false;
  const p = installPrompt;
  installPrompt = null;
  try { await p.prompt(); } catch { return false; }
  return true;
}
const isIOS = () => /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
/** How to install here, in words (Safari has no install dialog to show). */
export const installHow = () => (isIOS()
  ? "Safari 底部的分享按钮 →「添加到主屏幕」，以后从主屏幕的噜噜图标打开，就像一个 App。"
  : "Chrome 地址栏右边的「安装」小图标（或 ⋮ → 投放、保存和分享 → 安装页面），装好后从程序坞打开。");
export const isStandalone = () => matchMedia("(display-mode: standalone)").matches || matchMedia("(display-mode: window-controls-overlay)").matches;

const verLess = (a, b) => {
  const pa = String(a).split(".").map(Number), pb = String(b).split(".").map(Number);
  for (let i = 0; i < 3; i++) if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) < (pb[i] || 0);
  return false;
};

/** macApp() → my Mac's presence `app` version or null.
 * → [{id, icon, title, detail, button?, go?, state: "todo"|"done"|"dismissed", doneLine?}] — every item, done ones
 * included, so the sheet's 「已设置」 page can still show how each was set up (and bring back a dismissed one). */
export async function allSetupItems({ macApp }) {
  const dismissed = new Set(store.get("setupTodoDismissed", []) || []);
  const out = [];
  const perm = notify.permission();
  out.push({ id: "notify", icon: "🔔", title: "允许通知", detail: "页面在后台时，TA 来消息、该喝水 / 滴眼药水了也能弹出来。",
    button: perm === "default" ? "允许" : null, go: () => notify.requestPermission(),
    done: perm === "granted", doneLine: "已允许。要关掉：Chrome 地址栏左边的图标 → 网站设置 → 通知。" });
  const idle = await activity.idlePermission();
  out.push({ id: "idle", icon: "🪑", title: "允许检测我在不在电脑前", detail: "提醒只在你真的在用电脑时出现；你离开了就等你回来。",
    button: idle === "prompt" ? "允许" : null, go: () => activity.requestIdle(),
    done: idle === "granted", doneLine: "已允许。要改：Chrome 地址栏左边的图标 → 网站设置 → 设备使用情况检测。" });
  out.push({ id: "install", icon: "🍊", title: isIOS() ? "添加到主屏幕（推荐）" : "装成桌宠 App（推荐）", detail: installPrompt
    ? "噜噜会有自己的小窗口，没有地址栏，就只有宠物站在桌面上。不装也行：用「打开桌宠小窗」。"
    : isIOS() ? installHow() : `${installHow()}不装也行：用「打开桌宠小窗」。`,
    button: installPrompt ? "安装" : null, go: () => promptInstall(),
    done: isStandalone(), doneLine: isIOS() ? "已经从主屏幕打开了。" : "已经装成 App 了。" });
  out.push({ id: "keepAlive", icon: "⚡️", title: "让 Chrome 别把它睡掉",
    detail: "Chrome 设置 → 性能（地址栏输入 chrome://settings/performance）→「始终保持这些网站处于活动状态」→ 添加 → 填这个网站的网址，后台也一直在线。",
    button: "设置好了", go: () => dismiss("keepAlive"), done: dismissed.has("keepAlive"), keepDetail: true });
  const app = macApp();
  if (app) {
    out.push({ id: "mac018", icon: "🍊", title: "家里的 Mac 升级到 0.18", detail: `家里的 Mac 还是 v${app}。升级后眼药水的设置和打卡会和网页同步。`, button: null,
      done: !verLess(app, "0.18.0"), doneLine: `家里的 Mac 是 v${app} ✓` });
  }
  return out.map((t) => ({ ...t, state: t.done ? "done" : dismissed.has(t.id) ? "dismissed" : "todo" }));
}

/** Only the ones still to do (the badge count and the 待设置 page). */
export async function setupTodos(ctx) {
  return (await allSetupItems(ctx)).filter((t) => t.state === "todo");
}

function dismiss(id) {
  const d = new Set(store.get("setupTodoDismissed", []) || []);
  d.add(id);
  store.set("setupTodoDismissed", [...d]);
}

function undismiss(id) {
  store.set("setupTodoDismissed", (store.get("setupTodoDismissed", []) || []).filter((x) => x !== id));
}

export async function openTodos(ctx, onChange, startPage = "todo") {
  const sheet = openSheet({ icon: "🧰", title: "待设置", subtitle: "几件还没设置的小事，不急着做", body: [] });
  let page = startPage;
  async function render() {
    const items = await allSetupItems(ctx);
    const todos = items.filter((t) => t.state === "todo");
    const settled = items.filter((t) => t.state !== "todo");
    onChange?.(todos.length);
    const tab = (id, label) => h("button.pill-btn" + (page === id ? ".filled" : ""), { type: "button", "aria-pressed": String(page === id),
      onclick: () => { page = id; render(); } }, label);
    const tabs = h("div.todo-tabs", { role: "group", "aria-label": "待设置 / 已设置" }, tab("todo", `待设置 ${todos.length || ""}`.trim()), tab("set", `已设置 ${settled.length || ""}`.trim()));
    const row = (t, actions, detail) => h("div.todo",
      h("span.todo-icon", { "aria-hidden": "true" }, t.icon),
      h("div.todo-text", h("div.todo-title", t.title), h("div.todo-detail", detail)),
      h("div.todo-actions", ...actions));
    const list = page === "todo"
      ? (!todos.length ? [h("div.todo-done", "都设置好啦 ✓")] : todos.map((t) => row(t, [
          t.button ? h("button.pill-btn.filled", { type: "button", onclick: async () => { await t.go(); render(); } }, t.button) : null,
          h("button.pill-btn", { type: "button", onclick: () => { dismiss(t.id); render(); } }, "不用了")], t.detail)))
      : (!settled.length ? [h("div.todo-done", "还没有设置好的")] : settled.map((t) => row(t,
          t.state === "dismissed" || t.id === "keepAlive"
            ? [h("button.pill-btn", { type: "button", onclick: () => { undismiss(t.id); page = "todo"; render(); } }, "放回待设置")]
            : [h("span.todo-state", "✓ 已设置")],
          t.state === "dismissed" ? `（之前点了「不用了」）${t.detail}` : t.keepDetail ? t.detail : (t.doneLine || t.detail))));
    sheet.set([tabs, ...list]);
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
