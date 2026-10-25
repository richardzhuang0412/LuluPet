// The three jobs, written against a tiny database interface so tests run them on an in-memory tree:
//   db.get(path) → value (null = nothing)        db.update({path: value | null, …}) → multi-path write
// Paths have no leading slash. Nothing here logs a pair code.

import {
  CODE_RE, SEATS, TTL, decodeSubs, decodePresence, keyMatches, messagePush, messageTargets, otherSeat, pickTz, shouldSend,
} from "./rules.js";
import { sendAll } from "./send.js";
import {
  afterShow, bubbleCopy, decodeDays, decodeNag, decodeSettings, dayKey, parseSlotId, plan,
} from "../vendor/eyedrops.js";
import { addDays } from "../vendor/tz.js";
import { decodeDevices, staleDeviceIds } from "../vendor/devices.js";

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

async function dropGone(db, code, seat, ids) {
  if (!ids.length) return;
  await db.update(Object.fromEntries(ids.map((id) => [`pairs/${code}/push/${seat}/${id}`, null])));
}

/** /pairs/{code}/devices/{seat} as stored; records written more than 7 days ago are pruned on the way (rarely any). */
async function readDevices(db, code, seat, now) {
  const node = await db.get(`pairs/${code}/devices/${seat}`);
  const stale = staleDeviceIds(node, now);
  if (stale.length) await db.update(Object.fromEntries(stale.map((id) => [`pairs/${code}/devices/${seat}/${id}`, null])));
  return node;
}

/** /pairs/{code}/messages/{id} created → push to the other seat's subscriptions. */
export async function handleMessage({ db, webpush, vapid, code, id, value, now, log = () => {} }) {
  if (!CODE_RE.test(code)) return { skipped: "code" };
  const built = messagePush(id, value, now);
  if (!built) return { skipped: "kind" };
  const to = otherSeat(value.from);
  const subsNode = await db.get(`pairs/${code}/push/${to}`);
  if (!isObj(subsNode)) return { skipped: "no-subs" };
  const [presenceRaw, devicesRaw] = await Promise.all([db.get(`pairs/${code}/presence/${to}`), readDevices(db, code, to, now)]);
  const targets = messageTargets({ built, subsNode, presenceRaw, devicesRaw, now, publicKey: vapid.publicKey });
  if (!targets.length) return { skipped: "present" };
  const r = await sendAll({ webpush, vapid, targets, payload: built.payload, ttl: built.ttl, urgency: built.urgency });
  await dropGone(db, code, to, r.gone);
  log(`message push: sent ${r.sent}, gone ${r.gone.length}, failed ${r.failed.map((f) => f.status).join(",") || 0}`);
  return r;
}

/**
 * /pairs/{code}/push/{seat}/{subId}/prefs written → keep /pushIndex/{code}/{seat} (admin-only: the root rules deny
 * clients) true while any subscription of that seat wants eye drops, so the scheduler never scans /pairs.
 */
export async function updateIndex({ db, code, seat }) {
  if (!CODE_RE.test(code) || !SEATS.includes(seat)) return false;
  const want = decodeSubs(await db.get(`pairs/${code}/push/${seat}`)).some((s) => s.prefs.eyedrops);
  await db.update({ [`pushIndex/${code}/${seat}`]: want ? true : null });
  return want;
}

/**
 * One seat's eye drops, run every minute: the same `plan` as the pages (web/js/core/eyedrops.js), with the server's
 * own nag record /pairs/{code}/tools/{seat}/eyedrops/pushed/{day}/{HHmm} = {shown, next, at} (3 shows, 15 min apart),
 * pushed only to subscriptions whose device isn't showing it already (shouldSend).
 */
export async function eyedropsForSeat({ db, webpush, vapid, code, seat, now }) {
  const base = `pairs/${code}`;
  const tool = `${base}/tools/${seat}/eyedrops`;
  const rawSettings = await db.get(`${tool}/settings`);
  const settings = decodeSettings(rawSettings);
  if (!settings?.enabled || !settings.times.length) return { result: "off" };
  const subs = decodeSubs(await db.get(`${base}/push/${seat}`)).filter((s) => s.prefs.eyedrops && keyMatches(s, vapid.publicKey));
  if (!subs.length) return { result: "no-subs" };
  const presence = decodePresence(await db.get(`${base}/presence/${seat}`));
  const tz = pickTz(subs, rawSettings, presence);
  if (!tz) return { result: "no-tz" };

  const today = dayKey(now, tz), yesterday = addDays(today, -1);
  const [dToday, dYesterday] = await Promise.all([db.get(`${tool}/days/${today}`), db.get(`${tool}/days/${yesterday}`)]);
  const days = decodeDays({ [yesterday]: dYesterday, [today]: dToday });
  let p = plan({ settings, today: days, nag: null, now, active: true, tz });
  if (p.action !== "show") return { result: "none" };

  const at = parseSlotId(p.slot);
  const pushed = await db.get(`${tool}/pushed`);
  const rec = isObj(pushed) && isObj(pushed[at.day]) ? pushed[at.day][at.key] : null;
  const nag = isObj(rec) ? decodeNag({ slot: p.slot, shown: rec.shown, next: rec.next }, now) : null;
  p = plan({ settings, today: days, nag, now, active: true, tz });
  if (p.action !== "show") return { result: p.action, slot: p.slot };

  const devices = decodeDevices(await readDevices(db, code, seat, now), now);
  const targets = subs.filter((s) => shouldSend(s, presence, now, devices)).map((sub) => ({ sub, silent: false }));
  if (!targets.length) return { result: "present", slot: p.slot };

  // Claim the show before sending (an overlapping run then waits 15 minutes instead of pushing twice).
  const next = afterShow(nag, p.slot, now);
  const write = { [`${tool}/pushed/${at.day}/${at.key}`]: { shown: next.shown, next: next.next, at: now } };
  if (isObj(pushed)) for (const d of Object.keys(pushed)) if (d < yesterday) write[`${tool}/pushed/${d}`] = null;
  await db.update(write);

  const copy = bubbleCopy(p.slot, settings.times.indexOf(at.time) + 1, settings.times.length);
  const payload = { v: 1, kind: "eyedrops", title: copy.header, body: copy.line, tag: "eyedrops", slot: p.slot };
  const r = await sendAll({ webpush, vapid, targets, payload, ttl: TTL.eyedrops, urgency: "high", topic: "eyedrops" });
  await dropGone(db, code, seat, r.gone);
  return { result: "sent", slot: p.slot, shown: next.shown, ...r };
}

/** Every minute: each seat listed in /pushIndex. */
export async function runEyedrops({ db, webpush, vapid, now, log = () => {} }) {
  const index = await db.get("pushIndex");
  if (!isObj(index)) return [];
  const out = [];
  for (const code of Object.keys(index)) {
    if (!CODE_RE.test(code) || !isObj(index[code])) continue;
    for (const seat of SEATS) {
      if (index[code][seat] !== true) continue;
      try {
        out.push(await eyedropsForSeat({ db, webpush, vapid, code, seat, now }));
      } catch (e) {
        log(`eyedrops: ${e?.message ?? e}`);
        out.push({ result: "error" });
      }
    }
  }
  const sent = out.filter((r) => r.result === "sent");
  if (sent.length) log(`eyedrops push: ${sent.map((r) => `#${r.shown} sent ${r.sent} gone ${r.gone.length}`).join("; ")}`);
  return out;
}
