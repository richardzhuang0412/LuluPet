// Dedicated Worker metronome (spec §7.1). Chrome throttles main-thread timers of a page hidden for 5+ minutes to
// one wake-up a minute; worker timers are not, and a `message` event wakes the main thread at once. The main thread
// (scheduler.js) keeps the real timer list; this worker only says "tick".
//   postMessage({cmd: "start", ms})  start (or retime) ticking every `ms`
//   postMessage({cmd: "stop"})       stop
let timer = null;
self.onmessage = (e) => {
  const { cmd, ms } = e.data || {};
  if (timer !== null) { clearInterval(timer); timer = null; }
  if (cmd === "start") timer = setInterval(() => self.postMessage("tick"), Math.max(100, Number(ms) || 1000));
};
