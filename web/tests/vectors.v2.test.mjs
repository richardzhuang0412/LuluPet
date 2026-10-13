// Web v2 sections of web/tests/vectors/wire.json against the JS ports (eye-drops spec §7 W1). The same cases are
// checked against LuluCore by Sources/LuluCoreTests/WebVectors.swift (`runWebVectorsV2`).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import * as E from "../js/core/eyedrops.js";
import * as D from "../js/core/dnd.js";
import * as PO from "../js/core/pomodoro.js";
import * as O from "../js/core/outfits.js";
import * as PS from "../js/core/pose.js";
import * as I from "../js/core/idle.js";
import * as R from "../js/core/reactions.js";
import * as S from "../js/core/sounds.js";
import * as T from "../js/core/think.js";
import * as WL from "../js/core/weatherlook.js";
import * as V from "../js/core/visits.js";
import * as H from "../js/core/history.js";
import * as P from "../js/core/presence.js";

const W = JSON.parse(readFileSync(new URL("./vectors/wire.json", import.meta.url), "utf8"));
const scripted = (us) => { let i = 0; return () => us[i++ % us.length]; };
const rolls = (rs) => { let i = 0; return () => rs[i++]; };
const name = (c) => c.name ?? JSON.stringify(c).slice(0, 120);

test("vectors v2: eye drops", () => {
  const ed = W.eyedrops, tz = ed.tz;
  assert.ok(ed.plan.length >= 25 && ed.progress.length >= 8);
  for (const c of ed.suggested) assert.deepEqual(E.suggestedTimes(c.n), c.expect, `n=${c.n}`);
  for (const c of ed.slotKey) assert.equal(E.slotKey(c.time), c.key, c.time);
  for (const c of ed.slotTime) assert.equal(E.slotTime(c.key), c.time, c.key);
  for (const c of ed.validate) assert.deepEqual(E.validateTimes(c.times), c.expect, JSON.stringify(c.times));
  for (const c of ed.instant) assert.equal(E.slotInstant(c.day, c.time, tz), c.expect, `${c.day} ${c.time}`);
  for (const c of ed.dayKey) assert.equal(E.dayKey(c.ms, tz), c.expect);
  for (const c of ed.decode) assert.deepEqual(E.decodeEyedrops(c.json), c.expect, c.name);
  for (const c of ed.nag) assert.deepEqual(E.decodeNag(c.json, c.now), c.expect, name(c));
  for (const c of ed.merge) assert.deepEqual(E.mergeSettings(c.local, c.remote), c.expect);
  for (const c of ed.plan) {
    assert.deepEqual(E.plan({ settings: c.settings, today: c.today, nag: c.nag, now: c.now, active: c.active, tz }), c.expect, c.name);
  }
  for (const c of ed.afterShow) assert.deepEqual(E.afterShow(c.nag, c.slot, c.now), c.expect);
  for (const c of ed.progress) {
    const p = E.progress(c.settings, c.today, c.now, tz, c.nag);
    assert.deepEqual(p, c.expect, c.name);
    assert.equal(E.badge(p), c.badge, c.name);
  }
  for (const c of ed.bubble) assert.deepEqual(E.bubbleCopy(c.slot, c.index, c.total), c.expect);
});

test("vectors v2: 勿扰", () => {
  const d = W.dnd, tz = d.tz;
  for (const c of d.until) assert.equal(D.durationUntil(c.duration, c.now, tz), c.expect, c.duration);
  for (const seq of d.sequences) {
    let st = D.newState();
    for (const step of seq) {
      const [n, a, b] = step.op;
      const t = step.op[step.op.length - 1];
      let span = null;
      if (n === "turnOn") st = D.turnOn(st, a, b, tz);
      else if (n === "turnOff") ({ state: st, span } = D.turnOff(st, a));
      else if (n === "expire") ({ state: st, span } = D.expire(st, a));
      else if (n === "mood") st = { ...st, mood: a };
      const msg = JSON.stringify(step.op);
      assert.deepEqual(st, step.state, msg);
      assert.deepEqual(span, step.span, msg);
      assert.equal(D.isOn(st, t), step.on, msg);
      assert.deepEqual(D.status(st, t), step.status, msg);
      assert.equal(D.endDeadline(st), step.endDeadline, msg);
      assert.equal(D.offTitle(st, tz), step.offTitle, msg);
      assert.equal(D.statusLine(st, tz), step.statusLine, msg);
    }
  }
  for (const c of d.spans) assert.equal(D.spanLabel(c.span, tz), c.label);
  for (const c of d.lines) {
    assert.equal(D.bounceLine(c.dnd), c.bounce);
    assert.equal(c.dnd ? D.partnerStatusLine(c.dnd) : null, c.partner);
  }
  for (const c of d.cardTitle) assert.equal(D.cardTitle(c.n), c.expect);
  for (const c of d.moods) {
    assert.deepEqual([D.moodEmoji(c.mood), D.moodTitle(c.mood), D.moodReason(c.mood), D.moodSign(c.mood)], [c.emoji, c.title, c.reason, c.sign]);
  }
});

test("vectors v2: pomodoro + tools copy", () => {
  const p = W.pomodoro;
  for (const seq of p.sequences) {
    let st = { ...PO.IDLE };
    for (const step of seq.steps) {
      const [n, a] = step.op;
      let event = null;
      if (n === "start") st = PO.start(st, a, seq.config);
      else if (n === "pause") st = PO.pause(st, a);
      else if (n === "resume") st = PO.resume(st, a);
      else if (n === "stop") st = PO.stop();
      else if (n === "skipBreak") st = PO.skipBreak(st);
      else if (n === "advance") ({ state: st, event } = PO.advance(st, a, seq.config));
      const t = a ?? 0, msg = JSON.stringify(step.op);
      assert.deepEqual(st, step.state, msg);
      assert.deepEqual(event, step.event, msg);
      assert.equal(PO.remaining(st, t), step.remaining, msg);
      assert.equal(PO.isPaused(st), step.paused, msg);
      assert.deepEqual(PO.focusStatus(st), step.focusStatus, msg);
      assert.equal(PO.pomodoroStateLine(st, t), step.line, msg);
      assert.equal(PO.endedLongAgo(st, t), step.endedLongAgo, msg);
    }
  }
  for (const c of p.decode) assert.deepEqual(PO.decodeState(c.json), c.expect, JSON.stringify(c.json));
  for (const c of p.copy) {
    assert.equal(PO.menuTitle(c.kind, c.interval), c.menuTitle);
    assert.equal(PO.explanation(c.kind, c.interval), c.explanation);
    assert.equal(PO.menuHint(c.kind), c.menuHint);
  }
  for (const c of p.durations) assert.equal(PO.pomodoroDurations(c.config), c.expect);
  for (const c of p.cycle) assert.equal(PO.cycleLine(c.kind, c.status), c.expect);
  assert.equal(PO.POMODORO_HINT, p.hint);
});

test("vectors v2: outfits", () => {
  const o = W.outfits, tz = o.tz;
  for (const c of o.inSeason) assert.equal(O.inSeason(c.season, c.ms, tz), c.expect, `${c.season} ${c.ms}`);
  for (const c of o.launch) {
    assert.equal(O.launchOutfit(o.outfits, o.seasons, c.ms, tz), c.launch);
    assert.deepEqual(O.eligible(o.outfits, o.seasons, c.ms, tz), c.eligible);
  }
  for (const c of o.resolvePin) assert.equal(O.resolvePin(c.pinned, o.outfits, o.seasons, c.ms, tz), c.expect);
  for (const c of o.next) assert.equal(O.nextOutfit(c.current, o.outfits, o.seasons, c.ms, tz, scripted(c.rands)), c.expect, name(c));
  assert.equal(O.nextOutfit("a", ["a"], {}, 0, tz, () => 0.5), o.nextNone.expect);
  let stack = [];
  for (const step of o.history) {
    let outfit = null;
    if (step.op[0] === "push") stack = O.historyPush(stack, step.op[1]);
    else ({ stack, outfit } = O.historyPop(stack, step.op[1], step.op[2]));
    assert.deepEqual(stack, step.stack, JSON.stringify(step.op));
    assert.equal(outfit, step.outfit);
    assert.equal(O.canGoBack(stack, ["a", "b", "c", "x"], "a"), step.canGoBack);
  }
  for (const c of o.choices) assert.deepEqual(O.choices(o.outfits, c.labels, o.seasons, c.current, c.pinned, c.ms, tz), c.expect);
  for (const c of o.visitorOutfit) assert.equal(O.visitorOutfit(c.requested, c.available, c.fallback), c.expect);
});

test("vectors v2: pose", () => {
  for (const c of W.pose.derive) assert.equal(PS.derivePose(c.input), c.expect, JSON.stringify(c.input));
  for (const c of W.pose.thinkLook) assert.equal(PS.thinkPoseLook(c.pose, c.hasFocusClip, (l) => c.weatherClips.includes(l)), c.expect, name(c));
  for (const c of W.pose.dndSign) assert.equal(PS.dndSign(c.dnd), c.expect);
  for (const c of W.pose.thinkOutfit) assert.equal(PS.thinkOutfit(c.published, c.lastMessage, c.available, c.preferred), c.expect, name(c));
});

test("vectors v2: idle", () => {
  for (const c of W.idle.fidgetDelay) assert.equal(I.fidgetDelay(c.fixed, c.unit), c.expect, name(c));
  for (const c of W.idle.pickFidget) assert.equal(I.pickFidget(c.count, c.last, rolls(c.rolls)), c.expect, name(c));
  let clock = I.newDozeClock(W.idle.doze.start, W.idle.doze.threshold);
  for (const step of W.idle.doze.steps) {
    let out;
    if (step.op[0] === "check") ({ state: clock, step: out } = I.dozeCheck(clock, step.op[1], step.op[2]));
    else if (step.op[0] === "activity") ({ state: clock, wokeUp: out } = I.dozeActivity(clock, step.op[1]));
    else out = I.dozeIsDue(clock, step.op[1]);
    assert.deepEqual(out, step.out, JSON.stringify(step.op));
    assert.deepEqual(clock, step.state, JSON.stringify(step.op));
  }
  for (const c of W.idle.restPose) assert.equal(I.restPose(c.dozing, c.quiet, c.dnd), c.expect);
});

test("vectors v2: reactions", () => {
  const r = W.reactions;
  const parsed = R.parseReactions(r.table);
  assert.deepEqual(parsed, r.parsed);
  for (const c of r.lookup) {
    const got = R.reactionFor(parsed, c.kind, c.stickerId);
    assert.deepEqual(got, c.expect, name(c));
    assert.deepEqual(R.visitorClips(got, "lulu"), c.lulu);
    assert.deepEqual(R.visitorClips(got, "lumei"), c.lumei);
  }
  assert.equal(R.reactionFor({}, "text", null), r.lookupEmpty.expect);
  for (const c of r.click) assert.deepEqual(R.clickClips(parsed, c.character), c.expect);
  for (const c of r.poolPick) assert.equal(R.poolPick(c.pool, c.last, scripted(c.rands)), c.expect, name(c));
});

test("vectors v2: sounds", () => {
  const s = W.sounds;
  const m = S.parseSoundManifest(s.manifest);
  assert.deepEqual(m, s.parsed);
  for (const c of s.files) assert.deepEqual(S.soundFiles(m, c.key, c.visitor, c.allowIntimate), c.expect, name(c));
  for (const c of s.forCouple) assert.equal(S.forCouple(c.name), c.expect);
  for (const c of s.forSticker) assert.equal(S.forSticker(c.id), c.expect);
  for (const c of s.meetingKeys) assert.deepEqual(S.meetingKeys(c.reaction, c.clipSound, c.fallback, c.couple), c.expect);
  for (const c of s.presetIndex) assert.equal(S.presetIndex(c.volume), c.expect);
  const g = new S.SoundGate(true, 0.3);
  for (const step of s.gate) {
    const [n, a, b] = step.op;
    let out = null;
    if (n === "decide") out = g.decide(a, b);
    else if (n === "away") g.beginAwayOnly(a, b);
    else if (n === "endAway") g.endAwayOnly();
    else if (n === "hidden") g.hidden = a;
    else if (n === "enabled") g.enabled = a;
    assert.equal(out, step.out, JSON.stringify(step.op));
    assert.equal(g.allowsBGM, step.allowsBGM);
  }
  const picker = new S.SoundPicker();
  for (const c of s.picker) assert.equal(picker.pick(c.key, c.files, scripted(c.rands)), c.expect, name(c));
});

test("vectors v2: 想 TA", () => {
  const t = W.think;
  for (const c of t.shouldShow) assert.equal(T.shouldShow(c.reason, c.context, c.lastShown, c.now), c.expect, name(c));
  for (const c of t.peek) assert.deepEqual(T.peekVerdict(c.context, c.partnerEverSeen), c.expect, name(c));
  for (const c of t.weatherTrigger) assert.equal(T.weatherTrigger(c.previous, c.hadData, c.current), c.expect, name(c));
  for (const c of t.flourish) assert.equal(T.flourish(c.snapshot), c.expect);
  for (const c of t.bar) assert.equal(T.barText(c.reason, c.place, c.snapshot, c.nowMs), c.expect, name(c));
  for (const c of t.peekBar) assert.equal(T.peekBarText(c.online, c.place, c.snapshot, c.nowMs), c.expect, name(c));
  for (const c of t.localTime) assert.equal(T.localTimeLabel(c.timezone, c.ms), c.expect, name(c));
  for (const c of t.idleDelay) assert.equal(T.idleDelay(c.unit), c.expect);
});

test("vectors v2: weather looks", () => {
  const w = W.weatherlook;
  for (const c of w.of) assert.equal(WL.weatherLook(c.snapshot), c.expect, name(c));
  for (const c of w.clipLooks) assert.deepEqual(WL.clipLooks(c.look), c.expect);
  for (const c of w.pick) assert.deepEqual(WL.pickWeatherFidget(c.plain, c.weather, c.lastPlain, c.lastWeather, rolls(c.rolls)), c.expect, name(c));
  for (const c of w.needsRefresh) assert.equal(WL.needsRefresh(...c.args), c.expect);
});

test("vectors v2: visits", () => {
  const v = W.visits;
  for (const c of v.coupleMove) assert.equal(V.coupleMove(c.kind, c.text, c.label), c.expect, name(c));
  for (const c of v.keywordCouples) assert.deepEqual(V.keywordCouples(c.text), c.expect);
  for (const c of v.meeting) {
    assert.equal(V.meetingCouple({ pool: c.pool, preferred: c.preferred, couples: v.couples, policy: c.policy, last: c.last, rand: scripted(c.rands) }), c.expect, name(c));
  }
  for (const c of v.timing) {
    assert.deepEqual([V.dwell(c.kind), V.deliveryAway(c.kind), V.sendsWhenOffline(c.kind)], [c.dwell, c.deliveryAway, c.sendsWhenOffline], c.kind);
  }
  for (const c of v.collision) assert.equal(V.resolveCollision(c.partnerTs, c.myTs, c.partner), c.expect, name(c));
  for (const c of v.collisionPlan) assert.deepEqual(V.collisionPlan(c.mine, c.theirs, c.me), c.expect);
  for (const seq of v.location) {
    const l = new V.PetLocation();
    for (const step of seq) {
      const [n, a] = step.op;
      let out = null;
      if (n === "send") out = l.planSend(a);
      else if (n === "incoming") out = l.incoming(a);
      else if (n === "awayRemaining") out = l.awayRemaining(a);
      else if (n === "sent") l.sent(a);
      else if (n === "reachedAway") l.reachedAway(a);
      else if (n === "setReturn") l.setReturn(a);
      else if (n === "leaveAgain") l.leaveAgain(a);
      else if (n === "beginCollision") l.beginCollision(a);
      else l[n]();
      assert.deepEqual(out, step.out, JSON.stringify(step.op));
      assert.deepEqual(l.state, step.state, JSON.stringify(step.op));
    }
  }
  for (const c of v.stay) {
    const clock = new V.VisitorStayClock();
    if (c.startedAt != null) clock.start(c.startedAt);
    assert.equal(V.stayDecision(c.now, c.stayUntil, c.bubblesWaiting, clock), c.expect, name(c));
    assert.equal(clock.remaining(c.now), c.remaining);
  }
  for (const c of v.focus) {
    assert.equal(V.partnerFocusHolds(c.focus, c.partnerOnline, c.nowMs), c.holds, name(c));
    assert.equal(c.focus ? V.partnerFocusLine("噜妹", c.focus, c.nowMs) : null, c.line);
  }
  for (const c of v.holding) assert.equal(V.isHoldingForFocus(c.state, c.now), c.expect, name(c));
  for (const c of v.remindAck) assert.equal(V.remindAckLine(c.kind), c.expect);
});

test("vectors v2: history", () => {
  const h = W.history, tz = h.tz;
  const sorted = h.messages.slice().sort(H.compareMessages);
  assert.deepEqual(sorted, h.messages);
  for (const c of h.page) {
    const r = H.page(sorted, c.limit, c.before);
    assert.deepEqual({ ids: r.messages.map((m) => m.id), hasMore: r.hasMore }, c.expect, name(c));
  }
  for (const c of h.rows) {
    const rows = H.rows(sorted.slice(c.from), c.noSpans ? [] : h.spans, c.complete, h.now, tz);
    assert.deepEqual(rows.map((r) => (r.type === "message" ? { type: "message", id: r.message.id } : r)), c.expect, name(c));
  }
  for (const c of h.dayLabel) assert.equal(H.dayLabel(c.ms, c.now, tz), c.expect, name(c));
  for (const c of h.timeLabel) assert.equal(H.timeLabel(c.ms, tz), c.expect);
  for (const c of h.remindLine) assert.equal(H.remindHistoryLine(c.message, c.fromMe), c.expect, name(c));
});

test("vectors v2: heartbeat / sign-off (presence.js v2)", () => {
  for (const c of W.heartbeat) {
    const got = "look" in c ? P.heartbeatPayload(c.identity, c.now, c.look) : P.heartbeatPayload(c.identity, c.now);
    assert.deepEqual(got, c.expect, c.name);
  }
  for (const c of W.signOff) {
    const got = "extra" in c ? P.signOffPayload(c.identity, c.extra) : P.signOffPayload(c.identity);
    assert.deepEqual(got, c.expect, c.name);
  }
});
