#!/usr/bin/env python3
"""`Scripts/test/dmg_layout_smoke.sh` 的变异测试 —— 证明那 8 条判据**有牙**。

用法（**手动跑，不进门槛**，与 `Scripts/test/deployment_target_mutation.py` 同款）：

    source Tools/clt_swift_env.sh
    python3 Scripts/test/dmg_layout_mutation.py

退出码：0 = 全部变异都符合预期；1 = 有不符合预期的条目（或基线不绿 / 装置坏了）。

--------------------------------------------------------------------------
为什么这个守卫特别需要变异测试
--------------------------------------------------------------------------
它守的是「**同一个事实写在四处**」（两个源常量 + 两个生成物）—— 这类守卫有个
共同的坏法：**判据写得太松，于是永远为真**。本轮实测抓到两处，都是写的时候
「看起来显然对」的：

  · ⑥ 最初写成「`build_app.sh` 里出现过 `$DMG_DSSTORE_TEMPLATE` 这个变量名」——
    而 `create_dmg` 里本来就有一句 `[ -f "$DMG_DSSTORE_TEMPLATE" ]`（存在性检查），
    **把 `cp` 那一行整行删掉，变量名照样在** ⇒ 判据恒真。⇒ M4/M5 就是钉这条的。
  · ② 只比背景图的**像素尺寸** ⇒ 「改了文案却忘了重跑脚本」**查不出来**。
    这不是假设：本轮就真的发生过（仓库里的 PNG 与旧文案的源逐字节相同，而源已改）。
    ⇒ ⑧（生成物自带的出处块）就是为此加的，M9 是它的**回归条目**。
  · ⑦ 里「卷里没这个文件」有两个**完全不同**的成因（卷没挂上 / 资产没进卷），
    两者在回显上**逐字相同** ⇒ 必须先断言「Applications 替身在不在」当装置自证，
    否则一次挂载失败会被报成「打包链路把点文件丢了」（**方向完全错的诊断**）。

--------------------------------------------------------------------------
按本仓 `swift-mutation-testing-practices` 的硬规则写（每条都对应一次真实故障）
--------------------------------------------------------------------------

1. **备份按文件去重、名字必须唯一** —— 用**相对路径**拼名（`Resources__dmg__DS_Store.bak`），
   不用 `p.name`（同名文件会撞成同一个备份）。
2. **备份后立刻 `cmp -s` 自证「备份 == 当前内容」**；过期备份**重新采一份并打印**
   （**覆盖写，不 `unlink`** —— 见第 11 条），不静默沿用。
3. **每次变异之前先 `restore_all()`** —— 不许把变异 B 叠在 A 的改动上跑。
4. **落地后立即 `cmp`**：与备份逐字节相同 ⇒ 变异没生效，结论作废（不是「守卫没牙」）。
5. **`classify()` 先排掉 invalid**（装置没挂上 / 装置死 / 找不到解释器）——
   它们的退出码也是非 0，与「被守卫抓住」在退出码上**逐字相同**。
6. **还原用独立步骤 + `cmp` 校验**，绝不挂在会失败的命令后面。
7. 本脚本能改**二进制**（`Resources/dmg/DS_Store`、`background.png` 都是二进制）——
   编辑元组里 `old`/`new` 给 `bytes` 即走二进制路径。
8. **有的变异带「后续动作」**（M9 要重跑生成脚本）—— 动作会改到**没被编辑过**的文件
   （背景图），所以动作前也要 `ensure_backup` + 登记进 `modified`，否则还原漏掉它。
9. **还原不能只挂在正常路径的末尾**：注册 `atexit` + 捕 `SIGINT/SIGTERM`。
   2026-09-24 实测：脚本被中断 ⇒ 工作区留着带变异的源 ⇒ **下一次「基线」直接红**，
   而那个红会被读成「守卫坏了」。真相是「上一次没还原」。
   （同一次实测里，`atexit` 当场救了一次：抛异常时 `build_app.sh` 还带着变异。）
10. **读子进程输出不许用 `text=True`**：那是**在读取时**就 `decode`，
    子进程只要吐一个非 UTF-8 字节就抛 `UnicodeDecodeError` ⇒ 整个变异跑崩。
    2026-09-24 实测踩到（守卫的 stderr 里有 600+ 字节非 UTF-8）。
    ⇒ 拿 bytes，再用 `_decode()` 降级 + 打印现场字节。
11. ⚠️ **脚本里不许出现任何删除**（`unlink` / `rm` / `rmtree`）：本环境有**批量删除
    守卫**，按「本轮累计删除数」计数；累计超阈值后，连删一个文件都会被拦下
    **并直接结束调用进程** ⇒ 本脚本**跑到一半静默消失**（2026-09-24 实测两次：
    日志停在半句话上、退出码 1、**没有 traceback**，看着像「变异不符合预期」）。
    ⇒ 备份过期就**覆盖写**（`shutil.copy` 本身就是覆盖语义）；临时目录用 `mktemp -d`
    且**不去删**。**要删东西时先问：能不能改成覆盖或换名？**
"""

import atexit
import pathlib
import shutil
import signal
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
BAK = ROOT / ".build/mutation/dmg-layout"
SMOKE = ROOT / "Scripts/test/dmg_layout_smoke.sh"

BACKUPS: dict[pathlib.Path, pathlib.Path] = {}
modified: list[pathlib.Path] = []


def ensure_backup(p: pathlib.Path) -> pathlib.Path:
    """备份名 = 相对路径的 `__` 拼接 —— **不能用 `p.name`**（同名文件会撞）。

    ⚠️ **过期备份直接覆盖，绝不用 `unlink()`**。2026-09-24 实测两次：本环境有
    **批量删除守卫**（按「本轮累计删除数」计数），累计超阈值后连一次 `unlink` 都会被
    拦下**并直接结束调用进程** ⇒ 本脚本**跑到一半静默消失**（日志停在半句话上、
    退出码 1、**没有 traceback**），看着像「变异不符合预期」或「装置坏了」。
    ⇒ `shutil.copy` 本身就是覆盖语义，**根本不需要先删**。
    """
    bp = BAK / ("__".join(p.relative_to(ROOT).parts) + ".bak")
    BAK.mkdir(parents=True, exist_ok=True)
    if bp.exists() and subprocess.run(["cmp", "-s", str(p), str(bp)]).returncode != 0:
        print(f"   ⓘ 备份 {bp.name} 已过期（与当前内容不同）—— 重新采一份（覆盖写，不删）")
    shutil.copy(p, bp)
    BACKUPS[p] = bp
    ok = subprocess.run(["cmp", "-s", str(p), str(bp)]).returncode == 0
    print(f"   备份 {p.relative_to(ROOT)} → {bp.name}（与当前内容一致 = {ok}）")
    if not ok:
        raise SystemExit(f"❌ 备份内容与当前文件不一致：{bp} —— 结论作废")
    return bp


def restore_all() -> None:
    for src in list(modified):
        shutil.copy(BACKUPS[src], src)
        ok = subprocess.run(["cmp", "-s", str(src), str(BACKUPS[src])]).returncode == 0
        print(f"     还原 {src.relative_to(ROOT)}: {'OK' if ok else '**失败**'}")
    modified.clear()


def _restore_on_exit() -> None:
    """⚠️ **无论怎么退出都要还原**（正常结束 / 抛异常 / Ctrl-C）。

    2026-09-24 实测踩到：脚本跑到一半被中断 ⇒ `restore_all()` 从没执行 ⇒
    工作区留着**带变异**的源文件。症状极隐蔽：**下一次跑的「基线」直接红**，
    而基线红会被读成「守卫坏了」，其实真相是「上一次没还原」。
    ⇒ 还原是**必须发生**的事，不能只挂在正常路径的末尾。
    """
    if modified:
        print("   ⚠️ 退出路径上还有未还原的改动 —— 正在还原：")
    restore_all()


atexit.register(_restore_on_exit)


def _on_signal(signum, _frame) -> None:
    print(f"   ⚠️ 收到信号 {signum} —— 先还原再退出")
    restore_all()
    raise SystemExit(1)


for _sig in (signal.SIGINT, signal.SIGTERM):
    signal.signal(_sig, _on_signal)


def _decode(raw: bytes, what: str) -> str:
    """把子进程输出解成字符串。**不许因为编码问题让整个变异跑崩**。

    ⚠️ 2026-09-24 实测踩到：守卫的 stderr 里出现了 600+ 字节**非 UTF-8** 内容
    （`0xef` 作首字节，像某种本地化消息的 GBK 编码），而 `subprocess.run(text=True)`
    是在**读取时**就 `decode` ⇒ 直接抛 `UnicodeDecodeError`，整个变异跑到一半崩掉，
    回显看着像「装置坏了」而不是「有个子进程说了句非 UTF-8 的话」。
    ⇒ 改成 `capture_output=True`（拿 bytes）+ 这里降级解码，并把**现场字节**打出来。
    """
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        ctx = raw[max(0, exc.start - 40) : exc.start + 24]
        print(f"   ⚠️ 子进程 {what} 里有非 UTF-8 字节（{exc}）—— 现场：{ctx!r}")
        return raw.decode("utf-8", errors="replace")


def run_guard() -> tuple[int, str]:
    r = subprocess.run([str(SMOKE)], cwd=ROOT, capture_output=True)
    return r.returncode, _decode(r.stdout, "stdout") + _decode(r.stderr, "stderr")


# ⚠️ 这些字样说明**装置自己没跑起来**，不是「守卫抓住了变异」。
#    它们的退出码同样非 0 ⇒ 不排掉就会把「装置坏了」记成「守卫有牙」。
INVALID_MARKERS = (
    "装置没跑起来",
    "装置没挂上",
    "判装置死",
    "找不到**能跑的** python3",
    "先修本门",
)


def classify(code: int, raw: str) -> str:
    for m in INVALID_MARKERS:
        if m in raw:
            return f"invalid(装置问题：{m})"
    return "green" if code == 0 else "red"


def failing_lines(raw: str) -> list[str]:
    return [ln.strip() for ln in raw.splitlines() if ln.strip().startswith("✗")]


def apply_edits(edits) -> bool:
    """返回「是否全部落地」。str 走文本、bytes 走二进制。"""
    for path, old, new in edits:
        ensure_backup(path)
        if isinstance(old, bytes):
            before = path.read_bytes()
            kind = "二进制"
        else:
            before = path.read_text(encoding="utf-8")
            kind = "文本"
        n = before.count(old)
        if n != 1:
            print(f"   ❌ {path.relative_to(ROOT)}: 锚点出现 {n} 次（要恰好 1 次）—— 没落地，作废")
            return False
        after = before.replace(old, new)
        if isinstance(old, bytes):
            path.write_bytes(after)
        else:
            path.write_text(after, encoding="utf-8")
        modified.append(path)
        landed = subprocess.run(["cmp", "-s", str(path), str(BACKUPS[path])]).returncode != 0
        print(f"   落地自证 {path.relative_to(ROOT)}（{kind}）: 与备份不同 = {landed}")
        if not landed:
            print(f"   ❌ {path.relative_to(ROOT)} 改完与备份逐字节相同 —— 变异没生效，作废")
            return False
    return True


def apply_action(cmds: list, touched: list) -> bool:
    """跑「后续动作」（如重跑生成脚本）。⚠️ 动作会改到**没被编辑过**的文件 ⇒ 也要备份。

    ⚠️ `cmds` 必须是**命令的列表**（`[[解释器, 脚本], …]`），不是一条扁平 argv。
    2026-09-24 实测踩到：传成扁平 argv 时，下面的循环会**逐字符**迭代那个字符串 ——
    先跑 `python`（无参数、退出码 0，看着像成功），再把 `.py` 当**可执行文件**跑，
    于是走它的 shebang `#!/usr/bin/env python3` ⇒ 撞上一个**没有 Pillow** 的解释器。
    报错落在「动作失败」，而真因（传参形状错了）**完全看不出来**。
    """
    for p in touched:
        ensure_backup(p)
    for cmd in cmds:
        if isinstance(cmd, (str, bytes)):
            print(f"   ❌ 动作传成了字符串 {cmd!r} —— 必须是 argv 列表，否则会被逐字符迭代")
            return False
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True)
        print(f"   动作 {' '.join(str(c) for c in cmd)} ⇒ 退出码 {r.returncode}")
        if r.returncode != 0:
            print("   ❌ 动作没跑起来 —— 结论作废")
            print((_decode(r.stdout, "stdout") + _decode(r.stderr, "stderr"))[-800:])
            return False
    for p in touched:
        modified.append(p)
    return True


BG_PY = ROOT / "Tools/make_dmg_background.py"
LAYOUT_SH = ROOT / "Tools/make_dmg_layout.sh"
DS_STORE = ROOT / "Resources/dmg/DS_Store"
PNG = ROOT / "Resources/dmg/background.png"
BUILD = ROOT / "build_app.sh"

HINT_OLD = 'HINT = "把 SafeOut 拖进右侧的 Applications 文件夹即可安装"'
HINT_NEW = 'HINT = "把 SafeOut 拖进右侧的 Applications 文件夹即可安装。"'

# (名字, [(文件, old, new), ...], 期望判定, 后续动作)
# 后续动作 = None 或 (命令的列表, 会被动作改动的文件列表)
# ⚠️ 「命令的列表」是**列表的列表**（`[[解释器, 脚本]]`），不是一条扁平 argv —— 见 apply_action。
MUTATIONS = [
    (
        "M1 【①常量漂】布局脚本的图标 y 改成 190（背景图脚本不动）",
        [(LAYOUT_SH, "ICON_Y=185", "ICON_Y=190")],
        "red",
        None,
    ),
    (
        "M2 【①②】背景图脚本的宽度改成 680（布局脚本不动）",
        [(BG_PY, "WIDTH = 660", "WIDTH = 680")],
        "red",
        None,
    ),
    (
        "M3 【③④生成物过期】源文件全对，只把 .DS_Store 里的 app 坐标挪 2pt",
        [(DS_STORE, struct.pack(">II", 170, 185), struct.pack(">II", 172, 185))],
        "red",
        None,
    ),
    (
        "M4 【⑥只检查没拷】删掉 cp .DS_Store 那一行（保留 [ -f ] 存在性检查）",
        [(BUILD, '    cp "$DMG_DSSTORE_TEMPLATE" "$staging/.DS_Store"\n', "")],
        "red",
        None,
    ),
    (
        "M5 【⑥口径自证】把 cp 背景图改成 echo（变量名还在，但不是拷贝）",
        [(BUILD, '    cp "$DMG_BACKGROUND" "$staging/.background/background.png"', '    echo "$DMG_BACKGROUND"')],
        "red",
        None,
    ),
    (
        "M6 【⑦牙口】让 ⑦ 的 staging 不拷 .DS_Store ⇒ 卷里没有，必须抓住",
        [(SMOKE, '    cp -f "$ds" "$with_st/.DS_Store"', '    cp -f "$ds" "$with_st/DS_Store.bak"')],
        "red",
        None,
    ),
    (
        "M7 【③标题栏】布局脚本的 TITLEBAR_H 改成 30（窗口外框高对不上）",
        [(LAYOUT_SH, "TITLEBAR_H=28", "TITLEBAR_H=30")],
        "red",
        None,
    ),
    (
        "M8 【⑧回归·真 bug】改文案但**不重跑**生成脚本 ⇒ 生成物必须自证过期",
        [(BG_PY, HINT_OLD, HINT_NEW)],
        "red",
        None,
    ),
    (
        "M9 【⑧反面对照】改文案**并重跑**生成脚本 ⇒ 必须仍绿（不许凡改文案必红）",
        [(BG_PY, HINT_OLD, HINT_NEW)],
        "green",
        ([[sys.executable, "Tools/make_dmg_background.py"]], [PNG]),    ),
    (
        "M10 阴性对照：只改配色常量（既不在出处块、也不影响尺寸坐标）必须仍绿",
        [(BG_PY, "ARROW_INK = (176, 176, 184)", "ARROW_INK = (150, 150, 158)")],
        "green",
        None,
    ),
]


def main() -> int:
    print("=" * 72)
    print("基线自证：什么都不改必须绿（基线红的话，后面的红说明不了任何事）")
    print("=" * 72)
    code, raw = run_guard()
    verdict = classify(code, raw)
    print(f"   基线判定：{verdict}（退出码 {code}）")
    if verdict != "green":
        print(raw[-3000:])
        print("❌ 基线不是绿的 —— 本次结论作废")
        return 1

    results = []
    for name, edits, expect, action in MUTATIONS:
        print()
        print("=" * 72)
        print(f"{name}    [期望 {expect}]")
        print("=" * 72)
        restore_all()

        if not apply_edits(edits):
            results.append((name, expect, "invalid(没落地)"))
            continue
        if action and not apply_action(action[0], action[1]):
            results.append((name, expect, "invalid(动作没跑起来)"))
            continue

        code, raw = run_guard()
        verdict = classify(code, raw)
        print(f"   判定：{verdict}（退出码 {code}）")
        print("   ── 原始输出尾部 ──")
        for line in raw.strip().splitlines()[-8:]:
            print(f"      {line}")
        reds = failing_lines(raw)
        if reds:
            print(f"   报出的判据（{len(reds)} 条）：")
            for t in reds[:6]:
                print(f"      · {t}")
        results.append((name, expect, verdict))

    print()
    print("=" * 72)
    print("还原与校验")
    print("=" * 72)
    restore_all()

    dupes = len(BACKUPS) - len({str(v) for v in BACKUPS.values()})
    print(f"   备份名唯一（重复数应为 0）：{dupes}")
    bad = [
        str(p)
        for p, bp in BACKUPS.items()
        if subprocess.run(["cmp", "-s", str(p), str(bp)]).returncode != 0
    ]
    print(f"   全部备份与工作区一致：{not bad}" + (f"  不一致：{bad}" if bad else ""))

    print()
    print("=" * 72)
    print("汇总")
    print("=" * 72)
    ok = dupes == 0 and not bad
    for name, expect, verdict in results:
        good = verdict == expect
        ok = ok and good
        print(f"   {'OK ' if good else 'NG '} [{expect} → {verdict}] {name}")
    print()
    print("全部符合预期" if ok else "有不符合预期的条目 —— 见上")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
