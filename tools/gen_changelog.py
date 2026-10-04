#!/usr/bin/env python3
"""Renders assets/changelog.json (the in-app 更新日志) into the docs:

    CHANGELOG.md                      the full log, newest first: `## vX.Y.Z（YYYY-MM-DD）` + one bullet per item
    README.md                         the 「最近更新」 block (newest RECENT versions) between
                                      <!-- recent-changes:start --> and <!-- recent-changes:end -->

    python3 tools/gen_changelog.py            # write both (only if they changed)
    python3 tools/gen_changelog.py --check    # exit 1 if either is stale (scripts/check_docs_sync.sh)

Run by scripts/release.sh before its checks; assets/changelog.json is the only source — never edit the
generated text by hand.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "changelog.json"
CHANGELOG = ROOT / "CHANGELOG.md"
README = ROOT / "README.md"
START, END = "<!-- recent-changes:start -->", "<!-- recent-changes:end -->"
RECENT = 3


def load():
    entries = json.loads(SOURCE.read_text(encoding="utf-8"))
    for e in entries:
        if not e.get("version") or not isinstance(e.get("items"), list):
            sys.exit(f"gen_changelog: bad entry in {SOURCE.relative_to(ROOT)}: {e!r}")
    return entries   # newest first, as the app shows it


def heading(e):
    return f"v{e['version']}" + (f"（{e['date']}）" if e.get("date") else "")


def changelog_md(entries):
    out = ["# 更新日志", "",
           "噜噜桌宠每一版的更新内容，最新的在最上面。App 里也能看：🍊 →「更新日志…」。",
           "下载最新版：[Releases](https://github.com/richardzhuang0412/LuluPet/releases/latest)。", "",
           "<!-- 由 tools/gen_changelog.py 从 assets/changelog.json 生成，请不要手改。 -->", ""]
    for e in entries:
        out += [f"## {heading(e)}", ""] + [f"- {it}" for it in e["items"]] + [""]
    return "\n".join(out)


def recent_block(entries):
    out = [START, "## 最近更新", ""]
    for e in entries[:RECENT]:
        out += [f"**{heading(e)}**", ""] + [f"- {it}" for it in e["items"]] + [""]
    out += ["完整的更新日志见 [CHANGELOG.md](CHANGELOG.md)。", END]
    return "\n".join(out)


def readme_with_block(text, block):
    i, j = text.find(START), text.find(END)
    if i < 0 or j < i:
        sys.exit(f"gen_changelog: README.md has no {START} … {END} block")
    return text[:i] + block + text[j + len(END):]


def main():
    check = "--check" in sys.argv[1:]
    entries = load()
    want = {CHANGELOG: changelog_md(entries)}
    readme = README.read_text(encoding="utf-8")
    want[README] = readme_with_block(readme, recent_block(entries))
    stale = [p for p, text in want.items() if not p.exists() or p.read_text(encoding="utf-8") != text]
    if check:
        if stale:
            print("过期 / stale: " + ", ".join(str(p.relative_to(ROOT)) for p in stale)
                  + " — 运行 / run: python3 tools/gen_changelog.py", file=sys.stderr)
            sys.exit(1)
        return
    for p in stale:
        p.write_text(want[p], encoding="utf-8")
        print(f"gen_changelog: wrote {p.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
