// Tiny leveled logger that never prints a secret: every line passes through `redact`, which replaces the pair code,
// the database URL (and its host) with "***". The pair code is part of every Firebase URL, so anything that might
// echo a URL (fetch errors, EventSource errors) must go through here.

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40, silent: 100 };

export function makeRedactor(secrets = []) {
  const needles = [];
  for (const s of secrets) {
    if (typeof s !== "string" || s.length < 4) continue;
    needles.push(s);
    try {
      const u = new URL(s);
      if (u.host) needles.push(u.host);
    } catch { /* not a URL */ }
    const enc = encodeURIComponent(s);
    if (enc !== s) needles.push(enc);
  }
  needles.sort((a, b) => b.length - a.length);
  return (text) => {
    let out = String(text);
    for (const n of needles) out = out.split(n).join("***");
    return out;
  };
}

function fmt(v) {
  if (v instanceof Error) return v.stack || `${v.name}: ${v.message}`;
  if (typeof v === "string") return v;
  try { return JSON.stringify(v); } catch { return String(v); }
}

/** `{debug, info, warn, error}`; `sink(line)` defaults to stderr (systemd puts it in the journal). */
export function createLogger({ level = "info", secrets = [], sink, clock = () => new Date() } = {}) {
  const redact = makeRedactor(secrets);
  const min = LEVELS[level] ?? LEVELS.info;
  const out = sink ?? ((line) => process.stderr.write(line + "\n"));
  const log = (lvl) => (...args) => {
    if (LEVELS[lvl] < min) return;
    const line = `${clock().toISOString()} ${lvl.toUpperCase().padEnd(5)} ${args.map(fmt).join(" ")}`;
    out(redact(line));
  };
  return { debug: log("debug"), info: log("info"), warn: log("warn"), error: log("error"), redact, level };
}

export const silentLogger = createLogger({ level: "silent" });
