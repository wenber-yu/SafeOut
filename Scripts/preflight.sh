#!/usr/bin/env bash
# =============================================================
# SafeOut — CI 严格门槛本地预检
#
# 【为什么需要这个脚本】
# CI 在普通 `swift build` 之外还加了更严的门槛，其中最早的两道是：
#   1. `-Xswiftc -warnings-as-errors`（零警告构建，捕获 Swift 6 并发隔离问题）
#   2. `swift-format lint --strict`（格式零违规；扫描范围见 `FORMAT_SCOPE`
#      —— 那是唯一真相，门槛命令与「一键修复」提示都读它）
# 而这两道**不在 build_app.sh 的执行路径上**——build_app.sh 用的是不带该
# flag 的 `swift build -c release`。于是本地打包一路绿灯、CI 却红。
# 本项目曾因此让 13 条 Swift 6 并发错误潜伏三天（详见 SPEC.md §6.4）。
#
# 本脚本是**全部门槛的唯一实现**：本地与 CI 调用同一个文件，杜绝两侧逻辑分叉。
# ⚠️ **别在任何活文件里写死「N 道门槛」**（`run.sh` / `build_app.sh` / CI 工作流都栽过：
#    门槛一路在加，而那几处一直停在**最开始那个数字**上，
#    读的人据此**低估了检查范围**（`run.sh` 曾让人以为 `check` 只做构建 + 格式）。
#    要清单就跑一次 `./run.sh check` —— 它逐道打印标题，那份输出才是权威。
#
# 【用法】
#   ./Scripts/preflight.sh                 # 构建（警告视为错误）+ 格式检查
#   ./Scripts/preflight.sh --with-tests    # 额外跑测试与覆盖率门槛
#   COVERAGE_MIN=45 ./Scripts/preflight.sh --with-tests   # 自定义覆盖率门槛
#   DISABLE_SANDBOX=1 ./Scripts/preflight.sh               # 受管环境：跳过 SwiftPM 沙盒
#                                                          # （报 sandbox_apply 失败时用）
#
# 【退出码】
#   0 全部门槛通过；1 至少一道未通过（逐道打印）；2 参数错误。
#   即使前面已失败，也会把剩余门槛跑完再汇总，一次看到全部问题。
# =============================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 仓库根 == SPM 包根
PACKAGE_DIR="$REPO_ROOT"
FORMAT_CONFIG="$REPO_ROOT/.swift-format"
# ---------------------------------------------------------------
# 格式门的**扫描范围**（相对仓库根）—— **一处真相**：门槛 2 的命令与文件末尾
# 「格式问题一键修复」提示都读这一份，改范围只需改这里（此前是两处手写清单，
# 一处补齐了另一处没补）。
#
# ⚠️ **「范围」也是判据**（2026-09-24 实测补上）：原来只传 Sources + Tests，
# 于是 `Package.swift`、`Plugins/`、`Tools/` 下的 Swift **整批在门外** ——
# 实测那 7 个文件里 **5 个共 39 处违规**（TrailingComma / OrderedImports /
# Spacing / AddLines / Indentation / LineLength / DoNotUseSemicolons），
# 而**没有任何东西会红**。已全部格式化，并把范围补齐。
# ⇒ 以后**新增顶层含 Swift 的目录**，这里要跟着加，否则同样的洞再开一次。
# 变异证明（2026-09-24）：往 `Tools/probe/` 塞一个格式坏文件 ⇒ 本命令 rc=1；
# 移除 ⇒ rc=0。即补上范围后**确实扫到了**，不是摆设。
FORMAT_SCOPE=(Sources Tests Package.swift Plugins Tools)
FORMAT_PATHS=()
for _scope in "${FORMAT_SCOPE[@]}"; do FORMAT_PATHS+=("$PACKAGE_DIR/$_scope"); done
COVERAGE_MIN="${COVERAGE_MIN:-40}"

# ⚠️ **runner 级变量：本地必须和 CI 设成同一个值**（2026-09-21 新增）。
#
# 起因：CI 顶层 `env:` 设了 `LC_ALL: en_US.UTF-8`，而**本地没人设** ——
# 本机 `locale` 是 `LC_COLLATE=C`（`LANG` 为空）⇒ 本地门槛跑在**另一个 shell locale** 下。
#
# 以前这是靠**手动**补的：`1f611d9` 的提交正文写着「门槛 11/11 通过（本地 LC_ALL=en_US.UTF-8）」
# —— 也就是说「本地门槛 = CI 门槛」这条承诺，**靠人记得在命令行前面加那一段**。
# 忘了加（2026-09-21 本轮就忘了一次）就悄悄降级，而**两边都不报错**。
# 真出过事：`b530f68`（§8.108.1）—— bash 3.2 在 UTF-8 locale 下会把紧跟变量名的
# **全角括号**算进变量名 ⇒ `set -u` 报 unbound；本机 locale 是 C 所以**永远不红**。
#
# ⚠️ **别把它当成「能复现 CI 的文案类断言失败」**：`LC_ALL` **不会改变 `Locale.current`**
# （CI 自己在 ci.yml 里实测过：设了它，`Locale.current` 仍是 `zh_CN`）。
# 那 76 次连红走的是 **Swift 侧 `Locale.current`** 那条轴，与这里**不是同一件事**，别混。
#
# ⚠️ 为什么以前没有任何东西拦住它：`LC_ALL` 的消费者是 runner 本身（不是某个脚本里的
# `${VAR:-默认}`），所以它被 `GateParityTests.runnerLevelEnv` **白名单化**，
# 而白名单同时把它排除在两条既有检查之外 ⇒ 「本地这侧设了吗」从来没人查。
# 现在由 `GateParityTests.门槛必须把CI的runner级变量设成同一个值` 钉住。
#
# ⚠️ 这里**无条件设**（不写 `${LC_ALL:-…}`）：写默认值的话，谁在 shell 里预置一个别的
# `LC_ALL`，本地就悄悄退回「与 CI 不同环境」—— 而那正是本条要防的。
# 要做 locale 判别实验时，在**具体命令前**临时覆盖（同 `Scripts/test/test_timings_smoke.sh`）。
export LC_ALL="en_US.UTF-8"

# DISABLE_SANDBOX=1：跳过 SwiftPM 自带的 sandbox-exec。
# 受管执行环境自身已在一层沙箱内时，嵌套 sandbox-exec 会报
# "sandbox_apply: Operation not permitted" 并让构建失败（与代码无关）。
# 仅影响构建期隔离，不改变检查结论；CI 不应设置此变量。
SWIFT_SANDBOX_FLAGS=()
if [ "${DISABLE_SANDBOX:-0}" = "1" ]; then
    echo "ⓘ DISABLE_SANDBOX=1：swift build 将跳过 SwiftPM 沙盒（仅供受管环境使用）"
    SWIFT_SANDBOX_FLAGS+=(--disable-sandbox)
fi

WITH_TESTS=0
for arg in "$@"; do
    case "$arg" in
        --with-tests) WITH_TESTS=1 ;;
        -h | --help)
            sed -n '3,23p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "未知参数：${arg}" >&2
            echo "用法：./Scripts/preflight.sh [--with-tests]" >&2
            exit 2
            ;;
    esac
done

if [ ! -f "$PACKAGE_DIR/Package.swift" ]; then
    echo "错误：找不到 $PACKAGE_DIR/Package.swift" >&2
    exit 1
fi

LOG="$(mktemp -t diskejector-preflight)"
trap 'rm -f "$LOG"' EXIT

# ⚠️ 门槛失败时，把**全量**日志另存到持久目录 `.build/preflight/门槛N.log`。
#
# 为什么必须留（2026-09-20）：门槛曾红在「415 个测试里 1 个 issue」，而**失败测试的
# 名字没拿到** —— `$LOG` 被上面的 `trap` 删了、回显又只有尾部 30 行。那次之后
# 「下次要落盘再 grep」只写在「仍开着」表里，**没有任何机制保证它发生** ⇒
# 能不能拿到名字，取决于人事前有没有设 `PREFLIGHT_FAIL_TAIL=0`。
# 留一份持久副本 ⇒ 事后追查**不依赖**当时的环境变量。`.build/` 已被 gitignore。
KEEP_DIR="$REPO_ROOT/.build/preflight"
mkdir -p "$KEEP_DIR"
# ⚠️ **必须 export**（2026-09-23，账本 #51）：`coverage.sh` 从环境变量里**派生**
#    自己那份测试全量日志的落点，从而与这里**同一处**（不另写一份路径 ⇒ 不会漂）。
#    不 export 的话，它会退回自己的默认值 —— 两边各写一个目录，正是「同一事实
#    写两处」那个病。单独跑 `coverage.sh` 时没有这个变量 ⇒ 才走默认值那一支。
export KEEP_DIR

FAILED=0
GATE_NO=0

# 门槛执行与「失败报告」抽在 `Scripts/lib/gate_report.sh` —— 抽出来的唯一目的是让它
# **有行为测试**（`Scripts/test/gate_report_smoke.sh` 直接 source 它、喂一个必失败的
# 假门槛，几毫秒验完）。留在 preflight.sh 里就只剩源码文本断言，而那种断言守得住
# 「那行还在」，守不住「改坏了但还在」。
#
# ⚠️ `FAIL_TAIL` 由 `gate_report.sh` 自己从 `PREFLIGHT_FAIL_TAIL` 派生（与「按值分支」
#    那一支同文件 —— 见那边注释）。这里只提供 LOG / KEEP_DIR 两个变量。
source "$REPO_ROOT/Scripts/lib/gate_report.sh"

echo "SafeOut 预检（仓库：${REPO_ROOT}）"

# ---------------------------------------------------------------
# 门槛 1：构建（警告视为错误）
# 覆盖 Swift 6 严格并发下的 actor-isolation 问题——这类问题在默认构建里只是
# 警告，只有加了该 flag 才会让构建失败。
#
# **`--build-tests` 不可省**：不加它时编译的只有 **App 目标**，测试目标不在门内。
# 2026-09-17 实际踩到：`KeySilentWindowTests` 里有一条 `#expect(alert is NSPanel)`
# —— `alert` 的静态类型就是 `EjectAlertPanel`，编译器判定该表达式**恒真**
# （`-warnings-as-errors` 下报 `'is' test is always true`），
# 而它在测试目标里，门槛 1 一直看不见；同时 `swift test` 不把这个警告当错误，
# 于是这条**没有牙的断言**活了很久。与 §6.4 那 13 条并发错误是同一个病根：
# **门槛的覆盖面比它声称的窄**。谁再把 `--build-tests` 去掉，这条就回来。
# ---------------------------------------------------------------
run_gate "构建（-Xswiftc -warnings-as-errors，含测试目标）" \
    swift build --package-path "$PACKAGE_DIR" --build-tests -Xswiftc -warnings-as-errors \
    ${SWIFT_SANDBOX_FLAGS[@]+"${SWIFT_SANDBOX_FLAGS[@]}"} \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 门槛 2：swift-format 严格格式检查
# **--strict 不可省**：swift-format lint 默认即使发现问题也返回 0，不加它形同虚设。
# 显式传 --configuration：脚本可能从任意工作目录被调用，不能依赖自动发现。
# 扫描范围读文件头的 `FORMAT_SCOPE`（唯一真相）—— 别在这里再抄一份清单。
# ---------------------------------------------------------------
GATE2_TITLE="格式检查（swift-format lint --strict）"
# ⚠️ 2026-09-21：下面那句「格式问题一键修复」**曾经无条件打印**
# （只要有任一门槛红就打）⇒ 门槛 6 红的那次，我照它去查格式门，
# 白跑了 3 次 `swift-format lint`（全绿）才反应过来名字是假的。
# ⇒ 单独记一个 `GATE2_FAILED`，那条提示只在格式门**真的**红时才出现。
GATE2_FAILED=0
if [ ! -f "$FORMAT_CONFIG" ]; then
    gate_header "$GATE2_TITLE"
    echo "   ✗ 缺少配置文件 ${FORMAT_CONFIG}" >&2
    FAILED=$((FAILED + 1))
    GATE2_FAILED=1
elif ! xcrun --find swift-format >/dev/null 2>&1; then
    gate_header "$GATE2_TITLE"
    echo "   ✗ 未找到 swift-format（随 Xcode 工具链提供，请确认已安装 Xcode）" >&2
    FAILED=$((FAILED + 1))
    GATE2_FAILED=1
else
    run_gate "$GATE2_TITLE" \
        xcrun swift-format lint --strict \
        --configuration "$FORMAT_CONFIG" \
        --recursive \
        "${FORMAT_PATHS[@]}" \
        || { FAILED=$((FAILED + 1)); GATE2_FAILED=1; }
fi

# ---------------------------------------------------------------
# 门槛 3：注释里的「承诺句」必须带日期
# 覆盖一类**编译与测试都看不见**的错误：代码是对的、注释是错的。
# 2026-09-20 一轮里修掉 4 处（§8.88），其中「应用自身还不检查更新」挂着而
# Sparkle 早已接好 —— 读的人会照着错的注释做决策。
#
# ⚠️ **判据是「标了承诺就必须写日期」，不是「关键词出现就报警」**：
# 用 `尚未|还没` 这类泛词实测 33 处命中只有 ~3 处是真问题（precision ≈ 9%），
# 那种扫描器一定会被关掉。详见 Scripts/scan_stale_comments.sh 的文件头。
#
# 放在测试**之前**：它只要几秒，而门槛里最贵的失败应该最先暴露。
# ---------------------------------------------------------------
run_gate "注释承诺句（标了未核实/TODO/已知限制就必须带日期）" \
    "$REPO_ROOT/Scripts/scan_stale_comments.sh" \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 门槛 4：脚本冒烟（`run.sh ci` 的几条关键路径）
# 覆盖一类**只有网络抖动时才出现**的失败路径：`Scripts/ci_status.sh` 曾把
# 「查询失败」当成「一个空 run」，并报出**方向完全错**的诊断（§8.107）。
# 用假 `gh`（`Scripts/test/fake-gh/gh`）把那条路径变成**确定性样本**。
#
# ⚠️ **`--offline` 不可省**：不带它时冒烟脚本会去打 GitHub API（十几秒，且随网络抖动），
# 让一道**与网络无关**的门槛自己变成 flaky —— 那正是「门槛会自己烂掉」的来源。
# 它同时是**判据必须有人执行**的落点：这个冒烟脚本 2026-09-20 造出来时
# 没有任何东西跑它（`Scripts/test/` 下 0 个消费者），等于白写。
#
# 放在测试**之前**：它只要几秒，而门槛里最贵的失败应该最先暴露。
# ---------------------------------------------------------------
run_gate "脚本冒烟（ci_status.sh 的确定性用例，不碰网络）" \
    "$REPO_ROOT/Scripts/test/ci_status_smoke.sh" --offline \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 门槛 5：门槛**自己**的失败报告（`Scripts/lib/gate_report.sh`）
# 守「门槛红的时候能不能拿到失败项的名字 + 全量日志有没有留住」。
# 2026-09-20 之前这件事只是一条写在「仍开着」表里的建议 ⇒ 真红了一次却不知道
# 红的是谁，至今追不回来（`trap` 删了临时日志，回显又只有尾部 30 行）。
#
# ⚠️ 为什么它必须有行为测试而不是源码文本断言：文本断言守得住「那行还在」，
# 守不住「改坏了但还在」。⇒ `run_gate` 抽进 `Scripts/lib/` 就是为了能被 source。
# ---------------------------------------------------------------
run_gate "门槛失败报告（红时要给出失败项的名字并留住全量日志）" \
    "$REPO_ROOT/Scripts/test/gate_report_smoke.sh" \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 脚本冒烟：测试耗时名单（`Scripts/lib/test_timings.sh`）
#
# 守「最慢 N 条」这个诊断输出：它认得**真实**日志格式（两种名字写法）、
# 排序是**数值**降序、不把汇总行当成一条测试、且**locale 无关**。
#
# ⚠️ 最后那条不是凑数：本机 locale 未设（等价 C）、CI 设 `LC_ALL=en_US.UTF-8`
# （见 .github/workflows/ci.yml）⇒ 用 `[✔✘]` 这种多字节字符类实现的话，
# 本地一条都解析不出来、CI 完全正常 —— 方向与「本地绿 CI 红」相反，更难发现。
#
# 放在测试**之前**：它只要几十毫秒，而门槛里最贵的失败应该最先暴露。
# ---------------------------------------------------------------
run_gate "测试耗时名单（swift test 日志 → 最慢 N 条，locale 无关）" \
    "$REPO_ROOT/Scripts/test/test_timings_smoke.sh" \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 脚本冒烟：覆盖率收尾输出的**布局**（`Scripts/lib/coverage_tail.sh`）
#
# 守「最慢名单能不能被看见」：门槛 6 由 `run_gate` 执行，**成功时只回显最后
# 3 行** ⇒ 名单排在第四行就等于白打。而这件事**源码文本断言守不住**
# （只能证明「那行还在」，证明不了「它在最后 3 行里」）⇒ 冒烟**真调函数、
# 真做一次 `tail -3`**。
#
# 它同时守两件容易忘的事：① `✅ 覆盖率达标` 不能被新加的诊断行挤出那 3 行；
# ② `coverage.sh` **真的**调用收尾函数且条数写对（拆掉接线时函数照样好、
# 冒烟照样绿，而功能没了）。
#
# ⚠️ 变异脚本（手动跑，不进门槛）：`Scripts/test/test_timings_mutation.py`
# ---------------------------------------------------------------
run_gate "覆盖率收尾输出的布局（最慢名单必须落在门槛回显的 3 行内）" \
    "$REPO_ROOT/Scripts/test/coverage_tail_smoke.sh" \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 脚本冒烟：时间线打点装置（`Tools/probe/stamp_lines.py`）
#
# 守「打点时刻是**事件时刻**、不是**冲刷时刻**」这条契约。
#
# 为什么它必须有一条门：这个装置是「这轮测试卡在哪个时间窗 / 谁占住了串行资源」
# 的**唯一**观测手段（`passed after` 与 `--xunit-output` 给的都是**完成时刻**，
# 见 `Scripts/lib/test_timings.sh` 抬头）。而它一坏，坏法**看起来像一条真发现**：
# 子进程 stdout 变成块缓冲时，所有事件挤在同一时刻 —— 那个形状与「成批完成」
# **逐字相同**。2026-09-21 第一版就是这么死的（8 条测试的 9 行结果全打在 `0.000s`）。
#
# 判据是**一对正负对照**，缺一不可：伪终端版必须拿到行间隔（阳性），
# 同一个子进程走朴素管道必须**塌掉**（阴性）。只有阳性的话，
# 「子进程本来就会逐行冲刷」的实现也能通过 —— 而那时伪终端这个**唯一的机关**是多余的，
# 门就失去了分辨力。变异验证（2026-09-21 手动跑）：把 `pty.openpty()` 换成
# `subprocess.PIPE` ⇒ 阳性对照塌成 0.000 ⇒ 门判红。
#
# 放在测试**之前**：它只要约 1.3 秒，而门槛里最贵的失败应该最先暴露。
# ---------------------------------------------------------------
run_gate "时间线打点（伪终端拿到事件间隔、朴素管道必须塌掉）" \
    "$REPO_ROOT/Scripts/test/stamp_lines_smoke.sh" \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 脚本冒烟：`Scripts/lib/find_git.sh`（判「git 跑不跑得起来」只能靠**试跑**）
#
# 守的契约：`git_usable` 必须**真的跑一次**候选，而不是看存在性 / 可执行位 / 退出码。
#
# 为什么它必须有一条门：本环境 `/usr/bin/git` **存在且可执行**、退出码 0，
# 但它是 `xcrun` 桩（Xcode 许可未接受）⇒ 只打印许可警告、**没有输出**。
# 2026-09-21 实测的后果：`ci_status.sh` 的三处 `git rev-parse` 静默拿到空串，
# 回显成「等提交␣␣的 run 出现」（短号位置是空的）—— **看起来像「run 还没创建」**。
# 而 `gh` 内部也要调 `git`（`failed to determine base repo: failed to run git`），
# 所以修 git 必须排在 gh 之前、并把它放进 PATH。
#
# 判据是**一对正负**（缺一不可）：自造一个「能干活的假 git」必须判为可用（阳性），
# 另两个「存在、可执行、退出码 0 但不干活」的桩必须判为不可用（阴性）——
# 只有阳性的话，`git_usable() { [ -x "$1" ]; }` 这种实现**同样通过**，
# 而那正是本次要修掉的坏法。
# 变异验证（2026-09-21 手动跑）：把判据换成 `[ -x "$1" ]` ⇒ 阴性对照塌掉 ⇒ 门判红。
#
# ⚠️ 它**不依赖本机有没有可用的 git**（正负对照全是自造的假 git）；
# 只有最后一条端到端用例需要真 git，找不到时判红并说清 —— 与
# `stamp_lines_smoke.sh` 找不到 python3 时同款，**不许静默通过**。
# ---------------------------------------------------------------
run_gate "git 判据（必须试跑：坏桩不许被判成可用）" \
    "$REPO_ROOT/Scripts/test/find_git_smoke.sh" \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 脚本冒烟：`build_app.sh` 的版本派生**三档**（同一病根的第二处消费者）
#
# 守的契约：**「没有 git」与「有 git 但它不干活」必须分开处理**。
#   ① 有可用 git、HEAD 读得到          ⇒ 正常派生
#   ② 连 git 的痕迹都没有（tarball）    ⇒ **容忍**，版本写「未知」
#   ③ 有 git 的痕迹、但一份都跑不起来    ⇒ **硬报错**，除非显式给了 VERSION+BUILD_NUMBER
#
# 为什么它必须有一条门（2026-09-21）：`build_app.sh` 原先的四个 `git_*` 函数都是
# `… 2>/dev/null || true` ⇒ 坏 git 下**静默**产出 `1.0.0 / 1 / unknown / dirty=0`
# 的包，且因 `dirty=0` 而**一条告警都不打**。`dirty=0` 的意思是「工作区干净」，
# 而真相是「不知道」—— Swift 侧 `AppVersionInfo.dirtyCount` 的注释早就写明
# 「不要拿 0 代替缺失」。⇒ 生产者在撒谎，而消费者已经写对了。
#
# ⚠️ ②③ 在**旧代码的输出上逐字相同**（都是 `1.0.0 / unknown / dirty=0`）——
# 只断言「坏 git 时退出码非 0」会**误伤** tarball 这个有意支持的用法。
# 所以判据是**三档**，其中 ⑤ 是 ④ 的**反向守卫**（没有它，「硬报错」很容易被
# 写成「一律报错」）。
#
# 变异验证（2026-09-21 手动跑，三条，都判红）：
#   a. 把判定块整块替换回旧行为（`VERSION_UNTRUSTED_REASON=""`）⇒ 判红 11 条；
#   b. 移除 `find_git.sh` 的 `GIT_UNUSABLE_FOUND` 信号 ⇒ 判红 5 条，且**只有 ④**；
#   c. `BUILD_DIRTY="${GIT_DIRTY}"` → `"${GIT_DIRTY:-0}"` ⇒ 判红 1 条，**只有 ⑤**
#      （dump 出的原始输出正是现场：`未提交=0`，生产者在撒谎）。
#
# ⚠️ 装置**不真构建、不碰 `Dist/`**：往 PATH 最前放一个假 `swift`（`exit 97`），
# 而版本派生在 `swift build` 与 `rm -rf "$APP_BUNDLE"` **之前** ⇒ 全部用例都在
# 构建处停下。每条用例还断言输出里有那句假 `swift` 的自证 —— 否则「在构建处停下」
# 与「因为别的原因提前退出」在退出码上可能撞车。
# ---------------------------------------------------------------
run_gate "build_app.sh 版本派生（没有 git ≠ 有 git 但不干活）" \
    "$REPO_ROOT/Scripts/test/build_app_version_smoke.sh" \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 脚本冒烟：dmg 安装窗口的布局资产（`Scripts/test/dmg_layout_smoke.sh`）
#
# 守「安装窗口长什么样」这件事的**四处同源**：两个源常量（背景图脚本 / 布局脚本）
# + 两个入库的生成物（`Resources/dmg/background.png`、`Resources/dmg/DS_Store`）。
#
# 为什么它必须有一条门：这四处任何一处漂了，症状都是「**箭头指歪 / 背景图被裁 /
# 文案是旧的**」，而**四处都不报错** —— 打包一路绿灯，用户下载到的 dmg 却是坏的。
# 而 `.DS_Store` 是 **Finder 的私有格式**，人眼没法 review，只能靠机器比对。
#
# 两条判据是**踩过坑才有的**（详见该脚本的文件头）：
#   · ⑥ 的判据是「`create_dmg` 里有 `cp` 这两个资产的命令」，**不是**「变量名出现过」
#     —— 后者会被同函数里的一句 `[ -f "$VAR" ]` 存在性检查放过去（判据恒真）。
#   · ⑧ 比对背景图**自带的出处块**（PNG 的 `iTXt`）：② 只比像素尺寸，
#     于是「改了文案却忘了重跑生成脚本」查不出来 —— 2026-09-24 真的发生过。
#   · ⑦ 用与 `create_dmg` 同一串旗标真造一个小 dmg、真挂载、按字节比对，
#     并配阴性样本（不放资产 ⇒ 卷里必须没有）。`hdiutil` 带不带点文件**只能实测**。
#
# ⚠️ 变异脚本（**手动跑，不进门槛**）：`Scripts/test/dmg_layout_mutation.py`（10 条）。
#    本轮实测抓到两处「判据恒真」的坏法，都是靠它发现的。
#
# ⚠️ **它不快**：实测 **13–17 秒**（两次小 dmg 的建/挂/卸；`hdiutil create` 每次约 4 秒
#    —— 就这么点数据也一样，是**固定开销**，换 `-format UDRW` 只省 1 秒，而旗标必须与
#    `create_dmg` 一致才叫测同一个东西）。
#    仍然放在测试**之前**：它比测试便宜一个数量级，而门槛里最贵的失败应该最先暴露。
# ---------------------------------------------------------------
run_gate "dmg 安装窗口布局（四处同源 + 出处块 + 打包链路真带得进卷）" \
    "$REPO_ROOT/Scripts/test/dmg_layout_smoke.sh" \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 环境脚本自检：`Tools/clt_swift_env.sh` 被 **`set -e` 的调用方** source 时
# 不许**静默死掉**（`Scripts/test/clt_swift_env_smoke.sh`）。
#
# 守的是一条**看起来像噪音**的代码：`_probe="$(…)" || true` 末尾那三个词。
# 摘掉它，本机（Xcode 许可未接受 ⇒ `xcrun` 退出码 **69**，而 `xcodebuild -version`
# 在同状态下退出码是 0 —— 两个命令的结论不能互相套用）**立刻静默死**：
# 零输出、退出码 69，连 shim 自己的自证行都打不出来。症状与
# 「脚本根本没被 source」「环境更烂了」**逐字相同**。
# 而 **CI（许可正常）摘掉它也照样绿** ⇒ 只有本机能发现，且发现时症状指向别处。
#
# ⚠️ **为什么放在这里而不是最前**：本文件虽然自己就是 `set -euo pipefail`，
#    但它**不 source** 这个 shim（工具链由调用方在跑门槛之前就配好了）⇒
#    shim 坏掉并不会让前面的门失败，所以「放最前」换不来 fail-fast。
#    放最前反而会让**后面所有门的编号漂 1**，而注释里到处引用了编号
#    （「门槛 1：构建」「门槛 2 的范围」「门槛 6 红的那次」）—— 那才是真代价。
#
# ⚠️ 该脚本自带**双向对照**（合成一个好 shim / 一个复刻失败形态的坏 shim）：
#    坏 shim 若被判成「通过」⇒ 直接判**装置没牙**，不当作「代码没问题」。
# ---------------------------------------------------------------
run_gate "环境脚本自检（\`set -e\` 的调用方 source 后不许静默死）" \
    "$REPO_ROOT/Scripts/test/clt_swift_env_smoke.sh" \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 发版脚本自检（`Scripts/release.sh` 的纯函数 + 双向对照）
#
# 守三件**只有脚本自己知道**的事：版本号按日期推导（同日补丁 +1、数字前缀不许误匹配）、
# 发布说明四条硬规则（做错了界面上看不出来）、资产名与 appcast enclosure 末段逐字相同
# （改名 = 用户点「安装更新」404，而 appcast 不报错）。
#
# ⚠️ **为什么必须有这道门**：2026-09-28 之前 `Scripts/test/` 下的装置没人跑
# （`ci_status_smoke.sh` 就是那样白写的）。这道门是「判据有人执行」的落点。
#
# ⚠️ **为什么放在这里而不是最前**：同上（放最前会让后面所有编号漂 1，而注释里到处
# 引用编号）。它只要一秒，也换不来多少 fail-fast。
#
# ⚠️ 放在测试**之前**的另一个理由：它不碰网络也不改仓库，是纯函数 ——
# 一旦它红了，修起来比「测试红」便宜两个数量级。
# ---------------------------------------------------------------
run_gate "发版脚本自检（版本号推导 / 说明格式 / 资产名三处纯函数）" \
    "$REPO_ROOT/Scripts/release.sh" self-test \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 测试 + 覆盖率（可选）
# 复用 Scripts/coverage.sh，避免门槛口径写两份。
#
# ⚠️ **跑门槛时不要同时改文件**：构建中会编辑源文件 ⇒ 编译器报
# `input file ... was modified during the build`，门槛红而**与代码无关**
# （2026-09-20 实测复现）。症状与 flaky 测试**逐字相同**，极易误判。
#
# ⚠️ 变异脚本（**手动跑，不进门槛**）：`Scripts/test/settings_section_nav_mutation.py`（6 条）。
#    守的是两栏设置面板左栏的 ↑/↓ 分类导航 —— 那条守卫被拆成两半：**算术**（纯函数断言）
#    与**接线**（扫源码断言，因为 `swift test` 里既没有窗口也没有可信的方向键注入）。
#    六条变异体刻意**都不是「崩掉」而是「答错」**：下标越界崩溃会让进程半途死掉、
#    打不出 `Test run with N tests` 那一行，于是只能判 `invalid`，证据白丢。
# ---------------------------------------------------------------
if [ "$WITH_TESTS" = "1" ]; then
    run_gate "测试与覆盖率（≥${COVERAGE_MIN}%）" \
        "$REPO_ROOT/Scripts/coverage.sh" "$COVERAGE_MIN" \
        || FAILED=$((FAILED + 1))
fi

echo ""
echo "=================================================="
if [ "$FAILED" = "0" ]; then
    echo " ✅ ${GATE_NO} 道门槛全部通过"
    if [ "$WITH_TESTS" = "0" ]; then
        echo "    （加 --with-tests 可一并跑测试与覆盖率）"
    fi
else
    # ⚠️ **别再无条件打印「格式问题一键修复」**（2026-09-21）：它曾让我把
    # 门槛 6 的红当成格式门去查。**失败门的名字**在上方 `✗ 未通过` 那一行里
    # （`▶ 门槛 N` 的编号），全量日志在 `.build/preflight/门槛N.log`
    # —— 那份日志**只在失败时**落盘，且不清理旧的 ⇒ 用 mtime 认是哪一轮。
    # ⚠️ 别在这行里用反引号引记号（2026-09-21 实测）：双引号里的 `` `✗ 未通过` ``
    # 会被 bash 当**命令替换**执行 ⇒ 打出 `line N: ✗: command not found`、
    # 而 echo 照常输出（只是内容缺了一块）⇒ 错误不明显但信息是错的。
    echo " ✗ 有 ${FAILED} 道门槛未通过（失败门的名字见上方各 ▶ 门槛 N 行）"
    if [ "$GATE2_FAILED" = "1" ]; then
        echo "   格式问题一键修复（范围与门槛 2 同源，见文件头 FORMAT_SCOPE）："
        echo "     cd \"$PACKAGE_DIR\" && xcrun swift-format format --in-place --recursive \\"
        echo "       --configuration \"$FORMAT_CONFIG\" ${FORMAT_SCOPE[*]}"
    fi
fi
echo "=================================================="

[ "$FAILED" = "0" ]
