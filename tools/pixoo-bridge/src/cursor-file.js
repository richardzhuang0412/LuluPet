// The bridge's read cursor on local disk: `{"ts": <ms>, "savedAt": <ms>}`. Never synced anywhere.
// First start (no file / unreadable file) begins at "now": no history replay. A cursor more than a day in the
// future (clock was wrong) is reset to now, like the apps do with lastReadTs.

import { readFileSync, writeFileSync, mkdirSync, renameSync } from "node:fs";
import { dirname } from "node:path";

const DAY_MS = 86_400_000;

/** → {ts, fresh}: fresh = true when the file was missing / unusable and `now` was used. */
export function loadCursor(path, now) {
  let obj;
  try { obj = JSON.parse(readFileSync(path, "utf8")); }
  catch { return { ts: now, fresh: true }; }
  const ts = obj && typeof obj.ts === "number" && Number.isSafeInteger(obj.ts) && obj.ts >= 0 ? obj.ts : null;
  if (ts === null) return { ts: now, fresh: true };
  if (ts > now + DAY_MS) return { ts: now, fresh: true };
  return { ts, fresh: false };
}

/** Atomic write (temp file + rename), creating the folder. */
export function saveCursor(path, ts, now) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify({ ts, savedAt: now }) + "\n", { mode: 0o600 });
  renameSync(tmp, path);
}
