// Visits on the stage (port of VisitController): TA's pet runs in for TA's message, meets mine (couple clip or both
// happy + hearts), plays its reaction, says it (bubbles), stays (minimum dwell, at most 45 s), waves and runs off;
// my pet runs off with my sends (deliver / bounce / come back 「送到啦 ❤️」), and the collision dance when both pets set
// off at once. Rules: rules.js (Visits / PetLocation / reactions / sounds). Times are ms (Date.now).

import { Actor } from "./pet.js";
import { playCouple } from "./couple.js";
import { nameOf } from "./dom.js";
import {
  VISITS, PetLocation, coupleMove, keywordCouples, meetingCouple, coupleMirrored, dwellMs, collisionPlan, stayDecision,
  reactionFor, visitorClips, remindReactionKey, poolPick, meetingKeys, stickerSound,
} from "./rules.js";
import { decodeReply, replyLine, reminderKind, remindBubble } from "../../core/remind.js";
import { UNKNOWN_KIND_PLACEHOLDER, stickerFallbackLabel } from "../../core/message.js";

const other = (c) => (c === "lumei" ? "lulu" : "lumei");
const rollOf = (n) => Math.floor(Math.random() * n);

export class Visits {
  /** w = the world context (see world.js). */
  constructor(w) {
    this.w = w;
    this.state = "absent";          // absent | entering | meeting | staying | leaving
    this.location = new PetLocation();
    this.visitor = null;
    this.visitorLook = null;        // "character/outfit"
    this.visitorCharacter = null;
    this.plan = null;
    this.reset0();
    this.lastCouple = null;
    this.lastVisitorClip = null;
    this.epoch = 0;
  }

  reset0() {
    this.pending = [];
    this.pendingDwell = 0;
    this.pendingMove = "hug";
    this.pendingHearts = false;
    this.pendingCouples = [];
    this.pendingVisitorClip = null;
    this.pendingSounds = [];
    this.pendingFallback = [];
    this.pendingDone = [];
    this.nextMeeting = null;
    this.visitStay = null;
    this.stayUntil = 0;
    this.stayDeadline = null;
    this.leaveTimer = 0;
    this.limitTimer = 0;
    this.queuedWhileAway = [];
    this.tripMessages = [];
    this.homeX = null;
    this.awayTimer = 0;
    this.bounceTimer = 0;
    this.danceTimer = 0;
    this.homeNotice = null;
    this.tripMessage = null;
    this.dance = [];
    this.danceEvent = null;
    this.afterMeeting = null;
    this.deliverDone = null;
  }

  log(s) { this.w.log?.("visit: " + s); }
  get now() { return Date.now(); }
  get me() { return this.w.me; }
  get speed() { return VISITS.runSpeed * (this.w.baseH / 170); }
  get gap() { return VISITS.standGap * (this.w.baseH / 170); }
  get homeState() { return this.location.place; }
  /** Anything visit-related on screen or in motion. */
  get active() { return this.state !== "absent" || this.homeState !== "home"; }

  /** Wraps a completion so it does nothing after a reset (B7). */
  cur(f) { const e = this.epoch; return (...a) => { if (this.epoch === e) f(...a); }; }
  after(ms, f) { return this.w.timers.after(ms, this.cur(f)); }
  cancel(id) { this.w.timers.cancel(id); }

  /** Who is visiting: the message's character, else TA's as far as known, else the character that isn't mine. */
  characterFor(msg) {
    if (this.state !== "absent" && this.visitorCharacter) return this.visitorCharacter;
    if (msg?.character === "lulu" || msg?.character === "lumei") return msg.character;
    const p = this.w.policy();
    return p.partnerCharacter === "lulu" || p.partnerCharacter === "lumei" ? p.partnerCharacter : other(this.w.myCharacter);
  }

  // ---- messages → events -------------------------------------------------------------------------------------------

  /** The bubble a partner message shows (null for a poke). */
  bubbleItem(msg, onAnswered) {
    const name = nameOf(this.characterFor(msg));
    const header = `${name}说：`;
    const base = { header, msg };
    switch (msg.kind) {
      case "poke": return null;
      case "text": return { ...base, text: msg.text ?? "" };
      case "sticker": {
        const s = this.w.catalog.stickerById(msg.stickerId);
        const tilde = (l) => (l && /[～!！]$/.test(l) ? l : l ? l + "～" : null);
        // A sticker this page doesn't have yet (newer Mac): a soft placeholder with its name from the fallback text.
        if (!s) return { ...base, sticker: { url: null, caption: tilde(stickerFallbackLabel(msg)) ?? "发来一个新表情～", note: "网页版还没有这个表情" } };
        return { ...base, sticker: { url: this.w.catalog.url(s.file), caption: tilde(s.label || "") } };
      }
      case "visit": return { ...base, text: VISITS.visitGreeting, autoHide: dwellMs("visit") };
      case "remind": {
        const kind = reminderKind(msg);
        if (!kind) return msg.ackOf != null ? null : { ...base, text: UNKNOWN_KIND_PLACEHOLDER };
        const rb = remindBubble(kind, name);
        return {
          ...base, header: rb.header, text: rb.line,
          buttons: [{ title: rb.comply, primary: true }, { title: rb.snooze }],
          onButton: (i) => onAnswered?.(i === 0 ? "now" : "later"),
        };
      }
      default: return { ...base, text: UNKNOWN_KIND_PLACEHOLDER };
    }
  }

  /** The meeting for message `msg` (reaction pools, keyword pools, sounds, the sender's outfit). */
  event(msg, { live, local = false, bubble } = {}) {
    const stickerId = msg.kind === "remind" ? (msg.remind ? remindReactionKey(msg.remind) : null) : msg.stickerId;
    let reaction = reactionFor(this.w.catalog.reactions, msg.kind, stickerId);
    const kw = msg.kind === "text" ? keywordCouples(msg.text) : null;
    if (kw) reaction = { couples: kw, visitor: reaction?.visitor || {}, sounds: reaction?.sounds || [] };
    const label = msg.kind === "sticker" ? this.w.catalog.stickerById(msg.stickerId)?.label : null;
    const fb = msg.kind === "sticker" ? stickerSound(msg.stickerId) : null;
    return {
      msg, kind: msg.kind, live: !!live, local, bubble: bubble ?? null,
      move: coupleMove(msg.kind, msg.text, label),
      reaction, sounds: reaction?.sounds || [], fallback: fb ? [fb] : [], outfit: msg.outfit,
      done: null,
    };
  }

  // ---- TA visits us ------------------------------------------------------------------------------------------------

  partner(e) {
    if (this.homeState !== "home") {
      this.queuedWhileAway.push(e);
      this.log(`${e.kind} queued: my pet is out (${this.homeState})`);
      return;
    }
    const visitor = this.prepareVisitor(e);
    if (!visitor || this.w.mood.hidden) {
      this.log(`no visitor sprites, ${e.kind} on my pet`);
      this.onNoVisitor(e);
      return;
    }
    const dwell = dwellMs(e.kind);
    switch (this.state) {
      case "absent":
        if (e.local) { this.log("local meeting dropped: no visitor here"); e.done?.("dropped"); return; }
        this.arrive(e, visitor);
        break;
      case "entering":
      case "meeting":
        if (e.bubble) this.pending.push(e.bubble);
        this.pendingDwell = Math.max(this.pendingDwell, dwell);
        this.pendingHearts = this.pendingHearts || e.kind === "poke";
        if (e.live) this.nextMeeting = { ...e, bubble: null };
        else this.pendingDone.push(e);
        break;
      case "staying":
        if (e.live) { this.nextMeeting = null; this.meetAgain(e); } else {
          if (e.bubble) this.w.bubbles.enqueue(e.bubble);
          this.stayUntil = this.now + dwell;
          e.done?.("shown");
          this.scheduleLeaveCheck();
        }
        break;
      case "leaving": {
        this.state = "entering";
        this.pending = [];
        this.load(e);
        this.log(`${e.kind} while leaving: visitor turns back`);
        visitor.run(this.plan.standX, this.speed, this.cur(() => (e.live ? this.meet() : this.stay())));
        break;
      }
    }
  }

  /** No visitor can be drawn: the message shows on my pet. */
  onNoVisitor(e) {
    if (e.kind === "poke") { this.me.hearts(); this.w.sound(["poke"], this.characterFor(e.msg)); }
    if (e.bubble) this.w.bubbles.enqueue({ ...e.bubble, atHome: true });
    e.done?.("shown");
  }

  load(e) {
    if (e.bubble) this.pending.push(e.bubble);
    this.pendingDwell = dwellMs(e.kind);
    this.pendingMove = e.move;
    this.pendingHearts = e.kind === "poke";
    this.pendingCouples = e.reaction?.couples || [];
    this.pendingVisitorClip = this.pickVisitorClip(e);
    this.pendingSounds = e.sounds;
    this.pendingFallback = e.fallback;
    this.pendingDone.push(e);
  }

  pickVisitorClip(e) {
    if (!e.reaction || !this.visitor) return null;
    const pool = visitorClips(e.reaction, this.characterFor(e.msg)).filter((n) => this.visitor.clips?.has(n));
    const name = poolPick(pool, this.lastVisitorClip, rollOf);
    if (name) this.lastVisitorClip = name;
    return name;
  }

  prepareVisitor(e) {
    const character = this.characterFor(e?.msg);
    const p = this.w.policy();
    const cat = this.w.catalog;
    const outfit = cat.outfitOf(character, e?.outfit, p.partnerOutfit);
    const clips = cat.outfit(character, outfit);
    if (!clips?.idle) return null;
    if (!this.visitor) {
      this.visitor = new Actor(this.w, "visitor");
      this.visitor.setHidden(true);
      this.w.layer.append(this.visitor.el);
      this.visitor.el.addEventListener("click", (ev) => { ev.stopPropagation(); this.w.visitorClicked(); });
    }
    if (this.state === "absent") {
      this.visitor.setBaseHeight(this.w.baseH);
      const look = character + "/" + clips.outfit;
      if (this.visitorLook !== look) { this.visitor.setClips(clips); this.visitorLook = look; }
      this.visitorCharacter = character;
    }
    return this.visitor;
  }

  arrival() {
    const W = this.w.width, host = this.me.rect(), vw = this.visitor.idleWidth;
    const entry = this.me.x < W / 2 ? "left" : "right";
    const leftX = host.left - this.gap - vw / 2, rightX = host.right + this.gap + vw / 2;
    const leftFits = leftX - vw / 2 >= 0, rightFits = rightX + vw / 2 <= W;
    const stand = entry === "left" ? (leftFits || !rightFits ? "left" : "right") : (rightFits || !leftFits ? "right" : "left");
    return { entrySide: entry, entryX: this.offX(entry, vw), standX: stand === "left" ? leftX : rightX, standSide: stand };
  }
  offX(side, width) { return side === "left" ? -width / 2 - 12 : this.w.width + width / 2 + 12; }

  arrive(e, visitor) {
    this.startVisitor(e, this.arrival(), visitor);
    visitor.run(this.plan.standX, this.speed, this.cur(() => this.meet()));
  }

  startVisitor(e, plan, visitor) {
    this.plan = plan;
    this.state = "entering";
    this.pending = [];
    this.pendingDone = [];
    this.nextMeeting = null;
    this.load(e);
    const stays = visitor.clips.stays;
    this.visitStay = stays.length ? stays[rollOf(stays.length)].name : null;
    visitor.setRest("idle");
    visitor.setX(plan.entryX);
    visitor.setHidden(false);
    this.w.sound(["arrive"], this.visitorCharacter);
    this.log(`visitor entering from ${plan.entrySide}, stands ${plan.standSide} (${e.kind}, ${e.live ? "live" : "backlog"})`);
  }

  meet() {
    if (this.state !== "entering" || !this.visitor) return;
    this.state = "meeting";
    const p = this.w.policy();
    const policy = { allowsCoupleClips: !!p.allowsCoupleClips && this.w.myCharacter !== this.visitorCharacter, allowsIntimate: !!p.allowsIntimate };
    const name = meetingCouple({ pool: this.pendingCouples, preferred: this.pendingMove, couples: this.w.catalog.couples, policy, last: this.lastCouple, roll: rollOf });
    this.lastCouple = name ?? "none";
    const cc = name ? this.w.catalog.couple(name) : null;
    this.w.sound(meetingKeys(this.pendingSounds, cc?.sound, this.pendingFallback, name), this.visitorCharacter);
    this.pendingSounds = [];
    this.pendingFallback = [];
    if (cc) {
      this.log(`meeting: couple ${name}`);
      this.couple(cc, this.cur(() => this.stay()));
    } else {
      this.log("meeting: no couple clip, both happy + hearts");
      this.bothHappy(this.cur(() => this.stay()));
    }
  }

  couple(cc, done) {
    const me = this.me, v = this.visitor;
    const hostIsLeft = me.x < v.x;
    const mirrored = coupleMirrored(cc.luluOnLeft, this.w.myCharacter, this.visitorCharacter, hostIsLeft) ?? false;
    me.setHidden(true);
    v.setHidden(true);
    me.busy = true;
    playCouple(this.w, {
      couple: cc, centerX: (me.x + v.x) / 2, mirrored, baseH: this.w.baseH,
      done: () => {
        me.setHidden(false);
        v.setHidden(false);
        me.busy = false;
        me.playAction("happy");
        done();
      },
    });
  }

  bothHappy(done) {
    this.me.playAction("happy");
    this.me.hearts();
    this.visitor.hearts();
    this.visitor.playAction("happy", done);
  }

  stay() {
    const v = this.visitor;
    if (!v || (this.state !== "entering" && this.state !== "meeting")) return;
    this.state = "staying";
    v.setRest(this.visitStay ? { stay: this.visitStay } : "idle");
    const done = this.pendingDone;
    this.pendingDone = [];
    if (this.afterMeeting) {
      const next = this.afterMeeting;
      this.afterMeeting = null;
      if (this.pendingVisitorClip) this.playVisitorClip(this.pendingVisitorClip);
      this.pendingVisitorClip = null;
      if (this.pendingHearts) { v.hearts(); this.w.sound(["poke"], this.visitorCharacter); }
      this.pendingHearts = false;
      this.pending = [];
      next();
      return;
    }
    const startNext = this.cur(() => {
      if (this.state !== "staying" || !this.nextMeeting) return;
      const n = this.nextMeeting;
      this.nextMeeting = null;
      this.meetAgain(n);
    });
    if (!(this.pendingVisitorClip && this.playVisitorClip(this.pendingVisitorClip, startNext)) && this.nextMeeting) this.after(800, startNext);
    if (this.nextMeeting) this.after(6000, startNext);
    this.pendingVisitorClip = null;
    if (this.pendingHearts) { v.hearts(); this.w.sound(["poke"], this.visitorCharacter); }
    const items = this.pending;
    this.pending = [];
    this.pendingHearts = false;
    items.forEach((b) => this.w.bubbles.enqueue(b));
    this.stayUntil = this.now + this.pendingDwell;
    if (this.stayDeadline == null) this.stayDeadline = this.now + this.w.visitorMaxStayMs;
    this.log(`visitor staying (≥ ${this.pendingDwell} ms, ${items.length} bubble(s), pose ${this.visitStay || "idle"})`);
    done.forEach((e) => e.done?.("shown"));
    this.w.bubbles.layout();
    this.scheduleLeaveCheck();
    this.cancel(this.limitTimer);
    this.limitTimer = this.after(Math.max(50, this.stayDeadline - this.now), () => this.checkLeave());
  }

  playVisitorClip(name, done) {
    const v = this.visitor;
    if (!v?.playNamed(name, done)) return false;
    const key = v.clips.named(name)?.sound;
    if (key) this.w.sound([key], this.visitorCharacter);
    return true;
  }

  meetAgain(e) {
    if (this.state !== "staying") return;
    this.cancel(this.leaveTimer);
    this.stayDeadline = this.now + this.w.visitorMaxStayMs;
    this.state = "entering";
    this.pending = [];
    this.load(e);
    this.meet();
  }

  /**
   * A bubble went (收到 / clicked / auto-hide). When it was the visitor's last one, the visitor answers at once —
   * hearts — and sets off after a short beat instead of standing there for the rest of its minimum stay.
   */
  bubbleDismissed(item) {
    if (item && !item.atHome && this.state === "staying" && this.visitor && !this.w.bubbles.find((b) => !b.atHome)) {
      this.visitor.hearts();
      this.stayUntil = Math.min(this.stayUntil, this.now + VISITS.ackLingerMs);
      this.scheduleLeaveCheck();
      return;
    }
    this.checkLeave();
  }

  scheduleLeaveCheck() {
    this.cancel(this.leaveTimer);
    this.leaveTimer = this.after(Math.max(50, this.stayUntil - this.now), () => this.checkLeave());
  }

  checkLeave() {
    if (this.state !== "staying" || this.location.collision) return;
    const visitorBubbles = this.w.bubbles.find((b) => !b.atHome);
    const d = stayDecision({ now: this.now, stayUntil: this.stayUntil, bubblesWaiting: !!visitorBubbles, clockDeadline: this.stayDeadline });
    if (d === "wait") { if (this.now < this.stayUntil - 10) this.scheduleLeaveCheck(); return; }
    if (d === "leaveLeavingBubbles") {
      this.nextMeeting = null;
      const n = this.w.bubbles.leaveAllForHost();
      this.log(`time up: visitor leaves, ${n} bubble(s) stay as 「${VISITS.pinnedHeader}」`);
    }
    this.leave();
  }

  leave() {
    const v = this.visitor, plan = this.plan;
    if (!v || !plan) return;
    this.cancel(this.leaveTimer);
    this.cancel(this.limitTimer);
    this.stayDeadline = null;
    this.state = "leaving";
    v.setRest("idle");
    this.w.bubbles.layout();
    const go = this.cur(() => {
      if (this.state !== "leaving") return;
      this.w.sound(["leave"], this.visitorCharacter);
      v.run(plan.entryX, this.speed, this.cur(() => {
        if (this.state !== "leaving") return;
        v.setHidden(true);
        this.state = "absent";
        this.log("visitor gone");
        this.w.changed();
      }));
    });
    if (!v.playAction("wave", go)) v.playAction("happy", go);
  }

  // ---- drag my pet onto the visitor ---------------------------------------------------------------------------------

  /** My pet was dropped after a drag from `originX`: overlapping the staying visitor → merge. → true when handled. */
  homeDragEnded(originX) {
    if (this.state !== "staying" || this.location.collision || !this.visitor) return false;
    const a = this.me.rect(), b = this.visitor.rect();
    if (a.right < b.left || b.right < a.left) return false;
    this.cancel(this.leaveTimer);
    this.stayDeadline = this.now + this.w.visitorMaxStayMs;
    this.state = "meeting";
    this.pendingDwell = Math.max(VISITS.bubbleDwellMs, this.stayUntil - this.now);
    const p = this.w.policy();
    const policy = { allowsCoupleClips: !!p.allowsCoupleClips && this.w.myCharacter !== this.visitorCharacter, allowsIntimate: !!p.allowsIntimate };
    const pool = ["hug", "kiss", "hug_sit", "kiss_sit"].filter((n) => this.w.catalog.couple(n));
    const name = meetingCouple({ pool, preferred: "hug", couples: this.w.catalog.couples, policy, last: this.lastCouple, roll: rollOf });
    this.lastCouple = name;
    const cc = name ? this.w.catalog.couple(name) : null;
    this.w.sound(meetingKeys([], cc?.sound, [], name), this.visitorCharacter);
    this.log("merge: my pet dropped onto the visitor");
    const back = this.cur(() => this.w.slideMe(originX, this.cur(() => this.stay())));
    if (cc) this.couple(cc, back);
    else this.w.slideMe(originX, this.cur(() => this.bothHappy(this.cur(() => this.stay()))));
    return true;
  }

  // ---- incoming routing --------------------------------------------------------------------------------------------

  /** showVisitor | queueForCard | holdUntilHome | collision. */
  incomingAction(msg) { return this.location.incoming(msg); }

  queueForCard(msg) { this.tripMessages.push(msg); }

  // ---- my sends: deliver / bounce ----------------------------------------------------------------------------------

  /**
   * verdict = {visible, reachable, partnerDND, partnerFocus, notPaired, bounceLine}. Sets msg.trip synchronously
   * ("deliver" | "local" | null = don't send) and resolves when the pet's part is over.
   */
  goDeliver(msg, verdict = {}) {
    if (!verdict.visible || this.w.mood.hidden) { msg.trip = "local"; return Promise.resolve("local"); }
    const kind = msg.kind;
    const dnd = !!(verdict.partnerDND || verdict.partnerFocus);
    const before = this.homeState;
    const plan = this.location.planSend(kind, this.now, { visitorHere: this.state !== "absent", reachable: !!verdict.reachable, partnerDND: dnd });
    this.log(`send ${kind} (home ${before}, visitor ${this.state}) → ${plan.action}`);
    switch (plan.action) {
      case "coolingDown": msg.trip = null; return Promise.resolve("cooldown");
      case "sendOnly": msg.trip = "local"; return Promise.resolve("local");
      case "extendAway":
        msg.trip = "local";
        if (this.homeState === "away") this.scheduleAwayTimer();
        return Promise.resolve("local");
      case "localMeeting": {
        msg.trip = "local";
        const e = this.event(msg, { live: true, local: true });
        e.kind = kind;
        this.partner(e);
        return Promise.resolve("local");
      }
      case "deliver": {
        msg.trip = "deliver";
        if (before === "home") this.homeX = this.me.x;
        this.homeNotice = null;
        this.w.sound(["goVisit"], this.w.myCharacter);
        this.tripMessage = { ...msg, ts: msg.ts ?? this.now };
        this.location.sent(this.tripMessage.ts);
        const side = this.me.x < this.w.width / 2 ? "left" : "right";
        return new Promise((resolve) => {
          this.deliverDone?.("local");
          this.deliverDone = resolve;
          this.me.run(this.offX(side, this.me.idleWidth), this.speed, this.cur(() => {
            if (this.homeState !== "leaving" || this.location.bouncing) return;
            this.location.reachedAway(this.now);
            this.me.setHidden(true);
            this.scheduleAwayTimer();
          }));
        });
      }
      case "bounce": {
        const sent = plan.send;
        msg.trip = sent ? "local" : null;
        if (dnd) this.homeNotice = verdict.bounceLine || (verdict.partnerFocus && !verdict.partnerDND ? VISITS.focusBounceLine : "TA 开了勿扰，先放在 TA 那儿啦");
        else if (sent || this.homeNotice == null) {
          this.homeNotice = verdict.notPaired ? (sent ? VISITS.notPairedQueuedLine : VISITS.notPairedLine) : (sent ? VISITS.offlineQueuedLine : VISITS.offlineLine);
        }
        if (!(this.location.bouncing && before === "home")) return Promise.resolve("bounced");
        this.homeX = this.me.x;
        this.w.sound(["goVisit"], this.w.myCharacter);
        const side = this.me.x < this.w.width / 2 ? "left" : "right";
        return new Promise((resolve) => {
          this.deliverDone?.("local");
          this.deliverDone = resolve;
          this.me.run(this.offX(side, this.me.idleWidth), this.speed, this.cur(() => {
            if (this.homeState !== "leaving") return;
            this.me.setHidden(true);
            this.cancel(this.bounceTimer);
            this.bounceTimer = this.after(VISITS.bounceAwayMs ?? 1600, () => this.runHome());
          }));
        });
      }
    }
    return Promise.resolve("local");
  }

  scheduleAwayTimer() {
    this.cancel(this.awayTimer);
    const wait = this.location.awayRemaining(this.now) ?? 0;
    this.awayTimer = this.after(Math.max(50, wait), () => (this.location.collision ? this.nextStep() : this.runHome()));
    this.log(`away at TA's, back in ${Math.round(wait / 100) / 10} s`);
  }

  runHome(then) {
    if (this.homeState !== "leaving" && this.homeState !== "away") { then?.(); return; }
    this.cancel(this.awayTimer);
    const bounced = this.location.bouncing;
    this.location.startReturn();
    const homeX = this.w.clampX(this.homeX ?? this.w.homeX());
    this.me.setHidden(false);
    this.me.run(homeX, this.speed, this.cur(() => {
      if (this.homeState !== "returning") return;
      this.location.arrivedHome();
      this.w.changed();
      if (then) { then(); return; }
      if (this.homeNotice) {
        this.me.toast(this.homeNotice, 4000);
        this.w.sound(["notHome"], this.w.myCharacter);
      } else {
        this.me.toast(VISITS.deliveredToast);
        this.me.hearts();
        this.w.sound(["goBack"], this.w.myCharacter);
      }
      this.homeNotice = null;
      const r = this.deliverDone;
      this.deliverDone = null;
      r?.(bounced ? "bounced" : "delivered");
      this.home();
    }));
  }

  /** Back on my desk: the trip card, then what waited. */
  home() {
    if (this.tripMessages.length) {
      const msgs = this.tripMessages;
      this.tripMessages = [];
      this.w.showCard("trip", msgs);
    }
    const q = this.queuedWhileAway;
    this.queuedWhileAway = [];
    q.forEach((e) => this.partner(e));
  }

  // ---- collision dance ---------------------------------------------------------------------------------------------

  collide(msg, e) {
    const mine = this.tripMessage ?? { kind: "visit", ts: this.location.tripTs ?? this.now };
    const plan = collisionPlan(mine, msg, this.w.mySeat);
    this.location.beginCollision(plan.winner);
    this.dance = plan.steps.slice();
    this.danceEvent = e;
    this.log(`collision: mine ts ${mine.ts} vs theirs ts ${msg.ts} → ${plan.winner === "me" ? "I go first" : "TA goes first"}; ${plan.steps.map((s) => s.step).join(" → ")}`);
    this.w.emit("collision", { winner: plan.winner, steps: plan.steps.map((s) => s.step) });
    this.nextStep();
  }

  nextStep() {
    if (!this.location.collision) return;
    if (!this.dance.length) { this.finishDance(); return; }
    const s = this.dance.shift();
    this.log("collision step: " + s.step);
    switch (s.step) {
      case "turnBack":
        if (this.homeState === "leaving" || this.homeState === "away") this.runHome(() => this.nextStep());
        else this.nextStep();
        break;
      case "hostVisitor": {
        const e = this.danceEvent;
        const v = e && this.prepareVisitor(e);
        if (!v) { if (e) { this.onNoVisitor(e); this.danceEvent = { ...e, bubble: null }; } this.nextStep(); return; }
        this.afterMeeting = () => this.nextStep();
        this.arrive({ ...e, bubble: null, live: true, done: null }, v);
        break;
      }
      case "dwell":
        this.cancel(this.danceTimer);
        this.danceTimer = this.after(s.ms, () => this.nextStep());
        break;
      case "leaveTogether": this.leaveTogether(); break;
      case "stayAway":
      case "stayAwayFor":
        this.location.setReturn(this.now + s.ms);
        if (this.homeState === "away") this.scheduleAwayTimer();
        break;
      case "comeHome": this.runHome(() => this.nextStep()); break;
      case "showPinned": {
        const b = this.danceEvent?.bubble;
        if (b) { this.danceEvent.bubble = null; this.w.bubbles.enqueue({ ...b, header: VISITS.pinnedHeader, atHome: true }); }
        this.danceEvent?.done?.("shown");
        this.nextStep();
        break;
      }
      case "comeHomeWithVisitor": this.comeHomeWithVisitor(); break;
      default: this.nextStep();
    }
  }

  leaveTogether() {
    const v = this.visitor, plan = this.plan;
    if (!v || !plan || this.state === "absent") { this.nextStep(); return; }
    this.cancel(this.leaveTimer);
    this.cancel(this.limitTimer);
    this.stayDeadline = null;
    this.state = "leaving";
    v.setRest("idle");
    this.homeX = this.me.x;
    this.me.setHidden(false);
    this.location.leaveAgain(0);
    this.w.sound(["leave"], this.visitorCharacter);
    let running = 2;
    const done = this.cur(() => {
      if (--running > 0) return;
      this.location.reachedAway(this.now);
      this.nextStep();
    });
    v.run(plan.entryX, this.speed, this.cur(() => { v.setHidden(true); this.state = "absent"; done(); }));
    this.me.run(this.offX(plan.entrySide, this.me.idleWidth), this.speed, this.cur(() => { this.me.setHidden(true); done(); }));
  }

  comeHomeWithVisitor() {
    const e = this.danceEvent;
    const v = e && this.prepareVisitor(e);
    if (!v) {
      if (e) { this.onNoVisitor(e); this.danceEvent = null; }
      this.runHome(() => this.nextStep());
      return;
    }
    this.cancel(this.awayTimer);
    this.location.startReturn();
    const homeX = this.w.clampX(this.homeX ?? this.w.homeX());
    const fromX = this.me.x;
    this.me.setX(homeX);   // plan from the home spot
    const p = this.arrival();
    this.me.setX(fromX);
    this.me.setHidden(false);
    this.startVisitor({ ...e, live: true }, p, v);
    this.danceEvent = null;
    const behind = v.idleWidth * 0.8;
    v.setX(this.me.x + (p.entrySide === "left" ? -behind : behind));
    let running = 2;
    const done = this.cur(() => { if (--running === 0) this.meet(); });
    this.me.run(homeX, this.speed, this.cur(() => {
      this.location.arrivedHome();
      done();
      this.nextStep();
    }));
    v.run(p.standX, this.speed, done);
  }

  finishDance() {
    this.dance = [];
    this.danceEvent = null;
    this.cancel(this.danceTimer);
    this.location.endCollision();
    const r = this.deliverDone;
    this.deliverDone = null;
    r?.("delivered");
    this.log("collision: dance over");
    this.home();
  }

  // ---- reset / size ------------------------------------------------------------------------------------------------

  /** Ends everything (character changed / world hidden); hands back the bubbles that were still to be shown. */
  reset() {
    this.epoch++;
    const handBack = [...this.pending, ...this.queuedWhileAway.map((e) => e.bubble).filter(Boolean)];
    if (this.location.collision && this.danceEvent?.bubble) handBack.push(this.danceEvent.bubble);
    const r = this.deliverDone;
    this.deliverDone = null;
    r?.("local");
    for (const id of [this.leaveTimer, this.limitTimer, this.awayTimer, this.bounceTimer, this.danceTimer]) this.cancel(id);
    this.visitor?.stop();
    this.visitor?.setHidden(true);
    if (this.homeState !== "home") {
      this.me.stop();
      this.me.setX(this.w.clampX(this.homeX ?? this.w.homeX()));
      this.me.setHidden(false);
    }
    this.me.setHidden(false);
    this.state = "absent";
    this.location.endCollision();
    this.location.arrivedHome();
    const trips = this.tripMessages;
    this.reset0();
    this.tripMessages = trips;
    return handBack;
  }

  /**
   * New size or document (my pet already placed; `mapX` maps an old x to the new stage): a staying / meeting visitor
   * re-plans its spot next to my pet, one on its way in heads for the new spot, one on its way out for the new edge.
   */
  resized(mapX = (x) => x) {
    if (this.homeX != null) this.homeX = mapX(this.homeX);
    const v = this.visitor;
    if (!v) return;
    v.setBaseHeight(this.w.baseH);
    if (this.state === "absent") return;
    const side = this.plan?.entrySide;
    if (this.state === "staying" || (this.state === "meeting" && !v.running)) {
      this.plan = this.arrival();
      v.setX(this.plan.standX);
    } else if (this.state === "entering") {
      const p = this.arrival();
      this.plan = { ...p, entrySide: side ?? p.entrySide, entryX: this.offX(side ?? p.entrySide, v.idleWidth) };
      if (v.running) v.retarget(p.standX, mapX(v.liveX)); else v.setX(mapX(v.x));
    } else if (this.state === "leaving" && this.plan) {
      this.plan = { ...this.plan, entryX: this.offX(side, v.idleWidth) };
      if (v.running) v.retarget(this.plan.entryX, mapX(v.liveX)); else v.setX(mapX(v.x));
    }
  }
}

export { replyLine, decodeReply };
