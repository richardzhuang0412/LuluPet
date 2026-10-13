# web/assets（生成物，别手改）

由 `tools/build_web_assets.py` 生成，提交进仓库。输入只用仓库里提交了的文件：`Resources/`（Sprites / Clips / Couples /
Stickers / reactions.json / changelog.json）、`Sources/LuluCore/StickerPanel.swift`（默认常用表情、表情分组）和
`Sources/LuluCore/ToolClips.swift`（工具片段池），不碰 `assets/library`，所以谁都能重跑。

## 重新生成

```sh
nice -n 10 python3 tools/build_web_assets.py   # 需要 Pillow（python3 -m pip install --user pillow）
node --test web/tests/assets.test.mjs           # 检查清单、文件 hash、引用、预算
```

改了造型 / 表情（`tools/build_sprites.py` 重建了 `Resources/`）之后跑一次，把 `web/assets/` 的变化一起提交。
同样的输入产出逐字节相同的文件；清单不再引用的旧文件会被删掉。脚本结尾打印每套造型 / 每类片段的大小，超预算直接失败。

## 文件

- `manifest.json`：见下面的格式。
- `sprites/<store id>-h240.<hash>.webp`：每个片段一张精灵表，帧高 240 px、最多 8 列，只存不重复的帧（全帧率，不抽帧）。
- `stickers/<id>.<hash>.webp`：表情动图（最长边 200 px）；`stickers/thumbs.<hash>.webp`：全部表情第一帧，72 px 一格。
- 文件名带内容 hash，可以永久缓存（`sw.js` 对 `assets/sprites/`、`assets/stickers/` 用 cache-first）。
- 没有声音文件：网页版不放噜噜 / 噜妹的语音（办公室场景），W5 用 Web Audio 合成中性提示音；`sounds` 恒为 `{}`。

## manifest v2 格式（`"version": 2`）

v1 的字段全部保留、形状不变（读 v1 的代码照常能跑）；v2 的改动：

| 字段 | 说明 |
|---|---|
| `version` | `2`（v1 是 `1`） |
| `frameHeight` | `240`（v1 `200`） |
| `modes` | 同 v1：动作 → `loop` / `still` / `once` |
| `clips` | 同 v1 形状：`{key: {file, frames, cells, cols, w, h, src, delays, seq}}`。key 现在是 `<store id>-h240`（同一个片段用了几种速度时再加 `-<6 位 hash>`），只当不透明 id 用。第 i 帧画第 `seq[i]` 格（格子按行排，`cols` 列，每格 `w`×`h`），停 `delays[i]` 秒；`src` 是原始帧尺寸，同一套造型里各片段按 `src[1] / idle.src[1]` 的比例画。v2 不再抽帧：`frames` = Mac 的帧数，`delays` = Mac 的 delays。 |
| `characters.<c>.order` | 同 v1：造型顺序，`order[0]` = 默认造型 |
| `characters.<c>.outfits.<o>` | v1 字段 `label`、`season`、`actions`（动作 → clip key）、`fidgets`（clip key 列表）不变，但 `fidgets` 现在是 `fidgets.json` 里的**全部**（v1 最多 2 个）。新增：`fidgetNames`（和 `fidgets` 一一对应的片段名）、`stay`（访客停留姿势的片段名，`stay.json` 顺序）、`extras`（`clips.json` 的片段名，只由 reactions / 工具播放）、`named`（片段名 → clip key，fidgets + stay + extras，同名先到先得 = Mac `PetWindow.playNamed`）、`clipSounds`（片段名 → Mac 的声音键，只有绑了声音的片段才有） |
| `characters.<c>.weather` | 新：天气看法 → `[{name, clip, sound?}]`（`Sprites/<c>/weather.json` 顺序；看法是 `rain` / `hot` / `cold` / `windy` / `cloudy` …，snow 没有自己的片段时用 cold，规则同 `WeatherLook.clipLooks`） |
| `couples` | 新：合体片段名 → `{clip, intimate, sound, heightFactor, luluOnLeft}`。`sound` 是 Mac 声音键或 `null`；`heightFactor` 已夹在 0.3–1.5；`luluOnLeft` false = 原图噜噜在右边（`CoupleClip.mirrored`） |
| `reactions` | 新：`Resources/reactions.json` **原样**。`couple` 池里是 `couples` 的名字（`"none"` = 不放合体）；`visitor.<c>` 里是**片段名**，用访客当前造型的 `outfits.<o>.named[name]` 查 clip key，查不到 = 这套造型没有，跳过（同 Mac）。没有换成 clip key，因为同一个名字在不同造型里可能有也可能没有。 |
| `toolClips` | 新：`{water, stand, focus, breakTime, eyedrops}` → `{lulu: [片段名], lumei: [片段名]}`，来自 `ToolClips.swift`；同样按当前造型的 `named` 查，查不到跳过。空池：focus = 安静静止帧，eyedrops = 先播 `happy`（spec §2.5，Mac 加了 `.eyedrops` 池后重跑即可） |
| `sounds` | 新，恒为 `{}`（网页不用声音文件） |
| `stickers` / `stickerGroups` / `thumbs` / `defaultFavorites` | 同 v1 |
| `changelog` | 新：`Resources/changelog.json` 原样（`[{version, date, items}]`，新的在前） |
| `totalBytes` | 新：清单引用的全部文件（不含 manifest 本身）字节数之和，给「下载全部素材」显示总大小 |

清单里的 `sound` / `clipSounds` 只是 Mac 的声音事件名（例如 `lulu_comein`、`angry_hmph`），网页可以拿来选合成音，没有对应文件。

## 预算（spec §5，超了构建失败）

idle 精灵表 ≤ 320 KB；一套造型（核心动作 + 全部 fidget，按不同文件算）≤ 2.5 MB；天气片段 ≤ 600 KB；合体片段和
reactions.json `visitor` 池（含 `click` / `poke`）点到的片段 ≤ 900 KB；首屏（清单 + 最大 idle + 最大默认造型 idle +
缩略图集）≤ 1.5 MB；表情 ≤ 400 KB；`web/assets` 总量 ≤ 150 MB。

超预算时只降质量（80 → 72 → 65 → 58 → 50 → 45；一套造型超了先降它最大的那张表），不抽帧、不删片段；最低质量还超就失败并说是哪个。
每次降了质量的片段都打印在脚本输出的 `note:` 行里。
