// 极简模式 (work mode): the same channel, controllers and wire format as the full page (js/app.js run()), without the
// little world. Nothing animates, no sprite / sticker sheet is fetched (sticker thumbnails only behind 「显示表情小图」),
// no character sounds (an optional quiet chime for my own reminders). Messages go out exactly like the full page's
// when the pet isn't on screen: trip "local", with the offline / 勿扰 / not-paired lines as small inline notes.
// TA's messages land in the conversation list; reminders become inline cards; system notifications carry the rest.

import { v2, build, msgKey, allowsIntimate, decodeReply, isReplyable, SEATS, dndActive, focusActive, createScheduler, createToolsSync, loadNet, DEV } from "../deps.js";
import { h, $, setChildren, toast, nameOf } from "../dom.js";
import { store, deviceId } from "../store.js";
import { stickerById, outfitOf } from "../assets.js";
import { describe } from "../describe.js";
import { connectionLine, partnerBadge, partnerNote } from "../status.js";
import { onActiveChange } from "../activity.js";
import { createReminders } from "../reminders.js";
import { createEyedrops } from "../eyedrops.js";
import { createPomodoro } from "../pomodoro.js";
import { createDnd } from "../dnd.js";
import { createOutfits } from "../outfits.js";
import { createHistoryTab } from "../history-tab.js";
import { createToolsTab } from "../tools-tab.js";
import { createSettingsTab } from "../settings-tab.js";
import { createSetup } from "../setup.js";
import { openMenu } from "../menu.js";
import { openSheet, openTodos, openChangelog, setupTodos, whatsNew, isStandalone } from "../sheets.js";
import * as notify from "../notify.js";
import { minimalPrefs, switchMode, setFavicon, notifyIcon } from "./mode.js";
import { titleText, shownName, partnerNotice, stickerText, readable, notifyPartner } from "./logic.js";
import { createNotices } from "./notices.js";
import { createMiniTools } from "./tools.js";
import { createMiniCompose } from "./compose.js";
import { modeSection } from "./settings-section.js";
import { icon } from "./icons.js";

const WIDE = "(min-width: 720px)";

/** view: the page's {main, blocked, update, ...} elements; version() → web version string or null. */
export async function runMinimal(config, { version }) {
  const me = config.seat;
  const ta = SEATS.find((s) => s !== me);
  document.body.classList.add("minimal");
  const host = $("#minimal-view");
  host.hidden = false;
  placeWindow();
  // The installed app's title bar takes the panel's header colour (light / dark).
  const themeMeta = document.querySelector('meta[name="theme-color"]');
  const darkQ = matchMedia("(prefers-color-scheme: dark)");
  const setTheme = () => themeMeta?.setAttribute("content", darkQ.matches ? "#1d2126" : "#ffffff");
  setTheme();
  darkQ.addEventListener("change", setTheme);

  const state = {
    mine: null, identity: null, yielding: true,
    partner: null, partnerKnown: false, online: false, connected: false,
    unread: new Map(),          // key → msg (TA's, not yet seen)
  };
  const pendingReminds = new Map();
  const answered = new Set(store.get("answeredReminds", []) || []);
  const prefs = () => minimalPrefs.get();
  const scheduler = createScheduler({ tickMs: 15_000 });
  const myCharacter = () => { const p = state.identity || state.mine; return p?.character === "lulu" || p?.character === "lumei" ? p.character : me; };
  const myMode = () => ((state.identity || state.mine)?.mode === "friend" ? "friend" : "couple");
  const partnerCharacter = () => (state.partner?.character === "lulu" || state.partner?.character === "lumei" ? state.partner.character : ta);
  const taName = () => shownName(nameOf(partnerCharacter()), prefs().discreet);
  const intimate = () => allowsIntimate(myMode(), state.partner?.mode === "friend" ? "friend" : "couple");
  const everSeen = () => !!(state.partner && (typeof state.partner.lastSeen === "number" || state.partner.dnd || state.online));
  const partnerDnd = () => (state.online && dndActive(state.partner?.dnd, Date.now()) ? state.partner.dnd : null);
  const partnerFocus = () => (state.online && focusActive(state.partner?.focus, Date.now()) ? state.partner.focus : null);
  const looking = () => ({ visible: !document.hidden, focused: document.hasFocus() });

  const { createChannel, createStore } = await loadNet();
  const channel = createChannel({ config, store: createStore(), deviceId: deviceId(),
    defaultOutfits: { lulu: outfitOf("lulu"), lumei: outfitOf("lumei") } });
  // which device I'm using → push routing (same hook as the full app in app.js)
  if (DEV !== "fake" && DEV !== "pip") import("../../net/devices.js").then((m) => m.startDeviceActivity({ config, deviceId: deviceId() })).catch(console.error);
  const log = (line) => console.log("[lulu]", line);

  // ---- chime (my own reminders only) ----
  const sound = v2.createSound({});
  sound.unlock(document);
  const chime = () => { if (prefs().chime) { sound.setPrefs({ on: true, volume: 0.25 }); sound.play("remind"); } };

  let started = false;
  let toolsOpen = store.get("minimalToolsOpen", false) === true;   // 小工具 open on a narrow window
  const notices = createNotices({ onAdd: () => { if (started && toolsOpen && !matchMedia(WIDE).matches) toggleTools(false); } });
  const nIcon = () => notifyIcon(prefs().discreet) || undefined;

  // ---- controllers (same as the full page) ----
  const dnd = createDnd({ scheduler, onChange: () => { publishLook(); refresh(); }, onEnded: () => {} });
  const outfits = createOutfits({ scheduler, onChange: () => publishLook() });
  const reminders = createReminders({ onFire: (kind, o) => showOwnReminder(kind, o) });
  const pomodoro = createPomodoro({
    scheduler, config: () => reminders.settings().pomodoro,
    onChange: () => { publishLook(); refresh(); },
    onEvent: (e) => pomodoroEvent(e),
  });
  const eyedrops = createEyedrops({
    sync: createToolsSync({ config, deviceId: deviceId() }), deviceId: deviceId(), scheduler, log,
    show: ({ slot, copy, notify: n }) => {
      chime();
      notices.add({ tag: "eyedrops", title: copy.header, line: copy.line, buttons: [{ title: copy.done, primary: true }, { title: copy.later }] })
        .then((i) => { if (i === 0) eyedrops.markDone(slot); else if (i === 1) eyedrops.later(); });
      // 极简模式 has no pet to look at: the system notification always comes along.
      void n;
      notify.notify("eyedrops", { title: copy.header, body: copy.line, slot, icon: nIcon() });
      refresh();
    },
    hide: () => { notices.close("eyedrops"); notify.closeFor("eyedrops"); refresh(); },
    onChange: () => refresh(),
  });

  // ---- panel ----
  const dot = h("span.mi-dot", { "aria-hidden": "true" });
  const nameEl = h("span.mi-name-ta");
  const statusEl = h("span.mi-status");
  const connEl = h("span.mi-conn", { role: "status" });
  const dndBtn = h("button.mi-icon-btn", { type: "button", "aria-label": "勿扰", title: "勿扰", "aria-pressed": "false", "aria-expanded": "false", onclick: () => toggleDndRow() }, icon("moon"));
  const menuBtn = h("button.mi-icon-btn", { type: "button", "aria-label": "菜单", title: "菜单", "aria-haspopup": "menu", onclick: () => moreMenu() }, icon("more"));
  const update = $("#update");
  const head = h("header.mi-head",
    h("div.mi-who", { role: "status", "aria-live": "polite" }, dot, nameEl, statusEl),
    connEl, update, dndBtn, menuBtn);
  const dndRow = h("div.mi-dndrow", { hidden: true, role: "group", "aria-label": "勿扰" });
  const banner = h("div.mi-banner", { hidden: true, role: "status" });

  const history = createHistoryTab({ config, me, partnerName: taName, stickerThumbs: () => prefs().thumbs, thumbPx: 22 });
  const compose = createMiniCompose({ send, act });
  const fullTools = createToolsTab({ pomodoro, reminders, eyedrops, onSettingsChange: () => refresh() });
  const openToolsMore = () => { openSheet({ icon: "🧰", title: "小工具设置", body: fullTools.el }); fullTools.show(); };
  const tools = createMiniTools({ pomodoro, reminders, eyedrops, onSettingsChange: () => refresh(), openMore: openToolsMore });
  const stripBits = h("span.mi-strip-bits");
  const stripBtn = h("button.mi-strip", { type: "button", "aria-expanded": "false", onclick: () => toggleTools() },
    h("span.mi-strip-label", "小工具"), stripBits, icon("chevron", 16));
  const toolsAside = h("aside.mi-tools", { "aria-label": "小工具" }, stripBtn, tools.el);
  const main = h("div.mi-main", h("div.mi-chat", history.el), notices.el, compose.el);
  setChildren(host, head, banner, dndRow, h("div.mi-body", toolsAside, main));
  history.el.classList.add("mi-history");

  const settings = createSettingsTab({
    config, me, minimal: true,
    modeSection: () => modeSection({ minimal: true, onChange: () => { applyPrefs(); settings.render(); } }),
    seatInfo: () => ({ character: myCharacter(), mode: myMode(), place: state.mine?.place }),
    editConnection: () => openSheet({ icon: "🔗", title: "连接", body: createSetup({ current: config, onSave: () => location.reload() }).el }),
    placeWindow: () => placeWindow(true), canPlaceWindow: () => isStandalone(),
    openTodos: (page) => openTodos(todoCtx, () => {}, page === "set" ? "set" : "todo"),
    openChangelog: () => openChangelog(version()),
    todoCount: () => todoCount,
    version: () => (version() ? `网页版 v${version()}` : "网页版"),
    onPrefs: () => {}, downloadAll: async () => {}, intimate,
    backdrop: null, layout: () => "panel", canChooseLayout: () => false, setLayout: () => {},
  });
  const openSettings = () => { openSheet({ icon: "⚙️", title: "设置", body: settings.el }); settings.show(); };

  let todoCount = 0;
  const todoCtx = { macApp: () => (typeof state.mine?.app === "string" && !String(state.mine?.device ?? "").startsWith("web-") ? state.mine.app : null) };
  const countTodos = () => setupTodos(todoCtx).then((t) => { todoCount = t.length; });

  // 小工具: a one-line strip that opens on narrow windows; always open beside the chat on wide ones.
  const wide = matchMedia(WIDE);
  function toggleTools(force) {
    toolsOpen = typeof force === "boolean" ? force : !toolsOpen;
    store.set("minimalToolsOpen", toolsOpen);
    layoutTools();
  }
  function layoutTools() {
    const open = wide.matches || toolsOpen;
    toolsAside.classList.toggle("open", open);
    stripBtn.setAttribute("aria-expanded", String(open));
    tools.el.hidden = !open;
    if (open) tools.render();
  }
  wide.addEventListener("change", layoutTools);

  // 勿扰: duration chips under the header (presence dnd, as on the full page).
  let dndOpen = false;
  function toggleDndRow(force) { dndOpen = typeof force === "boolean" ? force : !dndOpen; renderDnd(); }
  function renderDnd() {
    const on = dnd.isOn();
    dndBtn.setAttribute("aria-pressed", String(on));
    dndBtn.setAttribute("aria-expanded", String(dndOpen));
    dndBtn.classList.toggle("on", on);
    dndRow.hidden = !dndOpen;
    if (!dndOpen) return;
    setChildren(dndRow,
      h("span.mi-dnd-label", on ? dnd.statusLine() : "勿扰多久？"),
      h("span.mi-dnd-chips",
        dnd.durations.map((d) => h("button.mi-chip.small", { type: "button", onclick: () => { dnd.turnOn(d.id); toggleDndRow(false); } }, d.title)),
        on ? h("button.mi-chip.small.strong", { type: "button", onclick: () => { dnd.turnOff(); toggleDndRow(false); } }, "关掉勿扰") : null));
  }

  // ---- sending (like the full page with the pet off screen: trip "local") ----
  function send(partial) {
    let msg;
    if (partial.kind === "text") msg = build.text(partial.text, me);
    else if (partial.kind === "sticker") msg = build.sticker(partial.stickerId, partial.label, me);
    else if (partial.kind === "poke") msg = build.poke(me);
    else if (partial.kind === "remind") msg = build.remind(partial.remind, me);
    if (!msg) return;
    try {
      const sent = channel.send(msg, { trip: "local" });
      history.add([sent], { toBottom: true });
    } catch (e) {
      console.error(e);
      compose.showNote("没发出去，等会儿再试试");
      return;
    }
    const V = v2.visits;
    const pd = partnerDnd(), pf = !pd && partnerFocus();
    if (!everSeen()) compose.showNote(V.sendsWhenOffline(msg.kind) ? V.NOT_PAIRED_QUEUED_LINE : V.NOT_PAIRED_LINE);
    else if (pd) compose.showNote(v2.dnd.bounceLine(pd));
    else if (pf) compose.showNote(V.FOCUS_BOUNCE_LINE);
    else if (!state.online) compose.showNote(V.OFFLINE_QUEUED_LINE);
    else if (partial.kind === "poke") compose.showNote("❤️ 送出去啦", 2000);
    else if (partial.kind === "remind") compose.showNote(partial.remind === "water" ? "叫 TA 喝水了 ✓" : "叫 TA 动动了 ✓", 2000);
  }
  function act(kind) {
    if (kind === "heart") return send({ kind: "poke" });
    if (kind === "water" || kind === "stand") return send({ kind: "remind", remind: kind });
  }

  function reply(msg, answer, late = false) {
    const kind = msg.remind === "stand" ? "stand" : "water";
    const key = msgKey(msg);
    try {
      history.add([channel.send(build.reply(kind, answer, me, key, late))]);
    } catch (e) {
      console.error(e);
      toast("没发出去，等会儿再试试");
      return;
    }
    pendingReminds.delete(key);
    answered.add(key);
    store.set("answeredReminds", [...(store.get("answeredReminds", []) || []), key].slice(-50));
    notify.closeFor("msg-" + key);
    notices.close(key);
    if (answer === "later") reminders.partnerSnoozed(kind, key);
    else if (!late) reminders.partnerDone(kind);
  }

  function markRead(msg) {
    try { channel.markRead(msg); } catch (e) { console.error(e); }
    state.unread.delete(msgKey(msg));
    notify.closeFor("msg-" + msgKey(msg));
  }
  /** Everything TA sent is read once the panel is really in front of me (reminder cards stay until answered). */
  function readSeen() {
    for (const k of readable(state.unread.keys(), looking())) markRead(state.unread.get(k));
    renderTitle();
  }

  // ---- TA's reminders → a card with 马上 / 等会儿 ----
  function remindCard(msg) {
    const key = msgKey(msg);
    if (answered.has(key) || notices.has(key) || !isReplyable(msg, Date.now())) return;
    const who = taName();
    const at = new Intl.DateTimeFormat("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(msg.ts || Date.now()));
    notices.add({ tag: key, tone: "ta", title: `${who}叫你${msg.remind === "stand" ? "起来动动 🧍" : "喝水啦 💧"}`, line: `${at} · 回 TA 一声`,
      buttons: [{ title: "马上", primary: true }, { title: "等会儿" }] })
      .then((i) => { if (i === 0) reply(msg, "now"); else if (i === 1) reply(msg, "later"); });
  }

  // ---- my reminders ----
  const ownHandlers = {};
  function showOwnReminder(kind, { partnerAck } = {}) {
    const copy = reminders.copy(kind);
    const line = partnerAck ? `${taName()}刚才叫你${kind === "water" ? "喝水" : "起来动动"}，现在去吧～` : copy.title;
    const done = () => {
      const ack = reminders.done(kind);
      notify.closeFor("own-" + kind);
      notices.close("own-" + kind);
      if (ack) reply({ id: ack, remind: kind }, "now", true);
      refresh();
    };
    const later = () => { reminders.snooze(kind); notify.closeFor("own-" + kind); notices.close("own-" + kind); refresh(); };
    ownHandlers[kind] = { done, later };
    chime();
    notices.add({ tag: "own-" + kind, title: kind === "water" ? "💧 喝水" : "🧍 站立", line, buttons: [{ title: copy.comply, primary: true }, { title: copy.snooze }] })
      .then((i) => { if (i === 0) done(); else if (i === 1) later(); });
    notify.notify("own-remind", { title: line, body: `「${copy.snooze}」10 分钟后再提醒`, remind: kind, comply: copy.comply, icon: nIcon() });
    refresh();
  }

  function pomodoroEvent(e) {
    chime();
    if (e.type === "focusDone") {
      const text = e.breakMinutes >= 1 ? `专注完成！休息 ${e.breakMinutes} 分钟吧` : "专注完成！休息一下吧";
      notices.add({ tag: "pomodoro", title: "🍅 番茄钟", line: text, closable: true });
      notify.notify("pomodoro", { title: "🍅 番茄钟", body: text, icon: nIcon() });
    } else {
      notices.add({ tag: "pomodoro", title: "🍅 番茄钟", line: "休息好啦，开始下一个番茄？", buttons: [{ title: "开始", primary: true }, { title: "先不了" }] })
        .then((i) => { if (i === 0) pomodoro.start(); });
      notify.notify("pomodoro", { title: "🍅 番茄钟", body: "休息好啦，开始下一个番茄？", icon: nIcon() });
    }
    refresh();
  }

  // ---- presence ----
  function publishLook() {
    if (!started) return;
    const pose = dnd.isOn() ? "dnd" : pomodoro.focusing() ? "focus" : "idle";
    channel.setLook?.({ outfit: outfits.yielding() ? undefined : outfits.current(), pose });
    channel.setDnd?.(dnd.status());
    channel.setFocus?.(pomodoro.focus());
  }

  // ---- header / title / strip ----
  function renderPartner() {
    const b = state.partnerKnown ? partnerBadge(state.partner, state.online, Date.now()) : { dot: "⏳", text: "看看 TA 在不在…" };
    dot.dataset.tone = b.dot === "🟢" ? "ok" : b.dot === "⚪️" || b.dot === "⏳" ? "off" : "busy";
    nameEl.textContent = taName();
    statusEl.textContent = b.text;
    compose.setPartner(taName());
    compose.setPolicy(intimate());
    const note = partnerNote(state.partner, state.online, Date.now());
    statusEl.title = note || b.text;
  }
  function renderTitle() {
    if (!started) return;
    const p = prefs();
    document.title = titleText({ unread: state.unread.size, eye: eyedrops.titleBit(), discreet: p.discreet });
    setFavicon(p.discreet);
    notify.setBadge(state.unread.size);
  }
  function renderBanner() {
    const perm = notify.permission();
    const yieldOn = state.yielding && state.connected && (dnd.isOn() || pomodoro.focusing());
    if (perm === "default") {
      setChildren(banner, h("span", "提醒靠系统通知：允许后，页面在后台也能弹出来。"),
        h("button.mi-btn.primary.small", { type: "button", onclick: async () => { await notify.requestPermission(); renderBanner(); } }, "允许通知"));
      banner.hidden = false;
    } else if (perm === "denied") {
      setChildren(banner, h("span", "通知被拦住了：地址栏左边的图标 → 网站设置 → 通知 → 允许。"));
      banner.hidden = false;
    } else if (yieldOn) {
      setChildren(banner, h("span", "家里的 Mac 在线，TA 看到的是 Mac 上的状态"));
      banner.hidden = false;
    } else banner.hidden = true;
  }
  function refresh() {
    if (!started) return;
    renderTitle();
    renderBanner();
    renderDnd();
    tools.render();
    setChildren(stripBits, tools.bits().map((b) => h("span.mi-bit", { class: b.due ? "due" : null }, b.text)));
    if (!stripBits.childNodes.length) stripBits.append(h("span.mi-bit.muted", "喝水 · 站立 · 眼药水 · 番茄钟"));
    settings.render();
  }
  function applyPrefs() {
    renderPartner();
    renderTitle();
    history.refresh();
  }
  setInterval(() => { renderPartner(); refresh(); }, 30_000);
  setInterval(() => { if (pomodoro.state().phase !== "idle" && !document.hidden) { tools.render(); setChildren(stripBits, tools.bits().map((b) => h("span.mi-bit", { class: b.due ? "due" : null }, b.text))); } }, 1000);

  // ---- ⋯ menu ----
  function moreMenu() {
    openMenu(() => {
      const ps = pomodoro.state();
      return [
        { label: "设置…", onClick: openSettings },
        { label: "小工具设置…", onClick: openToolsMore },
        { label: ps.phase === "idle" ? "开始专注 🍅" : "结束番茄钟", onClick: () => (ps.phase === "idle" ? pomodoro.start() : pomodoro.stop()) },
        { label: dnd.isOn() ? "关掉勿扰" : "勿扰…", onClick: () => (dnd.isOn() ? dnd.turnOff() : toggleDndRow(true)) },
        { separator: true },
        { label: todoCount ? `待设置（${todoCount}）` : "待设置", onClick: () => openTodos(todoCtx, (n) => { todoCount = n; }) },
        { label: "更新日志…", onClick: () => openChangelog(version()) },
        { separator: true },
        { label: "切回完整宠物", onClick: () => switchMode(false) },
      ];
    }, { anchor: menuBtn });
  }

  // ---- channel events ----
  const on = (type, fn) => channel.addEventListener(type, (e) => { try { fn(e.detail || {}); } catch (err) { console.error(err); } });
  on("connection", ({ state: s, reason }) => {
    const line = connectionLine(s, reason);
    connEl.textContent = s === "connected" ? "" : line.text;
    connEl.title = line.text;
    connEl.dataset.tone = line.tone;
    state.connected = s === "connected" || s === "polling";
    const elsewhere = s === "elsewhere";
    $("#blocked").hidden = !elsewhere;
    host.hidden = elsewhere;
    refresh();
  });
  on("mySeat", ({ presence, yielding, identity }) => {
    state.mine = presence || null;
    state.yielding = !!yielding;
    if (identity) state.identity = identity;
    outfits.setSeat({ character: myCharacter(), yielding: state.yielding, outfit: state.mine?.outfit ?? state.identity?.outfit });
    publishLook();
    renderPartner();
    refresh();
  });
  on("partner", ({ presence, online }) => {
    state.partnerKnown = true;
    state.partner = presence || null;
    state.online = !!online;
    renderPartner();
  });
  on("backlog", ({ msgs }) => {
    const all = msgs || [];
    history.add(all);
    for (const m of all.filter((x) => x.from !== me)) {
      if (m.kind === "remind" && !m.ackOf) { pendingReminds.set(msgKey(m), m); remindCard(m); }
      state.unread.set(msgKey(m), m);
    }
    if (all.some((m) => m.from !== me)) partnerNotify(all.filter((m) => m.from !== me));
    readSeen();
  });
  on("folded", ({ count }) => { if (count > 0) compose.showNote(`还有 ${count} 条更早的消息，已经算看过了`, 6000); });
  on("parked", () => toast("有一条消息没发出去", 6000));
  on("own", ({ msg }) => {
    if (!msg) return;
    history.add([msg]);
    if (decodeReply(msg) && typeof msg.ackOf === "string") {
      pendingReminds.delete(msg.ackOf);
      answered.add(msg.ackOf);
      notices.close(msg.ackOf);
    }
  });
  on("message", ({ msg, live }) => {
    if (!msg || msg.from === me || live === false) return;
    history.add([msg]);
    const key = msgKey(msg);
    if (msg.kind === "remind" && !msg.ackOf) { pendingReminds.set(key, msg); remindCard(msg); }
    state.unread.set(key, msg);
    partnerNotify([msg]);
    readSeen();
  });

  /** TA's messages → system notifications, unless I'm looking at the panel or in 勿扰 / 专注 (then just the list). */
  function partnerNotify(msgs) {
    const held = dnd.isOn() || pomodoro.focusing();
    for (const msg of msgs) {
      const remind = !!describe(msg).remind && isReplyable(msg, Date.now());
      // A reminder card is the thing to answer: its notification comes even while held, so it isn't missed.
      if (!notifyPartner({ ...looking(), held: held && !remind })) continue;
      if (!remind && Date.now() - msg.ts > 10 * 60_000) continue;     // old backlog: the list is enough
      const d = describe(msg);
      const key = msgKey(msg);
      const line = msg.kind === "sticker" ? stickerText(stickerById(msg.stickerId)?.label ?? "") : d.line.replace(nameOf(partnerCharacter()), taName());
      const kind = remind ? "partner-remind" : "message";
      const t = partnerNotice(kind, { name: nameOf(partnerCharacter()), line, isText: msg.kind === "text" }, prefs());
      notify.notify(kind, { title: t.title, body: t.body, key, remind: remind ? d.remind : undefined, icon: nIcon() });
    }
  }

  // ---- notification buttons (same contract as the full page) ----
  function handleAction({ action, data }) {
    if (!data) return;
    if (data.kind === "eyedrops") {
      const slot = typeof data.slot === "string" ? data.slot : eyedrops.showing();
      if (action === "done" && slot) eyedrops.markDone(slot);
      else if (action === "later" || action === "close") eyedrops.later();
      return;
    }
    if (data.kind === "own-remind" && (data.remind === "water" || data.remind === "stand")) {
      const hnd = ownHandlers[data.remind];
      if (action === "done" || action === "close") (hnd?.done ?? (() => reminders.done(data.remind)))();
      else if (action === "later") (hnd?.later ?? (() => reminders.snooze(data.remind)))();
      return;
    }
    if (data.kind === "partner-remind" && (action === "now" || action === "later") && typeof data.key === "string") {
      const msg = pendingReminds.get(data.key) || { id: data.key, remind: data.remind };
      reply(msg, action);
      if (msg.ts) markRead(msg);
    }
  }
  notify.onAction(handleAction);
  onActiveChange(() => {});
  const seen = () => { readSeen(); if (!document.hidden) countTodos(); };
  document.addEventListener("visibilitychange", seen);
  window.addEventListener("focus", seen);

  // ---- go ----
  started = true;
  renderPartner();
  layoutTools();
  refresh();
  countTodos();
  history.open();
  Promise.resolve(channel.start()).catch((e) => {
    console.error(e);
    connEl.textContent = "未连接：" + (e?.message || "出错了");
    connEl.dataset.tone = "bad";
  });
  const pendingAction = await notify.takePending();
  if (pendingAction) handleAction(pendingAction);
  whatsNew(version(), (seenV) => openChangelog(version(), seenV));
  compose.focus();

  if (DEV) {
    window.__lulu = { minimal: true, channel, reminders, eyedrops, pomodoro, dnd, history, notices, state, showOwnReminder, pomodoroEvent, openSettings, refresh };
  }
  return new Promise(() => {});   // keep the leader lock
}

/** As an installed app: 360×600 in the bottom-right corner the first time (Chrome remembers it afterwards). */
function placeWindow(force = false) {
  if (!isStandalone() || (!force && store.get("minimalWindowPlaced", false))) return;
  try {
    const w = 360, hgt = 600, s = window.screen;
    window.resizeTo(w, hgt);
    window.moveTo((s.availLeft ?? 0) + s.availWidth - w - 16, (s.availTop ?? 0) + s.availHeight - hgt - 16);
    store.set("minimalWindowPlaced", true);
  } catch { /* not allowed (a normal tab) */ }
}
