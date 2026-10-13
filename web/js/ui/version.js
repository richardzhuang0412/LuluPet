// version.json polling (spec §7.4): hourly and whenever the page becomes visible again; a different version than the
// one loaded → 「网页版有更新 · 刷新」.

const HOUR = 3600_000;

async function fetchVersion() {
  try {
    const r = await fetch(new URL("../../version.json", import.meta.url), { cache: "no-cache" });
    if (!r.ok) return null;
    const v = (await r.json())?.version;
    return typeof v === "string" && v.length <= 32 ? v : null;
  } catch { return null; }
}

export async function watchVersion({ onVersion, onUpdate }) {
  const loaded = await fetchVersion();
  onVersion(loaded);
  let last = Date.now();
  const check = async () => {
    last = Date.now();
    const v = await fetchVersion();
    if (v && loaded && v !== loaded) onUpdate(v);
  };
  setInterval(check, HOUR);
  document.addEventListener("visibilitychange", () => { if (!document.hidden && Date.now() - last > 60_000) check(); });
}
