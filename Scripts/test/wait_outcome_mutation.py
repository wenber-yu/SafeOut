#!/usr/bin/env python3
"""``WaitOutcome`` / ``appBundlePath`` 守卫的**变异测试**（手动跑，不进 CI）。

## 为什么需要

2026-09-21 这一轮加了三样东西，它们全都是「守装置」而不是「守产品」的：

1. ``WaitOutcome.diagnostic`` —— 失败信息里必须带「等了多久、求值几次」；
2. ``WaitOutcome.failureNote`` —— 那句话必须真的被拼进 `#expect` 的消息；
3. ``ProcessAppResolver.appBundlePath(fromRunningAppBundleURL:)`` ——
   运行中应用报的 `bundleURL` 只有真的是 `.app` 才可信。

第 3 条是**真 bug 修复**（CLT 下测试进程的 `bundleURL` 就是可执行文件自己的路径），
前两条是「下次 CI 红的时候能不能一眼看出真因」。
三条都**必须**用变异证明：把新行为改回旧行为，对应的断言要变红。
没有这一步，它们与「没写」逐字相同 —— 因为「装置报绿」有三种可能：
装置宽容 / 装置死了 / **变异自己没变成旧行为**。

⚠️ **2026-09-22 追加第 4 条**：``EventWait``（等事件那条路的诊断串）+ `waitForNextRound`
的**订阅源**。后者是本轮最有意义的一条变异 —— 把 `objectWillChange`（**不重放**）
换成 `$results`（**会重放当前值**），阴性对照（没有任何轮次）就会立刻「等到」，
于是「事件永不发生」这条判据**失去分辨力**。见 §8.127。

⚠️ **2026-09-23 追加第 5 条（§8.132）**：``WaitOutcome`` 的 `ok` 改成从 ``WaitOutcome/StopReason``
**派生**，且「放弃」必须说清是「看够了」（预算花完）还是「没看够」（撞安全网）。
两条新变异守它：**M7** 把两种放弃说成同一句话、**M8** 拆掉派生关系（`budgetExhausted` 也报「等到了」）。
⚠️ 同时 **M1 引用的格式串逐字更新**过 —— 它原来抄着旧的 `String(format:)` 调用，
改了实现就会「目标片段找不到」⇒ 变异**没落地**（脚本会把它报成失败，这正是要的行为）。

## 用法

```bash
source Tools/clt_swift_env.sh        # 先让 swift 可用（Xcode 许可未接受时）
python3 Scripts/test/wait_outcome_mutation.py
```

## 硬规则（沿用 `test_timings_mutation.py`）

- **备份用 `cp`，还原也用 `cp`**：不用 `git checkout`（它会连未提交的改动一起清掉）。
- **每次变异前先证明它落地了**（回读文件、打印那一行），否则「仍绿」可能只是没改上。
- **打印被测命令的原始尾部**，不只打印我的判红结论 —— 判据自己也会错。
## ⚠️ 第四次实测：判红口径被推翻（2026-09-28，与 `eject_hook_mutation.py` 同步）

原硬规则第 4 条写的是「判红看退出码，先排掉两种假红（查 `"error:"` / `Test run with 0 tests`）」。
⚠️ **那条本身也是错的**，实测各留过一个坑：

1. **`"error:" in raw` 是系统性误判**：**扫源码型守卫**失败时，
   swift-testing 会把 `#expect` 的操作数（**整份被扫文件**）**整份回显** ——
   文件里凡有 `error:`（如 `prompt(for error:)` 这种形参名）就撞上，
   于是**真的跑起来并失败**的变异被判成 `invalid`、**不算通过**，证据白丢。
   被扫文件越大越容易撞。
2. **`Test run with 0 tests` 认不出「压根没匹配上」**：一条都没匹配时 `swift test`
   打的是 `warning: No matching test cases were run` 且**返回 0** ⇒ 旧判据两处都不命中
   ⇒ 判成 **green**。⚠️ **`swift test` 的「退出码 0」同时表示「全部通过」与「一条都没跑」**。
3. **编译失败有两种形态**：swiftc 的 `<file>:<行>:<列>: error:`，以及 SwiftPM 的
   **构建期**错误（无文件行号，只有 `error: Build failed` / `error: fatalError`）。

现行口径：**先拿正向证据**（`Test run with N tests` 且 `N ≥ 1` 才配谈红），
一条都没跑到时按「构建成没成」+ 编译诊断分开两类 `invalid`。
本脚本的过滤器**本来就是测试函数名**（能匹配），但口径仍须统一 ——
判据的地基不能靠「我这次恰好没踩到」。

- 还原之后 `cmp -s` 再确认一次；还原步骤**不挂在会失败的命令后面**（别用 `&&` 串）。
- **先跑基线自检**（`baseline_is_green`）：未变异时必须绿，否则「每条都被抓住」毫无意义。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WAIT_OUTCOME = REPO / "Tests/SafeOutAppTests/WaitOutcome.swift"
OCCUPANCY = REPO / "Tests/SafeOutAppTests/OccupancyStoreTests.swift"
RESOLVER = REPO / "Sources/Services/ProcessAppResolver.swift"

# 两个「等待 helper 自己的守卫」的过滤器（swift-testing 的 --filter 认名字正则）。
# ⚠️ 2026-09-22 更新：`OccupancyStoreTests` 那条**轮询**守卫已换成**等事件**守卫
# （`等事件的装置必须分开报事件到了与接线断了`）—— 名字变了，过滤器必须跟着变，
# 否则「跑到了 0 条测试」与「守卫没牙」在退出码上**逐字相同**。
# ⚠️ 2026-09-23（§8.132）追加第三条：`ok必须由stopReason派生` —— 它断的是
# `ok` 与 `stopReason` 的**派生关系**、以及「两种放弃各有各的一句话」，正是本轮新增的判据。
FILTER_WAIT = (
    "等事件的装置必须分开报事件到了与接线断了|等待可执行路径超时时必须报出轮询次数与耗时"
    "|ok必须由stopReason派生"
)
FILTER_BUNDLE = "非app的运行中应用路径不被当成bundle"

# 「测试真的跑过」的**正向证据**：swift-testing 无论成败都会打这一行（见 ``classify``）。
TEST_RUN_RE = re.compile(r"Test run with (\d+) tests?")
# 构建成功的**正向证据**：SwiftPM 每次构建都会打；**编不过就没有它**。
BUILD_OK_RE = re.compile(r"^\s*Build complete!", re.M)
# 编译诊断的**两种**形态：① swiftc `<file>:<行>:<列>: error:`；② 构建期无行号的 `error: Build failed`。
COMPILE_DIAG_RE = re.compile(r":\d+:\d+: error:|^\s*error: (?:Build failed|fatalError)", re.M)

# 基线自检：本脚本的变异散在**四条**测试上（跨两个 suite），必须全跑。
BASELINE_FILTER = FILTER_WAIT + "|" + FILTER_BUNDLE
# 基线要核对的**四条测试函数名**（这些 suite 无 `@Suite` 展示名可用）。
#
# ⚠️ **核对前必须归一化**（``_normalize_name``）：`--filter` 匹配的是**函数名**，
# 而 swift-testing **输出里打的是 `@Test("…")` 的显示名**，两者**可能不同形** ——
# 实测 `OccupancyStoreTests` 那条：源码 `func 等事件的装置必须分开报事件到了与接线断了()`，
# 输出却是 `"等事件的装置必须分开报「事件到了」与「接线断了」"`（书书名号 + 引号包裹）。
# 拿函数名去 `raw` 里找 ⇒ **假阴性**（测试明明跑到了，却被判成「没跑到」）。
BASELINE_TESTS = (
    "等事件的装置必须分开报事件到了与接线断了",
    "等待可执行路径超时时必须报出轮询次数与耗时",
    "ok必须由stopReason派生",
    "非app的运行中应用路径不被当成bundle",
)


def _normalize_name(s: str) -> str:
    """把测试名归一化：去掉引号 / 书名号 / 括号 / 空白（函数名与显示名常不同形）。"""
    return re.sub(r"[\s「」『』\"'“”（）()\[\]{}]", "", s)


# 基线里**至少**要跑到多少条（2026-09-28 实测为 4 条）。防的是「过滤器只匹配上一部分」。
BASELINE_MIN_TESTS = 4

# (编号, 说明, 文件, 旧片段, 新片段, 过滤器)
MUTATIONS = [
    (
        "M1",
        "`diagnostic` 退化成一句不带数字的空话（正是要修的病）",
        WAIT_OUTCOME,
        'let head = String(format: "等了 %.2fs、求值 %d 次，条件", elapsed, polls)',
        'let head = String(format: "条件")',
        FILTER_WAIT,
    ),
    (
        "M2",
        "`failureNote` 把 `diagnostic` 整个丢掉（消息里就没有数字了）",
        WAIT_OUTCOME,
        'func failureNote(_ what: String) -> String {\n        "\\(what)\\n\\(diagnostic)"\n    }',
        'func failureNote(_ what: String) -> String {\n        "\\(what)"\n    }',
        FILTER_WAIT,
    ),
    (
        "M3",
        "`EventWait.diagnostic` 不再指出「接线断了」—— 兜底那条路又变成一句不指方向的话",
        WAIT_OUTCOME,
        '                : "事件始终没发生 —— 这是**接线断了**（不是排不上队）："',
        '                : "事件始终没发生："',
        FILTER_WAIT,
    ),
    (
        "M4",
        "`EventWait.diagnostic` 把墙钟那段格式改掉（诊断串里不再带出数字）",
        WAIT_OUTCOME,
        'format: "等了 %.2fs，%@", elapsed,',
        'format: "等了 %.2f 秒，%@", elapsed,',
        FILTER_WAIT,
    ),
    (
        "M5",
        "订阅 `$results`（**会重放当前值**）而不是 `objectWillChange`（不重放）"
        " ⇒ 没有轮次也会立刻「等到」—— 阴性对照必须抓住它",
        OCCUPANCY,
        "        cancellable = store.objectWillChange.sink { _ in",
        "        cancellable = store.$results.sink { _ in",
        FILTER_WAIT,
    ),
    (
        "M6",
        "`appBundlePath` 不再要求 `.app` 后缀（回到旧行为：直接采信 `bundleURL`）",
        RESOLVER,
        'guard let path, path.hasSuffix(".app") else { return nil }\n        return path',
        "return path",
        FILTER_BUNDLE,
    ),
    (
        "M7",
        "`ceilingHit` 与 `budgetExhausted` 说成**同一句话**（两种放弃又分不开了，§8.132）",
        WAIT_OUTCOME,
        """        case .ceilingHit:
            return head
                + "始终不成立 —— **没看够**（撞上墙钟安全网）⇒ 是排不上队/环境的问题，别怪被测逻辑\"""",
        """        case .ceilingHit:
            return head + "始终不成立 —— **看够了**（轮询预算花完）⇒ 是被测逻辑的问题\"""",
        FILTER_WAIT,
    ),
    (
        "M8",
        "`ok` 不再由 `stopReason` 派生（`budgetExhausted` 也会报成「等到了」）",
        WAIT_OUTCOME,
        "var ok: Bool { stopReason == .conditionMet }",
        "var ok: Bool { stopReason != .ceilingHit }",
        FILTER_WAIT,
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
    """把一次运行判成 `red` / `green` / `invalid`（口径见模块说明的「第四次实测」）。

    ⚠️ **不许**写成 `"error:" in raw`：扫源码型守卫失败时 swift-testing 会把
    `#expect` 的操作数（整份被扫文件）**整份回显**，文件里凡有 `error:` 字样就撞上
    ⇒ **真的跑起来并失败**的变异被判成 `invalid`、**不算通过**（2026-09-28 实测）。

    现行口径 = **正向证据**：`Test run with N tests` 且 `N ≥ 1` 才配谈红；
    一条都没跑到时，按「构建成没成」+ 编译诊断把两类 `invalid` 分开。
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
    所以这里三重自证：① ``classify`` 判 green；② 跑到 ≥ ``BASELINE_MIN_TESTS`` 条；
    ③ 四条测试函数名逐个出现在输出里。
    """
    print("===== 基线自检（未变异，四条测试全跑）=====")
    code, raw = run_tests(BASELINE_FILTER)
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
        f"基线跑到 {count} 条测试；四条测试名核对：" + ("全在" if not missing else "缺 " + "、".join(missing)))
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
