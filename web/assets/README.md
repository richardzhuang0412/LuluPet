# web/assets（生成物，别手改）

由 `tools/build_web_assets.py` 生成，提交进仓库。输入只用仓库里的 `Resources/`（Sprites / Clips / Stickers）
和 `Sources/LuluCore/StickerPanel.swift`（默认常用表情、表情分组），不碰 `assets/library`，所以谁都能重跑。

## 重新生成

```sh
nice -n 10 python3 tools/build_web_assets.py   # 需要 Pillow（python3 -m pip install --user pillow）
node --test web/tests/assets.test.mjs           # 检查清单、文件 hash、预算
```

改了造型 / 表情（`tools/build_sprites.py` 重建了 `Resources/`）之后跑一次，把 `web/assets/` 的变化一起提交。
同样的输入产出逐字节相同的文件；清单不再引用的旧文件会被删掉。脚本结尾打印每套造型的大小，超预算直接失败。

## 内容

- `manifest.json`：片段（`clips`）、角色造型（`characters`）、表情（`stickers` / `stickerGroups` / `thumbs`）、`defaultFavorites`。
- `sprites/<clip>-h200.<hash>.webp`：每个片段一张精灵表，帧高 200 px、最多 8 列，只存不重复的帧；
  第 i 帧画的是第 `seq[i]` 格（格子按行排，`cols` 列，每格 `w`×`h`），停留 `delays[i]` 秒。
  `src` 是原始帧尺寸：同一套造型里各片段按 `src[1] / idle.src[1]` 的比例画，和 Mac 一样大小一致。
- `stickers/<id>.<hash>.webp`：表情动图（最长边 200 px）；`stickers/thumbs.<hash>.webp`：全部表情第一帧，72 px 一格。
- 文件名带内容 hash，可以永久缓存。

## 为了预算做的取舍

帧率高于约 8 fps 的片段（蕾丝帽）隔帧保留；造型超 600 KB 时依次：降质量（80 → 72 → 65）→ 去掉 fidget → react / happy 再隔帧。
每次生成的取舍都打印在脚本输出的 `note:` 行里。
