// The web client's own settings (spec §3). Pure validation only; storage lives in the UI / net layers.
// The database URL, pair code and seat are only ever kept in this browser's localStorage — never in the repo or a URL.

import { normalize as normalizePairCode, isValid as isValidPairCode } from "./paircode.js";

export { normalizePairCode, isValidPairCode };

export const STORAGE_PREFIX = "lulupet.";
/** localStorage keys (without the prefix), §3. */
export const STORAGE_KEYS = Object.freeze({
  config: "config", deviceId: "deviceId", lastReadTs: "lastReadTs", outbox: "outbox",
  stickerQuickBar: "stickerQuickBar", stickerSendCounts: "stickerSendCounts", stickerRecent: "stickerRecent",
  weatherCache: "weatherCache", pipSize: "pipSize", petScale: "petScale",
});
export const SEATS = ["lulu", "lumei"];

const FIREBASEIO = /^https:\/\/([a-z0-9](?:[a-z0-9-]*[a-z0-9])?)\.firebaseio\.com$/;
const REGIONAL = /^https:\/\/([a-z0-9](?:[a-z0-9-]*[a-z0-9])?)\.([a-z0-9](?:[a-z0-9-]*[a-z0-9])?)\.firebasedatabase\.app$/;
const LOCAL = /^http:\/\/(127\.0\.0\.1|localhost):(\d{1,5})$/;

/**
 * Database URL check → {ok: true, url} (canonical: trimmed, lower-cased, no trailing "/") | {ok: false, reason}.
 * Allowed: `https://<name>.firebaseio.com`, `https://<name>.<region>.firebasedatabase.app` (no path / query / port),
 * or for local testing `http://127.0.0.1:<port>` / `http://localhost:<port>`.
 */
export function validateDatabaseURL(s) {
  if (typeof s !== "string") return { ok: false, reason: "请填写数据库地址" };
  let url = s.trim();
  while (url.endsWith("/")) url = url.slice(0, -1);
  if (url === "") return { ok: false, reason: "请填写数据库地址" };
  url = url.toLowerCase();
  if (FIREBASEIO.test(url) || REGIONAL.test(url)) return { ok: true, url };
  const local = LOCAL.exec(url);
  if (local) {
    const port = Number(local[2]);
    if (port >= 1 && port <= 65535) return { ok: true, url };
  }
  return { ok: false, reason: "数据库地址格式有误（应为 https://<名字>.firebaseio.com 或 https://<名字>.<区域>.firebasedatabase.app）" };
}

/**
 * Whole config check → {ok: true, config: {databaseURL, pairCode, seat}} (normalized) | {ok: false, reason}.
 */
export function validateConfig(cfg) {
  if (cfg === null || typeof cfg !== "object") return { ok: false, reason: "还没有设置" };
  const db = validateDatabaseURL(cfg.databaseURL);
  if (!db.ok) return db;
  const pairCode = normalizePairCode(cfg.pairCode ?? "");
  if (!isValidPairCode(pairCode)) return { ok: false, reason: "配对码应为 24 位（字母和数字，不含 0 / O / 1 / I）" };
  if (!SEATS.includes(cfg.seat)) return { ok: false, reason: "请选择座位" };
  return { ok: true, config: { databaseURL: db.url, pairCode, seat: cfg.seat } };
}

/** Stored `lulupet.config` (raw string) → normalized config or null (bad data = no config). */
export function parseStoredConfig(raw) {
  try {
    const r = validateConfig(JSON.parse(raw));
    return r.ok ? r.config : null;
  } catch {
    return null;
  }
}

/** `"web-" + uuid` (pass crypto.randomUUID()). */
export function makeDeviceId(uuid) {
  return "web-" + uuid;
}
