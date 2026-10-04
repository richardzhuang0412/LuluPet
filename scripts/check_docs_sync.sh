#!/usr/bin/env bash
# Checks that the user-facing docs were updated for a release (run by scripts/release.sh and the Claude Code hook).
#
# Usage: scripts/check_docs_sync.sh [x.y.z]      (default: ./VERSION)
#
# Passes when
#   1. assets/changelog.json has an entry for x.y.z, and Resources/changelog.json is an identical copy;
#   2. README.md or docs/features.md was touched for this release, i.e. EITHER
#      - modified in a commit after the last commit whose VERSION was the previous changelog version
#        (or modified in the working tree / index right now), OR
#      - contains the marker  <!-- docs-synced: vx.y.z -->  (the /release skill adds it after syncing docs,
#        for releases whose changes need no new README wording).
# Exit 0 = synced, 1 = not synced (message says what to update), 2 = usage error.
set -euo pipefail
cd "$(dirname "$0")/.."

VER="${1:-$(tr -d '[:space:]' < VERSION)}"
VER="${VER#v}"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "用法 / usage: scripts/check_docs_sync.sh x.y.z（收到 '$VER'）" >&2; exit 2; }

# Changelog entry for VER + the version just before it (next entry in the list), via python3 (no jq needed).
INFO="$(python3 - "$VER" <<'PY'
import json, sys
ver = sys.argv[1]
try:
    log = json.load(open("assets/changelog.json", encoding="utf-8"))
except Exception as e:
    print("ERR\tassets/changelog.json 读不了 / unreadable: %s" % e); sys.exit(0)
for i, e in enumerate(log):
    if e.get("version") == ver:
        prev = log[i + 1]["version"] if i + 1 < len(log) else ""
        print("PREV\t" + prev)
        for it in e.get("items", []):
            print("ITEM\t" + it)
        break
else:
    print("ERR\tassets/changelog.json 里没有 v%s 的条目 / no changelog entry for v%s" % (ver, ver))
PY
)"

fail() {
  echo "✗ 文档未同步 / docs not synced for v$VER:" >&2
  printf '  - %s\n' "$@" >&2
  echo "  先更新 / Update first: README.md「功能一览」(演示 + 全部功能表)、docs/features.md、" >&2
  echo "  docs/firebase-setup.md（如果改了云端结构）、docs/demo（界面有变化时跑 tools/make_demos.sh <scene>）；" >&2
  echo "  见 docs/DOCS_SYNC.md。没有需要写进文档的新功能时，在 README.md 末尾加 <!-- docs-synced: v$VER -->。" >&2
  exit 1
}

if grep -q $'^ERR\t' <<<"$INFO"; then
  fail "$(grep $'^ERR\t' <<<"$INFO" | cut -f2-)" "在 assets/changelog.json 最上面加这一版的中文更新条目 / add the entry at the top"
fi
cmp -s assets/changelog.json Resources/changelog.json \
  || fail "Resources/changelog.json 和 assets/changelog.json 不一样 / differs — cp assets/changelog.json Resources/changelog.json"

PREV="$(grep $'^PREV\t' <<<"$INFO" | cut -f2- || true)"
ITEMS="$(grep $'^ITEM\t' <<<"$INFO" | cut -f2- || true)"
DOCS=(README.md docs/features.md)

# Marker?
for f in "${DOCS[@]}"; do
  if [[ -f "$f" ]] && grep -qF "<!-- docs-synced: v$VER -->" "$f"; then
    echo "✓ 文档已同步 / docs synced for v$VER (marker in $f)"; exit 0
  fi
done

# Uncommitted edits to the docs count (the release commit is made after this check).
if [[ -n "$(git status --porcelain --untracked-files=all -- "${DOCS[@]}" 2>/dev/null)" ]]; then
  echo "✓ 文档已同步 / docs synced for v$VER (uncommitted edits to README.md / docs/features.md)"; exit 0
fi

# Base = last commit where VERSION was the previous version.
BASE=""
if [[ -n "$PREV" ]]; then
  while read -r c; do
    if [[ "$(git show "${c}:VERSION" 2>/dev/null | tr -d '[:space:]')" == "$PREV" ]]; then BASE="$c"; break; fi
  done < <(git log --format=%H -- VERSION)
fi
if [[ -n "$BASE" ]]; then
  CHANGED="$(git log --format=%h "${BASE}..HEAD" -- "${DOCS[@]}" | head -1)"
  if [[ -n "$CHANGED" ]]; then
    echo "✓ 文档已同步 / docs synced for v$VER (README.md / docs/features.md changed since v$PREV, e.g. $CHANGED)"; exit 0
  fi
  WHY="README.md 和 docs/features.md 自 v$PREV（${BASE:0:7}）以来都没改过 / unchanged since v$PREV"
else
  WHY="找不到 v${PREV:-?} 的提交，无法比较 / no commit with VERSION=${PREV:-?}; add the marker after syncing"
fi

MSG=("$WHY" "这一版的更新条目 / changelog items for v$VER:")
while IFS= read -r it; do [[ -n "$it" ]] && MSG+=("    · $it"); done <<<"$ITEMS"
fail "${MSG[@]}"
