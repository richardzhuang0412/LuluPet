// Real web-push request building (VAPID JWT + aes128gcm encryption) against a fake browser subscription: the
// "push service" here is a function that decrypts the body with the subscription's private key (RFC 8291).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createECDH, createDecipheriv, hkdfSync, randomBytes } from "node:crypto";
import webpush from "web-push";
import { parseVapid, sendAll } from "../src/send.js";

const b64u = (b) => Buffer.from(b).toString("base64url");

function fakeBrowser() {
  const ecdh = createECDH("prime256v1");
  ecdh.generateKeys();
  const auth = randomBytes(16);
  return { ecdh, auth, keys: { p256dh: b64u(ecdh.getPublicKey()), auth: b64u(auth) } };
}

function decrypt(browser, body) {
  const salt = body.subarray(0, 16);
  const idlen = body[20];
  const asPublic = body.subarray(21, 21 + idlen);
  const ct = body.subarray(21 + idlen);
  const secret = browser.ecdh.computeSecret(asPublic);
  const info = Buffer.concat([Buffer.from("WebPush: info\0"), browser.ecdh.getPublicKey(), asPublic]);
  const ikm = Buffer.from(hkdfSync("sha256", secret, browser.auth, info, 32));
  const cek = Buffer.from(hkdfSync("sha256", ikm, salt, Buffer.from("Content-Encoding: aes128gcm\0"), 16));
  const nonce = Buffer.from(hkdfSync("sha256", ikm, salt, Buffer.from("Content-Encoding: nonce\0"), 12));
  const d = createDecipheriv("aes-128-gcm", cek, nonce);
  d.setAuthTag(ct.subarray(ct.length - 16));
  const plain = Buffer.concat([d.update(ct.subarray(0, ct.length - 16)), d.final()]);
  let end = plain.length - 1;
  while (plain[end] === 0) end--;
  assert.equal(plain[end], 2, "last record delimiter");
  return plain.subarray(0, end).toString("utf8");
}

test("a payload sent with the real web-push library decrypts on the 'browser' and carries VAPID auth", async () => {
  const keys = webpush.generateVAPIDKeys();
  const vapid = parseVapid(JSON.stringify({ ...keys, subject: "mailto:test@example.invalid" }));
  const browser = fakeBrowser();
  const seen = [];
  // web-push with the network replaced: build the exact request, hand it to the fake push service.
  const wp = {
    async sendNotification(sub, payload, opts) {
      const req = webpush.generateRequestDetails(sub, payload, opts);
      seen.push(req);
      if (sub.endpoint.endsWith("/expired")) { const e = new Error("gone"); e.statusCode = 410; throw e; }
      return { statusCode: 201 };
    },
  };
  const payload = { v: 1, kind: "partner-remind", title: "噜妹说：", body: "噜妹叫你喝水啦 💧", tag: "msg-r1", key: "r1", remind: "water" };
  const targets = [
    { sub: { id: "a", endpoint: "https://push.example.invalid/a", keys: browser.keys }, silent: true },
    { sub: { id: "b", endpoint: "https://push.example.invalid/expired", keys: browser.keys }, silent: false },
  ];
  const r = await sendAll({ webpush: wp, vapid, targets, payload, ttl: 7200, urgency: "high" });
  assert.deepEqual(r, { sent: 1, gone: ["b"], failed: [] });
  const req = seen.find((x) => x.endpoint.endsWith("/a"));
  assert.equal(req.headers.TTL, 7200);
  assert.equal(req.headers.Urgency, "high");
  assert.equal(req.headers["Content-Encoding"], "aes128gcm");
  assert.match(req.headers.Authorization, new RegExp(`^vapid t=[\\w-]+\\.[\\w-]+\\.[\\w-]+, k=${keys.publicKey}$`));
  assert.deepEqual(JSON.parse(decrypt(browser, req.body)), { ...payload, silent: true });
  assert.ok(req.body.length < 4096, "Apple / FCM payload limit");
});

test("parseVapid rejects a missing / malformed secret and defaults the subject", () => {
  assert.throws(() => parseVapid(""), /not JSON/);
  assert.throws(() => parseVapid("{}"), /lacks keys/);
  assert.equal(parseVapid(JSON.stringify({ publicKey: "a", privateKey: "b", subject: "ftp://x" })).subject, "mailto:lulupet@example.invalid");
});
