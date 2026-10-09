// LocalizationGenerator — SafeOut 本地化 BuildToolPlugin（单一可信源）。
//
// 在 `swift build` / `swift test`（以及发布流程的 swift build）编译 SafeOutApp target 前，
// 自动读取包内的 `Localizable.xcstrings`，调用 gen_l10n_tool 生成 L10n.generated.swift。
// 生成的文件位于 plugin 工作目录，SwiftPM 会自动将其作为该 target 的额外源文件编译——
// 因此无需把生成文件提交到 git，也无需在 run.sh/build.sh/发布插件里手动调用 gen_l10n。
//
// 只要 Localizable.xcstrings 变化，下次构建即重新生成；新增 key 自动进入 L10n.Key 枚举，
// 未定义的 key 在编译期直接报错（绝不会静默漏翻）。
//
// 注意：PackagePlugin 自 SwiftPM 6 起弃用 `Path` 类型，统一改用 `URL`
// （`path`→`url`、`pluginWorkDirectory`→`pluginWorkDirectoryURL`、文件参数收 `URL`）。

import Foundation
import PackagePlugin

@main
struct LocalizationGenerator: BuildToolPlugin {

    /// 为什么**扫包目录**找 `.xcstrings`，而不是从 `sourceTarget.sourceFiles` 里挑
    /// （2026-09-24 改，原实现是后者）：
    ///
    /// `.xcstrings` 只要待在 target 目录下，SwiftPM 就会**顺手把它当 resource 再编一遍**，
    /// 产出 `.build/out/Products/<配置>/SafeOutApp_SafeOutApp.bundle`
    /// （内含 en / zh-Hans / zh-Hant 三份 `Localizable.strings`）—— 而**没有任何代码读它**：
    /// 本插件是把文案**内嵌**进 `L10n.generated.swift`（不需要 `Bundle.module`），
    /// `build_app.sh` 也不拷那个 `.bundle`。⇒ `Package.swift` 用 `exclude:` 把它摘出 target，
    /// 本插件改为自己找。
    ///
    /// ⚠️ 用**扫描**而不是写死 `Sources/Localization/...`：写死会把「文件可以搬」这个性质
    /// 丢掉（原实现靠 `sourceFiles` 自动跟随，搬迁是免费的）。扫描保留了这个性质，
    /// 代价只是每次构建多走一遍包目录（`.build` / `.git` 等隐藏目录会被跳过）。
    ///
    /// ⚠️ 找不到时**抛错**，不能 `return []` 静默跳过 —— 静默跳过会让 `L10n` 整个类型
    /// 不存在，报错指向「找不到 L10n」，与真正的原因（文件不在）隔了一层。
    private static func findXcstrings(in packageDirectory: URL) -> URL? {
        let fm = FileManager.default
        guard
            let walker = fm.enumerator(
                at: packageDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return nil }
        for case let url as URL in walker where url.pathExtension == "xcstrings" {
            return url
        }
        return nil
    }

    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard target is SourceModuleTarget else { return [] }

        guard let xcstringsURL = Self.findXcstrings(in: context.package.directoryURL) else {
            throw LocalizationSourceMissing(packageDirectory: context.package.directoryURL.path)
        }

        // 生成文件放到 plugin 工作目录；SwiftPM 会自动把它当作 target 的源文件编译。
        let outputURL = context.pluginWorkDirectoryURL
            .appending(component: "L10n.generated.swift")

        // 编译好的生成器工具（executableTarget，不进入主 app）。
        let tool = try context.tool(named: "gen_l10n_tool")

        return [
            .buildCommand(
                displayName: "Generating L10n localized strings",
                executable: tool.url,
                arguments: [xcstringsURL.path, outputURL.path],
                inputFiles: [xcstringsURL],
                outputFiles: [outputURL]
            )
        ]
    }
}

/// 包目录里找不到任何 `.xcstrings`。
///
/// 单独立一个类型（而不是抛裸字符串）是为了让 `swift build` 把这段话原样打出来 ——
/// 本地化是**编译期**契约，源文件不见了必须立刻、明确地说出来。
struct LocalizationSourceMissing: Error, CustomStringConvertible {
    let packageDirectory: String

    var description: String {
        """
        在包目录里找不到任何 .xcstrings（本地化源文件）：
          \(packageDirectory)
        本插件负责由它生成 L10n.generated.swift；没有它，L10n 整个类型都不会存在。
        检查：① 文件是否被误删；② 是否被移出了包目录（如挪进 .build/ 这类隐藏目录，
        它们被扫描跳过）。
        """
    }
}
