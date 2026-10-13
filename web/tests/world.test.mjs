// W5 world: the parts that are not DOM (manifest adapter, bubble queue, timers, sounds, rules adapter, size rules).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { createCatalog } from "../js/ui/world/catalog.js";
import { BubbleQueue, wantsAck } from "../js/ui/world/bubbles.js";
import { createTimers } from "../js/ui/world/timers.js";
import { createSound, toneFor, TONES, ALWAYS_EVENTS } from "../js/ui/world/sound.js";
import { sceneLook } from "../js/ui/world/think.js";
import { rubberBand, normalizeScale, petHeightFor, cardTitle, timeOfDay } from "../js/ui/world/world.js";
import * as R from "../js/ui/world/rules.js";

const webRoot = fileURLToPath(new URL("..", import.meta.url));
const manifest = JSON.parse(readFileSync(join(webRoot, "assets/manifest.json"), "utf8"));
const cat = createCatalog(manifest, "/assets/");
const seq = (...xs) => { let i = 0; return (n) => xs[i++ % xs.length] % n; };

test("catalog: outfits, named clips, weather, couples, reactions, tool pools from manifest v2", () => {
  assert.equal(cat.outfitOf("lulu", "nope"), manifest.characters.lulu.order[0]);
  assert.equal(cat.outfitOf("lumei", "../x"), manifest.characters.lumei.order[0]);
  const o = cat.outfit("lulu", "classic");
  assert.ok(o.idle && o.idleHeight > 0);
  if (manifest.version >= 2) {
    assert.equal(o.fidgets.length, manifest.characters.lulu.outfits.classic.fidgets.length);
    for (const name of manifest.characters.lulu.outfits.classic.stay) assert.ok(o.has(name), name);
    assert.ok(!o.has("no_such_clip"));
    assert.equal(o.named("lulu_comein_01")?.sound, "lulu_comein");
    assert.ok(cat.weather("lulu", "rain").length > 0);
    assert.deepEqual(cat.weather("lulu", "snow").map((x) => x.name), cat.weather("lulu", "snow").length ? cat.weather("lulu", "snow").map((x) => x.name) : cat.weather("lulu", "cold").map((x) => x.name));
    assert.equal(cat.couple("hug").intimate, true);
    assert.equal(cat.couple("angry").luluOnLeft, false);
    assert.equal(cat.couple("../hug"), null);
    assert.deepEqual(cat.toolPool("focus", "lulu"), ["tool_F01"]);
    assert.deepEqual(cat.toolPool("eyedrops", "lumei"), []);
    const r = R.reactionFor(cat.reactions, "sticker", "missyou");
    assert.ok(r.couples.includes("hug"));
    assert.deepEqual(R.visitorClips(r, "lumei"), ["lumei_more_07"]);
  }
});

test("catalog: manifest v1 shape still works (no couples / weather / named)", () => {
  const v1 = { version: 1, clips: { a: { file: "a.webp", w: 10, h: 20, cols: 1, frames: 1, src: [10, 20] } },
    characters: { lulu: { order: ["classic"], outfits: { classic: { actions: { idle: "a" }, fidgets: ["a", "missing"] } } } } };
  const c = createCatalog(v1, "");
  const o = c.outfit("lumei");
  assert.equal(o.character, "lulu");
  assert.equal(o.fidgets.length, 1);
  assert.deepEqual(c.weather("lulu", "rain"), []);
  assert.equal(c.couple("hug"), null);
  assert.equal(c.toolPool("focus", "lulu"), null);
});

test("bubble queue: one at a time, cards first, replace / remove by tag", () => {
  const q = new BubbleQueue();
  assert.equal(q.enqueue({ id: 1 }), true);
  q.enqueue({ id: 2 });
  q.enqueue({ id: 3, card: {} });
  q.enqueue({ id: 4, card: {} });
  assert.deepEqual(q.waiting.map((x) => x.id), [3, 4, 2]);
  assert.equal(q.acknowledge().id, 1);
  assert.equal(q.current.id, 3);
  q.enqueue({ id: 5, tag: "eye" });
  assert.equal(q.replace("eye", { id: 6, tag: "eye" }), "waiting");
  assert.equal(q.replace("nope", {}), null);
  assert.equal(q.remove("eye"), "waiting");
  assert.equal(q.count, 3);
  assert.equal(wantsAck({ text: "x" }), true);
  assert.equal(wantsAck({ text: "x", autoHide: 6000 }), false);
  assert.equal(wantsAck({ text: "x", buttons: [{ title: "a" }] }), false);
  assert.equal(wantsAck({ card: {} }), false);
});

test("bubble queue: my own reminders (urgent) go before TA's bubbles, which come back after", () => {
  const q = new BubbleQueue();
  q.enqueue({ id: "ta1" });
  q.enqueue({ id: "ta2" });
  assert.equal(q.preempt({ id: "eye", urgent: true }), true);
  assert.equal(q.current.id, "eye");
  assert.equal(q.preempt({ id: "water", urgent: true }), false);   // behind the reminder already up, before TA's
  assert.deepEqual(q.waiting.map((x) => x.id), ["water", "ta1", "ta2"]);
  q.acknowledge();
  assert.equal(q.current.id, "water");
  q.acknowledge();
  assert.equal(q.current.id, "ta1");
  const e = new BubbleQueue();
  assert.equal(e.preempt({ id: "eye", urgent: true }), true);
});

function fakeWin() {
  let id = 0;
  const pending = new Map();
  return {
    setTimeout(fn, ms) { pending.set(++id, { fn, ms }); return id; },
    clearTimeout(i) { pending.delete(i); },
    pending,
    fire() { const all = [...pending.values()]; pending.clear(); all.forEach((t) => t.fn()); },
  };
}

test("timers move to another window with their remaining time", () => {
  const a = fakeWin(), b = fakeWin();
  const t = createTimers(a);
  const hits = [];
  t.after(1000, () => hits.push("x"));
  const y = t.after(2000, () => hits.push("y"));
  t.cancel(y);
  assert.equal(a.pending.size, 1);
  t.rehome(b);
  assert.equal(a.pending.size, 0);
  assert.equal(b.pending.size, 1);
  assert.ok([...b.pending.values()][0].ms <= 1000);
  b.fire();
  assert.deepEqual(hits, ["x"]);
  assert.equal(t.size, 0);
});

test("sounds: neutral tones only, reminders always allowed, gesture needed, throttle", async () => {
  assert.equal(toneFor("arrive"), "twoNote");
  assert.equal(toneFor(["hug_missyou", "hug"]), "pop");   // custom keys → pop
  assert.equal(toneFor("leave"), null);
  assert.equal(toneFor("bgm"), null);
  assert.equal(toneFor("eyedrops"), "chime");
  for (const t of ["chime", "pop", "tick", "twoNote", "down"]) assert.ok(TONES[t].length > 0);
  assert.ok(ALWAYS_EVENTS.has("remind") && ALWAYS_EVENTS.has("eyedrops") && !ALWAYS_EVENTS.has("bubble"));

  const node = () => ({ connect: (x) => x || node(), disconnect() {}, gain: { value: 0, setValueAtTime() {}, exponentialRampToValueAtTime() {} },
    frequency: { setValueAtTime() {} }, start() {}, stop() {}, type: "" });
  class FakeCtx {
    constructor() { this.state = "suspended"; this.currentTime = 0; this.destination = node(); }
    resume() { this.state = "running"; return Promise.resolve(); }
    createGain() { return node(); }
    createOscillator() { return node(); }
  }
  const lines = [];
  const s = createSound({ manifest, log: (l) => lines.push(l), AudioContextCtor: FakeCtx });
  assert.equal(s.play("arrive"), null);                     // before any gesture: dropped
  const handlers = {};
  s.unlock({ addEventListener: (ev, fn) => { handlers[ev] = fn; } });
  handlers.pointerdown();
  await Promise.resolve();
  assert.equal(s.play("arrive"), "twoNote");
  assert.equal(s.play("arrive"), null);                     // throttled
  assert.equal(s.play("leave"), null);                      // silent on the web
  s.setPrefs({ on: false });
  assert.equal(s.play("bubble"), null);
  s.setPrefs({ on: true, volume: 0.8 });
  assert.equal(s.prefs.volume, 0.8);
  assert.equal(s.play("remind"), "chime");
  assert.ok(lines.some((l) => l.includes("[sound] arrive → twoNote")));
});

test("think scene: TA's pose picks the clip (doze z z, quiet, 勿扰 sign, weather, focus)", () => {
  const sc = (pose, extra) => sceneLook(cat, { character: "lumei", pose, ...extra }, () => 0);
  assert.equal(sc("idle").loop, true);
  assert.equal(sc("doze").badge.tiny, "z z");
  assert.equal(sc("quiet").still, true);
  assert.equal(sc("dnd", { dndSign: "💼 忙碌中" }).badge.sign, "💼 忙碌中");
  assert.equal(sc("focus").badge?.tiny, "🍅");             // 噜妹 has no focus clip
  const lulu = sceneLook(cat, { character: "lulu", pose: "focus" });
  if (manifest.version >= 2) assert.equal(lulu.loop, true);
  assert.equal(sc("weather:nope").loop, true);
});

test("rules (W1 via world/rules.js): PetLocation, couples, collisions, peek, idle", () => {
  const L = new R.PetLocation();
  assert.equal(L.planSend("text", 0, { visitorHere: false, reachable: true }).action, "deliver");
  L.sent(100);
  L.reachedAway(1000);
  assert.equal(L.place, "away");
  assert.equal(L.incoming({ trip: "deliver" }), "collision");
  assert.equal(L.incoming({ trip: "local" }), "queueForCard");
  assert.equal(L.planSend("poke", 2000, { visitorHere: false, reachable: true }).action, "extendAway");
  const B = new R.PetLocation();
  assert.deepEqual(B.planSend("poke", 0, { visitorHere: false, reachable: false }), { action: "bounce", send: false });
  const C = new R.PetLocation();
  assert.equal(C.planSend("visit", 0, { visitorHere: true, reachable: true }).action, "localMeeting");
  assert.equal(C.planSend("visit", 5000, { visitorHere: true, reachable: true }).action, "coolingDown");

  const couples = { hug: { intimate: true }, happy: { intimate: false } };
  const couple = { allowsCoupleClips: true, allowsIntimate: true };
  const friend = { allowsCoupleClips: true, allowsIntimate: false };
  assert.equal(R.meetingCouple({ pool: ["hug"], preferred: "hug", couples, policy: couple, last: null, roll: seq(0) }), "hug");
  assert.equal(R.meetingCouple({ pool: ["hug"], preferred: "hug", couples, policy: friend, last: null, roll: seq(0) }), null);
  assert.equal(R.meetingCouple({ pool: ["hug", "happy"], preferred: "hug", couples, policy: friend, last: null, roll: seq(0) }), "happy");
  assert.equal(R.meetingCouple({ pool: ["none"], preferred: "hug", couples, policy: couple, last: null, roll: seq(0) }), null);
  assert.equal(R.meetingCouple({ pool: [], preferred: "hug", couples, policy: { allowsCoupleClips: false }, last: null, roll: seq(0) }), null);
  assert.equal(R.coupleMirrored(true, "lulu", "lumei", true), false);
  assert.equal(R.coupleMirrored(true, "lulu", "lumei", false), true);
  assert.equal(R.coupleMirrored(true, "lulu", "lulu", true), null);

  assert.equal(R.collisionPlan({ ts: 10 }, { ts: 5 }, "lulu").winner, "partner");
  assert.equal(R.collisionPlan({ ts: 10 }, { ts: 10 }, "lumei").winner, "partner");   // tie: 噜噜 (the partner) first
  assert.equal(R.collisionPlan({ ts: 10 }, { ts: 10 }, "lulu").winner, "me");
  assert.deepEqual(R.collisionPlan({ ts: 1 }, { ts: 5 }, "lulu").steps.map((s) => s.step), ["stayAwayFor", "comeHomeWithVisitor"]);

  const ctx = { hidden: false, visitActive: false, bubbleShowing: false };
  assert.equal(R.peekVerdict(ctx, true).verdict, "show");
  assert.equal(R.peekVerdict({ ...ctx, bubbleShowing: true }, true).verdict, "wait");
  assert.equal(R.peekVerdict({ ...ctx, visitActive: true }, true).text, "TA 正在你这儿呢");
  assert.equal(R.peekVerdict(ctx, false).text, "还看不到 TA，等 TA 上线吧");
  assert.equal(R.thinkShouldShow("hover", { dnd: true }, null, 0), false);
  assert.equal(R.thinkShouldShow("hover", {}, 0, 59_000), false);
  assert.equal(R.thinkShouldShow("weather:rain", {}, 0, 1000), true);
  assert.equal(R.restPose({ dozing: false, quiet: false, dnd: true }), "quiet");
  assert.equal(R.derivePose({ dnd: false, focus: false, dozing: false, quiet: false, weather: "rain", hasWeatherClips: true }), "weather:rain");
  assert.equal(R.derivePose({ dnd: false, focus: false, dozing: false, quiet: false, weather: "rain", hasWeatherClips: false }), "idle");
  assert.deepEqual(R.pickFidget(3, 0, 1, null, seq(1)), { kind: "plain", index: 2 });
  assert.equal(R.pickFidget(0, 2, null, null, seq(0)).kind, "weather");
});

test("size rules and card titles", () => {
  assert.equal(normalizeScale(1.299999), 1.3);
  assert.equal(normalizeScale(9), 1.6);
  assert.ok(rubberBand(2) > 1.6 && rubberBand(2) < 1.64);
  assert.equal(rubberBand(1.2), 1.2);
  assert.equal(petHeightFor(230), 230 * 0.56);
  assert.equal(petHeightFor(300), 150);
  assert.equal(petHeightFor(100, 0.6), 72 * 0.6);
  // a tall stage (wide layout): a third of the height, at most half the width, 150–190 px
  assert.equal(petHeightFor(500, 1, 400), 170);
  assert.equal(petHeightFor(566, 1, 360), 180);
  assert.equal(petHeightFor(1000, 1, 300), 150);
  assert.equal(petHeightFor(1000), 190);
  assert.equal(timeOfDay(6), "dawn");
  assert.equal(timeOfDay(12), "day");
  assert.equal(timeOfDay(19.4), "dusk");
  assert.equal(timeOfDay(19.5), "night");
  assert.equal(timeOfDay(2), "night");
  assert.equal(cardTitle("dnd", 3), "你勿扰的时候，TA 来找过你 3 次～");
  assert.equal(cardTitle("trip"), "在TA那边的时候，TA说：");
});

test("world/ never imports js/net and never touches the opener's globals for DOM", () => {
  const dir = join(webRoot, "js/ui/world");
  const files = readdirSync(dir).filter((n) => n.endsWith(".js")).map((n) => join(dir, n));
  assert.ok(files.length >= 10 && statSync(dir).isDirectory());
  for (const f of files) {
    const src = readFileSync(f, "utf8").replace(/\/\/.*$/gm, "");
    assert.doesNotMatch(src, /from\s+["'][^"']*\/net\//, f);
    assert.doesNotMatch(src, /\bdocument\.(createElement|querySelector|getElementById|body|head)\b/, f);
  }
});
