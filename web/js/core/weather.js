// Weather model and rules. Port of Sources/LuluCore/Weather.swift (WeatherCondition, WeatherParse.snapshot,
// WeatherRefresh) and the Open-Meteo request of LuluSync/WeatherClient.current. Times in Unix SECONDS.
//
// Snapshot: {condition, temperature, high: number|null, low: number|null, windSpeed: number|null, isDay, fetchedAt}

import { round2 } from "./presence.js";

export { round2 };

export const CONDITIONS = ["clear", "partlyCloudy", "cloudy", "fog", "drizzle", "rain", "snow", "thunder"];
export const OVERCAST_CLOUD_COVER = 85;
export const REFRESH_INTERVAL_S = 1800;
export const STALE_AFTER_S = 3 * 3600;
export const AGE_SHOWN_FROM_S = 45 * 60;
export const UNAVAILABLE_TEXT = "暂时拿不到天气";
export const MAX_CACHED_PLACES = 4;

/** WMO weather code (+ optional cloud cover %) → condition. Unknown codes read as cloudy. */
export function conditionFromWMO(code, cloudCover = null) {
  const wmo = typeof code === "number" && Number.isFinite(code) ? Math.trunc(code) : -1;
  if (wmo === 3 && typeof cloudCover === "number" && cloudCover < OVERCAST_CLOUD_COVER) return "partlyCloudy";
  if (wmo === 0 || wmo === 1) return "clear";
  if (wmo === 2) return "partlyCloudy";
  if (wmo === 3) return "cloudy";
  if (wmo === 45 || wmo === 48) return "fog";
  if (wmo >= 51 && wmo <= 57) return "drizzle";
  if ((wmo >= 61 && wmo <= 67) || (wmo >= 80 && wmo <= 82)) return "rain";
  if ((wmo >= 71 && wmo <= 77) || wmo === 85 || wmo === 86) return "snow";
  if (wmo >= 95 && wmo <= 99) return "thunder";
  return "cloudy";
}

export function emoji(condition, isDay) {
  switch (condition) {
    case "clear": return isDay ? "☀️" : "🌙";
    case "partlyCloudy": return isDay ? "⛅" : "☁️";
    case "cloudy": return "☁️";
    case "fog": return "🌫";
    case "drizzle": return isDay ? "🌦" : "🌧";
    case "rain": return "🌧";
    case "snow": return "🌨";
    case "thunder": return "⛈";
    default: return "☁️";
  }
}

const LABELS = { clear: "晴", partlyCloudy: "多云", cloudy: "阴", fog: "雾", drizzle: "毛毛雨", rain: "雨", snow: "雪", thunder: "雷雨" };
export function label(condition) {
  return LABELS[condition] ?? "阴";
}

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const n = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** Open-Meteo forecast JSON (parsed) → snapshot, or null when malformed (no `current.temperature_2m`).
 *  `now` = fetchedAt in Unix seconds (defaults to the current time). */
export function parseForecast(json, now = Date.now() / 1000) {
  if (!isObj(json) || !isObj(json.current) || n(json.current.temperature_2m) === null) return null;
  const cur = json.current;
  const daily = isObj(json.daily) ? json.daily : null;
  const first = (k) => (daily && Array.isArray(daily[k]) ? n(daily[k][0]) : null);
  const isDay = n(cur.is_day);
  return {
    condition: conditionFromWMO(n(cur.weather_code) ?? -1, n(cur.cloud_cover)),
    temperature: cur.temperature_2m,
    high: first("temperature_2m_max"),
    low: first("temperature_2m_min"),
    windSpeed: n(cur.wind_speed_10m),
    isDay: isDay === null ? true : Math.trunc(isDay) !== 0,
    fetchedAt: now,
  };
}

/** The Open-Meteo request (same parameters as the Mac, query keys sorted). */
export function forecastURL(latitude, longitude) {
  const q = {
    current: "temperature_2m,weather_code,cloud_cover,wind_speed_10m,is_day",
    daily: "temperature_2m_max,temperature_2m_min",
    forecast_days: "1",
    latitude: latitude.toFixed(2),
    longitude: longitude.toFixed(2),
    timezone: "auto",
  };
  // Values are digits, letters, '.', '-', '_' and ',' only (left as is, like URLComponents does).
  return "https://api.open-meteo.com/v1/forecast?" + Object.keys(q).sort().map((k) => `${k}=${q[k]}`).join("&");
}

/** `weatherCache` key: the rounded coordinates "lat,lon" with two decimals. */
export function cacheKey(place) {
  return `${place.latitude.toFixed(2)},${place.longitude.toFixed(2)}`;
}

/** Never fetched, 30 minutes passed, or the clock went back. */
export function isDue(last, now) {
  if (last == null) return true;
  return now < last || now - last >= REFRESH_INTERVAL_S;
}

/** null below 45 minutes, else 「50 分钟前」 / 「2 小时前」. */
export function ageLabel(fetchedAt, now) {
  const age = now - fetchedAt;
  if (age < AGE_SHOWN_FROM_S) return null;
  return age < 3600 ? `${Math.floor(age / 60)} 分钟前` : `${Math.floor(age / 3600)} 小时前`;
}

/** More than 3 hours old: shown greyed / as 暂时拿不到天气. */
export function isStale(fetchedAt, now) {
  return now - fetchedAt > STALE_AFTER_S;
}
