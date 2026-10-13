// Pure rules for data that crosses the wire. Port of Sources/LuluCore/WireLimits.swift
// (WireLimits, QueueFold, OutboxPolicy, StreamBackoff) plus the PairChannel timing constants.
// No DOM, no network.

/** Message text, counted in UTF-16 code units (what the Firebase rules' `.length` counts). */
export const MAX_TEXT = 500;
/** stickerId / outfit / trip / remind / ackOf / answer, presence strings. */
export const MAX_FIELD = 64;
/** A message child whose JSON is larger than this (UTF-8 bytes, as LuluCore serializes it) is dropped. */
export const MAX_ENCODED_BYTES = 4096;
/** `ts` more than this far ahead of now is ignored on receive. */
export const FUTURE_SLACK_MS = 86_400_000;
/** Backlog length kept one by one; older ones are folded (counted, marked read). */
export const QUEUE_CAP = 50;

/** PairChannel timing (seconds). */
export const OUTBOX_RETRY_S = 5;
export const MAX_BACKOFF_S = 30;
export const MISCONFIGURED_RETRY_S = 60;
export const STREAM_IDLE_TIMEOUT_S = 90;
/** A connection that lived this long resets the reconnect backoff to 1 s. */
export const STABLE_AFTER_S = 30;
/** Message PUT timeout / presence request timeout (seconds). */
export const SEND_TIMEOUT_S = 20;
export const PRESENCE_TIMEOUT_S = 10;

let segmenter = null;
function graphemes(s) {
  if (typeof Intl !== "undefined" && Intl.Segmenter) {
    segmenter ??= new Intl.Segmenter(undefined, { granularity: "grapheme" });
    return Array.from(segmenter.segment(s), (x) => x.segment);
  }
  return Array.from(s); // code points: never splits a surrogate pair
}

/** `s` cut to at most `max` UTF-16 units, never inside a character (emoji / combining sequences stay whole). */
export function clipUTF16(s, max) {
  if (typeof s !== "string") return s;
  if (s.length <= max) return s;
  let out = "";
  for (const ch of graphemes(s)) {
    if (out.length + ch.length > max) break;
    out += ch;
  }
  return out;
}

/** Optional id-like field: null/undefined → null; a non-string or over `max` UTF-16 units → null (a cut id would name something else). */
export function field(s, max = MAX_FIELD) {
  if (typeof s !== "string" || s.length > max) return null;
  return s;
}

/** Presence strings: cut (still useful, just shorter). Non-strings → null. */
export function clipped(s, max = MAX_FIELD) {
  return typeof s === "string" ? clipUTF16(s, max) : null;
}

/** True when `ts` is further ahead of `now` than a skewed clock can explain. */
export function isFuture(ts, now) {
  return ts > now + FUTURE_SLACK_MS;
}

/** The unread cursor can never sit beyond what the rules allow, so a bad value can't stall the stream. */
export function clampCursor(ts, now) {
  return Math.min(ts, now + FUTURE_SLACK_MS);
}

/** Fold a long queue: keep the newest `cap`; the older ones are only counted ("+N"). */
export function queueFold(items, cap = QUEUE_CAP) {
  if (!(cap >= 0) || items.length <= cap) return { folded: [], kept: items.slice() };
  const cut = items.length - cap;
  return { folded: items.slice(0, cut), kept: items.slice(cut) };
}

/**
 * What to do with the head of the outbox after a failed send: "retry" | "park".
 * `status` = HTTP status of the failed request (null/undefined for network errors / timeouts: always retry).
 * 400 / 413 / 422: this message itself is bad → park. 401 / 403: park only while the stream is connected.
 */
export function outboxVerdict(status, streamConnected) {
  switch (status) {
    case 400: case 413: case 422: return "park";
    case 401: case 403: return streamConnected ? "park" : "retry";
    default: return "retry";
  }
}

/** Reconnect delay (seconds) after a connection ended: reset to 1 only when it lived ≥ 30 s, else unchanged. */
export function backoffAfter(current, livedFor) {
  return livedFor >= STABLE_AFTER_S ? 1 : current;
}

/** The delay to use after the one just waited: doubling, at most 30 s. */
export function nextBackoff(current) {
  return Math.min(current * 2, MAX_BACKOFF_S);
}

/** Strictly increasing send timestamps: `max(now, lastSentTs + 1)`. */
export function nextSendTs(now, lastSentTs) {
  return Math.max(now, (lastSentTs || 0) + 1);
}
