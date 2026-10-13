// Dev harness for web/js/ui/world (not deployed: deploy_web.sh excludes js/ui/dev/). Serve web/ with
//   python3 -m http.server --bind 127.0.0.1 8080 -d web
// and open http://127.0.0.1:8080/js/ui/dev/world/  (?pip=1 for the 300×260 PiP size, ?me=lumei to swap sides).
// Timings are shortened: fidget every 4 s, quiet after 15 s, doze after 25 s, visitor stays at most 20 s.

import { createWorld } from "../../world/world.js";
import { createSound } from "../../world/sound.js";

const params = new URLSearchParams(location.search);
const logEl = document.getElementById("log");
const box = document.getElementById("box");
if (params.get("pip")) box.classList.add("pip");
const log = (s) => {
  const line = `${new Date().toISOString().slice(11, 19)} ${s}\n`;
  logEl.textContent = line + logEl.textContent;
  console.log(s);
};

const base = new URL("../../../../assets/", import.meta.url).href;
const manifest = await (await fetch(base + "manifest.json", { cache: "no-cache" })).json();
const meChar = params.get("me") === "lumei" ? "lumei" : "lulu";
const taChar = meChar === "lulu" ? "lumei" : "lulu";
const sound = createSound({ manifest, log });
let mode = "couple";
let seq = 0;

const world = createWorld({
  manifest, sound, assetsBase: base, log: (s) => log("[world] " + s),
  policy: () => ({ allowsIntimate: mode === "couple", allowsCoupleClips: true, partnerCharacter: taChar, partnerOutfit: null }),
  onReply: (m, a) => log(`onReply ${m.id} ${a}`),
  onRead: (m) => log(`onRead ${m.id ?? m.kind}`),
  onCompose: (tab) => log(`onCompose ${tab}`),
  onMenu: (p) => log(`onMenu ${Math.round(p.x)},${Math.round(p.y)}`),
  onPeekDone: (r) => log(`onPeekDone ${r}`),
  fidgetMs: 4000, quietMs: 15_000, dozeMs: 25_000, visitorMaxStayMs: 20_000,
});
world.mountIn(document, box);
world.setMe({ character: meChar, seat: meChar, scale: 1 });
for (const ev of ["pose", "clicked", "dragged", "scaled", "wantThink", "collision"]) world.on(ev, (d) => log(`event ${ev} ${d === undefined ? "" : JSON.stringify(d)}`));
world.on("wantThink", (reason) => world.think(reason, scene("idle")));

const stickerIds = manifest.stickers.map((s) => s.id);
const sticker = ["hug", "baobao", "missyou"].find((id) => stickerIds.includes(id)) || stickerIds[0];
const msg = (kind, extra = {}) => ({ id: "m" + ++seq, kind, from: taChar, character: taChar, ts: Date.now(), trip: "local", ...extra });
const scene = (pose, extra = {}) => ({ character: taChar, outfit: null, pose, bar: "上海 🌧 19° · 晚上 11:42", flourish: "rain", ...extra });

const steps = {
  text: () => world.incoming(msg("text", { text: "下班一起吃饭吗～" }), { live: true }).then((r) => log("incoming → " + r)),
  sticker: () => world.incoming(msg("sticker", { stickerId: sticker }), { live: true }).then((r) => log("incoming → " + r)),
  kiss: () => world.incoming(msg("text", { text: "亲亲" }), { live: true }),
  poke: () => world.incoming(msg("poke"), { live: true }),
  visit: () => world.incoming(msg("visit"), { live: true }),
  remind: () => world.incoming(msg("remind", { remind: "water" }), { live: true }),
  friend: () => { mode = mode === "couple" ? "friend" : "couple"; log("mode " + mode); },
  deliver: () => { const m = { kind: "text", text: "hi", ts: Date.now() }; world.goDeliver(m, { visible: true, reachable: true }).then((r) => log(`deliver → ${r}`)); log("trip " + m.trip); },
  bounce: () => { const m = { kind: "poke", ts: Date.now() }; world.goDeliver(m, { visible: true, reachable: false }).then((r) => log(`bounce → ${r}`)); log("trip " + m.trip); },
  dndBounce: () => { const m = { kind: "text", ts: Date.now() }; world.goDeliver(m, { visible: true, reachable: true, partnerDND: true, bounceLine: "TA 开了勿扰（💼 忙碌中），先放在 TA 那儿啦" }).then((r) => log(`bounce → ${r}`)); },
  collision: () => {
    const mine = { kind: "text", text: "我先", ts: Date.now() };
    world.goDeliver(mine, { visible: true, reachable: true });
    setTimeout(() => world.incoming(msg("text", { text: "我也来找你", trip: "deliver", ts: mine.ts - 5 }), { live: true }), 600);
  },
  think: () => log("think → " + world.think("hover", scene("idle"))),
  thinkWeather: () => log("think → " + world.think("weather:rain", scene("weather:rain"))),
  peek: () => world.peek(scene("doze", { flourish: "snow", bar: "TA 不在线 ❄️ -2° · 早上 7:05" })),
  peekDnd: () => world.peek(scene("dnd", { dndSign: "💼 忙碌中", flourish: "none" })),
  eyedrops: () => world.bubble({ header: "👁️💧 眼药水", line: "该滴眼药水啦（14:00 · 今天第 3 次）", buttons: [{ title: "滴了 ✓", primary: true }, { title: "等会儿" }], tag: "eyedrops" }).then((r) => log("eyedrops → " + r)),
  eyedrops2: () => world.bubble({ header: "👁️💧 眼药水", line: "该滴眼药水啦（第 2 遍）", buttons: ["滴了 ✓", "等会儿"], tag: "eyedrops", replace: true }).then((r) => log("eyedrops#2 → " + r)),
  closeEye: () => log("closeBubble → " + world.closeBubble("eyedrops")),
  card: () => world.card("dnd", [msg("text", { text: "在吗" }), msg("poke"), msg("sticker", { stickerId: sticker }), msg("visit")]),
  weatherRain: () => world.setWeather("rain"),
  weatherHot: () => world.setWeather("hot"),
  weatherOff: () => world.setWeather(null),
  dndOn: () => world.setMood({ dnd: { sign: "💼 忙碌中" } }),
  focusOn: () => world.setMood({ dnd: null, focus: true, pomodoroLabel: "🍅 12" }),
  moodOff: () => world.setMood({ dnd: null, focus: false, pomodoroLabel: null }),
  big: () => world.setMe({ scale: 1.3 }),
  small: () => world.setMe({ scale: 0.75 }),
  activity: () => world.activity(),
  // Move the world into another document + window (what W4's PiP does), and back.
  popup: () => {
    const win = window.open("", "lw-popup", "width=320,height=280");
    if (!win) { log("popup blocked"); return; }
    win.document.title = "PiP stand-in";
    win.document.body.style.margin = "0";
    const host = win.document.createElement("div");
    host.style.width = "300px";
    host.style.height = "260px";
    win.document.body.append(host);
    world.mountIn(win.document, host);
    win.addEventListener("pagehide", () => world.mountIn(document, box), { once: true });
    window.__popup = win;
  },
  pip: async () => {
    if (!("documentPictureInPicture" in window)) { log("no Document PiP"); return; }
    const win = await window.documentPictureInPicture.requestWindow({ width: 300, height: 260 });
    win.document.body.style.margin = "0";
    const host = win.document.createElement("div");
    host.style.width = "100vw";
    host.style.height = "100vh";
    win.document.body.append(host);
    world.mountIn(win.document, host);
    win.addEventListener("pagehide", () => world.mountIn(document, box), { once: true });
  },
  home: () => { if (window.__popup) { window.__popup.close(); window.__popup = null; } world.mountIn(document, box); },
  ack: () => world.debug.bubbles.pressAck(),
};
window.__world = world;
window.__steps = steps;
const bar = document.getElementById("buttons");
for (const name of Object.keys(steps)) {
  const b = document.createElement("button");
  b.type = "button";
  b.textContent = name;
  b.addEventListener("click", () => steps[name]());
  bar.append(b);
}
log(`ready: me ${meChar}, manifest v${manifest.version}`);
