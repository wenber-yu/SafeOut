// swift-tools-version:6.0
// gen_l10n_tool — SafeOut 本地化代码生成器（作为独立本地 package）。
//
// 之所以独立成包：主包的 BuildToolPlugin（LocalizationGenerator）需要把它作为
// 可执行工具依赖。若把它直接放在主包顶层当 executableTarget，会让 `swift run`
// 出现两个可执行项（SafeOutApp / gen_l10n_tool）而报错，且会把它所在的 Scripts/
// 目录里的 .sh 误当成未处理资源。独立成包后，主包 `swift run` 只剩 SafeOutApp。
import PackageDescription

let package = Package(
    name: "gen_l10n_tool",
    // ⚠️ 与主包 `Package.swift` 同档：全仓部署目标统一为 14+，
    //    由 `Tests/SafeOutAppTests/DeploymentTargetTests.swift` 钉住一致。
    //    本工具只在**构建期**跑（宿主是装了 Xcode 26 的开发机 / CI runner），
    //    所以这里的下限不影响任何用户机器。
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "gen_l10n_tool", targets: ["gen_l10n_tool"])
    ],
    targets: [
        .executableTarget(
            name: "gen_l10n_tool",
            path: "Sources/gen_l10n_tool"
        )
    ]
)
