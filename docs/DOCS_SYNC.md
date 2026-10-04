# 发版时的文档清单（DOCS_SYNC）

每次发版（改 `VERSION`、往 `assets/changelog.json` 加新条目）时，对照这份清单检查用户文档是否跟上。
一个钩子会读这个文件：下面每一行 `- [ ]` 是一项检查，`触发:` 说明什么改动需要它，`文件:` 是要更新的文件。

## 每次发版都要做

- [ ] **README 功能一览** —— 触发: `assets/changelog.json` 有新的用户可见功能（新功能、新入口、改名的按钮 / 菜单项）。
  文件: `README.md`（「功能一览」一节：每个功能 1–2 行 + 动图；不要把完整更新日志抄进来，完整的在 App 的「更新日志」里）。
- [ ] **功能介绍** —— 触发: 同上，或者某个功能的用法、默认值、设置位置变了。
  文件: `docs/features.md`（做什么 / 怎么用 / 在哪里设置；和 README 保持一致）。
- [ ] **更新日志本身** —— 触发: 每次发版。
  文件: `assets/changelog.json`（用户能看懂的中文，一条一句，不写内部细节）。
- [ ] **CHANGELOG.md 和 README「最近更新」** —— 触发: 每次发版（`assets/changelog.json` 变了）。
  文件: `CHANGELOG.md`、`README.md` 里 `<!-- recent-changes:start -->` … `<!-- recent-changes:end -->` 之间（最新 3 版）。
  都由 `python3 tools/gen_changelog.py` 从 `assets/changelog.json` 生成，不要手改；`scripts/release.sh` 会先自动生成，
  `scripts/check_docs_sync.sh` 发现过期会报错。这一块的改动不算「README 已同步」，功能一览还是要自己写。

## 有相应改动时才做

- [ ] **Firebase 设置说明** —— 触发: 配对流程、欢迎窗 / 设置「通用」页的字段、模式 / 角色规则、Firebase 安全规则或数据路径变了。
  文件: `docs/firebase-setup.md`（和 README「两个人用：Firebase 设置」「常见问题」）。
- [ ] **演示动图** —— 触发: 动图里出现的界面变了（宠物窗口、气泡、传话面板、菜单、更新日志窗口……），或新增了值得演示的功能。
  文件: `docs/demo/*.gif|.mp4`，用 `tools/make_demos.sh <场景…>` 重新生成（新场景先加到 `tools/make_demos.py`）；
  高清：两个桌面并排的 GIF 宽 1440，单个桌面 960，每个 GIF ≤ 约 10 MB（超了先降帧率再缩小）；同名 MP4 是高清视频，
  README 里每张动图下面链接「高清视频」。README / features.md 里引用的每个文件都必须是已提交的文件。
- [ ] **安装 / 更新步骤** —— 触发: 下载方式、打开方式、更新方式变了（比如菜单里的「检查更新」）。
  文件: `README.md`（「安装」「常见问题 → 怎么更新」）、`docs/features.md`（「版本提醒和更新」）。
- [ ] **隐私说明** —— 触发: 新增了联网请求、共享给 TA 的新数据、新的第三方服务。
  文件: `README.md`（「隐私」）。
- [ ] **开发者说明** —— 触发: 构建、测试、脚本（`scripts/*.sh`）的用法变了。
  文件: `README.md`（「开发者」）。

## 写作要求

- 中文，温和、清楚；说「两个人」「TA」，不写任何个人信息（不提作者的伴侣、关系、所在地）。
- 演示用的城市、消息都用中性的示例。
- 素材库不公开分发：不要链接任何素材库压缩包；版权段落保留「非商用、侵删」。
