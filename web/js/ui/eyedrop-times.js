// 「一天几次」 changed on the 眼药水 card: keep the times the user already has (hand-edited ones included) and only
// add or take away at the end. Pure (tested in web/tests/ui.eyedrop-times.test.mjs).

import { parseTime, formatTime, suggestedTimes, validateTimes, SLOT_LIMITS } from "../core/eyedrops.js";

const DAY_START = 7 * 60, DAY_END = 22 * 60;   // where new times may go (half-hour grid)

/**
 * `times` ("HH:mm") → `n` times, sorted; none yet → the suggested set. Existing times never move (today's check-ins
 * are keyed by them). Fewer → the latest ones go. More → a new one goes at 22:00 when the day's last time leaves room, else where it
 * is farthest from the others (07:00–22:00 on the half hour, earliest on a tie), never closer than 30 minutes;
 * nothing fits → the list stays shorter.
 */
export function resizeTimes(times, n) {
  const list = (Array.isArray(times) ? times : []).filter((t) => parseTime(t) != null).sort((a, b) => parseTime(a) - parseTime(b));
  const k = Math.min(SLOT_LIMITS.maxSlots, Math.max(1, Math.trunc(Number(n) || 0)));
  if (!list.length) return suggestedTimes(k);
  if (k <= list.length) return list.slice(0, k);
  const mins = list.map(parseTime);
  while (mins.length < k) {
    const last = Math.max(...mins);
    if (last <= DAY_END - SLOT_LIMITS.minGapMin) { mins.push(DAY_END); continue; }   // room at the end of the day
    let best = null, bestGap = -1;
    for (let m = DAY_START; m <= DAY_END; m += 30) {
      const gap = Math.min(...mins.map((x) => Math.abs(x - m)));
      if (gap > bestGap) { best = m; bestGap = gap; }
    }
    if (best == null || bestGap < SLOT_LIMITS.minGapMin) break;
    mins.push(best);
  }
  return mins.sort((a, b) => a - b).map(formatTime);
}

/**
 * 「改时间」: the inputs edit a draft; the whole set is checked when focus leaves the time inputs or on 「改好了」, so
 * moving every time later one by one never trips the 30-minute rule midway. → {save: sorted times | null, error}:
 * save when the draft is valid and differs from `saved`; error (ERRORS text) when the final set is invalid, in which
 * case the last valid set stays saved.
 */
export function commitTimes(draft, saved) {
  const v = validateTimes(draft);
  if (!v.ok) return { save: null, error: v.error };
  const same = v.times.length === saved.length && v.times.every((t, i) => t === saved[i]);
  return { save: same ? null : v.times, error: null };
}
