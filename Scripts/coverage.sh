#!/usr/bin/env bash
#
# 测试覆盖率门槛。
#
# 用法：
#   ./Scripts/coverage.sh            # 使用默认门槛（见 DEFAULT_MIN 常量）
#   ./Scripts/coverage.sh 45         # 指定门槛（百分比整数）
#   DISABLE_SANDBOX=1 ./Scripts/coverage.sh   # 受管环境：跳过 SwiftPM 沙盒
#                                             # （报 sandbox_apply 失败时用）
#
# 统计口径：只统计「核心逻辑」——Models / Services / Settings。
# **为什么排除 Views 与 App 入口**：SwiftUI 视图与 NSApplication 委托几乎无法在
# 单元测试中真实驱动（需要宿主 App、runloop、窗口服务器），把它们计入分母会得到
# 一个被 UI 代码体量主导、对改进不敏感的数字。门槛的意义是防止核心逻辑的测试
# 被悄悄删掉，而不是追求一个漂亮的百分比。
#
# 排除范围是 **`Sources/SafeOutApp/` 整个目录**，而不是逐个文件列：
# 该目录是 AppKit 应用装配层（AppDelegate + MainMenu）。原先只排除了
# `SafeOutApp.swift` 一个文件，导致 2026-09-12 新增 `MainMenu.swift` 后
# 147 行无人测试的菜单构造代码混进分母，覆盖率从 62.5% 稀释到 56.7% ——
# 一个纯粹的记账噪音，掩盖了真实的核心逻辑覆盖率。按目录排除对后续新增文件免疫。

set -euo pipefail

DEFAULT_MIN=40
MIN_COVERAGE="${1:-$DEFAULT_MIN}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 仓库根 == SPM 包根
PACKAGE_DIR="$REPO_ROOT"

cd "$PACKAGE_DIR"

# DISABLE_SANDBOX=1：跳过 SwiftPM 自带的 sandbox-exec（受管环境嵌套沙箱会失败）。
# 仅影响构建期隔离，不改变测试与覆盖率结果；CI 不应设置此变量。
SWIFT_SANDBOX_FLAGS=()
if [ "${DISABLE_SANDBOX:-0}" = "1" ]; then
    SWIFT_SANDBOX_FLAGS+=(--disable-sandbox)
fi

echo "▶ 运行测试（启用覆盖率采集）..."
# 测试输出先落日志、按结果决定回显多少：
# 原先写成 `swift test ... | tail -3`，成功时省事，但**失败时只剩最后 3 行**，
# CI 上看到的就只有 `56 tests in 9 suites failed with 4 issues` 这一句，
# 4 个失败的具体断言全被吞掉，排查只能靠猜（本项目 2026-09-12 实际踩过）。
# 顺带也绕开了 `cmd | tail` 让 `$?` 变成 tail 状态的老坑——这里靠 pipefail 兜底，
# 但用日志文件表达意图更明确。
#
# ⚠️⚠️ **这份日志必须持久化**（2026-09-23，账本 #51）：
# 它原来写成 `mktemp` + `trap 'rm -f "$TEST_LOG"' EXIT`，**跑完即删** ⇒ 门槛
# **成功**时只剩回显的最后 3 行（行覆盖率 / 最慢 3 条 / ✅ 达标），**逐条
# `passed after` 一行都留不下**。而 CI 日志里连那 3 行的来源都没有 ——
# 实测 `gh api .../logs` 的 zip 解开只有 298 行、`passed after` **0 条** ⇒
# 「CI 上那条测试到底快了多少」**根本量不到**（§8.135 就栽在这上面，
# 最后只能把**本地**数写进文档冒充 CI 数）。
# ⇒ 直接写进门槛的持久日志目录 —— 与 `preflight.sh` 的 `KEEP_DIR` **同一处**
#   （由它 export 下来；单独跑本脚本时退回 `$REPO_ROOT/.build/preflight`），
#   再由 ci.yml 当 artifact 上传 ⇒ `./run.sh ci --logs` 拿得到全量。
TEST_LOG_DIR="${KEEP_DIR:-$REPO_ROOT/.build/preflight}"
mkdir -p "$TEST_LOG_DIR"
TEST_LOG="$TEST_LOG_DIR/测试全量.log"
echo "   测试全量日志：${TEST_LOG#$PWD/}（跑完**不删** —— 逐条耗时只在这里）"

if ! swift test --enable-code-coverage \
    ${SWIFT_SANDBOX_FLAGS[@]+"${SWIFT_SANDBOX_FLAGS[@]}"} > "$TEST_LOG" 2>&1; then
    echo "   ✗ 测试未通过，完整输出如下："
    sed 's/^/     /' "$TEST_LOG"
    exit 1
fi
sed 's/^/     /' "$TEST_LOG" | tail -3

# 不同 Swift 版本的构建产物路径不同（.build/debug 或 .build/<triple>/debug），
# 因此用 find 定位而不是硬编码。
#
# **`-perm -111` 而不是 `-perm +111`**：`+111`（"任一执行位"）是已废弃的旧写法，
# 当前 macOS 自带的 find 直接报 `find: bad mode '+111'` 并返回空 ——
# 而这里带 `2>/dev/null || true`，错误被吞掉后只剩一个空字符串，
# 表面症状是「找不到覆盖率产物」，实际与覆盖率毫无关系（2026-09-15 踩到）。
# `-111`（"三个执行位都要有"）语义清晰且被所有版本接受。
# 这个 `-perm` 不只是过滤可执行文件：`.dSYM` 子目录也嵌在 `Contents/MacOS/` 下，
# 不加它会把 DWARF 调试文件当成测试二进制。
#
# ⚠️ **2026-09-19 修**：这里原来写的是 `-print -quit`（取 find 返回的第一份）。
# `.build/` 里可能同时存在**多份** `default.profdata` —— 例如某个覆盖率取证探针留下的
# `.build/cov-forensics/{now,base}/default.profdata`。而 find 的返回顺序是**稳定**的，
# 于是门槛会**一直**读那一份陈旧的：
#   - 行数 / 未覆盖行数来自**二进制**（这部分是准的）；
#   - 但**命中计数**来自那份陈旧 profdata ⇒ 它里面没有的函数被读成 0 命中
#     ⇒ **覆盖率被系统性低估**，而输出看起来完全正常。
# 实测（同一份二进制）：新鲜 profdata 报 64.38%，陈旧那份报 63.61% —— **差 0.77pp、零警告**。
# 修法：取**最新改动**的那一份（`swift test --enable-code-coverage` 刚刚写过它）。
PROFDATA="$(find .build -name 'default.profdata' -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1)"

# ⚠️ **2026-09-24 修**：这里原来写的是 `*PackageTests.xctest/Contents/MacOS/*`，
# 那是**原生**构建系统的命名（测试二进制叫 `<包名>PackageTests`）。
# SwiftPM 6.4（本机与 CI 同一支）**默认走 SwiftBuild 构建系统**，产物落在
#     .build/out/Products/Debug/SafeOutAppTests.xctest/Contents/MacOS/SafeOutAppTests
# （`.build/debug` 只是指向上面那层的**软链**，`find` 默认不穿透软链目录）。
# 那个模式在新布局下**一条都匹配不到** ⇒ BINARY 为空 ⇒ 报「找不到覆盖率产物」，
# 而**测试本身 489 条全绿** —— 症状与「覆盖率真掉了」逐字相同。
#
# 为什么能藏这么久：`.build/` 里还留着旧原生构建的那份 `PackageTests` 二进制，
# `find` 一直读的是那份**陈旧**的（profdata 比它新，自证二也过了）。
# 2026-09-24 清 `.build` 旧产物（2.3G → 107M）之后才第一次红。
# ⇒ 改成「按形状找、取最新一份」：不再依赖任一构建系统的命名习惯。
BINARY="$(find .build -path '*.xctest/Contents/MacOS/*' -type f -perm -111 -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1)"

if [[ -z "$PROFDATA" || -z "$BINARY" ]]; then
    echo "✗ 找不到覆盖率产物（profdata='$PROFDATA', binary='$BINARY'）" >&2
    exit 1
fi

# **自证一：打印用的是哪一份。** 「读到了陈旧数据」与「覆盖率真的掉了」在报告里
# 逐字相同 —— 不打印路径，下一次的人根本无从分辨。
# **二进制同样要打印**：2026-09-24 那次红门就是二进制匹配不到（不是数字掉了），
# 而报错里只打了 `binary=''` 空串 —— 看的人第一反应是「覆盖率没了」。
echo "   覆盖率数据：${PROFDATA#$PWD/}（$(date -r "$PROFDATA" '+%Y-%m-%d %H:%M:%S')）"
echo "   测试二进制：${BINARY#$PWD/}（$(date -r "$BINARY" '+%Y-%m-%d %H:%M:%S')）"

# **自证二：profdata 必须不比二进制旧。** `swift test` 的顺序是「先构建、再跑、最后写
# profdata」，所以正常情况 profdata 一定更新。若它更旧，说明读到了上一次（或某个探针）
# 留下的东西 —— 这时候下面所有数字都是假的，宁可红。
if [[ "$PROFDATA" -ot "$BINARY" ]]; then
    echo "✗ 覆盖率数据（${PROFDATA#$PWD/}）比测试二进制还旧 —— 读到了陈旧数据，数字不可信" >&2
    exit 1
fi

echo
echo "▶ 核心逻辑覆盖率（排除 Views/ 与 App 入口）..."
REPORT="$(xcrun llvm-cov report "$BINARY" \
    -instr-profile "$PROFDATA" \
    -ignore-filename-regex='\.build|/Tests/|Views/|Sources/SafeOutApp/')"

echo "$REPORT"

# TOTAL 行第 10 列为行覆盖率（Filename Regions MissedRegions Cover Functions
# MissedFunctions Executed Lines MissedLines Cover ...）
LINE_COVER="$(echo "$REPORT" | awk '/^TOTAL/ {print $10}')"

if [[ -z "$LINE_COVER" ]]; then
    echo "✗ 未能从覆盖率报告中提取 TOTAL 行" >&2
    exit 1
fi

PERCENT="${LINE_COVER%\%}"
echo
echo "   行覆盖率: $LINE_COVER   门槛: ${MIN_COVERAGE}%"

# ---------------------------------------------------------------
# 最慢的几条测试（**诊断信息，不是判据**）。
#
# 为什么需要：测试输出只落 `TEST_LOG`，而门槛成功时只回显最后 3 行 ⇒
# 想在**回显里**看见耗时，只能靠这里补一条名单。2026-09-21「本地 <1s /
# CI 57.1s」那组数字来自一次**红**跑，之后想再看就得再造一次失败。
# （⚠️ 2026-09-23 起 `TEST_LOG` 已持久化到 `.build/preflight/测试全量.log`，
#   **全量**耗时不必再造失败了 —— 但**回显**仍然只有这几行，所以这条摘要照留。
#   「回显」与「落盘」是两条不同的路，别互相替代：CI 上看的是回显，
#   事后取证看的是落盘那份。）
#
# ⚠️ **口径（别把这个数字当成该测试自身的耗时）**：`passed after X seconds`
#    是「完成时刻距 run 开始」的墙钟，测试并行执行 ⇒ 早开始晚结束的那条会把
#    整轮时长算进去。实测 `.build/preflight/门槛6.log`（2026-09-21 10:40 本机）：
#    最慢单条 22.030 秒 vs 汇总行 `Test run with 442 tests ... failed after
#    22.032 seconds` —— **单条值 ≈ 整轮值**。详见 `Scripts/lib/test_timings.sh`。
#
# ⚠️ **位置不能动**：门槛 6 由 `run_gate` 执行，成功时只回显**最后 3 行**
#    （`Scripts/lib/gate_report.sh` 的 `tail -3`）。这里的三行是
#    「行覆盖率 / 最慢名单 / ✅ 覆盖率达标」—— 放到更前面等于白打。
#    `Scripts/test/coverage_tail_smoke.sh` 会**真做一次 `tail -3`** 守这件事。
#
# 解析不到时**只警告、不返回非 0** —— 它是诊断输出不是判据；让「测试全绿但
# swift 改了输出格式」把门槛判红，与覆盖率毫无关系（「门槛会自己烂掉」的源头）。
# 可见性由自证字段 `［耗时行 N/M］` 提供：格式一变 N 会塌成 0 而 M 不变。
# ---------------------------------------------------------------
source "$REPO_ROOT/Scripts/lib/coverage_tail.sh"

# awk 做浮点比较，避免依赖 bc
if awk -v c="$PERCENT" -v m="$MIN_COVERAGE" 'BEGIN { exit !(c >= m) }'; then
    coverage_success_tail "$TEST_LOG" 3
    exit 0
else
    echo "✗ 覆盖率未达标：当前 ${LINE_COVER} < 门槛 ${MIN_COVERAGE}%" >&2
    echo "  提示：若为新增未覆盖代码，请补充测试；" >&2
    echo "        若确属难以测试的代码，请调整门槛并在提交信息中说明理由。" >&2
    exit 1
fi
