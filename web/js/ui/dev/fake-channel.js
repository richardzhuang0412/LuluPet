// Dev only (?dev=fake / ?dev=pip): a scripted stand-in for W2's createChannel with the same events, so the UI can be
// driven without Firebase. `window.__fake.emit(name)` pushes one more scripted event (used by screenshots / manual poking).

let seq = 0;
const key = () => "-Fake" + String(Date.now()).slice(-8) + String(seq++).padStart(6, "0");

export function fakeSeats(seat) {
  const now = Date.now();
  const me = { lastSeen: now - 30_000, character: seat, mode: "couple", device: "mac-HOME", outfit: seat === "lulu" ? "classic" : "lace",
    place: { name: "上海", admin: "上海", country: "中国", latitude: 31.23, longitude: 121.47, timezone: "Asia/Shanghai" } };
  const ta = { lastSeen: now - 5_000, character: seat === "lulu" ? "lumei" : "lulu", mode: "couple", device: "mac-TA",
    outfit: seat === "lulu" ? "lace" : "classic",
    place: { name: "深圳", admin: "广东", country: "中国", latitude: 22.54, longitude: 114.06, timezone: "Asia/Shanghai" } };
  return { mine: me, partner: ta };
}

/** What setup reads for both seats (fake GET /presence.json). */
export async function fakeReadSeats(_db, _code) {
  await new Promise((r) => setTimeout(r, 300));
  const s = fakeSeats("lulu");
  return { lulu: s.mine, lumei: s.partner };
}

export function createFakeChannel({ config }) {
  const t = new EventTarget();
  const me = config.seat;
  const ta = me === "lulu" ? "lumei" : "lulu";
  const timers = [];
  const emit = (type, detail) => t.dispatchEvent(Object.assign(new Event(type), { detail }));
  const msg = (o, ago = 0) => ({ id: key(), from: ta, ts: Date.now() - ago, v: 1, character: ta, outfit: ta === "lumei" ? "lace" : "classic",
    trip: "local", ...o });
  const at = (ms, fn) => timers.push(setTimeout(fn, ms));

  const scripted = {
    text: () => msg({ kind: "text", text: "今天下班一起吃火锅好不好～" }),
    sticker: () => msg({ kind: "sticker", stickerId: "missyou", text: "[表情] 想你了" }),
    poke: () => msg({ kind: "poke" }),
    water: () => msg({ kind: "remind", remind: "water" }),
    stand: () => msg({ kind: "remind", remind: "stand" }),
    xss: () => msg({ kind: "text", text: "<img src=x onerror=alert(1)>" }),
    unknown: () => msg({ kind: "hologram", text: "?" }),
    unknownSticker: () => msg({ kind: "sticker", stickerId: "zzz_future", text: "[表情] 么么哒" }),
  };
  const partnerPresence = () => { const p = fakeSeats(me).partner; p.lastSeen = Date.now() - 5000; return p; };

  t.start = () => {
    emit("connection", { state: "connecting" });
    at(500, () => {
      emit("connection", { state: "connected" });
      emit("mySeat", { presence: fakeSeats(me).mine, yielding: true, identity: { character: me, mode: "couple", outfit: fakeSeats(me).mine.outfit, place: fakeSeats(me).mine.place } });
      emit("partner", { presence: partnerPresence(), online: true });
      emit("backlog", { msgs: [
        msg({ kind: "text", text: "早呀，记得吃早饭" }, 3 * 3600_000),
        msg({ kind: "sticker", stickerId: "hug", text: "[表情] 抱抱" }, 2.5 * 3600_000),
        msg({ kind: "text", text: "中午吃了什么？" }, 2 * 3600_000),
        msg({ kind: "poke" }, 40 * 60_000),
        msg({ kind: "sticker", stickerId: "milktea", text: "[表情] 喝奶茶" }, 30 * 60_000),
        msg({ kind: "remind", remind: "water" }, 20 * 60_000),
      ] });
      emit("folded", { count: 0 });
    });
    if (config.script !== false) {
      at(4000, () => emit("message", { msg: scripted.text(), live: true }));
    }
    timers.push(setInterval(() => emit("partner", { presence: partnerPresence(), online: true }), 20_000));
  };
  t.stop = () => { timers.forEach((x) => { clearTimeout(x); clearInterval(x); }); };
  t.send = (m, opts = {}) => {
    if (opts.trip) m = { ...m, trip: opts.trip };
    const out = { ...m, id: key(), ts: Date.now(), character: me, outfit: m.outfit ?? (me === "lulu" ? "classic" : "lace") };
    console.log("[fake] send", JSON.stringify(out));
    if (out.kind === "remind" && !out.ackOf) {
      at(3000, () => emit("message", { msg: msg({ kind: "remind", remind: out.remind, ackOf: out.id, answer: "now" }), live: true }));
    }
    return out;
  };
  t.markRead = (m) => console.log("[fake] markRead", m.id);
  // v2 (W3 contract): look / dnd / focus go into the heartbeat only while the web holds the seat; here: logged.
  t.setLook = (l) => console.log("[fake] setLook", JSON.stringify(l));
  t.setDnd = (d) => console.log("[fake] setDnd", JSON.stringify(d));
  t.setFocus = (f) => console.log("[fake] setFocus", JSON.stringify(f));
  t.peekPartner = async () => partnerPresence();
  t.signOff = () => {};
  window.__fake = {
    emit: (name) => {
      if (name === "parked") return emit("parked", { msg: scripted.text() });
      if (name === "error") return emit("connection", { state: "error", reason: 403 });
      if (name === "offline") return emit("partner", { presence: { ...partnerPresence(), lastSeen: Date.now() - 40 * 60_000 }, online: false });
      if (name === "dnd") return emit("partner", { presence: { ...partnerPresence(), dnd: { mood: "busy", until: 0 } }, online: true });
      if (name === "takeover") return emit("mySeat", { presence: { ...fakeSeats(me).mine, lastSeen: 0 }, yielding: false, identity: { character: me, mode: "couple", outfit: fakeSeats(me).mine.outfit, place: fakeSeats(me).mine.place } });
      emit("message", { msg: scripted[name](), live: true });
    },
  };
  return t;
}
