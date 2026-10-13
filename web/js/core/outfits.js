// Outfits (port of OutfitSeason / OutfitRules / OutfitHistory / OutfitChoice in Sources/LuluCore/Outfits.swift).
// `seasons` = outfit → season name ("springFestival" | "christmas"; anything else is never in season).
// Dates are instants (ms) read as a local calendar day in `tz`. Randomness is injected: `rand()` → [0, 1)
// (Math.random in the app); a pick of n is floor(rand() × n), as Swift's `Int.random(in: 0..<n)` maps its generator.

import { dayString, daysBetween } from "./tz.js";

export const SEASONS = ["springFestival", "christmas"];
export const SPRING_FESTIVAL_WINDOW = 15;
export const SEASONAL_WEIGHT = 4;
export const HISTORY_MAX = 10;
/** 正月初一 per Gregorian year (extend before 2036). */
export const CHINESE_NEW_YEAR = Object.freeze({
  2026: "02-17", 2027: "02-06", 2028: "01-26", 2029: "02-13", 2030: "02-03",
  2031: "01-23", 2032: "02-11", 2033: "01-31", 2034: "02-19", 2035: "02-08",
});

/** Whether local day of `ms` is in `season`. */
export function inSeason(season, ms, tz) {
  const day = dayString(ms, tz);
  const year = +day.slice(0, 4), month = +day.slice(5, 7);
  if (season === "christmas") return month === 12;
  if (season === "springFestival") {
    const ny = CHINESE_NEW_YEAR[year];
    return !!ny && Math.abs(daysBetween(`${year}-${ny}`, day)) <= SPRING_FESTIVAL_WINDOW;
  }
  return false;
}

export function isEligible(outfit, seasons, ms, tz) {
  const raw = seasons?.[outfit];
  return raw == null ? true : inSeason(raw, ms, tz);
}

export function isInSeason(outfit, seasons, ms, tz) {
  return seasons?.[outfit] != null && isEligible(outfit, seasons, ms, tz);
}

export function eligible(outfits, seasons, ms, tz) {
  return outfits.filter((o) => isEligible(o, seasons, ms, tz));
}

/** The pin honoured at launch: kept if it exists (even out of season); a vanished one → preferred outfit; null = no pin. */
export function resolvePin(pinned, outfits, seasons, ms, tz) {
  if (pinned == null) return null;
  if (outfits.includes(pinned)) return pinned;
  return eligible(outfits, seasons, ms, tz)[0] ?? outfits[0] ?? null;
}

/** Launch outfit when not pinned: first in-season seasonal, else first eligible, else first. */
export function launchOutfit(outfits, seasons, ms, tz) {
  return outfits.find((o) => isInSeason(o, seasons, ms, tz)) ?? eligible(outfits, seasons, ms, tz)[0] ?? outfits[0] ?? null;
}

/** Rotation / 换个造型: weighted random eligible outfit other than `current` (in-season seasonal weigh 4); null = none. */
export function nextOutfit(current, outfits, seasons, ms, tz, rand = Math.random) {
  const candidates = eligible(outfits, seasons, ms, tz).filter((o) => o !== current);
  const weights = candidates.map((o) => (isInSeason(o, seasons, ms, tz) ? SEASONAL_WEIGHT : 1));
  const total = weights.reduce((a, b) => a + b, 0);
  if (total <= 0) return null;
  let roll = Math.floor(rand() * total);
  for (let i = 0; i < candidates.length; i++) {
    if (roll < weights[i]) return candidates[i];
    roll -= weights[i];
  }
  return candidates[candidates.length - 1];
}

/** A visitor wears the outfit its message names if we have it, else `fallback`. */
export function visitorOutfit(requested, available, fallback) {
  return requested != null && available.includes(requested) ? requested : fallback ?? null;
}

// ---- 换回上一个 (stack, most recent first; local key `lulupet.outfitHistory`)

export function decodeHistory(raw) {
  return (Array.isArray(raw) ? raw.filter((s) => typeof s === "string") : []).slice(0, HISTORY_MAX);
}

/** Leaving `outfit`: on top, older copy dropped, at most 10. */
export function historyPush(stack, outfit) {
  return [outfit, ...stack.filter((o) => o !== outfit)].slice(0, HISTORY_MAX);
}

/** → {stack, outfit}: the most recent entry that still exists and isn't `current` (skipped ones are dropped). */
export function historyPop(stack, valid, current) {
  const s = stack.slice();
  while (s.length) {
    const o = s.shift();
    if (o !== current && valid.includes(o)) return { stack: s, outfit: o };
  }
  return { stack: s, outfit: null };
}

export function canGoBack(stack, valid, current) {
  return stack.some((o) => o !== current && valid.includes(o));
}

/** 选择造型 rows: [{name, title, current, enabled}] — seasonal ones say 节日限定 and need their season (or the pin). */
export function choices(outfits, labels, seasons, current, pinned, ms, tz) {
  return outfits.map((o) => {
    const seasonal = seasons?.[o] != null;
    const label = labels?.[o] ?? o;
    return {
      name: o,
      title: seasonal ? `${label}（节日限定）` : label,
      current: o === current,
      enabled: !seasonal || o === pinned || isInSeason(o, seasons, ms, tz),
    };
  });
}
