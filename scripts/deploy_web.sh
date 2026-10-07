#!/usr/bin/env bash
# Deploy the web version (web/) to Firebase Hosting of the pair's own Firebase project.
#
#   scripts/deploy_web.sh [--dry-run]
#
# The project id is NOT in the repo (it is part of the database host name): it is read from
# ~/.config/lulupet/firebase_project (override: $LULUPET_FIREBASE_PROJECT_FILE). `firebase login` is done once by the
# user. The site is built in a scratch dir: web/ minus tests/, web/version.json = VERSION, and a generated firebase.json
# with real response headers (CSP, noindex, caching).
set -euo pipefail
cd "$(dirname "$0")/.."

DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
PROJECT_FILE="${LULUPET_FIREBASE_PROJECT_FILE:-$HOME/.config/lulupet/firebase_project}"
die() { echo "✗ $*" >&2; exit 1; }
[[ -d web ]] || die "web/ not found"
[[ -s "$PROJECT_FILE" ]] || die "no Firebase project id at $PROJECT_FILE (one line, e.g. my-project-1234)"
PROJECT="$(tr -d '[:space:]' < "$PROJECT_FILE")"
[[ "$PROJECT" =~ ^[a-z0-9-]{4,40}$ ]] || die "project id in $PROJECT_FILE looks wrong"
VER="$(tr -d '[:space:]' < VERSION)"

if [[ -d web/tests ]] && command -v node >/dev/null; then
  echo "==> node --test web/tests"
  node --test "web/tests/**/*.test.mjs" >/dev/null || die "web tests failed (run: node --test "web/tests/**/*.test.mjs")"
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/lulupet-web.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/public"
rsync -a --exclude tests/ --exclude '.DS_Store' --exclude 'js/ui/dev/' web/ "$STAGE/public/"
printf '{"version": "%s"}\n' "$VER" > "$STAGE/public/version.json"

# Same CSP as the <meta> in index.html (the header also covers sw.js / workers).
CSP="default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; worker-src 'self'; connect-src 'self' https://*.firebaseio.com https://*.firebasedatabase.app https://api.open-meteo.com https://geocoding-api.open-meteo.com; manifest-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
python3 - "$STAGE/firebase.json" "$CSP" <<'PY'
import json, sys
path, csp = sys.argv[1:]
common = [
    {"key": "Content-Security-Policy", "value": csp},
    {"key": "X-Robots-Tag", "value": "noindex, nofollow"},
    {"key": "Referrer-Policy", "value": "no-referrer"},
    {"key": "X-Content-Type-Options", "value": "nosniff"},
    {"key": "Permissions-Policy", "value": "camera=(), microphone=(), geolocation=(), payment=()"},
]
cfg = {"hosting": {
    "public": "public",
    "cleanUrls": False,
    "headers": [
        {"source": "**", "headers": common + [{"key": "Cache-Control", "value": "no-cache"}]},
        {"source": "/assets/**", "headers": [{"key": "Cache-Control", "value": "public, max-age=31536000, immutable"}]},
        {"source": "/assets/manifest.json", "headers": [{"key": "Cache-Control", "value": "no-cache"}]},
    ],
}}
json.dump(cfg, open(path, "w"), indent=1)
PY

echo "==> 网页版 v$VER：$(find "$STAGE/public" -type f | wc -l | tr -d ' ') 个文件，$(du -sh "$STAGE/public" | cut -f1)"
if (( DRY )); then echo "==> dry run：不部署 / not deploying"; exit 0; fi
( cd "$STAGE" && npx --yes firebase-tools@latest deploy --only hosting --project "$PROJECT" --non-interactive 2>&1 | grep -v "npm warn" ) \
  || die "firebase deploy failed（没登录？运行 npx firebase-tools login）"
echo "✓ 网页版 v$VER 已部署 / deployed"
