#!/usr/bin/env python3
"""生成设计稿语言包 assets/i18n.js。

    python3 Tools/build_i18n.py

输入（都是手改的源）：
  1. Sources/Localization/Localizable.xcstrings —— 产品已有文案。
     设计稿的英文必须**逐字取自这里**：走查是把设计稿与真机并排看的，
     两边对不上就白设计了。
  2. Design/ui/v2/assets/i18n-extra.json —— 设计稿专有文案
     （实现侧还没有的界面、样本数据、设计稿自己的 chrome）。

输出（生成物，别手改）：
  Design/ui/v2/assets/i18n.js

为什么要有这个脚本：加一门语言 = 在 xcstrings 里补一列 + 在 extra 里补一个值。
没有脚本的话，i18n.js 里 150 条 × N 语言只能手抄，抄漏一条不会报错，
只会在切到那门语言时静默回退成中文 —— 而「回退」和「翻好了」长得一模一样。
"""
import hashlib
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
XCS = os.path.join(REPO, 'Sources/Localization/Localizable.xcstrings')
EXTRA = os.path.join(REPO, 'Design/ui/v2/assets/i18n-extra.json')
SELF = os.path.abspath(__file__)
OUT = os.path.join(REPO, 'Design/ui/v2/assets/i18n.js')

LANGS = [
    ('zh-Hans', 'zh-Hans', '简体中文'),
    ('en', 'en', 'English'),
    ('zh-Hant', 'zh-Hant', '繁體中文'),
]


def fingerprint():
    """源指纹 —— 三个输入（两个源文件 + 本脚本）的字节拼起来算一个 sha256。

    写进生成物头部，供 `DesignDraftIntegrityTests/生成物i18njs的源指纹必须与源一致` 比对
    （⚠️ 2026-09-20 订正：这里原先写的测试名 **`i18n.js 必须与源同步` 不存在** ——
    守卫一直在，只是**指针烂了**。下一轮照这个名去搜会一无所获，
    与「根本没有守卫」逐字相同 ⇒ 引用别的东西时，名字要照抄，不要凭印象写）：
    **任何一方变了，指纹就变** ⇒ 生成物过期会被测试拦下。

    ⚠️ 拼接顺序必须与测试里一致：XCS → EXTRA → 本脚本。
    """
    h = hashlib.sha256()
    for p in (XCS, EXTRA, SELF):
        h.update(open(p, 'rb').read())
    return h.hexdigest()


def md_bold(s):
    # xcstrings 英文里用 markdown `**...**` 加粗 —— 直接回填会显示成裸星号。
    # 转成 <b>...</b>，回填后由 ds.js 的 hydrate 当 HTML 渲染。
    # ⚠️ 只动成对的 `**X**`；孤立的星号（产品名 `SafeOut*` 之类的）保留。
    return re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', s)

def nl2br(s):
    # 值里的换行（`\n`）在 SwiftUI 里就是换行；但设计稿是 **innerHTML 回填**，
    # HTML 会把裸 `\n` 折叠成一个空格 ⇒ 那一段会悄悄变成一行（§8.69.5）。
    # ⚠️ 只改**生成物**：xcstrings / extra 里存的仍是 `\n`（App 侧照旧）。
    return s.replace('\n', '<br>')


def read_xcstrings():
    d = json.load(open(XCS, encoding='utf-8'))
    out = {}
    for k, v in d['strings'].items():
        loc = v.get('localizations') or {}
        row = {}
        for code, src, _ in LANGS:
            unit = (loc.get(src) or {}).get('stringUnit') or {}
            val = unit.get('value')
            if val:
                row[code] = nl2br(md_bold(val))
        if row:
            out[k] = row
    return out


def read_extra():
    d = json.load(open(EXTRA, encoding='utf-8'))
    out = {}
    for k, v in d.items():
        if k.startswith('_'):
            continue
        assert isinstance(v, list) and len(v) == len(LANGS), \
            '%s 的值必须是 [%s] 三个一组的数组' % (k, ', '.join(c for c, _, _ in LANGS))
        out[k] = {code: nl2br(val) for (code, _, _), val in zip(LANGS, v)}
    return out


def main():
    prod = read_xcstrings()
    extra = read_extra()
    overlap = sorted(set(prod) & set(extra))
    if overlap:
        sys.exit('键名冲突（既在 xcstrings 又在 extra）：%s' % ', '.join(overlap))

    pack = {code: {} for code, _, _ in LANGS}
    for k, row in prod.items():
        for code, _, _ in LANGS:
            if row.get(code):
                pack[code][k] = row[code]
            else:
                # 缺这门语言 → 用源语言兜底，并在下面报出来（不静默）
                pack[code][k] = row.get('zh-Hans', '')
    for k, row in extra.items():
        for code, _, _ in LANGS:
            pack[code][k] = row[code]

    # 体检 1：设计稿专有键里，有没有中文与产品已有键**一字不差**的？
    # 有了就是灾难：中文看不出区别，英文却是两套 —— 走查时设计稿显示 A、真机显示 B，
    # 而两边的人都会以为自己对。宁可让生成器报错，也不要留这种「同形异义」。
    by_zh = {}
    for k, row in prod.items():
        by_zh.setdefault(row.get('zh-Hans', ''), []).append(k)
    dup = []
    for k, row in extra.items():
        hit = by_zh.get(row['zh-Hans'], [])
        if hit:
            dup.append('  %-26s 中文与产品键 %s 完全相同 → 请删掉 extra 里的，直接用产品键'
                       % (k, '/'.join(hit)))
    if dup:
        print('\n❌ extra 里存在与产品文案重复的键（设计稿英文会与真机不一致）：')
        print('\n'.join(dup))
        sys.exit(1)

    # 体检 2：哪些键在某门语言里其实没翻（值与源语言相同）
    report = []
    for code, _, _ in LANGS:
        if code == 'zh-Hans':
            continue
        same = [k for k in pack[code]
                if pack[code][k] and pack[code][k] == pack['zh-Hans'].get(k)
                and re.search(r'[\u4e00-\u9fff]', pack[code][k])]
        if same:
            report.append('  %-8s 与中文相同的键 %d 条（疑似未翻）：%s'
                          % (code, len(same), ', '.join(same[:8]) + ('…' if len(same) > 8 else '')))

    body = [
        '/* ============================================================================',
        '   SafeOut UI v2 — 设计稿语言包（**生成物，不要手改**）',
        '   ----------------------------------------------------------------------------',
        '   生成：python3 Tools/build_i18n.py',
        '   来源：Sources/Localization/Localizable.xcstrings',
        '       + Design/ui/v2/assets/i18n-extra.json',
        '   ----------------------------------------------------------------------------',
        '   源指纹 %s' % fingerprint(),
        '     = sha256(xcstrings + extra + 本脚本) —— 任一方变了它就是旧的，',
        '       由 DesignDraftIntegrityTests 拦下「改了源忘了重跑」。',
        '   ----------------------------------------------------------------------------',
        '   · 无前缀的键 = 产品已有文案，逐字取自 xcstrings；',
        '   · ds. 前缀的键 = 设计稿专有（新增界面 / 样本数据 / 设计稿 chrome）。',
        '   · 值里允许 HTML（<b> / <code> / <br> / <i data-i="gear">），',
        '     回填后由 ds.js 重新水合图标（否则切语言后图标全丢）。',
        '   ========================================================================== */',
        '',
        '/* 支持的语言。新增语言：这里加一项 + xcstrings 补一列 + extra 补一个值。 */',
        'window.DS_LANGS = ' + json.dumps(
            [{'code': c, 'name': n} for c, _, n in LANGS], ensure_ascii=False, indent=2) + ';',
        '',
        'window.DS_L10N = {',
    ]
    for i, (code, _, _) in enumerate(LANGS):
        comma = ',' if i < len(LANGS) - 1 else ''
        body.append('  %s: %s%s' % (json.dumps(code),
                                    json.dumps(pack[code], ensure_ascii=False, indent=4,
                                               sort_keys=True).replace('\n', '\n  '),
                                    comma))
    body.append('};')
    body.append('')

    open(OUT, 'w', encoding='utf-8').write('\n'.join(body))

    print('已生成 %s' % os.path.relpath(OUT, REPO))
    print('  产品文案 %d 条 + 设计稿专有 %d 条 = %d 条/语言，%d 门语言'
          % (len(prod), len(extra), len(prod) + len(extra), len(LANGS)))
    for line in report:
        print(line)


if __name__ == '__main__':
    main()
