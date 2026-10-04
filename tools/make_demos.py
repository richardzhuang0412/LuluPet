#!/usr/bin/env python3
"""Renders the README demo GIFs / MP4s (docs/demo/<name>.gif|.mp4) — no screen recording, nothing on screen.

    tools/make_demos.sh                    # all scenes (sets up build/demo-venv with Pillow + imageio-ffmpeg)
    tools/make_demos.sh daily visit        # only these scenes
    tools/make_demos.sh --keep             # keep the raw frames (build/demo-work/<scene>/)

Each scene launches one or two LuluPet instances with `--offscreen` (windows below the desktop picture, no 🍊)
and throwaway profiles against tools/fake_firebase.py, drives them with the hidden demo flags (--auto-send,
--demo-ack, --demo-dnd…) and records them with `--record` (the app renders its own windows over a wallpaper).
Two-desktop scenes go side by side, aligned by timestamp. Scenes run one at a time; every instance, fake server
and profile is removed afterwards (also on Ctrl-C). Encoding runs niced in the background (2 threads).
"""
import argparse
import atexit
import json
import os
import random
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / ".build" / "debug" / "LuluPet"
OUT = ROOT / "docs" / "demo"
WORK = ROOT / "build" / "demo-work"
FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"
MAX_GIF = 6_000_000
PET_WIDTH = 167   # the pet window at size 1.0
LEFT_LABEL, RIGHT_LABEL = "你的桌面（噜噜）", "TA 的桌面（噜妹）"
# Every profile this script creates starts with this prefix (never the user's default / demo* / try* profiles).
PROFILE_PREFIX = "lprec"

# ---------------------------------------------------------------------------------------------- scenes
#
# Each scene: `instances` (role + extra flags; one = single desktop, two = side by side,噜噜 left),
# `seconds` recorded, `trim` (start, end) seconds kept, `region` (the crop in points: (w, h) at the screen's
# bottom-right where the pets sit — the same for both desktops — or "auto:minW,minH" around the windows), `fps`, `width` of the GIF, `caption` (README).
# Flag times are seconds after launch; both instances of a scene are launched together.

COMMON = ["--presence-fast", "--fidget-seconds", "600", "--quiet-seconds", "600", "--doze-seconds", "900",
          "--rotate-seconds", "100000"]

SCENES = {
    "daily": dict(
        caption="日常：待机、随机小动作，单击它冒爱心；一会儿没人理就安静地站好（省电）",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--demo-fidget", "1.8", "--demo-click", "9.3",
                                             "--quiet-seconds", "12"])],
        # Fidget clips run up to 7 s and a click on a busy pet is ignored: the click comes after it.
        seconds=16, trim=(1.2, 15.6), region=(460, 300), fps=15, width=720, menubar=True),
    "visit": dict(
        caption="送信串门：发个表情，噜噜亲自跑去 TA 的桌面送，见面、冒气泡、TA 点「收到 ❤️」，再跑回来说「送到啦」",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "sticker:hug@3"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-ack", "11"])],
        seconds=22, trim=(2.2, 21), region=(440, 450), fps=12, width=960),
    "collide": dict(
        caption="撞车：两个人同时发，先在一边见面，再一起走到另一边见一面，最后各回各家",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "sticker:hug@T"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--auto-send", "sticker:nuzzle@T"])],
        # Each live stream event held 1.5 s: both sends leave before either arrives (a real collision).
        seconds=33, trim=(2.2, 32.5), region=(440, 450), fps=12, width=960, server_args=["--stream-delay-ms", "1500"]),
    "offline": dict(
        caption="TA 不在：跑到边上找一圈，回来告诉你「TA 不在，先放在 TA 那儿啦」",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "text:晚上一起吃火锅吧 🍲@2"])],
        # 噜妹 was online before and signed off (lastSeen 0): "TA 不在", not "还没配对".
        seed={"presence/lumei": {"lastSeen": 0}},
        seconds=10, trim=(1.2, 9.8), region=(540, 300), pet_right=140, fps=15, width=720, menubar=True),
    "dnd": dict(
        caption="勿扰模式：TA 挂着「😤 生气中」，你发的都先攒着；TA 关掉勿扰，噜噜送来一张诚意清单",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "poke@3.5,text:别生气啦，晚上请你喝奶茶 🧋@6.5,sticker:hug@9.5"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-dnd", "angry@0.5", "--demo-dnd-off", "13"])],
        seconds=25, trim=(2.5, 24.5), region=(520, 450), pet_right=170, fps=12, width=960),
    "compose": dict(
        caption="传话面板：发爱心、去找 TA、24 个快捷表情；「记录」按天分组，可以一直往回翻",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--demo-history", "--demo-compose",
                                             "--demo-open-history-at", "5"])],
        seconds=10, trim=(1.0, 9.8), region=(600, 470), pet_right=160, fps=12, width=720, menubar=True),
    "v090_hug_sit": dict(
        caption="v0.9: hug_sit is bound to 我想你了 (hug_missyou)",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "sticker:missyou@3", "--force-couple", "hug_sit"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-ack", "13", "--force-couple", "hug_sit"])],
        seconds=24, trim=(2.2, 22.5), region=(440, 450), fps=12, width=960),
    "v090_angry": dict(
        caption="v0.9: angry is bound to 哼！ (angry_hmph)",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "sticker:angry@3", "--force-couple", "angry"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-ack", "13", "--force-couple", "angry"])],
        seconds=24, trim=(2.2, 22.5), region=(440, 450), fps=12, width=960),
    "v090_sleep": dict(
        caption="v0.9: sleep is bound to 打呼噜 (sleep_snore)",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "sticker:night@3", "--force-couple", "sleep"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-ack", "13", "--force-couple", "sleep"])],
        seconds=24, trim=(2.2, 22.5), region=(440, 450), fps=12, width=960),
    "v090_comein": dict(
        caption="v0.9: 噜噜 'hi' visitor clip with its aligned voice line (lulu_comein)",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "sticker:hi@3"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-ack", "13"])],
        seconds=22, trim=(2.2, 20.5), region=(440, 450), fps=12, width=960),
    "remind": dict(
        caption="v0.10: 叫 TA 喝水：噜噜跑去 TA 的桌面，TA 的气泡写着「叫你喝水啦」，点「喝了 ✓」，噜噜回家后冒一句「TA 喝啦」",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "remind:water@3"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-remind-reply", "comply@11"])],
        seconds=26, trim=(2.2, 25), region=(440, 450), fps=12, width=960),
    # v0.11 modes (docs/superpowers/specs/2026-10-05-modes-design.md): config extras (mode / character) per instance.
    # Friends never see intimate clips; two of the same character never get a two-person clip (both play happy + hearts).
    "v011_friend_same": dict(
        caption="v0.11 朋友：两只噜噜见面，没有双人片段，各自开心 + 冒爱心 (bothHappy)",
        labels=("你的桌面（噜噜）", "TA 的桌面（也是噜噜）"),
        instances=[dict(role="lulu", cfg=dict(mode="friend", character="lulu"), flags=["--outfit", "classic", "--auto-send", "sticker:run@3"]),
                   dict(role="lumei", cfg=dict(mode="friend", character="lulu"), flags=["--outfit", "classic", "--demo-ack", "11"])],
        seconds=22, trim=(2.2, 20), region=(440, 450), fps=12, width=960),
    "v011_friend_kiss_refused": dict(
        caption="v0.11 朋友：噜噜 + 噜妹，--force-couple kiss 被拒绝（亲密片段），回到 bothHappy",
        labels=("你的桌面（噜噜）", "TA 的桌面（噜妹）"),
        instances=[dict(role="lulu", cfg=dict(mode="friend", character="lulu"), flags=["--outfit", "classic", "--auto-send", "sticker:kiss@3", "--force-couple", "kiss"]),
                   dict(role="lumei", cfg=dict(mode="friend", character="lumei"), flags=["--outfit", "lace", "--demo-ack", "11", "--force-couple", "kiss"])],
        seconds=22, trim=(2.2, 20), region=(440, 450), fps=12, width=960),
    "v011_friend_mixed": dict(
        caption="v0.11 朋友：噜噜 + 噜妹，池子里的亲密片段被滤掉，只播非亲密的 (happy / dance)",
        labels=("你的桌面（噜噜）", "TA 的桌面（噜妹）"),
        instances=[dict(role="lulu", cfg=dict(mode="friend", character="lulu"), flags=["--outfit", "classic", "--auto-send", "sticker:run@3"]),
                   dict(role="lumei", cfg=dict(mode="friend", character="lumei"), flags=["--outfit", "lace", "--demo-ack", "11"])],
        seconds=22, trim=(2.2, 20), region=(440, 450), fps=12, width=960),
    "v011_couple": dict(
        caption="v0.11 情侣：和以前完全一样（hug）",
        instances=[dict(role="lulu", flags=["--outfit", "classic", "--auto-send", "sticker:hug@3", "--force-couple", "hug"]),
                   dict(role="lumei", flags=["--outfit", "lace", "--demo-ack", "11", "--force-couple", "hug"])],
        seconds=22, trim=(2.2, 20), region=(440, 450), fps=12, width=960),
    "outfits": dict(
        caption="换装和大小：「选择造型」直接挑一套；鼠标移上去拖右下角的小圆点等比例缩放",
        instances=[dict(role="lulu", flags=["--outfit", "classic",
                                             "--demo-outfit", "choose:bear@2,choose:panda@4,choose:cherry@6,choose:caishen@8",
                                             "--demo-resize-handle", "--demo-resize-drag", "-70,70@10.5",
                                             "--demo-scale", "1@14"])],
        seconds=16, trim=(1.2, 15.8), region=(470, 380), fps=12, width=720, menubar=True),
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
    """(width, visible bottom) of the main screen in points."""
    js = "ObjC.import('AppKit'); var s=$.NSScreen.mainScreen; [s.frame.size.width, s.visibleFrame.origin.y].join(' ')"
    w, y = subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True, check=True).stdout.split()
    return float(w), float(y)


def make_profile(role, db, pair, origin, extra=None):
    name = f"{PROFILE_PREFIX}-{role}-{os.getpid()}-{random.randrange(10**6)}"
    assert name.startswith(PROFILE_PREFIX + "-")
    profiles.append(name)
    cfg = json.dumps({"role": role, "pairCode": pair, "databaseURL": db, **(extra or {})}).encode()
    subprocess.run(["defaults", "write", f"lulupet.{name}", "config", "-data", cfg.hex()], check=True)
    # Same spot on both desktops: the pet's centre `pet_right` pt from the right edge, feet on the Dock.
    subprocess.run(["defaults", "write", f"lulupet.{name}", "petOrigin", "-string", "{%d, %d}" % origin], check=True)
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
    region = scene["region"]
    region = (["--record-region", "auto", "--record-min", region[5:], "--record-pad", "50"] if isinstance(region, str)
              else ["--record-region", f"bottom-right:{region[0]},{region[1]}"])
    launch = time.time()
    sync_ms = int((launch + 4) * 1000)   # "@T" in a flag: the same absolute moment for both instances
    dirs, running = [], []
    for i, inst in enumerate(scene["instances"]):
        out = work / f"{i}-{inst['role']}"
        sw, bottom = screen_geometry()
        prof = make_profile(inst["role"], db, pair, (sw - scene.get("pet_right", 230) - PET_WIDTH / 2, bottom + 8), inst.get("cfg"))
        flags = [f.replace("@T", f"@{sync_ms}") for f in inst["flags"]]
        cmd = ["nice", "-n", "10", str(APP), "--profile", prof, "--offscreen", *COMMON, *flags,
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
    cleanup()
    left = subprocess.run(["pgrep", "-f", f"profile {PROFILE_PREFIX}-"], capture_output=True, text=True).stdout.split()
    for pid in left:
        os.kill(int(pid), signal.SIGKILL)
    return dirs


def load_track(d):
    rows = [l.split() for l in (d / "timestamps.txt").read_text().splitlines() if l.strip()]
    return [(int(ts) / 1000.0, d / f"frame-{int(i):05d}.png") for i, ts in rows]


def pick(track, t):
    """The last frame shown at time t."""
    best = track[0][1]
    for ts, f in track:
        if ts > t:
            break
        best = f
    return best


def compose(scene, dirs, out_dir):
    labels = scene.get("labels", (LEFT_LABEL, RIGHT_LABEL))
    """Writes the final frames (PNG) for the GIF / MP4 into out_dir; returns the fps."""
    tracks = [load_track(d) for d in dirs]
    t0 = max(tr[0][0] for tr in tracks)
    t_end = min(tr[-1][0] for tr in tracks)
    a, b = scene["trim"]
    fps = scene["fps"]
    start, end = t0 + a, min(t_end, t0 + b)
    out_dir.mkdir(parents=True, exist_ok=True)
    width = scene["width"]
    font = ImageFont.truetype(FONT, 22)
    n = 0
    t = start
    while t <= end:
        imgs = [Image.open(pick(tr, t)).convert("RGB") for tr in tracks]
        if len(imgs) == 1:
            im = imgs[0]
            frame = im.resize((width, round(im.height * width / im.width) // 2 * 2), Image.LANCZOS)
        else:
            gap, label_h = 12, 44
            pw = (width - gap) // 2
            panels = [im.resize((pw, round(im.height * pw / im.width)), Image.LANCZOS) for im in imgs]
            ph = max(p.height for p in panels)
            frame = Image.new("RGB", (width, (label_h + ph) // 2 * 2), (250, 248, 252))
            d = ImageDraw.Draw(frame)
            for k, (p, label) in enumerate(zip(panels, labels)):
                x = k * (pw + gap)
                frame.paste(p, (x, label_h))
                tw = d.textlength(label, font=font)
                d.text((x + (pw - tw) / 2, 9), label, font=font, fill=(70, 62, 80))
            d.line([(pw + gap // 2, 6), (pw + gap // 2, frame.height - 6)], fill=(222, 214, 230), width=2)
        n += 1
        frame.save(out_dir / f"{n:05d}.png")
        t += 1.0 / fps
    return fps


def ffmpeg():
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()


def encode(name, frames_dir, fps):
    OUT.mkdir(parents=True, exist_ok=True)
    gif, mp4 = OUT / f"{name}.gif", OUT / f"{name}.mp4"
    bg = ["nice", "-n", "20", "taskpolicy", "-b", ffmpeg(), "-v", "error", "-y", "-threads", "2"]
    src = ["-framerate", str(fps), "-i", str(frames_dir / "%05d.png")]
    subprocess.run(bg + src + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "26", "-preset", "slow",
                               "-movflags", "+faststart", "-x264-params", "threads=2", str(mp4)], check=True)
    for colors, rate in [(128, fps), (96, fps), (64, min(fps, 10)), (48, 8)]:
        step = f"fps={rate}," if rate != fps else ""
        vf = (f"{step}split[a][b];[a]palettegen=max_colors={colors}:stats_mode=diff[p];"
              f"[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle")
        subprocess.run(bg + src + ["-vf", vf, "-loop", "0", str(gif)], check=True)
        if gif.stat().st_size <= MAX_GIF:
            break
        log(f"  {name}.gif is {gif.stat().st_size / 1e6:.1f} MB, trying fewer colours / frames")
    return gif, mp4


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scenes", nargs="*", help=f"scenes to render (default: all): {', '.join(SCENES)}")
    ap.add_argument("--keep", action="store_true", help="keep the raw frames in build/demo-work/")
    ap.add_argument("--no-build", action="store_true", help="skip `swift build`")
    ap.add_argument("--out", help="output directory (default docs/demo)")
    args = ap.parse_args()
    if args.out:
        global OUT
        OUT = Path(args.out).resolve()
    names = args.scenes or list(SCENES)
    for n in names:
        if n not in SCENES:
            sys.exit(f"unknown scene {n!r}; known: {', '.join(SCENES)}")
    if not args.no_build:
        subprocess.run(["nice", "-n", "10", "swift", "build"], cwd=ROOT, check=True)
    bg = WORK / "wallpaper.png"
    wallpaper(bg)
    for name in names:
        scene = SCENES[name]
        work = WORK / name
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        log(f"{name}: recording {scene['seconds']} s ({len(scene['instances'])} instance(s))")
        dirs = record(name, scene, work, bg)
        missing = [d for d in dirs if not (d / "timestamps.txt").exists()]
        if missing:
            sys.exit(f"{name}: no recording in {missing} (see {work}/*.log)")
        fps = compose(scene, dirs, work / "out")
        gif, mp4 = encode(name, work / "out", fps)
        log(f"{name}: {gif.relative_to(ROOT)} {gif.stat().st_size / 1e6:.2f} MB, {mp4.relative_to(ROOT)} {mp4.stat().st_size / 1e6:.2f} MB")
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)
    if not args.keep:
        shutil.rmtree(WORK, ignore_errors=True)


if __name__ == "__main__":
    main()
