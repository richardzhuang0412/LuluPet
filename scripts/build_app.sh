#!/usr/bin/env bash
# Build dist/LuluPet.app (ad-hoc signed) and dist/LuluPet.zip.
# Requires only Command Line Tools (swift, codesign, ditto): the generated Resources/ (sprites, clips,
# stickers) are committed, so a fresh clone builds without Python.
#
# Usage: scripts/build_app.sh [--rebuild-assets]
#   --rebuild-assets              regenerate Resources/ from assets/ (python3 + Pillow + tools/cutout,
#                                 i.e. macOS Vision); only needed after changing assets/*.json or GIFs.
#                                 Resources/ is also generated automatically when it is missing.
# Env overrides:
#   LULUPET_REBUILD_ASSETS=1      same as --rebuild-assets
#   LULUPET_BIN=/path/to/binary   skip `swift build` and package this binary instead
set -euo pipefail

REBUILD_ASSETS="${LULUPET_REBUILD_ASSETS:-0}"
for arg in "$@"; do
  case "$arg" in
    --rebuild-assets) REBUILD_ASSETS=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "error: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP="dist/LuluPet.app"

# Version: marketing version from ./VERSION (bump it for every release you hand out),
# build number = git commit count (always increases). See docs/upgrade-compat.md.
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: VERSION must look like 1.2.3, got '$VERSION'" >&2; exit 1; }
echo "==> LuluPet $VERSION ($BUILD)"
ICNS="assets/AppIcon.icns"

# 1. Sprites (committed; regenerate only on request or when missing)
if [[ "$REBUILD_ASSETS" == "1" ]]; then
  echo "==> --rebuild-assets: regenerating Resources/ from assets/"
  python3 tools/build_sprites.py
elif [[ ! -d Resources/Sprites || ! -d Resources/Couples || ! -d Resources/Clips || ! -d Resources/Stickers || ( -f assets/reactions.json && ! -f Resources/reactions.json ) ]]; then
  echo "==> Resources (Sprites / Couples / Clips / Stickers / reactions.json) missing, generating sprites"
  python3 tools/build_sprites.py
else
  echo "==> Using committed Resources/ (pass --rebuild-assets to regenerate)"
  if [[ -f assets/sounds.json && ! -f Resources/Sounds/sounds.json ]]; then
    echo "==> Resources/Sounds missing, copying sounds (stdlib python only)"
    python3 tools/build_sounds.py
  fi
fi

# 1b. v0.13 update log: always refresh the copy (a plain file copy, no python needed)
if [[ -f assets/changelog.json ]]; then
  cp assets/changelog.json Resources/changelog.json
fi

# 2. App icon
if [[ ! -f "$ICNS" ]]; then
  echo "==> Generating app icon"
  python3 tools/make_icon.py
fi

# 3. Binary
if [[ -n "${LULUPET_BIN:-}" ]]; then
  BIN="$LULUPET_BIN"
  echo "==> Using prebuilt binary $BIN"
else
  echo "==> swift build -c release"
  swift build -c release --product LuluPet
  BIN="$(swift build -c release --show-bin-path)/LuluPet"
fi
[[ -x "$BIN" ]] || { echo "error: binary not found: $BIN" >&2; exit 1; }

# 4. Bundle layout
echo "==> Assembling $APP"
rm -rf "$APP" dist/LuluPet.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LuluPet"
cp -R Resources/. "$APP/Contents/Resources/"

ICON_KEY=""
if [[ -f "$ICNS" ]]; then
  cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>LuluPet</string>
    <key>CFBundleDisplayName</key>
    <string>噜噜桌宠</string>
    <key>CFBundleIdentifier</key>
    <string>com.lulupet.app</string>
    <key>CFBundleExecutable</key>
    <string>LuluPet</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
${ICON_KEY}
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# 5. Ad-hoc sign
echo "==> codesign (ad-hoc)"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

# 6. Zip for AirDrop
echo "==> Zipping"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" dist/LuluPet.zip   # no ._ AppleDouble clutter

echo
echo "Done:"
du -sh "$APP" | sed "s|$APP|$ROOT/$APP|"
du -sh dist/LuluPet.zip | sed "s|dist/LuluPet.zip|$ROOT/dist/LuluPet.zip|"
