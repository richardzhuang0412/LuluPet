// The unread cursor (`lastReadTs`; the stream opens at `startAt = cursor + 1`). Port of PairChannel.markRead and the
// cursor rules of PairChannel.start (Sources/LuluSync/PairChannel.swift), plus the shared cursor of spec §5.2.

import { clampCursor, isFuture } from "./wire.js";

/** Write the shared cursor `read/<seat>` at most this often (s); also once on pagehide. */
export const SHARED_CURSOR_WRITE_S = 10;

/**
 * Cursor to open the stream with: max(local, shared). A value more than a day ahead (a poisoned cursor / bad clock)
 * becomes `now` (PairChannel.start), so it can't stall the stream.
 */
export function startCursor(local, shared, now) {
  const c = Math.max(Number.isSafeInteger(local) ? local : 0, Number.isSafeInteger(shared) ? shared : 0);
  return isFuture(c, now) ? now : c;
}

/** Value of the shared cursor read from `read/<seat>` ({ts, device, at}); anything else → null. */
export function decodeSharedCursor(obj) {
  if (obj === null || typeof obj !== "object" || Array.isArray(obj)) return null;
  return Number.isSafeInteger(obj.ts) ? obj.ts : null;
}

/** Body for `PUT read/<seat>`. */
export function sharedCursorPayload(ts, device, now) {
  return { ts, device, at: now };
}

/**
 * Messages may be acknowledged out of order (a poke at once, bubbles when dismissed), so the cursor never moves past
 * a delivered message that is still unread; otherwise it would be skipped after a restart. Only moves forward.
 */
export class ReadCursor {
  constructor(start = 0) {
    this.value = start;
    this.readHigh = 0;
    this.unread = new Map();
  }

  /** A message was handed to the UI (not read yet). */
  delivered(id, ts) {
    this.unread.set(id, ts);
  }

  /** The message was shown / dismissed. Returns the (possibly unchanged) cursor. */
  markRead(id, ts, now) {
    this.unread.delete(id);
    this.readHigh = Math.max(this.readHigh, ts);
    let cursor = this.readHigh;
    if (this.unread.size) cursor = Math.min(cursor, Math.min(...this.unread.values()) - 1);
    cursor = clampCursor(cursor, now);
    this.value = Math.max(this.value, cursor);
    return this.value;
  }

  /** Another device of my seat read further (shared cursor): only moves forward. */
  absorb(ts) {
    if (Number.isSafeInteger(ts)) this.value = Math.max(this.value, ts);
    return this.value;
  }

  get pending() {
    return this.unread.size;
  }
}
