// Sends one payload to a list of subscriptions with web-push (injected, so tests use a fake) and reports which
// subscriptions are gone (404 / 410 from the push service → the caller deletes them).

/** Secret LULUPET_VAPID (JSON written by scripts/push_vapid.sh) → {publicKey, privateKey, subject}; throws if unusable. */
export function parseVapid(raw) {
  let v;
  try { v = JSON.parse(String(raw ?? "")); } catch { throw new Error("LULUPET_VAPID is not JSON"); }
  if (typeof v?.publicKey !== "string" || typeof v?.privateKey !== "string") throw new Error("LULUPET_VAPID lacks keys");
  const subject = typeof v.subject === "string" && /^(mailto:|https:\/\/)/.test(v.subject) ? v.subject : "mailto:lulupet@example.invalid";
  return { publicKey: v.publicKey, privateKey: v.privateKey, subject };
}

export const GONE = new Set([404, 410]);

/**
 * targets: [{sub, silent}] · payload: object (JSON-encoded here; `silent` added per target)
 * options: {ttl, urgency, topic?} → {sent, gone: [subId], failed: [{id, status}]}
 */
export async function sendAll({ webpush, vapid, targets, payload, ttl, urgency = "normal", topic }) {
  const out = { sent: 0, gone: [], failed: [] };
  await Promise.all(targets.map(async ({ sub, silent }) => {
    const body = JSON.stringify(silent ? { ...payload, silent: true } : payload);
    const opts = {
      TTL: ttl, urgency, timeout: 10_000,
      vapidDetails: { subject: vapid.subject, publicKey: vapid.publicKey, privateKey: vapid.privateKey },
    };
    if (topic) opts.topic = topic;
    try {
      await webpush.sendNotification({ endpoint: sub.endpoint, keys: sub.keys }, body, opts);
      out.sent++;
    } catch (e) {
      const status = e?.statusCode ?? null;
      if (GONE.has(status)) out.gone.push(sub.id);
      else out.failed.push({ id: sub.id, status });
    }
  }));
  return out;
}
