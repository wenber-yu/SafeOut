#!/bin/bash
# =============================================================
# SafeOut — 一键生成 .app 脚本
# 用法：
#   ./build_app.sh                              # 版本与构建号从 git 自动派生（渠道固定为 direct 直发）
#   NOTARIZE=1 ./build_app.sh                   # 构建后自动公证 + 打包 SafeOut.dmg（需 Developer ID 签名）
#   PACKAGE=1 ./build_app.sh                    # 不公证，直接出分发产物：SafeOut.dmg + SafeOut.zip
#                                               #   （本机无 Developer ID 证书时用它出 GitHub Release 资产）
#   VERSION=2.1.0 ./build_app.sh                # 显式指定版本
#   BUILD_NUMBER=42 ./build_app.sh              # 显式指定构建号
#   OUTPUT_DIR=/tmp ./build_app.sh              # 指定输出目录（默认 Dist/）
#   STRICT_CI=1 ./build_app.sh                  # 打包前先过 CI 的门槛（见 Scripts/preflight.sh）
#   DISABLE_SANDBOX=1 ./build_app.sh            # 让 swift build 跳过 SwiftPM 自带的 sandbox-exec
#                                               #   （仅供本机执行环境已自带沙箱、导致
#                                               #    "sandbox_apply: Operation not permitted" 时使用）
# 产物：Dist/SafeOut.app（可拖入 /Applications 或双击运行）
#       Dist/SafeOut.dmg + Dist/SafeOut.zip（仅 PACKAGE=1 / NOTARIZE=1 时生成）
# 图标：复制预先生成的 Resources/AppIcon.icns（打包时不生成图标）；
#       图标由独立脚本生成：把源图放进 Design/app-icon/ 后运行
#         sh Scripts/build_icon.sh
#
# ---------------------------------------------------------------
# 分发渠道：**只有 direct 一种**（2026-09-18 决定：本应用不上架 Mac App Store）。
#   direct —— 官网 / GitHub 直发。Developer ID 签名、不开沙盒，lsof 可列出占用进程
#            （本应用核心价值所在）。用户需在「系统设置 › 隐私与安全性 › 完全磁盘访问」
#            中授权后检测才生效。
#
# 原先的 `BUILD_CHANNEL=mas` 分支（强制 App Sandbox + 跳过公证）已随该决定删除；
# 再传 `BUILD_CHANNEL` 会**直接报错退出**，而不是静默产出一个渠道不对的包。
#
# 签名身份（SIGN_IDENTITY，可选）
#   direct → "Developer ID Application: <Team Name> (<Team ID>)"
#   未设置时自动探测钥匙串，三档优先级依次回退：
#     1) Developer ID Application   —— 可公证、可正式分发
#     2) 任意其他稳定代码签名身份（如本机自签）—— 能保住 TCC 授权，但**无法公证**
#     3) ad-hoc（"-"）              —— 仅供本机验证；且 TCC 授权每次重建都会失效
#   构建结束的摘要会明确标注当前用的是哪一档，不要把自签误认成 Developer ID。
#
# 正式分发（direct 渠道）还需公证，否则 Gatekeeper 拦截 —— 交给 NOTARIZE=1 一把梭：
#   NOTARIZE=1 NOTARY_KEYCHAIN_PROFILE="<profile>" ./build_app.sh
# 开发期没有 Developer ID 证书、公证走不通时，用 PACKAGE=1 出未公证的 dmg / zip：
#   PACKAGE=1 ./build_app.sh
# dmg 内为 SafeOut.app + 指向 /Applications 的替身，用户挂载后拖入即可。
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 仓库根 == SPM 包根（Package.swift 位于仓库根目录，与 FCPX2AAF / ProxyGenerator 布局一致）
PACKAGE_DIR="$SCRIPT_DIR"

# 修正 LC_BUILD_VERSION 的 sdk 戳：XCBuild 把它错钉成部署目标，macOS 26 按
# 「链接 SDK」门控新外观（Liquid Glass 浮岛等），不修则发版产物整体退回旧形态。
# 详见 Scripts/lib/macos_link_version_args.sh 头部说明。
source "$SCRIPT_DIR/Scripts/lib/macos_link_version_args.sh" "$PACKAGE_DIR"

APP_NAME="SafeOut"
# 面向用户的中文显示名：Finder / Dock / 菜单栏 App 菜单 / 关于面板 / 系统设置里
# 「完全磁盘访问」授权列表展示的都是它。与 APP_NAME 分开的原因——APP_NAME 同时是
# .app 目录名、产物文件名（脚本路径、下载链接、CI 都依赖它），改中文会连带破坏这些。
APP_DISPLAY_NAME="磁盘推出助手"
APP_DISPLAY_NAME_HANT="磁碟推出助手"
EXECUTABLE="SafeOutApp"                 # SPM 可执行 target 名
# ---------------------------------------------------------------
# 版本号自动派生
#
# 优先取环境变量（CI 或手工发布时可精确指定）；未指定时从 git 派生：
#   VERSION      ← 最近的 tag（如 v1.2.0 → 1.2.0），无 tag 时回退 1.0.0
#   BUILD_NUMBER ← 提交总数，天然单调递增，不会像硬编码那样忘记改
#
# 仍保留显式覆盖能力，因为「从 tag 派生」在 hotfix 分支上可能取到不想要的 tag。
#
# ⚠️ **tag 与提交数都只反映「已提交」的代码**（2026-09-17 用户发现）：
#    版本号停在 tag 那次提交，而工作区可能有一堆未提交改动 —— 两者一起给出
#    `2026.09.13.1 / 44`，看起来像 9/13 那个正式构建，实际跑的却是今天的工作区。
#    所以额外把 **commit 短哈希**与**未提交改动数**写进 Info.plist，
#    设置窗口据此标出「这不是 tag 对应的那个构建」。
#
# ⚠️⚠️ **「一个可用 git 都没有」与「有 git 但它不干活」是两件事**（2026-09-21，§8.116）：
#    - 前者是**有意支持**的（从 tarball 构建）⇒ **容忍**，但版本信息按「未知」写；
#    - 后者是**环境坏了**（本机实测：Xcode 许可未接受 ⇒ `/usr/bin/git` 只打印许可警告、
#      **零输出、退出码 0**）。它原先的症状是**静默**产出一个自称
#      `1.0.0 / 1 / unknown / dirty=0` 的包 —— `dirty=0` 尤其糟：它的意思是
#      「**工作区干净**」，而真相是「**不知道**」（Swift 侧 `AppVersionInfo.dirtyCount`
#      的注释早就写明「不要拿 `0` 代替缺失 —— 「干净」与「不知道」是两回事」）。
#    ⇒ 判据只能**试跑**（`[ -x ]` / `command -v` / 退出码三条都判不出来），
#      实现见 `Scripts/lib/find_git.sh`；本段的门见 `Scripts/test/build_app_version_smoke.sh`。
# ---------------------------------------------------------------
# shellcheck source=Scripts/lib/find_git.sh
. "$SCRIPT_DIR/Scripts/lib/find_git.sh"
if find_usable_git; then
    GIT_AVAILABLE=1
else
    GIT_AVAILABLE=0
    GIT_BIN=""
fi

# ⚠️ 下面四个函数在**没有可用 git** 时一律返回空 —— 调用方必须分清
#    「空 = 本来就没有 git」与「空 = 有 git 但取不到」（见下面的硬报错）。
git_tag_version() {
    [ "$GIT_AVAILABLE" = "1" ] || return 0
    # 空是**合法**的：仓库还没有任何 tag
    "$GIT_BIN" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true
}
git_commit_count() {
    [ "$GIT_AVAILABLE" = "1" ] || return 0
    "$GIT_BIN" rev-list --count HEAD 2>/dev/null || true
}
git_commit_short() {
    [ "$GIT_AVAILABLE" = "1" ] || return 0
    "$GIT_BIN" rev-parse --short HEAD 2>/dev/null || true
}
# 未提交改动数（含未跟踪文件）。
# ⚠️ **退出码不能被 `wc` 吃掉**：`git status --porcelain | wc -l` 在 git 失败时打印 `0`
#    —— 与「工作区干净」**逐字相同**（本仓库在别处踩过多次）⇒ 先收输出、再判成败。
git_dirty_count() {
    [ "$GIT_AVAILABLE" = "1" ] || return 0
    local out
    if ! out="$("$GIT_BIN" status --porcelain 2>/dev/null)"; then
        return 0  # 取不到 ⇒ 输出空 = 「未知」，**不是** 0
    fi
    if [ -z "$out" ]; then
        printf '0\n'
        return 0
    fi
    printf '%s\n' "$out" | wc -l | tr -d ' '
}

DERIVED_VERSION="$(git_tag_version)"
DERIVED_BUILD="$(git_commit_count)"
GIT_COMMIT="$(git_commit_short)"
GIT_DIRTY="$(git_dirty_count)"

# ---- 版本信息可不可信？三档，只有第一档能直接往下走 ----
# 判据：`rev-parse --short HEAD` 与 `rev-list --count HEAD` 在有效仓库里**永远有值**
# （除非仓库一个提交都没有）⇒ 空 = 这份 git 没干活。
#
# ⚠️ **必须把「没有 git」与「有 git 但不干活」分开**（2026-09-21，§8.116）：
#   ① 有可用 git、HEAD 读得到         ⇒ 正常，往下走
#   ② 连 git 的痕迹都没有             ⇒ **有意支持**（从 tarball 构建）⇒ 容忍，写「未知」
#   ③ 有 git 的痕迹，但一份都跑不起来 ⇒ **环境坏了** ⇒ 硬报错（除非显式给了两个值）
# ②③ 混成一句「取不到就算了」正是本仓库反复踩的坑：**「没有」与「有但没用」在输出上逐字相同**。
if [ "$GIT_AVAILABLE" = "1" ] && [ -z "$GIT_COMMIT" ]; then
    VERSION_UNTRUSTED_REASON="找得到 git（${GIT_BIN}），但它取不到 HEAD"
elif [ "$GIT_AVAILABLE" = "0" ] && [ "${GIT_UNUSABLE_FOUND:-0}" = "1" ]; then
    VERSION_UNTRUSTED_REASON="找到了 git，但一份都跑不起来（许可未接受 / 安装损坏）"
else
    VERSION_UNTRUSTED_REASON=""
fi

if [ -n "$VERSION_UNTRUSTED_REASON" ]; then
    # 它后面给的任何读数都不可信 —— 尤其 `status --porcelain` 那个「0 处改动」
    GIT_DIRTY=""
    if [ -n "${VERSION:-}" ] && [ -n "${BUILD_NUMBER:-}" ]; then
        echo "⚠️  ${VERSION_UNTRUSTED_REASON}，但你已显式指定 VERSION 与 BUILD_NUMBER ⇒ 继续。" >&2
        echo "    产物里 DEBuildCommit 会是 unknown、DEBuildDirtyCount 会是空（界面显示「未知」）。" >&2
    else
        echo "错误：${VERSION_UNTRUSTED_REASON} —— 版本信息不可信，拒绝产出包。" >&2
        echo "      常见原因：Xcode 许可未接受 ⇒ git 只打印许可警告、**零输出、退出码 0**。" >&2
        echo "      正解：sudo xcodebuild -license（或先 source Tools/clt_swift_env.sh）。" >&2
        echo "      若确实要跳过版本派生，显式指定两个值：" >&2
        echo "          VERSION=… BUILD_NUMBER=… ./build_app.sh" >&2
        exit 1
    fi
fi

VERSION="${VERSION:-${DERIVED_VERSION:-1.0.0}}"
BUILD_NUMBER="${BUILD_NUMBER:-${DERIVED_BUILD:-1}}"
# 写进 Info.plist 的构建元信息。
# ⚠️ **「不知道」写**空串**，不写 `0`**：`0` 的意思是「工作区干净」。
#    空串在 Swift 侧读成 `nil`（`AppVersionInfo.value(forKey:)` 把空/全空白当读不到）
#    ⇒ 界面显示「未知」，那才是真话。
BUILD_COMMIT="${GIT_COMMIT:-unknown}"
BUILD_DIRTY="${GIT_DIRTY}"

# ---- 自证：把**实际用到的那份 git** 与派生结果打出来 ----
# ⚠️ 必须有：否则「派生失败」与「派生成功但值恰好是兜底值」在输出上分不开
#    （本仓库反复踩这个 —— 判据一律要带自证字段）。
# ⚠️ 打印的是 **`BUILD_DIRTY`**（= 将要写进 Info.plist 的那个值），**不是**中间变量
#    `GIT_DIRTY`：两者一旦被改得不同，自证行就会**替产物说谎**。
#    （2026-09-21 实测踩过：第一版打印 `GIT_DIRTY`，于是把
#     `BUILD_DIRTY="${GIT_DIRTY:-0}"` 这个「拿 0 代替缺失」的变异**照绿放过去了**。）
echo "ⓘ 版本派生：git=${GIT_BIN:-（无可用 git）} · 提交=${GIT_COMMIT:-未知} · 提交数=${DERIVED_BUILD:-未知} · 未提交=${BUILD_DIRTY:-未知}"

# 工作区不干净时**明确告警**：版本号指向的是 tag 那次提交，不是本次构建的代码。
if [ -n "${BUILD_DIRTY}" ] && [ "${BUILD_DIRTY}" != "0" ]; then
    echo "⚠️  工作区有 ${BUILD_DIRTY} 处未提交改动"
    echo "    版本号 ${VERSION} 取自 tag「${DERIVED_VERSION:-无}」，指向的是提交 ${BUILD_COMMIT}"
    echo "    它**不代表本次构建的实际代码**；设置窗口会标出这一点。"
fi

# ---------------------------------------------------------------
# 部署目标（写进 Info.plist 的 `LSMinimumSystemVersion`）—— **派生，不写死**
#
# 唯一真相是 `Package.swift` 的 `platforms: [.macOS(.vNN)]`（编译器读的也是它）。
# `LSMinimumSystemVersion` 是**同一件事的第二次声明**，写死就一定会漂：
# 2026-09-24 实测 —— 代码已提到 14.0，这里还硬编码着 `13.0`。差一档的后果**不是**
# 「被系统拦下」，而是**在 13 上启动、然后崩**（Gatekeeper 只看这个键）。
# ⇒ 从 Package.swift 派生；**派不出来就硬报错** —— 不退回字面量、也不写空串
#    （少一个键与值写空，在 Gatekeeper 眼里都不算拦得住）。
# 守卫：Tests/SafeOutAppTests/DeploymentTargetTests.swift
# ---------------------------------------------------------------
DEPLOY_TARGET_MAJOR="$(sed -nE 's/^[[:space:]]*platforms:[[:space:]]*\[\.macOS\(\.v([0-9]+)\)\].*$/\1/p' "$PACKAGE_DIR/Package.swift")"
# 必须**恰好是一个数字**：空 = 一行都没匹配到；带换行 = 匹配到多行。
# ⚠️ 用 `case` 而不是 `[ -z ]`：后者只挡得住「空」，挡不住「匹配到两行」。
case "$DEPLOY_TARGET_MAJOR" in
    '' | *[!0-9]*)
        echo "❌ 取不到部署目标：${PACKAGE_DIR}/Package.swift 里没有形如" >&2
        echo "   platforms: [.macOS(.vNN)] 的行（拿到的是「${DEPLOY_TARGET_MAJOR}」）。" >&2
        echo "   LSMinimumSystemVersion 由它派生 ⇒ 派不出来就拒绝产出包。" >&2
        exit 1
        ;;
esac
DEPLOY_TARGET="${DEPLOY_TARGET_MAJOR}.0"
echo "ⓘ 部署目标：${DEPLOY_TARGET}（派生自 Package.swift 的 platforms ⇒ Info.plist 的 LSMinimumSystemVersion）"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/Dist}"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
ICON_SOURCE="$PACKAGE_DIR/Resources/AppIcon.icns"

# ---------------------------------------------------------------
# 分发渠道 → entitlements
#
# 只有 direct 一种：不开沙盒，保留 Hardened Runtime（由 codesign --options runtime 提供）。
# 开沙盒会废掉「列出占用进程」这个核心价值，所以**不是可选项**。
#
# `BUILD_CHANNEL` 变量已随 mas 分支删除。这里保留一个**报错**而不是静默忽略：
# 脚本的调用方（CI、历史文档、肌肉记忆）可能还在传它，而「传了个无效值却被忽略」
# 和「渠道选错了」在产物上长得一模一样 —— 宁可让构建停下来。
# ---------------------------------------------------------------
if [ -n "${BUILD_CHANNEL:-}" ] && [ "$BUILD_CHANNEL" != "direct" ]; then
    echo "❌ BUILD_CHANNEL 已移除：本应用不上架 Mac App Store，渠道固定为 direct（Developer ID 直发）" >&2
    echo "   传了 mas 也不会产出上架包——之前的 mas 分支会强制 App Sandbox，直接废掉「列出占用进程」。" >&2
    exit 1
fi
ENTITLEMENTS="$PACKAGE_DIR/Resources/SafeOut.direct.entitlements"
# 签名身份：
#   显式设置 SIGN_IDENTITY 时直接使用；未设置则自动探测钥匙串里的
#   「Developer ID Application」证书——有了就自动采用（便于日后直接 NOTARIZE=1），
#   没有就回退 ad-hoc（"-"，仅供本机验证，无法公证/分发）。
#
# 无论身份来自哪里，都用 IDENTITY_KIND 记下它的**类型**，供后续文案与 NOTARIZE 前置检查使用。
# 为什么必须区分：自签身份（如 "SafeOut Dev Signing"）同样能签出有效签名、保住 TCC 授权，
# 但它**无法公证**。若一律显示成「Developer ID 证书」，使用者会误判自己
# 已经具备分发条件——这正是本项目曾出现的文案缺陷。
#   developer-id —— Apple 签发的 Developer ID Application：可公证、可正式分发
#   self-signed  —— 本机自签：开发期用来稳住 TCC 授权
#   adhoc        —— 无任何身份，仅供本机验证
#   explicit     —— 用户显式指定且类型未知
IDENTITY_KIND="explicit"
if [ -n "${SIGN_IDENTITY:-}" ]; then
    case "$SIGN_IDENTITY" in
        "-") IDENTITY_KIND="adhoc" ;;
        *"Developer ID"*) IDENTITY_KIND="developer-id" ;;
        *) IDENTITY_KIND="explicit" ;;
    esac
fi

if [ -z "${SIGN_IDENTITY:-}" ]; then
    # 优先级 1：Developer ID Application（可公证、可正式分发）
    # **bash 管道坑**：`|` 的优先级高于 `||`。
    # 写成 `A | grep X || true | head | sed` 会被解析成 `(A|grep X) || (true|head|sed)`，
    # 即 grep 成功时后面的 `head | sed` **完全不执行**，导致提取到的还是整行原始输出。
    # 必须把 `|| true` 放到**整个管道的外层**。
    AUTO_ID="$(security find-identity -p codesigning -v 2>/dev/null \
        | grep 'Developer ID Application' \
        | head -1 \
        | sed -E 's/.*\) "([^"]+)".*/\1/' || true)"
    if [ -n "$AUTO_ID" ]; then
        SIGN_IDENTITY="$AUTO_ID"
        IDENTITY_KIND="developer-id"
        echo "   自动选用 Developer ID 证书: $SIGN_IDENTITY"
    else
        # 优先级 2：钥匙串里**任意**其他有效代码签名身份（例如本机自签的
        # "SafeOut Dev Signing"）。
        #
        # **为什么必须有这一档**：TCC（完全磁盘访问）授权绑定的是代码签名身份。
        # ad-hoc（"-"）签名没有 Team ID，且 CDHash 随每次重建变化 → 系统视为另一个 app
        # → 用户刚在系统设置里授予的 FDA 立刻失效，横幅又冒出来。
        # 用带固定 Team ID（证书 OU 字段）的稳定身份签名后，TCC 按 TEAMID.bundle_id
        # 匹配，重建二进制也能保住授权。
        # `-v` 输出格式：`  1) 4C8302... "SafeOut Dev Signing"`，
        # 身份行以「空格+序号+)」开头，汇总行（"1 valid identities found"）不匹配此模式。
        # certificate 名里有空格，取**最后一对引号**里的内容。
        # `|| true` 同样必须放在管道外层（见上方 bash 优先级说明）。
        AUTO_ID="$(security find-identity -p codesigning -v 2>/dev/null \
            | grep -E '^[[:space:]]+[0-9]+\)' \
            | grep -v 'Developer ID Application' \
            | head -1 \
            | sed -E 's/.*"([^"]+)".*/\1/' || true)"
        if [ -n "$AUTO_ID" ]; then
            SIGN_IDENTITY="$AUTO_ID"
            IDENTITY_KIND="self-signed"
            echo "   自动选用稳定代码签名身份（自签）: $SIGN_IDENTITY"
            echo "         ⓘ 自签可保住 TCC 授权，但无法公证 / 无法正式分发"
        else
            SIGN_IDENTITY="-"
            IDENTITY_KIND="adhoc"
            echo "   警告：未找到任何代码签名身份，回退 ad-hoc"
            echo "         ad-hoc 下 TCC 授权每次重建都会失效（FDA 横幅反复出现）"
        fi
    fi
fi

# ---------------------------------------------------------------
# DISABLE_SANDBOX=1：让 swift build 跳过 SwiftPM 自带的 sandbox-exec
#
# **为什么需要这个开关**：SwiftPM 默认用 sandbox-exec 隔离构建过程。但部分托管 / 受管
# 执行环境**本身就跑在一层沙箱里**，此时再嵌套 sandbox-exec 会直接失败：
#     sandbox-exec: sandbox_apply: Operation not permitted
# 表现为「Invalid manifest」+ 构建中止，与代码无关。
# 该开关只影响构建期隔离，**不改变产物**（签名、Info.plist、渠道均不受影响），
# 也不会被 CI 默认启用 —— CI 环境有正常的沙盒权限，应保持默认的隔离。
#     DISABLE_SANDBOX=1 ./build_app.sh
# ---------------------------------------------------------------
SWIFT_BUILD_FLAGS=()
if [ "${DISABLE_SANDBOX:-0}" = "1" ]; then
    echo "ⓘ DISABLE_SANDBOX=1：swift build 将跳过 SwiftPM 沙盒（仅供受管环境使用）"
    SWIFT_BUILD_FLAGS+=(--disable-sandbox)
fi

# macOS 自带 bash 3.2：在 `set -u` 下，空数组的 "${arr[@]}" 会报 unbound variable。
# 下方调用点一律用 `${arr[@]+"${arr[@]}"}` 这一空安全展开写法（bash 3.2 / 4+ 通吃）。

if [ ! -f "$PACKAGE_DIR/Package.swift" ]; then
    echo "错误：找不到 $PACKAGE_DIR/Package.swift" >&2
    exit 1
fi

# ---------------------------------------------------------------
# STRICT_CI=1：打包前先过 CI 的门槛（`Scripts/preflight.sh`，逐道打印标题）
#
# **为什么默认关闭**：这些门槛比打包本身严格得多，日常迭代反复跑会拖慢节奏；
# 但它们恰恰是 CI 会拦下来的东西，而本脚本的 release 构建**不带**这些 flag，
# 所以「打包成功」不能推出「CI 会绿」。发布 / 提交 PR 前应显式开启：
#     STRICT_CI=1 ./build_app.sh
# 门槛实现见 Scripts/preflight.sh（本地与 CI 共用同一文件，避免逻辑分叉）。
# ---------------------------------------------------------------
if [ "${STRICT_CI:-0}" = "1" ]; then
    echo "▶ [0/5] 严格门槛预检（STRICT_CI=1）..."
    "$SCRIPT_DIR/Scripts/preflight.sh"
fi

# 注意：此处**不使用 shell 内建 `cd`** 切换目录。部分执行环境（带 brokered 沙盒的 shell）
# 在 `cd` 后会把脚本剩余部分放到一个不继承前面变量定义的新上下文里执行，导致后续步骤
# 报「未绑定变量」。改用 `env -C` 仅对 swift 构建命令临时切换工作目录（走 chdir 系统调用，
# 不被上述 broker 拦截），其余步骤一律使用绝对路径（$APP_BUNDLE 等），彻底规避该问题。
echo "▶ [1/5] Release 构建 ..."
env -C "$PACKAGE_DIR" swift build -c release --product "$EXECUTABLE" \
    ${MACOS_LINK_VERSION_ARGS[@]+"${MACOS_LINK_VERSION_ARGS[@]}"} \
    ${SWIFT_BUILD_FLAGS[@]+"${SWIFT_BUILD_FLAGS[@]}"}
BIN_PATH="$(env -C "$PACKAGE_DIR" swift build -c release --show-bin-path \
    ${SWIFT_BUILD_FLAGS[@]+"${SWIFT_BUILD_FLAGS[@]}"})/$EXECUTABLE"

echo "▶ [2/5] 组装 $APP_NAME.app ..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"

# ---------------------------------------------------------------
# 嵌入 Sparkle.framework
#
# Sparkle 是**动态框架**（SwiftPM 那个包是个 binaryTarget，里面是 Sparkle.xcframework），
# 可执行文件里记的是 `@rpath/Sparkle.framework/Versions/B/Sparkle`。
# SwiftPM 只在 `@loader_path`（= Contents/MacOS）里找，所以我们必须：
#   ① 把框架拷进 Contents/Frameworks
#   ② 给可执行文件补一条 `@executable_path/../Frameworks` 的 rpath
# 少任何一步，产物双击就是 `dyld: Library not loaded` —— 而构建和签名都**不会报错**，
# 只有真机运行才炸。所以这两步之后各有一条回读校验（见下）。
#
# ⚠️ rpath 必须在**签名之前**改：install_name_tool 改的是二进制本身，签完再改就废了签名。
# ---------------------------------------------------------------
SPARKLE_FW="$(find "$PACKAGE_DIR/.build/artifacts" -type d \
    -path "*Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" -print -quit 2>/dev/null || true)"
if [ -z "$SPARKLE_FW" ]; then
    echo "❌ 找不到 Sparkle.framework（.build/artifacts 下没有 xcframework）" >&2
    echo "   先跑一次 swift build 让 SwiftPM 下载并解包 Sparkle 二进制包。" >&2
    exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true
echo "   ✓ 已嵌入 Sparkle.framework（取自 $(basename "$(dirname "$(dirname "$SPARKLE_FW")")")）"

# ---------------------------------------------------------------
# Sparkle 的三条 Info.plist 配置
#
# SUFeedURL —— appcast 地址。**必须是 appcast.xml，不能填 /releases/latest**：
#   GitHub 的「latest release」链接给的是 HTML 页面 / atom 源，Sparkle 解析不了 ——
#   它要的是带 `sparkle:` 命名空间的 RSS。真正的下载地址写在 appcast 的 enclosure 里，
#   由 `Scripts/make_appcast.sh`（内部调 generate_appcast）生成，指向 Releases 的 dmg/zip。
#
# SUPublicEDKey —— EdDSA 公钥（base64）。为空时**不写这个键**，Sparkle 于是跳过验签：
#   任何人处在中间人位置都能推一个恶意版本进来。所以这里会**大声警告**，不悄悄略过。
#   生成：.build/artifacts/sparkle/Sparkle/bin/generate_keys（私钥进钥匙串，终端打印公钥）
#
# SUEnableAutomaticChecks —— 不设的话，Sparkle 会在**第二次启动**弹窗问用户
#   「要不要自动检查更新」。本应用自己有「自动更新」开关，不能先让 Sparkle 抢着问一遍。
# ---------------------------------------------------------------
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/wenber-yu/SafeOut/master/appcast.xml}"

# ⚠️ **公钥入库当默认值**（2026-09-20）。
#
# 为什么：它**本来就是公开的**（烤在每个发行包的 Info.plist 里，用户拿得到）；
# 而原先「靠环境变量传」有两个真实后果 ——
#   ① **CI 打的包不验签更新** ⇒ CI 那步「打包验证」验的**不是发行的那个东西**；
#   ② **忘了传就静默产出不验签的包**（只往 stderr 打一行警告，没人在 CI 日志里读它）
#      ⇒ 任何人处在中间人位置都能推一个恶意版本进来，而**打包一路绿灯**。
# 环境变量仍可覆盖（换钥匙时用它；日常不必记着传）。
#
# ⚠️ **私钥不在这里**，在登录钥匙串（`acct=ed25519`）。丢了它，这个公钥就再也签不出
#    能被验证的更新 —— 换钥匙要同时改这里和 appcast 的签名（详见 §8.39.7）。
DEFAULT_SPARKLE_PUBLIC_ED_KEY="DZSAElJGUg13m+uorm7qlJhQKPyxk4D1DXMYGEOtbBs="
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-$DEFAULT_SPARKLE_PUBLIC_ED_KEY}"

SPARKLE_PUBLIC_ED_KEY_PLIST=""
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
    SPARKLE_PUBLIC_ED_KEY_PLIST="    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_ED_KEY}</string>"
    echo "   ✓ SUPublicEDKey 已写入（更新会被验签）"
else
    echo "⚠️  未设置 SPARKLE_PUBLIC_ED_KEY：这个包**不会验签更新**" >&2
    echo "    中间人可推送任意版本。正式发布前补上：" >&2
    echo "      .build/artifacts/sparkle/Sparkle/bin/generate_keys" >&2
    echo "      SPARKLE_PUBLIC_ED_KEY=\"<终端打印的公钥>\" ./build_app.sh" >&2
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh-Hans</string>
	<key>CFBundleExecutable</key>
	<string>$EXECUTABLE</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.safeout.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_DISPLAY_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_DISPLAY_NAME</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>zh-Hans</string>
		<string>zh-Hant</string>
	</array>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <!-- 声明不使用非豁免加密；本应用不涉及加密，必须显式声明 false，
         否则公证 / 上传时会被标记为「缺失合规信息」。 -->
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
    <!-- Sparkle 自更新：SUFeedURL 必须是 appcast，不是 /releases/latest（见脚本上方说明）。 -->
    <key>SUFeedURL</key>
    <string>$SPARKLE_FEED_URL</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <!-- SUScheduledCheckInterval —— 常驻期间的**后台定时检查**间隔（秒）。
         2026-09-28 由 86400（1 天）改为 21600（6 小时）：本应用是菜单栏常驻工具，
         能连着跑几周，一天只查一次太钝 —— 而它**只在应用活着时才有效**
         （Sparkle 的定时器 fire 不了就等于没排），所以「启动时主动查一次」
         （见 Sources/Services/UpdateController.swift 里那条启动检查）与它是**互补**的
         两条路，不是替代。
         成本：一次 appcast 请求 3.3 KB，最坏 4 次/天。
         ⚠️ 改这里只对**新装的包**生效 —— 已装的老版本跑的还是它自己 Info.plist 里的值，
         要等它们装上带这一版的新包才会跟上。
         ⚠️ 本段 heredoc **没有加引号**（起始那行的标记是裸的 PLIST，没带引号）⇒
         反引号与「美元括号」命令替换会被 shell **先求值**：写一个反引号就会在每次构建
         打一条 command substitution 告警，而那段文字在产物里**被静默吃掉**
         （2026-09-28 实测栽过，本条注释自己就是那次事故现场）。要引用代码请直接写名字。 -->
    <key>SUScheduledCheckInterval</key>
    <integer>21600</integer>
$SPARKLE_PUBLIC_ED_KEY_PLIST
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 wenber-yu. Licensed under MIT.</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<!-- 构建元信息（自定义键，前缀 DE 避开 Apple 保留命名空间）。
	     ⚠️ 这两个键的意义是「让版本号说得清自己代表什么代码」：
	     CFBundleShortVersionString 取自最近的 tag，而 tag 与提交数**都只反映已提交的代码**；
	     工作区有未提交改动时，光看版本号会以为是 tag 那次正式构建。
	     设置窗口读到 DEBuildDirtyCount > 0 就会把这一点标出来。 -->
	<key>DEBuildCommit</key>
	<string>$BUILD_COMMIT</string>
	<key>DEBuildDirtyCount</key>
	<string>$BUILD_DIRTY</string>
	<key>LSMinimumSystemVersion</key>
	<string>$DEPLOY_TARGET</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

echo "▶ [3/5] 复制应用图标 ..."
if [ -f "$ICON_SOURCE" ]; then
    cp "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/"
    echo "   ✓ AppIcon.icns（来自 ${ICON_SOURCE}）"
else
    echo "   ⚠ 未找到 ${ICON_SOURCE}，将使用系统默认图标"
    echo "     生成图标：把源图放进 Design/app-icon/ 后运行 sh Scripts/build_icon.sh"
fi

echo "▶ [3.5/4] 写入本地化应用名（Finder / 系统设置列表取本地化值）..."
# macOS 对 .app 的**显示名**优先取本地化的 `InfoPlist.strings`：只把 CFBundleDisplayName 写进
# Info.plist，Finder 与「系统设置 › 完全磁盘访问」列表里看到的仍可能是文件名 SafeOut。
# 这里按语言各写一份覆盖值 —— 中文环境显示中文名，英文环境保留 SafeOut。
# .app 目录名与产物名仍是 ${APP_NAME}（下载链接与脚本路径依赖它，不能改中文）。
write_infoplist_strings() {
    local lproj="$1" name="$2"
    local dir="$APP_BUNDLE/Contents/Resources/${lproj}.lproj"
    mkdir -p "$dir"
    printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "$name" "$name" \
        >"$dir/InfoPlist.strings"
    plutil -convert binary1 "$dir/InfoPlist.strings" >/dev/null 2>&1 || true
    echo "   ✓ ${lproj}: ${name}"
}
write_infoplist_strings "zh-Hans" "$APP_DISPLAY_NAME"
write_infoplist_strings "zh-Hant" "$APP_DISPLAY_NAME_HANT"
write_infoplist_strings "en" "$APP_NAME"

echo "▶ [4/5] 签名（Hardened Runtime，直发渠道）..."
if [ ! -f "$ENTITLEMENTS" ]; then
    echo "   ❌ 缺少 entitlements: $ENTITLEMENTS" >&2
    exit 1
fi

# --options runtime 启用 Hardened Runtime；--deep 覆盖嵌套内容。
if codesign --force --deep --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" --options runtime "$APP_BUNDLE" >/dev/null 2>&1; then
    case "$IDENTITY_KIND" in
        adhoc)
            echo "   ✓ ad-hoc 签名完成（未检测到任何代码签名身份，仅供本机验证，无法公证/分发）"
            ;;
        developer-id)
            echo "   ✓ Developer ID 签名完成: $SIGN_IDENTITY"
            echo "     ⓘ 可公证、可正式分发"
            ;;
        self-signed)
            echo "   ✓ 自签身份签名完成: $SIGN_IDENTITY"
            echo "     ⓘ 自签能保住 TCC 授权，但无法公证、无法正式分发"
            ;;
        *)
            echo "   ✓ 使用指定签名身份签名完成: $SIGN_IDENTITY"
            ;;
    esac
else
    echo "   ❌ 签名失败" >&2
    exit 1
fi

# 回读校验：确认沙盒 entitlement **没有**被带进来，避免「以为没开沙盒其实开了」。
# 开了沙盒就列不出占用进程（本应用的核心价值），而这件事在界面上只表现为
# 「永远显示占用情况未知」——不做回读根本发现不了。
echo "   校验签名："
codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
    && { echo "     ❌ 直发渠道不应包含 App Sandbox entitlement（否则无法列出占用进程）"; exit 1; } \
    || echo "     ✓ 未启用 App Sandbox（直发版可枚举进程）"

# Sparkle 的回读：**构建和签名都不会因为框架没嵌入而失败**，只有双击运行时才炸
# （dyld: Library not loaded）。所以这里必须自己验三件事，缺一即停。
SPARKLE_EMBEDDED="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
[ -d "$SPARKLE_EMBEDDED" ] \
    || { echo "     ❌ 包内缺少 Contents/Frameworks/Sparkle.framework"; exit 1; }
[ -d "$SPARKLE_EMBEDDED/Versions/B/XPCServices" ] \
    || { echo "     ❌ Sparkle.framework 里缺 XPCServices（更新装不上：安装器跑在 XPC 里）"; exit 1; }
otool -l "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE" 2>/dev/null | grep -q "@executable_path/../Frameworks" \
    || { echo "     ❌ 可执行文件没有 @executable_path/../Frameworks 这条 rpath，dyld 找不到 Sparkle"; exit 1; }
echo "     ✓ Sparkle.framework 已嵌入，rpath 已就位"

# ---------------------------------------------------------------
# 分发产物打包（dmg / zip）
#
# 与公证**解耦**：NOTARIZE=1 时在公证流程中间调用（app 公证完 → 打 dmg → dmg 公证），
# PACKAGE=1 时独立调用。之所以要解耦，是因为公证强制要求 Developer ID 证书，
# 而开发期本机只有自签身份——旧写法把 dmg 生成焊在公证分支里，
# 导致「没有 Developer ID 就永远拿不到 dmg」，连出个内测包都做不到。
#
# 为什么 zip 不用 `zip` 命令：`zip` 会解引用符号链接、丢掉扩展属性，
# 框架里 Versions/Current 这类软链会被拍平成实体目录，解压后 app 直接损坏。
# `ditto -c -k --keepParent` 是 macOS 官方推荐的 bundle 归档方式，权限 / 扩展属性 / 软链都能保住。
#
# 为什么 dmg 里要放 Applications 替身：这是 dmg 相对 zip 的主要优势——
# 挂载后能把 app 直接拖进 /Applications，不必让用户自己找路径。
#
# 安装窗口的外观（背景图 + 图标位置）由两个**入库的**资产决定：
#   Resources/dmg/background.png —— 背景图（`Tools/make_dmg_background.py` 生成）
#   Resources/dmg/DS_Store       —— Finder 布局模板（`Tools/make_dmg_layout.sh` 生成）
# ⚠️ 打包期**不碰 Finder**：`.DS_Store` 是「生成一次、入库」的模板，这里只做拷贝。
# 所以 CI / 无 GUI 的环境照样能出带布局的 dmg（Finder 自动化只在**改布局**时才需要）。
# ⚠️ 两个文件**缺一不可，缺了就硬报错**：静默退化成「两个图标 + 一片空白」的窗口，
# 用户得自己猜「拖过去算安装」—— 而这正是 dmg 相对 zip 的唯一优势。
# ---------------------------------------------------------------
DMG_BACKGROUND="$PACKAGE_DIR/Resources/dmg/background.png"
DMG_DSSTORE_TEMPLATE="$PACKAGE_DIR/Resources/dmg/DS_Store"

create_dmg() {
    local dmg_path="$OUTPUT_DIR/$APP_NAME.dmg"
    local staging
    staging="$(mktemp -d)"
    # staging 建在 /var/folders 下，是脚本自建目录，失败路径也要清掉，
    # 否则每次打包都在临时目录里留一份 app 副本。
    # 双引号在此处是**故意**的：需要立即展开 ${staging}，而不是延迟到 trap 触发时
    # （那时函数已返回，local 变量出作用域，trap 里取到的会是空值）。
    trap "rm -rf '$staging'" EXIT
    ditto "$APP_BUNDLE" "$staging/$APP_NAME.app"
    ln -s /Applications "$staging/Applications"

    # 安装窗口的外观。`.background/` 是 Finder 约定的背景图位置（隐藏目录，用户看不见）。
    [ -f "$DMG_BACKGROUND" ] || {
        echo "❌ 缺 $DMG_BACKGROUND" >&2
        echo "   生成：python3 Tools/make_dmg_background.py" >&2
        exit 1
    }
    [ -f "$DMG_DSSTORE_TEMPLATE" ] || {
        echo "❌ 缺 $DMG_DSSTORE_TEMPLATE" >&2
        echo "   生成：./Tools/make_dmg_layout.sh（需要 Finder 自动化授权）" >&2
        exit 1
    }
    mkdir -p "$staging/.background"
    cp "$DMG_BACKGROUND" "$staging/.background/background.png"
    cp "$DMG_DSSTORE_TEMPLATE" "$staging/.DS_Store"

    rm -f "$dmg_path"
    hdiutil create -fs HFS+ -format UDZO -volname "$APP_NAME" -srcfolder "$staging" "$dmg_path" >/dev/null
    # ⚠️ **必须回读校验**（2026-09-28 实发 v2026.09.28.2 时踩到）：
    # `hdiutil create` **退出码 0 不代表产物可用** —— 那一轮就产出过一份「破坏的映像」
    # （文件头没有 GPT 保护分区，`hdiutil imageinfo` 直接说认不出），而这一行照样打
    # 「✓ 已生成 dmg」。它有**两种**暴露方式，都比这里晚、都比这里难懂：
    #   ① 走 `make_appcast.sh`：generate_appcast 解不开归档 ⇒
    #      `No usable archives found` —— 看起来像 appcast 的错、像 feed 配置的错；
    #   ② 直接 `PACKAGE=1` 出包就分发：**完全没人读**，要等用户下载后装不上才发现。
    # 判据的分辨力做过双向对照（同一次会话）：好 dmg 通过、那份坏 dmg 判失败。
    if ! hdiutil verify "$dmg_path" >/dev/null 2>&1; then
        echo "❌ dmg 生成了但**校验不过**：$dmg_path" >&2
        echo "   hdiutil create 会偶发产出损坏映像（2026-09-28 踩到过一次）。" >&2
        echo "   重跑本脚本即可；若反复出现，先查磁盘空间与 $OUTPUT_DIR 所在的卷。" >&2
        exit 1
    fi
    rm -rf "$staging"
    trap - EXIT
    echo "   ✓ 已生成 dmg（已回读校验）：$dmg_path"
}

create_zip() {
    local zip_path="$OUTPUT_DIR/$APP_NAME.zip"
    rm -f "$zip_path"
    ditto -c -k --keepParent "$APP_BUNDLE" "$zip_path"
    echo "   ✓ 已生成 zip：$zip_path"
}

# ---------------------------------------------------------------
# 公证 + 打包（NOTARIZE=1 时启用）
#
# 公证是直发版绕开 Gatekeeper 拦截的强制步骤（本应用只走直发，没有「由商店代审」这一路）。
# 前置条件：
#   1) SIGN_IDENTITY 必须是 Developer ID Application（ad-hoc「-」无法公证）
#   2) 下列三者之一提供 notarytool 凭证：
#      a. NOTARY_KEYCHAIN_PROFILE="<profile>"          # 事先 xcrun notarytool store-credentials 存过
#      b. APP_STORE_CONNECT_API_KEY_ID / _ISSUER / _PATH # App Store Connect API 密钥（.p8 文件路径）
#      c. APPLE_ID / APPLE_APP_PASSWORD / APPLE_TEAM_ID  # Apple ID + 应用专用密码
# ---------------------------------------------------------------
if [ "${NOTARIZE:-0}" = "1" ]; then
    if [ "$IDENTITY_KIND" != "developer-id" ]; then
        echo "   ❌ 公证需要 Developer ID Application 签名，当前身份「${SIGN_IDENTITY}」不被 notarytool 接受" >&2
        echo "      自签 / ad-hoc 签名均无法公证；请安装 Developer ID Application 证书后重试。" >&2
        exit 1
    else
        echo "▶ [5/5] 公证 + 打包 dmg ..."
        NOTARY_ARGS=()
        if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
            NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
        elif [ -n "${APP_STORE_CONNECT_API_KEY_ID:-}" ] && [ -n "${APP_STORE_CONNECT_API_KEY_ISSUER:-}" ] && [ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]; then
            NOTARY_ARGS=(--key "$APP_STORE_CONNECT_API_KEY_PATH" --key-id "$APP_STORE_CONNECT_API_KEY_ID" --issuer "$APP_STORE_CONNECT_API_KEY_ISSUER")
        elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
            NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
        else
            echo "   ❌ 未提供公证凭证：请设置 NOTARY_KEYCHAIN_PROFILE，或 App Store Connect API Key（APP_STORE_CONNECT_API_KEY_*），或 Apple ID（APPLE_ID/APPLE_APP_PASSWORD/APPLE_TEAM_ID）" >&2
            exit 1
        fi

        echo "   • 提交 .app 公证 ..."
        xcrun notarytool submit "$APP_BUNDLE" --wait "${NOTARY_ARGS[@]}" || { echo "   ❌ .app 公证失败"; exit 1; }
        xcrun stapler staple "$APP_BUNDLE"
        echo "   ✓ .app 已公证并钉入票根"

        echo "   • 打包 dmg ..."
        create_dmg
        DMG_PATH="$OUTPUT_DIR/$APP_NAME.dmg"
        echo "   • 提交 dmg 公证 ..."
        xcrun notarytool submit "$DMG_PATH" --wait "${NOTARY_ARGS[@]}" || { echo "   ❌ dmg 公证失败"; exit 1; }
        xcrun stapler staple "$DMG_PATH"
        echo "   ✓ dmg 已公证并钉入票根"
        create_zip
    fi
elif [ "${PACKAGE:-0}" = "1" ]; then
    # 本机无 Developer ID 证书时出 Release 资产：跳过公证，但产物结构与公证版保持一致。
    echo "▶ [5/5] 打包分发产物（dmg + zip，未经公证）..."
    echo "   ⓘ 未公证：用户首次打开会被 Gatekeeper 拦截，需右键「打开」放行"
    create_dmg
    create_zip
fi

echo ""
echo "=================================================="
echo " ✅ 应用已生成：$APP_BUNDLE"
echo "--------------------------------------------------"
echo " 渠道：官网直发（不开沙盒，可列出占用进程）"
case "$IDENTITY_KIND" in
    adhoc)
        echo " 签名：ad-hoc（无代码签名身份，仅供本机验证，无法公证/分发）"
        ;;
    developer-id)
        echo " 签名：Developer ID（${SIGN_IDENTITY}）—— 可公证、可正式分发"
        ;;
    self-signed)
        echo " 签名：自签（${SIGN_IDENTITY}）—— 保 TCC 授权稳定"
        echo "        ⓘ 自签无法公证 / 无法正式分发；拿到 Developer ID 证书后本脚本会自动改用它"
        ;;
    *)
        echo " 签名：指定身份（${SIGN_IDENTITY}）"
        ;;
esac
echo " 注意：用户需在「系统设置 › 隐私与安全性 › 完全磁盘访问」授权后检测才生效"
if [ "$IDENTITY_KIND" = "developer-id" ]; then
    echo " 正式分发：NOTARIZE=1 ./build_app.sh 自动公证并生成 dmg / zip"
else
    echo " 分发产物：PACKAGE=1 ./build_app.sh 生成未公证的 dmg / zip（供 GitHub Release 使用）"
fi
echo " 运行：        open \"$APP_BUNDLE\""
echo " 安装到系统：  cp -R \"$APP_BUNDLE\" /Applications/"
echo "=================================================="
