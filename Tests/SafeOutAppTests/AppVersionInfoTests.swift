import Foundation
import Testing

@testable import SafeOutApp

/// 「设置窗口显示的版本号 / 构建号是不是真值」的契约。
///
/// **为什么要有这个文件**：2026-09-17 用户问「设置窗口中的版本和构建是真实数据吗」，
/// 核查后发现两件事：
///
/// 1. **是真值** —— 读的是 `Info.plist`，`/Applications/SafeOut.app` 里是
///    `2026.09.13.1` / `44`（`build_app.sh` 按提交数写入）；
/// 2. **但没有任何守卫** —— 读取逻辑原本是 `SettingsView` 里的 `private` 计算属性，
///    测试碰不到。`Bundle.main` 一旦换成读不到 plist 的场景（跑法一变就会），
///    界面会**静默**显示兜底的 `1.0.0` / `1`，**没有任何测试会红**。
///
/// 用户报 bug 时唯一能给出的定位信息就是这行字 —— 它错了，后续排查全在错误的构建上做。
///
/// ⚠️ **这里造的是「只读」的 bundle，不启动它、也不调 `NSWorkspace`** ——
/// `ProcessAppResolverTests` 那个夹具因为调了 `icon(forFile:)` 触发 LaunchServices 校验，
/// 未签名时会让 macOS 弹「已损坏」（2026-09-17 的坑）。本文件只读 `Info.plist`，不会。
///
/// ## ⚠️ 本套件**故意不标** `@MainActor`（2026-09-22，§8.128）
///
/// 判据不是「读一遍代码觉得不需要」，是**编译器**：摘掉之后**全量构建绿**（`BUILD_EXIT=0`）。
/// 它只读 `Info.plist` / 打包产物、解析版本串，不碰任何主 actor 隔离的东西
/// （既不用 AppKit，也不用 `OffscreenRender` / `ViewFixtures` 那些测试装置）。
/// ⚠️ **「不用 AppKit」不足以当判据** —— 同批实验里 `EmptyStateTests` / `MainWindowDiskListTests`
/// 也不用 AppKit，但它们调 `OffscreenRender`（`@MainActor`）⇒ 摘掉立刻红（§8.128）。
struct AppVersionInfoTests {

    /// 造一个带 `Contents/Info.plist` 的临时 bundle，返回它的 URL。
    private func makeBundle(plist: [String: String]?) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("versioninfo-\(UUID().uuidString)", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        if let plist {
            let body = plist.map { "<key>\($0.key)</key><string>\($0.value)</string>" }.joined()
            let xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
                "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>\(body)</dict></plist>
                """
            try xml.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        }
        return root
    }

    /// 有键就读得出真值 —— 这是「设置窗口显示的是真实数据」的正面证据。
    @Test func 从bundle读出版本号与构建号() throws {
        let url = try makeBundle(plist: [
            "CFBundleShortVersionString": "2026.09.13.1",
            "CFBundleVersion": "44",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try #require(Bundle(url: url), "临时 bundle 构造失败")

        #expect(AppVersionInfo.shortVersion(in: bundle) == "2026.09.13.1")
        #expect(AppVersionInfo.build(in: bundle) == "44")
    }

    /// **读不到时必须返回 `nil`，不能自己编一个值**。
    ///
    /// 这条守的是「读失败」与「真值恰好等于兜底值」在测试里能分开 ——
    /// 若 `AppVersionInfo` 内部就兜底成 `"1.0.0"`，上面那条断言永远无法分辨
    /// 「真读到了 1.0.0」还是「什么都没读到」。
    @Test func 没有plist时返回nil而不是假值() throws {
        let url = try makeBundle(plist: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try #require(Bundle(url: url), "临时 bundle 构造失败")

        #expect(
            AppVersionInfo.shortVersion(in: bundle) == nil,
            "读不到版本号时返回了非 nil —— 界面会把兜底值当成真值显示")
        #expect(AppVersionInfo.build(in: bundle) == nil)
    }

    /// **键存在但值为空**同样算读不到 —— `Info.plist` 里写了 `""` 会显示成空版本号。
    @Test func 键存在但为空也算读不到() throws {
        let url = try makeBundle(plist: [
            "CFBundleShortVersionString": "",
            "CFBundleVersion": "   ",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try #require(Bundle(url: url), "临时 bundle 构造失败")

        #expect(AppVersionInfo.shortVersion(in: bundle) == nil, "空字符串版本号被当成了真值")
        #expect(AppVersionInfo.build(in: bundle) == nil, "纯空白构建号被当成了真值")
    }

    // MARK: - 构建元信息（「这次构建到底对应哪份代码」）

    /// 读得出提交哈希与未提交改动数。
    @Test func 读得出构建元信息() throws {
        let url = try makeBundle(plist: [
            "DEBuildCommit": "a94f731",
            "DEBuildDirtyCount": "61",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try #require(Bundle(url: url), "临时 bundle 构造失败")

        #expect(AppVersionInfo.commit(in: bundle) == "a94f731")
        #expect(AppVersionInfo.dirtyCount(in: bundle) == 61)
    }

    /// **「干净」与「不知道」必须分开**：`0` 是有意义的答案（工作区干净），
    /// 键缺失才是 `nil`。若把缺失也当成 0，界面就永远不会提示「脏构建」——
    /// 而那正是这个功能存在的理由。
    @Test func 缺失构建元信息时返回nil而不是零() throws {
        let url = try makeBundle(plist: ["CFBundleShortVersionString": "1.0.0"])
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try #require(Bundle(url: url), "临时 bundle 构造失败")

        #expect(AppVersionInfo.commit(in: bundle) == nil)
        #expect(
            AppVersionInfo.dirtyCount(in: bundle) == nil,
            "键缺失被当成了「工作区干净」—— 界面不会提示脏构建，用户会以为版本号代表了实际代码")
    }

    /// 显式写 `0` 时要读成「干净」，不能读成「未知」。
    @Test func 零改动读成干净而不是未知() throws {
        let url = try makeBundle(plist: ["DEBuildDirtyCount": "0"])
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try #require(Bundle(url: url), "临时 bundle 构造失败")

        #expect(AppVersionInfo.dirtyCount(in: bundle) == 0)
    }

    /// **打包产物的守卫**：最近一次 `build_app.sh` 产出的 `.app` 里，
    /// 这两个键必须真的存在且非空。
    ///
    /// 守的是「构建脚本哪天不再写版本号」——那种情况界面会静默显示 `1.0.0 / 1`，
    /// 用户照着报一个查不到的构建号。产物不在（没打包过 / 被移走）时跳过。
    ///
    /// ⚠️ **路径必须从本文件位置派生，不能写死绝对路径**（2026-09-21 修）：
    /// 原先写死 `/Users/wenbo/…/Dist/SafeOut.app` ⇒ 在任何别的 checkout
    /// （CI runner、另一台机器、另一个目录）上 `fileExists` 都是 false
    /// ⇒ 整条用例**静默空转**，而它与「查过了没问题」在输出上**逐字相同**。
    ///
    /// ⚠️ **跳过时必须把「跳过」打出来**：CI 里测试跑在 `build_app.sh` **之前**，
    /// 所以这条用例在 CI 上**永远是空转的** —— 真正端到端的那条判据在
    /// `Scripts/verify_app.sh`（CI 在打包之后跑它，读同一个键）。
    /// 两条一起才是「有牙」的：本用例守本地（产物在手时），verify_app 守 CI。
    @Test func 打包产物里确实写入了版本号与构建号() throws {
        // #filePath = <仓库根>/Tests/SafeOutAppTests/AppVersionInfoTests.swift
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appPath = repoRoot.appendingPathComponent("Dist/SafeOut.app").path
        // 自证：派生出来的路径得**像**仓库里的产物，否则「路径算错了」
        // 与「产物不存在」会走同一个 return（两者诊断方向完全不同）。
        guard appPath.hasSuffix("/Dist/SafeOut.app") else {
            Issue.record("派生的产物路径不像仓库里的产物：\(appPath) —— 装置算错了，本次结论作废")
            return
        }
        guard FileManager.default.fileExists(atPath: appPath), let bundle = Bundle(path: appPath) else {
            print("  [打包产物] 跳过：\(appPath) 不存在（本次没构建过产物）—— 本用例**未执行**")
            return
        }
        let version = try #require(
            AppVersionInfo.shortVersion(in: bundle),
            "打包产物 \(appPath) 的 Info.plist 里没有 CFBundleShortVersionString —— build_app.sh 没写版本号")
        let build = try #require(
            AppVersionInfo.build(in: bundle),
            "打包产物 \(appPath) 的 Info.plist 里没有 CFBundleVersion")
        print(
            "  [打包产物] \(appPath) → 版本 \(version) · 构建 \(build)"
                + " · 提交 \(AppVersionInfo.commit(in: bundle) ?? "—")"
                + " · 未提交 \(AppVersionInfo.dirtyCount(in: bundle).map(String.init) ?? "未知")")
        #expect(version != "1.0.0", "打包产物里的版本号落到了兜底值 —— 说明 Info.plist 没被写入")
        // 构建元信息两个键必须被 `build_app.sh` 写入 —— 缺了界面就无法提示脏构建。
        #expect(
            AppVersionInfo.dirtyCount(in: bundle) != nil,
            "打包产物里没有 DEBuildDirtyCount —— build_app.sh 没写构建元信息，界面将无法提示「未提交改动」")
    }
}
