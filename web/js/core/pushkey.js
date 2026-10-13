// Client-generated Firebase push key (port of PushKey in Sources/LuluCore/WireLimits.swift): 20 chars,
// the first 8 are `ms` in base 64 (time ordered like a server POST key), the last 12 random. A send is then an
// idempotent `PUT messages/<key>`.

export const PUSH_KEY_ALPHABET = "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz";

function cryptoRand() {
  const b = new Uint8Array(1);
  globalThis.crypto.getRandomValues(b);
  return b[0] & 63; // 256 is a multiple of 64: uniform
}

/** `rand` (optional, for tests): () → integer in [0, 64). Default: crypto.getRandomValues. */
export function generatePushKey(ms, rand = cryptoRand) {
  let t = Math.max(0, Math.floor(ms));
  const head = new Array(8);
  for (let i = 7; i >= 0; i--) {
    head[i] = PUSH_KEY_ALPHABET[t % 64];
    t = Math.floor(t / 64);
  }
  let tail = "";
  for (let i = 0; i < 12; i++) tail += PUSH_KEY_ALPHABET[rand() & 63];
  return head.join("") + tail;
}

export function isValidPushKey(s) {
  if (typeof s !== "string" || s.length !== 20) return false;
  for (const c of s) if (!PUSH_KEY_ALPHABET.includes(c)) return false;
  return true;
}
