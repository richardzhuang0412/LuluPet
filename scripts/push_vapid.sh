#!/usr/bin/env bash
# One-time: generate the Web Push VAPID key pair, store it in Secret Manager as LULUPET_VAPID (the private key never
# touches the repo or the screen) and write the PUBLIC key into web/js/net/vapid.js (safe to commit).
#
#   scripts/push_vapid.sh [--rotate]
#
# Needs the Blaze plan and `npx firebase-tools login`. Refuses to replace an existing key unless --rotate (rotating
# makes every phone / browser subscribe again: they do it on their next start when notification permission is still
# granted, otherwise in Settings → 手机 / 后台提醒). After it: deploy the web (scripts/deploy_web.sh) and the functions
# (scripts/deploy_functions.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

ROTATE=0
[[ "${1:-}" == "--rotate" ]] && ROTATE=1
die() { echo "✗ $*" >&2; exit 1; }
PROJECT_FILE="${LULUPET_FIREBASE_PROJECT_FILE:-$HOME/.config/lulupet/firebase_project}"
[[ -s "$PROJECT_FILE" ]] || die "no Firebase project id at $PROJECT_FILE"
PROJECT="$(tr -d '[:space:]' < "$PROJECT_FILE")"
[[ "$PROJECT" =~ ^[a-z0-9-]{4,40}$ ]] || die "project id in $PROJECT_FILE looks wrong"
if grep -q 'VAPID_PUBLIC_KEY = "B' web/js/net/vapid.js && (( ! ROTATE )); then
  die "web/js/net/vapid.js already has a key (use --rotate to replace it)"
fi
[[ -d functions/node_modules/web-push ]] || (cd functions && npm ci --no-audit --no-fund >/dev/null)

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lulupet-vapid.XXXXXX")"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
# subject: the site's own address (push services contact it about abuse; it is not stored in the repo).
(cd functions && SUBJECT="https://$PROJECT.web.app" node --input-type=module -e '
  import webpush from "web-push";
  const k = webpush.generateVAPIDKeys();
  process.stdout.write(JSON.stringify({ publicKey: k.publicKey, privateKey: k.privateKey, subject: process.env.SUBJECT }));
') > "$TMP/vapid.json"
PUBLIC="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).publicKey)' "$TMP/vapid.json")"
[[ "$PUBLIC" =~ ^B[A-Za-z0-9_-]{86}$ ]] || die "generated key looks wrong"

npx --yes firebase-tools@latest functions:secrets:set LULUPET_VAPID --data-file "$TMP/vapid.json" --project "$PROJECT" --non-interactive --force 2>&1 \
  | grep -v "npm warn" || die "secrets:set failed（还不是 Blaze？没登录？）"

python3 - "$PUBLIC" <<'PY'
import re, sys
p = "web/js/net/vapid.js"
s = open(p).read()
s = re.sub(r'export const VAPID_PUBLIC_KEY = "[^"]*";', f'export const VAPID_PUBLIC_KEY = "{sys.argv[1]}";', s)
open(p, "w").write(s)
PY
echo "✓ VAPID key stored in Secret Manager (LULUPET_VAPID); public key written to web/js/net/vapid.js:"
echo "  $PUBLIC"
