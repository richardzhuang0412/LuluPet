// Copies the pure web/js/core modules the functions reuse into functions/vendor/ (only functions/ is uploaded on
// deploy, so they can't be imported from ../web). test/vendor.test.mjs fails when a copy is out of date.
//   node functions/scripts/vendor.mjs        (scripts/deploy_functions.sh runs it before every deploy)
import { copyFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const VENDORED = ["wire.js", "tz.js", "presence.js", "message.js", "remind.js", "eyedrops.js", "devices.js"];

const src = new URL("../../web/js/core/", import.meta.url);
const dst = new URL("../vendor/", import.meta.url);

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  mkdirSync(dst, { recursive: true });
  for (const f of VENDORED) copyFileSync(new URL(f, src), new URL(f, dst));
  console.log(`vendored ${VENDORED.length} files from web/js/core`);
}
