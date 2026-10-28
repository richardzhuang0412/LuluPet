// Pixoo payloads and the client against the mock device.
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildGifPayloads, frameToBase64, FRAME_BYTES, PixooClient, PixooError, pickDevice, discover, endpointFor, describeCommand } from "../src/pixoo.js";
import { MockPixoo } from "../src/mock-pixoo.js";
import { silentLogger } from "../src/log.js";

const frame = (v = 0) => new Uint8Array(FRAME_BYTES).fill(v);

test("payloads: base64 of 64*64*3 bytes, PicOffset 0…n-1, one PicID / PicNum / speed", () => {
  const p = buildGifPayloads([frame(1), frame(2), frame(3)], 120.4, 1);
  assert.equal(p.length, 3);
  p.forEach((x, i) => {
    assert.equal(x.Command, "Draw/SendHttpGif");
    assert.equal(x.PicOffset, i);
    assert.equal(x.PicNum, 3);
    assert.equal(x.PicWidth, 64);
    assert.equal(x.PicID, 1);
    assert.equal(x.PicSpeed, 120);
    assert.equal(x.PicData.length, 16384);
    assert.equal(Buffer.from(x.PicData, "base64").length, 64 * 64 * 3);
    assert.equal(Buffer.from(x.PicData, "base64")[0], i + 1);
  });
  assert.throws(() => buildGifPayloads([], 100), PixooError);
  assert.throws(() => buildGifPayloads(Array(60).fill(frame()), 100), PixooError);
  assert.throws(() => frameToBase64(new Uint8Array(10)), PixooError);
  assert.match(describeCommand(p[1]), /SendHttpGif 2\/3 id=1 speed=120ms/);
  assert.ok(!describeCommand(p[1]).includes(p[1].PicData.slice(0, 20)));
});

test("endpoint / device picking", () => {
  assert.equal(endpointFor({ ip: "192.0.2.5" }), "http://192.0.2.5/post");
  assert.equal(endpointFor({ ip: "192.0.2.5", url: "http://192.0.2.5:9000/divoom_api" }), "http://192.0.2.5:9000/divoom_api");
  assert.equal(endpointFor({}), null);
  const list = [{ name: "TimeGate", ip: "a" }, { name: "Pixoo64", ip: "b" }, { name: "Kitchen Pixoo64", ip: "c" }];
  assert.equal(pickDevice(list).ip, "b");
  assert.equal(pickDevice(list, "kitchen").ip, "c");
  assert.equal(pickDevice([]), null);
});

test("discover parses Divoom's ReturnSameLANDevice reply", async () => {
  const fetch = async (url, init) => {
    assert.equal(url, "https://app.divoom-gz.com/Device/ReturnSameLANDevice");
    assert.equal(init.method, "POST");
    return new Response(JSON.stringify({ ReturnCode: 0, ReturnMessage: "", DeviceList: [{ DeviceName: "Pixoo64", DeviceId: 3, DevicePrivateIP: "192.0.2.7", DeviceMac: "x" }] }));
  };
  assert.deepEqual(await discover({ fetch }), [{ name: "Pixoo64", id: 3, ip: "192.0.2.7", mac: "x" }]);
});

test("client → mock device: reset + frames in order, brightness, screen", async () => {
  const dev = await new MockPixoo().listen();
  try {
    const c = new PixooClient({ endpoint: dev.url, requestGapMs: 0, minAnimationGapMs: 0, log: silentLogger });
    await c.setBrightness(140);
    await c.setScreen(false);
    assert.equal(await c.playAnimation([frame(9), frame(8)], 100, "t"), true);
    assert.equal(await c.playAnimation([frame(7)], 1000, "t2"), true);
    assert.deepEqual(dev.errors, []);
    assert.equal(dev.brightness, 100);
    assert.equal(dev.screenOn, false);
    assert.deepEqual(dev.commands.map((x) => x.Command), ["Channel/SetBrightness", "Channel/OnOffScreen",
      "Draw/ResetHttpGifId", "Draw/SendHttpGif", "Draw/SendHttpGif", "Draw/ResetHttpGifId", "Draw/SendHttpGif"]);
    assert.equal(dev.animations.length, 2);
    assert.equal(dev.animations[0].frames[1][0], 8);
    assert.equal(dev.animations[1].speed, 1000);
  } finally { await dev.close(); }
});

test("client retries a failing device, then reports the error", async () => {
  const dev = await new MockPixoo({ failFirst: 2 }).listen();
  try {
    const c = new PixooClient({ endpoint: dev.url, retries: 2, requestGapMs: 0, minAnimationGapMs: 0, log: silentLogger });
    await c.setBrightness(50);
    assert.equal(dev.brightness, 50);
    dev.failFirst = 10;
    await assert.rejects(c.setBrightness(10), PixooError);
  } finally { await dev.close(); }
});

test("a newer animation supersedes one still waiting in the queue", async () => {
  const dev = await new MockPixoo({ delayMs: 5 }).listen();
  try {
    const c = new PixooClient({ endpoint: dev.url, requestGapMs: 0, minAnimationGapMs: 0, log: silentLogger });
    const a = c.playAnimation(Array(10).fill(frame(1)), 100, "a");
    const b = c.playAnimation([frame(2)], 100, "b");
    assert.equal(await a, false);
    assert.equal(await b, true);
    assert.equal(dev.animations.at(-1).frames[0][0], 2);
    assert.deepEqual(dev.errors.filter((e) => !e.startsWith("out of order")), []);
  } finally { await dev.close(); }
});

test("timeouts become PixooError", async () => {
  const dev = await new MockPixoo({ delayMs: 300 }).listen();
  try {
    const c = new PixooClient({ endpoint: dev.url, timeoutMs: 50, retries: 0, log: silentLogger });
    await assert.rejects(c.ping(), /timeout/);
  } finally { await dev.close(); }
});
