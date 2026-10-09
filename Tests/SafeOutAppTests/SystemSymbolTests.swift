import AppKit
import Testing

/// `Sources/` 里用到的 **SF Symbol 名必须真的存在**。
///
/// **为什么值得守**：符号名是**字符串**，写错了 Swift 不报警、构建不失败、
/// 测试也不红 —— 而 `Image(systemName: "externaldrive.fil")` 渲染出来**是空的**。
/// 于是界面上「**图标不显示**」与「这块本来就没放图标」**逐字相同**（§8.54 那一类）。
///
/// ## ⚠️ 两条必须知道的边界
///
/// 1. **只有假阴性，不会 flaky。** 若某台机器系统较老而符号需要更新版本，
///    这里会报红 —— **那个红是对的**（那个符号对老系统用户确实不显示）。
///    反过来，在这台机器上是绿的**只证明「本机解析得到」**，
///    **证明不了「部署目标 macOS 14 上也有」** —— 这个盲区无法用本机检查填，
///    改动图标时**仍要自己确认最低系统版本**。
/// 2. **扫描是「行级」的**：只要一行里出现 `systemName:` / `systemSymbolName:` /
///    `systemImage:` / `icon:` / `.info("…")` 这类图标上下文，就收集该行所有
///    「像符号名」的字符串字面量。这是被逼的 ——
///    `Image(systemName: kind == .busy ? "a.b.fill" : "c.d")` 这种**三元**写法
///    用「紧跟冒号」的正则会漏（与 §8.48 本地化键那个坑同型）。
struct SystemSymbolTests {

    // MARK: 路径

    /// #filePath = <仓库根>/Tests/SafeOutAppTests/SystemSymbolTests.swift
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: 守卫

    /// 用到的每一个符号名，都必须能解析出真实图标。
    @Test func 用到的系统图标名必须都存在() throws {
        let names = try usedSymbolNames()
        // 扫描器的**锚**：`eject.fill` 是最常用的那个，扫不到说明扫描逻辑坏了，
        // 而那种情况下集合会**空着** —— 通过得毫无意义。
        #expect(names.count >= 15, "只扫到 \(names.count) 个符号名 —— 扫描逻辑多半坏了")
        #expect(names.contains("eject.fill"), "`eject.fill` 都没扫到 —— 口径漏了写法")
        #expect(
            names.contains("exclamationmark.triangle.fill"),
            "三元写法（`systemName: cond ? \"a\" : \"b\"`）没扫到 —— 口径退化了")

        let broken = names.filter { !Self.exists($0) }
        #expect(
            broken.isEmpty,
            """
            这些 SF Symbol 名在 `Sources/` 里用着，但**解析不出图标**：
            \(broken.sorted().joined(separator: ", "))
            `Image(systemName:)` 对未知名字渲染成**空** —— 界面上与「本来就没放图标」完全一样。
            修法：改回正确的符号名。⚠️ 同时确认它在**部署目标 macOS 14** 上就存在
            （本机检查只能证明本机，见本文件头注释）。
            """
        )
        print(
            "  [SF Symbol] \(names.count) 个符号，本机 \(ProcessInfo.processInfo.operatingSystemVersionString) 全部解析成功"
        )
    }

    /// **探针的锚**：一个必然不存在的名字**必须**解析失败。
    ///
    /// 少了这条，万一哪天 `NSImage(systemSymbolName:)` 对任何名字都返回非 nil，
    /// 上面那条会**永远绿** —— 而那种「通过」比不测更糟。
    @Test func 不存在的名字必须解析失败() {
        #expect(
            Self.exists("zz.probe.definitely.not.a.symbol") == false,
            """
            `NSImage(systemSymbolName:)` 对一个必然不存在的名字**返回了非 nil** ——
            这表示它不再能用来判断符号是否存在，上面那条守卫从此恒绿。
            请换一种判断方式，并同步修改本文件。
            """
        )
        // 正向对照：已知存在的名字必须解析成功
        #expect(Self.exists("gear"), "`gear` 都解析不出来 —— 判断方式本身有问题")
    }

    // MARK: 扫描

    private static func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// 行级收集 `Sources/` 里用到的符号名。
    private func usedSymbolNames() throws -> Set<String> {
        let fm = FileManager.default
        guard
            let e = fm.enumerator(
                at: repoRoot.appendingPathComponent("Sources"),
                includingPropertiesForKeys: nil)
        else { return [] }
        let files = e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }

        var out: Set<String> = []
        for url in files {
            for line in try String(contentsOf: url, encoding: .utf8).split(
                separator: "\n", omittingEmptySubsequences: false)
            {
                let s = String(line)
                if s.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                guard Self.iconContext.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) != nil
                else { continue }
                for lit in Self.literals(in: s) where Self.symbolShape.fullMatch(in: lit) {
                    out.insert(lit)
                }
            }
        }
        return out
    }

    /// 图标上下文：`systemName:` / `systemSymbolName:` / `systemImage:` / `icon:` / `.info("…")`。
    private static let iconContext = try! NSRegularExpression(
        pattern: #"systemName:|systemSymbolName:|systemImage:|\bicon:|\.(?:info|warning|danger|success|busy|safe)\("#)

    /// 只认「像符号名」的形状（小写 + 点），用来滤掉同行的日志文案等噪声。
    private static let symbolShape = try! NSRegularExpression(pattern: #"^[a-z][a-z0-9]*(?:\.[a-z0-9]+)*$"#)

    private static func literals(in line: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #""([^"]*)""#) else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return re.matches(in: line, range: range).compactMap { m in
            Range(m.range(at: 1), in: line).map { String(line[$0]) }
        }
    }
}

extension NSRegularExpression {
    fileprivate func fullMatch(in s: String) -> Bool {
        let r = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = firstMatch(in: s, range: r) else { return false }
        return m.range == r
    }
}
