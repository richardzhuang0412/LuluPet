// The one place the UI touches W1 (js/core) and W2 (js/net). Everything else in js/ui imports from here, so the
// shapes the UI relies on are pinned in one file.

import * as message from "../core/message.js";
import * as remind from "../core/remind.js";
import * as presence from "../core/presence.js";
import * as weather from "../core/weather.js";
import * as paircode from "../core/paircode.js";
import * as config from "../core/config.js";
import * as away from "../core/away.js";
import * as policy from "../core/policy.js";
import * as reminder from "../core/reminder.js";
import * as stickers from "../core/stickers.js";
import * as eyedrops from "../core/eyedrops.js";
import * as tz from "../core/tz.js";
import * as dnd from "../core/dnd.js";
import * as pomodoro from "../core/pomodoro.js";
import * as outfits from "../core/outfits.js";
import * as pose from "../core/pose.js";
import * as history from "../core/history.js";
import * as weatherlook from "../core/weatherlook.js";
import * as visits from "../core/visits.js";
import * as think from "../core/think.js";
import { createWorld } from "./world/world.js";
import { createSound } from "./world/sound.js";
import { fetchCurrent } from "../net/weather-client.js";
import { createLocalStore } from "../net/store.js";
export { createScheduler } from "../net/scheduler.js";
export { createToolsSync } from "../net/tools-sync.js";
export { openHistory, messagesFetcher, deleteHistory } from "../net/history-db.js";

const params = new URLSearchParams(location.search);
/** Dev only: "fake" / "pip" run the scripted fake channel (js/ui/dev, not deployed). */
export const DEV = params.get("dev") || "";

/** {createChannel, createStore}. */
export async function loadNet() {
  if (DEV === "fake" || DEV === "pip") {
    return { createChannel: (await import("./dev/fake-channel.js")).createFakeChannel, createStore: createLocalStore };
  }
  return { createChannel: (await import("../net/channel.js")).createChannel, createStore: createLocalStore };
}

/** Where W3's generated assets live. */
export const assetsBase = () => new URL("../../assets/", import.meta.url).href;

// ---- facade -----------------------------------------------------------------------------------------------------

export const SEATS = message.SEATS;
export const UNKNOWN_KIND = message.UNKNOWN_KIND_PLACEHOLDER;
export const clampText = (s) => message.clampText(s);
/** A sticker this page has no picture for: its name from the message's fallback text (「［表情］么么哒」), never the raw id. */
export const unknownStickerText = (msg) => { const l = message.stickerFallbackLabel(msg); return l ? `［表情］${l}` : "［新表情］"; };
export const stickerFallbackLabel = (msg) => message.stickerFallbackLabel(msg);

/** Firebase key of a decoded message. */
export const msgKey = (m) => m.id;

// channel.send() sets from / character / outfit / trip / ts / id; the builders only need the seat.
export const build = {
  visit: (from) => ({ from, kind: "visit", ts: Date.now(), v: message.CURRENT_SCHEMA_VERSION, trip: message.TRIP_LOCAL }),
  text: (text, from) => message.textMsg(text, { from }, Date.now()),
  sticker: (id, label, from) => message.stickerMsg(id, label, { from }, Date.now()),
  poke: (from) => message.pokeMsg({ from }, Date.now()),
  remind: (kind, from) => message.remindMsg(kind, { from }, Date.now()),
  /** late = 「终于做到了」 (a local re-remind after 等会儿 was answered 喝了 / 好的, spec §4.3). */
  reply: (kind, answer, from, ackOf, late = false) => {
    const m = remind.replyMessage(kind, answer, from, ackOf, Date.now());
    if (late && answer === "now") m.late = true;
    return m;
  },
};

/** {kind:"water"|"stand", answer:"now"|"later", late} or null. */
export const decodeReply = (m) => remind.decodeReply(m);
export const replyLine = (r) => remind.replyLine(r);
/** TA's reminder (not a reply) still answerable 马上 / 等会儿 (≤ 2 h old). */
export const isReplyable = (m, now) => remind.isReplyable(m, now);
/** "water" | "stand" | null for TA's reminder. */
export const reminderKind = (m) => remind.reminderKind(m);
export const remindBubble = (kind, sender) => remind.remindBubble(kind, sender);

export const dndActive = (dnd, now) => presence.dndActive(dnd, now);
export const focusActive = (focus, now) => presence.focusActive(focus, now);
export const focusMinutesLeft = (focus, now) => presence.focusMinutesLeft(focus, now);

export const stickerRules = {
  shownBar: (stored, visible, counts, recent) => stickers.shownBar(stored, visible, counts, recent),
  seedQuickBar: (favorites, counts, recent, library) => stickers.seedQuickBar(favorites, counts, recent, library),
  equipped: (id, stored, visible) => stickers.equipped(id, stored, visible),   // → {list, replaced}
  removed: (id, stored) => stickers.removed(id, stored),
  recorded: (id, ts, recent) => stickers.recorded(id, ts, recent),
  visibleIds: (catalog, intimate) => stickers.visibleIds(catalog, intimate),
  grouped: (list) => stickers.grouped(list),                                    // → [{group, title, stickers}]
  defaultFavorites: stickers.DEFAULT_FAVORITES,
};

export const weatherText = {
  /** fetchCurrent() → parseForecast() result; condition mapped from the WMO code when absent. */
  condition: (snap) => snap.condition ?? weather.conditionFromWMO(snap.code, snap.cloudCover),
  emoji: (condition, isDay) => weather.emoji(condition, isDay),
  label: (condition) => weather.label(condition),
  round2: (x) => weather.round2(x),
  // W1 works in seconds; weather-client's fetchedAt is ms.
  ageLabel: (fetchedAtMs, nowMs) => weather.ageLabel(fetchedAtMs / 1000, nowMs / 1000),
  isStale: (fetchedAtMs, nowMs) => weather.isStale(fetchedAtMs / 1000, nowMs / 1000),
  unavailable: weather.UNAVAILABLE_TEXT,
};
/** {…parseForecast(), fetchedAt (ms)}; 10 s timeout. */
export const fetchWeather = (place) => fetchCurrent(place, { timeoutMs: 10_000 });

export const pairCode = { normalize: (s) => paircode.normalize(s), isValid: (s) => paircode.isValid(s) };

/** Canonical database URL, or {reason} when invalid. */
export function checkDatabaseURL(s) {
  const v = config.validateDatabaseURL(s);
  return v.ok ? { url: v.url } : { reason: v.reason };
}
/** Stored config object → normalized {databaseURL, pairCode, seat} or null. */
export function parseConfig(obj) {
  const v = config.validateConfig(obj);
  return v.ok ? v.config : null;
}
export const makeDeviceId = () => config.makeDeviceId(crypto.randomUUID());

/** Away card: parts like ["💬 3", "🧸 2", "💧 叫你喝水"] (stale pokes / replies left out). */
export const awayParts = (msgs, now, me) => away.summaryParts(away.summarize(msgs, now, me));
export const isStaleAway = (m, now) => away.isStale(m, now);
export const allowsIntimate = (myMode, partnerMode) => policy.allowsIntimate(myMode, partnerMode);

/** My own reminders (Unix seconds; states are plain JSON, functions return new states). */
export const reminders = {
  fresh: (intervalS) => reminder.newReminder(intervalS),
  load: (obj) => reminder.decodeReminder(obj),
  tick: (state, nowS, active, blocked = false) => reminder.tick(state, nowS, active, blocked),   // → {state, due}
  resume: (state, nowS) => reminder.resume(state, nowS),
  done: (state, nowS) => reminder.done(state, nowS),
  snooze: (state, nowS) => reminder.snooze(state, nowS),
  copy: (kind) => reminder.reminderCopy(kind),                                // {title, comply, snooze}
  defaults: reminder.DEFAULT_INTERVALS,
  awayThreshold: reminder.AWAY_THRESHOLD,
};

export const decodeMessages = (obj, now = Date.now()) => message.decodeChildren(obj, now);
export const normalizePose = (p) => presence.normalizePose(p);
export const reminderStatus = (state, nowS, active, blocked = false) => reminder.status(state, nowS, active, blocked);

// ---- v2 modules (spec §7) -----------------------------------------------------------------------------------------
// W1's pure ports and W5's world, as namespaces. The controllers in js/ui call them directly; W1 works in Unix SECONDS
// for 勿扰 / 番茄钟 / reminders (like the Mac's UserDefaults) and in ms for eye drops and presence.

export const v2 = { eyedrops, tz, dnd, pomodoro, outfits, pose, history, weatherlook, visits, think, createWorld, createSound };
/** The local IANA time zone (W1 functions take it explicitly). */
export const TZ = Intl.DateTimeFormat().resolvedOptions().timeZone;
