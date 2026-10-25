#!/usr/bin/env bash
# Deploy the web-push Cloud Functions (functions/) to the pair's own Firebase project (needs the Blaze plan).
#
#   scripts/deploy_functions.sh [--dry-run] [--check] [--region REGION]
#
# --dry-run  build + test + stage only (no Firebase call at all)
# --check    `firebase deploy --dry-run` (validates against the project, changes nothing; needs `firebase login`)
# --region   where the Realtime Database lives (default $LULUPET_DB_REGION or us-central1; a database URL ending in
#            firebasedatabase.app names its region, e.g. europe-west1). RTDB triggers must run in that region.
#
# The project id is NOT in the repo: ~/.config/lulupet/firebase_project (override: $LULUPET_FIREBASE_PROJECT_FILE),
# like scripts/deploy_web.sh. The VAPID keys must exist first (scripts/push_vapid.sh, once). The code is staged in a
# scratch dir: functions/ (fresh vendor/ copy of web/js/core, no tests), its .env (DB_REGION), a generated firebase.json.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY=0; CHECK=0; REGION="${LULUPET_DB_REGION:-us-central1}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --check) CHECK=1 ;;
    --region) REGION="${2:-}"; shift ;;
    *) echo "✗ unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
die() { echo "✗ $*" >&2; exit 1; }
[[ "$REGION" =~ ^[a-z]+-[a-z]+[0-9]$ ]] || die "--region looks wrong: $REGION"
[[ -f functions/package.json ]] || die "functions/ not found"
PROJECT_FILE="${LULUPET_FIREBASE_PROJECT_FILE:-$HOME/.config/lulupet/firebase_project}"
PROJECT=""
if [[ -s "$PROJECT_FILE" ]]; then
  PROJECT="$(tr -d '[:space:]' < "$PROJECT_FILE")"
  [[ "$PROJECT" =~ ^[a-z0-9-]{4,40}$ ]] || die "project id in $PROJECT_FILE looks wrong"
elif (( ! DRY )); then
  die "no Firebase project id at $PROJECT_FILE (one line, e.g. my-project-1234)"
fi
grep -q 'VAPID_PUBLIC_KEY = "B' web/js/net/vapid.js || echo "⚠️  web/js/net/vapid.js has no public key yet — run scripts/push_vapid.sh first (pages can't subscribe without it)"

echo "==> vendor web/js/core → functions/vendor"
node functions/scripts/vendor.mjs
[[ -d functions/node_modules ]] || (cd functions && npm ci --no-audit --no-fund)
echo "==> node --test functions/test"
(cd functions && node --test "test/**/*.test.mjs" >/dev/null) || die "functions tests failed (run: cd functions && npm test)"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/lulupet-functions.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
rsync -a --exclude node_modules/ --exclude test/ --exclude scripts/ --exclude '.env*' --exclude '.DS_Store' functions/ "$STAGE/functions/"
printf 'DB_REGION=%s\n' "$REGION" > "$STAGE/functions/.env"
cat > "$STAGE/firebase.json" <<'JSON'
{"functions": [{"source": "functions", "codebase": "default", "runtime": "nodejs22", "ignore": ["node_modules", ".git", "*.log"]}]}
JSON
# The CLI loads the code locally to find the functions, so the staged copy needs its dependencies.
(cd "$STAGE/functions" && npm ci --omit=dev --no-audit --no-fund >/dev/null) || die "npm ci failed in the staged functions"
(cd "$STAGE/functions" && GCLOUD_PROJECT="${PROJECT:-demo-lulupet}" DB_REGION="$REGION" node -e '
  import("./index.js").then((m) => { for (const k of Object.keys(m)) console.log("    " + k + " → " + m[k].__endpoint.region.join(",")); })' ) \
  || die "functions/index.js does not load"

echo "==> 推送服务：$(find "$STAGE/functions" -path "$STAGE/functions/node_modules" -prune -o -type f -print | wc -l | tr -d ' ') 个文件，region $REGION"
if (( DRY )); then echo "==> dry run：不部署 / not deploying"; exit 0; fi
if (( CHECK )); then
  ( cd "$STAGE" && npx --yes firebase-tools@latest deploy --only functions --project "$PROJECT" --non-interactive --dry-run 2>&1 | grep -v "npm warn" ) \
    || die "firebase deploy --dry-run failed（没登录？还不是 Blaze？没运行 push_vapid.sh？）"
  echo "✓ 检查通过 / check passed（什么都没改）"
  exit 0
fi
( cd "$STAGE" && npx --yes firebase-tools@latest deploy --only functions --project "$PROJECT" --non-interactive 2>&1 | grep -v "npm warn" ) \
  || die "firebase deploy failed（没登录？还不是 Blaze？没运行 push_vapid.sh？）"
# Old container images are the only thing that would cost money over time: keep one day of them.
( cd "$STAGE" && npx --yes firebase-tools@latest functions:artifacts:setpolicy --location "$REGION" --days 1 --force --project "$PROJECT" --non-interactive 2>&1 | grep -v "npm warn" ) \
  || echo "⚠️  cleanup policy not set — run: npx firebase-tools functions:artifacts:setpolicy --location $REGION --days 1 --project <id>"
echo "✓ 推送服务已部署 / functions deployed (pushOnMessage, pushIndex, eyedropsPush)"
