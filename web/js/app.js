// Entry (web v2, spec §3–§4): the shell around W5's world and W3's channel. W1 / W3 / W5 are reached only through
// js/ui/deps.js. Two layouts: 桌宠模式 (installed app default, and the 桌宠小窗 popup a plain tab opens: a pet-sized window, the panel in its own small window —
// js/ui/petmode.js) and 展开面板 (tabs / phones: world on top or left, panel tabs 传话 · 记录 · 小工具 · 设置); 🍊 menu;
// 置顶小窗 (PiP) moves the world element; controllers for 勿扰 / 番茄钟 / 换装 / 喝水站立 / 眼药水 live in js/ui.

import { DEV, loadNet, v2, TZ, build, msgKey, allowsIntimate, decodeReply, SEATS, dndActive, focusActive, createScheduler, createToolsSync } from "./ui/deps.js";
import { h, $, setChildren, toast, nameOf, setToastDoc } from "./ui/dom.js";
import { store, deviceId, loadConfig } from "./ui/store.js";
import { loadManifest, stickerById, outfitOf, getManifest } from "./ui/assets.js";
import { describe } from "./ui/describe.js";
import { createCompose } from "./ui/compose.js";
import { createWeatherCard, snapshotFor } from "./ui/weather-card.js";
import { createAwayCard } from "./ui/away-card.js";
import { createSetup } from "./ui/setup.js";
import { createPip, pipSupported } from "./ui/pip.js";
import { connectionLine, partnerBadge, partnerNote } from "./ui/status.js";
import { watchInput, idlePermission, startIdle, onActiveChange } from "./ui/activity.js";
import { createReminders } from "./ui/reminders.js";
import { createEyedrops } from "./ui/eyedrops.js";
import { createPomodoro } from "./ui/pomodoro.js";
import { createDnd } from "./ui/dnd.js";
import { createOutfits } from "./ui/outfits.js";
import { createHistoryTab } from "./ui/history-tab.js";
import { createToolsTab } from "./ui/tools-tab.js";
import { createSettingsTab } from "./ui/settings-tab.js";
import { openMenu, closeMenu } from "./ui/menu.js";
import { openSheet, openTodos, openChangelog, setupTodos, whatsNew, isStandalone, setSheetDoc, canInstall, onInstallable, promptInstall, installHow } from "./ui/sheets.js";
import { createBackdrop } from "./ui/backdrop.js";
import { createPetMode, layoutFor } from "./ui/petmode.js";
import { isPetPopup, popupSupported, openPetPopup, petPopupOpen, claimPetWindow, onPetOpened, askPetBack, whenPetGone } from "./ui/petpopup.js";
import { prefs, SIZES, VOLUMES } from "./ui/prefs.js";
import { prefetch, prefetchList } from "./ui/prefetch.js";
import { migrateV1 } from "./ui/migrate.js";
import * as notify from "./ui/notify.js";
import { watchVersion } from "./ui/version.js";
import { minimalPrefs, finePointer, switchMode, setFavicon } from "./ui/minimal/mode.js";
import { useMinimal, shouldOffer, titleText } from "./ui/minimal/logic.js";
import { modeSection } from "./ui/minimal/settings-section.js";

const view = {
  setup: $("#setup-view"),
  main: $("#main-view"),
  conn: $("#conn"),
  ta: $("#ta-line"),
  update: $("#update"),
  blocked: $("#blocked"),
  parked: $("#parked"),
  desk: $("#desk"),
  boot: $("#boot"),
  worldFrame: $("#world-frame"),
  worldHost: $("#world-host"),
  strip: $("#world-strip"),
  pinBtn: $("#pin-btn"),
  menuBtn: $("#menu-btn"),
  composeBtn: $("#compose-btn"),
  tabbar: $("#tabbar"),
};
const TABS = ["compose", "history", "tools", "settings"];
const HIDE_FOR = [{ label: "5 分钟", ms: 5 * 60_000 }, { label: "30 分钟", ms: 30 * 60_000 }, { label: "1 小时", ms: 60 * 60_000 }];
const VISIT_COOLDOWN_MS = 10_000;
const PRESENCE_CHECK_MS = 1500;   // PairChannel.refreshPartnerPresence(timeout: 1.5)
const hhmm = (ms) => new Intl.DateTimeFormat("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(ms));
let version = null;

async function main() {
  migrateV1(store);
  watchInput(document);
  notify.registerSW();
  watchVersion({
    onVersion: (v) => { version = v; },
    onUpdate: () => {
      setChildren(view.update, "网页版有更新 · ", h("button.link", { type: "button", onclick: () => location.reload() }, "刷新"));
      view.update.hidden = false;
    },
  });
  // 极简模式 (js/ui/minimal): per device, never on a phone; no pet, so the 桌宠小窗 handover doesn't apply.
  const mini = minimalPrefs.get();
  let minimal = useMinimal(mini, { phone: isPhone() });
  if (minimal) {
    if (mini.discreet) { document.title = titleText({ discreet: true }); setFavicon(true); }
    if (isPetPopup()) { store.set("petPopup", false); window.close(); }   // a pet popup from before: the tab takes over
  }
  // 桌宠小窗: the popup owns everything while it is open; a normal tab steps aside (js/ui/petpopup.js).
  else if (isPetPopup() && popupSupported()) await claimPetWindow();
  else if (popupSupported() && loadConfig() && await petPopupOpen()) return showParked();
  if (await idlePermission() === "granted") startIdle();

  try {
    await loadManifest();
  } catch (e) {
    console.error(e);
    view.boot.hidden = true;
    setChildren(view.main, h("p.fatal", "素材没加载出来，请刷新试试。"));
    view.main.hidden = false;
    return;
  }
  view.boot.hidden = true;

  const config = loadConfig();
  if (!config) return showSetup();
  if (!minimal && shouldOffer(mini, { phone: isPhone(), fine: finePointer(), popup: isPetPopup() })) {
    minimal = await (await import("./ui/minimal/choice.js")).chooseMode(view.setup);
  }
  if (minimal) {
    view.main.hidden = true;
    const { runMinimal } = await import("./ui/minimal/run.js");
    return runMinimal(config, { version: () => version });
  }
  run(config);
}

/** The pet is in its popup: this tab shows only that, and takes over again as soon as the popup is gone. */
function showParked() {
  view.boot.hidden = true;
  document.body.classList.add("is-parked");
  document.title = "噜噜 · 在桌宠小窗里";
  view.parked.hidden = false;
  const hint = $("#parked-hint");
  $("#parked-back").onclick = () => {
    askPetBack();
    setTimeout(() => { hint.textContent = "小窗没有自己关上：直接关掉那个小窗就行。"; }, 2500);
  };
  whenPetGone(() => {
    // The popup closed while this tab is still here = the user brought the pet back. (Wait a moment: when Chrome
    // quits, both go, and the wish to have the pet out should survive that.)
    setTimeout(() => { store.set("petPopup", false); location.reload(); }, 800);
  });
}

async function showSetup() {
  if (isStandalone()) try { window.resizeTo(440, 700); } catch { /* not allowed */ }   // a pet-sized window from before
  const seatsReader = DEV ? (await import("./ui/dev/fake-channel.js")).fakeReadSeats : undefined;
  const setup = createSetup({ current: null, seatsReader, onSave: () => location.reload() });
  setChildren(view.setup, setup.el);
  document.body.classList.add("first-run");
  view.setup.hidden = false;
}

/** 展开面板 as an installed app window, first time: 380×680 in the bottom-right corner (Chrome remembers it afterwards). */
function placeWindow(force = false) {
  if (petMode) return petMode.place(force);
  if (!isStandalone() || (!force && store.get("windowPlaced", false))) return;
  try {
    const w = 380, hgt = 680, s = window.screen;
    window.resizeTo(w, hgt);
    window.moveTo((s.availLeft ?? 0) + s.availWidth - w - 16, (s.availTop ?? 0) + s.availHeight - hgt - 16);
    store.set("windowPlaced", true);
  } catch { /* not allowed here (a normal tab) */ }
}

let petMode = null;
const backdrop = createBackdrop();
const isPhone = () => matchMedia("(pointer: coarse) and (max-width: 479px)").matches;
const layout = () => layoutFor({ standalone: isStandalone(), phone: isPhone(), pref: store.get("layout", null), petWindow: isPetPopup(),
  dev: DEV ? new URLSearchParams(location.search).get("layout") : null });

async function run(config) {
  const me = config.seat;
  const ta = SEATS.find((s) => s !== me);
  view.main.hidden = false;
  backdrop.load();

  const state = {
    mine: null, yielding: true, identity: null,
    partner: null, partnerKnown: false, online: false, wasOnline: null,
    connected: false,
    worldPose: "idle",
    hiddenUntil: 0,
    unread: new Set(),
    held: { dnd: [], focus: [], hidden: [] },
    lastVisit: 0,
  };
  const pendingReminds = new Map();
  const scheduler = createScheduler({ tickMs: 15_000 });
  const myCharacter = () => {
    const p = state.identity || state.mine;
    return p?.character === "lulu" || p?.character === "lumei" ? p.character : me;
  };
  const myMode = () => ((state.identity || state.mine)?.mode === "friend" ? "friend" : "couple");
  const partnerLook = () => {
    const p = state.partner;
    const character = p?.character === "lulu" || p?.character === "lumei" ? p.character : ta;
    return { character, outfit: outfitOf(character, p?.outfit), mode: p?.mode === "friend" ? "friend" : "couple" };
  };
  const taName = () => nameOf(partnerLook().character);
  const intimate = () => allowsIntimate(myMode(), partnerLook().mode);
  // Like the Mac's PairChannel.partnerNeverSeen: a presence with any lastSeen (0 = signed off) or a dnd means TA has paired.
  const everSeen = () => !!(state.partner && (typeof state.partner.lastSeen === "number" || state.partner.dnd || state.online));
  const partnerDnd = () => (state.online && dndActive(state.partner?.dnd, Date.now()) ? state.partner.dnd : null);
  const partnerFocus = () => (state.online && focusActive(state.partner?.focus, Date.now()) ? state.partner.focus : null);

  const { createChannel, createStore } = await loadNet();
  const channel = createChannel({ config, store: createStore(), deviceId: deviceId(),
    defaultOutfits: { lulu: outfitOf("lulu"), lumei: outfitOf("lumei") } });
  if (DEV !== "fake" && DEV !== "pip") import("./net/devices.js").then((m) => m.startDeviceActivity({ config, deviceId: deviceId() })).catch(console.error);   // which device I'm using → push routing
  const log =(line) => console.log("[lulu]", line);

  let started = false;   // set once every piece below exists (controllers may call back while being built)
  let world = null;
  // ---- controllers ----
  const dnd = createDnd({ scheduler, onChange: () => { renderMood(); publishLook(); refreshUi(); }, onEnded: () => flushHeld("dnd") });
  const outfits = createOutfits({ scheduler, onChange: () => { applyLook(); publishLook(); refreshUi(); } });
  const reminders = createReminders({ onFire: (kind, o) => showOwnReminder(kind, o) });   // 勿扰 / 专注 don't block (user decision)
  const pomodoro = createPomodoro({
    scheduler,
    config: () => reminders.settings().pomodoro,
    onChange: () => { renderMood(); publishLook(); refreshUi(); if (!pomodoro.focusing()) flushHeld("focus"); },
    onEvent: (e) => pomodoroEvent(e),
  });
  const eyedrops = createEyedrops({
    sync: createToolsSync({ config, deviceId: deviceId() }),
    deviceId: deviceId(), scheduler, log,
    show: ({ slot, copy, shown, notify: n }) => {
      if (shown === 1) world.playTool("eyedrops");
      world.bubble({ header: copy.header, line: copy.line, tag: "eyedrops", replace: true, urgent: true, sound: "eyedrops",
        buttons: [{ title: copy.done, primary: true }, { title: copy.later }] })
        .then((i) => { if (i === 0) eyedrops.markDone(slot); else if (i === 1) eyedrops.later(); });
      if (n) notify.notify("eyedrops", { title: copy.header, body: copy.line, slot });
      refreshUi();
    },
    hide: () => { world.closeBubble("eyedrops"); notify.closeFor("eyedrops"); refreshUi(); },
    onChange: () => refreshUi(),
  });

  // ---- sound + world (W5) ----
  const sound = v2.createSound({ manifest: getManifest(), log: DEV ? (l) => console.log(l) : undefined });
  sound.setPrefs(prefs.get().sound);
  sound.unlock(document);
  world = v2.createWorld({
    manifest: getManifest(),
    sound,
    log: DEV ? (l) => console.log("[world]", l) : null,
    policy: () => {
      const p = partnerLook();
      return { allowsIntimate: intimate(), allowsCoupleClips: p.character !== myCharacter(), partnerCharacter: p.character, partnerOutfit: p.outfit };
    },
    onReply: (msg, answer) => reply(msg, answer),
    onRead: (m) => markRead(m),
    onCompose: (t) => (t === "history" ? showPanel("history") : petMode ? petMode.togglePanel("compose") : showPanel("compose")),
    onMenu: (pt) => orangeMenu(pt),
    onPeekDone: () => {},
  });
  view.worldHost.append(world.element);
  world.mountIn(document);
  world.on("pose", (p) => { state.worldPose = typeof p === "string" ? p : "idle"; publishLook(); });
  world.on("dragged", ({ x }) => { if (!petMode) store.set("petX", x); });
  world.on("scaled", (s) => { prefs.set({ petScale: s }); settings?.render(); petMode?.fit(); });
  world.on("wantThink", (reason) => { if (state.partner) world.think(reason, partnerScene(state.partner, reason)); });
  world.on("collision", (c) => log(`collision: ${c?.winner ?? "?"} goes first`));

  // ---- 待设置 ----
  let todoCount = 0;
  const todoCtx = { macApp: () => (typeof state.mine?.app === "string" && !String(state.mine?.device ?? "").startsWith("web-") ? state.mine.app : null) };
  const setTodoCount = (n) => { todoCount = n; };
  const countTodos = () => setupTodos(todoCtx).then((t) => setTodoCount(t.length));

  // ---- panel ----
  const compose = createCompose({ send, act, onExpand: () => petMode?.composeExpanded() });
  let partnerLookWas = { look: null, had: false };
  const weather = createWeatherCard({ onChange: () => {
    world.setWeather(v2.weatherlook.weatherLook(withCondition(snapshotFor(state.mine?.place))));
    // TA's weather turned rainy / snowy / hot: a 想 TA bubble (ThinkRules.weatherTrigger; ignores the cooldown).
    const snap = withCondition(snapshotFor(state.partner?.place));
    const look = v2.weatherlook.weatherLook(snap);
    const trig = v2.think.weatherTrigger(partnerLookWas.look, partnerLookWas.had, look);
    partnerLookWas = { look, had: partnerLookWas.had || !!snap };
    if (trig && state.online) world.think("weather:" + trig, partnerScene(state.partner, "weather:" + trig));
  } });
  const away = createAwayCard({
    onReply: reply,
    onDone: (msgs) => { for (const m of msgs.slice().sort((a, b) => a.ts - b.ts)) markRead(m); },
  });
  const yieldNote = h("div.yield-note", { hidden: true }, "家里的 Mac 在线，TA 看到的是 Mac 上的状态");
  const history = createHistoryTab({ config, me, partnerName: taName });
  const tools = createToolsTab({ pomodoro, reminders, eyedrops, onSettingsChange: () => refreshUi() });
  const settings = createSettingsTab({
    config, me,
    seatInfo: () => ({ character: myCharacter(), mode: myMode(), place: state.mine?.place }),
    editConnection: () => openSheet({ icon: "🔗", title: "连接", body: createSetup({ current: config, onSave: () => location.reload() }).el }),
    placeWindow, canPlaceWindow: () => isStandalone() || !!petMode,
    backdrop, layout: () => (petMode ? "pet" : "panel"),
    canChooseLayout: () => (isStandalone() || !!DEV) && !isPhone(),
    canChooseBackdrop: () => !isPhone() && (popupSupported() || pipSupported()),
    setLayout: (v) => { store.set("layout", v); petMode?.closePanel(); location.reload(); },
    openTodos: () => openTodos(todoCtx, setTodoCount),
    openChangelog: () => openChangelog(version),
    todoCount: () => todoCount,
    version: () => (version ? `网页版 v${version}` : "网页版"),
    onPrefs: (o = {}) => applyPrefs(o),
    downloadAll: (onProgress) => prefetch(prefetchList(looks(), { full: true }), { onProgress }),
    intimate,
    modeSection: () => (isPhone() ? null : modeSection({ minimal: false })),
  });
  const panes = {
    compose: h("div.pane-stack", compose.el, yieldNote, away.el, weather.el),
    history: history.el,
    tools: tools.el,
    settings: settings.el,
  };
  const paneEls = Object.fromEntries(TABS.map((t) => [t, $("#tab-" + t)]));   // kept: the panel may move to its own window
  for (const t of TABS) paneEls[t].append(panes[t]);
  compose.render();

  const askedTab = new URLSearchParams(location.search).get("tab");   // manifest shortcuts: ?tab=compose / ?tab=tools
  let tab = TABS.includes(askedTab) ? askedTab : TABS.includes(store.get("panelTab")) ? store.get("panelTab") : "compose";
  function selectTab(t) {
    tab = t;
    store.set("panelTab", t);
    for (const b of view.tabbar.querySelectorAll("[role=tab]")) {
      const on = b.dataset.tab === t;
      b.setAttribute("aria-selected", String(on));
      b.tabIndex = on ? 0 : -1;
    }
    for (const x of TABS) paneEls[x].hidden = x !== t;
    if (t === "history") history.open();
    if (t === "tools") tools.show(); else tools.hide();
    if (t === "settings") settings.show(); else settings.hide();
  }
  view.tabbar.addEventListener("click", (e) => { const b = e.target.closest("[role=tab]"); if (b) selectTab(b.dataset.tab); });
  view.tabbar.addEventListener("keydown", (e) => {
    if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
    const i = TABS.indexOf(tab) + (e.key === "ArrowRight" ? 1 : -1);
    selectTab(TABS[(i + TABS.length) % TABS.length]);
    view.tabbar.querySelector(`[data-tab="${tab}"]`).focus();
  });
  selectTab(tab);

  // ---- 桌宠模式 / where the panel shows ----
  if (layout() === "pet") {
    petMode = createPetMode({
      world, panel: $(".panel"), compose, selectTab, backdrop, scale: () => prefs.get().petScale,
      setDocHost: (doc) => { setSheetDoc(doc); setToastDoc(doc); },
    });
    petMode.start();
  } else placeWindow();
  view.composeBtn.hidden = !petMode;
  view.composeBtn.onclick = () => showPanel("compose", { compact: true });
  /** The panel at a tab: its own small window in 桌宠模式 (compact = just the 传话 box), else the tab here. */
  function showPanel(t, { compact = false } = {}) {
    if (petMode) return petMode.openPanel(t, { compact });
    selectTab(t);
    if (t === "compose") compose.focus();
  }

  // ---- PiP ----
  const pip = createPip({
    world, worldHome: view.worldHost, compose, composeHome: panes.compose, backdrop,
    onHeart: () => act("heart"),
    eyeLabel: () => eyedrops.titleBit(),
    onEye: () => {
      const slot = eyedrops.showing();
      if (slot) eyedrops.markDone(slot);
      else world.bubble({ header: "👁️💧 眼药水", line: eyedrops.settings().enabled ? `今天 ${eyedrops.progress().done}/${eyedrops.progress().total}` : "眼药水提醒没开", tag: "eye-peek", autoHide: 3000, sound: null });
    },
    onDoc: (doc) => { watchInput(doc); sound.unlock(doc); },
    onState: (open) => { document.body.classList.toggle("pip-open", open); renderStrip(); view.pinBtn.setAttribute("aria-pressed", String(open));
      $("#desk-pip-title").textContent = open ? "收回置顶小窗" : "置顶小窗"; placeInsets(); },
  });
  const pipAvailable = (pipSupported() && !isPhone()) || DEV === "pip";   // no 置顶小窗 on phones
  view.pinBtn.hidden = !pipAvailable;
  function togglePip() {
    if (pip.isOpen()) pip.close();
    else if (DEV === "pip") pip.openSim($("#pip-sim-host"));
    else pip.open().catch((e) => { console.warn(e); toast("小窗没打开：要在 Chrome 116 以上点按钮打开"); });
  }
  view.pinBtn.onclick = togglePip;

  // ---- 桌宠小窗 (a Chrome popup; js/ui/petpopup.js) ----
  // In a normal tab (the panel layout) the landing shows two big buttons; opening the popup hands everything over.
  const canPopup = !petMode && !isPhone() && popupSupported();
  view.desk.hidden = !canPopup;
  if (canPopup) {
    onPetOpened(() => location.reload());   // the popup took the pet: this tab steps aside (parked page)
    const again = () => store.get("petPopup", false) === true;   // Chrome was quit with the pet out
    const renderDesk = () => {
      $("#desk-again").hidden = !again();
      $("#popup-title").textContent = again() ? "再打开桌宠小窗" : "打开桌宠小窗";
      $("#desk-pip").hidden = !pipAvailable;
      // Installing is the best pet (桌宠模式 in its own window); a suggestion, dismissable like any 待设置 item.
      const dismissed = (store.get("setupTodoDismissed", []) || []).includes("install");
      $("#desk-install").hidden = dismissed;
      $("#install-btn").textContent = canInstall() ? "安装" : "怎么装？";
    };
    $("#install-btn").onclick = async () => {
      if (!(await promptInstall())) openSheet({ icon: "🍊", title: "装成桌宠 App", subtitle: "装好后噜噜就有自己的小窗口",
        body: [h("p", installHow()), h("p.muted.small", "不想装也没关系：「打开桌宠小窗」差不多，只是窗口上面多一条细细的地址栏。")] });
      renderDesk();
    };
    onInstallable(() => renderDesk());
    $("#popup-btn").onclick = () => {
      if (!openPetPopup({ scale: prefs.get().petScale })) toast("Chrome 拦住了小窗：点地址栏右边的图标 →「始终允许」，再点一次", 6000);
    };
    $("#desk-pip").onclick = togglePip;
    $("#desk-nope").onclick = () => { store.set("petPopup", false); renderDesk(); };
    renderDesk();
  }
  /** In the popup: 「回到网页」 closes it; the tab that opened it (if still there) takes over. */
  function backToTab() {
    store.set("petPopup", false);
    try { if (window.opener && !window.opener.closed) window.opener.focus(); } catch { /* ignore */ }
    window.close();
  }
  /** Bubbles keep clear of 📌 / 🍊 (top-right of the world); in the PiP window there are no corner buttons. */
  function placeInsets() {
    if (petMode) return world.setInsets({});   // the hover buttons fade away; the small window needs all its room
    const tools = view.worldFrame.querySelector(".world-tools");
    const f = view.worldHost.getBoundingClientRect(), t = tools.getBoundingClientRect();
    if (pip.isOpen() || !t.width || !f.width) return world.setInsets({});
    world.setInsets({ top: Math.ceil(t.bottom - f.top + 4), right: Math.ceil(f.right - t.left + 4) });
  }
  window.addEventListener("resize", placeInsets);
  view.menuBtn.onclick = () => orangeMenu({ anchor: view.menuBtn });
  $("#title-menu-btn").onclick = (e) => orangeMenu({ anchor: e.currentTarget });   // window-controls-overlay title area

  // ---- sending ----
  // Like the Mac's send(): with the pet on screen and the database reachable, TA's presence is read fresh first
  // (1.5 s at most) so a TA who just quit is seen as away and the pet bounces. Sends stay in order.
  let sendChain = Promise.resolve();
  function send(partial) {
    const fresh = worldVisible() && state.connected;
    if (!fresh) { dispatchSend(partial); return; }
    sendChain = sendChain.then(async () => {
      try {
        await Promise.race([channel.peekPartner?.(), new Promise((r) => setTimeout(r, PRESENCE_CHECK_MS))]);
      } catch { /* go by what we know */ }
      dispatchSend(partial);
    });
  }

  function dispatchSend(partial) {
    let msg;
    if (partial.kind === "text") msg = build.text(partial.text, me);
    else if (partial.kind === "sticker") msg = build.sticker(partial.stickerId, partial.label, me);
    else if (partial.kind === "poke") msg = build.poke(me);
    else if (partial.kind === "visit") msg = build.visit(me);
    else if (partial.kind === "remind") msg = build.remind(partial.remind, me);
    if (!msg) return;
    // Like the Mac's dispatchSend: the world decides the trip (deliver / bounce / meeting / cooldown) and sets
    // msg.trip synchronously ("deliver" | "local" | null = don't send); the message goes out right after.
    const V = v2.visits;
    const pd = partnerDnd(), pf = !pd && partnerFocus();
    const visible = worldVisible();
    const verdict = {
      visible, reachable: state.online && state.connected && !pd && !pf,
      partnerDND: !!pd, partnerFocus: !!pf, notPaired: !everSeen(), bounceLine: pd ? v2.dnd.bounceLine(pd) : null,
    };
    const trip = world.goDeliver(msg, verdict);
    trip.catch(() => {});
    if (msg.trip == null) {
      if (!visible) toast(V.OFFLINE_LINE, 3000);
      return;
    }
    try {
      const sent = channel.send(msg, { trip: msg.trip });
      history.add([sent]);
    } catch (e) {
      console.error(e);
      toast("没发出去，等会儿再试试");
      return;
    }
    if (visible) return;
    // No pet on screen to run: a line instead.
    if (!everSeen()) toast(V.sendsWhenOffline(msg.kind) ? V.NOT_PAIRED_QUEUED_LINE : V.NOT_PAIRED_LINE, 3000);
    else if (pd) toast(v2.dnd.bounceLine(pd), 3000);
    else if (pf) toast(V.FOCUS_BOUNCE_LINE, 3000);
    else if (!state.online) toast(V.OFFLINE_QUEUED_LINE, 3000);
    else toast(partial.kind === "poke" ? "❤️ 送出去啦" : "发出去啦 ✓", 2000);
  }

  function act(kind) {
    if (kind === "heart") return send({ kind: "poke" });
    if (kind === "water" || kind === "stand") return send({ kind: "remind", remind: kind });
    if (kind === "visit") {
      if (Date.now() - state.lastVisit < VISIT_COOLDOWN_MS) return toast("刚去过啦，歇一会儿再去");
      state.lastVisit = Date.now();
      return send({ kind: "visit" });
    }
    if (kind === "peek") return peek();
  }

  /** 偷看: one fresh GET of TA's presence, then a 9 s cloud (the world says 「还看不到 TA」 / 「TA 正在你这儿呢」 itself). */
  async function peek() {
    let p = state.partner;
    try { p = (await channel.peekPartner?.()) ?? p; } catch { /* use what we have */ }
    if (!worldVisible()) return toast(everSeen() ? "把宠物放出来才能偷看哦" : v2.think.PEEK_NEVER_SEEN_TOAST);
    world.peek(partnerScene(p, "peek"));
  }

  /** What the 想 TA / 偷看 cloud draws (world/think.js scene). */
  function partnerScene(p = state.partner, reason = "idle") {
    const look = partnerLook();
    const online = state.online && !!p;
    const snap = withCondition(snapshotFor(p?.place));
    const now = Date.now();
    const dnd = online && dndActive(p?.dnd, now) ? p.dnd : null;
    return {
      character: look.character, outfit: outfitOf(look.character, p?.outfit),
      // offline: the pet is drawn dozing (like the Mac's think bubble for an absent partner)
      pose: !online ? "doze" : dnd ? "dnd" : (p?.pose ?? "idle"),
      dndSign: dnd ? v2.pose.dndSign(dnd) : null,
      bar: reason === "peek" ? v2.think.peekBarText(online, p?.place ?? null, snap, now) : v2.think.barText(reason, p?.place ?? null, snap, now),
      flourish: v2.think.flourish(snap),
      everSeen: everSeen(),
    };
  }
  const withCondition = (snap) => (snap ? { ...snap, condition: snap.condition ?? null } : null);

  function reply(msg, answer, late = false) {
    const kind = msg.remind === "stand" ? "stand" : "water";
    const key = msgKey(msg);
    try {
      const sent = channel.send(build.reply(kind, answer, me, key, late));
      history.add([sent]);
    } catch (e) {
      console.error(e);
      toast("没发出去，等会儿再试试");
      return;
    }
    pendingReminds.delete(key);
    store.set("answeredReminds", [...(store.get("answeredReminds", []) || []), key].slice(-50));
    notify.closeFor("msg-" + key);
    away.resolved(key);
    world.closeBubble(key);
    if (answer === "later") reminders.partnerSnoozed(kind, key);
    else if (!late) reminders.partnerDone(kind);
  }

  function markRead(msg) {
    try { channel.markRead(msg); } catch (e) { console.error(e); }
    state.unread.delete(msgKey(msg));
    notify.closeFor("msg-" + msgKey(msg));
    renderTitle();
  }

  // ---- my reminders / pomodoro bubbles ----
  function showOwnReminder(kind, { partnerAck } = {}) {
    const copy = reminders.copy(kind);
    const header = kind === "water" ? "💧 喝水" : "🧍 站立";
    const line = partnerAck ? `${taName()}刚才叫你${kind === "water" ? "喝水" : "起来动动"}，现在去吧～` : copy.title;
    const done = () => {
      const ack = reminders.done(kind);
      notify.closeFor("own-" + kind);
      if (ack) reply({ id: ack, remind: kind }, "now", true);
    };
    const later = () => { reminders.snooze(kind); notify.closeFor("own-" + kind); };
    world.playTool(kind);
    world.bubble({ header, line, tag: "own-" + kind, replace: true, urgent: true, sound: "remind",
      buttons: [{ title: copy.comply + " ✓", primary: true }, { title: copy.snooze }] })
      .then((i) => { if (i === 0) done(); else if (i === 1) later(); });
    notify.notify("own-remind", { title: line, body: `「${copy.snooze}」10 分钟后再提醒`, remind: kind, comply: copy.comply });
    ownHandlers[kind] = { done, later };
  }
  const ownHandlers = {};

  function pomodoroEvent(e) {
    if (!world) return;
    if (e.type === "focusDone") {
      const text = e.breakMinutes >= 1 ? `专注完成！休息 ${e.breakMinutes} 分钟吧` : "专注完成！休息一下吧";
      world.playTool("breakTime");
      world.bubble({ header: "🍅 番茄钟", line: text, tag: "pomodoro", replace: true, urgent: true, autoHide: 8000, sound: "pomodoro" });
      notify.notify("pomodoro", { title: "🍅 番茄钟", body: text });
    } else {
      world.playTool("breakTime");
      world.bubble({ header: "🍅 番茄钟", line: "休息好啦，开始下一个番茄？", tag: "pomodoro", replace: true, urgent: true, sound: "pomodoro",
        buttons: [{ title: "开始", primary: true }, { title: "先不了" }] })
        .then((i) => { if (i === 0) pomodoro.start(); });
      notify.notify("pomodoro", { title: "🍅 番茄钟", body: "休息好啦，开始下一个番茄？" });
    }
  }

  // ---- 隐藏 (the world folds into one line; spec §4.3) ----
  let hideTimer = null;
  function hideFor(ms) {
    state.hiddenUntil = Date.now() + ms;
    if (hideTimer != null) scheduler.clearTimeout(hideTimer);
    hideTimer = scheduler.setTimeout(unhide, ms);
    renderMood(); publishLook(); renderStrip();
  }
  function unhide() {
    if (!state.hiddenUntil) return;
    state.hiddenUntil = 0;
    if (hideTimer != null) scheduler.clearTimeout(hideTimer);
    hideTimer = null;
    renderMood(); publishLook(); renderStrip();
    flushHeld("hidden");
  }
  const worldVisible = () => !state.hiddenUntil && (pip.isOpen() || !document.hidden);

  function renderStrip() {
    const hidden = !!state.hiddenUntil;
    view.worldFrame.classList.toggle("folded", hidden || pip.isOpen());
    if (hidden) {
      setChildren(view.strip, h("span", `${nameOf(myCharacter())}藏起来了 · ${hhmm(state.hiddenUntil)} 自动出来`), h("button.link", { type: "button", onclick: unhide }, "现在出来"));
    } else if (pip.isOpen()) {
      setChildren(view.strip, h("span", `${nameOf(myCharacter())}在置顶小窗里`), h("button.link", { type: "button", onclick: () => pip.close() }, "收回来"));
    }
    view.strip.hidden = !hidden && !pip.isOpen();
  }

  // ---- held partner messages (勿扰 / 专注 / 隐藏) ----
  function holdReason() {
    if (dnd.isOn()) return "dnd";
    if (pomodoro.focusing()) return "focus";
    if (state.hiddenUntil) return "hidden";
    return null;
  }
  function flushHeld(kind) {
    if (!started) return;
    const msgs = state.held[kind];
    state.held[kind] = [];
    if (!msgs.length) return;
    const next = holdReason();
    if (next) { state.held[next].push(...msgs); return; }
    world.card(kind, msgs);
  }

  // ---- look / mood / presence ----
  function applyLook() { if (!started) return;
    const x = store.get("petX", null);
    // 桌宠模式: the pet stands in the middle (the window widens evenly for visits, so it doesn't jump)
    world.setMe({ character: myCharacter(), outfit: outfits.current(), scale: prefs.get().petScale, seat: me, x: petMode ? 0.5 : Number.isFinite(x) ? x : undefined });
  }
  function renderMood() { if (!started) return;
    const d = dnd.status();
    world.setMood({ dnd: d ? { ...d, sign: dnd.sign() } : null, focus: pomodoro.focusing(),
      pomodoroLabel: pomodoro.focusing() ? `🍅 ${pomodoro.minutesLeft()}` : null, hidden: !!state.hiddenUntil });
  }
  function publishLook() { if (!started) return;
    // The world derives its pose (PetPose.derive) from the mood it was given; this only guards the order of updates.
    const pose = state.hiddenUntil ? "hidden" : dnd.isOn() ? "dnd" : pomodoro.focusing() ? "focus" : state.worldPose;
    channel.setLook?.({ outfit: outfits.yielding() ? undefined : outfits.current(), pose });
    channel.setDnd?.(dnd.status());
    channel.setFocus?.(pomodoro.focus());
  }
  setInterval(renderMood, 60_000);   // the 🍅 minutes under the pet

  function applyPrefs({ preview } = {}) {
    const p = prefs.get();
    sound.setPrefs(p.sound);
    applyLook();
    petMode?.fit();
    if (preview && p.sound.on) sound.play("click", { preview: true });
  }

  // ---- title / badge / ui refresh ----
  function renderTitle() { if (!started) return;
    const n = state.unread.size;
    const eye = eyedrops.titleBit();
    document.title = `${n ? `(${n}) ` : ""}噜噜${eye ? " · " + eye : ""}`;
    notify.setBadge(n);
    pip.refresh();
  }
  function refreshUi() { if (!started) return;
    renderTitle();
    tools.render();
    settings.render();
    yieldNote.hidden = !(state.yielding && state.connected && (dnd.isOn() || pomodoro.focusing()));
  }

  function renderPartner() {
    const now = Date.now();
    // Before the first presence read, "还没上线过" would be a false alarm.
    const b = state.partnerKnown ? partnerBadge(state.partner, state.online, now) : { dot: "⏳", text: "看看 TA 在不在…" };
    view.ta.textContent = `${taName()} · ${b.dot} ${b.text}`;
    compose.setPartner(taName(), partnerNote(state.partner, state.online, now));
    compose.setPolicy(intimate());
    weather.set(
      { place: state.mine?.place, avatar: myCharacter() === "lumei" ? "🎀" : "🍊" },
      { place: state.partner?.place, badge: b, avatar: partnerLook().character === "lumei" ? "🎀" : "🍊" });
  }
  setInterval(renderPartner, 60_000);

  // ---- 🍊 menu ----
  function orangeMenu({ anchor, x, y, doc } = {}) {
    const items = () => {
      const s = reminders.settings();
      const b = state.partnerKnown ? partnerBadge(state.partner, state.online, Date.now()) : { dot: "⏳", text: "看看 TA 在不在…" };
      const ps = pomodoro.state();
      const p = prefs.get();
      const dndOn = dnd.isOn();
      const yieldHint = outfits.yielding() ? "家里的 Mac 在线，造型跟着 Mac" : null;
      return [
        { note: `${taName()}：${b.dot} ${b.text}` },
        dndOn ? { note: dnd.statusLine() } : null,
        pomodoro.state().phase !== "idle" ? { note: `🍅 ${pomodoro.stateLine()}` } : null,
        { separator: true },
        { label: "传话…", onClick: () => showPanel("compose", { compact: true }) },
        petMode ? { label: "打开面板…", onClick: () => showPanel(tab) } : null,
        { label: "去找TA 🏃", onClick: () => act("visit"), disabled: !state.online },
        { label: "偷看 TA 👀", onClick: () => act("peek") },
        { separator: true },
        { label: dndOn ? "勿扰模式（开）" : "勿扰模式", submenu: [
          dndOn ? { label: dnd.offTitle(), onClick: () => dnd.turnOff() } : null,
          { header: "心情" },
          ...dnd.moods.map((m) => ({ label: m.title, checked: dnd.mood() === m.id, radio: true, keepOpen: true, onClick: () => dnd.setMood(m.id) })),
          { header: "开启" },
          ...dnd.durations.map((d) => ({ label: d.title, onClick: () => dnd.turnOn(d.id) })),
        ] },
        { label: ps.phase === "idle" ? "番茄钟" : `番茄钟（${ps.phase === "focus" ? "专注中" : "休息中"}）`, submenu: [
          { note: pomodoro.stateLine() },
          { label: ps.phase === "focus" ? "重新开始专注" : "开始专注", onClick: () => pomodoro.start() },
          ps.phase !== "idle" ? { label: pomodoro.isPaused() ? "继续" : "暂停", onClick: () => pomodoro.pauseResume() } : null,
          ps.phase === "shortBreak" || ps.phase === "longBreak" ? { label: "跳过休息", onClick: () => pomodoro.skipBreak() } : null,
          ps.phase !== "idle" ? { label: "结束", onClick: () => pomodoro.stop() } : null,
        ] },
        { label: "提醒", submenu: [
          { label: "喝水提醒 💧", checked: s.waterEnabled, keepOpen: true, onClick: () => reminders.update({ ...s, waterEnabled: !s.waterEnabled }) },
          { label: "站立提醒 🧍", checked: s.standEnabled, keepOpen: true, onClick: () => reminders.update({ ...s, standEnabled: !s.standEnabled }) },
          { label: eyedrops.settings().enabled ? `眼药水 ${eyedrops.titleBit()}` : "眼药水 👁️", checked: eyedrops.settings().enabled, onClick: () => showPanel("tools") },
          { note: `今天喝了 ${reminders.cups()} 杯` },
        ] },
        { separator: true },
        { label: "换个造型", disabled: outfits.yielding(), title: yieldHint, onClick: () => outfits.change() },
        { label: "换回上一个", disabled: !outfits.canGoBack(), onClick: () => outfits.back() },
        { label: "选择造型", disabled: outfits.yielding(), hint: outfits.label(), submenu: outfits.list().map((o) => ({ label: o.label, checked: o.id === outfits.current(), radio: true, disabled: !o.enabled, onClick: () => outfits.choose(o.id) })) },
        { label: "固定这套造型", checked: outfits.isPinned(), disabled: outfits.yielding(), onClick: () => outfits.togglePin() },
        yieldHint ? { note: yieldHint } : null,
        { separator: true },
        { label: "大小", submenu: SIZES.map((z) => ({ label: z.label, checked: Math.abs(p.petScale - z.value) < 0.01, radio: true, keepOpen: true, onClick: () => { prefs.set({ petScale: z.value }); applyPrefs(); } })) },
        { label: "声音", hint: p.sound.on ? "开" : "关", submenu: [
          { label: "开", checked: p.sound.on, radio: true, keepOpen: true, onClick: () => { prefs.set({ sound: { on: true } }); applyPrefs(); settings.render(); } },
          { label: "关", checked: !p.sound.on, radio: true, keepOpen: true, onClick: () => { prefs.set({ sound: { on: false } }); applyPrefs(); settings.render(); } },
          { header: "音量" },
          ...VOLUMES.map((v) => ({ label: v.label, checked: p.sound.volume === v.value, radio: true, keepOpen: true, onClick: () => { prefs.set({ sound: { volume: v.value } }); applyPrefs({ preview: true }); } })),
          { label: "背景音乐", checked: p.sound.bgm, keepOpen: true, onClick: () => { prefs.set({ sound: { bgm: !p.sound.bgm } }); applyPrefs(); } },
        ] },
        state.hiddenUntil ? { label: `显示${nameOf(myCharacter())}（${hhmm(state.hiddenUntil)} 自动出现）`, onClick: unhide }
          : { label: "隐藏", submenu: HIDE_FOR.map((x) => ({ label: x.label, onClick: () => hideFor(x.ms) })) },
        pipAvailable ? { label: pip.isOpen() ? "收回置顶小窗" : "置顶小窗 📌", onClick: togglePip } : null,
        canPopup ? { label: "打开桌宠小窗 🪟", onClick: () => $("#popup-btn").click() } : null,
        isPetPopup() ? { label: "收回到网页", onClick: backToTab } : null,
        { separator: true },
        { label: "设置…", onClick: () => showPanel("settings") },
        !isPhone() ? { label: "极简模式（适合上班）", onClick: () => switchMode(true) } : null,
        { label: todoCount ? `待设置（${todoCount}）` : "待设置", onClick: () => { if (petMode) showPanel("settings"); openTodos(todoCtx, setTodoCount); } },
        { label: "更新日志…", onClick: () => { if (petMode) showPanel("settings"); openChangelog(version); } },
      ];
    };
    const m = openMenu(items, { anchor, x, y, doc: doc || pip.doc() || document });
    menuRefresh = m.refresh;
  }
  let menuRefresh = null;
  view.worldFrame.addEventListener("contextmenu", (e) => { if (!e.defaultPrevented) { e.preventDefault(); orangeMenu({ x: e.clientX, y: e.clientY }); } });

  // ---- channel events ----
  const on = (type, fn) => channel.addEventListener(type, (e) => { try { fn(e.detail || {}); } catch (err) { console.error(err); } });
  on("connection", ({ state: s, reason }) => {
    const line = connectionLine(s, reason);
    view.conn.textContent = s === "connected" ? "" : line.text;
    view.conn.title = line.text;
    view.conn.dataset.tone = line.tone;
    state.connected = s === "connected" || s === "polling";
    const elsewhere = s === "elsewhere";
    // The pet popup waits a moment for the tab that opened it to step aside; it keeps showing the pet meanwhile.
    view.blocked.hidden = !elsewhere || isPetPopup();
    view.main.hidden = elsewhere && !isPetPopup();
    refreshUi();
  });
  on("mySeat", ({ presence, yielding, identity }) => {
    state.mine = presence || null;
    state.yielding = !!yielding;
    if (identity) state.identity = identity;
    outfits.setSeat({ character: myCharacter(), yielding: state.yielding, outfit: state.mine?.outfit ?? state.identity?.outfit });
    applyLook();
    publishLook();
    renderPartner();
    refreshUi();
  });
  on("partner", ({ presence, online }) => {
    state.partnerKnown = true;
    state.partner = presence || null;
    state.online = !!online;
    if (state.wasOnline === false && state.online) world.cheer();
    state.wasOnline = state.online;
    renderPartner();
  });
  on("backlog", ({ msgs }) => {
    const all = msgs || [];
    history.add(all);
    const theirs = all.filter((m) => m.from !== me);
    for (const k of store.get("answeredReminds", []) || []) away.resolved(k);
    for (const m of theirs) {
      if (m.kind === "remind" && !m.ackOf) pendingReminds.set(msgKey(m), m);
      state.unread.add(msgKey(m));
    }
    if (theirs.length) away.add(theirs);
    renderTitle();
  });
  on("folded", ({ count }) => { if (count > 0) away.fold(count); });
  on("parked", () => toast("有一条消息没发出去", 6000));
  on("own", ({ msg }) => {
    if (!msg) return;
    history.add([msg]);
    if (msg.kind === "sticker" && msg.stickerId) compose.countSent(msg.stickerId, msg.id);
    if (decodeReply(msg) && typeof msg.ackOf === "string") {
      pendingReminds.delete(msg.ackOf);
      away.resolved(msg.ackOf);
      world.closeBubble(msg.ackOf);
    }
  });
  on("message", ({ msg, live }) => {
    if (!msg || msg.from === me || live === false) return;
    history.add([msg]);
    const key = msgKey(msg);
    if (msg.kind === "remind" && !msg.ackOf) pendingReminds.set(key, msg);
    state.unread.add(key);
    renderTitle();
    const hold = holdReason();
    if (hold) { state.held[hold].push(msg); return; }
    world.incoming(msg, { live: true });
    notifyIncoming(msg);
  });

  function notifyIncoming(msg) {
    if (!document.hidden || pip.isOpen()) return;    // the pet is on screen already
    const name = taName();
    const d = describe(msg);
    const key = msgKey(msg);
    if (decodeReply(msg)) return notify.notify("message", { title: name, body: d.line, key });
    if (d.remind) return notify.notify("partner-remind", { title: `${name}说：`, body: d.line, key, remind: d.remind });
    let body = d.line;
    if (msg.kind === "sticker") body = `［表情］${stickerById(msg.stickerId)?.label ?? ""}`;
    if (body.length > 80) body = body.slice(0, 79) + "…";
    notify.notify("message", { title: msg.kind === "text" ? `${name}说：` : name, body, key });
  }

  // ---- notification buttons ----
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
      world.closeBubble("own-" + data.remind);
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

  // ---- go ----
  started = true;
  applyLook();
  renderMood();
  renderPartner();
  renderStrip();
  placeInsets();
  refreshUi();
  countTodos();
  document.addEventListener("visibilitychange", () => { if (!document.hidden) countTodos(); });
  Promise.resolve(channel.start()).catch((e) => {
    console.error(e);
    view.conn.textContent = "未连接：" + (e?.message || "出错了");
    view.conn.dataset.tone = "bad";
  });
  const pendingAction = await notify.takePending();
  if (pendingAction) handleAction(pendingAction);
  whatsNew(version, (seen) => {
    if (!petMode) return openChangelog(version, seen);
    // 桌宠模式: no room for a sheet here, and a new window needs a click — the pet says it instead
    world.bubble({ header: "🆕 网页版更新了", line: "看看这次改了什么？", tag: "whats-new", sound: null,
      buttons: [{ title: "看看", primary: true }, { title: "知道了" }] })
      .then((i) => { if (i === 0) { showPanel("settings"); openChangelog(version, seen); } });
  });
  const looks = () => [{ character: myCharacter(), outfit: outfits.current() }, partnerLook()];
  setTimeout(() => { if (navigator.serviceWorker?.controller) prefetch(prefetchList(looks()), { background: true }); }, 8000);

  if (DEV) {
    window.__lulu = { world, compose, pip, away, reminders, channel, eyedrops, pomodoro, dnd, outfits, history, selectTab, orangeMenu, hideFor, state, closeMenu, menu: () => menuRefresh,
      backdrop, petMode, showPanel };
    if (DEV === "pip") {
      document.head.append(h("link", { rel: "stylesheet", href: "css/pip.css" }));
      pip.openSim($("#pip-sim-host"));
    }
  }
  return new Promise(() => {});   // keep the leader lock
}

main();
