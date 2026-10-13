// localStorage under the `lulupet.` prefix (spec §3) for the UI's own keys; the channel gets W2's createLocalStore
// (same prefix, same JSON values). Every access is try/catch'd; bad JSON = missing.

import { makeDeviceId, parseConfig } from "./deps.js";

const PREFIX = "lulupet.";

export const store = {
  get(k, fallback = null) {
    try {
      const raw = localStorage.getItem(PREFIX + k);
      return raw == null ? fallback : JSON.parse(raw);
    } catch {
      return fallback;
    }
  },
  set(k, v) {
    try { localStorage.setItem(PREFIX + k, JSON.stringify(v)); } catch { /* quota / blocked */ }
  },
  remove(k) {
    try { localStorage.removeItem(PREFIX + k); } catch { /* blocked */ }
  },
  /** 「清除本机设置」: every lulupet.* key. */
  clearAll() {
    try {
      for (const k of Object.keys(localStorage)) if (k.startsWith(PREFIX)) localStorage.removeItem(k);
    } catch { /* blocked */ }
  },
};

export function deviceId() {
  let id = store.get("deviceId");
  if (typeof id !== "string" || !id.startsWith("web-")) {
    id = makeDeviceId();
    store.set("deviceId", id);
  }
  return id;
}

/** {databaseURL, pairCode, seat} (normalized by W1's validateConfig) or null. */
export const loadConfig = () => parseConfig(store.get("config"));
