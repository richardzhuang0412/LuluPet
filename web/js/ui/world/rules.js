// The one place the world touches the pure rules (W1's web/js/core modules). Everything in world/ imports rules from
// here. W1 works in SECONDS (like the Swift it ports) and takes `rand()` → [0, 1); the world works in milliseconds
// and passes `roll(n)` → 0..<n. This file converts, so the rest of world/ never cares.
// The world never imports js/net (spec §8 static check).

import * as idle from "../../core/idle.js";
import * as weatherlook from "../../core/weatherlook.js";
import * as pose from "../../core/pose.js";
import * as reactions from "../../core/reactions.js";
import * as visits from "../../core/visits.js";
import * as sounds from "../../core/sounds.js";
import * as think from "../../core/think.js";

const S = 1000;
/** A world `roll(n)` as a W1 `rand()`. */
const randOf = (roll) => () => Math.min(0.999999, Math.max(0, roll(1_000_000) / 1_000_000));

// ---- idle ---------------------------------------------------------------------------------------------------------
export const IDLE = Object.freeze({
  dozeAfterMs: idle.DOZE_AFTER * S, quietAfterMs: idle.QUIET_AFTER * S,
  fidgetMinMs: idle.FIDGET_INTERVAL[0] * S, fidgetMaxMs: idle.FIDGET_INTERVAL[1] * S, retryMs: idle.RETRY * S,
});
export const fidgetDelayMs = (unit) => idle.fidgetDelay(null, unit) * S;
export const restPose = ({ dozing, quiet, dnd }) => idle.restPose(!!dozing, !!quiet, !!dnd);
export const poolPick = (pool, last, roll) => reactions.poolPick(pool, last, randOf(roll));
export const pickFidget = (plain, weather, lastPlain, lastWeather, roll) => weatherlook.pickWeatherFidget(plain, weather, lastPlain, lastWeather, roll);
export const clipLooks = (look) => weatherlook.clipLooks(look);

// ---- pose -----------------------------------------------------------------------------------------------------------
export const derivePose = (s) => pose.derivePose(s);
/** → "idleLoop" | "dozeStill" | "quietStill" | "focusClip" | "focusStill" | "dndStill" | {weather: look}. */
export function thinkLook(raw, hasFocusClip, hasWeatherClip) {
  const p = typeof raw === "string" ? raw : "idle";
  const look = pose.thinkPoseLook(p, hasFocusClip, (l) => weatherlook.LOOKS.includes(l) && !!hasWeatherClip?.(l));
  return look.startsWith("weatherClip:") ? { weather: look.slice("weatherClip:".length) } : look;
}

// ---- reactions ------------------------------------------------------------------------------------------------------
export const CLICK_CHANCE = reactions.CLICK_CHANCE;
export const parseReactions = (obj) => reactions.parseReactions(obj);
export const reactionFor = (table, kind, stickerId) => reactions.reactionFor(table, kind, stickerId ?? null);
export const visitorClips = (reaction, character) => reactions.visitorClips(reaction, character);
export const clickClips = (table, character) => reactions.clickClips(table, character);
export const remindReactionKey = (kind) => reactions.remindReactionKey(kind);

// ---- visits ---------------------------------------------------------------------------------------------------------
export const VISITS = Object.freeze({
  runSpeed: visits.RUN_SPEED, standGap: visits.STAND_GAP, goCooldownMs: visits.GO_COOLDOWN * S,
  bubbleDwellMs: visits.BUBBLE_DWELL * S, visitorMaxStayMs: visits.VISITOR_MAX_STAY * S,
  bounceAwayMs: visits.BOUNCE_AWAY_SECONDS * S, collisionDwellMs: visits.COLLISION_DWELL * S,
  collisionWinnerAwayMs: visits.COLLISION_WINNER_AWAY * S, collisionLoserAwayMs: visits.COLLISION_LOSER_AWAY * S,
  visitGreeting: visits.VISIT_GREETING, offlineLine: visits.OFFLINE_LINE, offlineQueuedLine: visits.OFFLINE_QUEUED_LINE,
  notPairedLine: visits.NOT_PAIRED_LINE, notPairedQueuedLine: visits.NOT_PAIRED_QUEUED_LINE,
  focusBounceLine: visits.FOCUS_BOUNCE_LINE, deliveredToast: visits.DELIVERED_TOAST,
  tripCardTitle: visits.TRIP_CARD_TITLE, focusCardTitle: visits.FOCUS_CARD_TITLE, awayCardTitle: "你不在的时候，TA来过～",
  pinnedHeader: visits.PINNED_HEADER, ackTitle: visits.ACK_TITLE,
  /** Web: after 收到 on the visitor's last bubble it lingers this long (hearts), then waves and runs off. */
  ackLingerMs: 900,
});

/** W1's PetLocation on the world's millisecond clock; plans come back as {action, away?, send?, remaining?} (ms). */
export class PetLocation {
  #l = new visits.PetLocation(visits.GO_COOLDOWN);
  get place() { return this.#l.place; }
  get bouncing() { return this.#l.bouncing; }
  get collision() { return this.#l.collision; }
  get tripTs() { return this.#l.tripTs; }        // a message ts (ms), stored as given
  get isOut() { return this.#l.isOut; }
  planSend(kind, now, { visitorHere = false, reachable = false, partnerDND = false } = {}) {
    const p = this.#l.planSend({ kind, now: now / S, visitorHere, reachable, partnerDND });
    const out = { action: p.type };
    if (p.away != null) out.away = p.away * S;
    if (p.remaining != null) out.remaining = p.remaining * S;
    if (p.send != null) out.send = p.send;
    return out;
  }
  sent(ts) { this.#l.sent(ts); }
  reachedAway(now) { this.#l.reachedAway(now / S); }
  beginCollision(winner) { this.#l.beginCollision(winner); }
  endCollision() { this.#l.endCollision(); }
  setReturn(at) { this.#l.setReturn(at / S); }
  leaveAgain(awayMs) { this.#l.leaveAgain(awayMs / S); }
  awayRemaining(now) { const r = this.#l.awayRemaining(now / S); return r == null ? null : r * S; }
  startReturn() { this.#l.startReturn(); }
  arrivedHome() { this.#l.arrivedHome(); }
  incoming(m) { return this.#l.incoming(m); }
}

export const coupleMove = (kind, text, label) => visits.coupleMove(kind, text ?? null, label ?? null);
export const keywordCouples = (text) => (typeof text === "string" ? visits.keywordCouples(text) : null);
/**
 * policy = {allowsCoupleClips (false when both pets are the same character), allowsIntimate} → couple name or null.
 * W1 decides from modes; the world already knows the verdicts, so they are passed as modes it maps back.
 */
export function meetingCouple({ pool, preferred, couples, policy, last = null, roll }) {
  if (!policy?.allowsCoupleClips) return null;
  const mode = policy.allowsIntimate ? "couple" : "friend";
  return visits.meetingCouple({
    pool, preferred, couples: couples ?? {}, last: last ?? null, rand: randOf(roll),
    policy: { myMode: mode, partnerMode: mode, me: "lulu", partner: "lumei" },
  });
}
export const coupleMirrored = (luluOnLeft, host, visitor, hostIsLeft) => visits.coupleMirrored(luluOnLeft, host, visitor, hostIsLeft);
export const dwellMs = (kind) => visits.dwell(kind) * S;
/** {winner, steps} with each step's `seconds` also as `ms`. */
export function collisionPlan(mine, theirs, mySeat) {
  const plan = visits.collisionPlan(mine, theirs, mySeat);
  return { ...plan, steps: plan.steps.map((s) => (s.seconds != null ? { ...s, ms: s.seconds * S } : s)) };
}
/** → "wait" | "leave" | "leaveLeavingBubbles" (all times ms; clockDeadline null = the 45 s clock isn't running). */
export function stayDecision({ now, stayUntil, bubblesWaiting, clockDeadline }) {
  const clock = { expired: (n) => clockDeadline != null && n >= clockDeadline / S - 0.001 };
  return visits.stayDecision(now / S, stayUntil / S, !!bubblesWaiting, clock);
}

// ---- sounds ---------------------------------------------------------------------------------------------------------
export const meetingKeys = (reaction, clipSound, fallback, couple) => sounds.meetingKeys(reaction, clipSound ?? null, fallback, couple ?? null);
export const stickerSound = (id) => sounds.forSticker(id ?? null);

// ---- think ----------------------------------------------------------------------------------------------------------
export const THINK = Object.freeze({
  durationMs: think.DURATION * S, peekDurationMs: think.PEEK_DURATION * S, hoverDelayMs: think.HOVER_DELAY * S, cooldownMs: think.COOLDOWN * S,
});
export const thinkIdleDelayMs = (unit) => think.idleDelay(unit) * S;
export const thinkShouldShow = (reason, ctx, lastShown, now) => think.shouldShow(reason, ctx, lastShown == null ? null : lastShown / S, now / S);
export const peekVerdict = (ctx, everSeen) => think.peekVerdict(ctx, everSeen);

// ---- tool clips -----------------------------------------------------------------------------------------------------
/** Fallback when the manifest has no toolClips (v1 assets): none; the caller plays `happy`. */
export const toolClipPool = () => [];
