// Visits (port of Visits / PetLocation / VisitorStayClock / AckQueue in Sources/LuluCore/Visits.swift and the
// focus / remind rules in VisitsRemind.swift). Seconds on any monotonic clock unless named *Ms.
// Message kinds are message.js kinds ("text" | "sticker" | "poke" | "visit" | "remind" | anything else = unknown).
// `rand()` → [0, 1); a pick of n is floor(rand() × n).

import { poolPick, NO_COUPLE } from "./reactions.js";
import { allowsIntimate as policyAllowsIntimate, effectiveMode } from "./policy.js";

export const RUN_SPEED = 220;
export const STAND_GAP = 16;
export const GO_COOLDOWN = 10;
export const BUBBLE_DWELL = 2;
export const BOUNCE_AWAY_SECONDS = 1.6;
export const VISITOR_MAX_STAY = 45;
export const COLLISION_DWELL = 4;
export const COLLISION_WINNER_AWAY = 12;
export const COLLISION_LOSER_AWAY = 12;

export const VISIT_GREETING = "来看看你～想你啦";
export const OFFLINE_LINE = "TA 现在不在哦，等会儿再去找TA吧";
export const DELIVERED_TOAST = "送到啦 ❤️";
export const OFFLINE_QUEUED_LINE = "TA 不在，先放在 TA 那儿啦";
export const NOT_PAIRED_LINE = "还没和 TA 配对哦～把配对码发给 TA，TA 填好就能串门啦";
export const NOT_PAIRED_QUEUED_LINE = "还没和 TA 配对哦～消息先存着，TA 配好就能收到";
export const TRIP_CARD_TITLE = "在TA那边的时候，TA说：";
export const PINNED_HEADER = "TA 留下的话";
export const ACK_TITLE = "收到 ❤️";
export const FOCUS_BOUNCE_LINE = "TA 在专注，先放在 TA 那儿啦";
export const FOCUS_CARD_TITLE = "你专注的时候，TA来过～";

// ---- couple clips

/** "hug" | "kiss" | "nuzzle": visits and 想你 / 抱抱 → hug, 亲亲 / 么么哒 → kiss, else nuzzle. */
export function coupleMove(kind, text = null, label = null) {
  if (kind === "visit") return "hug";
  const words = [text, label].filter((x) => x != null).join(" ");
  if (words.includes("亲亲") || words.includes("么么哒")) return "kiss";
  if (words.includes("想你") || words.includes("抱抱")) return "hug";
  return "nuzzle";
}

/** The preferred move if built, else hug, else null. `available` = array of built couple names. */
export function resolveCouple(preferred, available) {
  if (available.includes(preferred)) return preferred;
  return available.includes("hug") ? "hug" : null;
}

/** From the reaction pool (built clips or "none"; not `last` again), else the built-in rule; null = no clip. */
export function coupleName(pool, preferred, available, last, rand = Math.random) {
  const usable = (pool ?? []).filter((n) => n === NO_COUPLE || available.includes(n));
  const pick = poolPick(usable, last, rand);
  if (pick != null) return pick === NO_COUPLE ? null : pick;
  return resolveCouple(preferred, available);
}

/** Text words that pick a couple pool (win over the kind / default pools); null = none. */
export function keywordCouples(text) {
  if (text == null) return null;
  if (text.includes("亲亲")) return ["kiss", "kiss_2", "kiss_sit"];
  if (text.includes("想你") || text.includes("抱抱")) return ["hug", "hug_sit", "nuzzle", "comfort", "hug_bed"];
  return null;
}

/**
 * The couple clip for a meeting under the content policy; null = no clip (both pets `happy` + hearts).
 * `couples` = {name: {intimate}} (built clips); policy = {myMode, partnerMode, me, partner} (characters).
 * Same character (or solo / partner unknown) → nothing; friend mode → no intimate clip.
 */
export function meetingCouple({ pool, preferred, couples, policy, last = null, rand = Math.random }) {
  const mode = effectiveMode(policy.myMode, policy.partnerMode);
  const paired = mode !== "solo";
  if (!paired || policy.partner == null || policy.partner === policy.me) return null;
  const names = Object.keys(couples ?? {});
  if (policyAllowsIntimate(policy.myMode, policy.partnerMode)) return coupleName(pool, preferred, names, last, rand);
  const allowed = names.filter((n) => !couples[n].intimate);
  const filtered = (pool ?? []).filter((n) => n === NO_COUPLE || allowed.includes(n));
  return coupleName(filtered, preferred, allowed, last, rand);
}

/** Mirror a couple clip so each pet lands on its side; null when both are the same character. */
export function coupleMirrored(luluOnLeft, host, visitor, hostIsLeft) {
  if (host === visitor) return null;
  return ((host === "lulu") === hostIsLeft) !== luluOnLeft;
}

/** Minimum stay after the meeting: poke 4 s, visit 6 s, else 2 s after the last bubble. */
export function dwell(kind) {
  return kind === "poke" ? 4 : kind === "visit" ? 6 : BUBBLE_DWELL;
}

/** Seconds our pet stays at the partner's after running off with a message. */
export function deliveryAway(kind) {
  return ["text", "sticker", "remind"].includes(kind) ? 12 : 10;
}

/** Text and stickers are worth leaving for an offline partner. */
export const sendsWhenOffline = (kind) => kind === "text" || kind === "sticker";

/** Seconds to run `distance` (CSS px on the web stage, scaled by the caller). */
export const runDuration = (distance, speed = RUN_SPEED) => Math.abs(distance) / speed;

// ---- collisions

/** Earlier message goes first; same millisecond → 噜噜 goes first. → "me" | "partner". */
export function resolveCollision(partnerTs, myTs, partner) {
  return partnerTs < myTs || (partnerTs === myTs && partner === "lulu") ? "partner" : "me";
}

/**
 * The dance for my side → {winner, steps}; steps are {step, seconds?, message?}:
 * loser: turnBack, hostVisitor, dwell, leaveTogether, stayAway, comeHome, showPinned; winner: stayAwayFor, comeHomeWithVisitor.
 */
export function collisionPlan(mine, theirs, me) {
  const partner = me === "lulu" ? "lumei" : "lulu";
  if (resolveCollision(theirs.ts, mine.ts, partner) === "partner") {
    return {
      winner: "partner",
      steps: [
        { step: "turnBack" }, { step: "hostVisitor", message: theirs }, { step: "dwell", seconds: COLLISION_DWELL },
        { step: "leaveTogether" }, { step: "stayAway", seconds: COLLISION_LOSER_AWAY }, { step: "comeHome" },
        { step: "showPinned", message: theirs },
      ],
    };
  }
  return { winner: "me", steps: [{ step: "stayAwayFor", seconds: COLLISION_WINNER_AWAY }, { step: "comeHomeWithVisitor", message: theirs }] };
}

/** Only a message whose sender's pet really set off can collide. */
export const isDeliveryTrip = (m) => m?.trip === "deliver";

/**
 * Where my pet is (PetLocation). place: "home" | "leaving" | "away" | "returning".
 * planSend → {type: "deliver", away} | {type: "extendAway", away} | {type: "localMeeting"} | {type: "bounce", send}
 *          | {type: "coolingDown", remaining} | {type: "sendOnly"}.
 * incoming → "showVisitor" | "queueForCard" | "holdUntilHome" | "collision".
 */
export class PetLocation {
  constructor(cooldown = GO_COOLDOWN) {
    this.cooldown = cooldown;
    this.place = "home";
    this.tripTs = null;
    this.bouncing = false;
    this.awayFor = 0;
    this.awayEnds = null;
    this.lastGo = null;
    this.collision = null;
    this.returnAt = null;
  }

  get isOut() { return this.place !== "home"; }

  planSend({ kind, now, visitorHere = false, reachable, partnerDND = false }) {
    if (kind === "visit") {
      if (this.lastGo != null && now - this.lastGo < this.cooldown) return { type: "coolingDown", remaining: this.cooldown - (now - this.lastGo) };
      this.lastGo = now;
    }
    const away = deliveryAway(kind);
    if (this.collision != null) return { type: "sendOnly" };
    if (this.bouncing && this.place !== "home") return { type: "bounce", send: partnerDND || sendsWhenOffline(kind) };
    if (this.place === "away") {
      this.awayEnds = Math.max(this.awayEnds ?? now, now + away);
      return { type: "extendAway", away };
    }
    if (this.place === "leaving") {
      this.awayFor = Math.max(this.awayFor, away);
      return { type: "extendAway", away };
    }
    if (this.place === "home" && visitorHere) return { type: "localMeeting" };
    if (!reachable) {
      if (this.place === "home") this.#begin(true, 0);
      return { type: "bounce", send: partnerDND || sendsWhenOffline(kind) };
    }
    this.#begin(false, away);
    return { type: "deliver", away };
  }

  #begin(bounce, away) {
    this.place = "leaving";
    this.bouncing = bounce;
    this.tripTs = null;
    this.awayFor = away;
    this.awayEnds = null;
  }

  /** The delivery's message went out with this ts. */
  sent(ts) {
    if (this.place !== "leaving" || this.bouncing || this.tripTs != null) return;
    this.tripTs = ts;
  }

  reachedAway(now) {
    if (this.place !== "leaving" || this.bouncing) return;
    this.place = "away";
    this.awayEnds = this.returnAt ?? now + this.awayFor;
    this.returnAt = null;
  }

  beginCollision(winner) { this.collision = winner; }
  endCollision() { this.collision = null; this.returnAt = null; }
  setReturn(time) { if (this.place === "away") this.awayEnds = time; else this.returnAt = time; }
  leaveAgain(away) { this.place = "leaving"; this.bouncing = false; this.awayFor = away; this.awayEnds = null; }
  awayRemaining(now) { return this.awayEnds == null ? null : Math.max(0, this.awayEnds - now); }

  startReturn() {
    if (this.place === "home") return;
    this.place = "returning";
    this.awayEnds = null;
  }

  arrivedHome() {
    this.place = "home";
    this.returnAt = null;
    this.bouncing = false;
    this.tripTs = null;
    this.awayFor = 0;
    this.awayEnds = null;
  }

  incoming(m) {
    if (this.collision != null) return "queueForCard";
    switch (this.place) {
      case "home": return "showVisitor";
      case "returning": return this.bouncing || isDeliveryTrip(m) ? "holdUntilHome" : "queueForCard";
      default:
        if (this.place === "leaving" && this.bouncing) return "holdUntilHome";
        return isDeliveryTrip(m) && this.tripTs != null ? "collision" : "queueForCard";
    }
  }

  /** Plain snapshot (for vectors / debugging). */
  get state() {
    return { place: this.place, tripTs: this.tripTs, bouncing: this.bouncing, awayFor: this.awayFor, awayEnds: this.awayEnds, collision: this.collision };
  }
}

// ---- visitor stay (v0.7.4)

/** Counts the visitor's stay against `limit`. */
export class VisitorStayClock {
  constructor(limit = VISITOR_MAX_STAY) { this.limit = limit; this.startedAt = null; }
  get isRunning() { return this.startedAt != null; }
  start(now) { if (this.startedAt == null) this.startedAt = now; }
  restart(now) { this.startedAt = now; }
  stop() { this.startedAt = null; }
  get deadline() { return this.startedAt == null ? null : this.startedAt + this.limit; }
  remaining(now) { return this.deadline == null ? null : Math.max(0, this.deadline - now); }
  expired(now) { return this.deadline != null && now >= this.deadline - 0.001; }
}

/** "wait" | "leave" | "leaveLeavingBubbles". */
export function stayDecision(now, stayUntil, bubblesWaiting, clock) {
  if (clock.expired(now)) return bubblesWaiting ? "leaveLeavingBubbles" : "leave";
  if (now < stayUntil - 0.01 || bubblesWaiting) return "wait";
  return "leave";
}

// ---- focus / remind (VisitsRemind)

/** Receiver: my own focus round holds incoming visits (paused does not). pomodoro state in seconds. */
export function isHoldingForFocus(state, now) {
  return state?.phase === "focus" && state.until != null && now < state.until;
}

/** Sender: the partner is online and focusing (a stale focus after sign-off doesn't count). */
export function partnerFocusHolds(focus, partnerOnline, nowMs) {
  return !!partnerOnline && !!focus && nowMs < focus.until;
}

/** 「噜妹正在专注 🍅 还剩 12 分钟」. */
export function partnerFocusLine(name, focus, nowMs) {
  const left = Math.max(1, Math.floor((Math.max(0, focus.until - nowMs) + 59_999) / 60_000));
  return `${name}正在专注 🍅 还剩 ${left} 分钟`;
}

/** 「TA 喝啦 💧」 / 「TA 站起来啦」. */
export const remindAckLine = (kind) => (kind === "water" ? "TA 喝啦 💧" : "TA 站起来啦");
