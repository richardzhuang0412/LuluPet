import { test } from "node:test";
import assert from "node:assert/strict";
import * as P from "../js/core/presence.js";
import * as S from "../js/core/seat.js";

const now = 1791000000000;
const MAC = "6F1C2A7E-0B8D-4A55-9E21-7C3D5B9A1F00";
const place = { name: "上海", admin: "上海", country: "中国", latitude: 31.23, longitude: 121.47, timezone: "Asia/Shanghai" };

test("seat yield truth table (§4.2)", () => {
  const me = "web-aaaa";
  const y = (mine) => S.seatYield({ mine, myDevice: me, now });
  assert.equal(y({ lastSeen: now - 10000, device: MAC }), "yield", "my Mac online");
  assert.equal(y({ lastSeen: now - 75000, device: MAC }), "yield", "75 s is still online");
  assert.equal(y({ lastSeen: now - 75001, device: MAC }), "beat", "Mac stale");
  assert.equal(y({ lastSeen: 0, device: MAC }), "beat", "Mac signed off");
  assert.equal(y({ lastSeen: now - 1000, device: me }), "beat", "written by me");
  assert.equal(y({ lastSeen: now - 1000, device: "web-other" }), "beat", "another web tab / phone");
  assert.equal(y({ lastSeen: now - 1000 }), "beat", "pre-0.11 client without device");
  assert.equal(y(null), "beat", "never written");
  assert.ok(S.isWebDevice("web-x") && !S.isWebDevice(MAC) && !S.isWebDevice(null));
});

test("adoptIdentity copies the Mac identity, else seat defaults", () => {
  const mac = P.decodePresence({ lastSeen: 0, character: "lumei", mode: "friend", outfit: "maid", place, device: MAC });
  assert.deepEqual(S.adoptIdentity(mac, "lulu"), { character: "lumei", mode: "friend", outfit: "maid", place });
  assert.deepEqual(S.adoptIdentity(null, "lumei", { lumei: "classic" }), { character: "lumei", mode: "couple", outfit: "classic", place: null });
  assert.deepEqual(S.adoptIdentity(null, "lulu"), { character: "lulu", mode: "couple", outfit: null, place: null });
  assert.ok(S.maySignOff("web-a", "web-a") && !S.maySignOff(MAC, "web-a") && !S.maySignOff(undefined, "web-a"));
});

test("heartbeat / sign-off bodies (§4.3)", () => {
  const id = { character: "lulu", mode: "couple", device: "web-aaaa", outfit: "classic", place };
  assert.deepEqual(P.heartbeatPayload(id, now), {
    lastSeen: now, character: "lulu", mode: "couple", device: "web-aaaa", client: "web", outfit: "classic", place, pose: "idle",
  });
  const off = P.signOffPayload(id);
  assert.deepEqual(off, { lastSeen: 0, character: "lulu", mode: "couple", device: "web-aaaa", client: "web", outfit: "classic", place });
  for (const body of [P.heartbeatPayload(id, now), off]) {
    for (const k of ["app", "dnd", "focus"]) assert.equal(body[k], undefined, `never writes ${k}`);
  }
  const bare = P.heartbeatPayload({ character: "lumei", mode: "couple", device: "web-b", outfit: "../x", place: null }, now);
  assert.equal(bare.outfit, undefined);
  assert.equal(bare.place, undefined);
  // what the web writes reads back the same
  const back = P.decodePresence(JSON.parse(JSON.stringify(P.heartbeatPayload(id, now))));
  assert.deepEqual(S.adoptIdentity(back, "lulu"), { character: "lulu", mode: "couple", outfit: "classic", place });
  assert.equal(back.client, "web");
});

test("dnd / focus activity and lines", () => {
  assert.ok(P.dndActive({ mood: "busy", until: 0 }, now));
  assert.ok(P.dndActive({ mood: "", until: now + 1 }, now));
  assert.ok(!P.dndActive({ mood: "", until: now }, now));
  assert.ok(!P.dndActive(undefined, now));
  assert.ok(P.focusActive({ phase: "focus", until: now + 1 }, now) && !P.focusActive({ phase: "focus", until: now }, now));
  assert.equal(P.focusMinutesLeft({ until: now + 61000 }, now), 2);
  assert.equal(P.focusMinutesLeft({ until: now - 5 }, now), 1);
  assert.equal(P.partnerDNDLine({ mood: "angry" }), "TA 勿扰中（😤 生气中）");
  assert.equal(P.partnerDNDLine({ mood: "unsaid" }), "TA 勿扰中");
});

test("round2 rounds half away from zero", () => {
  assert.equal(P.round2(1.005 * 1), Math.round(1.005 * 100) / 100);
  assert.equal(P.round2(-0.125), -0.13);
  assert.equal(P.round2(0.125), 0.13);
});
