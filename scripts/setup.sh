#!/usr/bin/env bash
# 噜噜桌宠 LuluPet —— 新手一键安装。
#
# 用法：./scripts/setup.sh [--rebuild-assets]
#   检查 macOS ≥ 14、Command Line Tools、Swift ≥ 6，然后构建 dist/LuluPet.app 和 dist/LuluPet.zip。
#   --rebuild-assets  同时从 assets/ 重新生成 Resources/（需要 python3 + Pillow）。平时不需要：
#                     生成好的 Resources/ 已经提交在仓库里。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

REBUILD=0
for arg in "$@"; do
  case "$arg" in
    --rebuild-assets) REBUILD=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg（用 --help 查看用法）" >&2; exit 2 ;;
  esac
done

ok()   { echo "  ✓ $*"; }
fail() { echo; echo "  ✗ $*" >&2; exit 1; }

echo "==> 检查环境"

# 1. macOS ≥ 14
[[ "$(uname -s)" == "Darwin" ]] || fail "LuluPet 只能在 macOS 上运行."
OS_VER="$(sw_vers -productVersion)"
if (( ${OS_VER%%.*} < 14 )); then
  fail "需要 macOS 14 (Sonoma) 或更新，你的是 $OS_VER。"
fi
ok "macOS $OS_VER"

# 2. Command Line Tools
if ! DEV_DIR="$(xcode-select -p 2>/dev/null)" || [[ ! -d "$DEV_DIR" ]]; then
  fail "没有找到 Xcode Command Line Tools。请在终端运行下面这行，装好后再运行 ./scripts/setup.sh：

      xcode-select --install"
fi
ok "Command Line Tools: $DEV_DIR"

# 3. Swift ≥ 6.0 (Package.swift uses swift-tools-version 6.0)
command -v swift >/dev/null || fail "找不到 swift 命令，请重新安装 Command Line Tools：xcode-select --install"
SWIFT_VER="$(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -1)"
[[ -n "$SWIFT_VER" ]] || fail "无法识别 Swift 版本：$(swift --version 2>&1 | head -1)"
if (( ${SWIFT_VER%%.*} < 6 )); then
  fail "需要 Swift 6.0 或更新，你的是 $SWIFT_VER。请更新 Command Line Tools：
      softwareupdate --list    # 然后安装 Command Line Tools 的更新
  或者删掉旧版重新装：sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
fi
ok "Swift $SWIFT_VER"

# 4. Python + Pillow — only for --rebuild-assets
BUILD_ARGS=()
if [[ "$REBUILD" == "1" ]]; then
  command -v python3 >/dev/null || fail "--rebuild-assets 需要 python3（Command Line Tools 自带）。"
  if ! python3 -c 'import PIL' 2>/dev/null; then
    fail "--rebuild-assets 需要 Pillow（Python 图片库）。安装：

      python3 -m pip install --user pillow

  它只用来从 assets/ 里的 GIF 重新生成 Resources/（抠图、缩放、转 WebP）。
  只是想用 App 的话不需要它：直接运行 ./scripts/setup.sh（不带参数）即可。"
  fi
  ok "python3 + Pillow（将重新生成素材）"
  BUILD_ARGS+=(--rebuild-assets)
elif [[ ! -d Resources/Sprites ]]; then
  fail "Resources/ 不见了（仓库应该自带）。请重新 git clone，或者用 ./scripts/setup.sh --rebuild-assets 重新生成。"
fi

echo
echo "==> 开始构建（第一次大约 1–3 分钟）"
./scripts/build_app.sh ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}

APP="$ROOT/dist/LuluPet.app"
[[ -d "$APP" ]] || fail "构建结束了，但没有找到 $APP"

cat <<EOF

🎉 构建成功！

  App：    $APP
  压缩包：  $ROOT/dist/LuluPet.zip   （发给对方用，隔空投送 / 微信都行）

接下来：
  1. 把 LuluPet 拖进「应用程序」文件夹：
       open "$ROOT/dist"
  2. 第一次打开会被系统拦住（这个 App 没有签名，是正常的）：
       - macOS 15 及以后：双击一次 → 点「完成」→ 打开 系统设置 → 隐私与安全性，
         往下滚，找到"已阻止 LuluPet"，点「仍要打开」，输入开机密码确认。
       - macOS 14：在「应用程序」里右键点 LuluPet → 打开 → 再点「打开」。
  3. 建一个你们俩自己的 Firebase 数据库（免费，约 10 分钟）：
       $ROOT/docs/firebase-setup.md
  4. 两个人都打开 App：一个选「我是噜噜」，一个选「我是噜妹」，
     只让一个人点「生成」配对码发给对方，两边填同一个数据库地址，保存。
EOF
