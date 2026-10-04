#!/usr/bin/env python3
"""v0.15.0: cut the 53 picked stickers (review package 2026-10-04-stickers) out of the raw library into
assets/gifs/sticker_<id>.gif (crop + frame range, source timing, capped at 360 px wide),
add them to assets/stickers.json (with `group`, and `intimate` where picked), give each a reactions.json entry
copied from the existing pool it is mapped to, and add the SOURCES.txt lines. Idempotent.

usage: LULU_LIBRARY=/path/to/assets/library nice -n 19 python3 tools/make_sticker_sources.py
The raw library is local only (gitignored); the generated assets/gifs/sticker_*.gif are what gets committed."""
import json, os
from PIL import Image

LIB = os.environ.get('LULU_LIBRARY', 'assets/library')
MAXW = 360

# Panel groups (emotion): the original 24 stickers by group. The id is stored in stickers.json `group`.
GROUPS = {
    'love': ['missyou', 'hug', 'kiss', 'nuzzle', 'holdhands', 'sleeptogether', 'flower', 'heart', 'shy', 'goodgirl', 'wink', 'run'],
    'happy': ['happy', 'dance', 'celebrate', 'bleh'],
    'sad': ['angry', 'cry'],
    'wow': ['whatsup'],
    'daily': ['night', 'morning', 'eat', 'milktea'],
    'reply': ['hi'],
    'season': [],
}

# id, review no., group, label, source gif, crop (x0,y0,x1,y1), frames (first,last), reaction, intimate
N = [
 ('mwah', 'S01', 'love', '么么哒', 'lulu_kiss_01', (126, 32, 586, 400), (0, 39), 'kiss', True),
 ('mwah2', 'S02', 'love', '么么哒', 'lumei_kiss_01', (0, 32, 400, 400), (0, 25), 'kiss', True),
 ('sajiao', 'S03', 'love', '撒娇', 'tenor_135', (0, 0, 240, 240), (0, 14), 'shy', False),
 ('sajiao2', 'S04', 'love', '撒娇', 'lumei_shy_03', (0, 51, 272, 364), (0, 29), 'shy', False),
 ('baituo', 'S05', 'love', '拜托啦', 'tenor_142', (0, 0, 240, 240), (0, 17), 'goodgirl', False),
 ('xindong', 'S06', 'love', '心动', 'tenor_204', (0, 0, 240, 240), (0, 30), 'heart', False),
 ('aini', 'S07', 'love', '爱你', 'baidu_057', (0, 0, 240, 240), (0, 23), 'heart', False),
 ('xingfu', 'S08', 'love', '好幸福', 'baidu_142', (0, 0, 400, 400), (0, 28), 'heart', False),
 ('anwei', 'S10', 'love', '安慰', 'couple_comfort_01', (191, 0, 1379, 950), (0, 22), 'cry', True),
 ('haha', 'S11', 'happy', '哈哈哈', 'sohu_042', (0, 0, 400, 400), (0, 19), 'happy', False),
 ('haha2', 'S12', 'happy', '哈哈哈', 'lumei_talk_01', (0, 34, 314, 395), (0, 25), 'happy', False),
 ('xiaosi', 'S13', 'happy', '笑死', 'couple_laugh_01', (78, 0, 578, 400), (0, 23), 'happy', False),
 ('heihei', 'S14', 'happy', '嘿嘿', 'tenor_217', (0, 0, 240, 240), (0, 16), 'happy', False),
 ('heihei2', 'S15', 'happy', '嘿嘿', 'lumei_giggle_01', (0, 34, 314, 395), (0, 35), 'happy', False),
 ('biye', 'S16', 'happy', '比耶', 'lulu_ok_01', (0, 32, 400, 400), (0, 27), 'celebrate', False),
 ('ye', 'S17', 'happy', '耶', 'tenor_206', (0, 0, 240, 240), (0, 20), 'celebrate', False),
 ('deyi', 'S18', 'happy', '得意', 'tenor_162', (0, 0, 300, 300), (0, 12), 'bleh', False),
 ('jiayou', 'S19', 'happy', '加油', 'lumei_clap_01', (0, 54, 266, 360), (0, 37), 'celebrate', False),
 ('chongya', 'S20', 'happy', '冲鸭', 'tenor_184', (0, 0, 240, 240), (0, 12), 'run', False),
 ('weiqu', 'S21', 'sad', '委屈', 'tenor_159', (0, 0, 300, 300), (0, 15), 'cry', False),
 ('heng', 'S22', 'sad', '哼', 'tenor_198', (0, 0, 240, 240), (0, 25), 'angry', False),
 ('heng2', 'S23', 'sad', '哼', 'lumei_stomp_01', (0, 289, 1080, 1531), (0, 47), 'angry', False),
 ('lengzhan', 'S24', 'sad', '冷战', 'couple_coldwar_01', (147, 0, 1553, 740), (0, 16), 'angry', False),
 ('xinsui', 'S25', 'sad', '心碎', 'baidu_061', (0, 0, 640, 640), (0, 25), 'cry', False),
 ('xiongni', 'S26', 'sad', '凶你哦', 'couple_shout_01', (244, 0, 1485, 730), (0, 30), 'angry', False),
 ('wuyu', 'S27', 'wow', '无语', 'tenor_115', (0, 0, 240, 240), (0, 41), 'bleh', False),
 ('wow', 'S29', 'wow', '哇', 'tenor_223', (0, 0, 240, 240), (0, 13), 'happy', False),
 ('xiasi', 'S30', 'wow', '吓死', 'tenor_110', (0, 0, 240, 240), (0, 19), 'cry', False),
 ('ah', 'S31', 'wow', '啊？', 'tenor_227', (0, 0, 240, 240), (0, 9), 'whatsup', False),
 ('chigua', 'S32', 'wow', '吃瓜', 'tenor_230', (0, 0, 240, 240), (0, 49), 'default', False),
 ('kunle', 'S33', 'daily', '困了', 'tenor_117', (0, 0, 240, 240), (0, 25), 'night', False),
 ('kunkun', 'S35', 'daily', '困困', 'couple_sleepy_01', (25, 0, 525, 400), (0, 29), 'night', False),
 ('wanan', 'S36', 'daily', '晚安', 'tenor_215', (0, 0, 320, 320), (0, 41), 'night', False),
 ('ganfan', 'S38', 'daily', '干饭', 'lumei_eat_02', (0, 32, 436, 400), (0, 40), 'eat', False),
 ('e', 'S39', 'daily', '饿了', 'tenor_172', (0, 0, 240, 240), (0, 35), 'eat', False),
 ('shangban', 'S40', 'daily', '上班中', 'tenor_124', (0, 0, 240, 240), (0, 18), 'whatsup', False),
 ('xiaban', 'S41', 'daily', '下班啦', 'tenor_175', (0, 0, 240, 240), (0, 38), 'run', False),
 ('daojia', 'S42', 'daily', '到家啦', 'tenor_182', (0, 0, 240, 240), (0, 16), 'hi', False),
 ('leitan', 'S43', 'daily', '累瘫', 'tenor_214', (0, 0, 240, 240), (0, 15), 'cry', False),
 ('aqi', 'S44', 'daily', '阿嚏', 'tenor_221', (0, 0, 240, 240), (0, 37), 'cry', False),
 ('haode', 'S46', 'reply', '好的', 'tenor_091', (0, 0, 240, 240), (0, 17), 'happy', False),
 ('shoudao', 'S47', 'reply', '收到', 'tenor_103', (0, 0, 240, 240), (0, 18), 'goodgirl', False),
 ('duibuqi', 'S49', 'reply', '对不起', 'tenor_090', (0, 0, 240, 240), (0, 24), 'missyou', False),
 ('buma', 'S50', 'reply', '不嘛', 'tenor_118', (0, 0, 240, 240), (0, 19), 'shy', False),
 ('xiexie', 'S51', 'reply', '谢谢', 'baidu_102', (0, 0, 300, 301), (0, 17), 'flower', False),
 ('dengni', 'S52', 'reply', '等你', 'tenor_112', (0, 0, 240, 240), (0, 26), 'missyou', False),
 ('baibai', 'S54', 'reply', '拜拜', 'lumei_more_08', (0, 0, 240, 240), (0, 38), 'hi', False),
 ('huilai', 'S55', 'reply', '我回来啦', 'couple_greet_01', (89, 0, 589, 400), (0, 22), 'run', False),
 ('wowowo', 'S56', 'reply', '我我我', 'tenor_174', (0, 0, 240, 240), (0, 16), 'whatsup', False),
 ('xiayu', 'S57', 'season', '下雨了', 'sohu_005', (0, 0, 400, 400), (0, 29), 'default', False),
 ('haore', 'S58', 'season', '好热', 'tenor_233', (0, 0, 240, 240), (0, 29), 'milktea', False),
 ('facai', 'S59', 'season', '发财', 'vid_16', (0, 32, 391, 400), (0, 28), 'celebrate', False),
 ('shengdan', 'S60', 'season', '圣诞快乐', 'tenor_180', (0, 0, 240, 240), (0, 12), 'celebrate', False),
]


def find(name):
    for d in ('assets/gifs', LIB):
        p = f'{d}/{name}.gif'
        if os.path.exists(p):
            return p, os.path.basename(d)
    raise SystemExit(f'missing source {name}.gif (set LULU_LIBRARY)')


def cut(sid, name, crop, frames):
    p, _ = find(name)
    im = Image.open(p)
    out, durs = [], []
    for i in range(frames[0], frames[1] + 1):
        im.seek(i)
        f = im.convert('RGB').crop(crop)
        if f.width > MAXW:
            f = f.resize((MAXW, round(f.height * MAXW / f.width)), Image.LANCZOS)
        out.append(f)
        durs.append(im.info.get('duration', 100) or 100)
    dst = f'assets/gifs/sticker_{sid}.gif'
    out[0].save(dst, save_all=True, append_images=out[1:], duration=durs, loop=0, optimize=True)
    return dst


def main():
    stickers = json.load(open('assets/stickers.json'))
    have = {s['id']: s for s in stickers}
    for g, ids in GROUPS.items():
        for i in ids:
            have[i]['group'] = g
    reactions = json.load(open('assets/reactions.json'))
    sources = open('assets/gifs/SOURCES.txt').read()
    add_src = []
    for sid, no, grp, label, name, crop, frames, react, intimate in N:
        dst = cut(sid, name, crop, frames)
        e = {'id': sid, 'label': label, 'gif': f'sticker_{sid}', 'group': grp}
        if intimate:
            e['intimate'] = True
        if sid in have:
            have[sid].update(e)
        else:
            stickers.append(e)
            have[sid] = e
        if react != 'default' and sid not in reactions:
            reactions[sid] = json.loads(json.dumps(reactions[react]))
        line = (f'sticker_{sid}.gif  cut from {name}.gif ({find(name)[1]}) crop x {crop[0]}-{crop[2]} y {crop[1]}-{crop[3]} '
                f'frames {frames[0]}-{frames[1]}, <=360 px wide (v0.15.0 user pick {no}, tools/make_sticker_sources.py)')
        if f'sticker_{sid}.gif ' not in sources:
            add_src.append(line)
        print(no, sid, label, os.path.getsize(dst) // 1024, 'KB')
    with open('assets/stickers.json', 'w') as f:
        f.write('[\n' + ',\n'.join('  ' + json.dumps(s, ensure_ascii=False) for s in stickers) + '\n]\n')
    with open('assets/reactions.json', 'w') as f:
        json.dump(reactions, f, ensure_ascii=False, indent=1)
        f.write('\n')
    if add_src:
        with open('assets/gifs/SOURCES.txt', 'a') as f:
            f.write(('' if sources.endswith('\n') else '\n') + '\n'.join(add_src) + '\n')


main()
