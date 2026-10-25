import { test } from "node:test";
import assert from "node:assert/strict";
globalThis.location ??= new URL("http://127.0.0.1/");
const { partnerHeadline, partnerBadge } = await import("../js/ui/status.js");

// A partner whose Mac signed off (lastSeen 0) has paired before: not 「等 TA 配对中」 (matches PairChannel.partnerNeverSeen).
test("signed-off partner (lastSeen 0) counts as paired", () => {
  const p = { lastSeen: 0, character: "lumei", mode: "couple" };
  assert.equal(partnerHeadline(p, false), "对方离线");
  assert.equal(partnerHeadline(null, false), "等 TA 配对中…");
  if (typeof partnerBadge === "function") assert.notEqual(partnerBadge(p, false, Date.now()).text, "还没上线过");
});
