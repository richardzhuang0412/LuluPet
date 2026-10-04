#!/usr/bin/env python3
"""Renders the README demo GIFs / MP4s (docs/demo/<name>.gif|.mp4) — no screen recording, nothing on screen.

    tools/make_demos.sh                    # all README scenes (sets up build/demo-venv with Pillow + imageio-ffmpeg)
    tools/make_demos.sh daily visit        # only these scenes
    tools/make_demos.sh --keep             # keep the raw frames (build/demo-work/<scene>/)

Each scene launches one or two LuluPet instances with `--offscreen` (windows below the desktop picture, no 🍊)
and throwaway profiles against tools/fake_firebase.py, drives them with the hidden demo flags (--auto-send,
--demo-ack, --demo-dnd…) and records them with `--record` (the app renders its own windows at 2x). The app
records over a transparent background; this script paints the wallpaper (and the title bar / background of
titled windows such as 更新日志 and the welcome window, which the app's renderer leaves out) underneath.
Two-desktop scenes go side by side, aligned by timestamp. Scenes run one at a time; every instance, fake server
and profile is removed afterwards (also on Ctrl-C). Encoding runs niced in the background (2 threads).

Output (HD): an MP4 at the full 2x resolution (H.264 crf 18, yuv420p, faststart) and a GIF 1440 px wide for
two desktops / 960 px for one (ffmpeg palettegen stats_mode=diff + paletteuse sierra2_4a, ≤ ~10 MB: fewer fps
first, then narrower).
"""
import argparse
import atexit
import http.server
import json
import os
import plistlib
import random
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / ".build" / "debug" / "LuluPet"
OUT = ROOT / "docs" / "demo"
WORK = ROOT / "build" / "demo-work"
FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"   # index 0 = W3, index 2 = W6
MAX_GIF = 10_000_000
GIF_WIDE, GIF_SINGLE = 1440, 960   # GIF width: two desktops side by side / one desktop
SCALE = 2         # the app records at 2x (DemoRecorder)
PET_WIDTH = 167   # the pet window at size 1.0
LEFT_LABEL, RIGHT_LABEL = "你的桌面（噜噜）", "TA 的桌面（噜妹）"
# Every profile this script creates starts with this prefix (never the user's default / demo* / try* profiles).
PROFILE_PREFIX = "lprec"

# ---------------------------------------------------------------------------------------------- scenes
#
# Each scene: `instances` (role + extra flags; one = single desktop, two = side by side,噜噜 left),
# `seconds` recorded, `trim` (start, end) seconds kept, `region` (the crop in points: (w, h) at the screen's
# bottom-right where the pets sit — the same for both desktops — "auto:minW,minH" around the windows, or
# "center:W,H" in the middle of the screen), `fps`, `caption` (README).
# Optional: `seed` (fake-database paths written before launch), per instance `cfg` (config extras) and `prefs`
# (defaults keys written as JSON data, e.g. myPlace), `width` (GIF width; default 1440 / 960), `segments` (a list
# of partial scenes — instances / seconds / trim … — recorded one after another and joined; they share the
# scene's region), `update_feed` (a local fake GitHub release feed, see UpdateFeed), `readme=False` (only
# rendered when named), `hold_blank_pet` (skip frames where the pet window shows nothing). Flag times are seconds after launch; both instances of a scene are launched together.
# Scenes named v0… are internal checks: rendered only when named on the command line.

COMMON = ["--presence-fast", "--fidget-seconds", "600", "--quiet-seconds", "600", "--doze-seconds", "900",
          "--rotate-seconds", "100000"]

# Neutral demo cities (no FakeWeather place: --fake-weather answers ⛅ 20° for them; --demo-think forces the 想 TA weather).
MY_PLACE = {"name": "杭州", "admin": "浙江", "country": "中国", "latitude": 30.27, "longitude": 120.15, "timezone": "Asia/Shanghai"}
TA_PLACE = {"name": "伦敦", "admin": "英格兰", "country": "英国", "latitude": 51.51, "longitude": -0.13, "timezone": "Europe/London"}
CITY_SEED = {"presence/lumei": {"lastSeen": 0, "place": TA_PLACE}}

SCENES = {
    "daily": dict(
        caption="日常：待机、随机小动作，单击它冒爱心；一会儿没人理就安静地站好（省电）",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--demo-fidget", "1.8", "--demo-click", "9.3",
                                             "--quiet-seconds", "12"])],
        # Fidget clips run up to 7 s and a click on a busy pet is ignored: the click comes after it.
        seconds=16, trim=(1.2, 15.6), region=(460, 300), fps=15, menubar=True),
    "visit": dict(
        caption="送信串门：发个表情，噜噜亲自跑去 TA 的桌面送，见面、冒气泡、TA 点「收到 ❤️」，再跑回来说「送到啦」",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "sticker:hug@3"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-ack", "11"])],
        seconds=22, trim=(2.2, 21), region=(440, 450), fps=12),
    "collide": dict(
        caption="撞车：两个人同时发，先在一边见面，再一起走到另一边见一面，最后各回各家",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "sticker:hug@T"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--auto-send", "sticker:nuzzle@T"])],
        # Each live stream event held 1.5 s: both sends leave before either arrives (a real collision).
        seconds=33, trim=(2.2, 32.5), region=(440, 450), fps=12, server_args=["--stream-delay-ms", "1500"]),
    "offline": dict(
        caption="TA 不在：跑到边上找一圈，回来告诉你「TA 不在，先放在 TA 那儿啦」",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "text:晚上一起吃火锅吧 🍲@2"])],
        # 噜妹 was online before and signed off (lastSeen 0): "TA 不在", not "还没配对".
        seed={"presence/lumei": {"lastSeen": 0}},
        seconds=10, trim=(1.2, 9.8), region=(540, 300), pet_right=140, fps=15, menubar=True),
    "dnd": dict(
        caption="勿扰模式：TA 挂着「😤 生气中」，你发的都先攒着；TA 关掉勿扰，噜噜送来一张诚意清单",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "poke@3.5,text:别生气啦，晚上请你喝奶茶 🧋@6.5,sticker:hug@9.5"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-dnd", "angry@0.5", "--demo-dnd-off", "13"])],
        seconds=25, trim=(2.5, 24.5), region=(520, 450), pet_right=170, fps=12),
    "compose": dict(
        caption="传话面板：发爱心、去找 TA、24 个快捷表情；「记录」按天分组，可以一直往回翻",
        instances=[dict(role="lulu", prefs=dict(myPlace=MY_PLACE), flags=["--outfit", "classic", "--demo-history", "--demo-compose",
                                             "--demo-open-history-at", "5", "--fake-weather"])],
        seed=CITY_SEED,
        seconds=10, trim=(1.0, 9.8), region=(600, 660), pet_right=160, fps=12, menubar=True),
    "v090_hug_sit": dict(
        caption="v0.9: hug_sit is bound to 我想你了 (hug_missyou)",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "sticker:missyou@3", "--force-couple", "hug_sit"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-ack", "13", "--force-couple", "hug_sit"])],
        seconds=24, trim=(2.2, 22.5), region=(440, 450), fps=12),
    "v090_angry": dict(
        caption="v0.9: angry is bound to 哼！ (angry_hmph)",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "sticker:angry@3", "--force-couple", "angry"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-ack", "13", "--force-couple", "angry"])],
        seconds=24, trim=(2.2, 22.5), region=(440, 450), fps=12),
    "v090_sleep": dict(
        caption="v0.9: sleep is bound to 打呼噜 (sleep_snore)",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "sticker:night@3", "--force-couple", "sleep"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-ack", "13", "--force-couple", "sleep"])],
        seconds=24, trim=(2.2, 22.5), region=(440, 450), fps=12),
    "v090_comein": dict(
        caption="v0.9: 噜噜 'hi' visitor clip with its aligned voice line (lulu_comein)",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "sticker:hi@3"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-ack", "13"])],
        seconds=22, trim=(2.2, 20.5), region=(440, 450), fps=12),
    "remind": dict(
        caption="叫 TA 喝水：噜噜跑去 TA 的桌面叫 TA 喝水，TA 点「喝了 ✓」，噜噜回家后冒一句「TA 喝啦」",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "remind:water@3"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-remind-reply", "comply@11"])],
        seconds=26, trim=(2.2, 25), region=(440, 450), fps=12),
    "tools": dict(
        caption="小工具：番茄钟专注倒计时（宠物捧着书陪你），到点提醒你喝水，点「喝了 ✓」记一杯",
        # A 10 s focus round from 1 s; the water bubble pops during it, 喝了 at 8 s, 专注完成 at ~11 s.
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--demo-compose", "--demo-compose-tab", "tools",
                                             "--demo-pomodoro", "10", "--demo-reminder", "water@4",
                                             "--demo-remind-reply", "comply@8"])],
        seconds=16, trim=(1.0, 15.5), region=(600, 640), pet_right=160, fps=12, menubar=True),
    "modes": dict(
        caption="朋友模式：两个人可以选同一个角色，见面一起开心，没有亲密动作",
        labels=("你的桌面（噜噜）", "朋友的桌面（也是噜噜）"),
        instances=[dict(role="lulu", cfg=dict(mode="friend", character="lulu"), flags=["--outfit", "classic", "--auto-send", "sticker:run@3"]),
                   dict(role="lumei", cfg=dict(mode="friend", character="lulu"), flags=["--outfit", "bear", "--demo-ack", "11"])],
        seconds=22, trim=(2.2, 20), region=(440, 450), fps=12),
    "weather": dict(
        caption="天气：宠物偶尔「想 TA」，头顶冒出 TA 那边的天气；传话面板顶部是你们两边的天气和当地时间",
        instances=[dict(role="lulu", prefs=dict(myPlace=MY_PLACE), flags=["--outfit", "classic", "--fake-weather",
                                                                         "--demo-think", "rain@1.5", "--demo-hotkey", "compose@9"])],
        seed=CITY_SEED,
        seconds=15, trim=(1.0, 14.8), region=(600, 660), pet_right=160, fps=12, menubar=True),
    "whatsnew": dict(
        caption="更新日志：升级后宠物冒个小卡片，点「看看」就能看到这一版多了什么，还有「待设置」清单",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--fake-app-version", "0.14.1",
                                             "--demo-whatsnew-seen", "0.13.3", "--demo-remind-reply", "comply@5.5"])],
        # The card's「看看」is its first button (--demo-remind-reply presses a bubble's buttons); the window opens centred.
        seconds=13, trim=(1.0, 12.8), region="auto:640,520", pet_right=420, fps=12, menubar=True),
    # v0.11 modes (docs/superpowers/specs/2026-10-05-modes-design.md): config extras (mode / character) per instance.
    # Friends never see intimate clips; two of the same character never get a two-person clip (both play happy + hearts).
    "v011_friend_same": dict(
        caption="v0.11 朋友：两只噜噜见面，没有双人片段，各自开心 + 冒爱心 (bothHappy)",
        labels=("你的桌面（噜噜）", "TA 的桌面（也是噜噜）"),
        instances=[dict(role="lulu", cfg=dict(mode="friend", character="lulu"), flags=["--outfit", "classic", "--auto-send", "sticker:run@3"]),
                   dict(role="lumei", cfg=dict(mode="friend", character="lulu"), flags=["--outfit", "classic", "--demo-ack", "11"])],
        seconds=22, trim=(2.2, 20), region=(440, 450), fps=12),
    "v011_friend_kiss_refused": dict(
        caption="v0.11 朋友：噜噜 + 噜妹，--force-couple kiss 被拒绝（亲密片段），回到 bothHappy",
        labels=("你的桌面（噜噜）", "TA 的桌面（噜妹）"),
        instances=[dict(role="lulu", cfg=dict(mode="friend", character="lulu"), flags=["--outfit", "classic", "--auto-send", "sticker:kiss@3", "--force-couple", "kiss"]),
                   dict(role="lumei", cfg=dict(mode="friend", character="lumei"), flags=["--outfit", "lace", "--demo-ack", "11", "--force-couple", "kiss"])],
        seconds=22, trim=(2.2, 20), region=(440, 450), fps=12),
    "v011_friend_mixed": dict(
        caption="v0.11 朋友：噜噜 + 噜妹，池子里的亲密片段被滤掉，只播非亲密的 (happy / dance)",
        labels=("你的桌面（噜噜）", "TA 的桌面（噜妹）"),
        instances=[dict(role="lulu", cfg=dict(mode="friend", character="lulu"), flags=["--outfit", "classic", "--auto-send", "sticker:run@3"]),
                   dict(role="lumei", cfg=dict(mode="friend", character="lumei"), flags=["--outfit", "lace", "--demo-ack", "11"])],
        seconds=22, trim=(2.2, 20), region=(440, 450), fps=12),
    "v011_couple": dict(
        caption="v0.11 情侣：和以前完全一样（hug）",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "sticker:hug@3", "--force-couple", "hug"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-ack", "11", "--force-couple", "hug"])],
        seconds=22, trim=(2.2, 20), region=(440, 450), fps=12),
    "outfits": dict(
        caption="换装和大小：「选择造型」直接挑一套；鼠标移上去拖右下角的小圆点等比例缩放",
        instances=[dict(role="lulu", flags=["--outfit", "classic",
                                             "--demo-outfit", "choose:bear@2,choose:panda@4,choose:cherry@6,choose:caishen@8",
                                             "--demo-resize-handle", "--demo-resize-drag", "-70,70@10.5",
                                             "--demo-scale", "1@14"])],
        # The sprite layer is empty for ~0.5 s while a new outfit loads: hold the last frame with the pet instead.
        seconds=16, trim=(1.2, 15.8), region=(470, 380), fps=12, menubar=True, hold_blank_pet=True),
    # v0.14 additions. One person: no partner, the panel has only 表情 and 小工具 (two takes, joined).
    "solo": dict(
        caption="一个人模式：桌面上只有自己的一只宠物；双击打开「表情」和「小工具」，开个番茄钟，到点它提醒你喝水",
        segments=[
            dict(instances=[dict(role="lulu", cfg=dict(mode="solo", character="lulu"),
                                 flags=["--outfit", "classic", "--demo-solo-compose"])],
                 seconds=6, trim=(1.0, 5.0)),
            # A 10 s focus round from 1 s; the water bubble pops during it, 喝了 at 8 s, 专注完成 at ~11 s.
            dict(instances=[dict(role="lulu", cfg=dict(mode="solo", character="lulu"),
                                 flags=["--outfit", "classic", "--demo-solo-compose", "--demo-compose-tab", "tools",
                                        "--demo-pomodoro", "10", "--demo-reminder", "water@4",
                                        "--demo-remind-reply", "comply@8"])],
                 seconds=16, trim=(1.4, 15.0)),
        ],
        region=(600, 640), pet_right=160, fps=12, menubar=True),
    # First launch: the welcome window on each step (--demo-welcome N opens it on step N), one take per step.
    "welcome": dict(
        caption="第一次打开：欢迎窗一步步带你选模式 → 角色 → 城市 → 配对",
        segments=[dict(instances=[dict(role="lulu", flags=["--demo-welcome", str(n), "--mode", "couple"])],
                       seconds=4.5, trim=(1.5, 4.2)) for n in (1, 2, 3, 4)],
        # NSWindow.center() puts the window in the upper third: the crop's top sits just above the tallest step.
        region="center:600,470,120", fps=12),
    # 检查更新 against a local fake release feed (UpdateFeed: v0.15.0, a slow fake zip — never a real GitHub call).
    # The app runs from a throwaway .app copy in build/demo-work (the only folder --update-allow-dir allows) and the
    # recording ends mid-download; the fake zip isn't a zip anyway, so nothing could ever be installed.
    "update": dict(
        caption="检查更新：有新版本时宠物冒出「有新版本 · 更新」卡片，点「更新」自动下载，下载完自动安装、重新打开",
        update_feed=True,
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--fake-app-version", "0.14.1",
                                             "--demo-whatsnew-seen", "0.14.1",
                                             "--update-feed", "{FEED}", "--update-allow-dir", "{ALLOW}",
                                             "--update-auto-confirm", "--demo-update-check", "1.5",
                                             "--demo-remind-reply", "comply@5.5"])],
        seconds=15, trim=(1.0, 14.8), region=(560, 440), pet_right=170, fps=12, menubar=True),
    # Placeholder: re-rendered once the 想 TA bubble mirrors TA's outfit / pose (v0.14.2). Not in README yet.
    "think": dict(
        caption="想 TA：宠物偶尔冒个泡泡，里面是 TA 和 TA 那边的天气",
        readme=False,
        instances=[dict(role="lulu", prefs=dict(myPlace=MY_PLACE), flags=["--outfit", "classic", "--fake-weather",
                                                                         "--demo-think", "rain@2"])],
        seed=CITY_SEED,
        seconds=10, trim=(1.0, 9.8), region=(460, 420), pet_right=160, fps=12, menubar=True),
}


# ---------------------------------------------------------------------------------------------- helpers

def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


procs = []          # live child processes (killed on exit)
profiles = []       # profiles created (deleted on exit)


def kill(p):
    if p.poll() is not None:
        return
    p.terminate()
    try:
        p.wait(1.5)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait(3)


def cleanup():
    for p in procs:
        kill(p)
    procs.clear()
    for name in profiles:
        subprocess.run(["defaults", "delete", f"lulupet.{name}"], capture_output=True)
        (Path.home() / "Library/Preferences" / f"lulupet.{name}.plist").unlink(missing_ok=True)
        shutil.rmtree(Path.home() / "Library/Application Support/LuluPet" / name, ignore_errors=True)
    profiles.clear()


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def screen_geometry():
    """(width, height, visible bottom) of the main screen in points."""
    js = ("ObjC.import('AppKit'); var s=$.NSScreen.mainScreen; "
          "[s.frame.size.width, s.frame.size.height, s.visibleFrame.origin.y].join(' ')")
    out = subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True, check=True).stdout
    w, h, y = (float(v) for v in out.split())
    return w, h, y


def make_profile(role, db, pair, origin, extra=None, prefs=None):
    name = f"{PROFILE_PREFIX}-{role}-{os.getpid()}-{random.randrange(10**6)}"
    assert name.startswith(PROFILE_PREFIX + "-")
    profiles.append(name)
    cfg = json.dumps({"role": role, "pairCode": pair, "databaseURL": db, **(extra or {})}).encode()
    subprocess.run(["defaults", "write", f"lulupet.{name}", "config", "-data", cfg.hex()], check=True)
    # Same spot on both desktops: the pet's centre `pet_right` pt from the right edge, feet on the Dock.
    subprocess.run(["defaults", "write", f"lulupet.{name}", "petOrigin", "-string", "{%d, %d}" % origin], check=True)
    for key, value in (prefs or {}).items():   # JSON-data defaults (e.g. myPlace)
        subprocess.run(["defaults", "write", f"lulupet.{name}", key, "-data", json.dumps(value).encode().hex()], check=True)
    # Offscreen pets must not hide when the user has a full-screen window open (tasks/lessons.md).
    subprocess.run(["defaults", "write", f"lulupet.{name}", "autoHideFullscreen", "-bool", "false"], check=True)
    # Silent: a recording must never play sounds on the user's speakers.
    for key in ("soundEnabled", "bgmEnabled"):
        subprocess.run(["defaults", "write", f"lulupet.{name}", key, "-bool", "false"], check=True)
    return name


def wallpaper(path):
    """A soft pastel macOS-like wallpaper (big blurred colour blobs over a diagonal gradient)."""
    if path.exists():
        return
    w, h = 1512, 982
    sw, sh = 48, 32   # the gradient at low resolution, smoothly upscaled
    small = Image.new("RGB", (sw, sh))
    top, mid, bot = (250, 232, 226), (232, 228, 248), (222, 238, 246)
    for y in range(sh):
        for x in range(sw):
            t = x / sw * 0.45 + (1 - y / sh) * 0.55
            a, b, u = (top, mid, t / 0.5) if t < 0.5 else (mid, bot, (t - 0.5) / 0.5)
            small.putpixel((x, y), tuple(int(a[i] + (b[i] - a[i]) * u) for i in range(3)))
    img = small.resize((w, h), Image.BICUBIC)
    blobs = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(blobs)
    for cx, cy, r, col in [(0.18, 0.25, 330, (255, 214, 222, 90)), (0.78, 0.2, 380, (214, 222, 255, 80)),
                           (0.62, 0.78, 420, (210, 244, 232, 90)), (0.1, 0.85, 300, (255, 236, 206, 80))]:
        d.ellipse((cx * w - r, cy * h - r, cx * w + r, cy * h + r), fill=col)
    blobs = blobs.filter(ImageFilter.GaussianBlur(120))
    img = Image.alpha_composite(img.convert("RGBA"), blobs).convert("RGB")
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path)


def clear_background(path):
    """The --record-bg the app draws under its windows: fully transparent (the wallpaper is painted here)."""
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        Image.new("RGBA", (16, 10), (0, 0, 0, 0)).save(path)


# ---------------------------------------------------------------------------------------------- update feed

class UpdateFeed:
    """A fake GitHub "latest release" feed on 127.0.0.1 for the `update` scene (never the real GitHub):
    /latest.json names v0.15.0 with a LuluPet.zip asset; /LuluPet.zip is junk (not a zip, so it could never be
    installed) sent slowly enough that the progress panel climbs during the recording."""
    SIZE = 4_000_000
    SECONDS = 9.0   # for the whole "download"

    def __init__(self):
        port = free_port()
        base = f"http://127.0.0.1:{port}"
        self.url = f"{base}/latest.json"
        feed = json.dumps({"tag_name": "v0.15.0", "draft": False, "prerelease": False, "html_url": f"{base}/release",
                           "body": "演示用的假版本", "assets": [{"name": "LuluPet.zip",
                                                           "browser_download_url": f"{base}/LuluPet.zip"}]}).encode()
        size, seconds = self.SIZE, self.SECONDS

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                if self.path.startswith("/latest.json"):
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(feed)))
                    self.end_headers()
                    self.wfile.write(feed)
                elif self.path.startswith("/LuluPet.zip"):
                    self.send_response(200)
                    self.send_header("Content-Type", "application/zip")
                    self.send_header("Content-Length", str(size))
                    self.end_headers()
                    chunk = 40_000
                    try:
                        for _ in range(size // chunk):
                            self.wfile.write(b"\0" * chunk)
                            self.wfile.flush()
                            time.sleep(seconds * chunk / size)
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                else:
                    self.send_response(404)
                    self.end_headers()

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def throwaway_app(work):
    """A copy of the debug binary as build/demo-work/<scene>/app/LuluPet.app (the updater only updates an .app
    in an allowed folder): returns (executable, folder to allow)."""
    folder = work / "app"
    app = folder / "LuluPet.app"
    macos = app / "Contents" / "MacOS"
    macos.mkdir(parents=True, exist_ok=True)
    shutil.copy2(APP, macos / "LuluPet")
    with open(app / "Contents" / "Info.plist", "wb") as f:   # not com.lulupet.app (tasks/lessons.md)
        plistlib.dump({"CFBundleIdentifier": "com.lulupet.demorec", "CFBundleExecutable": "LuluPet",
                       "CFBundleName": "LuluPet", "CFBundlePackageType": "APPL", "LSUIElement": True}, f)
    return macos / "LuluPet", folder


# ---------------------------------------------------------------------------------------------- recording

def record(name, scene, work, bg):
    """Runs the scene's instances (recording) and returns their frame directories."""
    port = free_port()
    db = f"http://127.0.0.1:{port}"
    server = subprocess.Popen(["nice", "-n", "10", sys.executable, str(ROOT / "tools/fake_firebase.py"), "--port", str(port),
                               *scene.get("server_args", [])],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    procs.append(server)
    for _ in range(50):
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close()
            break
        except OSError:
            time.sleep(0.1)
    pair = "".join(random.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(24))
    for path, value in scene.get("seed", {}).items():
        req = urllib.request.Request(f"{db}/pairs/{pair}/{path}.json", data=json.dumps(value).encode(), method="PUT")
        urllib.request.urlopen(req, timeout=5).read()
    env = dict(os.environ, LULU_RESOURCES=str(ROOT / "Resources"))
    sw, sh, bottom = screen_geometry()
    region = scene["region"]
    if isinstance(region, str) and region.startswith("auto:"):
        region = ["--record-region", "auto", "--record-min", region[5:], "--record-pad", "50"]
    elif isinstance(region, str) and region.startswith("center:"):   # center:W,H[,DY] (DY: points up)
        w, h, *dy = (float(v) for v in region[7:].split(","))
        region = ["--record-region", "%d,%d,%d,%d" % ((sw - w) / 2, (sh - h) / 2 + (dy[0] if dy else 0), w, h)]
    else:
        region = ["--record-region", f"bottom-right:{region[0]},{region[1]}"]
    exe, subst, feed = APP, {}, None
    if scene.get("update_feed"):
        feed = UpdateFeed()
        exe, allow = throwaway_app(work)
        subst = {"{FEED}": feed.url, "{ALLOW}": str(allow)}
    launch = time.time()
    sync_ms = int((launch + 4) * 1000)   # "@T" in a flag: the same absolute moment for both instances
    dirs, running = [], []
    for i, inst in enumerate(scene["instances"]):
        out = work / f"{i}-{inst['role']}"
        prof = make_profile(inst["role"], db, pair, (sw - scene.get("pet_right", 230) - PET_WIDTH / 2, bottom + 8),
                            inst.get("cfg"), inst.get("prefs"))
        flags = [subst.get(f, f).replace("@T", f"@{sync_ms}") for f in inst["flags"]]
        cmd = ["nice", "-n", "10", str(exe), "--profile", prof, "--offscreen", *COMMON, *flags,
               "--record", str(out), "--record-fps", str(scene.get("record_fps", 15)),
               "--record-duration", str(scene["seconds"]), *region,
               "--record-bg", str(bg)]
        if scene.get("menubar"):
            cmd.append("--record-menubar")
        logf = open(work / f"{i}-{inst['role']}.log", "w")
        p = subprocess.Popen(cmd, env=env, stdout=logf, stderr=subprocess.STDOUT)
        procs.append(p)
        running.append(p)
        dirs.append(out)
    deadline = time.time() + scene["seconds"] + 60   # + time to composite the frames
    for p in running:
        try:
            p.wait(max(1, deadline - time.time()))
        except subprocess.TimeoutExpired:
            log(f"  {name}: instance {p.pid} still running, killing it")
            kill(p)
    kill(server)
    if feed:
        feed.close()
        # The updater's scratch folders ($TMPDIR/LuluPetUpdate-*) from this take (never older ones).
        tmp = Path(os.environ.get("TMPDIR", "/tmp"))
        for d in tmp.glob("LuluPetUpdate-*"):
            if d.is_dir() and d.stat().st_mtime >= launch - 1:
                shutil.rmtree(d, ignore_errors=True)
    cleanup()
    left = subprocess.run(["pgrep", "-f", f"profile {PROFILE_PREFIX}-"], capture_output=True, text=True).stdout.split()
    for pid in left:
        os.kill(int(pid), signal.SIGKILL)
    return dirs


# ---------------------------------------------------------------------------------------------- frames

# Titled windows: the app renders only their content view (no title bar, no window background, and stretched
# over the whole frame), so they are rebuilt here: shadow, rounded light-grey body, title bar with the title.
TITLED = {"WhatsNewWindow": "噜噜桌宠 · 更新日志", "WelcomeWindow": "欢迎来到噜噜桌宠", "SettingsWindow": "噜噜桌宠 · 设置"}
WINDOW_RE = re.compile(r"(\w+) \{\{([-\d.e]+), ([-\d.e]+)\}, \{([-\d.e]+), ([-\d.e]+)\}\} img (\d+)x(\d+) a ([\d.]+)")


class Track:
    """One instance's recording: its frames painted over the wallpaper (with titled windows rebuilt), in RGB."""

    def __init__(self, d, wall, hold_blank_pet=False):
        self.dir = d
        self.hold_blank_pet = hold_blank_pet
        self._last_good = None
        rows = [l.split() for l in (d / "timestamps.txt").read_text().splitlines() if l.strip()]
        self.frames = [(int(ts) / 1000.0, int(i)) for i, ts in rows]
        rx, ry, rw, rh = (int(v) for v in (d / "region.txt").read_text().split())
        self.region = (rx, ry, rw, rh)
        self.windows = {}
        for line in (d / "windows.txt").read_text().splitlines():
            idx, _, rest = line.partition(" ")
            self.windows[int(idx)] = [m.groups() for m in WINDOW_RE.finditer(rest)]
        # The wallpaper as the app would have drawn it: aspect-filling the main screen, cropped to the region.
        sw, sh, _ = screen_geometry()
        W, H = int(sw * SCALE), int(sh * SCALE)
        s = max(W / wall.width, H / wall.height)
        full = wall.resize((round(wall.width * s), round(wall.height * s)), Image.BICUBIC)
        ox, oy = (full.width - W) // 2, (full.height - H) // 2
        fw, fh = int(rw * SCALE) // 2 * 2, int(rh * SCALE) // 2 * 2
        left, top = ox + rx * SCALE, oy + (sh - ry - rh) * SCALE
        self.wall = full.crop((int(left), int(top), int(left) + fw, int(top) + fh)).convert("RGBA")
        self.screen_h = sh
        self._cache = (None, None)

    def start(self):
        return self.frames[0][0]

    def end(self):
        return self.frames[-1][0]

    def at(self, t):
        """The painted frame shown at time t (the last one recorded at or before t)."""
        idx = self.frames[0][1]
        for ts, i in self.frames:
            if ts > t:
                break
            idx = i
        if self.hold_blank_pet:
            if self.pet_blank(idx) and self._last_good is not None:
                idx = self._last_good
            else:
                self._last_good = idx
        if self._cache[0] != idx:
            self._cache = (idx, self.paint(idx))
        return self._cache[1]

    def pet_blank(self, idx):
        """Is the pet window on screen but (almost) nothing drawn in it (< 5 % of its pixels)?"""
        rx, ry, rw, rh = self.region
        alpha = None
        for name, x, y, w, h, *_ in self.windows.get(idx, []):
            if name != "PetWindow":
                continue
            if alpha is None:
                alpha = Image.open(self.dir / f"frame-{idx:05d}.png").getchannel("A")
            x, y, w, h = float(x), float(y), float(w), float(h)
            box = (round((x - rx) * SCALE), round((ry + rh - y - h) * SCALE),
                   round((x - rx + w) * SCALE), round((ry + rh - y) * SCALE))
            hist = alpha.crop(box).histogram()
            area = max(1, (box[2] - box[0]) * (box[3] - box[1]))
            if (area - hist[0]) / area < 0.05:
                return True
        return False

    def paint(self, idx):
        frame = Image.open(self.dir / f"frame-{idx:05d}.png").convert("RGBA")
        base = self.wall.copy()
        rx, ry, rw, rh = self.region
        for name, x, y, w, h, iw, ih, a in self.windows.get(idx, []):
            title = TITLED.get(name)
            if title is None:
                continue
            x, y, w, h, iw, ih, a = float(x), float(y), float(w), float(h), int(iw), int(ih), float(a)
            left, top = round((x - rx) * SCALE), round((ry + rh - y - h) * SCALE)
            pw, ph = round(w * SCALE), round(h * SCALE)
            if pw <= 0 or ph <= ih:
                continue
            box = (left, top, left + pw, top + ph)
            content = frame.crop(box).resize((pw, ih), Image.LANCZOS)   # undo the stretch over the title bar
            frame.paste((0, 0, 0, 0), box)
            self.window(base, box, content, ph - ih, title, a)
        base.alpha_composite(frame)
        return base.convert("RGB")

    @staticmethod
    def window(base, box, content, bar, title, alpha):
        left, top, right, bottom = box
        w, h = right - left, bottom - top
        r = 10 * SCALE
        # Shadow.
        m = 40 * SCALE
        shadow = Image.new("L", (w + 2 * m, h + 2 * m), 0)
        ImageDraw.Draw(shadow).rounded_rectangle((m, m + 10 * SCALE, m + w, m + h + 6 * SCALE), r, fill=int(95 * alpha))
        shadow = shadow.filter(ImageFilter.GaussianBlur(14 * SCALE))
        layer = Image.new("RGBA", shadow.size, (0, 0, 0, 0))
        layer.putalpha(shadow)
        Track.composite_clipped(base, layer, left - m, top - m)
        # Body + title bar.
        win = Image.new("RGBA", (w, h), (236, 236, 236, 255))
        d = ImageDraw.Draw(win)
        d.rectangle((0, 0, w, bar), fill=(232, 232, 232, 255))
        d.line((0, bar - 1, w, bar - 1), fill=(214, 214, 214, 255), width=1)
        cy = bar // 2
        for k, (fill, line) in enumerate([((255, 95, 87), (225, 70, 64)), ((221, 221, 221), (200, 200, 200)),
                                          ((221, 221, 221), (200, 200, 200))]):
            cx = (14 + 20 * k) * SCALE
            rad = 6 * SCALE
            d.ellipse((cx - rad, cy - rad, cx + rad, cy + rad), fill=fill, outline=line, width=1)
        font = ImageFont.truetype(FONT, 13 * SCALE, index=2)
        tw = d.textlength(title, font=font)
        d.text(((w - tw) / 2, cy), title, font=font, fill=(64, 64, 64, 255), anchor="lm")
        win.alpha_composite(content, (0, bar))
        ImageDraw.Draw(win).rounded_rectangle((0, 0, w - 1, h - 1), r, outline=(0, 0, 0, 46), width=1)
        mask = Image.new("L", (w, h), 0)   # rounded corners (and the fade-in alpha)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), r, fill=round(255 * alpha))
        win.putalpha(mask)
        Track.composite_clipped(base, win, left, top)

    @staticmethod
    def composite_clipped(base, layer, x, y):
        """alpha_composite that tolerates a layer hanging off the frame."""
        sx, sy = max(0, -x), max(0, -y)
        crop = layer.crop((sx, sy, min(layer.width, base.width - x), min(layer.height, base.height - y)))
        if crop.width > 0 and crop.height > 0:
            base.alpha_composite(crop, (x + sx, y + sy))


def compose(scene, dirs, out_dir, wall, first=1):
    """Writes the final full-resolution frames (PNG) for the GIF / MP4 into out_dir, numbered from `first`;
    returns the number written."""
    labels = scene.get("labels", (LEFT_LABEL, RIGHT_LABEL))
    tracks = [Track(d, wall, scene.get("hold_blank_pet", False)) for d in dirs]
    t0 = max(tr.start() for tr in tracks)
    t_end = min(tr.end() for tr in tracks)
    a, b = scene["trim"]
    fps = scene["fps"]
    start, end = t0 + a, min(t_end, t0 + b)
    out_dir.mkdir(parents=True, exist_ok=True)
    n = 0
    t = start
    while t <= end:
        imgs = [tr.at(t) for tr in tracks]
        if len(imgs) == 1:
            frame = imgs[0]
        else:
            pw = max(im.width for im in imgs)
            gap, font_px = 12 * SCALE, round(pw * 0.046)
            label_h = font_px * 2
            font = ImageFont.truetype(FONT, font_px)
            ph = max(im.height for im in imgs)
            width = (2 * pw + gap) // 2 * 2
            frame = Image.new("RGB", (width, (label_h + ph) // 2 * 2), (250, 248, 252))
            d = ImageDraw.Draw(frame)
            for k, (im, label) in enumerate(zip(imgs, labels)):
                x = k * (pw + gap)
                frame.paste(im, (x, label_h))
                tw = d.textlength(label, font=font)
                d.text((x + (pw - tw) / 2, label_h / 2), label, font=font, fill=(70, 62, 80), anchor="lm")
            d.line([(pw + gap // 2, 6 * SCALE), (pw + gap // 2, frame.height - 6 * SCALE)], fill=(222, 214, 230), width=SCALE)
        frame.save(out_dir / f"{first + n:05d}.png", compress_level=1)
        n += 1
        t += 1.0 / fps
    return n


def ffmpeg():
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()


def encode(name, scene, frames_dir, fps, two):
    OUT.mkdir(parents=True, exist_ok=True)
    gif, mp4 = OUT / f"{name}.gif", OUT / f"{name}.mp4"
    bg = ["nice", "-n", "20", "taskpolicy", "-b", ffmpeg(), "-v", "error", "-y", "-threads", "2"]
    src = ["-framerate", str(fps), "-i", str(frames_dir / "%05d.png")]
    # HD video: full 2x resolution.
    subprocess.run(bg + src + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", "-preset", "slow",
                               "-movflags", "+faststart", "-x264-params", "threads=2", str(mp4)], check=True)
    full_w = Image.open(next(frames_dir.glob("*.png"))).width
    width = min(scene.get("width", GIF_WIDE if two else GIF_SINGLE), full_w)
    # Over the size cap: fewer frames first, then narrower.
    tries = [(r, width) for r in dict.fromkeys([fps, min(fps, 10), 8, 6])]
    tries += [(6, round(width * f)) for f in (0.9, 0.8, 0.7, 0.6)]
    for rate, w in tries:
        vf = (f"fps={rate},scale={w}:-1:flags=lanczos,split[a][b];"
              f"[a]palettegen=max_colors=256:stats_mode=diff[p];"
              f"[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle")
        subprocess.run(bg + src + ["-vf", vf, "-loop", "0", str(gif)], check=True)
        if gif.stat().st_size <= MAX_GIF:
            break
        log(f"  {name}.gif is {gif.stat().st_size / 1e6:.1f} MB at {rate} fps × {w} px, trying smaller")
    return gif, mp4


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scenes", nargs="*", help=f"scenes to render (default: the README ones): {', '.join(SCENES)}")
    ap.add_argument("--keep", action="store_true", help="keep the raw frames in build/demo-work/")
    ap.add_argument("--no-build", action="store_true", help="skip `swift build`")
    ap.add_argument("--out", help="output directory (default docs/demo)")
    args = ap.parse_args()
    if args.out:
        global OUT
        OUT = Path(args.out).resolve()
    names = args.scenes or [n for n, s in SCENES.items() if not n.startswith("v0") and s.get("readme", True)]
    for n in names:
        if n not in SCENES:
            sys.exit(f"unknown scene {n!r}; known: {', '.join(SCENES)}")
    if not args.no_build:
        subprocess.run(["nice", "-n", "10", "swift", "build"], cwd=ROOT, check=True)
    wall_path, bg = WORK / "wallpaper.png", WORK / "clear.png"
    wallpaper(wall_path)
    clear_background(bg)
    wall = Image.open(wall_path).convert("RGB")
    for name in names:
        scene = SCENES[name]
        work = WORK / name
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        parts = [{**scene, **seg} for seg in scene.get("segments", [{}])]
        n = 0
        for k, part in enumerate(parts):
            pwork = work / f"part{k}" if len(parts) > 1 else work
            pwork.mkdir(parents=True, exist_ok=True)
            log(f"{name}: recording {part['seconds']} s ({len(part['instances'])} instance(s))"
                + (f", take {k + 1}/{len(parts)}" if len(parts) > 1 else ""))
            dirs = record(name, part, pwork, bg)
            missing = [d for d in dirs if not (d / "timestamps.txt").exists()]
            if missing:
                sys.exit(f"{name}: no recording in {missing} (see {pwork}/*.log)")
            n += compose(part, dirs, work / "out", wall, first=n + 1)
        gif, mp4 = encode(name, scene, work / "out", scene["fps"], len(parts[0]["instances"]) > 1)
        dims = "x".join(str(v) for v in Image.open(gif).size)
        log(f"{name}: {gif.relative_to(ROOT) if gif.is_relative_to(ROOT) else gif} {dims} {gif.stat().st_size / 1e6:.2f} MB, "
            f"{mp4.name} {mp4.stat().st_size / 1e6:.2f} MB")
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)
    if not args.keep:
        shutil.rmtree(WORK, ignore_errors=True)


if __name__ == "__main__":
    main()
