// The shared pair code (port of Sources/LuluCore/PairCode.swift). The web client never generates one.

export const PAIR_CODE_LENGTH = 24;
/** Base32-ish alphabet without look-alikes (0/O, 1/I). */
export const PAIR_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

/** Upper-cased, all whitespace removed. */
export function normalize(raw) {
  return String(raw).toUpperCase().replace(/\p{White_Space}/gu, "");
}

export function isValid(code) {
  if (typeof code !== "string" || code.length !== PAIR_CODE_LENGTH) return false;
  for (const c of code) if (!PAIR_CODE_ALPHABET.includes(c)) return false;
  return true;
}
