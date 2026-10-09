#!/bin/bash
# =============================================================
# SafeOut — 发版一条命令
#
# 用法（从仓库根跑）：
#   ./run.sh release                          # 全流程
#   ./run.sh release --dry-run                # 只预演：打印每一步，不产生任何外部效果
#   ./run.sh release --notes-file <路径>       # 指定发布说明
#   ./run.sh release --message "…"             # 工作区有未提交改动时，用它做提交信息
#   ./run.sh release --message-file <路径>     # 同上，从文件读（多行推荐这个）
#   ./run.sh release --version 2026.09.29.1    # 显式指定版本（默认按日期推导）
#   ./run.sh release --skip-gate               # 跳过门槛（**只给刚跑过的人用**）
#   Scripts/release.sh self-test               # 装置自证（纯函数，不碰网络、不改仓库）
#
# ## 它做的十一件事，每一步都幂等 —— 中断后重跑同一条命令即可接着走
#
#   1. 门槛           ./run.sh check --with-tests
#   2. 提交业务改动    只在有未提交改动时做；message **必须由你给**（见下「动态」）
#   3. 发布说明就绪    Release-notes/<版本>.html 不存在 ⇒ 从上一个 tag 生成**草稿**并停下
#   4. 提交发布说明
#   5. 打 tag         **先打 tag 再构建**（版本号派生自 tag）
#   6. 构建           STRICT_CI=1 PACKAGE=1，输出到全新目录
#   7. 推送 master + tag
#   8. 生成 appcast    make_appcast.sh（它的 enclosure / 资产名 / 内嵌说明三处回读全在里面）
#   9. 创建 Release    正式版；资产名与 appcast enclosure 末段**逐字相同**
#  10. 提交 appcast.xml 并推送（SUFeedURL 读的是它的 raw 地址，推完才生效）
#  11. 回下载对 sha256
#
# ## 「动态」体现在哪（这是本脚本的设计核心，别改成写死）
#
#   · **版本号**按日期推导：`vYYYY.MM.DD[.N]`，同一天再发就 N+1（今天已有 .1/.2 ⇒ 下次 .3）。
#     也可用 `--version` 覆盖。
#   · **发布说明**是**面向用户**的文案，机器编不出可信的 —— 所以脚本只做两件事：
#     找到它（`--notes-file` / `Release-notes/<版本>.html`），或**从上一个 tag 到 HEAD 的
#     commit 标题生成草稿**让你改。**它不会自己编然后发出去。**
#   · **两个 release 提交的信息**从发布说明的**第一条内容**动态提取，
#     不由脚本写死一句话（写死的话，三个月后没人知道某个版本改了什么）。
#
# ## 三条来自实发事故的硬约束（别在这里"优化"掉）
#
#   ⚠️ **push 不写死「直连」或「代理」**：两条路都踩过 —— v2026.09.28.2 时代理 TLS
#      握手超时、直连通；v2026.09.29 时直连 github.com 超时、代理通。所以 ``git_push``
#      先直连、失败再回落到仓库代理，见 ``git_push``。
#   ⚠️ **先打 tag 再构建**：版本号派生自 `git describe`，顺序反了产物带的是**上一个**版本号，
#      而构建会成功、校验也不会红。
#   ⚠️ **清输出目录用 `mv` 不用 `rm`**：`Dist/` 下上百个文件会触发批量删除确认，
#      `build_app.sh` 会停在 `[2/5]` —— 看起来像构建失败。见 ``prepare_output_dir``。
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="SafeOut"

# ---------------------------------------------------------------
# 纯函数区：self-test 直接调这一区，**不许碰 git / 网络 / 文件系统**
# （碰了就没法用合成输入做双向对照，守卫会退化成"看仓库当前长什么样"）
# ---------------------------------------------------------------

# 从「同一天已有的 tag 列表」推下一个版本号。`tags` 一行一个 tag 名（可含 `v` 前缀），空串=没有。
#
# 规则（对齐仓库历史 tag：v2026.09.18.2 / .3 / .4、v2026.09.23.1 …）：
#   · 这天一个都没有                        ⇒ `<day>`
#   · 只有裸 `<day>`（2026-04 那批的写法）   ⇒ `<day>.1`
#   · 已有 `<day>.<N>`                      ⇒ `<day>.<N+1>`（取最大的 N，不是个数）
#   · 只有旧命名的 `<day>-mvp2`              ⇒ `<day>.1`（**算这天动过**，但不给序号）
#
# ⚠️ **后面只许接「结尾 / `.` / `-`」** —— 不这样写会踩数字前缀陷阱：
#    `v2026.04.11` 会被当成 `2026.04.1` 那天的 tag（`2026.04.1` 是 `2026.04.11` 的前缀），
#    于是一个从没发过版的 4 月 1 日会被判成「已经发过」，直接跳到 `.1`。
next_version_from_tags() {
    local day="$1" tags="$2" t rest max=0 seen=0

    while IFS= read -r t; do
        [ -n "$t" ] || continue
        t="${t#v}"
        case "$t" in
            "$day") seen=1 ;;
            "$day".*)
                rest="${t#"$day".}"
                seen=1
                case "$rest" in
                    '' | *[!0-9]*) : ;; # 非纯数字后缀不参与计数（也不报错）
                    *) if [ "$rest" -gt "$max" ]; then max="$rest"; fi ;;
                esac
                ;;
            "$day"-*) seen=1 ;; # 旧命名（-mvp2 那批）
            *) continue ;;
        esac
    done <<EOF
$tags
EOF

    if [ "$seen" = "0" ]; then
        printf '%s\n' "$day"
    else
        printf '%s.%s\n' "$day" "$((max + 1))"
    fi
}

# 发布说明的格式校验（四条硬规则的机检部分，来自 Release-notes/README.md）。
# 通过 → 0；不通过 → 1 并把原因打到 stdout（调用方决定怎么报）。
#
# ⚠️ 这里是**给草稿和用户文件同一把尺子**：草稿也必须过，否则「脚本生成的草稿
# 自己就不合规」这种事会等到 make_appcast 才发现。
notes_violation() {
    local file="$1"
    [ -f "$file" ] || { printf '%s\n' "文件不存在：$file"; return 1; }

    # 规则 1：不许有 HTML 注释。解析器只剥尖括号对，注释正文会**原样进弹窗**。
    if grep -q '<!--' "$file"; then
        printf '%s\n' "含 HTML 注释（<!--）——解析器不认注释，注释正文会原样出现在更新弹窗里"
        return 1
    fi
    # 规则 2：不许有 DOCTYPE / <html> / <body>。含了就不会被内嵌进 <description>，
    # 而 user driver **只读内嵌的那份** ⇒ 弹窗里一行都不显示。
    if grep -qiE '<!doctype|<html|<body' "$file"; then
        printf '%s\n' "含 <!DOCTYPE> / <html> / <body> —— 这样内容不会被**内嵌**进 <description>，弹窗里什么都看不到"
        return 1
    fi
    # 规则 3：每条要用 <li> 包起来（解析器先按 <li> 断行再剥标签）。
    if ! grep -q '<li>' "$file"; then
        printf '%s\n' "没有任何 <li> —— 解析器按 <li>/<br> 断行，没有它们所有条目会粘成一行"
        return 1
    fi
    # 规则 4：条目**文字本身**不许以 ·/-/* 开头（弹窗自己会画 ·，会变成「· · 修复了…」）。
    #
    # ⚠️ **不能只查「行首」**：真实写法是 `<li>· 修复了甲</li>` —— 那一行的行首是 `<li>`，
    #    按行首查永远查不到（第一版就是这么写的，自检当场抓住：这条守卫是**假绿**）。
    #    ⇒ 先把每条 `<li>` 的**内容**取出来、剥掉行内标签与前导空白，再看第一个字符。
    local item
    while IFS= read -r item; do
        item="$(printf '%s' "$item" | sed 's/<[^>]*>//g' | sed 's/^[[:space:]]*//')"
        [ -n "$item" ] || continue
        case "$item" in
            '·'* | '*'* | '-'*)
                printf '%s\n' "有条目以 · / * / - 开头 —— 弹窗自己会画 ·，会变成「· · 修复了…」：$item"
                return 1
                ;;
        esac
    done <<EOF
$(sed -n 's/.*<li>\(.*\)<\/li>.*/\1/p' "$file")
EOF
    # 再兜一层：`<li>` 之外**自己起一行**写 · 或 * 的（解析器同样会读进去）
    if grep -q '^[[:space:]]*·' "$file" || grep -q '^[[:space:]]*\*' "$file"; then
        printf '%s\n' "有一行以 · 或 * 开头 —— 弹窗自己会画 ·，会变成「· · 修复了…」"
        return 1
    fi
    return 0
}

# 从发布说明里抽一句「摘要」，给两个 release 提交的信息用（**动态**，不写死）。
# 取第一条 <li> 的文本，剥标签、去掉开头那对 <strong>，截到 40 字。
#
# ⚠️ **截断必须看得出来是截断**：第一版直接 `cut -c 1-40`，commit message 变成
#    「…它只按上」—— 半个词挂在结尾，读的人会以为原文就那样（而且 `git log` 里
#    看不到全句，等于信息丢了还不知道丢了）。⇒ 真截断了就在末尾补一个「…」。
#    40 这个数是为了让 `git log --oneline` 一行放得下，不是拍脑袋。
notes_summary() {
    local file="$1" full
    full="$(sed -n 's/.*<li>\(.*\)<\/li>.*/\1/p' "$file" \
        | head -1 \
        | sed 's/<[^>]*>//g' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ "$(printf '%s' "$full" | wc -m | tr -d ' ')" -gt 40 ]; then
        printf '%s…\n' "$(printf '%s' "$full" | cut -c 1-40)"
    else
        printf '%s\n' "$full"
    fi
}

# 资产名与 appcast enclosure 末段是否逐字相同（改名 = 用户点「安装更新」时 404）。
# 参数：<enclosure url> <待上传文件路径>
asset_name_matches_enclosure() {
    local url="$1" asset="$2"
    [ "$(basename "$url")" = "$(basename "$asset")" ]
}



# ---------------------------------------------------------------
# 参数
# ---------------------------------------------------------------
DRY_RUN=0
SKIP_GATE=0
VERSION_OVERRIDE=""
NOTES_FILE=""
COMMIT_MESSAGE=""
COMMIT_MESSAGE_FILE=""

usage() {
    printf '%s\n' \
        '用法（从仓库根跑）：' \
        '  ./run.sh release                          # 全流程' \
        '  ./run.sh release --dry-run                # 只预演：打印每一步，不产生任何外部效果' \
        '  ./run.sh release --notes-file <路径>       # 指定发布说明' \
        '  ./run.sh release --message "…"             # 工作区有未提交改动时，用它做提交信息' \
        '  ./run.sh release --message-file <路径>     # 同上，从文件读（多行推荐这个）' \
        '  ./run.sh release --version 2026.09.29.1    # 显式指定版本（默认按日期推导）' \
        '  ./run.sh release --skip-gate               # 跳过门槛（只给刚跑过的人用）' \
        '  Scripts/release.sh self-test               # 装置自证（纯函数，不碰网络/仓库）' \
        '' \
        '十一个阶段、每一步都幂等：中断后重跑同一条命令即可接着走。'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --skip-gate) SKIP_GATE=1; shift ;;
        --version) VERSION_OVERRIDE="${2:-}"; shift 2 ;;
        --notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
        --message) COMMIT_MESSAGE="${2:-}"; shift 2 ;;
        --message-file) COMMIT_MESSAGE_FILE="${2:-}"; shift 2 ;;
        -h | --help) usage 0 ;;
        self-test)
            # 装置自证放在纯函数之后、任何副作用之前 —— 见文件末尾的实现
            SELFTEST_ONLY=1
            shift
            ;;
        *)
            echo "❌ 未知参数：$1" >&2
            usage 1
            ;;
    esac
done

# ---------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------
SELFTEST_ONLY="${SELFTEST_ONLY:-0}"

say() { printf '%s\n' "$*"; }
stage() { printf '\n▶ [%s/11] %s\n' "$1" "$2"; }
warn() { printf '   ⚠️  %s\n' "$*" >&2; }
fail() {
    printf '\n❌ %s\n' "$*" >&2
    exit 1
}

# 未提交改动数（含未跟踪）。⚠️ 不能用 `git status --porcelain | wc -l` 一把梭：
# git 失败时 `wc` 打出 0，与「工作区干净」**逐字相同**（本仓库在别处踩过多次）。
dirty_count() {
    local out
    if ! out="$(git -C "$PACKAGE_DIR" status --porcelain 2>/dev/null)"; then
        return 1
    fi
    if [ -z "$out" ]; then
        printf '0\n'
    else
        printf '%s\n' "$out" | wc -l | tr -d ' '
    fi
}

git_tag_exists() {
    git -C "$PACKAGE_DIR" rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1
}

# push 的网络策略：**直连与代理哪个通用哪个**，不写死。
#
# 历史教训（两条方向相反，都踩过）：
#   - v2026.09.28.2 发版时，`.git/config` 里 `http.proxy = 127.0.0.1:7890` 端口开着但
#     TLS 握手超时，**直连是通的** —— 那次必须绕过代理。
#   - v2026.09.29 发版时，情况反过来了：直连 github.com 超时（主站路由不通），
#     **走代理反而能通**。
# 所以唯一稳妥的做法是：先直连，失败（非零退出）再回落到仓库里那条代理。
# 代理地址从 `git config --get http.proxy` 现读，不写死（本机可能是任意端口）。
git_push() {
    local proxy
    proxy="$(git -C "$PACKAGE_DIR" config --get http.proxy 2>/dev/null || true)"

    # 第一招：直连。
    if run_or_echo git -C "$PACKAGE_DIR" -c http.proxy= -c https.proxy= push "$@"; then
        return 0
    fi
    say "   直连 push 失败 —— 回落到仓库代理（${proxy:-无}）重试"

    # 第二招：代理（若仓库里有配）。
    if [ -n "$proxy" ]; then
        run_or_echo git -C "$PACKAGE_DIR" -c http.proxy="$proxy" -c https.proxy="$proxy" push "$@" \
            || fail "push 失败（直连与代理都不通）"
        return 0
    fi

    fail "push 失败（直连不通，且仓库未配置代理）"
}

# dry-run 包装：只对**有外部副作用**的命令用它。只读命令（git status / log / gh view）照跑，
# 这样 dry-run 才能真正验证判据，而不是把所有东西都跳过。
#
# ⚠️ 打印时要**加引号**：`git commit -m chore: 发版脚本` 看起来像两个参数
# （`-m` 后面那个值没了引号），照着它去敲就是错的 ⇒ 含非常规字符的参数用单引号包起来。
run_or_echo() {
    if [ "$DRY_RUN" = "1" ]; then
        local out="" a
        for a in "$@"; do
            case "$a" in
                '' | *[!A-Za-z0-9_./:=@+-]*) out="$out '$a'" ;;
                *) out="$out $a" ;;
            esac
        done
        printf '   [dry-run]%s\n' "$out"
        return 0
    fi
    "$@"
}

# 确保输出目录是**全新的**。
#
# ⚠️ 旧的挪走而不是删：`Dist/` 下动辄上百个文件，批量删除会触发确认、把
# `build_app.sh` 卡在 `[2/5]`（看起来像构建失败）。挪走还有后路。
prepare_output_dir() {
    if [ -e "$OUTPUT_DIR" ]; then
        local stash="${TMPDIR:-/tmp}/de-release-$(basename "$OUTPUT_DIR").$(date +%s)"
        say "   （旧输出目录挪到 $stash —— 用 mv 不用 rm，理由见文件头）"
        mv "$OUTPUT_DIR" "$stash"
    fi
    mkdir -p "$OUTPUT_DIR"
}

# ---------------------------------------------------------------
# self-test：纯函数 + 双向对照（不碰网络、不改仓库）
# ---------------------------------------------------------------
selftest() {
    local fails=0
    check() { # <说明> <期望> <实际>
        if [ "$2" = "$3" ]; then
            printf '   ✓ %s\n' "$1"
        else
            printf '   ✘ %s（期望 %s，实得 %s）\n' "$1" "$2" "$3"
            fails=$((fails + 1))
        fi
    }

    printf '▶ 发版脚本自检（纯函数，不碰网络/仓库）\n'

    # ---- next_version_from_tags：三种历史形态 ----
    check "这天第一次发（无 tag）" "2026.09.28" "$(next_version_from_tags 2026.09.28 '')"
    check "只有裸日期 tag（2026-04 那批）" "2026.04.11.1" \
        "$(next_version_from_tags 2026.04.11 'v2026.04.11')"
    check "已有 .1" "2026.09.28.2" "$(next_version_from_tags 2026.09.28 'v2026.09.28.1')"
    check "已有 .1 .2（今天的真实形态）" "2026.09.28.3" \
        "$(next_version_from_tags 2026.09.28 'v2026.09.28.1
v2026.09.28.2')"
    check "取最大 N 而不是个数" "2026.09.18.5" \
        "$(next_version_from_tags 2026.09.18 'v2026.09.18.4
v2026.09.18.2')"
    check "别的日子的 tag 不参与计数" "2026.09.28.2" \
        "$(next_version_from_tags 2026.09.28 'v2026.09.23.1
v2026.09.28.1')"
    check "非数字后缀跳过（-mvp2 那批）" "2026.04.11.1" \
        "$(next_version_from_tags 2026.04.11 'v2026.04.11-mvp2')"
    check "裸日期与 .N 并存" "2026.04.11.2" \
        "$(next_version_from_tags 2026.04.11 'v2026.04.11
v2026.04.11.1')"
    # ⚠️ 数字前缀陷阱：`2026.04.1` 是 `2026.04.11` 的**前缀**。
    # 第一版没限制「后面只许接 结尾/./-」，于是 4 月 1 日会被判成「已经发过版」。
    check "数字前缀陷阱（2026.04.1 不许匹配 v2026.04.11）" "2026.04.1" \
        "$(next_version_from_tags 2026.04.1 'v2026.04.11')"
    check "数字前缀陷阱（2026.09.2 不许匹配 v2026.09.28.1）" "2026.09.2" \
        "$(next_version_from_tags 2026.09.2 'v2026.09.28.1')"

    # ---- notes_violation：四条硬规则，**双向对照**（好文件必须过、坏文件必须拦）----
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" EXIT

    printf '<ul>\n<li>修复了甲</li>\n<li>修复了乙</li>\n</ul>\n' >"$tmp/good.html"
    printf '<ul>\n<!-- 说明 -->\n<li>修复了甲</li>\n</ul>\n' >"$tmp/comment.html"
    printf '<!DOCTYPE html>\n<ul><li>修复了甲</li></ul>\n' >"$tmp/doctype.html"
    printf '<p>没有列表项</p>\n' >"$tmp/noli.html"
    printf '<ul>\n<li>· 修复了甲</li>\n</ul>\n' >"$tmp/bullet.html"

    if notes_violation "$tmp/good.html" >/dev/null; then
        printf '   ✓ 合法说明被接受（双向对照的正向）\n'
    else
        printf '   ✘ 合法说明被拦下了：%s\n' "$(notes_violation "$tmp/good.html")"
        fails=$((fails + 1))
    fi
    check "含 HTML 注释被拦" "1" "$(notes_violation "$tmp/comment.html" >/dev/null 2>&1 && echo 0 || echo 1)"
    check "含 DOCTYPE 被拦" "1" "$(notes_violation "$tmp/doctype.html" >/dev/null 2>&1 && echo 0 || echo 1)"
    check "没有 <li> 被拦" "1" "$(notes_violation "$tmp/noli.html" >/dev/null 2>&1 && echo 0 || echo 1)"
    check "行首自己画 · 被拦" "1" "$(notes_violation "$tmp/bullet.html" >/dev/null 2>&1 && echo 0 || echo 1)"
    check "文件不存在被拦" "1" "$(notes_violation "$tmp/nope.html" >/dev/null 2>&1 && echo 0 || echo 1)"

    # ---- notes_summary：从第一条 <li> 取摘要（动态提交信息靠它）----
    check "摘要取第一条并剥标签" "修复了甲" \
        "$(notes_summary "$tmp/good.html")"
    printf '<ul>\n<li><strong>重新打开应用时现在会真的检查更新</strong>：此前……</li>\n</ul>\n' >"$tmp/bold.html"
    check "摘要剥掉 <strong>" "重新打开应用时现在会真的检查更新：此前……" "$(notes_summary "$tmp/bold.html")"

    # 截断**必须在末尾看得出来**（否则 commit message 挂着半个词，读的人以为原文如此）
    printf '<ul>\n<li>这是一条明显超过四十个字的说明文字用来验证摘要在截断之后会不会于末尾补上省略号而不是把半个句子挂在结尾</li>\n</ul>\n' >"$tmp/long.html"
    local long_sum
    long_sum="$(notes_summary "$tmp/long.html")"
    check "摘要截断后长度是 41（40 字 + 省略号）" "41" "$(printf '%s' "$long_sum" | wc -m | tr -d ' ')"
    check "摘要被截断时末尾补「…」" "…" "${long_sum#"${long_sum%?}"}"
    check "短摘要**不许**加省略号" "修复了甲" "$(notes_summary "$tmp/good.html")"

    # ---- asset_name_matches_enclosure：改名即 404 ----
    check "资产名一致" "0" \
        "$(asset_name_matches_enclosure 'https://github.com/o/r/releases/download/v1.2.3/App-1.2.3.dmg' '/x/dist/updates/App-1.2.3.dmg' && echo 0 || echo 1)"
    check "资产名不一致（改名那个坑）" "1" \
        "$(asset_name_matches_enclosure 'https://github.com/o/r/releases/download/v1.2.3/App-1.2.3.dmg' '/x/dist/App.dmg' && echo 0 || echo 1)"

    # ⚠️ **两条 bash 语法陷阱不在这里查**（2026-09-28 先在这里各写了一份，后来才发现
    #    仓库已经有了）—— 权威在 `ToolingClaimTests`，它扫**所有**活文件、含注释、
    #    且认得 heredoc：
    #      · `活文件里双引号内不得有反引号`   —— 双引号里的反引号会被当命令替换执行
    #      · `活文件里变量引用不得紧跟多字节字符` —— bash 3.2 把全角字符算进变量名
    #    这里不重复实现：两份实现必然漂移，而那边的范围更大、也在 CI 上跑。
    rm -rf "$tmp"
    trap - EXIT

    if [ "$fails" -gt 0 ]; then
        printf '\n❌ 自检失败 %s 项\n' "$fails" >&2
        return 1
    fi
    printf '\n✅ 自检通过\n'
    return 0
}

if [ "$SELFTEST_ONLY" = "1" ]; then
    selftest
    exit $?
fi

# ---------------------------------------------------------------
# 0. 前置：工具 / 仓库状态 / 版本号
# ---------------------------------------------------------------
cd "$PACKAGE_DIR"

for tool in git gh curl shasum; do
    command -v "$tool" >/dev/null 2>&1 || fail "找不到 $tool"
done
[ -f "$PACKAGE_DIR/build_app.sh" ] || fail "找不到 build_app.sh —— 必须在仓库根跑"
[ -f "$PACKAGE_DIR/Scripts/make_appcast.sh" ] || fail "找不到 Scripts/make_appcast.sh"

TODAY="$(date +%Y.%m.%d)"

if [ -n "$VERSION_OVERRIDE" ]; then
    VERSION="${VERSION_OVERRIDE#v}"
    VERSION_SOURCE="--version 显式指定"
else
    # ⚠️ 取**同一天**的 tag 来推：跨天的 tag 不参与计数（规则见纯函数区）
    SAME_DAY_TAGS="$(git tag -l "v${TODAY}*" || true)"
    VERSION="$(next_version_from_tags "$TODAY" "$SAME_DAY_TAGS")"
    VERSION_SOURCE="按日期推导（同一天第 N 次发版，N 自动递增）"
fi
TAG="v$VERSION"

NOTES_DEFAULT="$PACKAGE_DIR/Release-notes/$VERSION.html"
OUTPUT_DIR="$PACKAGE_DIR/Dist/release-$VERSION"
UPDATES_DIR="$OUTPUT_DIR/updates"

say "=================================================="
say " SafeOut 发版"
say "=================================================="
say "  版本      ${VERSION}（${VERSION_SOURCE}）"
say "  tag       $TAG"
say "  发布说明   ${NOTES_FILE:-$NOTES_DEFAULT}"
say "  输出目录   $OUTPUT_DIR"
if [ "$DRY_RUN" = "1" ]; then
    say "  模式      **dry-run**（不产生任何外部效果；只读命令照跑，好让判据真的被验到）"
fi
say ""
say "  即将执行：门槛 → 提交 → tag → 构建 → push → appcast → Release → 提交 appcast → 对 sha256"
say "  中断了不要紧：**重跑同一条命令**即可接着走（每一步都幂等）。"
say "  Ctrl-C 现在就可以退出。"

# ---------------------------------------------------------------
# 1. 门槛
# ---------------------------------------------------------------
stage 1 "门槛"
if [ "$SKIP_GATE" = "1" ]; then
    warn "已跳过门槛（--skip-gate）—— 只在你刚跑过 ./run.sh check --with-tests 时这么用"
else
    if [ "$DRY_RUN" = "1" ]; then
        # ⚠️ 别写死「13 道」—— 门槛数会变（2026-09-28 加了发版脚本自检那道就漂过一次），
        #    写死的那个数三个月后就是**错的**，而它出现在发版前最显眼的一行里。
        say "   [dry-run] 会跑：./run.sh check --with-tests（门槛数随仓库变化）"
    else
        "$PACKAGE_DIR/run.sh" check --with-tests || fail "门槛没过 —— 先修，别发版"
    fi
fi

# ---------------------------------------------------------------
# 2. 提交业务改动（只在有未提交改动时；message 必须由你给）
# ---------------------------------------------------------------
stage 2 "提交业务改动"
DIRTY="$(dirty_count)" || fail "取不到 git status —— 先确认这是个干净的 git 仓库"
if [ "$DIRTY" = "0" ]; then
    say "   工作区干净 —— 跳过（改动早就提交过了）"
else
    say "   工作区有 $DIRTY 项未提交改动："
    git status --short | sed 's/^/     /'
    if [ -z "$COMMIT_MESSAGE" ] && [ -z "$COMMIT_MESSAGE_FILE" ]; then
        fail "$(printf '%s\n' \
            '有未提交改动，但没有提交信息 —— 本脚本**不替你编** commit message。' \
            '' \
            '两种做法，选一个：' \
            '  A) 你自己先按主题提交，然后重跑本脚本（推荐 —— 一次发版往往不止一个主题）：' \
            '       git add -A && git commit' \
            '       ./run.sh release' \
            '  B) 把信息交给本脚本：' \
            '       ./run.sh release --message-file /tmp/msg.txt' \
            '       ./run.sh release --message "fix(x): …"')"
    fi
    if [ -n "$COMMIT_MESSAGE_FILE" ]; then
        [ -f "$COMMIT_MESSAGE_FILE" ] || fail "--message-file 指向的文件不存在：$COMMIT_MESSAGE_FILE"
        run_or_echo git add -A
        run_or_echo git commit -F "$COMMIT_MESSAGE_FILE"
    else
        run_or_echo git add -A
        run_or_echo git commit -m "$COMMIT_MESSAGE"
    fi
fi

# ---------------------------------------------------------------
# 3. 发布说明就绪（找不到就生成草稿并**停下**）
# ---------------------------------------------------------------
stage 3 "发布说明就绪"
if [ -z "$NOTES_FILE" ]; then
    NOTES_FILE="$NOTES_DEFAULT"
fi

if [ -f "$NOTES_FILE" ]; then
    say "   已有：$NOTES_FILE"
    if ! VIOLATION="$(notes_violation "$NOTES_FILE")"; then
        fail "$(printf '%s\n' \
            "发布说明不合规：$NOTES_FILE" \
            "  $VIOLATION" \
            '格式四条见 Release-notes/README.md —— 做错了界面上看不出来，所以在这里拦。')"
    fi
    say "   格式校验通过"
else
    PREV_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    if [ -z "$PREV_TAG" ]; then
        RANGE=""
        fail "$(printf '%s\n' \
            "没有发布说明：$NOTES_FILE" \
            '而且仓库里一个 tag 都没有 ⇒ 脚本不知道该从哪段历史起算草稿。' \
            "请手写一份：${NOTES_FILE}（格式见 Release-notes/README.md），然后重跑。")"
    fi
    say "   没有发布说明 —— 从 $PREV_TAG..HEAD 的提交生成**草稿**"
    say ""
    say "   ⚠️ 下面是草稿，**内容还是开发者语言**（commit 标题）。"
    say "      发布说明是给用户看的，脚本不替你编 —— 改完再重跑。"
    say ""
    if [ "$DRY_RUN" = "1" ]; then
        say "   [dry-run] 会写入 ${NOTES_FILE}，内容大致是："
        git log --no-merges --pretty=format:'%s' "$PREV_TAG..HEAD" 2>/dev/null | sed 's/^/     <li>/; s/$/<\/li>/' | head -20
    else
        # 转义 & < >，否则 commit 标题里的尖括号会把弹窗文案吃掉
        {
            printf '<ul>\n'
            git log --no-merges --pretty=format:'%s' "$PREV_TAG..HEAD" 2>/dev/null \
                | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' \
                | sed 's/^/<li>/; s/$/<\/li>/'
            printf '</ul>\n'
        } >"$NOTES_FILE"
        say "   草稿已写入：$NOTES_FILE"
    fi
    fail "$(printf '%s\n' \
        '草稿已生成，请改写成面向用户的文案后重跑：' \
        "  \$EDITOR $NOTES_FILE" \
        "  ./run.sh release" \
        '' \
        '（格式四条：不要 HTML 注释 / 不要 DOCTYPE / 每条用 <li> 包 / 别自己写行首的 ·）')"
fi

# ---------------------------------------------------------------
# 4. 提交发布说明
# ---------------------------------------------------------------
stage 4 "提交发布说明"
SUMMARY="$(notes_summary "$NOTES_FILE")"
if [ -z "$SUMMARY" ]; then
    fail "从 $NOTES_FILE 里抽不出摘要（第一条 <li> 是空的？）—— 两个 release 提交的信息靠它，不能是空的"
fi
say "   摘要：$SUMMARY"

# ⚠️ **不能用 `[ "$(dirty_count)" = "0" ]` 来判「要不要提交」**：仓库里可能还有别的
# 未跟踪文件（比如刚生成的发布说明就还没跟 git 打过交道），而 `git add <指定文件>` 之后
# **索引**里到底有没有变化，才是这一步唯一该问的问题。
STAGED=0
if [ "$DRY_RUN" = "0" ]; then
    git add "$NOTES_FILE"
    if ! git diff --cached --quiet 2>/dev/null; then STAGED=1; fi
else
    # dry-run 下不碰索引，直接假设「有变化」，好把下一步的提交命令打印出来
    STAGED=1
fi
if [ "$STAGED" = "1" ]; then
    run_or_echo git commit -m "release: $TAG 发布说明（${SUMMARY}）"
else
    say "   发布说明没有变化 —— 跳过提交（上次已经提交过了）"
fi

# ---------------------------------------------------------------
# 5. 打 tag（**必须在构建之前**）
# ---------------------------------------------------------------
stage 5 "打 tag（先 tag 再构建）"
if git_tag_exists "$TAG"; then
    TAG_SHA="$(git rev-parse "$TAG^{commit}")"
    HEAD_SHA="$(git rev-parse HEAD)"
    if [ "$TAG_SHA" != "$HEAD_SHA" ]; then
        fail "$(printf '%s\n' \
            "tag $TAG 已存在，但它指向 ${TAG_SHA}，不是 HEAD（${HEAD_SHA}）。" \
            '两种可能：① 你重跑时又有了新提交 ⇒ 删掉 tag 重来（git tag -d '"$TAG"'）；' \
            '② 版本号推导撞了老 tag ⇒ 用 --version 显式指定。' \
            '**不要**直接把 tag 指过去：tag 一动，已发布的下载地址就指向了别的内容。')"
    fi
    say "   tag $TAG 已存在且指向 HEAD —— 跳过"
else
    run_or_echo git tag -a "$TAG" -m "$TAG"
    # ⚠️ dry-run 下不能说「已打」—— 它什么都没做，而这句话会出现在**最显眼**的位置
    if [ "$DRY_RUN" = "1" ]; then
        say "   （dry-run：没有真打）"
    else
        say "   已打 tag：$TAG"
    fi
fi
# ⚠️ 别在这行里用反引号引 git describe（2026-09-28）：双引号里的反引号会被 bash
#    当**命令替换**执行 ⇒ 这里会真的跑一次 git describe，回显里那一块变成空。
#    同一条坑在 preflight.sh 里也踩过一次。守卫见
#    `ToolingClaimTests.活文件里双引号内不得有反引号`。
say "   版本号将由 build_app.sh 从 git describe 派生 ⇒ **必须**是上面这个 tag"

# ---------------------------------------------------------------
# 6. 构建
# ---------------------------------------------------------------
stage 6 "构建（STRICT_CI=1 PACKAGE=1，输出到全新目录）"
if [ "$DRY_RUN" = "1" ]; then
    say "   [dry-run] 会先跑 STRICT_CI=1 的门槛，再："
    say "   [dry-run]   VERSION=$VERSION OUTPUT_DIR=$OUTPUT_DIR STRICT_CI=1 PACKAGE=1 ./build_app.sh"
    say "   （真跑时这一步会回读 dmg 的 Info.plist 版本，核对是不是 $VERSION —— 跑反顺序会静默带出上个版本号）"
else
    prepare_output_dir
    VERSION="$VERSION" BUILD_NUMBER="$(git rev-list --count HEAD)" \
        OUTPUT_DIR="$OUTPUT_DIR" STRICT_CI=1 PACKAGE=1 \
        "$PACKAGE_DIR/build_app.sh" || fail "构建失败"

    BUILT_VERSION="$(
        /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
            "$OUTPUT_DIR/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || true
    )"
    [ "$BUILT_VERSION" = "$VERSION" ] || fail "$(printf '%s\n' \
        "产物版本是 ${BUILT_VERSION}，而我们要发的是 ${VERSION}。" \
        '多半是 tag 与构建的顺序反了（版本号派生自 `git describe`），或者 OUTPUT_DIR 里是旧产物。')"
    say "   产物版本核对通过：$BUILT_VERSION"
fi

# ---------------------------------------------------------------
# 7. 推送 master + tag
# ---------------------------------------------------------------
stage 7 "推送 master + tag"
say "   （绕过 .git/config 里那条失效代理 —— 端口开着但 TLS 握手超时，直连是通的）"
git_push origin master
git_push origin "$TAG"

# ---------------------------------------------------------------
# 8. 生成 appcast
# ---------------------------------------------------------------
stage 8 "生成 appcast（enclosure / 资产名 / 内嵌说明三处回读都在 make_appcast.sh 里）"
if [ "$DRY_RUN" = "1" ]; then
    say "   [dry-run] RELEASE_NOTES_FILE=$NOTES_FILE OUTPUT_DIR=$OUTPUT_DIR ./Scripts/make_appcast.sh"
else
    RELEASE_NOTES_FILE="$NOTES_FILE" OUTPUT_DIR="$OUTPUT_DIR" \
        "$PACKAGE_DIR/Scripts/make_appcast.sh" || fail "appcast 生成失败"

    APPCAST="$UPDATES_DIR/appcast.xml"
    [ -f "$APPCAST" ] || fail "没有产出 $APPCAST"
    ENCLOSURE_URL="$(sed -n 's/.*<enclosure[^>]*url="\([^"]*\)".*/\1/p' "$APPCAST" | head -1)"
    [ -n "$ENCLOSURE_URL" ] || fail "appcast 里没有 enclosure"

    # 资产名与 enclosure 末段比对（make_appcast.sh 内部也查，这里是**流水线级**的第二次 ——
    # 因为下一步 gh release create 用的就是本地文件名，改名的代价是用户 404 而 appcast 不报错）
    UPLOAD_DMG="$UPDATES_DIR/$APP_NAME-$VERSION.dmg"
    [ -f "$UPLOAD_DMG" ] || fail "找不到待上传的 dmg：$UPLOAD_DMG"
    asset_name_matches_enclosure "$ENCLOSURE_URL" "$UPLOAD_DMG" \
        || fail "enclosure 末段（$(basename "$ENCLOSURE_URL")）与待上传文件（$(basename "$UPLOAD_DMG")）不一致 —— 传上去也 404"
    say "   资产名与 enclosure 逐字一致：$(basename "$UPLOAD_DMG")"
fi

# ---------------------------------------------------------------
# 9. 创建 Release
# ---------------------------------------------------------------
stage 9 "创建 Release（正式版）"
if [ "$DRY_RUN" = "1" ]; then
    say "   [dry-run] gh release create $TAG --title $VERSION --notes-file $NOTES_FILE \\"
    say "   [dry-run]   $UPDATES_DIR/$APP_NAME-$VERSION.dmg $UPDATES_DIR/$APP_NAME-$VERSION.zip"
else
    # zip 也要按同一规则命名 —— gh 用的资产名就是本地文件名（跟上一版对齐：
    # 历史 release 上是 SafeOut-<版本>.dmg 与 SafeOut-<版本>.zip 成对出现）
    cp -f "$OUTPUT_DIR/$APP_NAME.zip" "$UPDATES_DIR/$APP_NAME-$VERSION.zip"

    if gh release view "$TAG" >/dev/null 2>&1; then
        warn "Release $TAG 已存在 —— 改为**覆盖重传资产**（不新建、不改正文之外的东西）"
        gh release upload "$TAG" \
            "$UPDATES_DIR/$APP_NAME-$VERSION.dmg" \
            "$UPDATES_DIR/$APP_NAME-$VERSION.zip" --clobber
    else
        gh release create "$TAG" \
            --title "$VERSION" \
            --notes-file "$NOTES_FILE" \
            "$UPDATES_DIR/$APP_NAME-$VERSION.dmg" \
            "$UPDATES_DIR/$APP_NAME-$VERSION.zip" || fail "gh release create 失败"
    fi

    # 回读：① 必须是正式版 ② 两个资产名要与 enclosure 对得上
    # （「`state: uploaded` 不等于内容是新的」这条教训见技能 github-release-swiftpm-app）
    READBACK="$(gh release view "$TAG" --json isPrerelease,isDraft,assets -q \
        '(.isPrerelease|tostring) + " " + (.isDraft|tostring) + " " + ([.assets[].name]|join(","))')" || fail "回读 Release 失败"
    case "$READBACK" in
        "false false "*) : ;;
        *) fail "Release $TAG 不是「已发布的正式版」：$READBACK" ;;
    esac
    case "$READBACK" in
        *"$APP_NAME-$VERSION.dmg"*) : ;;
        *) fail "Release 上没有 $APP_NAME-$VERSION.dmg —— appcast 的 enclosure 指的就是它" ;;
    esac
    say "   回读通过：正式版，资产齐"
fi

# ---------------------------------------------------------------
# 10. 提交 appcast 并推送
# ---------------------------------------------------------------
stage 10 "提交 appcast.xml 并推送"
if [ "$DRY_RUN" = "1" ]; then
    say "   [dry-run] cp $UPDATES_DIR/appcast.xml appcast.xml && git add appcast.xml"
    say "   [dry-run] git commit -m \"release: $TAG appcast（${SUMMARY}）\""
    say "   [dry-run] git push origin master（绕过代理）"
else
    cp -f "$UPDATES_DIR/appcast.xml" "$PACKAGE_DIR/appcast.xml"
    git add "$PACKAGE_DIR/appcast.xml"
    if git diff --cached --quiet 2>/dev/null; then
        say "   appcast.xml 没有变化 —— 跳过提交"
    else
        git commit -m "release: $TAG appcast（${SUMMARY}）"
    fi
    git_push origin master
    say "   appcast 已推送 —— 老版本应用下次检查就能看到 $VERSION"
fi

# ---------------------------------------------------------------
# 11. 回下载对 sha256（**发版不能只看上传成功**）
# ---------------------------------------------------------------
stage 11 "回下载对 sha256"
if [ "$DRY_RUN" = "1" ]; then
    say "   [dry-run] curl 下载 enclosure，shasum -a 256 与本地资产比对"
else
    TMP_DL="${TMPDIR:-/tmp}/de-release-verify-$VERSION.dmg"
    curl -fsSL --connect-timeout 20 --max-time 300 -o "$TMP_DL" "$ENCLOSURE_URL" \
        || fail "回下载失败：${ENCLOSURE_URL}（Release 刚建好，CDN 可能有几秒延迟，重跑即可）"

    LOCAL_SHA="$(shasum -a 256 "$UPLOAD_DMG" | awk '{print $1}')"
    REMOTE_SHA="$(shasum -a 256 "$TMP_DL" | awk '{print $1}')"
    hdiutil verify "$TMP_DL" >/dev/null 2>&1 || fail "回下载的 dmg 校验不过 —— 别发，先查构建"
    rm -f "$TMP_DL"

    [ "$LOCAL_SHA" = "$REMOTE_SHA" ] || fail "$(printf '%s\n' \
        '回下载的 sha256 与本地不一致 —— 用户点「安装更新」下载到的不是我们构建的那份。' \
        "  本地 $LOCAL_SHA" \
        "  线上 $REMOTE_SHA")"
    say "   sha256 一致：$LOCAL_SHA"
fi

# ---------------------------------------------------------------
say ""
say "=================================================="
if [ "$DRY_RUN" = "1" ]; then
    say " ✅ dry-run 预演结束 —— 没有产生任何外部效果"
    say "    确认无误后去掉 --dry-run 重跑。"
else
    say " ✅ 发版完成：$VERSION"
    say "=================================================="
    say "  Release   https://github.com/wenber-yu/SafeOut/releases/tag/$TAG"
    say "  产物      $OUTPUT_DIR"
    say ""
    say "  ⚠️ 自举提示：这一版**修好的东西**要用户手动装一次才生效 ——"
    say "     盘上在用的旧版本跑的是旧逻辑，它不会自己变好。"
    say ""
    say "  推送之后看一眼 CI：./run.sh ci"
fi
