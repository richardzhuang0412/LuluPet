// In-memory stand-ins for the admin database and web-push.

export const CODE = "ABCDEFGHJKLMNPQRSTUVWXYZ";   // a well-formed fake pair code (never a real one)

export function fakeDb(tree = {}) {
  const root = { v: structuredClone(tree) };
  const segs = (p) => p.split("/").filter(Boolean);
  const reads = [];
  function get(path) {
    reads.push(path);
    let n = root.v;
    for (const s of segs(path)) {
      if (n == null || typeof n !== "object") return null;
      n = n[s];
    }
    return n === undefined ? null : structuredClone(n);
  }
  function set(path, value) {
    const ss = segs(path);
    let n = root.v;
    for (const s of ss.slice(0, -1)) {
      if (n[s] == null || typeof n[s] !== "object") {
        if (value === null) return;
        n[s] = {};
      }
      n = n[s];
    }
    const last = ss[ss.length - 1];
    if (value === null) delete n[last];
    else n[last] = structuredClone(value);
  }
  return {
    reads,
    tree: () => root.v,
    get: async (p) => get(p),
    update: async (obj) => { for (const [p, v] of Object.entries(obj)) set(p, v); },
  };
}

/** web-push stand-in: records calls; `statusFor(endpoint)` → throw a WebPushError-like error with that status. */
export function fakeWebpush(statusFor = () => null) {
  const calls = [];
  return {
    calls,
    async sendNotification(sub, body, opts) {
      calls.push({ endpoint: sub.endpoint, payload: JSON.parse(body), opts });
      const s = statusFor(sub.endpoint);
      if (s) { const e = new Error("push failed"); e.statusCode = s; throw e; }
      return { statusCode: 201 };
    },
  };
}

export const VAPID = { publicKey: "BPUBLICKEYPUBLICKEYPUBLICKEY", privateKey: "private", subject: "mailto:test@example.invalid" };

export function sub(over = {}) {
  return {
    endpoint: "https://push.example.invalid/sub/1",
    keys: { p256dh: "p", auth: "a" },
    device: "web-phone",
    phone: true,
    tz: "America/Los_Angeles",
    ua: "test",
    at: 1,
    key: VAPID.publicKey.slice(0, 16),
    prefs: { messages: true, reminders: true, eyedrops: false, onlyWhenAway: true, dnd: "silent" },
    ...over,
  };
}
