// The `store` the channel takes (spec §3, §10): a thin localStorage wrapper. Keys are given without the prefix
// ("lastReadTs", "outbox", …); values are JSON. Every access is try/catch: bad / missing data reads as null.

export function createLocalStore(storage = globalThis.localStorage, prefix = "lulupet.") {
  return {
    get(key) {
      try {
        const raw = storage.getItem(prefix + key);
        return raw == null ? null : JSON.parse(raw);
      } catch { return null; }
    },
    set(key, value) {
      try { storage.setItem(prefix + key, JSON.stringify(value)); } catch { /* quota / private mode */ }
    },
    remove(key) {
      try { storage.removeItem(prefix + key); } catch { /* ignore */ }
    },
  };
}

/** Same interface, in memory (tests, or when localStorage is unavailable). */
export function createMemoryStore(initial = {}) {
  const m = new Map(Object.entries(initial).map(([k, v]) => [k, JSON.stringify(v)]));
  return {
    get: (k) => (m.has(k) ? JSON.parse(m.get(k)) : null),
    set: (k, v) => { m.set(k, JSON.stringify(v)); },
    remove: (k) => { m.delete(k); },
  };
}
