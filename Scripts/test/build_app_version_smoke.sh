#!/usr/bin/env bash
# =============================================================
# 冒烟：`build_app.sh` 的**版本派生**三档 ——
# **「没有 git」与「有 git 但它不干活」必须分开处理。**
#
# 【为什么必须有这条门】
# 2026-09-21 实测：`/usr/bin/git` 是 `xcrun` 桩（Xcode 许可未接受）⇒ 跑起来只打印
# 许可警告、**零输出、退出码 0**。`build_app.sh` 的四个 `git_*` 函数原先都是
# `… 2>/dev/null || true` ⇒ **静默**产出一个自称
#
#     VERSION=1.0.0 · BUILD_NUMBER=1 · commit=unknown · dirty=0
#
# 的包，而且因为 `dirty=0` 而**一条告警都不打**。`dirty=0` 尤其糟：它的意思是
# 「**工作区干净**」，而真相是「**不知道**」—— Swift 侧 `AppVersionInfo.dirtyCount`
# 的注释早就写明「不要拿 `0` 代替缺失 —— 「干净」与「不知道」是两回事」。
# ⇒ 生产者（本脚本）在撒谎，而消费者（设置窗口）已经写对了。
#
# 【判据为什么是「三档」而不是「一条」】
# 只断言「坏 git 时退出码非 0」会**误伤**一个**有意支持**的用法：从 tarball 构建
# （机器上根本没有 git）。⇒ 必须把两种「取不到版本信息」分开：
#
#   ① 有可用 git、HEAD 读得到          ⇒ 正常，往下走
#   ② 连 git 的痕迹都没有              ⇒ **容忍**（tarball），版本写「未知」
#   ③ 有 git 的痕迹，但一份都跑不起来  ⇒ **硬报错**，除非显式给了 VERSION+BUILD_NUMBER
#
# ②③ 在**旧代码的输出上逐字相同**（都是 `1.0.0 / unknown / dirty=0`）——
# 这正是本仓库最贵的那个坑：**「没有」与「有但没用」分不开**。
#
# 【装置怎么做到「不真的构建、不碰 Dist/」】
# 往 PATH 最前放一个假 `swift`，它打印一句自证后 `exit 97`。`build_app.sh` 的
# 版本派生（第 84–166 行）在 `swift build`（第 299 行）与 `rm -rf "$APP_BUNDLE"`
# （第 305 行）**之前** ⇒ 四档用例全都在构建处停下，产物目录一个字节都不动。
# ⚠️ 每条用例都断言输出里**有**那句「[假 swift]」：否则「在构建处停下」与
#    「因为别的原因（缺 Package.swift 之类）提前退出」在退出码上可能撞车。
#
# 【用法】Scripts/test/build_app_version_smoke.sh
# 退出码：0 = 通过；1 = 未通过。
# =============================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_APP="$REPO_ROOT/build_app.sh"
HEADLESS_GIT="$REPO_ROOT/Scripts/test/fake-git-headless/git"

for f in "$BUILD_APP" "$HEADLESS_GIT"; do
    if [ ! -f "$f" ]; then
        echo "   ✗ 装置坏了：找不到 $f"
        exit 1
    fi
done

TMP="$(mktemp -d -t build-app-version-smoke)"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/out.txt"
ST=0

FAILS=0
fail() {
    echo "   ✗ $1"
    FAILS=$((FAILS + 1))
}

# ---- 造装置 ----
# ① 能干活的假 git：五个调用点各给一个确定的答案（与真仓库状态无关 ⇒ 用例确定）
mkdir -p "$TMP/goodbin"
cat > "$TMP/goodbin/git" <<'SH'
#!/bin/bash
case "${1:-}" in
    rev-parse)
        case "${2:-}" in
            --git-dir) echo ".git" ;;
            --short)   echo "a1b2c3d" ;;
            --short=*) echo "a1b2c3d" ;;
            *)         : ;;
        esac
        ;;
    rev-list) echo "42" ;;          # rev-list --count HEAD
    describe) echo "v1.2.3" ;;      # describe --tags --abbrev=0
    status)   : ;;                  # 干净工作区 ⇒ 零输出
    *)        : ;;
esac
exit 0
SH
# ② 许可桩的坏法：**存在、可执行、退出码 0、stdout 零字节**
#    ⚠️ 三个「看起来能判」的手段全废：`[ -x ]` 真、`command -v` 找得到、退出码 0。
#    文案写 **stderr**、stdout 留空 —— 与真 `/usr/bin/git`（xcrun 桩）实测一致。
cat > "$TMP/license-stub" <<'SH'
#!/bin/bash
echo "You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license'." >&2
exit 0
SH
# ③ 假 swift：在构建处停下（**不真构建、不碰 Dist/**）
mkdir -p "$TMP/bin"
cat > "$TMP/bin/swift" <<'SH'
#!/bin/bash
echo "   [假 swift] 拦住了构建（本冒烟不真的构建，也不碰 Dist/）" >&2
exit 97
SH
chmod +x "$TMP/goodbin/git" "$TMP/license-stub" "$TMP/bin/swift"

# ---- 装置自证：三样都在、且**跑起来的行为**就是上面说的那样 ----
# 否则下面「判红/判绿」可能只是因为装置没造出来（与「判据生效」逐字相同）。
for f in "$TMP/goodbin/git" "$TMP/license-stub" "$TMP/bin/swift"; do
    if [ ! -x "$f" ]; then
        echo "   ✗ 装置坏了：$f 不存在或不可执行 ⇒ 本次结论作废"
        exit 1
    fi
done
echo "   [自证] 装置已就位（${TMP}）"
echo "   [自证] 假 swift 的退出码：$("$TMP/bin/swift" >/dev/null 2>&1; echo $?)（期望 97）"
echo "   [自证] 许可桩的退出码：$("$TMP/license-stub" >/dev/null 2>&1; echo $?)（⚠️ 是 0 ⇒ 退出码判不出来）"
echo "   [自证] 许可桩 stdout 字节数：$("$TMP/license-stub" 2>/dev/null | wc -c | tr -d ' ')（⚠️ 是 0 ⇒ stdout 也判不出来）"
echo "   [自证] 许可桩 stderr 首行：$("$TMP/license-stub" 2>&1 >/dev/null | head -1)"

# ---- 统一的调用与断言 ----
# 用法：invoke <FIND_GIT_ONLY 的值|-> <额外 env 参数...>
invoke() {
    local only="$1"
    shift
    local envargs=(-u VERSION -u BUILD_NUMBER -u STRICT_CI -u FIND_GIT_ONLY -u DISABLE_SANDBOX)
    if [ "$only" != "-" ]; then
        envargs+=("FIND_GIT_ONLY=$only")
    fi
    set +e
    env "${envargs[@]}" "$@" "$BUILD_APP" >"$OUT" 2>&1
    ST=$?
    set -e
}
expect_status() {
    if [ "$ST" -eq "$1" ]; then
        echo "   [状态] $2 → 退出码 $ST ✓"
    else
        # ⚠️ `${ST}` 必须带花括号：`$ST` 紧跟**全角括号**时，bash 3.2 在 UTF-8 locale 下
        #    会把那个括号算进变量名 ⇒ `set -u` 报 `unbound variable`（变量名里多了它的字节）。
        #    本机 locale 是 C 所以**永远不红**，CI 设了 `LC_ALL=en_US.UTF-8` 就炸。
        #    实测（2026-09-21，同一脚本两种 locale 各跑一遍）：这种写法在 C 下正常、
        #    在 `en_US.UTF-8` 下报错；而**位置参数** `$1` 紧跟全角括号**两种都安全**
        #    （位置参数不会被延长）⇒ 守卫 `ToolingClaimTests` 只管具名变量是对的。
        #    ⚠️ 写这段注释时**自己也踩了一次**：守卫连**注释**一起扫，把坏例子原样写进来
        #    照样算违规（第一版就写成 `$ST` 紧跟括号，当场判红）—— 例子要隔开写。
        fail "$2 → 退出码 ${ST}（期望 $1）"
    fi
}
expect_has() {
    if grep -qF -- "$1" "$OUT"; then
        echo "   [输出] 含「$1」✓"
    else
        fail "$2 的输出里**没有**「$1」"
    fi
}
expect_not_has() {
    if grep -qF -- "$1" "$OUT"; then
        fail "$2 的输出里**出现了不该出现的**「$1」"
    else
        echo "   [输出] 不含「$1」✓"
    fi
}
# 每条「应该走到构建处」的用例都要求输出里有那句自证 —— 否则退出码可能撞车。
# ⚠️ **只在能过版本门的用例上用**（①③⑤）；②④ 是硬报错档，**本来就该在构建前退出**，
#    对它们用这条会误判（实测踩过：第一版把 `expect_reached_build` 加到了 ② 上）。
expect_reached_build() {
    expect_has "[假 swift]" "$1"
}
# 硬报错档的对应自证：**必须没走到**自证行 ⇒ 证明是在版本门处退的，不是别处。
expect_blocked_before_build() {
    expect_not_has "ⓘ 版本派生" "$1"
    expect_not_has "[假 swift]" "$1"
}
dump_out() {
    echo "   ── 实际输出（尾部 12 行）──"
    tail -12 "$OUT" | sed 's/^/      /'
}

# =============================================================
# ① 阳性：有可用 git ⇒ 版本派生正常、无报错
# =============================================================
echo ""
echo "① 有可用 git（自造 good-git 排在 PATH 最前）"
invoke - PATH="$TMP/goodbin:$TMP/bin:$PATH"
expect_reached_build "①"
expect_status 97 "①"
expect_has "ⓘ 版本派生" "①"
expect_has "提交=a1b2c3d" "①"
expect_has "提交数=42" "①"
expect_has "未提交=0" "①"
expect_not_has "错误：" "①"
# ⚠️ 部署目标是**派生**的（从 `Package.swift` 的 `platforms`）⇒ 这里只断言
#    「**派生这条路是通的**」：输出里有那一行，且没走「取不到部署目标」的硬报错分支。
#    **不在这里写死具体版本号** —— 「值是多少」由
#    `Tests/SafeOutAppTests/DeploymentTargetTests.swift` 钉；这里再写一份
#    就又多了一处会漂的声明（本脚本要守的正是「同一件事写两处」这个病）。
expect_has "ⓘ 部署目标：" "①"
expect_not_has "取不到部署目标" "①"
if [ "$FAILS" -gt 0 ]; then dump_out; fi

# =============================================================
# ② 阴性 A：**有可用 git，但它取不到 HEAD** ⇒ 硬报错
#    （用本仓库既有的 `fake-git-headless`：能过 `git_usable` 的探针，其余零输出）
# =============================================================
echo ""
echo "② 有 git、但取不到 HEAD（fake-git-headless）"
BEFORE_FAILS="$FAILS"
invoke "$HEADLESS_GIT" PATH="$TMP/bin:$PATH"
expect_status 1 "②"
expect_has "取不到 HEAD" "②"
expect_has "拒绝产出包" "②"
expect_blocked_before_build "②"
if [ "$FAILS" -gt "$BEFORE_FAILS" ]; then dump_out; fi

# =============================================================
# ③ 排除档：同样的坏 git，但**显式指定** VERSION + BUILD_NUMBER ⇒ 允许继续
#    （这是硬报错里承诺的逃生门；没有它，「拒绝产出包」会变成死路）
# =============================================================
echo ""
echo "③ 坏 git + 显式 VERSION/BUILD_NUMBER（逃生门）"
BEFORE_FAILS="$FAILS"
invoke "$HEADLESS_GIT" PATH="$TMP/bin:$PATH" VERSION=9.9.9 BUILD_NUMBER=7
expect_reached_build "③"
expect_status 97 "③"
expect_has "已显式指定" "③"
expect_not_has "拒绝产出包" "③"
if [ "$FAILS" -gt "$BEFORE_FAILS" ]; then dump_out; fi

# =============================================================
# ④ 阴性 B：**有 git 的痕迹，但一份都跑不起来** ⇒ 也是环境坏了，同样硬报错
#    ⚠️ 这一档与 ② 是**两条不同的路**：② 是 GIT_AVAILABLE=1，这一档是
#       GIT_AVAILABLE=0 且 GIT_UNUSABLE_FOUND=1。旧代码在两者上都静默。
# =============================================================
echo ""
echo "④ 有 git 的痕迹、但一份都跑不起来（许可桩）"
BEFORE_FAILS="$FAILS"
invoke "$TMP/license-stub" PATH="$TMP/bin:$PATH"
expect_status 1 "④"
expect_has "跑不起来" "④"
expect_has "拒绝产出包" "④"
expect_blocked_before_build "④"
if [ "$FAILS" -gt "$BEFORE_FAILS" ]; then dump_out; fi

# =============================================================
# ⑤ tarball 档：**连 git 的痕迹都没有** ⇒ 有意支持，必须**容忍**
#    ⚠️ 这一档是 ④ 的反向守卫：没有它，「硬报错」很容易被写成「一律报错」，
#       而那就把「从 tarball 构建」这个支持的用法一起打死了。
# =============================================================
echo ""
echo "⑤ 连 git 的痕迹都没有（tarball 构建）⇒ 必须容忍"
BEFORE_FAILS="$FAILS"
invoke "$TMP/ghost-git-does-not-exist" PATH="$TMP/bin:$PATH"
expect_reached_build "⑤"
expect_status 97 "⑤"
expect_has "（无可用 git）" "⑤"
# ⚠️ 这条断言读的是自证行里的 `BUILD_DIRTY`（**将要写进 Info.plist 的那个值**）。
#    它守的是「**不知道**不许被写成 `0`」—— `0` 的意思是「工作区干净」，
#    而这里真相是「连 git 都没有，无从知道」。Swift 侧 `AppVersionInfo.dirtyCount`
#    的注释早就写明这条；本脚本是生产端的对应守卫。
expect_has "未提交=未知" "⑤"
expect_not_has "工作区有" "⑤"
expect_not_has "错误：" "⑤"
if [ "$FAILS" -gt "$BEFORE_FAILS" ]; then dump_out; fi

# =============================================================
# ⑥ 产物自证：整个冒烟**一个字节都不该动 Dist/**
# =============================================================
echo ""
echo "⑥ Dist/ 未被本次冒烟触碰"
if [ -e "$REPO_ROOT/Dist/SafeOut.app" ]; then
    echo "   [产物] Dist/SafeOut.app 仍在（本脚本只读不写）✓"
else
    echo "   [产物] Dist/SafeOut.app 不存在（本来就没构建过）—— 不算失败"
fi

if [ "$FAILS" -gt 0 ]; then
    echo ""
    echo "   ✗ 未通过（$FAILS 条）"
    exit 1
fi
echo ""
echo "   ✓ 通过：三档分开了 —— 好 git 正常派生；有 git 不干活（两条路）都硬报错；"
echo "     连 git 都没有（tarball）容忍并写「未知」；且「不知道」不会被写成 0"
