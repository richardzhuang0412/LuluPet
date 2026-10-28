// The bridge's own read cursor and message queue (pure; no I/O).
//
// The cursor only moves past a message once it was shown, skipped (quiet hours "skip" / backlog fold) or ignored
// (sent by the other seat). It never moves past a message still waiting in the queue, so a restart at night re-reads
// the waiting messages from Firebase instead of losing them (the feed starts at `cursor + 1`). Nothing here is ever
// written to Firebase: the shared read/<seat> cursor belongs to the person's own devices.

export class Inbox {
  /** `cursor` = ms (messages with ts <= cursor count as seen). */
  constructor({ watchSeat = "lulu", cursor = 0, maxBacklog = 10 } = {}) {
    this.watchSeat = watchSeat;
    this.cursor = cursor;
    this.maxBacklog = maxBacklog;
    this.pending = [];
    this.seen = new Map();     // id → ts (dedupe across reconnects; pruned once behind the cursor)
    this.maxDone = cursor;
  }

  /** Decoded messages (any order) → {added: [msgs queued], ignored, folded}. */
  add(msgs) {
    const added = [];
    let ignored = 0, folded = 0;
    for (const m of [...msgs].sort(byTsId)) {
      if (m.ts <= this.cursor || this.seen.has(m.id)) continue;
      this.seen.set(m.id, m.ts);
      if (m.from !== this.watchSeat) { ignored++; this.maxDone = Math.max(this.maxDone, m.ts); continue; }
      this.pending.push(m);
      added.push(m);
    }
    this.pending.sort(byTsId);
    if (this.pending.length > this.maxBacklog) {
      const dropped = this.pending.splice(0, this.pending.length - this.maxBacklog);
      folded = dropped.length;
      for (const d of dropped) this.maxDone = Math.max(this.maxDone, d.ts);
    }
    return { added: added.filter((m) => this.pending.includes(m)), ignored, folded };
  }

  get size() { return this.pending.length; }
  peek() { return this.pending[0] ?? null; }

  /** The message was shown (or deliberately skipped). */
  done(msg) {
    const i = this.pending.findIndex((m) => m.id === msg.id);
    if (i >= 0) this.pending.splice(i, 1);
    this.maxDone = Math.max(this.maxDone, msg.ts);
  }

  /** Drop everything waiting (quiet hours with messages: "skip"). → number dropped. */
  skipAll() {
    const n = this.pending.length;
    for (const m of this.pending) this.maxDone = Math.max(this.maxDone, m.ts);
    this.pending = [];
    return n;
  }

  /** Where the cursor may move now: past everything done / ignored, but never past a waiting message. */
  cursorCandidate() {
    const limit = this.pending.length ? this.pending[0].ts - 1 : Infinity;
    return Math.max(this.cursor, Math.min(this.maxDone, limit));
  }

  /** Moves the cursor; → true when it changed (caller persists it). */
  commit() {
    const next = this.cursorCandidate();
    if (next === this.cursor) return false;
    this.cursor = next;
    for (const [id, ts] of this.seen) if (ts <= this.cursor) this.seen.delete(id);
    return true;
  }
}

function byTsId(a, b) {
  return (a.ts - b.ts) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}
