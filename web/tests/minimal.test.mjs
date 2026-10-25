import { test } from "node:test";
import assert from "node:assert/strict";
import * as M from "../js/ui/minimal/logic.js";

test("minimal: prefs decode with defaults (off, chime on, thumbs / hideContent / discreet off)", () => {
  assert.deepEqual(M.decodePrefs(null), { on: false, chime: true, thumbs: false, hideContent: false, discreet: false, chosen: false });
  assert.deepEqual(M.decodePrefs([]), M.decodePrefs(null));
  const p = M.decodePrefs({ on: true, chime: false, thumbs: "yes", discreet: true });
  assert.equal(p.on, true);
  assert.equal(p.chime, false);
  assert.equal(p.thumbs, false, "non-boolean = default");
  assert.equal(p.discreet, true);
  assert.equal(p.chosen, true);
  assert.equal(M.decodePrefs({ chime: false }).chosen, false, "only `on` counts as a choice");
  assert.equal(M.decodePrefs({ on: false }).chosen, true);
});

test("minimal: phones never run it; desktops are asked once", () => {
  const on = M.decodePrefs({ on: true });
  assert.equal(M.useMinimal(on, { phone: false }), true);
  assert.equal(M.useMinimal(on, { phone: true }), false);
  assert.equal(M.useMinimal(M.decodePrefs(null), { phone: false }), false);
  const fresh = M.decodePrefs(null);
  assert.equal(M.shouldOffer(fresh, { phone: false, fine: true, popup: false }), true);
  assert.equal(M.shouldOffer(fresh, { phone: true, fine: false, popup: false }), false);
  assert.equal(M.shouldOffer(fresh, { phone: false, fine: false, popup: false }), false, "touch tablet: not asked");
  assert.equal(M.shouldOffer(fresh, { phone: false, fine: true, popup: true }), false, "never in the pet popup");
  assert.equal(M.shouldOffer(M.decodePrefs({ on: false }), { phone: false, fine: true, popup: false }), false, "chosen already");
});

test("minimal: title — names / eye-drop bit, or neutral 「提醒」", () => {
  assert.equal(M.titleText({}), "噜噜");
  assert.equal(M.titleText({ unread: 2, eye: "👁️ 1/4" }), "(2) 噜噜 · 👁️ 1/4");
  assert.equal(M.titleText({ unread: 0, eye: "👁️ 该滴了", discreet: true }), "提醒");
  assert.equal(M.titleText({ unread: 3, discreet: true }), "(3) 提醒");
  assert.equal(M.shownName("噜妹", false), "噜妹");
  assert.equal(M.shownName("噜妹", true), "TA");
});

test("minimal: partner notifications honour 不显示内容 and 低调标题", () => {
  assert.deepEqual(M.partnerNotice("message", { name: "噜妹", line: "下班一起吃饭", isText: true }), { title: "噜妹说：", body: "下班一起吃饭" });
  assert.deepEqual(M.partnerNotice("message", { name: "噜妹", line: "［表情］么么哒" }), { title: "噜妹", body: "［表情］么么哒" });
  assert.deepEqual(M.partnerNotice("message", { name: "噜妹", line: "secret", isText: true }, { hideContent: true }), { title: "新消息", body: "噜妹 发来一条消息" });
  assert.deepEqual(M.partnerNotice("message", { name: "噜妹", line: "secret", isText: true }, { hideContent: true, discreet: true }), { title: "新消息", body: "TA 发来一条消息" });
  assert.deepEqual(M.partnerNotice("partner-remind", { name: "噜妹", line: "噜妹叫你喝水啦 💧" }, { hideContent: true }), { title: "提醒", body: "噜妹 发来一个提醒" });
  assert.deepEqual(M.partnerNotice("partner-remind", { name: "噜妹", line: "TA叫你喝水啦 💧" }, { discreet: true }), { title: "TA说：", body: "TA叫你喝水啦 💧" });
  const long = M.partnerNotice("message", { name: "x", line: "字".repeat(120), isText: true });
  assert.equal(long.body.length, 80);
  assert.ok(long.body.endsWith("…"));
});

test("minimal: clock / sticker text", () => {
  assert.equal(M.clock(0), "00:00");
  assert.equal(M.clock(59.2), "01:00");
  assert.equal(M.clock(25 * 60), "25:00");
  assert.equal(M.clock(3725), "1:02:05");
  assert.equal(M.clock(null), "--:--");
  assert.equal(M.clock(-1), "--:--");
  assert.equal(M.stickerText("么么哒"), "［表情］么么哒");
  assert.equal(M.stickerText(""), "［表情］");
});

test("minimal: read only while looking; notify unless looking or held", () => {
  const keys = new Set(["a", "b"]).keys();
  assert.deepEqual(M.readable(keys, { visible: true, focused: true }), ["a", "b"]);
  assert.deepEqual(M.readable(["a"], { visible: true, focused: false }), []);
  assert.deepEqual(M.readable(["a"], { visible: false, focused: true }), []);
  assert.equal(M.notifyPartner({ visible: true, focused: true, held: false }), false);
  assert.equal(M.notifyPartner({ visible: true, focused: false, held: false }), true, "window behind others");
  assert.equal(M.notifyPartner({ visible: false, focused: false, held: false }), true);
  assert.equal(M.notifyPartner({ visible: false, focused: false, held: true }), false, "勿扰 / 专注 hold TA's messages");
});

test("minimal: the 小工具 strip", () => {
  assert.deepEqual(M.toolBits({}), []);
  const bits = M.toolBits({
    water: { on: true, phase: "counting", left: 61 },
    stand: { on: true, phase: "showing" },
    eye: { on: true, done: 1, total: 4, showing: false },
    pomo: { phase: "focus", left: 24 * 60 + 5, paused: false },
  });
  assert.deepEqual(bits.map((b) => b.text), ["🍅 专注 24:05", "💧 2 分", "🧍 该动动了", "👁️ 1/4"]);
  assert.deepEqual(bits.map((b) => !!b.due), [false, false, true, false]);
  assert.deepEqual(M.toolBits({ water: { on: false, phase: "counting", left: 10 }, pomo: { phase: "idle" } }), []);
  assert.equal(M.toolBits({ water: { on: true, phase: "away" } })[0].text, "💧 暂停");
  assert.equal(M.toolBits({ pomo: { phase: "shortBreak", left: 300, paused: true } })[0].text, "🍅 休息 05:00 暂停");
  assert.equal(M.toolBits({ eye: { on: true, done: 2, total: 4, showing: true } })[0].text, "👁️ 该滴了");
});
