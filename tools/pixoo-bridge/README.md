# Pixoo-64 小屏幕（pixoo-bridge）

把噜噜桌宠「搬」到一块 64×64 的像素屏上：放在 TA 家里的树莓派一直开着，实时把**一个座位**（默认 `lulu`）发来的消息
画在 Divoom Pixoo-64 上，平时屏幕上是那个人的桌宠，在线就动、勿扰就安静、离线就睡觉。

它是一个**只读**的小程序：只从 Firebase 读消息和在线状态，从不写任何东西（见下面「隐私」）。

## 屏幕上会出现什么

| 发生了什么 | Pixoo 上 |
|---|---|
| 平时，对方在线 | 对方当前造型的待机动画 |
| 对方开了勿扰 / 在专注 | 安静站着，右上角一个小 🔕 / 🍅 |
| 对方离线 | 造型有睡觉片段就放睡觉，没有就变暗 + 「Zzz」 |
| 戳一下 | 开心动作 + 飘起来的小爱心 |
| 文字 | 上面是角色，下面两行像素中文，长了自动翻页（右上角小点是页码） |
| 表情 | 表情动图铺满屏幕，底下一行表情名字（可关） |
| 串门 | 角色从左边跑进来，然后「来看看你～想你啦」 |
| 叫你喝水 / 起来动动 | 喝水 / 活动的小片段 +「喝水啦 💧」「起来动动 🧍」 |
| 对方回复了你的提醒 | 「TA 说马上喝 💧」「TA 说等会儿再动」…… |

每条消息放 20–25 秒（文字按页数延长）再回到待机；一次来好几条就排队，一条一条放（排队时每条时间减半）。
夜里（默认 23:00–08:00）屏幕关掉或调到很暗，这段时间来的消息早上再放（也可以设置成直接跳过）。

用 `--preview` 可以先在电脑上看到每种画面（GIF + 一张总览图），不需要 Pixoo。

## 需要的硬件

- **Divoom Pixoo-64**，先用 Divoom App 连好家里的 Wi-Fi。
- **树莓派**：Pi 3 / 4 / 5 或 Zero 2 W，装 **64 位** Raspberry Pi OS（Lite 就行），和 Pixoo 在同一个局域网。
  其实任何一直开着的 Linux / macOS 电脑都可以，下面以树莓派为例。
- 网络：树莓派要能访问 Firebase（HTTPS）和 Pixoo（局域网 HTTP）。

## 隐私：它读什么、不写什么

- **只读**这三样：`/pairs/<配对码>/messages`（按时间从游标往后的新消息，实时流 + 断线时轮询）、
  `/pairs/<配对码>/presence/<座位>`（每 15 秒一次，用来决定待机画面）。不读历史记录，不读别的路径。
- **从不写** Firebase：不写 `presence`（否则对方会显示「在线」），不写 `read`（否则会把消息标成已读、让对方收不到推送），
  不在 `devices/` 下登记（否则会打乱推送发给哪台设备）。代码里有两道闸：所有发往 Firebase 的请求都经过一个只放行 GET 的
  fetch，客户端对象上的写方法一调用就报错；测试会检查这两点（`test/readonly.test.mjs`）和整条链路只发 GET
  （`test/bridge.e2e.test.mjs`）。
- 它自己的「读到哪了」存在树莓派本地的一个 JSON 文件里。**第一次启动从「现在」开始**，不会把以前的消息重放一遍。
- 配对码和数据库地址只在配置文件里，日志里一律显示成 `***`。消息正文不写进日志（只记类型和 id 尾巴）。
- 自动查找 Pixoo（不填 IP 时）会请求 Divoom 的服务器 `app.divoom-gz.com`，它按公网 IP 列出同一网络里的 Divoom 设备；
  不想联系 Divoom 的话，直接在配置里填 Pixoo 的 IP。
- 素材（角色、表情）直接读仓库里的 `web/assets/`，转换后的小图只缓存在本机（`cache/`），不进仓库、不对外分发。

## 在树莓派上安装

### 1. 装 Node.js（≥ 20）

Raspberry Pi OS 自带的 Node 太旧，用 NodeSource 的源装 22 版：

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs git
node --version     # v22.x
```

### 2. 下载代码、装依赖、下载字体

```bash
sudo git clone --depth 1 https://github.com/richardzhuang0412/LuluPet.git /opt/lulupet
cd /opt/lulupet/tools/pixoo-bridge
sudo npm ci --omit=dev       # sharp 会自动下载树莓派（linux-arm64）用的预编译包
sudo npm run fetch-font      # 下载像素字体到 fonts/（约 23 MB 的压缩包，只解出要用的一个文件）
```

### 3. 找到 Pixoo 的 IP

任选一种：

- Divoom App → 设备设置里一般能看到 IP；或者在路由器的管理页面里找名字带 Pixoo 的设备。
- 让 Divoom 的服务器帮忙找：`node bin/pixoo-bridge.js --discover`（会打印 `名字  IP  id`）。

最好在路由器里给 Pixoo 固定一个 IP（DHCP 保留），不然重启后可能变。配置里不填 IP 时，程序每次启动会自动找。

### 4. 写配置

```bash
sudo mkdir -p /etc/pixoo-bridge
sudo cp config.example.json /etc/pixoo-bridge/config.json
sudo nano /etc/pixoo-bridge/config.json
```

至少要改：

| 字段 | 填什么 |
|---|---|
| `databaseURL` | 和 App 里一样的 Firebase 数据库地址（`https://<项目>-default-rtdb.firebaseio.com`） |
| `pairCode` | 和 App 里一样的 24 位配对码 |
| `watchSeat` | 要显示**谁发的**消息：`"lulu"`（A 座位，默认）或 `"lumei"`（B 座位）。另一个座位发的消息一律忽略 |
| `pixoo.ip` | Pixoo 的 IP，比如 `"192.168.1.50"`；留空 = 自动查找 |

其他可选：

| 字段 | 默认 | 说明 |
|---|---|---|
| `brightness` | `60` | 白天亮度 0–100 |
| `timezone` | 系统时区 | 夜间时段按哪个时区算，比如 `"Asia/Shanghai"`；树莓派默认时区常常是 UTC，最好填上或用 `sudo raspi-config` 设好 |
| `quietHours.start` / `end` | `23:00` / `08:00` | 夜间时段（可以跨午夜）；`enabled: false` 关掉 |
| `quietHours.mode` | `"off"` | `"off"` 关屏；`"dim"` 调到 `dimBrightness` 并显示一张静止的暗图 |
| `quietHours.messages` | `"morning"` | 夜里来的消息：`"morning"` 早上再放；`"skip"` 不放 |
| `durations.*Ms` | 20–25 秒 | 每种消息放多久；文字每页 `textPageMs`，最多 `textMaxPages` 页 |
| `stickerLabel` | `true` | 表情下面显示表情名字 |
| `pixoo.url` | 空 | 直接写完整接口地址。Divoom 文档说硬件版本 96 的设备用 `http://<IP>:9000/divoom_api` |
| `pixoo.deviceName` | 空 | 自动查找时，挑名字里包含这几个字的设备 |
| `cacheDir` / `stateFile` | `./cache` / `./state/cursor.json` | systemd 服务里改到了 `/var/lib/pixoo-bridge/` |

也可以用环境变量覆盖：`LULUPET_DATABASE_URL`、`LULUPET_PAIR_CODE`、`PIXOO_IP`、`PIXOO_URL`、`PIXOO_BRIDGE_CACHE_DIR`、
`PIXOO_BRIDGE_STATE_FILE`、`PIXOO_BRIDGE_LOG_LEVEL`、`PIXOO_BRIDGE_CONFIG`（配置文件路径）。

配置文件里有配对码，只给服务用户能读：

```bash
sudo useradd --system --home /var/lib/pixoo-bridge --shell /usr/sbin/nologin pixoo-bridge
sudo chown root:pixoo-bridge /etc/pixoo-bridge/config.json
sudo chmod 640 /etc/pixoo-bridge/config.json
```

### 5. 先预览，再连 Pixoo

```bash
# ① 不需要 Pixoo 也不需要 Firebase：用假消息把每种画面渲染成 GIF + 总览图
PIXOO_BRIDGE_CACHE_DIR=/tmp/pixoo-cache node bin/pixoo-bridge.js --preview --out ~/pixoo-preview
#    ~/pixoo-preview/contact-sheet.png 是总览图，*.gif 是每种画面；可以 scp 到电脑上看

# ② 在 Pixoo 上把示例画面轮流放一遍（不需要 Firebase），确认 IP 对、能显示
sudo -u pixoo-bridge PIXOO_BRIDGE_CACHE_DIR=/tmp/pixoo-cache node bin/pixoo-bridge.js --config /etc/pixoo-bridge/config.json --demo

# ③ 连 Firebase，但不发给 Pixoo：日志里会打印每次要发什么
sudo -u pixoo-bridge PIXOO_BRIDGE_CACHE_DIR=/tmp/pixoo-cache PIXOO_BRIDGE_STATE_FILE=/tmp/pixoo-cursor.json \
  node bin/pixoo-bridge.js --config /etc/pixoo-bridge/config.json --dry-run

# ④ 真实消息写成 GIF 文件（不发给 Pixoo）
… --preview --live --out /tmp/pixoo-live
```

`--dry-run` 跑起来以后，让对方在 App 里戳一下，日志里应该出现 `messages: +1` 和 `show: poke`。Ctrl+C 退出。

### 6. 开机自动运行（systemd）

仓库里带了一个服务文件 `pixoo-bridge.service`（专门的 `pixoo-bridge` 用户、挂了自动重启、只能写 `/var/lib/pixoo-bridge`）：

```bash
sudo cp /opt/lulupet/tools/pixoo-bridge/pixoo-bridge.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now pixoo-bridge
systemctl status pixoo-bridge
journalctl -u pixoo-bridge -f          # 看日志
```

代码不在 `/opt/lulupet` 或配置不在 `/etc/pixoo-bridge/config.json` 的话，先改服务文件里的 `WorkingDirectory` / `ExecStart`。

## 更新

```bash
cd /opt/lulupet
sudo git pull
cd tools/pixoo-bridge
sudo npm ci --omit=dev
sudo npm run fetch-font          # 字体已经有了会直接跳过
sudo systemctl restart pixoo-bridge
```

素材更新后不用手动清缓存：缓存按素材文件名（带内容 hash）区分，旧的不会再被用到；想省空间可以删掉
`/var/lib/pixoo-bridge/cache/`，下次用到时会重新生成。

## 常见问题

| 现象 | 看看这里 |
|---|---|
| 日志里 `pixoo ✗ … timeout` / `ECONNREFUSED` | IP 不对或 Pixoo 不在同一网络。`ping <IP>`；换了 IP 就改配置；硬件版本 96 的设备试试 `pixoo.url` |
| `discovery found no device` | Divoom 云端没看到设备：Pixoo 要先在 Divoom App 里联网绑定，并且和树莓派走同一个出口；直接填 IP 最稳 |
| `firebase: misconfigured (数据库规则拒绝访问 …)` | 数据库地址 / 配对码填错了，或者数据库规则没按 docs/firebase-setup.md 配 |
| `firebase: polling` | 网络挡住了实时流，自动改成每 15 秒查一次，能用，只是慢一点 |
| 屏幕一直是 Pixoo 自己的表盘 | 程序没在跑或连不上 Pixoo：`systemctl status pixoo-bridge`。Pixoo 重启后会回到表盘，程序最多 30 分钟内会重新发待机画面（有消息时立刻） |
| 画面停在上一张、或者半张新半张旧 | Pixoo 固件的已知问题（开源客户端也遇到过）：程序每次发动画前都会重置动画编号；还不行就给 Pixoo 断电重启一下 |
| 夜里屏幕没关 / 早上没亮 | 时区不对：在配置里填 `timezone`，或 `sudo timedatectl set-timezone Asia/Shanghai` |
| 第一次启动没显示以前的消息 | 正常：第一次从「现在」开始。删掉游标文件（`/var/lib/pixoo-bridge/cursor.json`）效果一样 |
| `找不到字体` | 没运行 `npm run fetch-font`（需要能访问 GitHub） |
| 文字显示成小方框 | 字体里没有这个字（少见的生僻字）；表情符号只画常用的几个（💧❤️🧍⏰🔕🍅✨🌙😊），其余的不显示 |

日志更详细：配置里 `"logLevel": "debug"`，或者 `PIXOO_BRIDGE_LOG_LEVEL=debug`。

## Pixoo 接口：核对过什么、有哪些限制

2026-10 对照 Divoom 官方 API 文档（docin.divoom-gz.com 上的 ShowDoc，Pixoo64 部分：command format、Find device、
set brightness、Screen switch、get all setting、Get / Reset sending animation PicId、Send animation、Command list）和两个
常用的开源客户端（GitHub 上的 SomethingWithComputers/pixoo、4ch1m/pixoo-rest）核对，细节写在 `src/pixoo.js` 开头：

- 所有命令都是 `POST http://<IP>/post`，JSON `{"Command": "…"}`，返回 `{"error_code": 0}`。
- 动画：`Draw/SendHttpGif` 每帧一个请求，`PicNum`（帧数，文档写「小于 60」）、`PicWidth: 64`、`PicOffset`（0 起按顺序）、
  `PicID`、`PicSpeed`（每帧毫秒数，整段动画一个速度）、`PicData`（64×64×3 字节 RGB 的 base64，16384 个字符）。
  全部帧收到后 Pixoo 自己循环播放，所以待机动画只发一次，不占网络。
- 开源客户端的经验：连续推几百次后屏幕会不再响应，需要定期 `Draw/ResetHttpGifId`；推送别太频繁（大约一秒一次以内）。
  所以这里**每段动画前都先重置编号、用 PicID 1**（和 pixoo-rest 一样），每段最多 40 帧，请求一个接一个发、中间停 30 ms，
  两段动画之间至少隔 1 秒，超时 5 秒、失败重试 2 次；连续失败会重新查找设备。
- 没有真机测过（开发时手边没有 Pixoo）：程序是按文档和开源客户端写的，用本地假设备（`bin/mock-pixoo.js`，按文档检查每个
  请求）测过。真机上一帧一个请求大概要几十到一百多毫秒，40 帧的动画要几秒才能发完；文字每翻一页都要重新发，所以多页文字
  只发 14 帧（`textFrames`）。觉得卡可以调小 `maxFrames` / `textFrames`。

## 字体和素材

- 中文用 **Fusion Pixel Font（缝合像素字体）10px 比例宽度、简体中文版**（作者 TakWolf，github.com/TakWolf/fusion-pixel-font），
  **SIL Open Font License 1.1**，可以自由使用和再分发。仓库里不放字体文件，`npm run fetch-font` 从 GitHub Releases
  下载固定版本（2026.10.25，校验 SHA-256），解出 BDF 点阵文件和许可证（`fonts/OFL.txt`、`fonts/LICENSES/`）。
  汉字 9×9 像素、每字占 10 像素宽，一行 6 个字，两行一页。
- 画面里的小图标（爱心、水滴、🔕、🍅、Zzz 等）是 `src/icons.js` 里手画的像素点。
- 角色和表情来自仓库里的 `web/assets/`（和网页版同一份），只在本机转换、缓存；版权说明同主 README：非商用、侵删。

## 开发者

```bash
cd tools/pixoo-bridge
npm ci && npm run fetch-font
npm test                                      # 单元测试 + 假数据库 / 假 Pixoo 的端到端测试（需要 python3）
node bin/pixoo-bridge.js --preview            # 输出到 out/
node bin/mock-pixoo.js --port 8090 --out /tmp/mock   # 本机假 Pixoo，配置里 "pixoo": {"ip": "127.0.0.1:8090"}
python3 ../fake_firebase.py --port 8765       # 本机假数据库，配置里 "databaseURL": "http://127.0.0.1:8765"
```

结构：`src/readonly.js`（唯一的 Firebase 入口，只读）、`src/bridge.js`（主循环）、`src/scenes.js`（消息 / 在线状态 → 画面，纯函数）、
`src/render.js`（画面 → 64×64 帧）、`src/assets.js`（精灵表 / 表情 → 小图 + 缓存）、`src/font.js`（BDF 点阵字、换行、分页）、
`src/pixoo.js`（设备接口）、`src/inbox.js`（排队和本地游标）。消息格式、在线状态、提醒回复的文案直接 import 网页版的
`web/js/core/*.js` 和 `web/js/net/firebase.js`，不复制一份；改那些文件时跑一下这里的测试。
