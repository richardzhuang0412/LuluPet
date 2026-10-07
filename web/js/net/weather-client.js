// Open-Meteo current weather (port of LuluSync/WeatherClient.current): same request as the Mac, 10 s timeout.
// No NWS (spec §9). `place` is a presence `place` object: {name, latitude, longitude, timezone, admin?, country?}.

import { parseForecast } from "./_shim_core.js";   // TEMP → ../core/weather.js

export const FORECAST_BASE = "https://api.open-meteo.com/v1/forecast";
export const WEATHER_TIMEOUT_MS = 10_000;

/** The forecast URL; query items sorted by name, coordinates at two decimals (like `WeatherClient.url`). */
export function forecastURL(place, base = FORECAST_BASE) {
  const lat = Number(place?.latitude), lon = Number(place?.longitude);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) throw new Error("place without coordinates");
  const q = {
    current: "temperature_2m,weather_code,cloud_cover,wind_speed_10m,is_day",
    daily: "temperature_2m_max,temperature_2m_min",
    forecast_days: "1",
    latitude: lat.toFixed(2),
    longitude: lon.toFixed(2),
    timezone: "auto",
  };
  const qs = Object.keys(q).sort().map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(q[k])}`).join("&");
  return `${base}?${qs}`;
}

/**
 * Current conditions + today's high / low → W1's parseForecast(json) result plus `fetchedAt` (ms since epoch).
 * Throws on network error, timeout (10 s), non-2xx, or a forecast without a temperature.
 * Options (tests): fetch, base, timeoutMs, now.
 */
export async function fetchCurrent(place, { fetch: fetchImpl, base, timeoutMs = WEATHER_TIMEOUT_MS, now = Date.now } = {}) {
  const doFetch = fetchImpl ?? globalThis.fetch.bind(globalThis);
  const res = await doFetch(forecastURL(place, base), {
    signal: AbortSignal.timeout(timeoutMs),
    credentials: "omit",
    referrerPolicy: "no-referrer",
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const snapshot = parseForecast(await res.json());
  return { ...snapshot, fetchedAt: now() };
}
