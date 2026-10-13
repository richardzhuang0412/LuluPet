// Runs web/tests/vectors/wire.json against the JS port. The same file is checked against LuluCore by
// Sources/LuluCoreTests/WebVectors.swift (swift run LuluCoreTests).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import * as M from "../js/core/message.js";
import * as W from "../js/core/wire.js";
import * as PK from "../js/core/pushkey.js";
import * as R from "../js/core/remind.js";
import * as P from "../js/core/presence.js";
import * as S from "../js/core/seat.js";
import * as ST from "../js/core/stickers.js";
import * as WE from "../js/core/weather.js";
import * as PC from "../js/core/paircode.js";
import * as PO from "../js/core/policy.js";
import * as A from "../js/core/away.js";
import * as RM from "../js/core/reminder.js";
import { ReadCursor } from "../js/core/cursor.js";

const V = JSON.parse(readFileSync(new URL("./vectors/wire.json", import.meta.url), "utf8"));
const now = V.now;
const dec = (c) => M.decodeChild(c.key, c.value, now);

test("vectors: message decode", () => {
  assert.ok(V.decode.length >= 30);
  for (const c of V.decode) assert.deepEqual(dec(c), c.expect, c.name);
});

test("vectors: payload encode (round trip keeps unknown fields)", () => {
  for (const c of V.encode) {
    const p = M.encodePayload(dec(c));
    assert.deepEqual(p, c.expect, c.name);
    assert.deepEqual(Object.keys(p), Object.keys(p).slice().sort(), "keys sorted: " + c.name);
  }
});

test("vectors: send factories", () => {
  for (const c of V.factories) {
    let m;
    switch (c.factory) {
      case "text": m = M.textMsg(c.text, c.me, c.ts); break;
      case "sticker": m = M.stickerMsg(c.stickerId, c.label, c.me, c.ts); break;
      case "poke": m = M.pokeMsg(c.me, c.ts); break;
      case "remind": m = M.remindMsg(c.remind, c.me, c.ts); break;
      case "reply": m = R.replyMessage(c.remind, c.answer, c.me.from, c.ackOf, c.ts, c.me); break;
    }
    assert.deepEqual(M.encodePayload(m), c.expect, c.factory);
  }
});

test("vectors: remind replies", () => {
  for (const c of V.replies) {
    const r = R.decodeReply(dec(c));
    assert.deepEqual(r, c.expect, c.name);
    assert.equal(r && R.replyLine(r), c.line, c.name);
  }
});

test("vectors: wire limits", () => {
  for (const c of V.clipUTF16) assert.equal(W.clipUTF16(c.s, c.max), c.expect, JSON.stringify(c));
  for (const c of V.field) assert.equal(W.field(c.s), c.expect);
  for (const c of V.pushKeyPrefix) assert.equal(PK.generatePushKey(c.ms).slice(0, 8), c.prefix);
  for (const c of V.pushKeyValid) assert.equal(PK.isValidPushKey(c.s), c.expect, c.s);
  for (const c of V.outboxVerdict) assert.equal(W.outboxVerdict(c.status, c.streamConnected), c.expect, JSON.stringify(c));
  for (const c of V.backoff) assert.equal(W.backoffAfter(c.current, c.livedFor), c.expect);
  for (const c of V.queueFold) {
    const r = W.queueFold([...Array(c.n).keys()], c.cap);
    assert.equal(r.folded.length, c.folded);
    assert.deepEqual(r.kept, c.kept);
  }
  for (const c of V.cursorClamp) {
    assert.equal(W.isFuture(c.ts, c.now), c.isFuture);
    assert.equal(W.clampCursor(c.ts, c.now), c.clamp);
  }
});

test("vectors: presence", () => {
  for (const c of V.presence) assert.deepEqual(P.decodePresence(c.json), c.expect, c.name);
  for (const c of V.online) assert.equal(P.isOnline(c.lastSeen, c.now), c.expect);
});

test("vectors: stickers", () => {
  const s = V.stickers;
  assert.deepEqual(ST.sendCounts(s.sendCounts.messages.map(dec), s.sendCounts.me), s.sendCounts.expect);
  for (const c of s.ranked) assert.deepEqual(ST.ranked(c.counts, c.recent, c.visible), c.expect);
  for (const c of s.quickBar) {
    assert.deepEqual(ST.quickBar(c.stored, c.visible), c.quickBar);
    assert.equal(ST.hiddenOnBar(c.stored, c.visible), c.hiddenOnBar);
    const shown = ST.shownBar(c.stored, c.visible, s.counts, s.recent);
    assert.deepEqual(shown, c.shownBar);
    assert.deepEqual(ST.frequent(shown, s.counts, s.recent, c.visible), c.frequent);
  }
  for (const c of s.seedQuickBar) assert.deepEqual(ST.seedQuickBar(c.favorites, c.counts, c.recent, s.library), c.expect);
  for (const c of s.equipped) assert.deepEqual(ST.equipped(c.id, c.stored, c.visible), c.expect);
  for (const c of s.removed) assert.deepEqual(ST.removed(c.id, c.stored), c.expect);
});

test("vectors: weather", () => {
  for (const c of V.weather.wmo) assert.equal(WE.conditionFromWMO(c.code, c.cloudCover), c.expect, JSON.stringify(c));
  for (const c of V.weather.emoji) {
    assert.equal(WE.emoji(c.condition, c.isDay), c.emoji);
    assert.equal(WE.label(c.condition), c.label);
  }
  for (const c of V.weather.forecast) assert.deepEqual(WE.parseForecast(c.json, c.now), c.expect, c.name);
});

test("vectors: pair code, policy, away card", () => {
  for (const c of V.pairCode) {
    assert.equal(PC.normalize(c.raw), c.normalized);
    assert.equal(PC.isValid(c.normalized), c.valid);
  }
  for (const c of V.policy) assert.equal(PO.allowsIntimate(c.myMode, c.partnerMode), c.allowsIntimate, JSON.stringify(c));
  assert.deepEqual(A.summarize(V.away.messages.map(dec), V.away.now, V.away.me), V.away.expect);
});

test("vectors: ActiveTimeReminder sequences", () => {
  for (const seq of V.reminder) {
    let s = RM.newReminder(seq.interval);
    for (const step of seq.steps) {
      const [name, a, b, c] = step.op;
      let due = null;
      if (name === "tick") ({ state: s, due } = RM.tickIdle(s, a, b, c ?? false));
      else if (name === "snooze") s = RM.snooze(s, a);
      else if (name === "done") s = RM.done(s, a);
      else if (name === "resume") s = RM.resume(s, a);
      else if (name === "set") s = { ...s, ...a };
      assert.equal(due, step.due, JSON.stringify(step.op));
      assert.deepEqual(s, step.state, JSON.stringify(step.op));
    }
  }
});

test("vectors (JS only): seat yield truth table and read cursor", () => {
  for (const c of V.seatYield) assert.equal(S.seatYield({ mine: c.mine, myDevice: c.myDevice, now: c.now }), c.expect, `${c.writer}/${c.state}`);
  for (const seq of V.readCursor) {
    const cur = new ReadCursor(seq.start);
    for (const st of seq.steps) {
      const [n, id, ts] = st.op;
      const v = n === "delivered" ? (cur.delivered(id, ts), cur.value) : cur.markRead(id, ts, now);
      assert.equal(v, st.cursor, JSON.stringify(st.op));
    }
  }
});
