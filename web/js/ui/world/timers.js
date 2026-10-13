// One-shot timers that can move between windows. The world's timers run on the window that shows it (a Document PiP
// window's own timers are not throttled with the hidden tab); when the world moves (mountIn), every pending timer is
// re-armed on the new window with the time it had left. Wall clock (Date.now) so a slept laptop catches up.

export function createTimers(initialWin) {
  let win = initialWin;
  let seq = 0;
  const live = new Map();   // id → {fn, due, handle}

  function arm(id, t) {
    t.handle = win.setTimeout(() => {
      live.delete(id);
      t.fn();
    }, Math.max(0, t.due - Date.now()));
  }

  return {
    /** Runs `fn` after `ms`; returns an id for cancel(). */
    after(ms, fn) {
      const id = ++seq;
      const t = { fn, due: Date.now() + Math.max(0, ms), handle: 0 };
      live.set(id, t);
      arm(id, t);
      return id;
    },
    cancel(id) {
      const t = id && live.get(id);
      if (!t) return;
      win.clearTimeout(t.handle);
      live.delete(id);
    },
    /** Moves every pending timer to `next` (same due times). */
    rehome(next) {
      if (next === win) return;
      for (const t of live.values()) win.clearTimeout(t.handle);
      win = next;
      for (const [id, t] of live) arm(id, t);
    },
    get win() { return win; },
    get size() { return live.size; },
    clear() {
      for (const t of live.values()) win.clearTimeout(t.handle);
      live.clear();
    },
  };
}
