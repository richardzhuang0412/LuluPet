// The vendored web/js/core modules are byte-identical to the web's, and the shared eye-drop vectors pass on them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { VENDORED } from "../scripts/vendor.mjs";
import * as E from "../vendor/eyedrops.js";

const web = new URL("../../web/js/core/", import.meta.url);
const vectors = new URL("../../web/tests/vectors/wire.json", import.meta.url);

test("vendor/ matches web/js/core (run: node functions/scripts/vendor.mjs)", { skip: !existsSync(web) }, () => {
  for (const f of VENDORED) {
    assert.equal(readFileSync(new URL(f, new URL("../vendor/", import.meta.url)), "utf8"), readFileSync(new URL(f, web), "utf8"), f);
  }
});

test("eye-drop plan / afterShow / nag vectors on the vendored copy", { skip: !existsSync(vectors) }, () => {
  const v = JSON.parse(readFileSync(vectors, "utf8")).eyedrops;
  for (const c of v.plan) {
    const got = E.plan({ settings: E.decodeSettings(c.settings), today: c.today, nag: c.nag, now: c.now, active: c.active, tz: c.tz ?? v.tz });
    assert.deepEqual(got, c.expect, c.name);
  }
  for (const c of v.afterShow) assert.deepEqual(E.afterShow(c.nag, c.slot, c.now), c.expect);
  for (const c of v.nag) assert.deepEqual(E.decodeNag(c.json, c.now), c.expect);
});
