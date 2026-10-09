#!/usr/bin/env python3
"""`DeploymentTargetTests` 的变异测试 —— 证明那 5 条守卫**有牙**。

用法（**手动跑，不进门槛**，与 `Scripts/test/test_timings_mutation.py` 同款）：

    source Tools/clt_swift_env.sh
    python3 Scripts/test/deployment_target_mutation.py

退出码：0 = 全部变异都符合预期；1 = 有不符合预期的条目（或基线不绿 / 装置坏了）。

--------------------------------------------------------------------------
按本仓 `swift-mutation-testing-practices` 的硬规则写（每条都对应一次真实故障）
--------------------------------------------------------------------------

1. **备份按文件去重、名字必须唯一**。第一版用 `p.name` 当备份名 ⇒
   主包 `Package.swift` 与 `Tools/gen_l10n_tool/Package.swift` **撞成同一个备份文件**，
   还原时把主包的内容写进了工具包，**而末尾自检还报「一致」**（比对的正是那份错备份）。
   ⇒ 现在按**相对路径**拼名字（`Tools__gen_l10n_tool__Package.swift.bak`）。
2. **备份后立刻 `cmp -s` 自证「备份 == 当前内容」**（K4）。这条本轮真的救了一次：
   上一次跑留下的过期备份还在（清理被批量删除守卫拦下）⇒ 当场报
   「备份内容与当前文件不一致」并中止，而不是拿错备份去还原。
   过期备份的处理是**重新采一份并打印**，不是静默沿用。
3. **每次变异之前先 `restore_all()`** —— 不许把变异 B 叠在变异 A 的改动上跑，
   否则 B 的「红」分不清是谁造成的。
4. **落地后立即 `cmp`**：与备份逐字节相同 ⇒ 变异没生效，结论作废（不是「守卫没牙」）。
5. **`classify()` 先排掉 invalid**（变异体编译不过 / 过滤器一条都没跑到）——
   它们的退出码也是非 0，与「被守卫抓住」在退出码上**逐字相同**（K15）。
6. **还原用独立步骤 + `cmp` 校验**，绝不挂在会失败的命令后面。
7. **逐条打印失败的测试名** —— 连带红会把人带偏（K9）。
"""

import pathlib
import re
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
BAK = ROOT / ".build/mutation/deployment-target"

BACKUPS: dict[pathlib.Path, pathlib.Path] = {}
modified: list[pathlib.Path] = []


def ensure_backup(p: pathlib.Path) -> pathlib.Path:
    """备份名 = 相对路径的 `__` 拼接 —— **不能用 `p.name`**（同名文件会撞）。"""
    bp = BAK / ("__".join(p.relative_to(ROOT).parts) + ".bak")
    BAK.mkdir(parents=True, exist_ok=True)
    if bp.exists() and subprocess.run(["cmp", "-s", str(p), str(bp)]).returncode != 0:
        print(f"   ⓘ 备份 {bp.name} 已过期（与当前内容不同）—— 重新采一份")
        bp.unlink()
    if not bp.exists():
        shutil.copy(p, bp)
    BACKUPS[p] = bp
    # K4：备份内容本身必须是对的 —— 拿它与**当前文件**比一次（不是与「我以为的」比）。
    ok = subprocess.run(["cmp", "-s", str(p), str(bp)]).returncode == 0
    print(f"   备份 {p.relative_to(ROOT)} → {bp.name}（与当前内容一致 = {ok}）")
    if not ok:
        raise SystemExit(f"❌ 备份内容与当前文件不一致：{bp} —— 结论作废")
    return bp


def restore_all() -> None:
    for src in list(modified):
        shutil.copy(BACKUPS[src], src)
        ok = subprocess.run(["cmp", "-s", str(src), str(BACKUPS[src])]).returncode == 0
        print(f"     还原 {src.name}: {'OK' if ok else '**失败**'}")
    modified.clear()


def run_tests() -> tuple[int, str]:
    r = subprocess.run(
        ["swift", "test", "--disable-sandbox", "--filter", "DeploymentTargetTests"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return r.returncode, r.stdout + r.stderr


# 「测试真的跑过」的**正向证据**：swift-testing 无论成败都会打这一行。
TEST_RUN_RE = re.compile(r"Test run with (\d+) tests?")
# 构建成功的**正向证据**：SwiftPM 每次构建都会打这一行；**编不过就没有它**。
BUILD_OK_RE = re.compile(r"^\s*Build complete!", re.M)
# 编译诊断的**两种**形态：swiftc 的 `<file>:<行>:<列>: error:`，
# 与**构建期**（无文件行号）的 `error: Build failed` / `error: fatalError`。
# ⚠️ 本脚本的 M1 / M2 正是「编译器挡」，它们报的是**第二种**
# （`error: The package product 'gen_l10n_tool-product' requires minimum platform version 14.0 …`）
# ⇒ 少了第二种就会被错判成「过滤器一条都没跑到」，与 `expect` 逐字比较时当场 NG。
COMPILE_DIAG_RE = re.compile(r":\d+:\d+: error:|^\s*error: (?:Build failed|fatalError)", re.M)


def classify(code: int, raw: str) -> str:
    """先排掉 invalid —— 它们的退出码也是非 0，与「被守卫抓住」逐字相同。

    ⚠️ **不许**写成 `"error:" in raw`（2026-09-28 实测翻车，见 `swift-mutation-testing-practices`
    的 K15 补强）：**扫源码型守卫**的失败操作数是**整份被扫文件**（`#expect(code.contains(…))`），
    swift-testing 失败时把它整份回显，而本仓 `Sources/Views/SettingsView.swift` 里就有
    `private func prompt(for error: LaunchAtLoginError)` ⇒ `"error:" in raw` 为真 ⇒
    把**真的跑起来并失败**的变异误判成「编译不过」（`invalid` 不算通过 ⇒ 证据被白白丢掉）。

    改用**正向证据**：只有真的跑到测试（`Test run with N tests` 且 N ≥ 1）才配谈红；
    跑 0 条时，看**构建成没成**（`Build complete!` 在不在）+ **编译诊断**来分
    「编译不过」与「过滤器没跑到」。
    ⚠️ 后者（过滤器没匹配上）`swift test` 是**退出码 0**，光看退出码会读成绿。
    """
    run = TEST_RUN_RE.search(raw)
    if run is not None and int(run.group(1)) >= 1:
        # 真的跑到测试了 —— 这时候退出码说了算。
        return "green" if code == 0 else "red"
    # 一条都没跑到：要么构建就没过，要么过滤器一条都没匹配上。
    if COMPILE_DIAG_RE.search(raw) or not BUILD_OK_RE.search(raw):
        return "invalid(变异体编译不过)"
    return "invalid(过滤器一条都没跑到)"


def failing(raw: str) -> list[str]:
    out = []
    for line in raw.splitlines():
        s = line.strip()
        if s.startswith("✘") and "Test " in s:
            m = re.match(r"^✘ Test (.+?)\(\)", s)
            if m:
                out.append(m.group(1))
    return sorted(set(out))


MAIN = ROOT / "Package.swift"
TOOL = ROOT / "Tools/gen_l10n_tool/Package.swift"
TESTS = ROOT / "Tests/SafeOutAppTests/DeploymentTargetTests.swift"
V14 = "platforms: [.macOS(.v14)],"
V13 = "platforms: [.macOS(.v13)],"
V15 = "platforms: [.macOS(.v15)],"

# (名字, [(文件, old, new), ...], 期望判定)
MUTATIONS = [
    (
        "M1 【编译器挡】只降主包、工具包不动 ⇒ SwiftPM 自己报平台版本冲突",
        [(MAIN, V14, V13)],
        "invalid(变异体编译不过)",
    ),
    (
        "M2 【编译器挡】两个 Package.swift 一起降回 13 ⇒ 源码里的 14-only API 报错",
        [(MAIN, V14, V13), (TOOL, V14, V13)],
        "invalid(变异体编译不过)",
    ),
    (
        "M3 README hero 行改成 13+（文档一致 + 负向扫两轴）",
        [(ROOT / "README.md", "macOS 14+ · SwiftUI", "macOS 13+ · SwiftUI")],
        "red",
    ),
    (
        "M4 build_app.sh 的 plist 写死 13.0（派生那一轴）",
        [(ROOT / "build_app.sh", "<string>$DEPLOY_TARGET</string>", "<string>13.0</string>")],
        "red",
    ),
    (
        "M5 白名单指向一个不再出现的串（白名单自证那一轴）",
        [(TESTS, "别写「macOS 15+ / 26+」", "ZZZ_NOPE_ZZZ")],
        "red",
    ),
    (
        "M6 排除表里去掉 Design/（负向扫范围那一轴）",
        [(TESTS, '        "Design/",\n', "")],
        "red",
    ),
    (
        "M7 真升级到 15 但不动文档 ⇒ 必须逼着改齐",
        [(MAIN, V14, V15), (TOOL, V14, V15)],
        "red",
    ),
    (
        "M8 锚点措辞被改写（SPEC.md 去掉 ** 加粗）⇒ 必须判红，不许静默失效",
        [(ROOT / "SPEC.md",
          "| 最低系统版本 | **macOS 14.0+**（Sonoma",
          "| 最低系统版本 | macOS 14.0+（Sonoma")],
        "red",
    ),
    (
        "M9 阴性对照：与版本号无关的改动必须仍绿",
        [(ROOT / "Sources/Views/GlassViews.swift",
          "（macOS 14+ 的 SwiftUI 默认行为）",
          "（macOS 14+ 的 SwiftUI 默认行为，本仓记过）")],
        "green",
    ),
]


def main() -> int:
    print("=" * 72)
    print("基线自证：什么都不改必须绿（基线红的话，后面的红说明不了任何事）")
    print("=" * 72)
    code, raw = run_tests()
    verdict = classify(code, raw)
    print(f"   基线判定：{verdict}（退出码 {code}）")
    if verdict != "green":
        print(raw[-3000:])
        print("❌ 基线不是绿的 —— 本次结论作废")
        return 1

    results = []
    for name, edits, expect in MUTATIONS:
        print()
        print("=" * 72)
        print(f"{name}    [期望 {expect}]")
        print("=" * 72)
        restore_all()

        failed_landing = False
        for path, old, new in edits:
            ensure_backup(path)
            before = path.read_text(encoding="utf-8")
            if before.count(old) != 1:
                print(f"   ❌ {path.name}: 锚点出现 {before.count(old)} 次（要恰好 1 次）—— 没落地，作废")
                failed_landing = True
                break
            path.write_text(before.replace(old, new), encoding="utf-8")
            modified.append(path)
            landed = subprocess.run(["cmp", "-s", str(path), str(BACKUPS[path])]).returncode != 0
            print(f"   落地自证 {path.relative_to(ROOT)}: 与备份不同 = {landed}")
            for line in path.read_text(encoding="utf-8").splitlines():
                if new and new in line:
                    print(f"     变异后的那一行 → {line.strip()[:110]}")
                    break
            if not landed:
                print(f"   ❌ {path.name} 改完与备份逐字节相同 —— 变异没生效，作废")
                failed_landing = True
                break
        if failed_landing:
            results.append((name, expect, "invalid(没落地)"))
            continue

        code, raw = run_tests()
        verdict = classify(code, raw)
        print(f"   判定：{verdict}（退出码 {code}）")
        print("   ── 原始输出尾部 ──")
        for line in raw.strip().splitlines()[-10:]:
            print(f"      {line}")
        reds = failing(raw)
        if reds:
            print(f"   失败的测试（{len(reds)} 条）：")
            for t in reds:
                print(f"      · {t}")
        results.append((name, expect, verdict))

    print()
    print("=" * 72)
    print("还原与校验")
    print("=" * 72)
    restore_all()

    # 备份名唯一性（第一版就是栽在这里）。
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
