import { test } from "node:test";
import assert from "node:assert/strict";
import * as M from "../js/core/message.js";
import * as R from "../js/core/remind.js";

const now = 1791000000000;
const me = { from: "lumei", character: "lumei", outfit: "bluedress" };

test("spec §2.1 table: exactly the fields the web writes", () => {
  const keys = (m) => Object.keys(M.encodePayload(m)).sort();
  const common = ["character", "from", "kind", "outfit", "trip", "ts", "v"];
  assert.deepEqual(keys(M.textMsg("hi", me, 1)), [...common, "text"].sort());
  assert.deepEqual(keys(M.stickerMsg("missyou", "想你了", me, 1)), [...common, "stickerId", "text"].sort());
  assert.deepEqual(keys(M.pokeMsg(me, 1)), common);
  assert.deepEqual(keys(M.remindMsg("water", me, 1)), [...common, "remind"].sort());
  assert.deepEqual(keys(R.replyMessage("water", "now", "lumei", "K", 1, me)), [...common, "ackOf", "answer", "remind"].sort());
  const later = M.encodePayload(R.replyMessage("water", "later", "lumei", "K", 1, me));
  assert.equal(later.remind, "water.later");
  assert.equal(later.answer, "later");
  assert.equal(later.trip, "local");
  assert.equal(M.stickerMsg("missyou", "想你了", me, 1).text, "[表情] 想你了");
  assert.equal(M.stickerMsg("missyou", null, me, 1).text, undefined);
  for (const m of [M.textMsg("x", me, 1), M.pokeMsg(me, 1)]) {
    assert.equal(m.id, undefined, "no id: the channel assigns the push key");
    assert.equal(M.encodePayload({ ...m, id: "K", localId: "L" }).id, undefined);
  }
});

test("factory text is clamped to 500 UTF-16 units", () => {
  assert.equal(M.textMsg("x".repeat(600), me, 1).text.length, 500);
  assert.equal(M.textMsg("a".repeat(499) + "👍", me, 1).text, "a".repeat(499));
});

test("encodedSize counts '/' as '\\/' and UTF-8 bytes", () => {
  assert.equal(M.encodedSize({ a: "/" }), Buffer.byteLength('{"a":"/"}') + 1);
  assert.equal(M.encodedSize({ a: "噜" }), Buffer.byteLength('{"a":"噜"}'));
  assert.equal(M.encodedSize({ a: "😀" }), Buffer.byteLength('{"a":"😀"}'));
});

test("decodeChild: XSS text is kept verbatim (rendering uses textContent)", () => {
  const m = M.decodeChild("k", { from: "lulu", kind: "text", text: "<img src=x onerror=alert(1)>", ts: now }, now);
  assert.equal(m.text, "<img src=x onerror=alert(1)>");
});

test("decodeChildren sorts by (ts, id) and drops bad children", () => {
  const out = M.decodeChildren({
    b: { from: "lulu", kind: "poke", ts: 2 },
    a: { from: "lulu", kind: "poke", ts: 2 },
    c: { from: "lulu", kind: "poke", ts: 1 },
    bad: { from: "x", kind: "poke", ts: 1 },
  }, now);
  assert.deepEqual(out.map((m) => m.id), ["c", "a", "b"]);
  assert.deepEqual(M.decodeChildren(null, now), []);
});

test("decodeStreamEvent: backlog, single child, deeper paths, keep-alive", () => {
  const backlog = M.decodeStreamEvent("put", JSON.stringify({ path: "/", data: { k1: { from: "lumei", kind: "poke", ts: 5 } } }), now);
  assert.equal(backlog.backlog, true);
  assert.deepEqual(backlog.msgs.map((m) => m.id), ["k1"]);
  const empty = M.decodeStreamEvent("put", JSON.stringify({ path: "/", data: null }), now);
  assert.deepEqual(empty, { backlog: true, msgs: [] });
  const one = M.decodeStreamEvent("put", JSON.stringify({ path: "/k2", data: { from: "lumei", kind: "text", text: "hi", ts: 6 } }), now);
  assert.equal(one.backlog, false);
  assert.equal(one.msgs[0].id, "k2");
  assert.deepEqual(M.decodeStreamEvent("put", JSON.stringify({ path: "/k2/text", data: "x" }), now).msgs, []);
  assert.deepEqual(M.decodeStreamEvent("keep-alive", "null", now), { backlog: false, msgs: [] });
  const patch = M.decodeStreamEvent("patch", JSON.stringify({ path: "/", data: { k3: { from: "lulu", kind: "poke", ts: 7 } } }), now);
  assert.equal(patch.msgs.length, 1);
  assert.ok(M.isAuthRevokedEvent("cancel") && M.isAuthRevokedEvent("auth_revoked") && !M.isAuthRevokedEvent("put"));
});

test("unknown sticker / kind display", () => {
  const withLabel = M.decodeChild("k", { from: "lulu", kind: "sticker", stickerId: "newone", text: "[表情] 么么哒", ts: 1 }, now);
  assert.equal(M.unknownStickerText(withLabel), "［表情：么么哒］");
  assert.equal(M.unknownStickerText(withLabel, "目录名"), "［表情：目录名］");
  const bare = M.decodeChild("k", { from: "lulu", kind: "sticker", stickerId: "newone", ts: 1 }, now);
  assert.equal(M.unknownStickerText(bare), "［表情：newone］");
  assert.equal(M.UNKNOWN_KIND_PLACEHOLDER, "［新版本消息，请升级噜噜桌宠查看］");
  assert.ok(M.isKnownKind("remind") && !M.isKnownKind("hug2"));
});
