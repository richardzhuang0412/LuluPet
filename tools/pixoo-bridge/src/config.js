// Config: defaults ← JSON file (--config / $PIXOO_BRIDGE_CONFIG / ./config.json) ← environment variables.
// Relative paths are resolved against the bridge folder (tools/pixoo-bridge), so the systemd unit and a manual
// `node bin/pixoo-bridge.js` behave the same. Secrets (database URL, pair code) are never printed: `describe()`
// masks them, and the logger redacts them from every line.

import { readFileSync, existsSync } from "node:fs";
import { dirname, resolve, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";
import { normalize as normalizePairCode, isValid as isValidPairCode } from "../../../web/js/core/paircode.js";

export const BRIDGE_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");

export const DEFAULTS = Object.freeze({
  databaseURL: "",
  pairCode: "",
  watchSeat: "lulu",
  pixoo: {
    ip: "",                 // e.g. "192.168.1.50"; empty → discover via Divoom's cloud (same public IP = same LAN)
    url: "",                // full endpoint override, e.g. "http://192.168.1.50:9000/divoom_api" (hardware version 96)
    deviceName: "",         // with discovery: pick the device whose DeviceName contains this (default: first Pixoo64)
    requestTimeoutMs: 5000,
    retries: 2,
    requestGapMs: 30,       // pause between the per-frame requests of one animation
    minAnimationGapMs: 1000 // never start a new animation sooner than this after the previous one finished
  },
  brightness: 60,
  timezone: "",             // IANA name; empty = the system time zone
  quietHours: {
    enabled: true,
    start: "23:00",
    end: "08:00",
    mode: "off",            // "off" = screen off; "dim" = dimBrightness + a still idle frame
    dimBrightness: 5,
    messages: "morning"     // "morning" = keep and show when quiet hours end; "skip" = drop (mark seen)
  },
  durations: {
    pokeMs: 20_000,
    stickerMs: 25_000,
    remindMs: 25_000,
    visitMs: 25_000,
    unknownMs: 15_000,
    textMinMs: 20_000,
    textPageMs: 5_000,
    textMaxPages: 12
  },
  maxFrames: 40,            // per animation (Divoom: PicNum must be < 60)
  textFrames: 14,           // frames uploaded per page of a multi-page text (each page is a separate upload)
  maxBacklog: 10,           // after a long gap only the newest N messages are shown, the rest are marked seen
  presencePollMs: 15_000,
  stickerLabel: true,
  assetsDir: "../../web/assets",
  cacheDir: "./cache",
  stateFile: "./state/cursor.json",
  fontFile: "./fonts/fusion-pixel-10px-proportional-zh_hans.bdf",
  logLevel: "info"
});

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

function merge(base, over) {
  const out = { ...base };
  for (const [k, v] of Object.entries(over ?? {})) {
    if (k.startsWith("_")) continue;               // "_comment" keys in the example file
    out[k] = isObj(v) && isObj(base[k]) ? merge(base[k], v) : v;
  }
  return out;
}

const ENV = {
  LULUPET_DATABASE_URL: (c, v) => { c.databaseURL = v; },
  LULUPET_PAIR_CODE: (c, v) => { c.pairCode = v; },
  PIXOO_IP: (c, v) => { c.pixoo.ip = v; },
  PIXOO_URL: (c, v) => { c.pixoo.url = v; },
  PIXOO_BRIDGE_CACHE_DIR: (c, v) => { c.cacheDir = v; },
  PIXOO_BRIDGE_STATE_FILE: (c, v) => { c.stateFile = v; },
  PIXOO_BRIDGE_LOG_LEVEL: (c, v) => { c.logLevel = v; },
};

export class ConfigError extends Error {}

const HHMM = /^([01]\d|2[0-3]):([0-5]\d)$/;

/**
 * → config object. `needFirebase` = live mode (the database URL and pair code must be valid).
 * `file` = explicit path (must exist); otherwise $PIXOO_BRIDGE_CONFIG or ./config.json if present.
 */
export function loadConfig({ file, env = process.env, needFirebase = true } = {}) {
  let path = file ?? env.PIXOO_BRIDGE_CONFIG ?? null;
  if (!path && existsSync(resolve(BRIDGE_DIR, "config.json"))) path = resolve(BRIDGE_DIR, "config.json");
  let raw = {};
  if (path) {
    try { raw = JSON.parse(readFileSync(path, "utf8")); }
    catch (e) { throw new ConfigError(`读不了配置文件 ${path}: ${e.code ?? e.message}`); }
    if (!isObj(raw)) throw new ConfigError(`配置文件 ${path} 不是一个 JSON 对象`);
  }
  const c = merge(structuredClone(DEFAULTS), raw);
  for (const [k, set] of Object.entries(ENV)) if (env[k]) set(c, env[k]);
  c.configPath = path ? resolve(path) : null;

  c.pairCode = c.pairCode ? normalizePairCode(c.pairCode) : "";
  c.databaseURL = String(c.databaseURL ?? "").trim().replace(/\/+$/, "");
  if (needFirebase) {
    if (!/^https?:\/\/[^/?#]+$/.test(c.databaseURL)) throw new ConfigError("databaseURL 格式不对（应该像 https://<项目>-default-rtdb.firebaseio.com）");
    if (!isValidPairCode(c.pairCode)) throw new ConfigError("pairCode 不对（24 位，大写字母和数字）");
  }
  if (!["lulu", "lumei"].includes(c.watchSeat)) throw new ConfigError('watchSeat 只能是 "lulu" 或 "lumei"');
  const q = c.quietHours;
  if (q.enabled && (!HHMM.test(q.start) || !HHMM.test(q.end))) throw new ConfigError("quietHours.start / end 要写成 HH:MM");
  if (!["off", "dim"].includes(q.mode)) throw new ConfigError('quietHours.mode 只能是 "off" 或 "dim"');
  if (!["morning", "skip"].includes(q.messages)) throw new ConfigError('quietHours.messages 只能是 "morning" 或 "skip"');
  c.brightness = clampInt(c.brightness, 0, 100);
  q.dimBrightness = clampInt(q.dimBrightness, 0, 100);
  c.maxFrames = clampInt(c.maxFrames, 1, 59);
  c.textFrames = clampInt(c.textFrames, 1, c.maxFrames);
  if (c.timezone) {
    try { new Intl.DateTimeFormat("en-US", { timeZone: c.timezone }); }
    catch { throw new ConfigError(`timezone 不认识：${c.timezone}`); }
  }
  for (const k of ["assetsDir", "cacheDir", "stateFile", "fontFile"]) c[k] = resolvePath(c[k]);
  return c;
}

export function resolvePath(p) {
  return isAbsolute(p) ? p : resolve(BRIDGE_DIR, p);
}

function clampInt(v, lo, hi) {
  const n = Math.round(Number(v));
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : lo;
}

/** Config summary for the start-up log: secrets masked. */
export function describe(c) {
  return {
    config: c.configPath,
    database: c.databaseURL ? "(set)" : "(none)",
    pairCode: c.pairCode ? "(set)" : "(none)",
    watchSeat: c.watchSeat,
    pixoo: c.pixoo.url || c.pixoo.ip || "(auto-discover)",
    brightness: c.brightness,
    quietHours: c.quietHours.enabled ? `${c.quietHours.start}–${c.quietHours.end} ${c.quietHours.mode}, messages: ${c.quietHours.messages}` : "off",
    timezone: c.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone,
    cacheDir: c.cacheDir,
    stateFile: c.stateFile,
  };
}

/** Strings the logger must never print. */
export function secretsOf(c) {
  return [c.pairCode, c.databaseURL].filter(Boolean);
}
