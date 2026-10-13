// Weather looks (port of WeatherLook.of / clipLooks in Sources/LuluCore/Weather.swift and WeatherPlan in
// WeatherPlan.swift). snapshot = weather.js `parseForecast` result. `roll(n)` → a random integer in 0..<n.

import { pickFidget } from "./idle.js";

export const LOOKS = Object.freeze(["rain", "snow", "hot", "cold", "windy", "cloudy"]);
export const HOT_AT = 30;
export const COLD_AT = 5;
export const WINDY_AT = 30;
export const WEATHER_ONE_IN = 3;

/** Priority: rain / snow > hot / cold > windy > cloudy; null = nothing special. */
export function weatherLook(s) {
  if (!s) return null;
  if (["rain", "drizzle", "thunder"].includes(s.condition)) return "rain";
  if (s.condition === "snow") return "snow";
  if (s.temperature >= HOT_AT) return "hot";
  if (s.temperature <= COLD_AT) return "cold";
  if (s.windSpeed != null && s.windSpeed >= WINDY_AT) return "windy";
  if (s.condition === "cloudy" || s.condition === "fog") return "cloudy";
  return null;
}

/** Whose clips to use: snow falls back to cold. */
export const clipLooks = (look) => (look === "snow" ? ["snow", "cold"] : [look]);

/**
 * The next fidget out of `plain` regular and `weather` weather clips → {kind: "plain" | "weather", index} or null.
 * With weather clips about one in three is a weather one; with no regular fidgets, always.
 */
export function pickWeatherFidget(plain, weather, lastPlain, lastWeather, roll) {
  if (weather > 0 && (plain === 0 || roll(WEATHER_ONE_IN) === 0)) {
    const i = pickFidget(weather, lastWeather, roll);
    return i == null ? null : { kind: "weather", index: i };
  }
  const i = pickFidget(plain, lastPlain, roll);
  return i == null ? null : { kind: "plain", index: i };
}

/** A refresh job exists only for a set city AND something that shows weather. */
export function needsRefresh(hasPlace, partnerHasPlace, composeOpen, hasClips) {
  return hasPlace && (partnerHasPlace || composeOpen || hasClips);
}
