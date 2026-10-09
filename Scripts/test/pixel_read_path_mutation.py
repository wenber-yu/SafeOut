#!/usr/bin/env python3
"""``PixelReadPathTests`` 守卫的**变异测试**（手动跑，不进 CI）。

## 为什么需要

2026-09-23 把 ``Tests/`` 里 7 个文件各自手写的「逐像素读像素循环」与 3 份自建位图块
收敛进 ``OffscreenRender``，并加了 ``PixelReadPathTests`` 挡住回退。
那条守卫是**静态源码扫描器**，而静态扫描器的失效方式恰好是「输出看起来一样」：
「0 处」既可能是真的没有，也可能是**装置瞎了**。所以必须证明它有牙。

⚠️ 本轮要证明的**不只是**「能抓到」，还有两件更细的：

1. **口径是承重的**：读像素那一半必须用 `colorAt(x:` 而不是裸词 `colorAt` ——
   否则函数名（`透明底样本直读与colorAt逐像素相等`）与失败信息里的字符串都会进计数，
   守卫变成噪音（M5）。
2. **次数棘轮两个方向都有牙**：在**已允许**的文件里再抄一段也要红（M3，变多），
   收敛掉一处之后忘了改小也要红（M4，变少）。

## 用法

```bash
source Tools/clt_swift_env.sh        # 先让 swift 可用（Xcode 许可未接受时）
python3 Scripts/test/pixel_read_path_mutation.py
```

## 硬规则（沿用 ``wait_outcome_mutation.py`` / ``test_timings_mutation.py``）

- **备份用 `cp`，还原也用 `cp`**：不用 `git checkout`（它会连未提交的改动一起清掉）。
- **每次变异前先证明它落地了**（回读文件），否则「仍绿」可能只是没改上。
- **打印被测命令的原始尾部**，不只打印我的判红结论 —— 判据自己也会错。
- ⚠️ **判红之前先排除「变异体编译不过」与「过滤器一条都没跑到」**：
  这两种情况下退出码同样非 0，与「被守卫抓住」**逐字相同**。
  本脚本对这两种情况**判为结论作废**，不算通过。
- 还原之后 `cmp` 再确认一次；还原步骤**不挂在会失败的命令后面**（不用 `&&` 串）。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TESTS = REPO / "Tests/SafeOutAppTests"
EMPTY_STATE = TESTS / "EmptyStateTests.swift"
VISUAL_STYLE = TESTS / "VisualStyleTests.swift"
GUARD = TESTS / "PixelReadPathTests.swift"

FILTER = "PixelReadPathTests"

# 追加式变异体的锚点：文件里唯一的一行，变异体接在它后面。
ANCHOR = "@testable import SafeOutApp"

MUTANT_READ = """

// ZZ 变异体：手写一处逐像素读像素（模拟回退）
@MainActor
private func zzMutantRead(_ rep: NSBitmapImageRep) -> NSColor? { rep.colorAt(x: 0, y: 0) }
"""

MUTANT_BITMAP = """

// ZZ 变异体：自建一份位图（模拟回退）
@MainActor
private func zzMutantBitmap(_ size: CGSize) -> NSBitmapImageRep? {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
}
"""

# (编号, 说明, 文件, 旧片段（None = 追加到 ANCHOR 之后）, 新片段, 期望)
MUTATIONS = [
    (
        "M1",
        "在**清单外**的文件里手写一处读像素 ⇒ 必须报「清单外出现」",
        EMPTY_STATE,
        None,
        MUTANT_READ,
        "red",
    ),
    (
        "M2",
        "在**清单外**的文件里自建一份位图 ⇒ 必须报「清单外出现」（出图那一半的牙）",
        EMPTY_STATE,
        None,
        MUTANT_BITMAP,
        "red",
    ),
    (
        "M3",
        "在**已允许**的文件里再抄一处读像素（次数 1→2）⇒ 必须报「次数与登记不符」（棘轮往紧的方向）",
        VISUAL_STYLE,
        None,
        MUTANT_READ,
        "red",
    ),
    (
        "M4",
        "把 `OffscreenRenderParityTests` 的登记次数 8 改成 7（模拟「收敛掉一处却忘了改小」）"
        " ⇒ 必须报「次数与登记不符」",
        GUARD,
        '"Tests/SafeOutAppTests/OffscreenRenderParityTests.swift": (\n            8,',
        '"Tests/SafeOutAppTests/OffscreenRenderParityTests.swift": (\n            7,',
        "red",
    ),
    (
        "M5",
        "口径退化成**裸词** `colorAt` ⇒ 装置自证那条（函数名不许被数到）必须立刻红",
        GUARD,
        'private static let colorAtCall = "colorAt(x:"',
        'private static let colorAtCall = "colorAt"',
        "red",
    ),
    (
        "M6",
        "模式串改成匹配不到任何东西 ⇒ 「只数到 N 处」那条装置自证必须红（**装置死了**的控制组）",
        GUARD,
        'private static let colorAtCall = "colorAt(x:"',
        'private static let colorAtCall = "zzNoSuchCall(x:"',
        "red",
    ),
]


def run_guard() -> tuple[int, str]:
    """跑一次只含守卫的 `swift test`，返回 (退出码, 原始输出)。"""
    proc = subprocess.run(
        ["swift", "test", "--disable-sandbox", "--filter", FILTER],
        cwd=REPO,
        capture_output=True,
        text=True,
        errors="replace",
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


# 「测试真的跑过」的**正向证据**：swift-testing 无论成败都会打这一行。
TEST_RUN_RE = re.compile(r"Test run with (\d+) tests?")
# 构建成功的**正向证据**：SwiftPM 每次构建都会打这一行；**编不过就没有它**。
BUILD_OK_RE = re.compile(r"^\s*Build complete!", re.M)
# 编译诊断的**两种**形态（2026-09-28 补齐第二种，见 `deployment_target_mutation.py` 的 M1/M2）：
# swiftc 的 `<file>:<行>:<列>: error:`，与**构建期**无文件行号的 `error: Build failed`。
COMPILE_DIAG_RE = re.compile(r":\d+:\d+: error:|^\s*error: (?:Build failed|fatalError)", re.M)


def classify(code: int, raw: str) -> str:
    """把一次运行判成 `red` / `green` / `invalid`。

    ⚠️ 判据自己也要验（见模块说明）：编译失败与「一条都没跑到」都会与「被守卫抓住」
    给出**看不出差别**的结果 —— 必须先排掉。

    ⚠️ 但**不许**用 `"error:" in raw` 排「编译不过」（2026-09-28 实测翻车，见
    `swift-mutation-testing-practices` 的 K15 补强）：本文件的守卫正是**扫源码型**，
    失败操作数是**整份被扫文件**，swift-testing 会把它整份回显，而 `Sources/` 里就存在
    `error:` 字样（`SettingsView.swift` 的 `prompt(for error: LaunchAtLoginError)`）⇒
    **真的跑起来并失败**的变异被误判成 `invalid`，而 `invalid` 不算通过 ⇒ 证据白丢。

    改用**正向证据**：只有真的跑到测试（`Test run with N tests` 且 N ≥ 1）才配谈红；
    跑 0 条时看**构建成没成**（`Build complete!`）与**编译诊断**来分两种 invalid。
    ⚠️ 「过滤器没匹配上」这一种 `swift test` 是**退出码 0**，光看退出码会读成绿。
    """
    run = TEST_RUN_RE.search(raw)
    if run is not None and int(run.group(1)) >= 1:
        # 真的跑到测试了 —— 这时候退出码说了算。
        return "green" if code == 0 else "red"
    # 一条都没跑到：要么构建就没过，要么过滤器一条都没匹配上。
    if COMPILE_DIAG_RE.search(raw) or not BUILD_OK_RE.search(raw):
        return "invalid（变异体编译不过）"
    return "invalid（过滤器一条都没跑到）"


def main() -> int:
    failures: list[str] = []
    for name, why, path, old, new, expect in MUTATIONS:
        original = path.read_text(encoding="utf-8")
        if old is None:
            if original.count(ANCHOR) != 1:
                print(f"[{name}] ⚠️ 锚点在 {path.name} 里出现 {original.count(ANCHOR)} 次 —— 结论作废")
                failures.append(f"{name}: 锚点不唯一")
                continue
            mutated = original.replace(ANCHOR, ANCHOR + new, 1)
            landed_marker = new.strip().splitlines()[0]
        else:
            if original.count(old) != 1:
                print(f"[{name}] ⚠️ 目标片段在 {path.name} 里出现 {original.count(old)} 次 —— 结论作废")
                failures.append(f"{name}: 片段不唯一")
                continue
            mutated = original.replace(old, new, 1)
            landed_marker = new.strip().splitlines()[-1]

        backup = Path(tempfile.mkdtemp(prefix="mut-pixel-")) / path.name
        shutil.copy2(path, backup)
        try:
            path.write_text(mutated, encoding="utf-8")
            # 装置自证 ①：变异真的写进去了（回读，不信写入返回）
            landed = landed_marker in path.read_text(encoding="utf-8")
            print(f"\n[{name}] {why}")
            print(f"[{name}] 变异落地：{landed}（{path.name}）")
            if not landed:
                failures.append(f"{name}: 变异没写进去")
                continue

            code, raw = run_guard()
            verdict = classify(code, raw)
            # 装置自证 ②：打印**原始尾部**（含守卫自己的失败行），不只打印我的结论
            lines = [ln for ln in raw.splitlines() if ln.startswith("✘") or "Test run with" in ln]
            print(f"[{name}] 守卫输出（✘ 与汇总行）：")
            for ln in lines[-8:] or ["（没有任何 ✘ / 汇总行）"]:
                print(f"        {ln}")
            print(f"[{name}] 原始尾部：\n" + "\n".join(raw.splitlines()[-4:]))

            if verdict == expect:
                print(f"[{name}] ✅ 符合预期（{verdict}，退出码 {code}）")
            else:
                print(f"[{name}] ❌ 不符合预期：期望 {expect}，实得 {verdict}（退出码 {code}）")
                failures.append(f"{name}: 期望 {expect} 实得 {verdict}")
        finally:
            # ⚠️ 还原**单独一条**，不挂在可能失败的语句后面；还原后再比对
            shutil.copy2(backup, path)
        if path.read_text(encoding="utf-8") != original:
            print(f"[{name}] ⚠️ 还原后与原文不一致 —— 请人工核对 {path}")
            failures.append(f"{name}: 还原失败")
        else:
            print(f"[{name}] 还原确认：与原文逐字节一致")

    print("\n===== 汇总 =====")
    print(f"变异 {len(MUTATIONS)} 条，未通过 {len(failures)} 条")
    for item in failures:
        print(f"  - {item}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
