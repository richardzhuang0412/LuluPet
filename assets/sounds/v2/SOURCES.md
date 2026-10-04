# 第二轮声音素材来源（人声分离后）

个人非商用。全部来自 B 站公开视频音轨（未登录下载）。每段都先用 demucs（htdemucs，two-stems）把整条音轨拆成“人声 / 伴奏”，
**输出文件用的是拆出来的人声轨**，不是原始混音。单声道 44.1kHz AAC，响度约 -18 LUFS（峰值限 -1 dBFS），首尾 10 ms 淡入淡出。

入选条件（每段都满足）：

- 该时间段内伴奏轨比人声轨低 ≥ 25 dB（“伴奏低于人声”列），即原视频在这里基本没有 BGM；
- faster-whisper medium（中文，中性提示词，不预设“噜/哼”）对这段人声轨的转写里含有该事件的关键词；
- 时长 0.2–2.5 s。

注意：没有人真正听过这些片段。转写对不到 1 秒的短音不稳定（同一段略改边界会从“哼”变成“呵呵”），whisper 常把“噜”写成“鲁/露/罗”；
“人声”轨只说明这是人声类声音，**不能证明是噜噜本人的配音**（也可能是噜妹或旁白）。f0 = 自相关估计的基频中位数。

| 文件 | 可信度 | 转写（人声轨） | 伴奏低于人声 | f0 | 视频 | 标题 | UP 主 | 时间段 | 备注 |
|---|---|---|---|---|---|---|---|---|---|
| arrive_01.m4a | 高 | 罗罗! | 48.9 dB | 501 Hz | https://www.bilibili.com/video/BV1pthB64Ey9 | 噜噜和回声干起来了~ | 恐龙考古一号 | 0.07–2.42s | 伴奏比人声低 48.9 dB、强浊音（f0≈501 Hz），转写本身就是目标音；与第一轮 cry_02 是同一时刻（这次只保留人声轨） |
| arrive_02.m4a | 高 | 鲁鲁 | 39.8 dB | 445 Hz | https://www.bilibili.com/video/BV1w6hy6kEB2 | 噜噜撒娇求抱抱，噜妹也太宠啦 | 噜噜软萌 | 5.43–6.19s | 伴奏比人声低 39.8 dB、强浊音（f0≈445 Hz），转写本身就是目标音 |
| arrive_03.m4a | 高 | Lulu | 44.9 dB | 322 Hz | https://www.bilibili.com/video/BV1BJeq69EMz | 噜噜噜妹的日常 | 噜噜小王王 | 0.22–0.67s | 伴奏比人声低 44.9 dB、强浊音（f0≈322 Hz），转写本身就是目标音 |
| arrive_04.m4a | 高 | 鲁鲁 | 38.7 dB | 416 Hz | https://www.bilibili.com/video/BV1w6hy6kEB2 | 噜噜撒娇求抱抱，噜妹也太宠啦 | 噜噜软萌 | 1.58–2.01s | 伴奏比人声低 38.7 dB、强浊音（f0≈416 Hz），转写本身就是目标音；与第一轮 nuzzle_03 是同一时刻（这次只保留人声轨） |
| poke_01.m4a | 高 | 干嘛? | 45.8 dB | 408 Hz | https://www.bilibili.com/video/BV1cTwAzAEtT | 噜噜又被打 | 噜噜是个大胖子 | 8.66–9.18s | 伴奏比人声低 45.8 dB、强浊音（f0≈408 Hz），转写本身就是目标音 |
| poke_02.m4a | 高 | 天呐! | 45.8 dB | 558 Hz | https://www.bilibili.com/video/BV1aZLf6aEoV | 大坏噜，才不是这样亲呢！！！ | 软萌噜噜 | 9.40–9.96s | 伴奏比人声低 45.8 dB、强浊音（f0≈558 Hz），转写本身就是目标音 |
| poke_03.m4a | 中 | 哎呀! | 25.2 dB | 459 Hz | https://www.bilibili.com/video/BV16Hgf6bENp | 这像不像你家蹭你的男朋友! | 噜妹的小跟班噜噜 | 2.05–2.45s | 转写吻合，但伴奏余量只有 25.2 dB（<30，接近门槛） |
| poke_04.m4a | 低 | 啊啊啊! | 37.3 dB | 401 Hz | https://www.bilibili.com/video/BV1pthB64Ey9 | 噜噜和回声干起来了~ | 恐龙考古一号 | 9.58–11.23s | 过了“无音乐”门槛，但转写只是间接符合这个事件（如尖叫/呼气，不是确切的那个声音） |
| hug_01.m4a | 中 | 鲁妹要抱抱妈。 | 40.9 dB | 333 Hz | https://www.bilibili.com/video/BV1w6hy6kEB2 | 噜噜撒娇求抱抱，噜妹也太宠啦 | 噜噜软萌 | 6.74–8.90s | 人声干净，但这是一句带关键词的短句，不是单纯的语气声 |
| hug_02.m4a | 中 | 好啦好啦,给你抱。 | 34.2 dB | 304 Hz | https://www.bilibili.com/video/BV1w6hy6kEB2 | 噜噜撒娇求抱抱，噜妹也太宠啦 | 噜噜软萌 | 10.07–11.49s | 人声干净，但这是一句带关键词的短句，不是单纯的语气声 |
| kiss_01.m4a | 中 | 啾。 | 25.8 dB | 408 Hz | https://www.bilibili.com/video/BV1Fsj36yEkT | 我想你了，很想很想！！！ | 软萌噜噜 | 8.51–8.85s | 转写吻合，但伴奏余量只有 25.8 dB（<30，接近门槛） |
| kiss_02.m4a | 中 | 宝宝亲爱的。 | 40.0 dB | 273 Hz | https://www.bilibili.com/video/BV14LJn6HEzT | 亲亲＾3＾不要张大嘴巴子哦～ | 噜噜酱来了 | 6.79–7.34s | 人声干净，但这是一句带关键词的短句，不是单纯的语气声 |
| nuzzle_01.m4a | 中 | 投降啦!别蹭啦! | 31.3 dB | 474 Hz | https://www.bilibili.com/video/BV16Hgf6bENp | 这像不像你家蹭你的男朋友! | 噜妹的小跟班噜噜 | 7.71–9.83s | 人声干净，但这是一句带关键词的短句，不是单纯的语气声 |
| nuzzle_02.m4a | 低 | 呃呃呃呃。 | 43.2 dB | 341 Hz | https://www.bilibili.com/video/BV1Hjer6GEaD | 噜噜撒娇 | -噜噜宝贝- | 1.57–2.71s | 过了“无音乐”门槛，但转写只是间接符合这个事件（如尖叫/呼气，不是确切的那个声音）；与第一轮 hug_03 是同一时刻（这次只保留人声轨） |
| nuzzle_03.m4a | 中 | 还凶人家。 | 40.8 dB | 371 Hz | https://www.bilibili.com/video/BV1xwYM6SEFT | 你们的噜噜也要这样哄吗？哭的怪心疼的 | 我同随风 | 8.78–9.86s | 人声干净，但这是一句带关键词的短句，不是单纯的语气声 |
| angry_01.m4a | 中 | 哼! | 45.4 dB | 390 Hz | https://www.bilibili.com/video/BV1Hjer6GEaD | 噜噜撒娇 | -噜噜宝贝- | 0.00–0.77s | 转写吻合、伴奏低 45.4 dB，但浊音比例偏低（0.59），可能夹气声/噪声；与第一轮 nuzzle_01 是同一时刻（这次只保留人声轨） |
| angry_02.m4a | 中 | 哼。 | 28.4 dB | 596 Hz | https://www.bilibili.com/video/BV19VaN6DEkW | 噜噜哼唧撒娇，噜妹只用一招搞定 | 噜噜软萌 | 4.75–5.47s | 转写吻合，但伴奏余量只有 28.4 dB（<30，接近门槛） |
| angry_03.m4a | 中 | 哼。 | 25.2 dB | 382 Hz | https://www.bilibili.com/video/BV1Fsj36yEkT | 我想你了，很想很想！！！ | 软萌噜噜 | 8.10–8.39s | 转写吻合，但伴奏余量只有 25.2 dB（<30，接近门槛） |
| angry_04.m4a | 中 | 讨厌。 | 29.3 dB | 455 Hz | https://www.bilibili.com/video/BV1Wrj26UEFL | 谁家噜噜这么会撒娇呀? | 噜妹的小跟班噜噜 | 9.10–9.72s | 人声干净，但这是一句带关键词的短句，不是单纯的语气声 |
| cry_01.m4a | 低 | 啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊! | 48.3 dB | 455 Hz | https://www.bilibili.com/video/BV143Yq6KEE2 | 呜呜～为什么要咬噜噜 | 恶霸噜噜 | 14.75–15.04s | 过了“无音乐”门槛，但转写只是间接符合这个事件（如尖叫/呼气，不是确切的那个声音） |
| cry_02.m4a | 低 | 啊啊啊啊! | 25.6 dB | 525 Hz | https://www.bilibili.com/video/BV1xtg562E9H | 下次再亲我就咬你舌头 | 噜噜有点皮 | 8.43–10.08s | 过了“无音乐”门槛，但转写只是间接符合这个事件（如尖叫/呼气，不是确切的那个声音） |
| happy_01.m4a | 高 | 嘻嘻嘻嘻嘻嘻嘻嘻。 | 43.1 dB | 298 Hz | https://www.bilibili.com/video/BV1qRGM6DEwk | 这死噜，太会撒娇了 | 咕咕噜噜和牛牛 | 23.14–24.15s | 伴奏比人声低 43.1 dB、强浊音（f0≈298 Hz），转写本身就是目标音 |
| happy_02.m4a | 中 | 嘻嘻嘻嘻。 | 26.8 dB | 334 Hz | https://www.bilibili.com/video/BV1w6hy6kEB2 | 噜噜撒娇求抱抱，噜妹也太宠啦 | 噜噜软萌 | 11.98–12.74s | 转写吻合，但伴奏余量只有 26.8 dB（<30，接近门槛） |
| happy_03.m4a | 低 | Yeah! | 48.0 dB | 544 Hz | https://www.bilibili.com/video/BV1pthB64Ey9 | 噜噜和回声干起来了~ | 恐龙考古一号 | 2.61–3.04s | 过了“无音乐”门槛，但转写只是间接符合这个事件（如尖叫/呼气，不是确切的那个声音）；与第一轮 happy_01 是同一时刻（这次只保留人声轨） |
| happy_04.m4a | 中 | 超喜欢你 | 31.0 dB | 377 Hz | https://www.bilibili.com/video/BV1duh969EHq | 谁懂啊！闹脾气的水豚，听到喜欢人的语音瞬间变软 | 愿景泰 | 29.08–29.90s | 人声干净，但这是一句带关键词的短句，不是单纯的语气声 |
| doze_01.m4a | 低 | 呼! | 28.8 dB | 375 Hz | https://www.bilibili.com/video/BV1cFtv6MEqL | 臭噜噜，吵架的，你还睡着了！ | 是小小噜呀 | 0.26–1.26s | 过了“无音乐”门槛，但转写只是间接符合这个事件（如尖叫/呼气，不是确切的那个声音） |
| doze_02.m4a | 低 | 呼。 | 47.0 dB | 408 Hz | https://www.bilibili.com/video/BV1pthB64Ey9 | 噜噜和回声干起来了~ | 恐龙考古一号 | 11.74–12.08s | 过了“无音乐”门槛，但转写只是间接符合这个事件（如尖叫/呼气，不是确切的那个声音） |
| doze_03.m4a | 中 | 我还没睡着呢。 | 43.5 dB | 292 Hz | https://www.bilibili.com/video/BV1uTEx6uEQJ | 像不像你的男朋友！！#水豚噜噜 #打呼噜 | 软萌噜噜 | 8.43–9.84s | 人声干净，但这是一句带关键词的短句，不是单纯的语气声 |
| doze_04.m4a | 中 | 我不是故意的,我就是太困了。我不管。 | 38.2 dB | 513 Hz | https://www.bilibili.com/video/BV1cFtv6MEqL | 臭噜噜，吵架的，你还睡着了！ | 是小小噜呀 | 13.92–16.31s | 人声干净，但这是一句带关键词的短句，不是单纯的语气声 |
| awaySummary_01.m4a | 高 | 在吗? | 34.8 dB | 531 Hz | https://www.bilibili.com/video/BV16Chd6uEJA | 在吗 | -噜噜宝贝- | 0.08–0.82s | 伴奏比人声低 34.8 dB、强浊音（f0≈531 Hz），转写本身就是目标音 |
| awaySummary_02.m4a | 中 | 在吗? | 26.0 dB | 408 Hz | https://www.bilibili.com/video/BV16Chd6uEJA | 在吗 | -噜噜宝贝- | 3.68–4.45s | 转写吻合，但伴奏余量只有 26.0 dB（<30，接近门槛） |
| awaySummary_03.m4a | 中 | 刚刚一直在想你哦。 | 41.1 dB | 291 Hz | https://www.bilibili.com/video/BV1duh969EHq | 谁懂啊！闹脾气的水豚，听到喜欢人的语音瞬间变软 | 愿景泰 | 19.76–21.13s | 人声干净，但这是一句带关键词的短句，不是单纯的语气声 |

## 数量

| 事件 | 数量 | 高 / 中 / 低 |
|---|---|---|
| arrive（登场） | 4 | 4 / 0 / 0 |
| poke（戳一戳） | 4 | 2 / 1 / 1 |
| hug（抱抱） | 2 | 0 / 2 / 0 |
| kiss（亲亲） | 2 | 0 / 2 / 0 |
| nuzzle（蹭蹭） | 3 | 0 / 2 / 1 |
| angry（生气） | 4 | 0 / 4 / 0 |
| cry（哭哭） | 2 | 0 / 0 / 2 |
| happy（开心） | 4 | 1 / 2 / 1 |
| doze（打盹） | 4 | 0 / 2 / 2 |
| awaySummary（“你不在的时候”） | 3 | 1 / 2 / 0 |

## 被拒的候选（节选）

过了第一轮筛选但最终验证没过的：

- poke · BV1Hjer6GEaD 6.78–7.89s：转写“噢!”，伴奏低于人声 32.8 dB → transcript lacks expected cue
- poke · BV1Fsj36yEkT 8.97–9.45s：转写“哎呦!”，伴奏低于人声 22.6 dB → acc<25dB
- nuzzle · BV16Hgf6bENp 2.59–4.65s：转写“好养好养,别闹啦!”，伴奏低于人声 26.4 dB → transcript lacks expected cue
- angry · BV1YMaA6jEqU 0.06–0.38s：转写“哼!”，伴奏低于人声 23.0 dB → acc<25dB
- angry · BV1Fsj36yEkT 9.57–9.87s：转写“哼。”，伴奏低于人声 21.4 dB → acc<25dB
- angry · BV1Hjer6GEaD 4.94–6.81s：转写“呃呃呃呃呃呃呃呃呃呃呃呃呃呃呃呃呃呃呃呃”，伴奏低于人声 39.3 dB → transcript lacks expected cue
- cry · BV1aZLf6aEoV 5.70–6.76s：转写“呜呜呜呜呜。”，伴奏低于人声 23.5 dB → acc<25dB
- happy · BV1w6hy6kEB2 13.04–13.74s：转写“嘻嘻嘻。”，伴奏低于人声 21.9 dB → acc<25dB
- happy · BV16Hgf6bENp 5.45–7.74s：转写“哈哈哈哈,我投降,我投降。”，伴奏低于人声 24.3 dB → acc<25dB
- doze · BV1uTEx6uEQJ 4.80–6.21s：转写“噗!”，伴奏低于人声 24.7 dB → acc<25dB
- awaySummary · BV16Chd6uEJA 1.10–1.97s：转写“在吗?”，伴奏低于人声 20.4 dB → acc<25dB
- kiss · BV14LJn6HEzT 2.62–4.72s：转写“不清就不清嘛。”，伴奏低于人声 29.5 dB → transcript lacks expected cue
