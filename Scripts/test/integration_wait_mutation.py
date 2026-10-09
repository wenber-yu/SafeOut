#!/usr/bin/env python3
"""`IntegrationEjectTests` 的**等待装置 / 诊断装置**的变异测试（手动跑，不进 CI）。

## 为什么需要

2026-09-21 这一轮改的是**测试装置**，不是产品：

1. `waitForDisk` —— 不再假设「`hdiutil attach` 返回 ⇒ 盘立刻可见」，改成**轮询**到
   `fetchExternalDisks()` 里出现为止（那才是产品自己的可见判定时点）；
2. `notFoundDiagnostic` —— 未找到测试盘时的失败文本，必须把**四条证据**打出来，
   好把「没挂上 / DiskArbitration 还没描述出它 / 枚举口径」三种可能分开。

两条都**必须**用变异证明：把新行为改回旧行为，对应的断言要变红。
没有这一步，它们与「没写」逐字相同 —— 因为「装置报绿」有三种可能：
装置宽容 / 装置死了 / **变异自己没变成旧行为**。

## ⚠️ 一次实测留下的重要提醒（2026-09-21）

变异 M1 下，**真机那条 `真实占用时关闭进程并推出` 照样是绿的** ——
也就是说「偶发」并没有被这条变异复现出来。⇒ **变异只证明「守卫有牙」，
不证明「那个偶发已经消失」**；这条测试的偶发本来就只有 ~1/几十 的概率。
别把「变异全红」当成「flaky 已修好」的证据。

## ⚠️ 第二次实测：**守卫自己也会 flaky**（2026-09-21，§8.118）

第一版守卫写的是「探针 `[nil, nil, disk]` ⇒ 恰好 3 拍」，本地全绿，**CI 上红了 3 条 issue**
（`IntegrationEjectTests.swift:304 / :305 / :308`）：

    ✘ Expectation failed: (waited.outcome → WaitOutcome(ok: false, polls: 2, elapsed: 6.140589952468872)).ok → false

两次求值之间那次 `await`（`Task.sleep` / actor 跳转）**只保证下界** —— runner 上实测拖了 ~6.1s
⇒ `timeout: 5` 的窗口被整个吃掉 ⇒ 第 3 拍**永远没发生**。

⇒ 守卫里**不许**写「第 N 拍才成立」（N ≥ 3）：那是把机器的调度延迟写进判据。
当时 ① 改成 `[nil, disk]`（第 **2** 拍 —— 「循环里那拍」与「补查那拍」两条路都在第 2 次
求值拿到盘，所以与调度无关），并新增 ④（`timeout: 0`）钉「超时后那次补查」。

**M4 就是为 ④ 准备的**：删掉补查后，② 的 `polls >= 2` 可能仍然成立（循环自己跑了两拍
就够了），只有 ④ 会红。

## ⚠️ 第三次实测：**根因修掉了，那条禁令随之作废**（2026-09-23，§8.132）

上面那条「不许写第 N 拍才成立」是**绕过**，不是修好 —— 循环的退出条件仍然是
`while Date() < deadline`，墙钟说了算。本轮把退出条件换成**轮询预算**（`pollBudget`），
墙钟降级成安全网（`hardCeilingMS`）⇒ 「迭代次数由截止时间决定」这个前提**不存在了**。

⇒ 三条新变异专门守这一轮的新行为：

- **M5**：退出条件退回纯墙钟 ⇒ 「预算说了算」那条守卫必须红（**这条就是旧 bug 的回归测试**）；
- **M6**：`stopReason` 的默认值改成 `ceilingHit` ⇒ 「两个出口各有各的名字」必须红；
- **M7**：把**参考实现**（阳性对照）的墙钟判断拆掉 ⇒ 阳性对照自己必须红 ——
  否则「新写法成功了」这句话什么都没证明（装置死了与真修好了，输出**逐字相同**）。

⚠️ 同时 M1 / M4 引用的源码文本**逐字更新**过：它们原来整段抄着旧实现，
改了实现就会「目标片段找不到」⇒ 变异**没落地**，而脚本会把它报成失败（这正是要的行为：
**先证明变异落地，再判红**）。

## 用法

```bash
source Tools/clt_swift_env.sh        # 先让 swift 可用（Xcode 许可未接受时）
python3 Scripts/test/integration_wait_mutation.py
```

## 硬规则（沿用 `wait_outcome_mutation.py`）

- **备份用 `cp`，还原也用 `cp`**：不用 `git checkout`（它会连未提交的改动一起清掉）。
- **每次变异前先证明它落地了**（回读文件、打印那一行），否则「仍绿」可能只是没改上。
- **打印被测命令的原始尾部**，不只打印我的判红结论 —— 判据自己也会错。
- 判红**要拿出「测试真的跑过」的正向证据**（`classify`），**不是**「退出码非 0」。
- 还原之后 `cmp -s` 再确认一次；还原步骤**不挂在会失败的命令后面**（别用 `&&` 串）。
- **先跑基线自检**（`baseline_is_green`）：未变异时必须绿，否则「每条都被抓住」毫无意义。

## ⚠️ 第四次实测：判红口径被推翻（2026-09-28，与 `eject_hook_mutation.py` 同步）

本脚本原判据是「`"error:" in raw` ⇒ 编译不过 / `Test run with 0 tests` ⇒ 过滤器没跑到 /
否则看退出码」。三处都错，实测各留过一个坑：

1. **`"error:" in raw` 是系统性误判**：**扫源码型守卫**失败时，
   swift-testing 会把 `#expect` 的操作数（**整份被扫文件**）**整份回显** ——
   文件里凡是出现 `error:`（如 `prompt(for error:)` 这类形参名）就撞上，
   于是**真的跑起来并失败**的变异被判成 `invalid`、**不算通过**，证据白丢。
2. **`Test run with 0 tests` 认不出「压根没匹配上」**：过滤器一条都没匹配时，
   `swift test` 打的是 `warning: No matching test cases were run` 且**返回 0** ——
   旧判据两处都不命中 ⇒ 判成 **green**。⚠️ **`swift test` 的「退出码 0」同时表示
   「全部通过」与「一条都没跑」**，这是本装置最危险的一种假绿。
3. **编译失败有两种形态**：swiftc 的 `<file>:<行>:<列>: error:`，
   以及 SwiftPM 的**构建期**错误（没有文件行号，只有 `error: Build failed` /
   `error: fatalError`）。只认前者会漏掉后者。

现行口径（`classify`）：**先拿正向证据** —— `Test run with N tests` 且 `N ≥ 1` 才配谈红；
一条都没跑到时，用「构建成没成」（`Build complete!`）+ 编译诊断把
「编译不过」与「过滤器没跑到」分开。
⚠️ 基线自检也必须**三重自证**（绿 + 条数下限 + 各测试函数名逐个核对），
否则整套论证的地基是个空转的绿。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
INTEGRATION = REPO / "Tests/SafeOutAppTests/IntegrationEjectTests.swift"

# 整个套件一起跑：swift-testing 的 --filter 认名字正则，用套件名最稳（不会匹配到 0 条）。
#
# ⚠️ **必须是类型标识符，不能是 `@Suite("…")` 的展示名**：`--filter` 只匹配
# **类型标识符与测试函数名**，展示名**不参与**匹配（`eject_hook_mutation.py` 2026-09-28 实测）。
# 本套件恰好**没有** `@Suite` 展示名（`struct IntegrationEjectTests` 直接开头），
# 所以基线自检核对的是**五条测试函数名**，不是展示名。
FILTER_SUITE = "IntegrationEjectTests"

# 「测试真的跑过」的**正向证据**：swift-testing 无论成败都会打这一行（见 ``classify``）。
TEST_RUN_RE = re.compile(r"Test run with (\d+) tests?")
# 构建成功的**正向证据**：SwiftPM 每次构建都会打；**编不过就没有它**。
BUILD_OK_RE = re.compile(r"^\s*Build complete!", re.M)
# 编译诊断的**两种**形态：① swiftc `<file>:<行>:<列>: error:`；② 构建期无行号的 `error: Build failed`。
COMPILE_DIAG_RE = re.compile(r":\d+:\d+: error:|^\s*error: (?:Build failed|fatalError)", re.M)

# 基线要核对的**五条测试函数名**（本套件没有展示名，只能核对这些）。
#
# ⚠️ **核对前必须归一化**（``_normalize_name``）：`--filter` 匹配**函数名**，
# 而输出里打的是 `@Test("…")` 的**显示名**，两者可能不同形
# （实测 `OccupancyStoreTests` 有一条：源码 `…报事件到了与接线断了`，
# 输出却是 `"…报「事件到了」与「接线断了」"`）。本套件这五条当前同形，
# 但口径必须统一 —— 别等改了显示名才发现核验是假阴性。
BASELINE_TESTS = (
    "真实占用时关闭进程并推出",
    "等待测试盘的装置必须真的轮询并且能超时",
    "每拍被拖长时不再误报超时",
    "放弃时要分清看够了与没看够",
    "未找到测试盘时的诊断必须带上四条证据与数字",
)


def _normalize_name(s: str) -> str:
    """把测试名归一化：去掉引号 / 书名号 / 括号 / 空白（函数名与显示名常不同形）。"""
    return re.sub(r"[\s「」『』\"'“”（）()\[\]{}]", "", s)


# 基线里**至少**要跑到多少条（2026-09-28 实测为 5 条）。防的是「过滤器只匹配上一部分」。
BASELINE_MIN_TESTS = 5

# (编号, 说明, 文件, 旧片段, 新片段, 过滤器)
MUTATIONS = [
    (
        "M1",
        "`waitForDisk` 退回「只查一次」（模拟 2026-09-21 那次偶发的旧行为）",
        INTEGRATION,
        """        var stopReason = WaitOutcome.StopReason.budgetExhausted
        while polls < pollBudget {""",
        """        var stopReason = WaitOutcome.StopReason.budgetExhausted
        while polls < 0 {""",
        FILTER_SUITE,
    ),
    (
        "M2",
        "诊断里删掉 ② 与 ④ 两条证据（三种可能就分不开了）",
        INTEGRATION,
        """        ② 只喂它一个 URL 给 fetchExternalDisks()：\\(Self.enumerateOnly(vol))
           （空 = DiskArbitration 还描述不出它 / 判定为不可推出；非空 = 枚举本身能认它）
""",
        "",
        FILTER_SUITE,
    ),
    (
        "M3",
        "诊断装置瞎掉：`systemMounts()` 恒返回空数组",
        INTEGRATION,
        """        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? [])
            .map(\\.path)""",
        """        []""",
        FILTER_SUITE,
    ),
    (
        "M4",
        "删掉「放弃后那次补查」（`pollBudget: 0` 时盘就再也拿不到了）",
        INTEGRATION,
        """        // 退出循环时可能刚好是最后一拍就绪 —— 再查一次，别把「刚好赶上」误报成超时。
        polls += 1
        let found = await probe()
        return (
            WaitOutcome(
                stopReason: found != nil ? .conditionMet : stopReason, polls: polls,
                elapsed: Date().timeIntervalSince(started)),
            found
        )""",
        """        return (
            WaitOutcome(
                stopReason: stopReason, polls: polls,
                elapsed: Date().timeIntervalSince(started)),
            nil
        )""",
        FILTER_SUITE,
    ),
    (
        "M5",
        "退出条件退回**纯墙钟**（**旧 bug 的回归测试**：§8.118 那次 CI 红的写法）"
        " ⇒「预算说了算」必须红",
        INTEGRATION,
        """        while polls < pollBudget {
            if Date() >= ceiling {
                stopReason = .ceilingHit
                break
            }
            polls += 1""",
        """        while Date() < ceiling {
            polls += 1""",
        FILTER_SUITE,
    ),
    (
        "M6",
        "`stopReason` 的默认值改成 `ceilingHit` ⇒「预算花完」与「安全网到点」就分不开了",
        INTEGRATION,
        """        var stopReason = WaitOutcome.StopReason.budgetExhausted
        while polls < pollBudget {""",
        """        var stopReason = WaitOutcome.StopReason.ceilingHit
        while polls < pollBudget {""",
        FILTER_SUITE,
    ),
    (
        "M7",
        "把**参考实现**（阳性对照）的墙钟窗口放到无限大 ⇒ 阳性对照自己必须红。"
        " 它不红，就说明「新写法成功了」这句话什么都没证明（装置死了与真修好了，输出逐字相同）",
        INTEGRATION,
        "        while Date() < deadline {",
        "        while Date() < deadline + 86_400 {",
        FILTER_SUITE,
    ),
]


def run_tests(filter_expr: str) -> tuple[int, str]:
    """跑一次 `swift test`（只跑目标用例），返回 (退出码, 原始输出)。"""
    proc = subprocess.run(
        ["swift", "test", "--disable-sandbox", "--filter", filter_expr],
        cwd=REPO,
        capture_output=True,
        text=True,
        errors="replace",
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def classify(code: int, raw: str) -> str:
    """把一次运行判成 `red` / `green` / `invalid`。

    ## ⚠️ 判据自己也要验（2026-09-28，与 `eject_hook_mutation.py` 同步）

    本函数原来写的是 `"error:" in raw` —— **系统性误判**：扫源码型守卫失败时
    swift-testing 会把 `#expect` 的操作数（整份被扫文件）**整份回显**，
    文件里凡有 `error:` 字样就撞上 ⇒ **真的跑起来并失败**的变异被判成 `invalid`、
    **不算通过**。详见模块说明的「第四次实测」。

    ## 现行口径：要判红，先拿出「测试真的跑过」的正向证据

    - **被抓住（red）** ⇒ `Test run with N tests` 且 `N ≥ 1`，同时退出码非 0；
    - **过滤器没跑到** ⇒ 没有那一行、或 `N == 0`。⚠️ 这一种 `swift test`
      **返回 0**（只有一行 `warning: No matching test cases were run`）——
      光看退出码会读成**绿**，比「假红」更坏；
    - **编译不过** ⇒ 构建阶段就挂了，不会有那一行。与上一种按
      「构建成没成」（`Build complete!`）+ 编译诊断分开。
    """
    run = TEST_RUN_RE.search(raw)
    if run is not None and int(run.group(1)) >= 1:
        # 真的跑到测试了 —— 这时候退出码说了算。
        return "green" if code == 0 else "red"
    # 一条都没跑到：要么构建就没过，要么过滤器一条都没匹配上。
    if COMPILE_DIAG_RE.search(raw) or not BUILD_OK_RE.search(raw):
        return "invalid（变异体编译不过）"
    return "invalid（过滤器一条都没跑到）"


def baseline_is_green() -> bool:
    """先证明**未变异时装置是绿的** —— 否则后面「每条都被抓住」毫无意义。

    ⚠️ 光看「退出码 0」不够：**跑 0 条测试也返回 0**（见 ``classify`` 的说明）。
    所以这里三重自证：
    ① ``classify`` 判 green（跑到 ≥ 1 条且退出码 0）；
    ② 真的跑到 ≥ ``BASELINE_MIN_TESTS`` 条（拦「只匹配上一部分」）；
    ③ 五条测试函数名逐个出现在输出里（拦「某一条悄悄变名字/没跑」）。
    """
    print("===== 基线自检（未变异，整个套件全跑）=====")
    code, raw = run_tests(FILTER_SUITE)
    verdict = classify(code, raw)
    print(f"退出码 {code}，判定 {verdict}")
    print("原始尾部：")
    print("\n".join(raw.splitlines()[-6:]))
    if verdict != "green":
        print("⚠️ 基线不是绿的 —— 先修基线，再来谈变异。")
        return False

    run = TEST_RUN_RE.search(raw)
    count = int(run.group(1))
    haystack = _normalize_name(raw)
    missing = [name for name in BASELINE_TESTS if _normalize_name(name) not in haystack]
    print(
        f"基线跑到 {count} 条测试；五条测试名核对：" + ("全在" if not missing else "缺 " + "、".join(missing)))
    if count < BASELINE_MIN_TESTS:
        print(f"⚠️ 基线只跑到 {count} 条（< {BASELINE_MIN_TESTS}）—— 过滤器少匹配了，结论作废。")
        return False
    if missing:
        print("⚠️ 有测试名没跑到 —— 基线覆盖不完整，结论作废。")
        return False
    return True


def main() -> int:
    if not baseline_is_green():
        return 1

    failures: list[str] = []
    for name, why, path, old, new, filter_expr in MUTATIONS:
        original = path.read_text(encoding="utf-8")
        if old not in original:
            print(f"[{name}] ⚠️ 装置自证失败：目标片段不在 {path.name} 里 —— 这条变异没落地，结论作废")
            failures.append(f"{name}: 目标片段找不到")
            continue
        if original.count(old) != 1:
            print(f"[{name}] ⚠️ 目标片段出现 {original.count(old)} 次，无法唯一定位 —— 结论作废")
            failures.append(f"{name}: 片段不唯一")
            continue

        backup = Path(tempfile.mkdtemp(prefix="mut-")) / path.name
        shutil.copy2(path, backup)
        try:
            path.write_text(original.replace(old, new, 1), encoding="utf-8")
            # 装置自证 ①：变异真的写进去了（回读，不信写入返回）
            landed = new in path.read_text(encoding="utf-8")
            print(f"\n[{name}] {why}")
            print(f"[{name}] 变异落地：{landed}（{path.name}）")
            if not landed:
                failures.append(f"{name}: 变异没写进去")
                continue
            code, raw = run_tests(filter_expr)
            verdict = classify(code, raw)
            # 装置自证 ②：打印**原始输出**里的 ✘ 与汇总行，不只打印我的判红结论
            lines = [ln for ln in raw.splitlines() if ln.startswith("✘") or "Test run with" in ln]
            print(f"[{name}] 守卫输出（✘ 与汇总行）：")
            for ln in lines[-8:] or ["（没有任何 ✘ / 汇总行）"]:
                print(f"        {ln}")
            print(f"[{name}] 原始尾部：\n" + "\n".join(raw.splitlines()[-4:]))
            if verdict == "red":
                print(f"[{name}] ✅ 被抓住（退出码 {code}）")
            elif verdict == "green":
                print(f"[{name}] ❌ 仍绿 —— 这条守卫没有牙")
                failures.append(f"{name}: 仍绿")
            else:
                print(f"[{name}] ❌ {verdict} —— 结论作废")
                failures.append(f"{name}: {verdict}")
        finally:
            # ⚠️ 还原**单独一条**，不挂在可能失败的语句后面；还原后再 cmp 确认
            shutil.copy2(backup, path)
        if path.read_text(encoding="utf-8") != original:
            print(f"[{name}] ⚠️ 还原后内容与原文不一致 —— 请人工核对 {path}")
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
