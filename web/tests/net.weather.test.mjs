import { test } from "node:test";
import assert from "node:assert/strict";
import { forecastURL, fetchCurrent } from "../js/net/weather-client.js";
import { createScheduler } from "../js/net/scheduler.js";
import { createLocalStore } from "../js/net/store.js";

const SH = { name: "上海", latitude: 31.2304, longitude: 121.4737, timezone: "Asia/Shanghai" };

test("forecastURL: same request as the Mac WeatherClient (sorted, 2 decimals)", () => {
  assert.equal(forecastURL(SH),
    "https://api.open-meteo.com/v1/forecast?current=temperature_2m%2Cweather_code%2Ccloud_cover%2Cwind_speed_10m%2Cis_day" +
    "&daily=temperature_2m_max%2Ctemperature_2m_min&forecast_days=1&latitude=31.23&longitude=121.47&timezone=auto");
  assert.throws(() => forecastURL({ name: "x" }));
});

test("fetchCurrent: parses the forecast, stamps fetchedAt; HTTP error and 10 s timeout reject", async () => {
  const body = { current: { temperature_2m: 21.5, weather_code: 3, cloud_cover: 90, wind_speed_10m: 12, is_day: 0 },
    daily: { temperature_2m_max: [24], temperature_2m_min: [17] } };
  let seen;
  const ok = async (url, init) => { seen = { url, init }; return new Response(JSON.stringify(body), { status: 200 }); };
  const snap = await fetchCurrent(SH, { fetch: ok, now: () => 1234 });
  assert.equal(seen.url, forecastURL(SH));
  assert.equal(seen.init.credentials, "omit");
  assert.equal(snap.temperature, 21.5);
  assert.equal(snap.high, 24);
  assert.equal(snap.low, 17);
  assert.equal(snap.isDay, false);
  assert.equal(snap.fetchedAt, 1234);

  await assert.rejects(fetchCurrent(SH, { fetch: async () => new Response("x", { status: 502 }) }), /HTTP 502/);
  await assert.rejects(fetchCurrent(SH, { fetch: async () => new Response("{}", { status: 200 }) }));
  const hang = (url, init) => new Promise((_, rej) => init.signal.addEventListener("abort", () => rej(init.signal.reason)));
  const t0 = Date.now();
  await assert.rejects(fetchCurrent(SH, { fetch: hang, timeoutMs: 80 }));
  assert.ok(Date.now() - t0 < 2000);
});

test("scheduler: worker ticks fire due timers once; clearTimeout; dispose stops the worker", async () => {
  const posted = [];
  let instance;
  globalThis.Worker = class {
    constructor(url) { this.url = String(url); instance = this; }
    postMessage(m) { posted.push(m); }
    terminate() { this.terminated = true; }
  };
  try {
    const s = createScheduler({ tickMs: 500 });
    assert.match(instance.url, /tick-worker\.js$/);
    assert.deepEqual(posted[0], { cmd: "start", ms: 500 });
    let fired = 0, cancelled = 0;
    s.setTimeout(() => fired++, 0);
    const h = s.setTimeout(() => cancelled++, 0);
    s.clearTimeout(h);
    instance.onmessage({ data: "tick" });   // the worker's tick fires the due timer …
    assert.equal(fired, 1);
    await new Promise((r) => setTimeout(r, 20));   // … and the native timer does not fire it again
    assert.equal(fired, 1);
    assert.equal(cancelled, 0);
    s.setTimeout(() => fired++, 60_000);
    instance.onmessage({ data: "tick" });
    assert.equal(fired, 1, "not due yet");
    s.dispose();
    assert.equal(instance.terminated, true);
    assert.equal(s.pending, 0);
  } finally {
    delete globalThis.Worker;
  }
});

test("createLocalStore: prefixed JSON values, bad data reads as null", () => {
  const m = new Map();
  const storage = { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, v), removeItem: (k) => m.delete(k) };
  const st = createLocalStore(storage);
  st.set("lastReadTs", 42);
  assert.equal(m.get("lulupet.lastReadTs"), "42");
  assert.equal(st.get("lastReadTs"), 42);
  m.set("lulupet.outbox", "{bad");
  assert.equal(st.get("outbox"), null);
  st.remove("lastReadTs");
  assert.equal(st.get("lastReadTs"), null);
  const throwing = createLocalStore({ getItem() { throw new Error("denied"); }, setItem() { throw new Error("quota"); }, removeItem() { throw new Error("x"); } });
  assert.equal(throwing.get("x"), null);
  throwing.set("x", 1);
  throwing.remove("x");
});
