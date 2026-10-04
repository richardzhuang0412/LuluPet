# 升级兼容约定（Upgrade compatibility）

我们会不断发新版本，两个人不一定同时升级。**硬性要求：升级后所有聊天记录必须原样保留。**
下面这些东西一旦改了，老数据就会丢或者新老版本互相看不懂，所以**永远不要改**，只能按规则"加"。

> English summary: the identifiers below are frozen. Data formats are additive-only; an older app must
> tolerate data written by a newer one; a migration never deletes local history or remote data.

## 1. 不能改的标识（Frozen identities）

| 东西 | 值 | 为什么不能改 |
|---|---|---|
| Bundle ID | `com.lulupet.app`（`scripts/build_app.sh`） | macOS 按它认 App：UserDefaults 默认域、"仍要打开"授权都跟它绑定 |
| App 名 / 可执行文件 | `LuluPet.app` / `Contents/MacOS/LuluPet` | 覆盖安装时替换同一个 App |
| UserDefaults 域 | 无 `--profile`：App 的标准域（打包后即 `com.lulupet.app`）；有 `--profile X`：`lulupet.X` | 配置存在这里 |
| UserDefaults 键 | `config`（`AppConfig` 的 JSON：`role` / `pairCode` / `databaseURL`；v0.11 起可选 `mode`（`solo` / `couple` / `friend`，缺省 = `couple`）和 `character`（`lulu` / `lumei`，缺省 = 和 `role` 同名的角色）） | 身份、配对码、数据库地址。`role` 从 v0.11 起的含义是**座位**（A = lulu，B = lumei），取值和 Firebase 路径不变；画哪个角色看 `character`。`mode` / `character` 为 nil 时不写进 JSON；读到不认识的值当作 nil（整个 config 仍可读）。`solo` 模式下 `pairCode` / `databaseURL` 照常保留，切回情侣 / 朋友不用重填；`isComplete`：solo = 永远完整，其余规则不变。老版本忽略这两个字段（照情侣处理） |
| | `lastReadTs`（Int64 毫秒，已读游标） | 改了会重复弹出旧消息或漏掉消息 |
| | `petOrigin`（`NSStringFromPoint`，桌宠窗口位置） | 位置记忆 |
| | `schemaVersion`（Int，缺省 = 1） | 本地数据迁移进度 |
| | `pinnedOutfit`（字典 `{角色 rawValue: 造型名}`，例如 `{"lumei": "lace"}`；缺省 = 没固定） | "固定这套造型"：固定后不自动换装，下次启动还原这套。v0.5：固定的造型已经不存在（v0.4 的 `bow`）时，改成固定该角色的默认造型（`lace`）；固定的节日造型过了季节也照样保留 |
| | `hotkeyToggle`（v0.4，`Shortcut` 的 JSON：`keyCode`（macOS 虚拟键码）/ `modifiers`（位：1=⌃ 2=⌥ 4=⇧ 8=⌘）/ `key`（显示用，如 `"L"`）；缺省 = ⌃⌥L） | 显示 / 隐藏桌宠的全局快捷键 |
| | `hotkeyCompose`（v0.4，同上；缺省 = ⌃⌥M） | 打开传话面板的全局快捷键 |
| | `autoHideFullscreen`（v0.4，Bool；缺省 = true） | 全屏时自动隐藏 |
| | `soundEnabled`（v0.5，Bool；缺省 = 开，即 `SoundDefaults.enabled`） | 声音开 / 关 |
| | `soundVolume`（v0.5，Double 0…1；缺省 = 0.25，菜单"小 / 中 / 大" = 0.25 / 0.5 / 0.8） | 音量 |
| | `bgmEnabled`（v0.5，Bool；缺省 = 关） | 背景音乐（只在启动时放一首，不循环） |
| | `showInDock`（v0.6.3，Bool；缺省 = 关） | 在程序坞中显示图标 |
| | `hotkeyQuit`（v0.7，`Shortcut` 的 JSON，格式同 `hotkeyToggle`；缺省 = ⌃⌥Q） | 退出噜噜桌宠的全局快捷键（和 🍊 → 退出 一样会先通知对方下线） |
| | `petScale`（v0.7，Double；缺省 = 1.0；读写时都限制在 0.6…1.6，写入时保留两位小数） | 桌宠大小（菜单"大小"：小 0.75 / 标准 1.0 / 大 1.3，或拖右下角的小圆点）。本机桌面上的主宠、来串门的 TA、合体动画、特效和站位间距都按它缩放。老版本忽略这个键（显示标准大小） |
| | `dndUntil`（v0.8，Double，Unix 秒；`0` = 直到我关掉；**缺省 = 勿扰关着**） | 勿扰模式结束时间。重启后还开着；已经过了的在启动时自动结束（并记进 `dndLog`）。老版本忽略（不勿扰） |
| | `dndMood`（v0.8，String：`angry` / `busy` / `resting` / `unsaid`；缺省或不认识 = `unsaid` 🤐 不说原因） | 勿扰的心情；关掉勿扰后也保留，是菜单里「心情」的选择 |
| | `dndSince`（v0.8，Double，Unix 秒；只在勿扰开着时存在） | 这次勿扰从什么时候开始（给「记录」里的分隔线用） |
| | `dndLog`（v0.8，JSON 数组 `[{"start": 毫秒, "end": 毫秒, "mood": "angry"}]`，旧的在前，最多 500 条；坏数据 = 空） | 结束了的勿扰时段，「记录」里显示成「😤 勿扰中 14:05–15:10」分隔线 |
| | `outfitHistory`（v0.8，字典 `{角色 rawValue: [造型名]}`，最近的在前，每个角色最多 10 个；缺省 = 空） | 「换回上一个」的造型栈。换个造型 / 定时换装 / 选择造型时把离开的那套压进去，换回上一个时弹出；已经不存在的造型名弹出时跳过 |
| | `toolsSettings`（v0.10，JSON `{"pomodoro": {"focus": 1500, "shortBreak": 300, "longBreak": 900, "roundsPerLong": 4}, "waterEnabled": false, "standEnabled": false, "waterInterval": 3600, "standInterval": 2700}`，单位秒；缺省 / 坏数据 = 这些默认值，提醒默认关） | 小工具设置。缺的键用默认值，不认识的键忽略。老版本忽略这个键 |
| | `pomodoroState`（v0.10，JSON `{"phase": "idle\|focus\|shortBreak\|longBreak", "until": Unix 秒（暂停时没有）, "pausedRemaining": 秒（只在暂停时有）, "completedFocus": 本轮已完成的专注次数}`；缺省 = idle） | 番茄钟进度，重启后从这里恢复（`until` 是 wall clock，睡眠期间照常走，醒来后只推进一步）。老版本忽略 |
| | `waterLog`（v0.10，JSON `{"day": "yyyy-MM-dd"（本地日期）, "cups": 杯数}`；缺省 = 空，跨天读成 0） | 今天喝了几杯 |
| | `reminder.water` / `reminder.stand`（v0.10，JSON `{"interval", "activeSeconds", "lastTick", "snoozeUntil", "showing"}`，秒 / Unix 秒；没存过 = 按设置新建） | 喝水 / 站立提醒的累计活跃时间和「等会儿」状态 |
| | `deviceId`（v0.11，String，UUID；第一次读取时生成并保存，每台机器 / 每个 profile 一个） | 发布在 presence 的 `device` 里，用来分辨两台机器是不是占了同一个座位（`SeatClash`）。老版本忽略这个键 |
| | `upgradeNudgedFor`（v0.11.2，String，如 `"0.12.0"`；缺省 = 没提醒过） | 我已经被"TA 升级了"气泡提醒过的那个对方版本（`UpgradeNudge`）：同一个对方版本只弹一次，对方升到更高版本才再弹。老版本忽略这个键 |
| | `whatsNewSeen`（v0.13，String，如 `"0.13.0"`；缺省 = 没看过） | 最近一次看过更新日志的版本。启动时：没有这个键又没有配置 = 新用户，直接记成当前版本、不弹卡片；没有这个键但已有配置 = 从 0.12.2 及以前升级上来的老用户，弹「升级到 vX 啦」卡片（只汇总最新一条）。老版本忽略这个键 |
| | `setupTodoDismissed`（v0.13，字符串数组，如 `["city","reminders"]`；缺省 = 空） | 「待设置」里点了「不用了」的项（`city` / `weatherWidget`（v0.13.3 起不再出现） / `reminders` / `partnerUpgrade`），永远不再出现；欢迎窗走完时会写入 `city` 和 `reminders`。老版本忽略 |
| | `updateLastCheck`（v0.14，Double，Unix 秒；缺省 = 从没检查过） | 一天一次自动检查更新的上次时间（失败的检查也算一次，断网不会连环重试）。读不到就当作该检查了 |
| | `updateSkipped`（v0.14，String，如 `"0.14.0"`；缺省 = 没跳过） | 在新版本卡片上点了「以后再说」的版本。只有自动检查对它保持安静；手动「检查更新」照常提示，更新的版本也照常提示 |
| | `myPlace`（v0.12，`WeatherPlace` 的 JSON：`{"name", "admin"?, "country"?, "latitude", "longitude", "timezone"}`；经纬度保留两位小数，读取时也会取整；缺省 / 坏数据 = 没设城市） | 我的城市。设了才会查天气，也才会发布到 presence 的 `place`。老版本忽略这个键 |
| | `weatherWidget`（v0.12，JSON `{"enabled": Bool, "x": Double?, "y": Double?}`；缺省 / 坏数据 = 关闭、没拖动过） | **已弃用（v0.13.3 起不再使用）**：v0.12 桌面天气小组件的开关和位置。v0.13.3 去掉了小组件（天气改在传话面板里），键仍可读、不会删，也不再写。老版本忽略 |
| | `weatherCache`（v0.12，JSON `{"<纬度两位>,<经度两位>": WeatherSnapshot}`，最多 8 个地点，满了删最旧的；坏数据 = 空） | 每个地点最近一次成功的天气（失败时保留旧数据，显示「x 分钟前」）。老版本忽略 |
| | `myPlaceAuto`（v0.14.1，Bool；缺省 = false；关掉时直接删除这个键） | 「使用我现在的位置」开关：`true` 表示 `myPlace` 是自动定位出来的。手动选 / 清除城市会把它删掉。老版本忽略这个键（`myPlace` 仍是一个普通城市，老版本照常用） |
| | `nwsLookups`（v0.14.1，JSON `{"<纬度两位>,<经度两位>": {"isUS": Bool, "stations": [{"id", "latitude", "longitude"}], "checkedAt": Unix 秒}}`，最多 8 个地点；坏数据 = 空） | 美国气象局 `/points` → 附近气象站的查询结果缓存（7 天；`isUS: false` = 不在美国，同样缓存 7 天）。单独一个键，不改 `weatherCache` 的格式。老版本忽略 |
| （不存） | "隐藏到几点"**故意不保存**：重启 App 一定重新显示 | v0.4 |
| 本地聊天记录 | `~/Library/Application Support/LuluPet/<profile 或 default>/history.jsonl` | 所有历史消息 |
| Firebase 路径 | `/pairs/{pairCode}/messages/{pushId}`、`/pairs/{pairCode}/presence/{lulu\|lumei}/lastSeen` | 两个人共用的数据 |
| presence 字段 | `/pairs/{pairCode}/presence/{role}` = `{"lastSeen": 毫秒, "dnd": {"mood": "angry", "until": 毫秒或 0}}`：`dnd`（v0.8，可选）只在勿扰开着时写，`until` = 0 表示直到手动关掉，`mood` 同 `dndMood`（不认识的心情显示成"TA 勿扰中"，不带原因） | 老版本只读 `presence/{role}/lastSeen`，所以看不到勿扰、照常送达（新版本收到后照样攒着）；老版本心跳 PUT 整个对象时没有 `dnd`，新版本读到就是"没开勿扰"。v0.8 读整个 `presence/{role}` 对象，缺 `dnd` = 没开 。v0.10 再加可选 `focus`：`{"phase": "focus", "until": 毫秒}`，只在番茄钟专注中（没暂停）写，`until` 的单位和 `dnd.until` 一样是 Unix 毫秒；老版本整个对象 PUT 时没有 `focus` = 没在专注，老版本读 presence 时忽略 `focus`；新版本读到已过 `until` 的 `focus` 当作没有，缺 `phase` 当 `"focus"`，`until` 不是数字就整个忽略。清楚下线（`lastSeen: 0`）时不写 `focus`。v0.11 再加可选 `character`（`lulu` / `lumei`：对方画的是哪个角色）、`mode`（`solo` / `couple` / `friend`）、`device`（对方这台机器的 `deviceId`）：缺省 = 老客户端 / 没发布，新版本分别按「对方座位同名角色」「情侣」「不算座位冲突」处理；不认识的值读成缺省；老版本整个对象 PUT 时没有它们，老版本读 presence 时忽略它们。v0.11.2 再加可选 `app`（字符串，对方的 App 版本，如 `"0.11.2"` = `CFBundleShortVersionString`；不在 App 包里运行（`swift run`）时不写）：缺省 = 老客户端 / 未知，不提醒也不被提醒；解析不了的字符串当作未知（`AppVersion`）；心跳和下线（`lastSeen: 0`）都带它；老版本整个对象 PUT 时没有 `app`，读 presence 时忽略它。我方座位的 presence 在线（`lastSeen` 在 75 秒以内）而且 `device` 不是本机 = 座位冲突（`SeatClash.detect`），`device` 缺省不算冲突。读取方式：只在启动时和之后每约 3 分钟读一次自己的座位（在那一轮心跳 PUT 之前读，否则读到的只是自己刚写的），连续两次读到才报冲突、连续两次读不到才算解除（`SeatClashMonitor`） |
| 消息字段 | `from`（`lulu`/`lumei`）、`kind`（`text`/`sticker`/`poke`/`visit`（v0.2 起）/…）、`text`、`stickerId`、`ts`（Unix 毫秒）、`v`（可选，缺省 = 1）、`outfit`（v0.5，可选字符串：发送时自己桌宠穿的造型名，如 `"bear"`；缺省 = 不知道）、`trip`（v0.6，可选字符串：`"deliver"` = 发送时自己的桌宠真的跑出去送了，`"local"` = 没跑（和来访的 TA 就地见面 / 桌宠已经在外面 / 对方离线跑到边上就回来了）；缺省或不认识的值 = `"deliver"`） | 老消息就是这样存的。`outfit`：v0.4 及更早的版本收到后放进 `extra` 原样保留、界面忽略；v0.5 收到时访客穿这套（本机没有这套就穿对方角色的默认造型）。`trip`：v0.5 及更早的版本收到后放进 `extra` 原样保留、界面忽略；v0.6 用它判断两边是不是同时出门（见 visits-design §12），老版本发来的消息没有 `trip`，按 `"deliver"` 处理 ；`remind`（v0.10，可选字符串，只在 `kind: "remind"` 的消息上：`"water"` / `"stand"`，不认识的值 = 没有这个提醒类型，但原样保留）、`ackOf`（v0.10，可选字符串：这条 remind 是对哪条提醒（push id）的回执「TA 喝啦 / TA 站起来啦」；缺省 = 是一条新的提醒）。老版本（< v0.10）收到时 `remind` / `ackOf` 放进 `extra` 原样保留；`character`（v0.11，可选字符串 `lulu` / `lumei`：发送方的桌宠画的是哪个角色；缺省 = 不知道，按发送方座位同名角色）：v0.10 及更早的版本收到后放进 `extra` 原样保留、界面忽略（会按座位画角色，对方升级后就对了）；v0.11 读到不认识的值时 `Message.character` 为 nil，原始字符串留在 `extra["character"]` 里写历史时原样写回 |
| 本地专用字段 | 历史文件里额外的 `id`（push id）和 `localId`（发送时的本地 id），不会上传 | 去重 |
| 身份取值 | `lulu` / `lumei` | 写在 `config` 和每条消息的 `from` 里 |
| 配对码格式 | 24 位，字符表 `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`（去掉 0/O/1/I） | 也是 Firebase 路径；规则要求长度 ≥ 24 |

## 2. 规则（Rules）

1. **字段只增不改（additive only）**：可以给消息 / 配置加新的**可选**字段；不能改名、不能删、不能改类型或单位
   （比如 `ts` 永远是毫秒整数）。新增字段在解码时必须可缺省（`decodeIfPresent` / 有默认值）。
2. **老版本必须能容忍新数据**：
   - 不认识的 `kind`（比如将来的 `voice`）不会被丢掉：解码为 `.unknown("voice")`，原样存进历史，
     气泡里显示"［新版本消息，请升级噜噜桌宠查看］"。
   - 不认识的字段保存在 `Message.extra` 里，写历史时原样写回，界面忽略。
   - 所以新版本加新消息类型时，**老版本也会照常记录**，等升级后就能正常显示。
3. **`v`（schema version）**：发送时写 `v: 1`；没有 `v` 视为 1。只有当旧客户端**必须**区别对待时才升 `v`，
   并且仍然要遵守第 1 条。
4. **本地历史只追加**：`history.jsonl` 永远不重写、不截断、不删除（包括迁移时）。崩溃留下的半行会被跳过。
   启动后第一次连上时，会从 Firebase 拉一次完整消息列表合并进来（按 id 去重），
   所以新装、换电脑、文件丢了都能恢复。
5. **迁移不删远端数据**：`ConfigStore.migrations` 按版本号顺序执行（`schemaVersion` 记录进度），
   迁移只能新增或转换**本地**数据；**绝不**删除或改写 Firebase 上的消息。
6. **Firebase 规则**只要求 `from` / `kind` / `ts`；不要加"禁止未知字段"的校验（见 firebase-setup.md）。

## 3. 发版本（Versioning）

- 版本号只在一个地方：仓库根目录的 `VERSION`（例如 `0.1.0`），`scripts/build_app.sh` 把它写进
  `CFBundleShortVersionString`。每次要发给对方前改一下这个文件。
- `CFBundleVersion`（构建号）= `git rev-list --count HEAD`，自动递增——发版前先提交。
- 升级方法：v0.14 起可以在 App 里点「检查更新…」一键更新（见第 10 节，发布到 GitHub Releases，资产名 `LuluPet.zip`）；也可以把新的 `LuluPet.app` 拖进"应用程序"覆盖旧的。配置和聊天记录都不在 App 包里，不受影响。

## 4. 加新东西时的检查清单（Checklist）

- [ ] 新字段是可选的吗？老版本收到它会怎样？（应该：忽略但保留）
- [ ] 新 `kind`：老版本会显示"请升级"的提示，这可以接受吗？
- [ ] 没有改动第 1 节表格里的任何名字、路径、键
- [ ] 需要迁移本地数据？往 `ConfigStore.migrations` 追加一条，版本号 +1，写测试
- [ ] `swift run LuluCoreTests` 里"today's payloads decode"之类的兼容测试仍然通过（不要改 fixture 去迁就新代码）

## 5. 资源清单字段（assets/*.json → Resources，v0.9）

这些是随 App 打包的清单，不是用户数据，但同样**只增不改**：老字段含义不变，新字段都是可选的，缺省 = 以前的行为。

| 清单 | 新字段（v0.9） | 说明 |
|---|---|---|
| `sounds.json` | 列表项可以是对象 `{"file": "v4/S01.m4a", "visitor": "lulu"}`（也可单个对象当值） | 只在"这件事说的是噜噜 / 噜妹"时才放这个文件：arrive = 来访的那只，goVisit / goBack = 自己的桌宠。纯字符串仍表示中性（谁都放）。`visitor` 不是 `lulu` / `lumei` 时当中性。老版本解析时会跳过对象项（只丢这几条声音，其余照常） |
| `couples.json` | `"sound": "<sounds.json 的键>"` | 绑定到这个合体动画的声音：播这个动画时替换 `SoundEvent.forCouple` 的类别声音（顺序：reactions.json 的 `sound` → 动画绑定声音 → 贴纸内置声音 → 类别声音；该键没有声音文件就落到下一个） |
| | `"heightFactor": 0.7` | 半身动画画得小一点（占桌宠高度的比例，0.3…1.5，缺省 1）。写进 `Couples/<name>/meta.json` |
| `reactions.json` 的访客动画条目 / `sprites.json` 的 fidgets / stay | `"sound": "<sounds.json 的键>"` | 动画开始时放的声音（写进造型的 `clips.json` / `fidgets.json` 条目），配音和画面对齐 |
| `reactions.json` | 伪条目 `"click"`：`{"visitor": {"lulu": [...]}}` | 单击桌宠时有 `ReactionTable.clickChance`（20%）的概率播这里的搞笑动画，代替普通 react |
| `sounds.json` | 新的自定义键（`hug_missyou` / `comfort_missyou` / `angry_hmph` / `dance_lalala` / `sleep_snore` / `lulu_comein`） | 只被上面的 `"sound"` 引用，不是事件 |
| `changelog.json`（v0.13） | `[{"version": "0.12.2", "date": "2026-10-07", "items": ["…"]}]` | 只读资源，构建时从 `assets/changelog.json` 复制成 `Resources/changelog.json`；字段只增不改，读不出来 = 空日志，不弹卡片 |

新增 / 改动的 `couples.json` 键名（`sleep` / `cuddle_bed` / `coldwar` / `makeup` / `comfort` / `hug_bed` / `sniff` / `bite` / `shout` / `lean`）只增不删；`reactions.json` 里引用了不存在的合体动画时，构建会警告、运行时从池里跳过。

## 6. 个人小工具（v0.10）

- **新消息类型 `kind: "remind"`**（「叫 TA 喝水 / 起来动动」）。老版本（< v0.10）不认识这个 kind，按第 2 节规则解码成 `.unknown("remind")`，实际行为（读代码得出）：
  - 照常存进本地历史（`remind` / `ackOf` 在 `extra` 里原样写回）；「记录」里显示成灰色的「［新版本消息］」；
  - 桌面上：来访的 TA 照样跑过来（走默认的串门动画，因为 `reactions.json` 没有 `remind` 这个键就落到 `default`），气泡显示「［新版本消息，请升级噜噜桌宠查看］」，要点掉才离开；
  - 「离开期间」汇总里算作"其它消息"（v0.10 起 `.remind` 暂时同样算进 `unknown`）；
  - **回执（带 `ackOf` 的 remind）对老版本也是一条这样的未知消息**：会再来一次访客 + 升级提示。可以接受，升级后就正常。
  - 所以老版本不会丢消息也不会崩，只是看不懂提醒内容、也不会有"喝了 / 等会儿"按钮。
- `Message.Kind.remind` 的 `rawValue` 永远是 `"remind"`；`remind` 字段的取值只增不改（现有 `water` / `stand`）。
- 对方在专注（`presence.focus` 有效）时，发送方把东西"先放在 TA 那儿"；消息本身照常写进 Firebase，不影响老版本。
- 新的 `HousekeepingTask`（`pomodoro` wall clock，`water` / `stand` monotonic）只是 app 内部的计时挂点，不涉及数据格式。
- **v0.10 partner（Task 3）：** `reactions.json` 新增 `remind_water` / `remind_stand` 两个键（只增）；v0.10 收到 remind 时按它们挑访客片段。回执（`ackOf`）不串门，只在自家宠物冒小气泡。对方专注（`presence.focus` 有效且在线）时，发送方的消息照发但宠物只跑出去再回来（同勿扰）；接收方自己专注时，来访先攒着，专注结束后用「你专注的时候，TA来过～」卡片汇总（remind 在卡片里是「💧 叫你喝水 ×N」等行，不再算「新版本消息」）。没有新的 UserDefaults 键。

## 7. 三种模式（v0.11）

- 规格：docs/superpowers/specs/2026-10-05-modes-design.md。`Role`（lulu / lumei）从此是**座位**，线上的值、Firebase 路径、`message.from`、`presence/<role>` 一律不变；`PetCharacter` 表示画哪个角色，raw 值和 Role 相同。
- 新的键 / 字段（全部可选，缺省 = 以前的行为）：`config.mode` / `config.character`、`deviceId`、`presence.character` / `mode` / `device`、`message.character`（具体见第 1 节表格）。
- 对方的角色按 `presence.character` → 对方最近一条消息的 `character` → 对方座位同名角色推断（`PartnerIdentity.resolve`）；对方的模式取 `presence.mode`，缺省 = 情侣。两边模式不一致时按更严格的来：任意一方是朋友就过滤亲密内容（`ContentPolicy`）。
- 清单里的 `intimate`（只增，缺省 = false，老版本 / 老 Resources 全都当非亲密）：
  - `couples.json` 条目 `"intimate": true`，写进 `Couples/<name>/meta.json`（`CoupleClip.intimate`）。已标：`hug` `hug_slow` `hug_soft` `hug_sit` `hug_stand` `hug_kneel` `hug_bed` `kiss` `kiss_2` `kiss_sit` `nuzzle` `cuddle_bed` `comfort` `lean` `sniff`。
  - `stickers.json` 条目 `"intimate": true`，写进 `Stickers/stickers.json`（`Sticker.intimate`）。已标：`hug` `kiss` `nuzzle` `sleeptogether` `holdhands` `wink`。
  - `sounds.json` 的对象条目 `{"file": ..., "intimate": true}`（可以和 `visitor` 同时出现）：`v4/S02`（arrive / goBack）、`v4/S06`（hug / hug_missyou / comfort_missyou）。`SoundManifest.files(for:visitor:allowIntimate:)` 在 `allowIntimate == false` 时跳过它们；整个事件的文件都被跳过时，调用方改用分类音效。老版本解析时跳过对象条目（只丢这几条声音）。

## 8. App 版本互相提醒（v0.11.2）

- `presence/<seat>/app`（可选字符串）见第 1 节表格；本地键 `upgradeNudgedFor` 同。纯加字段，老版本忽略，没有迁移。
- 规则 `UpgradeNudge`：双方版本都能解析才比较；任一方未知（老客户端 / 没发布）→ 什么都不提示。对方更新 → 首页气泡（每个对方版本一次，「知道啦」）+ 🍊 菜单常驻一行，直到我升级；对方更旧 → 菜单一行"TA 还在用 vX"，不弹气泡。只在情侣 / 朋友模式、对方在线时显示；一个人模式什么都没有。
- 隐藏测试参数 `--fake-app-version X` 只改本次运行报告的版本。

## 9. 天气（v0.12）

- 规格：docs/superpowers/specs/2026-10-06-weather-design.md。纯加字段，没有迁移，老版本忽略全部新东西。
- **presence 新字段 `place`**（可选对象，`WeatherPlace` 的 JSON：`name` / `latitude` / `longitude` / `timezone` 必填，`admin` / `country` 可选；经纬度只有两位小数）。心跳和下线（`lastSeen: 0`）都带它，所以对方离线时也能查到我这边的天气。缺省 = 没设城市 / 老客户端；读到缺必填项或类型不对的 `place` 当作没有；老版本整个对象 PUT 时没有 `place`，读 presence 时忽略它。
- 本地键 `myPlace` / `weatherWidget` / `weatherCache` 见第 1 节表格。
- 新的 `HousekeepingTask.weather`（wall clock）只是 app 内部的计时挂点，不涉及数据格式。网络：只访问 Open-Meteo（`api.open-meteo.com`、`geocoding-api.open-meteo.com`），不用 key；每 30 分钟最多 2 个请求。
- 资源清单：`assets/sprites.json` 里每个角色可选的 `"weather": {"rain" | "snow" | "hot" | "cold" | "windy": [clip 规格]}`（和 `fidgets` 的规格一样，不是造型）。`tools/build_sprites.py` 写出 `Resources/Sprites/<角色>/weather.json`（`{look: [{"name", "dir", "sound"?}]}`）和 `_weather/<look>_<i>/`；没有片段 / 空列表就什么都不写，运行时没有片段 = 不变（`SpriteCatalog.weatherClips`）。老版本不读这些文件；`_weather` 目录不含 `idle`，不会被当成造型。
- 隐藏测试参数 `--fake-weather`（Task 2 / 3 接线）：用固定数据（`FakeWeather`），不联网；双人模式下对方没有公布城市时用「上海」顶上（只为截图）。
- 桌面小组件（Task 3）：只用已有的本地键 `weatherWidget`（`enabled` / 左上角坐标 `x`、`y`），没有新键。小组件窗口层级在桌面图标层 +1，跟着全屏自动隐藏一起隐藏；关闭时窗口和每分钟的时钟都不存在。天气刷新只有 `HousekeepingTask.weather` 一个挂点（设了城市且（小组件开 ∨ 面板开 ∨ 角色有天气片段）才存在，失败的尝试也算一次，所以断网不会连环重试）；唤醒后过期就立刻补一次。

- v0.13.3：天气卡片在传话面板里（TA 一行、我一行；单人只有我），不再有桌面小组件；`weatherWidget` 键已弃用（见第 1 节）。天气刷新的条件改为「设了城市 ∧（配对且 TA 有城市 ∨ 面板开 ∨ 角色有天气片段）」。「想 TA」气泡不存任何新键、不上传任何新字段（只读已有的对方 `place` 和天气）。

## 10. 一键更新（v0.14）

- 纯加：两个本地键 `updateLastCheck` / `updateSkipped`（第 1 节表格），没有新的远端字段，没有迁移，老版本忽略。
- 来源：GitHub Releases `richardzhuang0412/LuluPet` 的 `releases/latest`（不带 token，`User-Agent: LuluPet/<版本>`），按名字找资产 `LuluPet.zip`；`tag_name` 写成 `v0.14.0` 或 `0.14.0` 都行；草稿 / 预发布 / 没有该资产 = 当作没有新版本。**发版时资产名必须是 `LuluPet.zip`（`scripts/build_app.sh` 的产物，原样上传）。**
- 检查：一天一次（`HousekeepingTask.updateCheck`，挂在已有的 housekeeping 一次性计时器上，没有新的重复计时器；启动后至少 20 秒才查），另有菜单「检查更新…」和更新日志窗口里的按钮。找到新版本：我自己的桌宠冒卡片「有新版本 vX · 更新」（「更新」/「以后再说」），菜单多一行「有新版本 vX」，TA 升级提醒气泡多一个「一键更新」。
- 更新：下载到临时目录 → `ditto -x -k` → 校验（bundle id = `com.lulupet.app`、版本 > 当前、`codesign --verify --deep --strict`）→ 写一个 `/bin/sh` 小脚本并脱离启动：等本进程退出，`ditto` 到 `<App>.new`，旧的改名 `<App>.old`、新的换上去（失败就还原）、`xattr -dr com.apple.quarantine`、`open` 重新打开（带原来的启动参数，`--demo-update*` 除外）。App 随后走正常退出（presence 下线）。只在 App 直接位于 `/Applications` 或 `~/Applications` 时自动更新，其余情况提示「请手动更新」+ 发布页。
- 用户数据（UserDefaults、Application Support、日志）都在 App 包外，脚本从不碰；确认框里写明「聊天记录和设置不会丢」。更新后的更新日志卡片走 v0.13 已有的 `whatsNewSeen` 逻辑。
- 隐藏测试参数：`--update-feed <url>`（整个替换 releases/latest 的地址）、`--update-auto-confirm`（跳过确认框）、`--update-allow-dir <dir>`（把该文件夹也当作可自动更新的位置）、`--demo-update-check S`（S 秒后手动检查）、`--demo-update-now S`（S 秒后一键更新）。`--offscreen` 的测试实例没有 `--update-feed` 时不做每日自动检查（测试不碰 GitHub）。

## 11. 天气更准 + 使用当前位置（v0.14.1）

- 研究：docs/research/weather-accuracy.md。纯加字段 / 加键，没有迁移，老版本忽略全部新东西；presence 的 `place` 格式不变（自动定位出来的城市也只是一个取整到两位小数的 `WeatherPlace`，TA 看不出区别，也不会收到精确位置）。
- 新的本地键：`myPlaceAuto`、`nwsLookups`（见第 1 节表格）。`weatherCache`（`WeatherSnapshot`）格式不变。
- 网络：除 Open-Meteo 外，**美国坐标**还会访问 `api.weather.gov`（`/points`、`/gridpoints/…/stations`、`/stations/<id>/observations?limit=3`；`User-Agent: LuluPet/<版本> (github.com/richardzhuang0412/LuluPet)`，无 key）。点到站的查询每个地点缓存 7 天，平时每次刷新只多 1 个观测请求（最多 3 个：最近的站没有可用读数时依次试下一个）；中国等明显不在美国的坐标从不请求；`/points` 返回 404 = 不在美国，同样缓存 7 天，服务器报错不缓存。读数要求有温度、不超过 90 分钟、站点在 25 公里内，不满足就退回 Open-Meteo；温度站没有天气描述 / 云层时，再多请求 1 次最近的机场站（K 开头、25 公里内、90 分钟内）借它的天气，都没有才用 Open-Meteo 的；最高 / 最低温一直来自 Open-Meteo。Open-Meteo 的 `current` 多请求一个 `cloud_cover`，WMO 3 只有云量 ≥ 85 才算「阴」，否则是「多云」。
- 定位（默认关，用户在设置里打开）：`NSLocationUsageDescription` / `NSLocationWhenInUseUsageDescription` 写进 Info.plist（`scripts/build_app.sh`）；`CLLocationManager.requestLocation()` 一次性、公里级精度；授权弹窗只会在用户点「使用我现在的位置」时出现，后台刷新遇到没决定的授权当作没授权，不弹窗。反查城市名：macOS 26 用 `MKReverseGeocodingRequest`，更早用 `CLGeocoder`，都用 zh_CN。刷新时机：启动、唤醒（至少隔 5 分钟）、距上次 3 小时（新的 `HousekeepingTask.location`，挂在已有的 housekeeping 一次性计时器上，没有新计时器；只在 `myPlaceAuto` 为 true 时才有）；位置移动超过 3 公里才重新反查城市名。手动选 / 清除城市会把 `myPlaceAuto` 关掉。精确坐标不落盘、不上传，只有取整后的城市存进 `myPlace`。
- 隐藏测试参数（不碰真实定位权限）：`--fake-location ok|denied|fail`、`--demo-my-place-auto`、`--demo-location-status denied|failed|locating`。
