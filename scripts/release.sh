#!/usr/bin/env bash
# 发版 / Release: test → build → install locally → commit → publish to GitHub (public tree) → GitHub release.
#
# Usage: scripts/release.sh [--dry-run] [--no-install] x.y.z
#   --dry-run     only the checks (VERSION, changelog, docs sync, working tree, tests, privacy check of the
#                 current public tree); builds, installs, commits and pushes nothing (it does regenerate
#                 CHANGELOG.md / README「最近更新」 from assets/changelog.json, like a real run).
#   --no-install  skip installing into /Applications (still builds, commits and publishes).
#
# Signing: dist/LuluPet.zip is signed (Ed25519) by scripts/update_signing_key.sh and uploaded as LuluPet.zip.sig; the app
# refuses unsigned updates. Needs the private key (~/.config/lulupet/update_signing_key) and a real public key in
# Sources/LuluCore/UpdateKey.swift (both from `scripts/update_signing_key.sh init`); refuses to run without them.
#
# Before running: bump VERSION, add the x.y.z entry at the top of assets/changelog.json (copied to
# Resources/changelog.json) and sync the docs (scripts/check_docs_sync.sh; see docs/DOCS_SYNC.md).
# CHANGELOG.md and README.md's 「最近更新」 block are regenerated from the changelog here (tools/gen_changelog.py).
# Refuses when: VERSION ≠ x.y.z, no changelog entry, docs not synced, tests fail, the privacy check hits,
# or tracked files other than the release files (VERSION, changelogs, CHANGELOG.md, README.md, docs/) are modified.
# Needs (for a real run): branch master, local branch `release`, remote `github`, `gh` logged in, and the
# installed app's config (the privacy check reads the Firebase host / pair code from it — never printed).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

DRY=0; INSTALL=1; VER=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-install) INSTALL=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) echo "未知参数 / unknown option: $a" >&2; exit 2 ;;
    *) VER="${a#v}" ;;
  esac
done
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "用法 / usage: scripts/release.sh [--dry-run] [--no-install] x.y.z" >&2; exit 2; }

REPO="richardzhuang0412/LuluPet"
AUTHOR_NAME="Richard Zhuang"
AUTHOR_EMAIL="richardzhuang0412@berkeley.edu"
TRAILER="Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
APP_ID="com.lulupet.app"
INSTALLED="/Applications/LuluPet.app"
HISTORY="$HOME/Library/Application Support/LuluPet/default/history.jsonl"
# Tracked files a release may leave uncommitted (they go into the release commit).
RELEASE_FILES=(VERSION assets/changelog.json Resources/changelog.json CHANGELOG.md README.md docs/features.md docs/firebase-setup.md docs/DOCS_SYNC.md docs/demo)

TMP="$(mktemp -d -t lulupet-release)"
trap 'rm -rf "$TMP"' EXIT

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '\n✗ %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- checks
preflight() {
  step "检查 / Preflight v$VER$([[ $DRY == 1 ]] && echo ' (dry run)')"
  local cur; cur="$(tr -d '[:space:]' < VERSION)"
  [[ "$cur" == "$VER" ]] || die "VERSION 是 $cur，不是 $VER / VERSION mismatch — bump VERSION first"
  ok "VERSION = $VER"

  local top; top="$(python3 -c 'import json;print(json.load(open("assets/changelog.json",encoding="utf-8"))[0]["version"])')"
  [[ "$top" == "$VER" ]] || die "assets/changelog.json 第一条是 v$top，不是 v$VER / the top changelog entry must be v$VER"
  ok "changelog 有 v$VER 的条目 / changelog entry present"

  # CHANGELOG.md + README「最近更新」 are generated from assets/changelog.json (release files, committed below).
  python3 tools/gen_changelog.py | sed 's/^/    /' || die "tools/gen_changelog.py 失败 / failed"
  ok "CHANGELOG.md / README「最近更新」已按 changelog 生成 / regenerated"

  scripts/check_docs_sync.sh "$VER" || die "先同步文档再发版 / sync the docs first"

  # Signed updates: the build must carry a real public key and I must hold the matching private key.
  grep -q 'UPDATE-KEY-PLACEHOLDER' Sources/LuluCore/UpdateKey.swift \
    && die "Sources/LuluCore/UpdateKey.swift 还是占位公钥，先运行 scripts/update_signing_key.sh init / placeholder update key — run scripts/update_signing_key.sh init first"
  local want have
  want="$(sed -n 's/.*publicKeyBase64 = "\(.*\)".*/\1/p' Sources/LuluCore/UpdateKey.swift)"
  have="$(scripts/update_signing_key.sh pubkey 2>/dev/null)" || die "没有更新签名私钥 / no update signing key — run scripts/update_signing_key.sh init"
  [[ -n "$want" && "$want" == "$have" ]] || die "UpdateKey.swift 的公钥和本机私钥不匹配 / compiled public key does not match the local private key"
  ok "更新签名密钥就绪 / update signing key ready"

  local branch; branch="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$branch" != "master" ]]; then
    [[ $DRY == 1 ]] && warn "当前分支是 $branch，正式发版必须在 master / real releases run on master" \
                    || die "当前分支是 $branch，发版必须在 master / must be on master"
  fi

  # Working tree: only release files may be modified (untracked files outside docs/ are ignored).
  local dirty=() f ok_file p
  while IFS= read -r f; do
    if [[ -z "$f" ]]; then continue; fi
    ok_file=0
    for p in "${RELEASE_FILES[@]}"; do if [[ "$f" == "$p" || "$f" == "$p"/* ]]; then ok_file=1; fi; done
    [[ $ok_file == 1 ]] || dirty+=("$f")
  done < <(git diff --name-only HEAD; git diff --name-only --cached)
  if (( ${#dirty[@]} )); then
    printf '    %s\n' "${dirty[@]}" >&2
    die "有别的未提交改动（上面列出）/ uncommitted changes outside the release files — commit them first"
  fi
  ok "工作区干净（除发版文件）/ working tree clean apart from release files"

  if [[ $DRY == 0 ]]; then
    git rev-parse -q --verify refs/heads/release >/dev/null || die "没有本地 release 分支 / no local 'release' branch"
    git remote get-url github >/dev/null 2>&1 || die "没有 github 远程 / no 'github' remote"
    command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || die "gh 没登录 / gh not authenticated"
    if gh release view "v$VER" --repo "$REPO" >/dev/null 2>&1; then die "GitHub 上已经有 v$VER 了 / release v$VER already exists"; fi
    ok "release 分支 / github 远程 / gh 都就绪 / release branch, remote and gh ready"
  fi
}

run_tests() {
  step "测试 / swift run LuluCoreTests"
  nice -n 10 swift run LuluCoreTests > "$TMP/tests.log" 2>&1 || { tail -30 "$TMP/tests.log" >&2; die "测试没通过 / tests failed"; }
  tail -3 "$TMP/tests.log" | sed 's/^/    /'
  ok "测试通过 / tests passed"
}

# Privacy check on a git tree: real Firebase host + pair code (read from the installed app's config, never
# printed), this Mac's home path, personal wording (needles built at run time, so this file never matches
# itself), and e-mail addresses other than the author's / Claude's.
privacy_check() {
  local tree="$1" hits=0
  step "隐私检查 / Privacy check on public tree ${tree:0:12}"
  python3 - "$APP_ID" > "$TMP/needles" <<'PY'
import json, plistlib, subprocess, sys
from urllib.parse import urlparse
try:
    p = plistlib.loads(subprocess.run(["defaults", "export", sys.argv[1], "-"], capture_output=True, check=True).stdout)
    c = json.loads(p["config"])
except Exception:
    sys.exit(0)
host = urlparse(c.get("databaseURL") or "").hostname or ""
if host:
    print(host)
    label = host.split(".")[0]
    if len(label) >= 10 and "-" in label:
        print(label)
code = c.get("pairCode") or ""
if len(code) >= 6:
    print(code)
PY
  chmod 600 "$TMP/needles"
  if [[ -s "$TMP/needles" ]]; then
    local secret; secret="$(git grep -I -l -F -f "$TMP/needles" "$tree" 2>/dev/null | sed "s|^${tree}:||" || true)"
    if [[ -n "$secret" ]]; then
      echo "    含真实 Firebase 地址 / 配对码的文件 / files containing the real Firebase host or pair code:" >&2
      printf '      %s\n' $secret >&2; hits=1
    fi
    ok "真实 Firebase 地址 / 配对码 已检查（$(wc -l < "$TMP/needles" | tr -d ' ') 个，不显示）/ secrets checked (not shown)"
  else
    [[ $DRY == 1 ]] && warn "读不到本机 App 的配置，跳过 Firebase 地址 / 配对码检查 / no local config — secret check skipped" \
                    || die "读不到本机 App 的配置（defaults $APP_ID config），没法做隐私检查 / cannot read local config"
  fi
  local n
  # "/Users/<me>" and \u8001\u5a46 (personal wording), assembled here so the script itself is not a hit.
  for n in "$HOME/" "$(printf '\xe8\x80\x81\xe5\xa9\x86')"; do
    if git grep -I -n -F -e "$n" "$tree" >/dev/null 2>&1; then
      echo "    「$n」出现在 / found in:" >&2
      git grep -I -n -F -e "$n" "$tree" | sed "s|^${tree}:|      |" | cut -c1-160 >&2; hits=1
    fi
  done
  local emails
  emails="$(git grep -I -h -o -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$tree" 2>/dev/null \
    | sort -u | grep -v -x -i -E "${AUTHOR_EMAIL//./\\.}|noreply@anthropic\.com|[^@]+@(example\.(com|org)|users\.noreply\.github\.com)" || true)"
  if [[ -n "$emails" ]]; then
    echo "    其他邮箱 / other e-mail addresses:" >&2
    printf '      %s\n' $emails >&2; hits=1
  fi
  [[ $hits == 0 ]] || die "隐私检查没通过，什么都没推 / privacy check failed — nothing pushed"
  ok "隐私检查通过 / privacy check clean"
}

# ---------------------------------------------------------------- build
build() {
  step "构建 / scripts/build_app.sh"
  nice -n 10 scripts/build_app.sh
  codesign --verify --deep --strict dist/LuluPet.app || die "签名校验失败 / codesign verify failed"
  ok "dist/LuluPet.app + dist/LuluPet.zip，签名有效 / signature valid"
}

# Signs dist/LuluPet.zip → dist/LuluPet.zip.sig and checks it against the public key compiled into the build.
sign_zip() {
  step "签名更新包 / Sign dist/LuluPet.zip"
  grep -q 'UPDATE-KEY-PLACEHOLDER' Sources/LuluCore/UpdateKey.swift && die "占位公钥 / placeholder update key"
  scripts/update_signing_key.sh sign dist/LuluPet.zip > dist/LuluPet.zip.sig || die "签名失败 / signing failed"
  scripts/update_signing_key.sh verify dist/LuluPet.zip dist/LuluPet.zip.sig || die "签名和编进 App 的公钥对不上 / signature does not verify against the compiled-in key"
  ok "dist/LuluPet.zip.sig（Ed25519，已用 App 里的公钥验证）/ signed and verified"
}

# ---------------------------------------------------------------- install
snapshot_user_data() {   # prints the four values that must survive the install
  local lines=missing
  [[ -f "$HISTORY" ]] && lines="$(wc -l < "$HISTORY" | tr -d ' ')"
  echo "history.jsonl lines: $lines"
  echo "petOrigin: $(defaults read "$APP_ID" petOrigin 2>/dev/null | tr -s '[:space:]' ' ' || echo missing)"
  echo "petScale: $(defaults read "$APP_ID" petScale 2>/dev/null || echo missing)"
  echo "config md5: $(defaults read "$APP_ID" config 2>/dev/null | md5 -q || echo missing)"
}

install_local() {
  step "安装到本机 / Install to $INSTALLED"
  snapshot_user_data > "$TMP/before"
  sed 's/^/    /' "$TMP/before"

  local pid i
  pid="$(pgrep -f "${INSTALLED}/Contents/MacOS/LuluPet$" || true)"
  if [[ -n "$pid" ]]; then
    echo "    退出正在运行的 LuluPet / stopping running app (pid $pid)"
    kill -TERM $pid 2>/dev/null || true
    for i in 1 2 3 4 5; do pgrep -f "${INSTALLED}/Contents/MacOS/LuluPet$" >/dev/null || break; sleep 1; done
    pid="$(pgrep -f "${INSTALLED}/Contents/MacOS/LuluPet$" || true)"
    if [[ -n "$pid" ]]; then warn "5 秒没退出，kill -9 / force kill"; kill -9 $pid 2>/dev/null || true; sleep 1; fi
  fi

  rm -rf "${INSTALLED}.new" "${INSTALLED}.old"
  ditto dist/LuluPet.app "${INSTALLED}.new"
  if [[ -d "$INSTALLED" ]]; then mv "$INSTALLED" "${INSTALLED}.old"; fi
  mv "${INSTALLED}.new" "$INSTALLED"
  rm -rf "${INSTALLED}.old"
  codesign --verify --deep --strict "$INSTALLED" || die "安装后签名校验失败 / installed app fails codesign verify"
  open "$INSTALLED"
  sleep 4

  snapshot_user_data > "$TMP/after"
  if ! cmp -s "$TMP/before" "$TMP/after"; then
    diff "$TMP/before" "$TMP/after" | sed 's/^/    /' >&2
    die "装完后用户数据变了（上面），停下来没推 GitHub / user data changed after install — stopped before publishing"
  fi
  ok "记录 / 位置 / 大小 / 配置 都没变 / history, origin, scale, config unchanged"

  local old
  for old in "$HOME"/Desktop/LuluPet-v*.zip; do
    if [[ -e "$old" && "$old" != "$HOME/Desktop/LuluPet-v$VER.zip" ]]; then rm -f "$old"; fi
  done
  cp dist/LuluPet.zip "$HOME/Desktop/LuluPet-v$VER.zip"
  ok "~/Desktop/LuluPet-v$VER.zip"
}

# ---------------------------------------------------------------- commit + publish
commit_master() {
  step "提交 master / Commit on master"
  local p
  for p in "${RELEASE_FILES[@]}"; do
    if [[ -e "$p" ]]; then git add -A -- "$p"; fi
  done
  if git diff --cached --quiet; then
    ok "没有要提交的（发版改动已经在 HEAD 里）/ nothing to commit — release changes already in HEAD"
  else
    git commit -q -m "v$VER: release (changelog, docs)" -m "$TRAILER"
    ok "$(git log -1 --format='%h %s')"
  fi
}

release_notes() {
  python3 - "$VER" <<'PY'
import json, sys
for e in json.load(open("assets/changelog.json", encoding="utf-8")):
    if e["version"] == sys.argv[1]:
        print("\n".join("- " + it for it in e["items"]))
        # Install footer (first-time installers land on this page): keep in sync with .claude/skills/release/SKILL.md.
        print("\n---\n第一次安装？先把 LuluPet 拖进「应用程序」，再按 "
              "[README「安装」第 3 步](https://github.com/richardzhuang0412/LuluPet#安装3-步)放行"
              "（macOS 15 / 26：系统设置 → 隐私与安全性 → 仍要打开）。"
              "Apple 芯片（M1 及以后）、macOS 14+，约 190 MB。")
PY
}

publish_github() {
  step "发布到 GitHub / Publish to github.com/$REPO"
  local T C
  T="$(scripts/public_tree.sh)"
  privacy_check "$T"
  if [[ "$(git rev-parse 'release^{tree}')" == "$T" ]]; then
    C="$(git rev-parse release)"
    ok "公开树和 release 一样，沿用 ${C:0:7} / public tree unchanged, reusing release head"
  else
    C="$(GIT_AUTHOR_NAME="$AUTHOR_NAME" GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
         GIT_COMMITTER_NAME="$AUTHOR_NAME" GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
         git commit-tree "$T" -p release -m "噜噜桌宠 v$VER" -m "$TRAILER")"
    git branch -f release "$C"
    ok "release → ${C:0:7}"
  fi
  git push github "${C}:refs/heads/main"
  ok "github main → ${C:0:7}"

  local notes; notes="$(release_notes)"
  mkdir -p "$TMP/asset"
  cp dist/LuluPet.zip "$TMP/asset/LuluPet.zip"   # the in-app updater downloads the asset named LuluPet.zip …
  cp dist/LuluPet.zip.sig "$TMP/asset/LuluPet.zip.sig"   # … and checks the signature in LuluPet.zip.sig
  scripts/update_signing_key.sh verify "$TMP/asset/LuluPet.zip" "$TMP/asset/LuluPet.zip.sig" || die "上传前签名校验失败 / signature check failed before upload"
  gh release create "v$VER" --repo "$REPO" --target main --title "v$VER" --notes "$notes" "$TMP/asset/LuluPet.zip" "$TMP/asset/LuluPet.zip.sig"
  ok "GitHub release v$VER（附件 LuluPet.zip + LuluPet.zip.sig）"
}

# ---------------------------------------------------------------- main
preflight
run_tests

if [[ $DRY == 1 ]]; then
  privacy_check "$(scripts/public_tree.sh)"
  step "Dry run 通过 / passed — 正式发版会做 / a real run would:"
  echo "    build dist/LuluPet.app + zip → $([[ $INSTALL == 1 ]] && echo "install to $INSTALLED, ~/Desktop/LuluPet-v$VER.zip → ")commit on master → public tree → release branch → push github main → gh release v$VER"
  echo "    Release notes:"; release_notes | sed 's/^/      /'
  exit 0
fi

build
sign_zip
if [[ $INSTALL == 1 ]]; then install_local; else warn "跳过本机安装 / --no-install: not installing"; fi
commit_master
publish_github

step "完成 / Done: v$VER"
echo "    https://github.com/$REPO/releases/tag/v$VER"
