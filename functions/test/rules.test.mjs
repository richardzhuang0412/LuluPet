import { test } from "node:test";
import assert from "node:assert/strict";
import {
  clipBody, decodeDevices, decodePrefs, decodeSub, decodeSubs, isQuiet, keyMatches, messagePush, messageTargets, otherSeat, pickTz,
  shouldSend, whereIs,
} from "../src/rules.js";
import { sub, VAPID } from "./helpers.mjs";

const NOW = 1_791_900_000_000;
const msg = (o) => ({ from: "lumei", kind: "text", ts: NOW - 1000, v: 1, character: "lumei", ...o });

test("payloads: titles like the Mac, short bodies, no pair code / URL", () => {
  const t = messagePush("-Nabc", msg({ text: "下班啦" }), NOW);
  assert.deepEqual(t, { category: "messages", ttl: 21600, urgency: "normal",
    payload: { v: 1, key: "-Nabc", tag: "msg--Nabc", kind: "message", title: "噜妹说：", body: "下班啦" } });
  assert.equal(messagePush("k", msg({ from: "lulu", character: "lulu", text: "x" }), NOW).payload.title, "噜噜说：");
  // character wins over the seat (friend mode: both may be 噜噜)
  assert.equal(messagePush("k", msg({ from: "lulu", character: "lumei", text: "x" }), NOW).payload.title, "噜妹说：");

  const s = messagePush("k", msg({ kind: "sticker", stickerId: "lumei_heart", text: "[表情] 比心" }), NOW).payload;
  assert.equal(s.body, "［表情］比心");
  assert.equal(messagePush("k", msg({ kind: "sticker", stickerId: "x" }), NOW).payload.body, "［表情］");
  assert.equal(messagePush("k", msg({ kind: "poke" }), NOW).payload.body, "噜妹给你发了一颗爱心 ❤️");
  assert.equal(messagePush("k", msg({ kind: "visit", trip: "deliver" }), NOW).payload.body, "噜妹跑来找你玩啦");

  const r = messagePush("r1", msg({ kind: "remind", remind: "water" }), NOW);
  assert.equal(r.category, "reminders");
  assert.equal(r.urgency, "high");
  assert.deepEqual(r.payload, { v: 1, key: "r1", tag: "msg-r1", kind: "partner-remind", title: "噜妹说：", body: "噜妹叫你喝水啦 💧", remind: "water" });
  assert.equal(messagePush("r2", msg({ kind: "remind", remind: "stand" }), NOW).payload.body, "噜妹叫你起来动动 🧍");

  for (const p of [t.payload, s, r.payload]) assert.doesNotMatch(JSON.stringify(p), /firebase|pairs|https?:/i);
});

test("acks: only replies to my reminders, short; other kinds and stale / malformed messages are skipped", () => {
  const now = messagePush("a", msg({ kind: "remind", remind: "water", ackOf: "r1", answer: "now" }), NOW);
  assert.equal(now.category, "reminders");
  assert.equal(now.payload.kind, "message");
  assert.equal(now.payload.title, "噜妹");
  assert.equal(now.payload.body, "TA 说马上喝 💧");
  assert.equal(messagePush("a", msg({ kind: "remind", remind: "water.later", ackOf: "r1", answer: "later" }), NOW).payload.body, "TA 说等会儿再喝 ⏰");
  assert.equal(messagePush("a", msg({ kind: "remind", remind: "nap", ackOf: "r1" }), NOW), null);
  assert.equal(messagePush("a", msg({ kind: "remind", remind: "nap" }), NOW), null);
  assert.equal(messagePush("a", msg({ kind: "hug" }), NOW), null);              // a newer kind: no push
  assert.equal(messagePush("a", msg({ text: "" }), NOW), null);
  assert.equal(messagePush("a", msg({ ts: NOW - 7 * 3_600_000 }), NOW), null);
  assert.equal(messagePush("a", msg({ from: "x" }), NOW), null);
  assert.equal(messagePush("a", { kind: "text" }, NOW), null);
});

test("clipBody: ≤ 80 UTF-16 units, emoji kept whole, whitespace folded", () => {
  assert.equal(clipBody("a\n\n b"), "a b");
  const long = "好".repeat(100);
  assert.equal(clipBody(long).length, 80);
  assert.ok(clipBody(long).endsWith("…"));
  const emoji = "x".repeat(78) + "👩‍👩‍👧";
  assert.equal(clipBody(emoji), "x".repeat(78) + "…");
  assert.equal(messagePush("k", msg({ text: long }), NOW).payload.body.length, 80);
});

test("recipient seat", () => {
  assert.equal(otherSeat("lulu"), "lumei");
  assert.equal(otherSeat("lumei"), "lulu");
  assert.equal(otherSeat("web"), null);
});

test("prefs and subscription decoding", () => {
  assert.deepEqual(decodePrefs(undefined), { messages: true, reminders: true, eyedrops: false, onlyWhenAway: true, dnd: "silent" });
  assert.deepEqual(decodePrefs({ messages: false, eyedrops: true, onlyWhenAway: false, dnd: "skip" }),
    { messages: false, reminders: true, eyedrops: true, onlyWhenAway: false, dnd: "skip" });
  assert.equal(decodeSub("a", { ...sub(), endpoint: "http://insecure" }), null);
  assert.equal(decodeSub("a", { ...sub(), keys: null }), null);
  assert.equal(decodeSub("a", "x"), null);
  assert.deepEqual(decodeSubs({ b: sub(), a: sub({ device: "web-2" }), c: 7 }).map((s) => s.id), ["a", "b"]);
  assert.equal(keyMatches(decodeSub("a", sub()), VAPID.publicKey), true);
  assert.equal(keyMatches(decodeSub("a", sub({ key: "OLDKEYOLDKEYOLD1" })), VAPID.publicKey), false);
  assert.equal(keyMatches(decodeSub("a", sub({ key: undefined })), VAPID.publicKey), true);
});

test("presence: away / here / elsewhere and the onlyWhenAway pref", () => {
  const phone = decodeSub("p", sub());
  const laptop = decodeSub("l", sub({ device: "web-laptop", phone: false }));
  const fresh = NOW - 30_000, stale = NOW - 76_000;
  const pres = (device, lastSeen = fresh) => ({ lastSeen, device });
  // nobody online
  assert.equal(whereIs(phone, null, NOW), "away");
  assert.equal(whereIs(phone, pres("mac-1", stale), NOW), "away");
  assert.equal(whereIs(phone, pres("mac-1", 0), NOW), "away");
  // the Mac (or another web page) is online but has no activity record (0.18): no longer suppresses
  assert.equal(whereIs(phone, pres("mac-1"), NOW), "away");
  assert.equal(shouldSend(phone, pres("mac-1"), NOW), true);
  // this browser holds the seat
  assert.equal(whereIs(laptop, pres("web-laptop"), NOW), "here");
  assert.equal(shouldSend({ ...laptop, prefs: { ...laptop.prefs, onlyWhenAway: false } }, pres("web-laptop"), NOW), false);
  assert.equal(whereIs(phone, pres("web-phone"), NOW), "here");
  // … a phone page in the background (frozen on iOS) counts as away; a hidden desktop tab still runs and shows it
  assert.equal(whereIs({ ...phone, vis: { hidden: true, at: NOW - 5000 } }, pres("web-phone"), NOW), "away");
  assert.equal(whereIs({ ...laptop, vis: { hidden: true, at: NOW - 5000 } }, pres("web-laptop"), NOW), "here");
});

test("routing matrix: whichever device I'm actually using gets it (spec §2.1)", () => {
  const phone = decodeSub("p", sub());                                            // iPhone home-screen app, device web-phone
  const laptop = decodeSub("l", sub({ device: "web-laptop", phone: false }));    // work laptop browser
  const anyway = (s) => ({ ...s, prefs: { ...s.prefs, onlyWhenAway: false } });  // 「不管在不在电脑前」
  const macOnline = { lastSeen: NOW - 20_000, device: "mac-1" };                 // the home Mac holds the seat
  const rec = (kind, activeAgo, atAgo, vis) => ({ kind, activeAt: activeAgo == null ? 0 : NOW - activeAgo, at: NOW - atAgo, ...(vis ? { vis } : {}) });
  const macIdle = rec("mac", 3_600_000, 20_000);                 // awake, charging, nobody touching it for an hour
  const macUsed = rec("mac", 40_000, 20_000);
  const phonePocket = rec("phone", 1_200_000, 1_200_000, "hidden");
  const phoneOpen = rec("phone", 10_000, 10_000, "visible");
  const laptopUsed = rec("web", 30_000, 30_000, "visible");
  const laptopHiddenUsed = rec("web", 30_000, 30_000, "hidden");   // tab in the background, IdleDetector says active
  const route = (s, presence, devices) => {
    const ds = decodeDevices(devices, NOW);
    return [whereIs(s, presence, NOW, ds), shouldSend(s, presence, NOW, ds)];
  };

  // home Mac awake but idle + phone in the pocket → the phone is pushed
  assert.deepEqual(route(phone, macOnline, { "mac-1": macIdle, "web-phone": phonePocket }), ["away", true]);
  // the home Mac actively used → the Mac shows it; the phone only with 「不管在不在电脑前」
  assert.deepEqual(route(phone, macOnline, { "mac-1": macUsed, "web-phone": phonePocket }), ["elsewhere", false]);
  assert.deepEqual(route(anyway(phone), macOnline, { "mac-1": macUsed, "web-phone": phonePocket }), ["elsewhere", true]);
  // work laptop actively used → no phone push; the laptop's open page shows it itself
  const atWork = { "mac-1": macIdle, "web-laptop": laptopUsed, "web-phone": phonePocket };
  assert.deepEqual(route(phone, macOnline, atWork), ["elsewhere", false]);
  assert.deepEqual(route(laptop, macOnline, atWork), ["here", false]);
  assert.deepEqual(route(anyway(laptop), macOnline, atWork), ["here", false]);
  // … laptop tab hidden while I work in other apps: its own subscription is pushed (same tag as the page's own
  // notification, so at most a harmless duplicate); the phone still isn't
  const atWorkHidden = { ...atWork, "web-laptop": laptopHiddenUsed };
  assert.deepEqual(route(laptop, macOnline, atWorkHidden), ["away", true]);
  assert.deepEqual(route(phone, macOnline, atWorkHidden), ["elsewhere", false]);
  // phone app open on screen → no push to it (it shows in-app), even with 「不管在不在电脑前」
  assert.deepEqual(route(phone, macOnline, { "mac-1": macIdle, "web-phone": phoneOpen }), ["here", false]);
  assert.deepEqual(route(anyway(phone), null, { "web-phone": phoneOpen }), ["here", false]);
  // … but the laptop's subscription isn't held back by the phone being used (it is: the phone is another device)
  assert.deepEqual(route(laptop, macOnline, { "web-phone": phoneOpen }), ["elsewhere", false]);
  // a "visible" record not written for 2 minutes isn't proof the page is open any more
  assert.deepEqual(route(phone, null, { "web-phone": rec("phone", 120_000, 120_000, "visible") }), ["away", true]);
  // nothing active (all asleep / nobody online) → push
  assert.deepEqual(route(phone, null, {}), ["away", true]);
  assert.deepEqual(route(laptop, null, { "mac-1": macIdle, "web-phone": phonePocket }), ["away", true]);
  // old Mac (0.18) without records, online → push (extra rather than missed)
  assert.deepEqual(route(phone, macOnline, null), ["away", true]);
  // the phone page holds the seat presence but its record (newer than sub.vis) says hidden → push
  const phonePres = { lastSeen: NOW - 20_000, device: "web-phone" };
  assert.deepEqual(route({ ...phone, vis: { hidden: false, at: NOW - 60_000 } }, phonePres, { "web-phone": rec("phone", 30_000, 5_000, "hidden") }), ["away", true]);
  assert.deepEqual(route(phone, phonePres, {}), ["here", false]);
  // records older than 7 days are ignored; a clock far in the future isn't believed
  assert.deepEqual(route(phone, null, { "mac-1": { kind: "mac", activeAt: NOW - 10_000, at: NOW - 8 * 86_400_000 } }), ["away", true]);
  assert.deepEqual(route(phone, null, { "mac-1": rec("mac", -3_600_000, -3_600_000) }), ["away", true]);
  // a little clock skew still counts
  assert.deepEqual(route(phone, null, { "mac-1": rec("mac", -30_000, -30_000) }), ["elsewhere", false]);
  // malformed records are ignored
  assert.deepEqual(route(phone, null, { "mac-1": "x", "web-2": { kind: "web", activeAt: NOW } }), ["away", true]);
});

test("messageTargets: categories, 勿扰 silent / skip, presence", () => {
  const built = messagePush("k", msg({ text: "hi" }), NOW);
  const remind = messagePush("r", msg({ kind: "remind", remind: "water" }), NOW);
  const subsNode = {
    a: sub({ endpoint: "https://p/a" }),
    b: sub({ endpoint: "https://p/b", prefs: { messages: false, reminders: true } }),
    c: sub({ endpoint: "https://p/c", prefs: { dnd: "skip" } }),
    d: sub({ endpoint: "https://p/d", key: "OLDKEYOLDKEYOLD1" }),
  };
  const ids = (t) => t.map((x) => x.sub.id + (x.silent ? ":silent" : ""));
  assert.deepEqual(ids(messageTargets({ built, subsNode, presenceRaw: null, now: NOW, publicKey: VAPID.publicKey })), ["a", "c"]);
  assert.deepEqual(ids(messageTargets({ built: remind, subsNode, presenceRaw: null, now: NOW, publicKey: VAPID.publicKey })), ["a", "b", "c"]);
  const dnd = { lastSeen: 0, dnd: { mood: "busy", until: 0 } };
  assert.equal(isQuiet(dnd, NOW), true);
  assert.deepEqual(ids(messageTargets({ built, subsNode, presenceRaw: dnd, now: NOW, publicKey: VAPID.publicKey })), ["a:silent"]);
  const focus = { lastSeen: 0, focus: { phase: "focus", until: NOW + 60_000 } };
  assert.deepEqual(ids(messageTargets({ built, subsNode, presenceRaw: focus, now: NOW, publicKey: VAPID.publicKey })), ["a:silent"]);
  const expired = { lastSeen: 0, dnd: { mood: "busy", until: NOW - 1 } };
  assert.deepEqual(ids(messageTargets({ built, subsNode, presenceRaw: expired, now: NOW, publicKey: VAPID.publicKey })), ["a", "c"]);
  // the Mac online but idle no longer suppresses; the Mac actively used does
  const macOnline = { lastSeen: NOW - 10_000, device: "mac-1" };
  assert.deepEqual(ids(messageTargets({ built, subsNode, presenceRaw: macOnline, now: NOW, publicKey: VAPID.publicKey })), ["a", "c"]);
  const macIdle = { "mac-1": { kind: "mac", activeAt: NOW - 3_600_000, at: NOW - 20_000 } };
  assert.deepEqual(ids(messageTargets({ built, subsNode, presenceRaw: macOnline, devicesRaw: macIdle, now: NOW, publicKey: VAPID.publicKey })), ["a", "c"]);
  const macUsed = { "mac-1": { kind: "mac", activeAt: NOW - 30_000, at: NOW - 20_000 } };
  assert.deepEqual(ids(messageTargets({ built, subsNode, presenceRaw: macOnline, devicesRaw: macUsed, now: NOW, publicKey: VAPID.publicKey })), []);
  assert.deepEqual(messageTargets({ built, subsNode: null, presenceRaw: null, now: NOW, publicKey: VAPID.publicKey }), []);
});

test("eye-drop time zone: subscription → settings.tz → the seat's city → none", () => {
  const s = [decodeSub("a", sub({ tz: "Not/AZone" })), decodeSub("b", sub({ tz: "Asia/Shanghai" }))];
  assert.equal(pickTz(s, {}, null), "Asia/Shanghai");
  const none = [decodeSub("a", sub({ tz: "" }))];
  assert.equal(pickTz(none, { tz: "Europe/Paris" }, null), "Europe/Paris");
  assert.equal(pickTz(none, {}, { place: { timezone: "America/New_York" } }), "America/New_York");
  assert.equal(pickTz(none, {}, {}), null);
});
