import Foundation
import Testing

@testable import SafeOutApp

/// `DiskService.shared` 的线程安全**靠的是没有可变状态**，不是锁 —— 这条就是那份承诺的守卫。
///
/// ## 它在关什么（SPEC 第 42 行，§8.113）
///
/// §8.111.3 扫「非 main-actor 的测试代码碰共享单例」时开出第 42 行：
/// `IntegrationEjectTests` 摘掉 `@MainActor` 之后（§8.99 的副作用），它调的
/// `DiskService.shared.fetchExternalDisks()` 就成了**非隔离共享对象上的并发访问**。
/// 当时登记为「风险未证、不做没根据的修改」。
///
/// 本轮把它**证否**了，办法是看它的状态而不是猜它的行为：
///
/// ```
/// $ 实扫 Sources/Services/DiskService.swift 的类体属性
/// static let shared = DiskService()      ← let
/// private static let logger = Logger(…)  ← let
/// （实例级 var：0 个；所有 var 都在函数体内）
/// ```
///
/// ⇒ 它是**无状态**的：每一次 `fetchExternalDisks()` 都只用局部变量与系统 API，
/// 两个线程同时进来也各自建各自的数组。并发访问**安全**。
///
/// 而 `@unchecked Sendable` 是一句**手工承诺**（编译器不检查）。这份承诺唯一的兑现方式
/// 就是「没有可变状态」—— 哪天有人加一个 `var cache` 做去重，承诺当场失效，
/// 而**没有任何东西会红**（编译器不管、现有测试也不碰）。这条守卫就是为那一刻准备的。
///
/// ⚠️ **它会随设计决策翻转**（§8.98 那条）：如果将来真的需要缓存，
/// 正确做法是**同时**改这里 —— 要么把守卫换成「有锁 / 有 actor 隔离」的判据，
/// 要么在豁免处写明新机制。**别直接删守卫。**
@Suite("DiskService 无状态")
struct DiskServiceStatelessTests {

    private var repoRoot: URL {
        // #filePath = <仓库根>/Tests/SafeOutAppTests/DiskServiceStatelessTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 声明修饰符。判据是「跳过修饰符之后第一个词是不是 `var`」——
    /// **不用正则**：`(private|static|…)+` 这种写法在本项目已经因为正则方言踩过两次
    /// （BRE 无 `\|`、ERE 无 `(?:`，§8.110），分词没有方言问题。
    private let modifiers: Set<String> = [
        "static", "private", "public", "internal", "fileprivate", "open",
        "final", "lazy", "weak", "unowned", "override",
        "private(set)", "public(set)", "internal(set)",
    ]

    /// 类体里的**可变**状态：缩进恰好 4 空格、跳过修饰符后是 `var`。
    ///
    /// ⚠️ **「恰好 4 空格」就是判据本身**：函数体内的局部变量是 8 空格，
    /// 它们随调用栈生灭、不构成共享状态 ⇒ **不算**。判据写成「出现过 `var`」的话，
    /// 现有那 6 处局部变量会让这条守卫**一上来就是红的**，结局一定是被关掉
    /// （§8.89 那条：precision 太低的扫描器活不下来）。
    private func mutableState(in source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            guard line.hasPrefix("    "), !line.hasPrefix("        ") else { return false }
            var tokens = line.dropFirst(4).split(separator: " ").map(String.init)
            while let first = tokens.first, modifiers.contains(first) { tokens.removeFirst() }
            return tokens.first == "var"
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @Test func DiskService不得有可变实例状态() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Services/DiskService.swift"),
            encoding: .utf8)

        // 装置自证：读到的确实是那个文件（拼错路径 ⇒ String(contentsOf:) 抛错，
        // 但「读到一个别的文件」不会抛 ⇒ 用两个已知特征锚住）。
        #expect(
            source.contains("class DiskService: @unchecked Sendable"),
            "这不是 DiskService.swift —— 路径或类名变了就要同步这条断言")
        #expect(
            source.contains("static let shared"),
            "连 `static let shared` 都没扫到 —— 口径失效了，下面的「0 个 var」不可信")

        let found = mutableState(in: source)
        #expect(
            found.isEmpty,
            """
            DiskService 出现了实例级可变状态：\(found.joined(separator: "；"))。
            它是 `@unchecked Sendable` —— 这个标记是**手工承诺**线程安全，而唯一的兑现方式
            就是没有可变状态。加了可变状态而不同步加锁 / actor 隔离，
            `IntegrationEjectTests` 那条非 main-actor 的并发访问就真的成了数据竞争
            （SPEC 第 42 行，§8.113）。
            """)
    }

    /// **双向阳性对照**：扫描器自己要有牙。
    ///
    /// 「0 个」这种阴性结论在本项目出过好几次错，而且与「装置瞎了」**逐字相同**
    /// （§8.96 / §8.106）。所以这里用一段手写样本同时验两个方向：
    /// 该报的报（4 空格的 `var`）、不该报的不报（8 空格的局部变量、`let`）。
    @Test func 扫描器能抓到类体的var且不误报函数体内的局部变量() {
        let sample = """
            final class Sample {
                static let shared = Sample()
                var cache: [String: Int] = [:]
                private(set) var hits = 0

                func go() {
                    var disks: [Int] = []
                    disks.append(1)
                }
            }
            """

        let found = mutableState(in: sample)
        #expect(
            found.count == 2,
            """
            该抓到的没抓全（实得 \(found)）：类体里有两个 `var`（含 `private(set)` 修饰），
            扫描器只认出 \(found.count) 个 ⇒ 上一条的「0 个 var」可能是漏报。
            """)
        #expect(
            !found.contains(where: { $0.contains("disks") }),
            """
            误报：函数体里的局部变量 `var disks` 被当成共享状态了。
            它是 8 空格缩进、随调用栈生灭，不是共享状态 ——
            判据一旦把它算进来，这条守卫会**一上来就红**，结局一定是被关掉。
            """)
    }

    /// 前提锚：这条守卫成立的前提是「它靠 `@unchecked Sendable` 而不是别的机制」。
    ///
    /// 哪天它改成 `@MainActor`（或换成 actor），第 42 行的**理由**就变了 ——
    /// 那时应该连这条守卫一起改，而不是让它静默变成一句过时的注释。
    @Test func DiskService的并发承诺确实是手工承诺() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Services/DiskService.swift"),
            encoding: .utf8)
        #expect(
            source.contains("@unchecked Sendable") && !source.contains("@MainActor"),
            """
            DiskService 的并发模型变了（不再是「`@unchecked Sendable` + 无状态」）。
            SPEC 第 42 行的结论是**基于无状态**得出的，请同步更新
            `DiskServiceStatelessTests` 与那一行 —— 别让它留着一句过时的理由。
            """)
    }
}
