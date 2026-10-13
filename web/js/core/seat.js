// Same seat on two devices (Mac at home + web at work), spec §4.2–4.3: the web client yields the seat's presence
// to an online Mac and copies the Mac's published identity.

import { isOnline } from "./presence.js";

export const WEB_DEVICE_PREFIX = "web-";
/** How often the web reads its own seat (s); a heartbeat needs ≥ 20 s since its last PUT. */
export const SEAT_CHECK_S = 10;

export function isWebDevice(id) {
  return typeof id === "string" && id.startsWith(WEB_DEVICE_PREFIX);
}

/**
 * `mine` = decoded presence of my own seat (or null), `myDevice` = this browser's device id.
 * "yield" when the seat was last written by a non-web device (my Mac) that is online; else "beat".
 */
export function seatYield({ mine, myDevice, now }) {
  const d = mine?.device;
  if (typeof d === "string" && d !== myDevice && !isWebDevice(d) && isOnline(mine.lastSeen, now)) return "yield";
  return "beat";
}

/**
 * The identity the web publishes for my seat (§4.3): character / mode / outfit / place copied from the seat's presence;
 * never written → character = the seat's namesake, mode "couple", outfit = `defaultOutfits[character]` (or null), no place.
 */
export function adoptIdentity(presence, seat, defaultOutfits = {}) {
  const character = presence?.character ?? seat;
  return {
    character,
    mode: presence?.mode ?? "couple",
    outfit: presence?.outfit ?? defaultOutfits[character] ?? null,
    place: presence?.place ?? null,
  };
}

/** The web's sign-off is only written when the last writer read on the seat was this browser itself. */
export function maySignOff(lastReadDevice, myDevice) {
  return lastReadDevice === myDevice;
}
