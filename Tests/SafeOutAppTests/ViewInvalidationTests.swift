import Foundation
import Testing

/// 守「**订阅随读取走**」这条规矩（2026-09-24 立）。
///
/// ## 它守什么
///
/// `@ObservedObject` 订阅的是 `objectWillChange` **整条**，不是「body 里读到的那几个属性」。
/// 于是「挂上去但只读一两个属性」和「挂上去什么都不读」在失效范围上**没有区别**：
/// 只要挂上，对方一发通知，整个视图就重算。
///
/// 本项目里最贵的一处是 ``OccupancyStore``：它每 15s 跑一次 `lsof`（还会被「回到前台」
/// 触发），而它的结论只有**磁盘行**用得上。曾经 ``ContentView`` 与 ``MenuPopoverView``
/// 各自挂着一个 `@ObservedObject` ⇒ 每次占用刷新都把整个窗口 / 整个面板重建一遍
/// （标题栏计数、FDA 横幅、分隔线、四行动作区全跟着重算），而那些地方一个字节都没变。
///
/// 修法是把订阅**下移**到真正读它的子视图（``DiskListRegion`` / ``MenuDiskList``），
/// 上层只把它当**参数**传下来。
///
/// ## 为什么值得写测试
///
/// 这条规矩**违反了没有任何症状**：界面照常显示、测试照常绿，只是白重算。
/// 而「图省事在上层挂一个 `@ObservedObject`」是**最自然的手滑** ——
/// 尤其当以后有人要在标题栏显示「占用中 N 块盘」时。
///
/// ⚠️ 光靠「把 body 拆成计算属性」**达不到**这个效果：计算属性会被内联进同一个 body，
/// 失效范围一点没变小。必须拆成独立 struct —— 下面两条断言把**两半都钉住**。
@Suite("订阅随读取走（视图失效范围）")
struct ViewInvalidationTests {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SafeOutAppTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // 仓库根
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 取出**某个顶层 `struct` 的区间**（从它的声明行到下一个顶层声明为止）。
    ///
    /// ⚠️ **不能整文件扫**（第一版就是这么错的，实测被判红）：`ContentView.swift` 里
    /// ``DiskListRegion`` 的 `@ObservedObject var occupancyStore` 是**合法的**（它就该订阅），
    /// 整文件扫会把它当成违规。判据必须限定在「上层那个 struct 里」。
    private func topLevelBody(_ text: String, of name: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard
            let start = lines.firstIndex(where: {
                $0.hasPrefix("struct \(name):") || $0.hasPrefix("struct \(name) ")
            })
        else { return nil }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            // 顶层声明的开头 = 行首无缩进且是声明关键字；`@MainActor` 那类前缀行不在此列，
            // 但下一个 struct 一定以 `struct ` 开头，所以只认这几种就够了。
            let isTopLevelDecl =
                !line.hasPrefix(" ") && !line.hasPrefix("\t")
                && ["struct ", "extension ", "enum ", "class ", "actor "].contains { line.hasPrefix($0) }
            if isTopLevelDecl { break }
            body.append(line)
        }
        return body.joined(separator: "\n")
    }

    /// **阴性面**：上层两个视图不许订阅 ``OccupancyStore``。
    ///
    /// 判据是源码文本（`@ObservedObject` + `occupancyStore` 出现在同一行），不是编译期 ——
    /// 因为「订阅了但没读」在类型系统里完全合法，编译器不会说话。
    @Test("上层视图不得订阅占用结论（订阅随读取走）")
    func 上层不订阅占用结论() throws {
        let files: [(path: String, type: String)] = [
            ("Sources/Views/ContentView.swift", "ContentView"),
            ("Sources/Views/MenuPopoverView.swift", "MenuPopoverView"),
        ]
        var checked = 0
        for file in files {
            let text = try source(file.path)
            // **装置自证**：文件必须真读到（路径写错时 String(contentsOf:) 会抛，
            // 但读到一个空文件不会 —— 那样下面所有断言都会「通过」）。
            #expect(text.count > 2000, "\(file.path) 只读到 \(text.count) 字符 —— 路径写错了？")
            guard let body = topLevelBody(text, of: file.type) else {
                Issue.record("\(file.path) 里找不到 `struct \(file.type)` —— 本测试的前提不成立")
                continue
            }
            #expect(body.count > 500, "\(file.type) 的区间只取到 \(body.count) 字符 —— 区间切错了？")
            checked += 1

            let offenders = body.split(separator: "\n").enumerated().filter { _, line in
                // 只认「真的声明了订阅」的行：注释行（`///` / `//`）不算 ——
                // 上面那几段解释文字里就写着 `@ObservedObject`，不排除会**自己把自己判红**。
                let l = line.trimmingCharacters(in: .whitespaces)
                return !l.hasPrefix("//") && l.contains("@ObservedObject") && l.contains("occupancyStore")
            }
            #expect(
                offenders.isEmpty,
                """
                \(file.type) 又订阅上占用结论了（该 struct 区间内）：\
                \(offenders.map { "第 \($0.offset + 1) 行" }.joined(separator: "、"))
                `@ObservedObject` 订阅的是 `objectWillChange` **整条** ⇒ 占用每 15s 刷一次，
                这个视图就整个重算一遍（标题栏 / 横幅 / 动作区跟着重建，它们根本不关心占用）。
                要用占用结论，就让**真正画它的那个子视图**自己接 `OccupancyStore`
                （`DiskListRegion` / `MenuDiskList` 就是这么做的），上层只传值。
                """)
        }
        #expect(checked == files.count, "只检查了 \(checked) 个文件，应当是 \(files.count) 个")
    }

    /// **阳性面**：承接订阅的两个子视图**必须**真的订阅着。
    ///
    /// 没有这一半，上面那条只要「谁都不订阅」就永远绿 —— 而那样界面会**静默不刷新**
    /// （占用结论变了没人重画），比多算几次严重得多。
    @Test("承接订阅的子视图必须真的订阅着（阳性对照）")
    func 子视图确实订阅() throws {
        let expectations: [(path: String, type: String)] = [
            ("Sources/Views/ContentView.swift", "DiskListRegion"),
            ("Sources/Views/MenuPopoverView.swift", "MenuDiskList"),
        ]
        for file in expectations {
            let text = try source(file.path)
            guard let body = topLevelBody(text, of: file.type) else {
                Issue.record("\(file.path) 里找不到 `struct \(file.type)` —— 它被改名/删掉了")
                continue
            }
            #expect(
                body.contains("@ObservedObject var occupancyStore"),
                """
                \(file.type) 没有订阅 `OccupancyStore` ⇒ 占用结论变了它不会重画。
                订阅该在这里（它才是读占用结论的那一层），别把它挪回上层。
                """)
        }
    }

    /// **判据自己也要有牙**：拿一个已知样本试一遍上面那个「找违规行」的过滤器。
    ///
    /// 实测过同族事故：判红条件写成 `grep -q 'A\|B'`（BSD grep 的 BRE 不支持交替），
    /// 于是**永远不成立**，每一条都报「仍绿」。这里用正向 + 反向两个样本自证。
    @Test("违规行的判据本身能被样本证实")
    func 判据有牙() {
        func isOffender(_ line: String) -> Bool {
            let l = line.trimmingCharacters(in: .whitespaces)
            return !l.hasPrefix("//") && l.contains("@ObservedObject") && l.contains("occupancyStore")
        }
        #expect(isOffender("    @ObservedObject private var occupancyStore: OccupancyStore"))
        #expect(isOffender("@ObservedObject var occupancyStore: OccupancyStore"))
        #expect(!isOffender("    /// 上面那段解释里写着 @ObservedObject 和 occupancyStore"))
        #expect(!isOffender("    private let occupancyStore: OccupancyStore"))
        #expect(!isOffender("    @ObservedObject private var store: DiskListStore"))
    }
}
