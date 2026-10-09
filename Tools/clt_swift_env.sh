#!/bin/bash
# Tools/clt_swift_env.sh —— 本机 Xcode **许可未接受**时，用 CLT 工具链照常跑 swift。
#
# 用法（**必须 source，不能直接执行**）：
#
#     source Tools/clt_swift_env.sh
#     swift test --disable-sandbox
#
# ## 为什么需要它（2026-09-21 查清）
#
# 症状是 `git` / `swift` / `xcodebuild` 全报
# 「You have not agreed to the Xcode license agreements」。
# 根因是 Xcode 从 26.4 升到 27.0，而 `/Library/Preferences/com.apple.dt.Xcode.plist`
# 里 `IDEXcodeVersionForAgreedToGMLicense` 还停在 `26.4`。
# **正解是 `sudo xcodebuild -license`（需要用户敲，本脚本替代不了）**；
# 本脚本只是让「等用户敲」的这段时间里本地还能验证。
#
# 绕开许可的办法是 `DEVELOPER_DIR=/Library/Developer/CommandLineTools`，
# 但 CLT 工具链**缺两样东西**，缺了会在两个完全不同的阶段报错
# （第一次遇到很容易以为是「许可还是没过」）：
#
# 1. **`xcstringstool`**（处理 `Sources/Localization/Localizable.xcstrings`）
#    CLT 里没有这个工具 ⇒ `xcrun --find xcstringstool` 失败
#    ⇒ SwiftPM 回落到**裸名字**、按**包根**解析成 `<仓库>/xcstringstool`
#    ⇒ 报「`.../SafeOut/xcstringstool` is not an executable file」。
#    实测过三条「放哪儿」的路，只有最后一条成立：
#      - **调用目录**相对 ✗ —— 从别的目录 `swift build --package-path <仓库>`，
#        报的仍然是 `<仓库>/xcstringstool`（是**包根**相对）；
#      - **PATH** ✗ —— `xcrun` 自己的报错文案里那句
#        「not a developer tool **or in PATH**」是真的（我手动跑
#        `PATH=<目录>:$PATH xcrun --find xcstringstool` 确实找得到），
#        但 **SwiftPM 内部那次查找看不到 PATH**：实测子进程 env 里
#        `PATH` 已经含了那个目录，SwiftPM 用的仍是包根裸路径。
#      - **包根软链** ✓ —— 这一条是确定性的，也是本脚本采用的。
#    ⚠️ 附带一个坑：`xcrun` 有**查找缓存** `$TMPDIR/xcrun_db`。缓存里存着
#    旧路径时，`xcrun --find` 会返回一个**已经不对**的路径（我踩过一次：
#    它返回的是上一轮实验的临时目录），所以本脚本顺手清掉这个缓存。
#
# 2. **`libSwiftUIMacros.dylib`**（`@State` / `@Binding` 这类宏的实现体）
#    它不在 toolchain 的 `usr/lib/swift/host/plugins` 里，而在
#    **platform** 目录 `MacOSX.platform/Developer/usr/lib/swift/host/plugins`。
#    CLT 没有 `Platforms/` ⇒ 编译器找不到 ⇒ 满屏
#    「external macro implementation type 'SwiftUIMacros.StateMacro' could not be found」。
#    这一样没有 PATH 捷径，只能靠 `-Xswiftc -plugin-path`。
#
# ⚠️ **本地门槛绿 ≠ CI 绿，这里还多一条**：CLT 的 SDK 与 Xcode 的 SDK 不是同一个
# （实测 `DEVELOPER_DIR=CLT` 时用 `MacOSX27.0.sdk`，而 `xcode-select -p` 指向 Xcode），
# **编译器版本也不同** ⇒ 诊断的集合不一样。2026-09-21 实测两条：
#
# - **门槛 1（`-warnings-as-errors`）会红**：CLT 的 Swift 6.4 对
#   `Sources/SafeOutApp/SafeOutApp.swift:633` 报 `ImplicitStrongCapture`
#   （`Task {}` 强捕获 self，而内层闭包写 `[weak self]`），CI 的 Xcode 工具链**不报**这条。
#   ⇒ 这是**工具链差异**，不是代码问题：别为了让本地门槛变绿去改生产代码。
# - **门槛 8 偶发红**：`IntegrationEjectTests.真实占用时关闭进程并推出` 要真的
#   `hdiutil attach` 一个 dmg 并让它被认成外置盘，这台机器上偶发「未找到测试盘」
#   （同一条单独跑 2/2 绿、全量 `swift test` 也绿）。属环境性。
#
# 所以本脚本跑出来的绿**只是「没写坏」的证据**，验收仍以 CI 为准。
# 用户敲完 `sudo xcodebuild -license` 之后，本脚本会自动变成空操作 ——
# 那时本地与 CI 用的是**同一套工具链**，上面两条差异自然消失。
#
# ⚠️ **一次性的坑：磁盘上的「构建计划」会记住旧结论**
# 若你**先**在「包根没有软链」的状态下跑过一次 `swift build`（比如没 source 本脚本
# 就直接跑），SwiftPM 会把那份**解析失败**的计划写到 `.build/` 下，之后即使软链补上，
# 它也照样报同一句「`.../xcstringstool` is not an executable file」——
# 而这一次**软链明明是好的**（`[ -x ]` 为真、`ls -l` 指向真二进制）。
# 判据是输出里那句 `[Using on-disk description]`（复用磁盘计划，没有重新规划）。
# 解法是把计划挪走重来（**不要删**，留个后路）：
#
#     mv .build/out .build/out.old
#
# 本脚本不自动做这件事：它不该在一次「source 环境」里顺手清掉几十秒的构建缓存。

# ⚠️ **不要 `set -u`**：本脚本是 source 用的，`set` 会**泄漏给调用方的 shell**，
# 后面随便哪条命令碰到未定义变量就炸 —— 症状与「环境没配好」逐字相同。
# 需要的地方一律写 `${VAR:-}`。

# 解析自身位置：bash 有 `BASH_SOURCE`，zsh 没有（`${(%):-%x}` 那种 zsh 语法
# 在 bash 里是**解析期**错误，不能写）；两边都不成立时退回 `$PWD` 并用 Package.swift 自证。
_self="${BASH_SOURCE[0]:-}"
_repo_root=""
if [ -n "$_self" ]; then
    _repo_root="$(cd "$(dirname "$_self")/.." && pwd)"
fi
if [ -z "$_repo_root" ] || [ ! -f "$_repo_root/Package.swift" ]; then
    _repo_root="$PWD"
fi
if [ ! -f "$_repo_root/Package.swift" ]; then
    echo "  [clt-swift] 找不到仓库根（当前 $PWD 下没有 Package.swift）—— 请在仓库根目录 source 本脚本" >&2
    return 1 2>/dev/null || exit 1
fi

# ① 许可已经接受 ⇒ 什么都不做（正路优先，避免把 CLT 当成常态）
#
# ⚠️ **判据必须看输出，不能看退出码**：许可未接受时 `xcodebuild -version` 会
# 把警告打进输出、**退出码仍是 0**（`swift --version` 也一样）。按退出码判
# ⇒ 这个分支**永远成立** ⇒ 脚本静默空操作、后面照旧报许可错，
# 而看起来像「脚本没生效」。改成问 `xcrun --find` 要一个**绝对路径**：
# 拿到了就是许可过了，拿到警告文案就不是。
#
# ⚠️⚠️ **末尾的 `|| true` 不是装饰，去掉会「静默杀掉调用方」**（2026-09-24 实测）：
# `xcrun` 在许可未接受时的退出码是 **69**（与 `xcodebuild -version` 的 0 **不同**，
# 别把两者的结论互相套用）。而**「变量赋值 = 简单命令」**，`set -e` 下这个非零状态
# 会**直接终止整个脚本** —— 调用方若写了 `set -e`（写测试脚本的常态），
# 症状是：**零输出 + 退出码 69**，连本脚本下面那些自证行都打不出来，
# 看起来与「脚本根本没被 source」「环境更烂了」**逐字相同**。
# 判据（两条互为对照，同一台机器上跑）：
#   bash -c 'source Tools/clt_swift_env.sh; echo AFTER'      → rc=0，8 行自证 ✅
#   bash -c 'set -e; source Tools/clt_swift_env.sh; echo AFTER' → rc=69，零输出 ❌
# ⇒ 一般规律：**`$( )` 的结果要当数据用（而非当状态用）时，一律补 `|| true`** ——
#   否则「取到的内容」与「命令成不成功」被绑成同一件事，而前者才是本意。
_probe="$(/usr/bin/xcrun --find swiftc 2>&1)" || true
case "$_probe" in
    /*)
        echo "  [clt-swift] Xcode 许可正常，无需绕过（本脚本空操作）"
        return 0 2>/dev/null || exit 0
        ;;
esac

_clt=/Library/Developer/CommandLineTools
if [ ! -d "$_clt" ]; then
    echo "  [clt-swift] 找不到 $_clt —— 请先装 Command Line Tools，或直接 sudo xcodebuild -license" >&2
    return 1 2>/dev/null || exit 1
fi

# ② 找 Xcode 里那两个 CLT 缺的东西（不假设 Xcode 一定在 /Applications）
_xcode_dev=""
for candidate in "$(xcode-select -p 2>/dev/null)" /Applications/Xcode.app/Contents/Developer; do
    [ -n "$candidate" ] && [ -x "$candidate/usr/bin/xcstringstool" ] && { _xcode_dev="$candidate"; break; }
done
if [ -z "$_xcode_dev" ]; then
    echo "  [clt-swift] 找不到 Xcode 的 Developer 目录（xcstringstool 在那里）—— 只能先 sudo xcodebuild -license" >&2
    return 1 2>/dev/null || exit 1
fi
_plugin_dir="$_xcode_dev/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

# 宏插件要挂**三处**，少一处就有一类代码编不过（每一处都对应一个实测过的报错）：
#   ① `<CLT>/usr/lib/swift/host/plugins`        —— Observation / Swift 宏（SwiftPM 会自己带上，
#                                                  留着是为了「SwiftPM 哪天不带了」也不炸）
#   ② 上面的 `testing/` 子目录                   —— `libTestingMacros.dylib`（`#expect`）。
#      ⚠️ 它**藏在子目录里**，SwiftPM 扫插件只扫顶层 ⇒ 不挂就报
#      「external macro implementation type 'TestingMacros.ExpectMacro' could not be found」。
#      实测「点 `testing` 自己」与「点它的父目录」都试过，两个都留着最省事。
#   ③ Xcode 的 **platform** 目录                —— `libSwiftUIMacros.dylib`（`@State`）。
#      它不在 toolchain 里，CLT 也没有 `Platforms/`。
_clt_plugins="$_clt/usr/lib/swift/host/plugins"
_plugin_args="-Xswiftc -plugin-path -Xswiftc $_clt_plugins"
_plugin_args="$_plugin_args -Xswiftc -plugin-path -Xswiftc $_clt_plugins/testing"
_plugin_args="$_plugin_args -Xswiftc -plugin-path -Xswiftc $_plugin_dir"

# ③ 造一个只属于自己的 bin 目录（放 .build/ 下 ⇒ 不进 git）
_bin="$_repo_root/.build/clt-toolchain/bin"
mkdir -p "$_bin" || { echo "  [clt-swift] 建不出 $_bin" >&2; return 1 2>/dev/null || exit 1; }
ln -sfn "$_xcode_dev/usr/bin/xcstringstool" "$_bin/xcstringstool"
# ⚠️ **包根那一份才是真正起作用的**（SwiftPM 只认它，见文件头第 1 条）。
# `.gitignore` 里锚定了 `/xcstringstool`，所以它不会出现在 `git status` 里。
ln -sfn "$_xcode_dev/usr/bin/xcstringstool" "$_repo_root/xcstringstool"
# `xcrun` 的查找缓存会返回**过期的路径**，清掉免得下一个排查的人被它带偏。
rm -f "${TMPDIR:-/tmp}/xcrun_db"

# `swift` 包装：只给 build/test/run 追加 `-plugin-path`。
# ⚠️ 不能无条件追加 —— `swift --version` / `swift package describe` 不认 `-Xswiftc`，
# 追加了会把不相关的命令弄坏（而那种坏法看起来像「环境更烂了」）。
#
# ⚠️⚠️ **参数必须插在「子命令之后、可执行名之前」，不能追加在整条命令末尾**
# （2026-09-24 实测查清；此前一直追加在末尾，导致 `./run.sh` **一直是坏的**）：
#
# `swift run` 的官方用法行是
#     swift run [<options>] [<executable>] [<arguments> ...]
# —— 可执行名**之后**的东西是**传给程序的**，不是给 SwiftPM 的。
# 所以旧写法 `swift run SafeOutApp -Xswiftc -plugin-path …` 里，
# 那几个 `-Xswiftc` 全被当成**应用自己的参数**吃掉了，构建**一个插件路径都没拿到**，
# 于是满屏 `SwiftUIMacros.StateMacro could not be found`（`@State` 编不过）。
#
# 判据（两条实测，互为对照；`definitely-nope-xyz` 是造出来的 token）：
#   `swift run -v SafeOutApp -Xswiftc -plugin-path -Xswiftc /tmp/definitely-nope-xyz`
#       → 构建输出里 token 出现 **0 次**（参数没进构建）
#   `swift run -v -Xswiftc -plugin-path -Xswiftc /tmp/definitely-nope-xyz SafeOutApp`
#       → token 出现 **5 次**（参数进了构建）
#
# ⚠️ **为什么以前没被发现**：`swift build` / `swift test` **没有位置参数**
# （`swift build [<options>]`），末尾追加的选项照样被解析成选项 ⇒ 那两条一直是对的。
# 只有 `swift run <exe>` 有「可执行名」这个分水岭，**只有它中招**。
# ⇒ 一般规律：**往别人命令行末尾追加参数时，先问「这条命令有没有位置参数」**。
#
# ⚠️ 顺带一个「症状与真因不同形」的坑：`swift run` 失败时报的是**宏插件找不到**，
# 看起来像「CLT 又缺东西 / 脚本没生效」，而真因是**参数位置**。
# 排查时不要停在第一层症状上——先 `-v` 把**真实命令行**抓出来，
# 与 `swift build -v` 成功的命令行**逐项对拍**（那次成功的命令行长 3960 字符、
# 用的是 `swiftc @<响应文件>`，`SwiftUIMacros` 在可见行里出现 0 次、其实在响应文件里）。
cat >"$_bin/swift" <<WRAPPER
#!/bin/bash
# 由 Tools/clt_swift_env.sh 生成，请勿手改（下次 source 会覆盖）。
export DEVELOPER_DIR="$_clt"
case "\${1:-}" in
    build | test | run)
        _sub="\$1"
        shift
        exec /usr/bin/swift "\$_sub" $_plugin_args "\$@"
        ;;
    *)
        exec /usr/bin/swift "\$@"
        ;;
esac
WRAPPER
chmod +x "$_bin/swift"

# ④ 生效
export DEVELOPER_DIR="$_clt"
case ":$PATH:" in
    *":$_bin:"*) ;;
    *) PATH="$_bin:$PATH" ;;
esac
export PATH

# ⑤ 自证（⚠️ 装置必须自己证明自己生效了：下面每一行都要有确定的值）
#
# ⚠️ 这里**不报 `xcrun --find xcstringstool`**：它返回什么与「SwiftPM 能不能用」
# **没有关系**（SwiftPM 那次查找看不到 PATH，见文件头第 1 条）。
# 报一个与成败无关的数字，只会让下一个排查的人拿它当判据 —— 所以只报真正起作用的那个。
echo "  [clt-swift] DEVELOPER_DIR=$DEVELOPER_DIR"
echo "  [clt-swift] which swift → $(command -v swift)"
echo "  [clt-swift] 包根 xcstringstool → $([ -x "$_repo_root/xcstringstool" ] && echo "可执行（$_repo_root/xcstringstool）" || echo "缺")"
echo "  [clt-swift] 宏插件 ① Swift/Observation → $([ -f "$_clt_plugins/libSwiftMacros.dylib" ] && echo 有 || echo 缺)"
echo "  [clt-swift] 宏插件 ② Testing           → $([ -f "$_clt_plugins/testing/libTestingMacros.dylib" ] && echo 有 || echo 缺)"
echo "  [clt-swift] 宏插件 ③ SwiftUI           → $([ -f "$_plugin_dir/libSwiftUIMacros.dylib" ] && echo 有 || echo 缺)"
# ⚠️ **参数顺序也是判据，不是风格**（2026-09-24）：`run` 那一路的插件参数必须排在
# **可执行名之前**，否则 `swift run` 会把它们当成**应用自己的参数** ⇒ 构建拿不到插件路径
# ⇒ `./run.sh` 报「SwiftUIMacros.StateMacro could not be found」。上面 wrapper 段有实测。
# 用 `grep -F`（固定串）：ERE 里 `$` 在中段是字面量还是锚，各家实现不一致，别赌。
if grep -qF 'exec /usr/bin/swift "$_sub" ' "$_bin/swift"; then
    echo "  [clt-swift] 包装器参数顺序           → 插件参数排在子命令之后（run 也吃得到）✅"
else
    echo "  [clt-swift] 包装器参数顺序           → ⚠️ 插件参数没排在可执行名之前 ⇒ ./run.sh 会构建失败" >&2
fi
echo "  [clt-swift] ⚠️ CLT 的 SDK 与 CI 的 Xcode SDK 不是同一把尺子：本地绿只证明「没写坏」"
