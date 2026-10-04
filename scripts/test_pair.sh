#!/bin/bash
# 本机一对一测试：在这台 Mac 上同时开两只「测试用」宠物（test-lulu / test-lumei），互相串门、发消息。
# 它们用独立的设置和记录（profile），和你们俩的正式版完全分开：
#   - 设置在 lulupet.test-lulu / lulupet.test-lumei 里，记录在 ~/Library/Application Support/LuluPet/test-*/
#   - 用一个单独的测试配对码，所以 Firebase 里是另一块数据（/pairs/<测试码>），碰不到正式记录
#
#   scripts/test_pair.sh start           两只测试宠物，连正式的 Firebase（自动读取你现在的数据库地址）+ 测试配对码
#   scripts/test_pair.sh start --local   改用本机假服务器（tools/fake_firebase.py），完全不联网
#   scripts/test_pair.sh start --blank   不预填配置：两只都从欢迎窗开始，用来测「第一次打开」的流程
#   scripts/test_pair.sh stop            关掉两只测试宠物（和本机假服务器）
#   scripts/test_pair.sh reset           关掉并清空测试用的设置、记录和测试配对码（正式版不受影响）
#
# 正式版的 /Applications/LuluPet.app 照常运行，不受影响。测试宠物用的就是同一个 app（所以永远是你装的最新版）。
set -euo pipefail
cd "$(dirname "$0")/.."

APP=/Applications/LuluPet.app
PROFILES=(test-lulu test-lumei)
SUPPORT="$HOME/Library/Application Support/LuluPet"
CODE_FILE="$SUPPORT/test-pair-code"
FAKE_PORT=8765
FAKE_PID_FILE="$SUPPORT/test-fake-firebase.pid"

stop() {
    for p in "${PROFILES[@]}"; do pkill -f -- "--profile $p" 2>/dev/null || true; done
    if [ -f "$FAKE_PID_FILE" ]; then kill "$(cat "$FAKE_PID_FILE")" 2>/dev/null || true; rm -f "$FAKE_PID_FILE"; fi
}

# Seeds lulupet.<profile> with a config (role, the test pair code, the database URL) unless one is already there.
seed() {
    local profile=$1 role=$2 url=$3 code=$4
    if defaults read "lulupet.$profile" config >/dev/null 2>&1; then return; fi
    local hex
    hex=$(python3 -c 'import json,sys; print(json.dumps({"role":sys.argv[1],"pairCode":sys.argv[2],"databaseURL":sys.argv[3]}).encode().hex())' "$role" "$code" "$url")
    defaults write "lulupet.$profile" config -data "$hex"
    defaults write "lulupet.$profile" showInDock -bool false
}

case "${1:-}" in
start)
    mode=${2:-}
    [ -d "$APP" ] || { echo "找不到 $APP，先装好正式版"; exit 1; }
    stop
    mkdir -p "$SUPPORT"
    if [ "$mode" != "--blank" ]; then
        [ -f "$CODE_FILE" ] || python3 -c 'import secrets; print("".join(secrets.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(24)))' > "$CODE_FILE"
        code=$(cat "$CODE_FILE")
        if [ "$mode" = "--local" ]; then
            nohup python3 tools/fake_firebase.py --port "$FAKE_PORT" >/dev/null 2>&1 &
            echo $! > "$FAKE_PID_FILE"
            url="http://127.0.0.1:$FAKE_PORT"
            # A config made for the other backend is replaced.
            for p in "${PROFILES[@]}"; do defaults delete "lulupet.$p" config 2>/dev/null || true; done
        else
            url=$(defaults export com.lulupet.app - | python3 -c 'import plistlib,sys,json; print(json.loads(plistlib.loads(sys.stdin.buffer.read())["config"])["databaseURL"])') \
                || { echo "读不到正式版的数据库地址（正式版还没设置好？）可以改用 --local"; exit 1; }
            for p in "${PROFILES[@]}"; do
                if defaults read "lulupet.$p" config >/dev/null 2>&1 \
                   && ! defaults export "lulupet.$p" - | python3 -c 'import plistlib,sys,json; sys.exit(0 if json.loads(plistlib.loads(sys.stdin.buffer.read())["config"])["databaseURL"].startswith("https") else 1)'; then
                    defaults delete "lulupet.$p" config
                fi
            done
        fi
        seed test-lulu lulu "$url" "$code"
        seed test-lumei lumei "$url" "$code"
    fi
    for p in "${PROFILES[@]}"; do open -n -a "$APP" --args --profile "$p"; done
    echo "已开两只测试宠物（test-lulu / test-lumei）${mode:+ $mode}。日志：~/Library/Logs/LuluPet/LuluPet-test-*.log"
    echo "关掉：scripts/test_pair.sh stop"
    ;;
stop)
    stop
    echo "测试宠物已关掉"
    ;;
reset)
    stop
    for p in "${PROFILES[@]}"; do
        defaults delete "lulupet.$p" 2>/dev/null || true
        rm -f "$HOME/Library/Preferences/lulupet.$p.plist"
        rm -rf "${SUPPORT:?}/$p"
    done
    rm -f "$CODE_FILE"
    echo "测试用的设置、记录和配对码都清掉了（正式版没动）"
    ;;
*)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
