// Per-device activity records (docs/superpowers/specs/2026-10-22-web-push.md §2.1, docs/upgrade-compat.md §18):
// which of my devices I am actually using, so push goes to that one ("whichever device I'm using gets the reminders").
//
//   /pairs/{code}/devices/{seat}/{deviceId} = {kind: "mac" | "web" | "phone", activeAt: ms of the last real user input
//                                               (0 = none yet), at: ms of this write, vis?: "visible" | "hidden"}
//
// Writers: the web page (js/net/devices.js; desktop "web", phones "phone") and the Mac app (≥ 0.19, kind "mac",
// activeAt from the HID idle time). Readers: the push functions (functions/src/rules.js), via a vendored copy.
// Pure: no DOM, no network. Times are ms on the writer's clock.

export const KINDS = Object.freeze(["mac", "web", "phone"]);
/** "Actively used" = real input within this long. */
export const ACTIVE_WINDOW_MS = 180_000;
/** A device's own page counts as open on screen while vis is "visible" and its last write is this recent. */
export const VISIBLE_FRESH_MS = 90_000;
/** Records whose `at` is older than this are ignored (and pruned by the functions). */
export const STALE_MS = 7 * 86_400_000;
/** Writers: on input at most once per this long … */
export const INPUT_WRITE_MS = 60_000;
/** … and a heartbeat this often while the page is open. */
export const HEARTBEAT_MS = 300_000;
/** A writer clock this far ahead of the reader's is not believed (a device would otherwise look active for hours). */
export const FUTURE_SLACK_MS = 300_000;

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const ms = (v) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? Math.trunc(v) : 0);

/** The record a writer PUTs. Unknown kinds are written as "web"; vis only when known. */
export function deviceRecord({ kind, activeAt, at, vis }) {
  const rec = { kind: KINDS.includes(kind) ? kind : "web", activeAt: ms(activeAt), at: ms(at) };
  if (vis === "visible" || vis === "hidden") rec.vis = vis;
  return rec;
}

/** One stored record → {id, kind, activeAt, at, vis} or null (not an object / no `at`). Unknown kinds kept as text. */
export function decodeDevice(id, v) {
  if (!isObj(v) || typeof v.at !== "number" || !Number.isFinite(v.at)) return null;
  return {
    id: String(id).slice(0, 64),
    kind: typeof v.kind === "string" ? v.kind.slice(0, 16) : "",
    activeAt: ms(v.activeAt),
    at: ms(v.at),
    vis: v.vis === "visible" || v.vis === "hidden" ? v.vis : null,
  };
}

export const isStale = (rec, now) => now - rec.at > STALE_MS;

/** `/devices/{seat}` node → the decoded, non-stale records, in key order. */
export function decodeDevices(node, now) {
  if (!isObj(node)) return [];
  return Object.keys(node).sort().map((k) => decodeDevice(k, node[k])).filter((r) => r && !isStale(r, now));
}

/** Ids of records to prune: `at` older than STALE_MS (malformed records are left alone — maybe a newer format). */
export function staleDeviceIds(node, now) {
  if (!isObj(node)) return [];
  return Object.keys(node).filter((k) => { const r = decodeDevice(k, node[k]); return !!r && isStale(r, now); });
}

/** Real input within ACTIVE_WINDOW_MS (a clock far in the future is not believed). */
export function isActivelyUsed(rec, now) {
  if (!rec || rec.activeAt <= 0 || rec.activeAt > now + FUTURE_SLACK_MS) return false;
  return now - rec.activeAt <= ACTIVE_WINDOW_MS;
}

/** The device's page is on screen right now: vis "visible" and written within VISIBLE_FRESH_MS. */
export function isVisibleNow(rec, now) {
  if (!rec || rec.vis !== "visible" || rec.at > now + FUTURE_SLACK_MS) return false;
  return now - rec.at <= VISIBLE_FRESH_MS;
}
