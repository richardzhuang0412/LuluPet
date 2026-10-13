// 设置 tab (SettingsWindow 通用 / 小工具 / 表情 as sections of one page, spec §3.3): 连接 · 我 · 显示 · 声音 · 表情 ·
// 通知和活跃检测 · 离线素材 · 待设置 / 更新日志 · 版本. Rendered when shown (cheap; it's text and a few controls).

import { h, setChildren, toast, nameOf } from "./dom.js";
import { stickerRules } from "./deps.js";
import { stickerList, thumbEl } from "./assets.js";
import { quickBar } from "./compose.js";
import { toggle } from "./tools-tab.js";
import * as notify from "./notify.js";
import * as activity from "./activity.js";
import { prefs, SIZES, VOLUMES } from "./prefs.js";

const MODE = { couple: "情侣", friend: "朋友", solo: "单人" };

/** A row of options, one selected (segmented control). */
export function segmented(label, options, value, onPick) {
  return h("div.segmented", { role: "radiogroup", "aria-label": label }, options.map((o) =>
    h("button.seg", { type: "button", role: "radio", "aria-checked": String(o.value === value), onclick: () => onPick(o.value) }, o.label)));
}

export function createSettingsTab({ config, me, seatInfo, editConnection, placeWindow, canPlaceWindow, openTodos, openChangelog, todoCount, version, onPrefs, downloadAll, intimate }) {
  const el = h("div.settings");
  let visible = false;
  let showAllStickers = false;
  const section = (title, ...children) => h("section.set-section", h("h3.set-title", title), children);
  const row = (label, ...right) => h("div.set-row", h("span.set-label", label), h("span.set-right", right));
  const note = (text) => h("div.set-note", text);

  function connection() {
    const host = (() => { try { return new URL(config.databaseURL).host; } catch { return config.databaseURL; } })();
    return section("连接",
      row("数据库", h("span.mono", host)),
      row("配对码", h("span.mono", config.pairCode.slice(0, 4) + " •••• " + config.pairCode.slice(-4))),
      row("座位", `${nameOf(me)}座（我的 Mac 坐的那边）`),
      h("div.set-actions", h("button.pill-btn", { type: "button", onclick: editConnection }, "改连接设置…")));
  }

  function meSection() {
    const s = seatInfo();
    return section("我",
      row("角色", `我是${nameOf(s.character)}`),
      row("模式", MODE[s.mode] ?? "情侣"),
      row("城市", s.place?.name ?? "还没设置"),
      note("角色、模式和城市跟着家里的 Mac 走（Mac 上 🍊 → 设置 → 通用）。"));
  }

  function display() {
    const p = prefs.get();
    return section("显示",
      row("宠物大小", segmented("宠物大小", SIZES, SIZES.find((x) => Math.abs(x.value - p.petScale) < 0.01)?.value ?? null, (v) => { prefs.set({ petScale: v }); onPrefs(); render(); })),
      note(SIZES.some((x) => Math.abs(x.value - p.petScale) < 0.01)
        ? "也可以把鼠标放到宠物身上，拖它右下角的小角。"
        : `现在是拖出来的大小（×${p.petScale.toFixed(2)}），点上面的选项可以换回来。`),
      canPlaceWindow() ? h("div.set-actions", h("button.pill-btn", { type: "button", onclick: () => { placeWindow(true); toast("放回右下角啦"); } }, "放回右下角")) : null);
  }

  function sound() {
    const p = prefs.get().sound;
    const set = (patch) => { prefs.set({ sound: { ...p, ...patch } }); onPrefs({ preview: patch.volume != null }); render(); };
    return section("声音",
      h("label.set-row.check-row", h("span.set-label", "声音（串门、爱心、气泡……会有小小的提示音）"), toggle(p.on, "声音", (v) => set({ on: v }))),
      row("音量", segmented("音量", VOLUMES, p.volume, (v) => set({ volume: v }))),
      h("label.set-row.check-row", h("span.set-label", "背景音乐（打开页面后放一首，不循环）"), toggle(p.bgm, "背景音乐", (v) => set({ bgm: v }))),
      h("div.set-actions", h("button.pill-btn", { type: "button", disabled: !p.on, onclick: () => onPrefs({ preview: true }) }, "试听")));
  }

  function stickers() {
    const bar = quickBar();
    const visible = stickerRules.visibleIds(stickerList(), intimate());
    const on = new Set(bar.stored());
    const byId = new Map(stickerList().map((s) => [s.id, s]));
    const flip = (s) => { toast(bar.toggle(s, visible)); render(); };
    const slots = bar.shown(visible).map((id) => byId.get(id)).filter(Boolean);
    return section("表情",
      note("快捷栏放 8 个最爱。点下面的表情放进 / 拿下。"),
      h("div.sticker-grid.bar-edit", slots.map((s) => h("button.sticker.on-bar", { type: "button", title: `从快捷栏拿下「${s.label}」`, onclick: () => flip(s) }, thumbEl(s, 40), h("span.sticker-label", s.label)))),
      h("button.link", { type: "button", "aria-expanded": String(showAllStickers), onclick: () => { showAllStickers = !showAllStickers; render(); } }, showAllStickers ? "收起全部表情" : "全部表情…"),
      showAllStickers ? h("div.sticker-grid", stickerList().filter((s) => visible.includes(s.id)).map((s) =>
        h("button.sticker", { type: "button", class: on.has(s.id) ? "on-bar" : null, title: on.has(s.id) ? "从快捷栏拿下" : "放进快捷栏", onclick: () => flip(s) }, thumbEl(s, 40), h("span.sticker-label", s.label)))) : null);
  }

  function perms() {
    const n = notify.permission();
    const nLine = n === "granted" ? "通知：已允许 ✓（TA 来消息、提醒你的时候，页面在后台也会弹通知）"
      : n === "denied" ? "通知：被拒绝了。点地址栏左边的图标 → 网站设置 → 通知 → 允许，然后刷新页面。"
        : n === "unsupported" ? "通知：这个浏览器不支持" : "通知：还没允许。允许后，页面在后台也能提醒你。";
    const iLine = h("div.set-note", "在不在电脑前：…");
    const iBtn = h("button.pill-btn", { type: "button", hidden: true, onclick: async () => { await activity.requestIdle(); render(); } }, "允许检测我在不在电脑前");
    activity.idlePermission().then((i) => {
      iBtn.hidden = i !== "prompt";
      iLine.textContent = i === "granted" ? "在不在电脑前：已允许 ✓（离开 5 分钟以上会重新计时）"
        : i === "denied" ? "在不在电脑前：被拒绝了。地址栏左边的图标 → 网站设置 → 设备使用情况检测 → 允许。没有它时，按窗口是否在前台来算。"
          : i === "unsupported" ? "在不在电脑前：这个浏览器不支持，按窗口是否在前台来算。"
            : "在不在电脑前：允许后，喝水 / 站立 / 眼药水提醒只在你真的在用电脑时出现。";
    });
    return section("通知和活跃检测",
      note(nLine),
      n === "default" ? h("div.set-actions", h("button.pill-btn", { type: "button", onclick: async () => { await notify.requestPermission(); render(); } }, "允许通知")) : null,
      iLine, h("div.set-actions", iBtn),
      note("让它一直在线：Chrome 设置 → 性能 → 「始终保持这些网站处于活动状态」→ 添加这个网站。"));
  }

  function offline() {
    const status = h("div.set-note", "宠物的动作会边用边下载；也可以一次下完，没网也能用。");
    const btn = h("button.pill-btn", { type: "button", onclick: async () => {
      btn.disabled = true;
      await downloadAll((done, total, bytes) => { status.textContent = `下载中 ${done}/${total}${bytes ? ` · ${(bytes / 1048576).toFixed(1)} MB` : ""}`; });
      status.textContent = "全部素材都在这台电脑上了 ✓";
      btn.disabled = false;
    } }, "下载全部素材（离线可用）");
    return section("离线素材", status, h("div.set-actions", btn));
  }

  function more() {
    const n = todoCount();
    return section("更多",
      h("div.set-actions",
        h("button.pill-btn", { type: "button", onclick: openTodos }, n ? `待设置（${n}）` : "待设置"),
        h("button.pill-btn", { type: "button", onclick: openChangelog }, "更新日志")),
      h("div.set-version", version()));
  }

  function render() {
    if (!visible) return;
    const y = el.scrollTop;
    setChildren(el, connection(), meSection(), display(), sound(), stickers(), perms(), offline(), more());
    el.scrollTop = y;
  }

  return { el, show() { visible = true; render(); }, hide() { visible = false; }, render };
}
