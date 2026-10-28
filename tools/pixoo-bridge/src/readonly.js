// The ONLY way the bridge talks to Firebase. It is a strictly read-only client:
//   - it never writes presence/<seat> (that would show the other person as online),
//   - never writes read/<seat> (that would mark messages read and suppress their notifications),
//   - never registers under devices/ or push/ (that would break push routing).
// Two independent guards make that hold even if a future change calls the wrong method:
//   1. `readOnlyFetch` wraps fetch and refuses any method but GET / HEAD before a byte leaves the machine;
//      the same wrapped fetch is handed to the EventSource polyfill (SSE is a GET).
//   2. `createReadOnlyFirebase` exposes only `get` / `openEventSource`; put / patch / del throw.
// The repo's createFirebase turns fetch exceptions into FirebaseError("network"), so a violation is also reported
// through `onViolation` (the bridge logs it as an error) instead of only being swallowed as a network error.

import { EventSource as EventSourcePolyfill } from "eventsource";
import { createFirebase } from "../../../web/js/net/firebase.js";

export class ReadOnlyViolation extends Error {
  constructor(method) {
    super(`pixoo-bridge is read-only: refused a ${method} request to Firebase`);
    this.name = "ReadOnlyViolation";
    this.method = method;
  }
}

const ALLOWED = new Set(["GET", "HEAD"]);

/** fetch → fetch that throws ReadOnlyViolation for anything but GET / HEAD (checked on the Request object too). */
export function readOnlyFetch(fetchImpl, onViolation = () => {}) {
  if (typeof fetchImpl !== "function") throw new TypeError("fetch implementation required");
  return function guardedFetch(input, init = {}) {
    const fromRequest = typeof input === "object" && input !== null && typeof input.method === "string" ? input.method : null;
    const method = String(init?.method ?? fromRequest ?? "GET").toUpperCase();
    if (!ALLOWED.has(method) || (init && init.body != null)) {
      const err = new ReadOnlyViolation(init && init.body != null && ALLOWED.has(method) ? `${method}+body` : method);
      try { onViolation(err); } catch { /* ignore */ }
      throw err;
    }
    return fetchImpl(input, init);
  };
}

/**
 * Read-only view of the repo's Firebase REST client: {url, get, openEventSource} plus put / patch / del that throw.
 * `fetch` / `EventSource` are injectable for tests; by default Node's fetch and the `eventsource` polyfill
 * (given the same guarded fetch).
 */
export function createReadOnlyFirebase({ databaseURL, pairCode, fetch: fetchImpl, EventSource: ESImpl, onViolation } = {}) {
  const guarded = readOnlyFetch(fetchImpl ?? globalThis.fetch.bind(globalThis), onViolation);
  const ES = ESImpl ?? EventSourcePolyfill;
  class GuardedEventSource extends ES {
    constructor(url, init = {}) {
      super(url, { ...init, fetch: guarded });
    }
  }
  const fb = createFirebase({ databaseURL, pairCode, fetch: guarded, EventSource: GuardedEventSource });
  const deny = (name) => () => {
    const err = new ReadOnlyViolation(name);
    try { onViolation?.(err); } catch { /* ignore */ }
    throw err;
  };
  return Object.freeze({
    url: fb.url,
    get: fb.get,
    openEventSource: fb.openEventSource,
    put: deny("PUT"),
    patch: deny("PATCH"),
    del: deny("DELETE"),
  });
}
