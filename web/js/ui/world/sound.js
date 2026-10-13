// Web sounds (spec §4.2 as changed by the user, 2026-10-12): the web version is used at the office, so it plays no
// character voices / audio files at all. Every sounds.json event maps to one of five short, quiet, synthesized UI
// tones (Web Audio oscillators with a soft envelope) or to silence. One AudioContext in the document that created
// it (the main page); the first pointerdown / keydown in any unlocked document (main page or PiP) resumes it — sounds
// asked for before that are dropped, not queued. Same API as the spec contract: createSound → unlock / play / setPrefs.

/** event → tone; anything not listed (and every custom sounds.json key) → "pop"; null = silent. */
export const EVENT_TONES = {
  // a visitor shows up / the 「你不在的时候」 card
  arrive: "twoNote", awaySummary: "twoNote",
  // something TA said: a bubble, a sticker reaction, a meeting
  bubble: "pop", poke: "pop", hug: "pop", kiss: "pop", nuzzle: "pop", happy: "pop", angry: "pop", cry: "pop", click: "pop",
  // my own sends: off with a message / back home
  goVisit: "tick", goBack: "tick",
  // TA not there / busy: the pet comes back with the message
  notHome: "down",
  // my own reminders (water / stand / eye drops / pomodoro): always sound, even during 勿扰 / 专注
  remind: "chime", eyedrops: "chime", pomodoro: "chime", water: "chime", stand: "chime",
  // quiet on the web
  leave: null, doze: null, bgm: null,
};
/** Events that play even while 勿扰 / 专注 (the world only lets card sounds through otherwise). */
export const ALWAYS_EVENTS = new Set(["remind", "eyedrops", "pomodoro", "water", "stand", "awaySummary"]);

export const VOLUMES = { small: 0.25, medium: 0.5, large: 0.8 };
const THROTTLE_MS = 300;
const MASTER = 0.35;   // tones are quiet even at 「大」

/** The tone an event (or the first of a list of sounds.json keys) plays; null = silence. */
export function toneFor(event) {
  const key = Array.isArray(event) ? event[0] : event;
  if (typeof key !== "string" || !key) return null;
  return Object.prototype.hasOwnProperty.call(EVENT_TONES, key) ? EVENT_TONES[key] : "pop";
}

/** Notes of each tone: [freqHz, startS, lengthS, wave, gain]. */
export const TONES = {
  chime: [[880, 0, 0.5, "sine", 0.9], [1318.5, 0.12, 0.6, "sine", 0.6], [1760, 0.12, 0.35, "sine", 0.15]],
  pop: [[660, 0, 0.12, "triangle", 0.9], [990, 0.02, 0.09, "sine", 0.35]],
  tick: [[1500, 0, 0.05, "triangle", 0.55]],
  twoNote: [[587.3, 0, 0.18, "sine", 0.8], [880, 0.14, 0.26, "sine", 0.8]],
  down: [[523.3, 0, 0.18, "triangle", 0.7], [392, 0.15, 0.26, "triangle", 0.7]],
};

/**
 * `manifest` is accepted for the contract (the web plays no files, so it is not read). `log` (optional) gets
 * "[sound] arrive → twoNote" lines (dev / E11). `AudioContextCtor` defaults to the creating window's AudioContext.
 */
export function createSound({ manifest, log, AudioContextCtor } = {}) {
  void manifest;
  let prefs = { on: true, volume: VOLUMES.small, bgm: false };
  let ctx = null;
  let unlocked = false;
  const last = new Map();
  const docs = new WeakSet();
  const Ctor = AudioContextCtor || globalThis.AudioContext || globalThis.webkitAudioContext;

  function context() {
    if (!ctx && Ctor) { try { ctx = new Ctor(); } catch { ctx = null; } }
    return ctx;
  }

  function onGesture() {
    const c = context();
    if (!c) return;
    if (c.state === "suspended") c.resume().then(() => { unlocked = true; }, () => {});
    else unlocked = true;
  }

  function tone(name) {
    const c = ctx;
    const notes = TONES[name];
    if (!c || !notes) return;
    const out = c.createGain();
    out.gain.value = MASTER * prefs.volume;
    out.connect(c.destination);
    const t0 = c.currentTime + 0.01;
    let end = t0;
    for (const [f, at, len, wave, g] of notes) {
      const o = c.createOscillator();
      const env = c.createGain();
      o.type = wave;
      o.frequency.setValueAtTime(f, t0 + at);
      env.gain.setValueAtTime(0.0001, t0 + at);
      env.gain.exponentialRampToValueAtTime(g, t0 + at + 0.012);
      env.gain.exponentialRampToValueAtTime(0.0001, t0 + at + len);
      o.connect(env).connect(out);
      o.start(t0 + at);
      o.stop(t0 + at + len + 0.02);
      end = Math.max(end, t0 + at + len + 0.05);
    }
    setTimeout(() => { try { out.disconnect(); } catch { /* ignore */ } }, Math.ceil((end - c.currentTime) * 1000) + 100);
  }

  return {
    /** Listens for the first gesture in `doc` (the main page, and the PiP document when it opens). */
    unlock(doc) {
      if (!doc || docs.has(doc)) return;
      docs.add(doc);
      doc.addEventListener("pointerdown", onGesture, { capture: true });
      doc.addEventListener("keydown", onGesture, { capture: true });
    },
    /**
     * Plays the tone for `event` (an event name, or a list of sounds.json keys: the first decides). `visitor` /
     * `intimateOK` are part of the contract; neutral tones don't depend on them. → the tone played, or null.
     */
    play(event, opts = {}) {
      void opts;
      const key = Array.isArray(event) ? event[0] : event;
      const name = toneFor(event);
      if (!prefs.on || !name) return null;
      const now = Date.now();
      if (now - (last.get(name) ?? -Infinity) < THROTTLE_MS) return null;
      if (!unlocked || !ctx || ctx.state !== "running") { log?.(`[sound] ${key} → dropped (no gesture yet)`); return null; }
      last.set(name, now);
      log?.(`[sound] ${key} → ${name}`);
      tone(name);
      return name;
    },
    /** {on, volume (0.25 / 0.5 / 0.8), bgm (ignored: no music on the web)}. */
    setPrefs(p = {}) {
      prefs = {
        on: p.on ?? prefs.on,
        volume: Number.isFinite(p.volume) ? Math.min(1, Math.max(0, p.volume)) : prefs.volume,
        bgm: !!(p.bgm ?? prefs.bgm),
      };
    },
    get prefs() { return { ...prefs }; },
    get unlocked() { return unlocked; },
  };
}
