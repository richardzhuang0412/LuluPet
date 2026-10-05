#!/usr/bin/env bash
# Update-signing key management (Ed25519). The app only installs release zips whose signature verifies against the
# PUBLIC key compiled into Sources/LuluCore/UpdateKey.swift; the PRIVATE key lives only on the release machine.
#
#   scripts/update_signing_key.sh init     create the key (refuses if one exists), rewrite UpdateKey.swift with the public key
#   scripts/update_signing_key.sh pubkey   print the public key (base64)
#   scripts/update_signing_key.sh sign F   print the base64 signature of file F's exact bytes
#   scripts/update_signing_key.sh verify F SIG_FILE   check a signature against the public key compiled into UpdateKey.swift
#
# Private key location: $LULUPET_SIGNING_KEY_FILE, default ~/.config/lulupet/update_signing_key (mode 0600, dir 0700,
# base64 of the 32-byte seed). BACK IT UP (password manager): lose it and no installed app can ever be updated again.
# (A file rather than the login Keychain: no GUI prompts when release.sh runs unattended.)
# $LULUPET_UPDATE_KEY_SWIFT overrides the Swift file `init` rewrites / `verify` reads (tests only).
set -euo pipefail
cd "$(dirname "$0")/.."
KEYFILE="${LULUPET_SIGNING_KEY_FILE:-$HOME/.config/lulupet/update_signing_key}"
SWIFT_KEY="${LULUPET_UPDATE_KEY_SWIFT:-Sources/LuluCore/UpdateKey.swift}"
CACHE="${TMPDIR:-/tmp}/lulupet-ed25519-tool-$(id -u)"

tool() {   # compiled once per source change
  local src="scripts/ed25519_tool.swift" bin
  bin="$CACHE/ed25519_tool-$(shasum "$src" | cut -c1-12)"
  if [[ ! -x "$bin" ]]; then
    mkdir -p "$CACHE"; chmod 700 "$CACHE"
    swiftc -O -o "$bin" "$src" >&2 || true
    [[ -x "$bin" ]] || { echo "could not compile scripts/ed25519_tool.swift" >&2; exit 1; }
  fi
  "$bin" "$@"
}
need_key() { [[ -s "$KEYFILE" ]] || { echo "no signing key at $KEYFILE — run: scripts/update_signing_key.sh init" >&2; exit 1; }; }

case "${1:-}" in
  init)
    [[ ! -e "$KEYFILE" ]] || { echo "refusing: $KEYFILE already exists (rotation: see README 开发者 → 发布签名)" >&2; exit 1; }
    mkdir -p "$(dirname "$KEYFILE")"; chmod 700 "$(dirname "$KEYFILE")"
    ( umask 077; tool gen > "$KEYFILE" )
    chmod 600 "$KEYFILE"
    pub="$(tool pub "$(cat "$KEYFILE")")"
    python3 - "$SWIFT_KEY" "$pub" <<'PY'
import re, sys
path, pub = sys.argv[1:]
s = open(path, encoding="utf-8").read()
s2 = re.sub(r'(publicKeyBase64 = ")[^"]*(")', lambda m: m.group(1) + pub + m.group(2), s)
s2 = re.sub(r'[ \t]*// UPDATE-KEY-PLACEHOLDER[^\n]*\n', '', s2)
assert s2 != s, "could not rewrite " + path
open(path, "w", encoding="utf-8").write(s2)
PY
    echo "private key: $KEYFILE (0600) — back it up now"
    echo "public key:  $pub"
    echo "rewrote $SWIFT_KEY — commit it; releases signed with this key are accepted by apps built from that commit"
    ;;
  pubkey) need_key; tool pub "$(cat "$KEYFILE")" ;;
  sign)
    need_key; [[ -f "${2:-}" ]] || { echo "usage: $0 sign <file>" >&2; exit 2; }
    tool sign "$(cat "$KEYFILE")" "$2" ;;
  verify)
    [[ -f "${2:-}" && -f "${3:-}" ]] || { echo "usage: $0 verify <file> <sig-file>" >&2; exit 2; }
    pub="$(sed -n 's/.*publicKeyBase64 = "\(.*\)".*/\1/p' "$SWIFT_KEY")"
    [[ -n "$pub" && "$pub" != *PLACEHOLDER* ]] || { echo "UpdateKey.swift still has the placeholder public key" >&2; exit 1; }
    tool verify "$pub" "$2" "$(cat "$3")" ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
