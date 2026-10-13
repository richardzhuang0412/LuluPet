// Static checks over web/js (spec §8, §11): no HTML injection sinks or dynamic code, no external URLs outside the
// allow-list, and web/js/core stays pure (no DOM / storage / network).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync, existsSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = fileURLToPath(new URL("..", import.meta.url));
const jsRoot = join(webRoot, "js");

function files(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? files(p) : /\.(m?js)$/.test(n) ? [p] : [];
  });
}

function hits(paths, re) {
  const out = [];
  for (const p of paths) {
    readFileSync(p, "utf8").split("\n").forEach((line, i) => { if (re.test(line)) out.push(`${relative(webRoot, p)}:${i + 1}: ${line.trim()}`); });
  }
  return out;
}

test("no innerHTML / outerHTML / insertAdjacentHTML / document.write / eval / new Function in web/js", () => {
  const all = files(jsRoot);
  assert.ok(all.length > 0);
  const re = /\b(innerHTML|outerHTML|insertAdjacentHTML|document\.write(ln)?|createContextualFragment)\b|(^|[^\w.])eval\s*\(|\bnew\s+Function\s*\(|\bsetTimeout\s*\(\s*["'`]|\bsetInterval\s*\(\s*["'`]/;
  assert.deepEqual(hits(all, re), []);
});

test("external URLs only from the allow-list", () => {
  const allowed = /^https?:\/\/(api\.open-meteo\.com|geocoding-api\.open-meteo\.com|127\.0\.0\.1|localhost|<[^>]+>\.firebaseio\.com|<[^>]+>\.<[^>]+>\.firebasedatabase\.app)([/:?]|$)/;
  const bad = [];
  for (const p of files(jsRoot)) {
    for (const m of readFileSync(p, "utf8").matchAll(/https?:\/\/[^\s"'`)\]（）]+/g)) {
      if (!allowed.test(m[0])) bad.push(`${relative(webRoot, p)}: ${m[0]}`);
    }
  }
  assert.deepEqual(bad, []);
});

test("web/js/core is pure: no DOM, storage or network", () => {
  const core = files(join(jsRoot, "core"));
  assert.ok(core.length >= 12);
  const re = /\b(document|window|localStorage|sessionStorage|indexedDB|navigator|fetch|XMLHttpRequest|EventSource|WebSocket|importScripts)\b/;
  const code = core.map((p) => [p, readFileSync(p, "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1")]);
  const out = [];
  for (const [p, src] of code) src.split("\n").forEach((l, i) => { if (re.test(l)) out.push(`${relative(webRoot, p)}:${i + 1}: ${l.trim()}`); });
  assert.deepEqual(out, []);
});
