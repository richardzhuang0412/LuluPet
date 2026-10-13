import { test } from "node:test";
import assert from "node:assert/strict";
import * as ST from "../js/core/stickers.js";
import * as WE from "../js/core/weather.js";
import * as C from "../js/core/config.js";
import * as PC from "../js/core/paircode.js";
import * as PO from "../js/core/policy.js";
import * as A from "../js/core/away.js";
import * as R from "../js/core/remind.js";

const now = 1791000000000;

test("stickers: friend mode keeps intimate ids stored but hides them", () => {
  const stored = ["hug", "missyou", "kiss", "hi"];
  const friend = ["missyou", "hi", "cry", "bear"];
  assert.deepEqual(ST.quickBar(stored, friend), ["missyou", "hi"]);
  assert.equal(ST.hiddenOnBar(stored, friend), 2);
  assert.deepEqual(ST.shownBar(stored, friend, { bear: 2 }, {}), ["missyou", "hi", "bear", "cry"]);
  assert.deepEqual(ST.removed("hug", stored), ["missyou", "kiss", "hi"]);
  assert.deepEqual(ST.visibleIds([{ id: "hug", intimate: true }, { id: "hi" }], false), ["hi"]);
  assert.deepEqual(ST.visibleIds([{ id: "hug", intimate: true }, { id: "hi" }], true), ["hug", "hi"]);
  assert.equal(ST.ranked({ constructor: 1 }, {}, ["hi", "constructor"])[0], "constructor", "own keys only");
  assert.deepEqual(ST.ranked({}, {}, ["hi", "toString"]), ["hi", "toString"]);
});

test("stickers: grouped / recorded / seed", () => {
  const g = ST.grouped([{ id: "a", group: "daily" }, { id: "b", group: "love" }, { id: "c" }, { id: "d", group: "zzz" }]);
  assert.deepEqual(g.map((x) => [x.group, x.stickers.map((s) => s.id)]), [["love", ["b"]], ["daily", ["a"]], [null, ["c", "d"]]]);
  assert.equal(g[2].title, "其他");
  let r = {};
  for (let i = 0; i < 205; i++) r = ST.recorded("s" + i, i, r);
  assert.equal(Object.keys(r).length, 200);
  assert.equal(r.s0, undefined);
  assert.equal(r.s204, 204);
  assert.deepEqual(ST.seedQuickBar(null, {}, {}, [...ST.DEFAULT_FAVORITES]), ST.DEFAULT_FAVORITES.slice(0, 8));
});

test("weather helpers", () => {
  assert.equal(WE.forecastURL(31.23, -118.2),
    "https://api.open-meteo.com/v1/forecast?current=temperature_2m,weather_code,cloud_cover,wind_speed_10m,is_day&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&latitude=31.23&longitude=-118.20&timezone=auto");
  assert.equal(WE.cacheKey({ latitude: 31.2, longitude: 121.47 }), "31.20,121.47");
  assert.equal(WE.ageLabel(0, 44 * 60), null);
  assert.equal(WE.ageLabel(0, 50 * 60), "50 分钟前");
  assert.equal(WE.ageLabel(0, 2 * 3600 + 5), "2 小时前");
  assert.ok(WE.isStale(0, 3 * 3600 + 1) && !WE.isStale(0, 3 * 3600));
  assert.ok(WE.isDue(null, 5) && WE.isDue(100, 50) && WE.isDue(0, 1800) && !WE.isDue(0, 1799));
  const s = WE.parseForecast({ current: { temperature_2m: 3 } });
  assert.ok(Math.abs(s.fetchedAt - Date.now() / 1000) < 5, "fetchedAt defaults to now (seconds)");
  assert.equal(s.condition, "cloudy");
});

test("database URL validation (§3)", () => {
  const ok = (s, url) => assert.deepEqual(C.validateDatabaseURL(s), { ok: true, url });
  ok("https://my-pair-db.firebaseio.com", "https://my-pair-db.firebaseio.com");
  ok("  https://My-Pair-DB.firebaseio.com/ ", "https://my-pair-db.firebaseio.com");
  ok("https://pair-default-rtdb.asia-southeast1.firebasedatabase.app", "https://pair-default-rtdb.asia-southeast1.firebasedatabase.app");
  ok("http://127.0.0.1:8765", "http://127.0.0.1:8765");
  ok("http://localhost:9000/", "http://localhost:9000");
  for (const bad of ["", null, "http://x.firebaseio.com", "https://x.firebaseio.com/path", "https://x.firebaseio.com?q=1",
    "https://x.firebaseio.com#f", "https://evil.com", "https://a.b.firebaseio.com", "https://x.firebaseio.com.evil.com",
    "http://127.0.0.1", "http://127.0.0.1:0", "http://127.0.0.1:70000", "https://127.0.0.1:8765", "javascript:alert(1)",
    "https://x.firebasedatabase.app", "https://-x.firebaseio.com", "https://user" + "\u0040" + "x.firebaseio.com"]) {   // userinfo URL, built so it is not an address literal
    assert.equal(C.validateDatabaseURL(bad).ok, false, String(bad));
  }
});

test("config validation and storage parse", () => {
  const code = "ABCD EFGH jkLM NPQR STUV WXYZ";
  const r = C.validateConfig({ databaseURL: "http://127.0.0.1:8765/", pairCode: code, seat: "lumei" });
  assert.deepEqual(r, { ok: true, config: { databaseURL: "http://127.0.0.1:8765", pairCode: "ABCDEFGHJKLMNPQRSTUVWXYZ", seat: "lumei" } });
  assert.equal(C.validateConfig({ databaseURL: "http://127.0.0.1:8765", pairCode: code, seat: "bob" }).ok, false);
  assert.equal(C.validateConfig({ databaseURL: "http://127.0.0.1:8765", pairCode: "SHORT", seat: "lulu" }).ok, false);
  assert.equal(C.parseStoredConfig("{bad json"), null);
  assert.equal(C.parseStoredConfig(JSON.stringify(r.config)).pairCode, "ABCDEFGHJKLMNPQRSTUVWXYZ");
  assert.equal(C.makeDeviceId("1234"), "web-1234");
  assert.equal(PC.normalize("ab\u0085cd　ef"), "ABCDEF");
});

test("content policy", () => {
  assert.equal(PO.effectiveMode("couple", null), "couple");
  assert.equal(PO.effectiveMode("couple", "friend"), "friend");
  assert.equal(PO.effectiveMode(undefined, "weird"), "couple");
  assert.equal(PO.partnerCharacter("lumei", null, null), "lumei");
  assert.equal(PO.partnerCharacter("lumei", { character: "lulu" }, "lumei"), "lulu");
  assert.equal(PO.partnerCharacter("lumei", {}, "lulu"), "lulu");
});

test("away card: stale pokes / replies skipped, parts", () => {
  const msgs = [
    { id: "1", from: "lumei", kind: "poke", ts: now - 300000 },
    { id: "2", from: "lumei", kind: "poke", ts: now - 299999 },
    { id: "3", from: "lumei", kind: "remind", remind: "water", ts: now - 3 * 3600000 },
    { id: "4", from: "lumei", kind: "text", text: "a", ts: now },
    { id: "5", from: "lumei", kind: "text", text: "b", ts: now },
    { id: "6", from: "lumei", kind: "sticker", stickerId: "hug", ts: now },
  ];
  const s = A.summarize(msgs, now);
  assert.equal(s.poke, 1);
  assert.equal(s.water, 1, "an old reminder still counts (only pokes / replies go stale)");
  assert.deepEqual(A.summaryParts(s), ["💬 2", "🧸 1", "❤️ 1", "💧 叫你喝水"]);
  assert.equal(A.summarize([], now).total, 0);
  assert.ok(R.isReplyable({ kind: "remind", remind: "stand", ts: now - 7200000 }, now));
  assert.ok(!R.isReplyable({ kind: "remind", remind: "stand", ts: now - 7200001 }, now));
  assert.ok(!R.isReplyable({ kind: "remind", remind: "stand", ackOf: "x", ts: now }, now));
  assert.ok(!R.isReplyable({ kind: "remind", remind: "water.later", ts: now }, now));
  assert.equal(R.remindBubble("water", "噜妹").line, "噜妹叫你喝水啦 💧");
});
