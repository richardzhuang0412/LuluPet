// 噜噜桌宠 web push (Cloud Functions for Firebase, 2nd gen, Node 22). Spec: docs/superpowers/specs/2026-10-22-web-push.md.
//   pushOnMessage   RTDB /pairs/{code}/messages/{id} created → Web Push to the other seat's subscriptions
//   pushIndex       RTDB /pairs/{code}/push/{seat}/{subId}/prefs written → /pushIndex/{code}/{seat} (eye-drop seats)
//   eyedropsPush    every minute → eye-drop reminders for seats in /pushIndex (to devices the user isn't using right now)
// Deploy: scripts/deploy_functions.sh. VAPID keys: Secret Manager secret LULUPET_VAPID (scripts/push_vapid.sh).
// DB_REGION (.env, written by the deploy script) must be the Realtime Database's location (us-central1 by default).

import { onValueCreated, onValueWritten } from "firebase-functions/v2/database";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { setGlobalOptions } from "firebase-functions/v2";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import { initializeApp } from "firebase-admin/app";
import { getDatabase } from "firebase-admin/database";
import webpush from "web-push";
import { handleMessage, runEyedrops, updateIndex } from "./src/handlers.js";
import { parseVapid } from "./src/send.js";

const VAPID = defineSecret("LULUPET_VAPID");
const DB_REGION = /^[a-z]+-[a-z]+\d$/.test(process.env.DB_REGION ?? "") ? process.env.DB_REGION : "us-central1";

setGlobalOptions({ region: DB_REGION, memory: "256MiB", cpu: "gcf_gen1", concurrency: 1, maxInstances: 2, timeoutSeconds: 60 });
initializeApp();

/** Admin database as the small get / update interface the handlers use. */
function adminDb() {
  const root = getDatabase().ref();
  return {
    get: async (path) => (await root.child(path).get()).val(),
    update: (obj) => root.update(obj),
  };
}

const log = (line) => logger.info(line);

export const pushOnMessage = onValueCreated({ ref: "/pairs/{code}/messages/{id}", secrets: [VAPID] }, async (event) => {
  const value = event.data.val();
  if (!value || typeof value !== "object") return;
  await handleMessage({ db: adminDb(), webpush, vapid: parseVapid(VAPID.value()), code: event.params.code, id: event.params.id,
    value, now: Date.now(), log });
});

export const pushIndex = onValueWritten({ ref: "/pairs/{code}/push/{seat}/{subId}/prefs" }, async (event) => {
  await updateIndex({ db: adminDb(), code: event.params.code, seat: event.params.seat });
});

export const eyedropsPush = onSchedule({ schedule: "every 1 minutes", secrets: [VAPID], retryCount: 0 }, async () => {
  await runEyedrops({ db: adminDb(), webpush, vapid: parseVapid(VAPID.value()), now: Date.now(), log });
});
