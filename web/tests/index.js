// `node --test web/tests/` does not expand a directory: Node resolves it as a module, i.e. this file.
// Load every *.test.mjs here so that command runs the whole suite. (Works as CommonJS or ESM; `node --test` with no
// arguments finds the *.test.mjs files directly and never loads this file.)
(async () => {
  const { readdirSync, statSync } = await import("node:fs");
  const { join, dirname } = await import("node:path");
  const { pathToFileURL } = await import("node:url");
  let dir = process.argv[1];
  if (!statSync(dir).isDirectory()) dir = dirname(dir);
  for (const f of readdirSync(dir).filter((n) => n.endsWith(".test.mjs")).sort()) {
    await import(pathToFileURL(join(dir, f)).href);
  }
})();
