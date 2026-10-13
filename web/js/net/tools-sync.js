// Personal tools synced between my Mac and my web (v2 §2.2), port of LuluSync/ToolsSync.swift: the eye-drop
// reminder under /pairs/{code}/tools/{seat}/eyedrops — only my seat's devices read or write it.
//
//   {"settings": {"enabled", "times": ["08:00", …], "notify", "at": ms, "device"},
//    "days": {"2026-10-12": {"0800": {"done": ms, "device"}, …}}}
//
//   const ts = createToolsSync({config: {databaseURL, pairCode, seat}, deviceId});
//   await ts.getSettings()                 → the settings object as stored (null = never written); decode with W1's
//                                            decodeEyedrops({settings}) — nothing is validated here
//   await ts.putSettings(settings)         → PUT …/settings (whole object; `at` defaults to now, `device` to mine)
//   await ts.getDay("2026-10-12")          → {"0800": {done, device}, …} as stored ({} = nothing)
//   await ts.putDone("2026-10-12", "08:00" | "0800", {done?, device?})  → PUT …/days/{day}/{HHmm} = {done, device}
//   await ts.deleteDone("2026-10-12", "0800")                           → DELETE that leaf
// Every call rejects with a FirebaseError (or a TypeError for a bad day / slot); the caller queues the write in
// `eyedropsPending` and retries. Default timeout 5 s (ToolsSync); pass {timeoutMs: 3000} for the read before a nag.

import { createFirebase } from "./firebase.js";

export const TOOLS_TIMEOUT_MS = 5_000;

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

/** "08:00" / "0800" → "0800" (24 h); anything else → null. */
export function slotLeaf(slot) {
  const m = /^([01]\d|2[0-3]):?([0-5]\d)$/.exec(String(slot ?? ""));
  return m ? m[1] + m[2] : null;
}

export function createToolsSync({ config, deviceId, fetch, timeoutMs = TOOLS_TIMEOUT_MS, now = () => Date.now() } = {}) {
  if (config?.seat !== "lulu" && config?.seat !== "lumei") throw new Error("config.seat must be lulu or lumei");
  const fb = createFirebase({ databaseURL: config.databaseURL, pairCode: config.pairCode, fetch });
  const base = `tools/${config.seat}/eyedrops`;
  const t = (opts) => ({ timeoutMs: opts?.timeoutMs ?? timeoutMs });
  const day = (d) => {
    if (typeof d !== "string" || !DAY_RE.test(d)) throw new TypeError(`bad day key: ${d}`);
    return d;
  };
  const leaf = (s) => {
    const k = slotLeaf(s);
    if (!k) throw new TypeError(`bad slot: ${s}`);
    return k;
  };
  const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

  return {
    path: base,

    async getSettings(opts) {
      const v = await fb.get(`${base}/settings`, t(opts));
      return isObj(v) ? v : null;
    },

    /** Resolves the body written. */
    async putSettings(settings, opts) {
      const body = { ...settings };
      if (!Number.isSafeInteger(body.at)) body.at = now();
      if (typeof body.device !== "string" || !body.device) body.device = deviceId;
      await fb.put(`${base}/settings`, body, t(opts));
      return body;
    },

    async getDay(d, opts) {
      const v = await fb.get(`${base}/days/${day(d)}`, t(opts));
      return isObj(v) ? v : {};
    },

    /** Resolves the leaf written ({done, device}). */
    async putDone(d, slot, { done, device } = {}, opts) {
      const path = `${base}/days/${day(d)}/${leaf(slot)}`;
      const body = { done: Number.isSafeInteger(done) ? done : now(), device: device || deviceId };
      await fb.put(path, body, t(opts));
      return body;
    },

    /** Undo: only for a leaf this device wrote (the caller checks `device`). */
    async deleteDone(d, slot, opts) {
      await fb.del(`${base}/days/${day(d)}/${leaf(slot)}`, t(opts));
    },
  };
}
