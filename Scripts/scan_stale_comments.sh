#!/usr/bin/env bash
# =============================================================
# SafeOut — 注释里的「承诺句」扫描器（门槛：进 preflight）
#
# 【它解决什么】
# 2026-09-20 一轮里修掉 **4 处**过时注释（§8.88），其中「应用自身还不检查更新」
# 挂了很久而 Sparkle 早已接好。共同点：**代码是对的、注释是错的** ⇒
# 编译 / 测试 / CI 全绿，只有读的人会照着错的注释做决策。
#
# 【它不做什么 —— 关键设计】
# ⚠️ **不要做成「关键词出现就报警」**。实测：用 `尚未|还没` 这类泛词扫 Sources，
# **33 处命中里只有 ~3 处是真问题**（precision ≈ 9%）—— 其余 30 处都是
# 「还没生效 / 还没重启 / 尚未检查」这类**描述运行时状态**的正常注释。
# 那种扫描器一上来就误报满天飞，结局一定是被关掉（§8.88.3）。
#
# ⇒ 本脚本的判据不是「这句话像不像承诺」，而是：
#    **作者自己标了承诺 / 限制 / 未决，就必须写下日期。**
#    机器只负责「标了没写日期」和「到期了催复核」这两件确定的事。
#
# ⚠️ **「哪天 / 将来 / 以后再」刻意不在词表里** —— 2026-09-23 实测量化过：
#    扫 Sources 得 13 处、扫 Tests 得 30 处，**真待办只有 1 处**
#    （`UpdateController` 里「将来换了签名，这一段要重验」，且已由账本 #46 覆盖）
#    ⇒ precision ≈ **2.3%**，比上面那个已经被否掉的 9% 还低。
#    这类词的绝大多数在**说明守卫的作用**（「若哪天改成 X，这条守卫会红」）——
#    那是**设计意图**，不是待办，给它加日期反而是噪音。
#    ⇒ 想加这个词的人：**先量 precision**，别只看「有一处漏了」。
#    ℹ️ 真出现「条件性待办」时走**账本**（#46 / #54 就是这么处理的），不靠词表。
#
# 【约定】注释里出现下列触发词时，**同一行或前后 2 行内**必须有一个 `YYYY-MM-DD`：
#     未核实 | 待拍板 | TODO | FIXME | 已知限制 | 尚未支持 | 尚未接入
#     还没支持 | 还没做 | 未做 | 下一轮做 | 暂时不 | 暂时没
#
# 【退出码】
#   0 无问题；1 有「标了承诺却没写日期」（**门槛失败**）。
#   「日期超过 STALE_DAYS」只**警告不失败** —— 见下面 STALE_DAYS 的说明。
#
# 【用法】
#   ./Scripts/scan_stale_comments.sh
#   SCAN_DIRS="Sources Tests" ./Scripts/scan_stale_comments.sh
# =============================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SCAN_DIRS="${SCAN_DIRS:-Sources Tests}"
# 到期只警告、不失败：**没有代码改动也会变红**的门槛会被关掉。
# 催复核靠人（以及「仍开着」表），不靠让 CI 自己烂掉。
STALE_DAYS="${STALE_DAYS:-30}"
ALLOWLIST="Scripts/stale_comment_allowlist.txt"

# ⚠️ BSD grep 的 BRE 不支持 `\|` 交替 —— 一律用 `grep -E`。
TRIGGER='未核实|待拍板|TODO|FIXME|已知限制|尚未支持|尚未接入|还没支持|还没做|未做|下一轮做|暂时不|暂时没'
DATE_RE='20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]'

missing=0
stale=0
total=0

allowed() {
    # 豁免表按 "路径:行号" 精确匹配，**整行**比较（`grep -xF`）。
    [ -f "$ALLOWLIST" ] || return 1
    # ⚠️ 先剥掉行内 `#` 注释与行尾空白再比：本脚本自己的提示写着「可加 # 说明」，
    #    而 `-x` 认的是**整行** ⇒ 写成 `Sources/X.swift:12 # 误报` 的条目会
    #    **永远匹配不上**，症状是「豁免写了、门槛还是红」，且看不出是格式不对。
    sed 's/#.*$//; s/[[:space:]]*$//' "$ALLOWLIST" | grep -qxF "$1"
}

today="$(date +%Y-%m-%d)"
today_epoch="$(date -j -f '%Y-%m-%d' "$today" '+%s' 2>/dev/null || date '+%s')"

while IFS= read -r file; do
    # 只取注释行（行首是 //），并挑出含触发词的行
    hits="$(grep -nE "^[[:space:]]*//" "$file" | grep -E "$TRIGGER" || true)"
    [ -z "$hits" ] && continue
    while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        lineno="${hit%%:*}"
        text="${hit#*:}"
        total=$((total + 1))
        key="${file}:${lineno}"
        if allowed "$key"; then
            continue
        fi
        # 前后 2 行窗口内找日期
        from=$((lineno - 2)); [ "$from" -lt 1 ] && from=1
        to=$((lineno + 2))
        window="$(sed -n "${from},${to}p" "$file")"
        if ! printf '%s' "$window" | grep -qE "$DATE_RE"; then
            echo "❌ ${key}"
            echo "     ${text}"
            echo "     → 标了承诺/限制/未决，却没写日期。在这一行或前后 2 行内补一个 YYYY-MM-DD。"
            missing=$((missing + 1))
            continue
        fi
        # 有日期：算不算到期
        d="$(printf '%s' "$window" | grep -oE "$DATE_RE" | head -1)"
        d_epoch="$(date -j -f '%Y-%m-%d' "$d" '+%s' 2>/dev/null || echo 0)"
        if [ "$d_epoch" -gt 0 ]; then
            age_days=$(( (today_epoch - d_epoch) / 86400 ))
            if [ "$age_days" -gt "$STALE_DAYS" ]; then
                echo "⚠️  ${key}（${d}，${age_days} 天前，> ${STALE_DAYS} 天）"
                echo "     ${text}"
                echo "     → 只警告：请人工复核这句话还成不成立。"
                stale=$((stale + 1))
            fi
        fi
    done <<< "$hits"
done < <(find $SCAN_DIRS -name '*.swift' -type f | sort)

echo ""
echo "注释承诺句扫描：共 ${total} 处标记 —— 缺日期 ${missing} 处（门槛失败）、到期 ${stale} 处（仅警告）"
if [ "$missing" -gt 0 ]; then
    echo "  修复：补日期；确属误报则把 \"路径:行号\" 写进 ${ALLOWLIST}（每行一条，可加 # 说明）"
    exit 1
fi
exit 0
