// One-shot timers that keep firing while the tab is in the background (spec §7.1).
// Every timer is armed twice: a normal setTimeout (precise while visible) and an entry checked on each tick of
// tick-worker.js (a worker's timers are not throttled in a hidden tab). Whichever comes first fires it, once.
// Interface used by the net layer (tests inject their own):
//   { now(), setTimeout(fn, ms) → handle, clearTimeout(handle), dispose() }

export function createScheduler({ tickMs = 1000, useWorker = typeof Worker !== "undefined" } = {}) {
  const timers = new Map();   // handle -> {due, fn, native}
  let next = 1;
  let worker = null;

  const fire = (h) => {
    const t = timers.get(h);
    if (!t) return;
    timers.delete(h);
    clearTimeout(t.native);
    try { t.fn(); } catch (e) { console.error("[lulu] timer", e); }
  };

  if (useWorker) {
    try {
      worker = new Worker(new URL("./tick-worker.js", import.meta.url));
      worker.onmessage = () => {
        const now = Date.now();
        for (const [h, t] of [...timers]) if (t.due <= now) fire(h);
      };
      worker.postMessage({ cmd: "start", ms: tickMs });
    } catch {
      worker = null;   // no Worker / blocked: plain timers (throttled to 1/min in a hidden tab, still < 75 s)
    }
  }

  return {
    now: () => Date.now(),
    setTimeout(fn, ms) {
      const h = next++;
      const delay = Math.max(0, ms);
      timers.set(h, { due: Date.now() + delay, fn, native: setTimeout(() => fire(h), delay) });
      return h;
    },
    clearTimeout(h) {
      const t = timers.get(h);
      if (!t) return;
      clearTimeout(t.native);
      timers.delete(h);
    },
    dispose() {
      for (const t of timers.values()) clearTimeout(t.native);
      timers.clear();
      if (worker) { worker.postMessage({ cmd: "stop" }); worker.terminate(); worker = null; }
    },
    get pending() { return timers.size; },
  };
}
