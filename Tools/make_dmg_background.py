#!/usr/bin/env python3
"""生成 dmg 安装界面的背景图 `Resources/dmg/background.png`。

    python3 Tools/make_dmg_background.py

**为什么要一张背景图**：dmg 挂载后就是一个普通的 Finder 窗口 —— 没有背景图、没有
提示文字时，用户看到的是「两个图标 + 一片空白」，得自己猜「拖过去算安装」。
背景图把这件事**画出来**（一条从 app 指向 Applications 的箭头 + 一句提示），
这是 dmg 相对 zip 的主要优势，也是 macOS 上用户最熟悉的那套。

**尺寸与图标位置是成对的**（`660×420`，图标中心 y=185）：Finder 窗口尺寸与图标坐标
必须与这里一致，否则箭头会指歪。两处数字**同源**写在本文件的常量与
`Tools/make_dmg_layout.sh` 的常量里 —— **改一处必须改另一处**
（`Scripts/test/dmg_layout_smoke.sh` 会比对这两处，不一致就红）。

⚠️ `build_app.sh` **不参与**这些常量：它在打包期只是把 `Resources/dmg/` 下的
两个资产（本脚本出的背景图 + `make_dmg_layout.sh` 出的 `.DS_Store`）拷进 staging。

**为什么用 PIL 画而不是找设计稿**：这是安装器外壳、不属于应用 UI，设计稿里没有它。
配色取应用自己的令牌（`DesignTokens` 的 `--bg-glass` / `--text-3` 一档），
让安装界面与应用是同一套观感。

--------------------------------------------------------------------------
出处（provenance）：生成物自带「我是用哪些输入生成的」
--------------------------------------------------------------------------
本脚本把**全部绘制输入**（尺寸 / 图标坐标 / 两句文案 / 箭头几何 / 字体与字重 index）
写进 PNG 自己的 `iTXt` 块（键前缀 `de.`）。

**为什么需要它**（2026-09-24 实测踩到）：守卫原先只比对背景图的**像素尺寸**，
于是「改了文案却忘了重跑本脚本」**查不出来** —— 而那正是最隐蔽的一种漂：
源文件是对的、生成物是旧的，两边都不报错，用户看到的却是旧文案。
实测证据：当时仓库里那张 `background.png` 与「无句号」版本的源**逐字节相同**，
而源文件已经被改成了带句号的版本 ⇒ **守卫全绿、图却是旧的**。
⇒ 现在生成物**自己记下输入**，守卫读回来与源逐项比对，改了文案不重跑就红。

⚠️ **新增绘制参数时，记得同时加进 `provenance()`** —— 没记进去的输入，
漂了照样查不出来（这是本机制**已知**的边界）。
"""

import hashlib
import os
import sys

# ⚠️ `Pillow` **不在标准库里**，而 `python3` 解析到哪个解释器取决于 PATH：
#    2026-09-24 实测 —— 本机 `#!/usr/bin/env python3`（本文件的 shebang）解析到的那个
#    解释器**没有 Pillow** ⇒ 直接跑 `./Tools/make_dmg_background.py` 会抛
#    `ModuleNotFoundError`，而那条报错里**看不出「换个解释器就行」**。
#    ⇒ 换成一句能照着做的提示（`build_app.sh` 缺资产时的报错文案也指向本脚本）。
try:
    from PIL import Image, ImageDraw, ImageFont
    from PIL.PngImagePlugin import PngInfo
except ModuleNotFoundError as exc:
    sys.exit(
        f"❌ 需要 Pillow（{exc}）。\n"
        f"   当前解释器：{sys.executable}\n"
        "   本机带 Pillow 的解释器：~/.workbuddy-ai/binaries/python/envs/default/bin/python\n"
        "   ⇒ 换它来跑：\n"
        "     ~/.workbuddy-ai/binaries/python/envs/default/bin/python Tools/make_dmg_background.py"
    )

# ---- 与 Tools/make_dmg_layout.sh 的常量同源（改这里必须改那里）----
WIDTH = 660
HEIGHT = 420
ICON_Y = 185  # 图标中心的 y（Finder 坐标从窗口左上角算，这里用「距顶部」）
APP_CX = 170  # 应用图标中心 x
APPS_CX = 490  # Applications 替身中心 x

# ---- 绘制几何（全部记进出处块；改任何一项都要重跑本脚本）----
TITLE_TOP = 52  # 标题文字距顶部
HINT_BOTTOM = 74  # 提示文字距底部
ARROW_GAP = 60  # 箭头两端各距对应图标中心多远
ARROW_DY = 6  # 箭头相对图标中心的竖直偏移
ARROW_HEAD = 16  # 箭头三角的长度
ARROW_HALF = 9  # 箭头三角的半高
ARROW_LINE_END = 14  # 线段停在三角底部**之内** 2pt ⇒ 接缝不会露白（不是笔误）

TITLE = "SafeOut"
HINT = "把 SafeOut 拖进右侧的 Applications 文件夹即可安装"

# ---- 配色（取自应用的明色令牌）----
BG_TOP = (247, 247, 249)
BG_BOTTOM = (238, 238, 242)
TITLE_INK = (28, 28, 32)
HINT_INK = (110, 110, 118)
ARROW_INK = (176, 176, 184)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO_ROOT, "Resources", "dmg", "background.png")

# 中文字体：**必须指定 `.ttc` 里的 index**（多字重集合，index 0=W3、index 2=W6）。
#
# ⚠️ **2026-09-24 实测踩到的坑**：第一版把 `/System/Library/Fonts/PingFang.ttc` 写在候选表
# 第一位，**这台机器上它根本不存在** ⇒ 静默退到 `Helvetica.ttc` ⇒ 中文全部渲染成方框，
# 而脚本**一个字都没说**（还打印了「已生成」）。⇒ 两处改：
#   ① 不再「候选里挑一个」，直接写死这一份；
#   ② 取不到**硬报错**（宁可不出图，也不要出一张用户看不懂的安装界面）。
# 本机实测可用的中文字体（`getname()` 自证）：Hiragino Sans GB W3/W6、Heiti SC、Songti SC。
FONT_PATH = "/System/Library/Fonts/Hiragino Sans GB.ttc"
FONT_INDEX_REGULAR = 0  # W3
FONT_INDEX_BOLD = 2  # W6


def load_font(size, index):
    if not os.path.exists(FONT_PATH):
        sys.exit(f"❌ 找不到中文字体 {FONT_PATH} —— 安装界面里的中文会变成方框，拒绝出图。")
    font = ImageFont.truetype(FONT_PATH, size, index=index)
    # **自证**：把真拿到的字体名打出来。`.ttc` 的 index 写错时会**静默**给另一个字重/语种
    # （实测 index 4 直接抛 `invalid argument`，而 0/2 是 W3/W6，两者肉眼几乎一样）。
    name = font.getname()
    if not any(k in name[0] for k in ("Hiragino", "Heiti", "Songti", "PingFang")):
        sys.exit(f"❌ {FONT_PATH}[{index}] 取到的是 {name} —— 不是中文字体，拒绝出图。")
    print(f"  字体 {name[0]} {name[1]}（index={index}）")
    return font


def provenance() -> dict:
    """**绘制输入的清单**（唯一真相）—— 既写进 PNG，也是「改了要重跑」的那份契约。

    ⚠️ 值可能是中文 ⇒ 必须用 `iTXt`（UTF-8）。`tEXt` 是 Latin-1，
    写中文要么炸要么乱码。
    ⚠️ 这份清单必须与 `main()` 真正用到的输入**一一对应**：漏记一项，
    那一项漂了守卫就看不见（见文件头的已知边界）。
    """
    return {
        "de.width": str(WIDTH),
        "de.height": str(HEIGHT),
        "de.icon_y": str(ICON_Y),
        "de.app_cx": str(APP_CX),
        "de.apps_cx": str(APPS_CX),
        "de.title": TITLE,
        "de.hint": HINT,
        "de.title_top": str(TITLE_TOP),
        "de.hint_bottom": str(HINT_BOTTOM),
        "de.arrow_gap": str(ARROW_GAP),
        "de.arrow_dy": str(ARROW_DY),
        "de.arrow_head": str(ARROW_HEAD),
        "de.arrow_half": str(ARROW_HALF),
        "de.arrow_line_end": str(ARROW_LINE_END),
        "de.font_path": FONT_PATH,
        "de.font_index_regular": str(FONT_INDEX_REGULAR),
        "de.font_index_bold": str(FONT_INDEX_BOLD),
    }


def build_provenance() -> PngInfo:
    meta = PngInfo()
    for key, value in provenance().items():
        meta.add_itxt(key, value)
    return meta


def main():
    img = Image.new("RGB", (WIDTH, HEIGHT), BG_TOP)
    draw = ImageDraw.Draw(img)

    # 自上而下的极轻渐变：纯平色在大屏上会显得像没画完
    for y in range(HEIGHT):
        t = y / (HEIGHT - 1)
        color = tuple(round(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3))
        draw.line([(0, y), (WIDTH, y)], fill=color)

    title_font = load_font(30, FONT_INDEX_BOLD)
    hint_font = load_font(16, FONT_INDEX_REGULAR)

    tw = draw.textlength(TITLE, font=title_font)
    draw.text(((WIDTH - tw) / 2, TITLE_TOP), TITLE, font=title_font, fill=TITLE_INK)

    # 箭头：从应用图标右侧指向 Applications 替身左侧（两端各留 ARROW_GAP 空隙）
    x0 = APP_CX + ARROW_GAP
    x1 = APPS_CX - ARROW_GAP
    y = ICON_Y + ARROW_DY
    draw.line([(x0, y), (x1 - ARROW_LINE_END, y)], fill=ARROW_INK, width=3)
    draw.polygon(
        [(x1, y), (x1 - ARROW_HEAD, y - ARROW_HALF), (x1 - ARROW_HEAD, y + ARROW_HALF)],
        fill=ARROW_INK,
    )

    hw = draw.textlength(HINT, font=hint_font)
    draw.text(((WIDTH - hw) / 2, HEIGHT - HINT_BOTTOM), HINT, font=hint_font, fill=HINT_INK)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.save(OUT, "PNG", pnginfo=build_provenance())
    with open(OUT, "rb") as fh:
        digest = hashlib.sha256(fh.read()).hexdigest()[:16]
    print(f"已生成 {os.path.relpath(OUT, REPO_ROOT)}（{os.path.getsize(OUT)} 字节，sha256[:16]={digest}）")
    print(f"  尺寸 {WIDTH}×{HEIGHT}，图标中心 y={ICON_Y}，app x={APP_CX}，Applications x={APPS_CX}")
    print(f"  出处块已写进 PNG（de.* 共 {len(provenance())} 项）")
    print("  ⚠️ 改常量/文案/字体必须重跑本脚本：守卫会拿 PNG 里的出处块与源逐项比对")


if __name__ == "__main__":
    main()
