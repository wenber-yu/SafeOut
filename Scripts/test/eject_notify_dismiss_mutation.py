#!/usr/bin/env python3
"""「占用通知幂等 + 系统框归属判据 + 占用者摘要」的**变异测试**（手动跑，不进 CI）。

## 为什么需要

2026-09-29 本轮新增七处**纯判据**，每一处判错都不会有任何编译错、也不会崩：

| 判据 | 判错的症状 |
|---|---|
| ``EjectNotificationPolicy/shouldPost(mountPath:)`` | 访达每重试一次（≈2s）就多投一条系统通知 → 一分钟几十条刷屏 |
| ``SystemEjectDialogDismisser/mentionsDisk(_:name:)`` | 去关**别的盘**的系统占用框（用户在处理 A，B 的提示却消失了） |
| ``SystemEjectDialogDismisser/pressPlan(hasCancelButton:titledButtonCount:)`` | 取消按钮读不到时按到「强制推出…」= **强制卸载、可能丢数据** |
| ``SystemEjectDialogDismisser/allowsTerminateFallback(windowCount:)`` | 无授权兜底时把**无关那块盘**的框一起关掉（agent 挂着多个框） |
| ``EjectAttention/processSummary`` | 菜单面板与系统通知对同一件事**各说一套**（分隔符/顺序漂移） |
| ``AppReopenPolicy/target(hasPendingAttention:)`` | 点系统通知却开出主窗口，把菜单面板顶掉（看不到「关闭并推出」） |
| ``SystemEjectDialogDismisser/shouldSuggestAccessibility(isTrusted:)`` | 两个方向都是缺陷：**恒真** ⇒ 已授权的用户每次拨开关都被打扰；**恒假** ⇒ 辅助功能引导永不出现，而界面别处没有任何痕迹（用户永远不知道这项权限存在） |

所以每条断言都必须**有牙**：把它变异回错误行为，对应断言要变红。
没有这一步，「装置报绿」有三种可能：装置宽容 / 装置死了 / **变异自己没变成错误行为**。

## 用法

```bash
source Tools/clt_swift_env.sh        # 先让 swift 可用（Xcode 许可未接受时）
python3 Scripts/test/eject_notify_dismiss_mutation.py
```

## 硬规则（沿用 `eject_flow_mutation.py` 的现行口径）

- **备份用 `cp`，还原也用 `cp`**：不用 `git checkout`（它会连未提交的改动一起清掉）。
- **每次变异前先证明它落地了**（回读文件），否则「仍绿」可能只是没改上。
- **判红要正向证据**：`Test run with N tests` 且 `N ≥ 1` 才配谈红；
  `"error:" in raw` 是系统性误判（扫源码型守卫失败时整份文件被回显）。
- **编译失败两种形态都认**：`文件:行:列: error:` 与构建期无行号的
  `error: Build failed` / `error: fatalError`。
- **匹配 0 条时 `swift test` 打 warning 并返回 0** ⇒ 退出码 0 同时表示
  「全通过」与「一条都没跑」，必须先拿 `Test run with N tests`。
- **`--filter` 只认类型标识符 / 测试函数名，不认 `@Suite("…")` 展示名**。
  这些 suite 都有展示名，所以基线自检**除了条数下限，还要逐个核对展示名**。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
NOTIFICATION = REPO / "Sources/Services/EjectNotificationService.swift"
DISMISSER = REPO / "Sources/Services/SystemEjectDialogDismisser.swift"
ATTENTION = REPO / "Sources/Services/EjectAttentionCenter.swift"
APP_DELEGATE = REPO / "Sources/SafeOutApp/SafeOutApp.swift"

TEST_RUN_RE = re.compile(r"Test run with (\d+) tests?")
BUILD_OK_RE = re.compile(r"^\s*Build complete!", re.M)
COMPILE_DIAG_RE = re.compile(r":\d+:\d+: error:|^\s*error: (?:Build failed|fatalError)", re.M)

# 三个 suite 一起跑。`--filter` 是正则，用 `|` 拼。（不能用 `@Suite` 展示名做过滤器 ——
# 见模块说明最后一条硬规则。）
FILTER_BASELINE = (
    "EjectNotificationPolicyTests|SystemEjectDialogDismisserTests"
    "|SystemEjectDialogPressPlanTests|SystemEjectDialogFallbackTests|EjectAttentionSummaryTests"
    "|AppReopenPolicyTests|AccessibilityOnboardingTests"
)

# 基线条数：策略 4 + 框归属 5 + 按钮选择 4 + 兜底边界 2 + 摘要 3 + 落点 2
# + 辅助功能引导 2 = 22。防「过滤器只匹配上一部分」的半空转。
BASELINE_MIN_TESTS = 22

# 基线还要**逐个核对展示名**（这七个 suite 都有 `@Suite("…")`），
# 防「过滤器命中了别的同名 suite」。空白/引号/书名号一律剥掉再比 —— `--filter` 认
# 类型名、输出打显示名，两者常常不同形。
EXPECTED_SUITE_NAMES = [
    "占用通知的幂等判据",
    "系统占用框的归属判据",
    "系统框该按哪个按钮",
    "无授权时的关框兜底",
    "占用者摘要",
    "重新打开时的落点",
    "辅助功能引导的触发判据",
]


def normalize(text: str) -> str:
    return re.sub(r"[\s「」『』\"'“”()（）]", "", text)


MUTATIONS = [
    (
        "M1",
        "``EjectNotificationPolicy.shouldPost`` **永远返回 `true`**（记账失效）⇒"
        "访达每次重试都再投一条通知 —— 用户会在一分钟内被几十条通知刷屏",
        NOTIFICATION,
        "notifiedMountPaths.insert(mountPath).inserted",
        "true",
        "同一块盘只投一条|撤回一块盘不影响另一块",
    ),
    (
        "M2",
        "``EjectNotificationPolicy.shouldPost`` **永远返回 `false`**（永不投递）⇒"
        "功能静默失效：菜单栏会警示，但系统通知一条都收不到",
        NOTIFICATION,
        "notifiedMountPaths.insert(mountPath).inserted",
        "false",
        "同一块盘只投一条|不同的盘互不影响",
    ),
    (
        "M3",
        "``SystemEjectDialogDismisser.mentionsDisk`` 的**空名字守卫反转**"
        "（空串变成万能匹配）⇒ 会把**别的盘**的系统框一起关掉",
        DISMISSER,
        "guard !name.isEmpty else { return false }",
        "guard !name.isEmpty else { return true }",
        "空盘名一律不算",
    ),
    (
        "M4",
        "``SystemEjectDialogDismisser.mentionsDisk`` **永远返回 `false`** ⇒"
        "任何框都关不掉，功能静默失效（退出码 0、日志也无异常）",
        DISMISSER,
        "return texts.contains { $0.contains(name) }",
        "return false",
        "正文提到这块盘就算它|带弯引号的盘名照样匹配",
    ),
    (
        "M5",
        "``EjectAttention.processSummary`` 的分隔符改成 `, `（与菜单面板那份漂移）⇒"
        "同一件事在两处出现两种说法",
        ATTENTION,
        'processes.map(\\.displayName).joined(separator: "、")',
        'processes.map(\\.displayName).joined(separator: ", ")',
        "多个占用者用顿号连接",
    ),
    (
        "M6",
        "``SystemEjectDialogDismisser.pressPlan`` 的兜底**去掉「恰好一个」这条边界** ⇒"
        "取消按钮读不到时会把「强制推出…」当成唯一出口按下去 —— **强制卸载、可能丢数据**",
        DISMISSER,
        "        return titledButtonCount == 1 ? .soleButton : .none",
        "        return .soleButton",
        "多个带标题按钮且没有取消时不动手",
    ),
    (
        "M7",
        "``SystemEjectDialogDismisser.pressPlan`` **不再优先「取消」** ⇒"
        "形态 A（取消 / 强制推出…）会退到兜底分支，两个按钮 ⇒ 一个框都关不掉（功能静默失效）",
        DISMISSER,
        "        if hasCancelButton { return .cancel }",
        "        if hasCancelButton { return .none }",
        "有取消按钮时优先按取消",
    ),
    (
        "M8",
        "``SystemEjectDialogDismisser.allowsTerminateFallback`` 的**「恰好一个」边界放开成「至少一个」** ⇒"
        "agent 同时挂着两块盘的框时，结束进程会把**跟本次操作无关**的那个框一起关掉（误伤）",
        DISMISSER,
        "        windowCount == 1",
        "        windowCount >= 1",
        "零个或多个框都不动手",
    ),
    (
        "M9",
        "``AppReopenPolicy.target`` **恒返回主窗口** ⇒ 点系统通知时开出主窗口，"
        "把刚打开的菜单面板顶掉 —— 用户看不到「关闭并推出」（真机踩过一次）",
        APP_DELEGATE,
        "        hasPendingAttention ? .attentionPanel : .mainWindow",
        "        .mainWindow",
        "有待处理提醒时开菜单面板",
    ),
    (
        "M10",
        "``SystemEjectDialogDismisser.shouldSuggestAccessibility`` **恒真** ⇒"
        "已经授权的用户每次拨「推出时提醒占用」都被这个弹窗打扰一次"
        "（他刚在系统设置里点过 —— 纯噪音，且**没有任何东西会变红**）",
        DISMISSER,
        "-> Bool { !isTrusted }",
        "-> Bool { true }",
        "已授权就不再打扰",
    ),
    (
        "M11",
        "``SystemEjectDialogDismisser.shouldSuggestAccessibility`` **恒假** ⇒"
        "辅助功能引导永不出现。而这是**唯一**能告诉用户这项权限存在的通道"
        "（它不影响可用性，所以别处没有痕迹），且每次重新构建都会掉授权",
        DISMISSER,
        "-> Bool { !isTrusted }",
        "-> Bool { false }",
        "没授权时才引导",
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
    """把一次运行判成 `red` / `green` / `invalid`（口径见模块说明的「硬规则」）。"""
    run = TEST_RUN_RE.search(raw)
    if run is not None and int(run.group(1)) >= 1:
        return "green" if code == 0 else "red"
    if COMPILE_DIAG_RE.search(raw) or not BUILD_OK_RE.search(raw):
        return "invalid（变异体编译不过）"
    return "invalid（过滤器一条都没跑到）"


def baseline_is_green() -> bool:
    """先证明**未变异时装置是绿的**，且过滤器命中的确实是这三套用例。

    三重自证：① ``classify`` 判 green；② 真跑到 ≥ ``BASELINE_MIN_TESTS`` 条；
    ③ 三套 suite 的展示名逐个出现（防「过滤器改坏了、只跑到一部分」）。
    """
    print("===== 基线自检（未变异）=====")
    code, raw = run_tests(FILTER_BASELINE)
    verdict = classify(code, raw)
    print(f"退出码 {code}，判定 {verdict}")
    if verdict != "green":
        print("⚠️ 基线不是绿的 —— 先修基线，再来谈变异。")
        print("\n".join(raw.splitlines()[-12:]))
        return False

    count = int(TEST_RUN_RE.search(raw).group(1))
    print(f"基线跑到 {count} 条测试（下限 {BASELINE_MIN_TESTS}）")
    if count < BASELINE_MIN_TESTS:
        print(f"⚠️ 只跑到 {count} 条（< {BASELINE_MIN_TESTS}）—— 过滤器少匹配了，结论作废。")
        return False

    flat = normalize(raw)
    missing = [name for name in EXPECTED_SUITE_NAMES if normalize(name) not in flat]
    if missing:
        print(f"⚠️ 这些展示名没在输出里出现：{missing} —— 过滤器命中的不是这三套用例，结论作废。")
        return False
    print(f"展示名逐个核对通过：{EXPECTED_SUITE_NAMES}")
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
            landed = new in path.read_text(encoding="utf-8")
            print(f"\n[{name}] {why}")
            print(f"[{name}] 变异落地：{landed}（{path.name}）")
            if not landed:
                failures.append(f"{name}: 变异没写进去")
                continue
            code, raw = run_tests(filter_expr)
            verdict = classify(code, raw)
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
