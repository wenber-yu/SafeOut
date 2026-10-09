import Foundation
import Testing

/// 守「**读像素 / 出图**」两条路的**唯一入口**（2026-09-23，`DESIGN-SPEC.md` §8.131）。
///
/// ## 为什么需要这一条守卫
///
/// `Tests/` 里原先有 7 个文件各自手写「逐像素读像素循环」，另有 3 份各写一遍的
/// `NSBitmapImageRep(bitmapDataPlanes: nil, …)` 出图块。2026-09-23 把它们收敛进
/// `OffscreenRender`。收敛的收益有两块，**缺一不可**：
///
/// 1. **快约 400 倍**：旧写法每次要构造一个 `NSColor`（原语探针实测 **0.773 µs/次**），
///    缓冲区直读是 **0.002 µs/次**。整轮测试（汇总行口径、**同一会话内 A/B** 各三次取均值）
///    **9.156s → 7.590s**（净省 1.566s / 约 17%），两组区间**完全不重叠**（探针与数字见 §8.131）。
///    ⚠️ 别拿**跨批次**的「三连跑」说事：同一份代码不同批次可以差 1s 以上（§8.131.9）。
/// 2. **判据只有一个来源**：0.75 那条墨迹阈值原先在 `Tests/` 里**逐字抄了 6 遍** ——
///    改阈值漏掉一处，就会有一条测试在守**另一个判据**，而**没有任何东西会红**。
///    ⚠️ 这一条**不是**本守卫守的：它由 `OffscreenRenderParityTests.三种新形状与参考实现一致`
///    钉住（参考实现里写死 0.75，改了 `isInk` 就红）。本守卫守的是**入口**。
///
/// 还有第三条，是 2026-09-22 那次 **CI 红**（§8.130）的直接教训：副本里的
/// `c.redComponent` 隐式转 `Double`，**本地 Swift 6.4 接受、CI 的 6.3.3 拒绝**
/// ⇒ 副本越多，「本地绿 CI 红」的面越大。
///
/// ## 口径（静态扫源码 —— §8.96 的教训是「静态扫描器的错多半是口径错」）
///
/// 1. 扫 `Tests/` + `Sources/` 的**全部 `.swift`**。产品代码里也有两处（见清单末条）——
///    漏掉那一半就是「范围」错误：清单看起来齐了，实际只扫了一半。
/// 2. 先剥**整行**注释（行首空白后以 `//` 开头）—— 本文件的说明里就写着这两个词，
///    不剥的话**文档会把自己判成违规**（「文档越全、越容易误报」的经典形状）。
/// 3. ⚠️ 读像素那一半用 **`colorAt(x:`** 而不是裸词 `colorAt`：裸词会把**函数名**
///    （`透明底样本直读与colorAt逐像素相等`）与**失败信息里的字符串**一起数进去，
///    于是「改个测试名」也会让计数变 —— 守卫变成噪音就会被关掉。
/// 4. 清单是**双向棘轮**：清单外出现 ⇒ 红；清单里登记了却没出现 ⇒ 红；
///    次数与登记不符 ⇒ 红（**多了**是「又加了一个读像素点」，**少了**是「还了账要回来划掉」）。
/// 5. **跳过本文件** —— 上面两个模式串就写在本文件里（`MainActorBlockingTests` 同款处理）。
///
/// ## 为什么用「次数」而不是「有没有」
///
/// 只判「这个文件出现过」的话，在已允许的文件里**再抄一段循环**照样绿 ——
/// 而那正是本轮要防的回退。次数棘轮把「在 `VisualStyleTests` 里加第二个读像素点」
/// 也拦下来。
///
/// ## 已知局限（故意不修，当前实测 0 例）
///
/// - 次数按**子串出现次数**数：一次调用跨两行写成 `rep.colorAt(\n  x: …)` 会漏。
/// - 只认 `bitmapDataPlanes` 这一个「新分配位图」的标记；用 `NSBitmapImageRep(cgImage:)`
///   或 `NSBitmapImageRep(data:)` 绕过去的写法看不见（本仓 `Tests/` 里 0 例）。
struct PixelReadPathTests {

    // MARK: - 扫描器（纯函数，便于用合成样本做对照）

    /// 读像素的**调用形状** —— 口径第 3 条。
    private static let colorAtCall = "colorAt(x:"

    /// 「新分配一块位图」的标记：`bitmapDataPlanes` 只出现在那个 init 里。
    private static let bitmapAllocation = "bitmapDataPlanes"

    /// 去掉**整行**注释（行首空白后以 `//` 开头）—— 与 `MainActorBlockingTests` 同一口径。
    static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// `code` 里 `needle` 出现的次数。
    static func count(of needle: String, in code: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return code.components(separatedBy: needle).count - 1
    }

    /// 扫 `Tests/` + `Sources/` 的全部 `.swift`，返回（相对仓库根的路径 → 次数，扫过的文件数）。
    ///
    /// 只收次数 > 0 的文件 —— 清单里「登记了却没出现」由 `ratchetDiff` 的另一半判。
    static func scan(needle: String) throws -> (found: [String: Int], scanned: Int) {
        let repoRoot =
            URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SafeOutAppTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // 仓库根
        // ⚠️ 跳过本文件：上面两个模式串就写在本文件里，不跳过会**自己把自己判红**。
        let selfName = URL(fileURLWithPath: #filePath).lastPathComponent
        var found: [String: Int] = [:]
        var scanned = 0

        for dir in ["Tests", "Sources"] {
            let root = repoRoot.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            else {
                Issue.record("枚举不到 \(root.path) —— 这一半的结果不可信")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard url.lastPathComponent != selfName else { continue }
                scanned += 1
                let code = Self.codeOnly(try String(contentsOf: url, encoding: .utf8))
                let n = Self.count(of: needle, in: code)
                guard n > 0 else { continue }
                let prefix = repoRoot.path + "/"
                let rel =
                    url.path.hasPrefix(prefix)
                    ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
                found[rel] = n
            }
        }
        return (found, scanned)
    }

    /// **双向棘轮**差集（纯函数，便于用合成样本做对照）。
    static func ratchetDiff(
        found: [String: Int], ledger: [String: (count: Int, reason: String)]
    ) -> (unregistered: [String], stale: [String], countMismatch: [String]) {
        let unregistered = Set(found.keys).subtracting(ledger.keys).sorted()
        let stale = Set(ledger.keys).subtracting(found.keys).sorted()
        let countMismatch =
            found
            .filter { key, n in ledger[key].map { $0.count != n } ?? false }
            .map(\.key)
            .sorted()
        return (unregistered, stale, countMismatch)
    }

    // MARK: - 清单

    /// 允许出现 `colorAt(x:` 的**文件 → （次数，理由）**。
    ///
    /// 每条理由必须回答「**为什么这一条不能走 `OffscreenRender`**」——
    /// 写「历史原因」「暂时保留」等于没写（理由短于 12 字会被下面判红）。
    private static let colorAtAllowlist: [String: (count: Int, reason: String)] = [
        "Tests/SafeOutAppTests/OffscreenRender.swift": (
            2,
            "出图装置本体：`rgb(_:x:y:)` 与 `forEachPixel` 的**兜底分支** —— 位图布局不认识时才走"
        ),
        "Tests/SafeOutAppTests/OffscreenRenderParityTests.swift": (
            8,
            "等价性守卫：**参考实现**必须逐字保留旧写法当对照（7 处），另有 1 处逐像素对照"
        ),
        "Tests/SafeOutAppTests/VisualStyleTests.swift": (
            1,
            "单像素读取，判据是整颗 `NSColor`（**含 alpha**）的 `isEqual` —— 三通道 API 给不出 alpha"
        ),
        "Tests/SafeOutAppTests/GlassSurfaceTests.swift": (
            1,
            "单像素读取 + 显式 `usingColorSpace(.sRGB)` 换算 —— 直读给的是 deviceRGB 原始字节"
        ),
        "Tests/SafeOutAppTests/ImplicitCGFloatConversionTests.swift": (
            1,
            "**不是代码**：多行字符串里的合成样本（就是 §8.130 CI 红掉的那一行）"
        ),
        "Sources/SafeOutApp/WindowSelfCheck.swift": (
            2,
            "产品代码：读**真机截图**的像素（`captureWindowImage` 抓的位图，两处逐像素扫描）"
                + " —— 不在测试 target，用不到 `OffscreenRender`"
        ),
    ]

    /// 允许出现 `bitmapDataPlanes` 的**文件 → （次数，理由）**。
    private static let bitmapAllowlist: [String: (count: Int, reason: String)] = [
        "Tests/SafeOutAppTests/OffscreenRender.swift": (
            1,
            "出图装置本体：`bitmap(_:size:appearance:background:)` —— 所有离屏出图的唯一入口"
        ),
        "Tests/SafeOutAppTests/SnapshotRenderTests.swift": (
            1,
            "把**已经布局好的 `NSView`** 光栅化成 PNG —— 入口收 `NSView` 不是 SwiftUI `View`，且要写文件"
        ),
    ]

    // MARK: - 守卫

    /// 读像素只许走 `OffscreenRender` 一条路。
    @Test("读像素只走 OffscreenRender 一条路")
    func 读像素只走一条路() throws {
        // ① 装置自证：双向阳性对照（§8.96.4）。
        //    只报「没找到」的装置与「瞎了」的装置，输出**逐字相同** —— 必须先证明它有牙。
        #expect(
            Self.count(
                of: Self.colorAtCall,
                in: Self.codeOnly("guard let c = rep.colorAt(x: x, y: y) else { continue }")) == 1,
            "阳性对照：逐像素读必须被数到。数不到 ⇒ 装置瞎了，下面的结果不可信")
        #expect(
            Self.count(
                of: Self.colorAtCall, in: Self.codeOnly("let c = rep.colorAt(x: 20, y: 20)")) == 1,
            "阳性对照：**单像素**读取同样是这一条路的例外，必须被数到 —— 否则它就成了清单外的漏洞")
        #expect(
            Self.count(
                of: Self.colorAtCall,
                in: Self.codeOnly("@Test func 白底样本直读与colorAt逐像素相等() {}")) == 0,
            """
            阴性对照：**函数名**里的 `colorAt` 不许被数到。
            数了就说明口径退回了裸词匹配 —— 那样「改个测试名」也会让计数变，守卫立刻变成噪音。
            """)
        #expect(
            Self.count(of: Self.colorAtCall, in: Self.codeOnly("// rep.colorAt(x: x, y: y)")) == 0,
            "阴性对照：注释里的不算 —— 否则本文件（以及所有文档）会把自己判红")

        // ② 棘轮的两个方向各来一条对照。
        let onlyFound = Self.ratchetDiff(found: ["A.swift": 1], ledger: [:])
        #expect(
            onlyFound.unregistered == ["A.swift"] && onlyFound.stale.isEmpty
                && onlyFound.countMismatch.isEmpty,
            "阳性对照：**清单外出现**必须报（新写一个读像素点就是这条拦下）")
        let onlyLedger = Self.ratchetDiff(found: [:], ledger: ["A.swift": (1, "理由写得足够长")])
        #expect(
            onlyLedger.stale == ["A.swift"] && onlyLedger.unregistered.isEmpty,
            "阳性对照：**登记了却没出现**也必须报（还了账要回来划掉，别安静地烂在表里）")
        let more = Self.ratchetDiff(found: ["A.swift": 2], ledger: ["A.swift": (1, "理由写得足够长")])
        #expect(
            more.countMismatch == ["A.swift"],
            "阳性对照：**次数变多**必须报 —— 这就是「在已允许的文件里又抄了一段循环」")
        let fewer = Self.ratchetDiff(found: ["A.swift": 1], ledger: ["A.swift": (2, "理由写得足够长")])
        #expect(
            fewer.countMismatch == ["A.swift"],
            "阳性对照：**次数变少**也要报（收敛掉一处之后要回来把数改小）")
        let same = Self.ratchetDiff(found: ["A.swift": 1], ledger: ["A.swift": (1, "理由写得足够长")])
        #expect(
            same.unregistered.isEmpty && same.stale.isEmpty && same.countMismatch.isEmpty,
            "阴性对照：两边一致不许报 —— 报了就把守卫逼成噪音")

        // ③ 真扫。
        let (found, scanned) = try Self.scan(needle: Self.colorAtCall)

        // ④ 装置自证：真的扫到了足够多的文件、也真的数到了足够多的调用。
        //    否则「差集为空」可能只是「一个都没扫」或「模式串没匹配上」—— 三者断言层面完全一样。
        #expect(
            scanned > 80,
            "只扫到 \(scanned) 个文件 —— 枚举很可能没生效，结果不可信（2026-09-23 实测 98 个，本文件除外）")
        #expect(
            found.values.reduce(0, +) > 10,
            "只数到 \(found.values.reduce(0, +)) 处 —— 模式串很可能失效了，结果不可信（2026-09-23 实测 15 处）")

        // ⑤ 理由不许敷衍（沿用本仓库「理由短于 12 字算敷衍」的口径）。
        let thin = Self.colorAtAllowlist.filter { $0.value.reason.count < 12 }.keys.sorted()
        #expect(thin.isEmpty, "这些条目的理由太短，等于没写：\(thin.joined(separator: "、"))")

        // ⑥ 双向棘轮。
        let diff = Self.ratchetDiff(found: found, ledger: Self.colorAtAllowlist)
        #expect(
            diff.unregistered.isEmpty,
            """
            这些文件手写了**读像素**的调用，但不在清单里：\(diff.unregistered.joined(separator: "、"))。
            读像素一律走 `OffscreenRender`：计数用 `inkCount(_:in:scale:)`、
            区间用 `inkColumnRange(_:rows:maxX:scale:)` / `inkRowRange(_:columns:rows:scale:)`、
            自定义谓词用 `forEachPixel(_:in:scale:)`。
            手写的坏处不是「风格不统一」：旧写法每次构造一个 `NSColor`（实测 0.773 µs/次，
            直读 0.002 µs/次，差约 400 倍），而且 0.75 那条判据会跟着抄出去、改了不会有人红（§8.131）。
            确实不能收敛的（要 alpha / 要 `usingColorSpace` 换算 / 读的不是离屏位图），
            把**文件名 + 次数 + 理由**加进 `colorAtAllowlist`。
            """)
        #expect(
            diff.stale.isEmpty,
            """
            这些文件登记在清单里，但**已经没有**这类调用了：\(diff.stale.joined(separator: "、"))。
            说明有人收敛掉了它（好事）⇒ 回来把这一条**划掉**（§8.33 的教训：别让条目安静地烂在表里）。
            """)
        #expect(
            diff.countMismatch.isEmpty,
            """
            这些文件的**次数与登记不符**：\(diff.countMismatch.joined(separator: "、"))。
            变多 = 又在同一个文件里加了一个读像素点 ⇒ 要么收敛，要么连同理由一起改登记数；
            变少 = 收敛掉了 ⇒ 回来把数改小。棘轮只许往紧的方向走。
            """)
    }

    /// 出图只许走 `OffscreenRender` 一条路。
    @Test("离屏出图只走 OffscreenRender 一条路")
    func 出图只走一条路() throws {
        // ① 装置自证：双向阳性对照（§8.96.4）。
        #expect(
            Self.count(
                of: Self.bitmapAllocation,
                in: Self.codeOnly("let rep = NSBitmapImageRep(\n    bitmapDataPlanes: nil,")) == 1,
            "阳性对照：`bitmapDataPlanes` 必须被数到。数不到 ⇒ 装置瞎了，下面的结果不可信")
        #expect(
            Self.count(of: Self.bitmapAllocation, in: Self.codeOnly("// bitmapDataPlanes: nil,")) == 0,
            "阴性对照：注释里的不算 —— 否则本文件（以及所有文档）会把自己判红")
        #expect(
            Self.count(
                of: Self.bitmapAllocation, in: Self.codeOnly("let rep = NSBitmapImageRep(cgImage: cg)"))
                == 0,
            "阴性对照：`NSBitmapImageRep(cgImage:)` 是**包装已有位图**，不是新分配 —— 不许数进去")

        // ② 棘轮的两个方向各来一条对照。
        let onlyFound = Self.ratchetDiff(found: ["A.swift": 1], ledger: [:])
        #expect(
            onlyFound.unregistered == ["A.swift"],
            "阳性对照：**清单外出现**必须报（新写一份出图块就是这条拦下）")
        let more = Self.ratchetDiff(found: ["A.swift": 2], ledger: ["A.swift": (1, "理由写得足够长")])
        #expect(more.countMismatch == ["A.swift"], "阳性对照：**次数变多**必须报")

        // ③ 真扫。
        let (found, scanned) = try Self.scan(needle: Self.bitmapAllocation)

        // ④ 装置自证。
        #expect(
            scanned > 80,
            "只扫到 \(scanned) 个文件 —— 枚举很可能没生效，结果不可信（2026-09-23 实测 98 个，本文件除外）")
        #expect(
            found.values.reduce(0, +) >= 2,
            "只数到 \(found.values.reduce(0, +)) 处 —— 模式串很可能失效了（2026-09-23 实测 2 处）")

        // ⑤ 理由不许敷衍。
        let thin = Self.bitmapAllowlist.filter { $0.value.reason.count < 12 }.keys.sorted()
        #expect(thin.isEmpty, "这些条目的理由太短，等于没写：\(thin.joined(separator: "、"))")

        // ⑥ 双向棘轮。
        let diff = Self.ratchetDiff(found: found, ledger: Self.bitmapAllowlist)
        #expect(
            diff.unregistered.isEmpty,
            """
            这些文件手写了**新分配位图**的出图块，但不在清单里：\(diff.unregistered.joined(separator: "、"))。
            出图一律走 `OffscreenRender.bitmap(_:size:appearance:background:)`。
            自建位图的坏处不只是重复：缓冲区的布局（`samplesPerPixel` / `bitmapFormat` / 预乘）
            要自己保证与 `PixelBuffer` 认识的那套一致，错一步扫出来的计数**照样是个合理的整数**（§8.131）。
            确实不能收敛的（收 `NSView` 不是 `View`、要写 PNG、要透明宿主），
            把**文件名 + 次数 + 理由**加进 `bitmapAllowlist`。
            """)
        #expect(
            diff.stale.isEmpty,
            "这些文件登记在清单里，但**已经没有**这类调用了：\(diff.stale.joined(separator: "、")) ⇒ 回来把这一条划掉。")
        #expect(
            diff.countMismatch.isEmpty,
            "这些文件的**次数与登记不符**：\(diff.countMismatch.joined(separator: "、")) —— 棘轮只许往紧的方向走。")
    }
}
