// The 记录 tab's local copy of the pair's messages (v2 §4.5): IndexedDB `lulupet` (version 1), store `messages`
// (key = push key, index `ts` on [ts, id]) holding the Firebase JSON as it is, store `meta` (one row) =
// {pairCode, seat, oldestComplete, oldestFetched, syncedTo}. Another pair code / seat → everything is cleared.
//
//   const h = await openHistory({pairCode, seat});              // backend: IndexedDB (browser) or memory (tests)
//   await h.put([msg, …]);                                       // decoded Msgs (channel events) or {key: raw} objects
//   const {added, complete} = await h.backfill(messagesFetcher(config));          // first time / newer
//   await h.backfill(fetcher, {older: true});                    // scrolled to the top: one older page
//   const rows = await h.page({beforeTs, beforeId, limit});      // decoded Msgs, oldest first (newest page if no bound)
//   const {page, complete} = await h.olderPage(fetcher, {beforeTs, beforeId, limit});   // 「更早的 ↑」, no gaps
//
// Backfill (Firebase REST, numbers unquoted):
//   first time   orderBy="ts"&limitToLast=300
//   older page   orderBy="ts"&endAt=<oldest fetched ts − 1>&limitToLast=300   (fewer than 300 back → oldestComplete)
//   afterwards   orderBy="ts"&startAt=<newest fetched ts + 1>
// "Fetched" counts only what backfill pages covered, so messages put() from the stream never hide a gap.

import { decodeChild, encodePayload } from "../core/message.js";
import { createFirebase } from "./firebase.js";

export const DB_NAME = "lulupet";
export const DB_VERSION = 1;
export const BACKFILL_PAGE = 300;
const META_KEY = "meta";

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const byTsId = (a, b) => a.ts - b.ts || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

export const backfillQuery = {
  latest: () => `orderBy=%22ts%22&limitToLast=${BACKFILL_PAGE}`,
  older: (oldestTs) => `orderBy=%22ts%22&endAt=${Math.trunc(oldestTs) - 1}&limitToLast=${BACKFILL_PAGE}`,
  newer: (newestTs) => `orderBy=%22ts%22&startAt=${Math.trunc(newestTs) + 1}`,
};

/** A fetcher for backfill(): (query) → the raw `messages` children (`{key: value}` or null). */
export function messagesFetcher({ databaseURL, pairCode }, { fetch, timeoutMs = 20_000 } = {}) {
  const fb = createFirebase({ databaseURL, pairCode, fetch });
  return (query) => fb.get("messages", { query, timeoutMs });
}

/**
 * @param {{pairCode: string, seat: string}} who
 * @param {object} [o]  backend: createMemoryBackend() / createIDBBackend(); default IndexedDB when there is one,
 *                      else memory. now: clock (decoding drops messages more than a day in the future).
 */
export async function openHistory({ pairCode, seat }, { backend, now = () => Date.now() } = {}) {
  const db = backend ?? (globalThis.indexedDB ? createIDBBackend(globalThis.indexedDB) : createMemoryBackend());
  await db.open();
  let meta = await db.getMeta();
  if (!meta || meta.pairCode !== pairCode || meta.seat !== seat) {
    await db.clear();
    meta = fresh();
    await db.setMeta(meta);
  }
  function fresh() { return { pairCode, seat, oldestComplete: false, oldestFetched: null, syncedTo: null }; }

  /** {key: raw} / [Msg] → [{id, ts, raw}] of the ones that decode. */
  function records(input) {
    const out = [];
    const t = now();
    const add = (key, raw) => {
      const m = decodeChild(key, raw, t);
      if (m) out.push({ id: m.id, ts: m.ts, raw });
    };
    if (Array.isArray(input)) {
      for (const m of input) if (isObj(m) && typeof m.id === "string" && m.id) add(m.id, encodePayload(m));
    } else if (isObj(input)) {
      for (const [k, v] of Object.entries(input)) add(k, v);
    }
    return out;
  }

  // One backfill at a time (a second call waits for the first, then runs on the updated meta).
  let chain = Promise.resolve();
  const serial = (fn) => { const p = chain.then(fn); chain = p.catch(() => {}); return p; };

  const api = {
    get meta() { return { ...meta }; },

    /** Stores messages (dedupe by key: the same key again just overwrites). Resolves the number stored. */
    async put(msgs) {
      const recs = records(msgs);
      if (recs.length) await db.putMany(recs);
      return recs.length;
    },

    /**
     * Up to `limit` messages before (beforeTs, beforeId) — or the newest ones without a bound — decoded, oldest
     * first. Next older page: page({beforeTs: rows[0].ts, beforeId: rows[0].id}).
     */
    async page({ beforeTs = Infinity, beforeId = null, limit = 100 } = {}) {
      const recs = await db.before(beforeTs, beforeId, limit);
      const t = now();
      return recs.map((r) => decodeChild(r.id, r.raw, t)).filter(Boolean).sort(byTsId);
    },

    /**
     * 「更早的 ↑」: up to `limit` messages before (beforeTs, beforeId), oldest first, with no gaps. Messages put()
     * from the stream (e.g. all of mine, delivered by the channel's first GET) can sit far below oldestFetched
     * while TA's in between are still only on the server, so a full local page is trusted only down to
     * oldestFetched; below it, older backfill pages are fetched first (onFetch() before the first request).
     * Resolves {page, complete}. Fetch errors reject.
     */
    async olderPage(fetcher, { beforeTs, beforeId = null, limit = 100, onFetch } = {}) {
      let fetching = false;
      for (;;) {
        const page = await api.page({ beforeTs, beforeId, limit });
        if (meta.oldestComplete) return { page, complete: true };
        if (meta.oldestFetched != null && page.length >= limit && page[0].ts >= meta.oldestFetched) return { page, complete: false };
        const was = meta.oldestFetched;
        if (!fetching) { fetching = true; onFetch?.(); }
        await api.backfill(fetcher, { older: true });
        if (!meta.oldestComplete && meta.oldestFetched === was) return { page: await api.page({ beforeTs, beforeId, limit }), complete: false };   // no progress (never synced)
      }
    },

    /** Newest stored ts, 0 when empty. */
    latestTs: () => db.maxTs(),

    /**
     * One backfill step with `fetcher(query) → {key: raw}|null` (messagesFetcher). Default: the latest page the
     * first time, else everything newer than what backfill has seen; {older: true}: one older page (no-op once
     * oldestComplete). Resolves {added, complete} (complete = nothing older on the server). Fetch errors reject.
     */
    backfill(fetcher, { older = false } = {}) {
      return serial(async () => {
        let mode = meta.syncedTo == null ? "latest" : older ? "older" : "newer";
        if (mode === "older" && (meta.oldestComplete || meta.oldestFetched == null)) return { added: 0, complete: meta.oldestComplete };
        const query = mode === "latest" ? backfillQuery.latest()
          : mode === "older" ? backfillQuery.older(meta.oldestFetched) : backfillQuery.newer(meta.syncedTo);
        const raw = await fetcher(query);
        const children = isObj(raw) ? raw : {};
        const count = Object.keys(children).length;   // what the server returned (decodable or not)
        const recs = records(children);
        if (recs.length) await db.putMany(recs);
        const tsAll = Object.values(children).map((v) => (isObj(v) && Number.isSafeInteger(v.ts) ? v.ts : null)).filter((x) => x != null);
        const next = { ...meta };
        if (mode === "latest" || mode === "older") {
          if (count < BACKFILL_PAGE) next.oldestComplete = true;
          if (tsAll.length) next.oldestFetched = Math.min(...tsAll, next.oldestFetched ?? Infinity);
        }
        if (mode === "latest") {
          next.syncedTo = tsAll.length ? Math.max(...tsAll) : 0;
          if (!tsAll.length) next.oldestFetched = 0;
        } else if (mode === "newer" && tsAll.length) {
          next.syncedTo = Math.max(next.syncedTo, ...tsAll);
        }
        if (next.oldestFetched == null && next.syncedTo != null) next.oldestFetched = next.syncedTo;
        meta = next;
        await db.setMeta(meta);
        return { added: recs.length, complete: meta.oldestComplete };
      });
    },

    /** Deletes every stored message and starts over (same pair code / seat). */
    async clear() {
      await db.clear();
      meta = fresh();
      await db.setMeta(meta);
    },

    close: () => db.close(),
  };
  return api;
}

/** 「清除本机设置」: drop the whole database. */
export function deleteHistory(idb = globalThis.indexedDB) {
  if (!idb) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const r = idb.deleteDatabase(DB_NAME);
    r.onsuccess = () => resolve();
    r.onerror = () => reject(r.error);
    r.onblocked = () => resolve();   // finishes once the other tab closes its connection
  });
}

// ---- backends: {open, close, getMeta, setMeta, putMany([{id, ts, raw}]), before(ts, id, limit), maxTs, clear} ----

/** In memory (Node tests; browsers without IndexedDB). `shared` lets two opens see the same data. */
export function createMemoryBackend(shared = { rows: new Map(), meta: null }) {
  return {
    shared,
    async open() {},
    close() {},
    async getMeta() { return shared.meta ? structuredClone(shared.meta) : null; },
    async setMeta(m) { shared.meta = structuredClone(m); },
    async putMany(recs) { for (const r of recs) shared.rows.set(r.id, structuredClone(r)); },
    async before(ts, id, limit) {
      const below = (r) => r.ts < ts || (r.ts === ts && id != null && r.id < id);
      return [...shared.rows.values()].filter(below).sort(byTsId).slice(-limit).map((r) => structuredClone(r));
    },
    async maxTs() { let m = 0; for (const r of shared.rows.values()) m = Math.max(m, r.ts); return m; },
    async clear() { shared.rows.clear(); shared.meta = null; },
  };
}

const req = (r) => new Promise((resolve, reject) => { r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error); });
const done = (tx) => new Promise((resolve, reject) => {
  tx.oncomplete = () => resolve();
  tx.onerror = () => reject(tx.error);
  tx.onabort = () => reject(tx.error ?? new Error("aborted"));
});

/** IndexedDB (browser). */
export function createIDBBackend(idb) {
  let db = null;
  const tx = (stores, mode) => db.transaction(stores, mode);
  return {
    async open() {
      if (db) return;
      const r = idb.open(DB_NAME, DB_VERSION);
      r.onupgradeneeded = () => {
        const d = r.result;
        if (!d.objectStoreNames.contains("messages")) d.createObjectStore("messages", { keyPath: "id" }).createIndex("ts", ["ts", "id"]);
        if (!d.objectStoreNames.contains("meta")) d.createObjectStore("meta");
      };
      db = await req(r);
      db.onversionchange = () => { db.close(); db = null; };   // deleteHistory() from another tab
    },
    close() { db?.close(); db = null; },
    async getMeta() { return (await req(tx("meta", "readonly").objectStore("meta").get(META_KEY))) ?? null; },
    async setMeta(m) { const t = tx("meta", "readwrite"); t.objectStore("meta").put(m, META_KEY); await done(t); },
    async putMany(recs) {
      const t = tx("messages", "readwrite");
      const s = t.objectStore("messages");
      for (const r of recs) s.put(r);
      await done(t);
    },
    before(ts, id, limit) {
      const idx = tx("messages", "readonly").objectStore("messages").index("ts");
      // [ts, id] keys: strictly below (ts, id); with no id, below every key with that ts (the prefix [ts] sorts first).
      const range = ts === Infinity ? null : IDBKeyRange.upperBound(id != null ? [ts, id] : [ts], true);
      return new Promise((resolve, reject) => {
        const out = [];
        const c = idx.openCursor(range, "prev");
        c.onerror = () => reject(c.error);
        c.onsuccess = () => {
          const cur = c.result;
          if (!cur || out.length >= limit) { resolve(out.reverse()); return; }
          out.push(cur.value);
          cur.continue();
        };
      });
    },
    async maxTs() {
      const idx = tx("messages", "readonly").objectStore("messages").index("ts");
      const cur = await req(idx.openCursor(null, "prev"));
      return cur ? cur.value.ts : 0;
    },
    async clear() {
      const t = tx(["messages", "meta"], "readwrite");
      t.objectStore("messages").clear();
      t.objectStore("meta").clear();
      await done(t);
    },
  };
}
