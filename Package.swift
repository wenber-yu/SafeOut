// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SafeOutApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 本地化生成器（独立本地 package，仅作为插件工具依赖，不进入主程序）。
        .package(path: "Tools/gen_l10n_tool"),
        // Sparkle 2：自更新框架。**二进制 target**（官方发布的 Sparkle.xcframework zip），
        // 不从源码编译 —— 源码构建需要 Xcode 工程与一堆 XPC 子目标，SPM 里拿不到。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "SafeOutApp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            // `Localizable.xcstrings` 由 LocalizationGenerator 插件**直接读**（文案内嵌进
            // `L10n.generated.swift`，不经过 `Bundle.module`），所以这里把它摘出 target。
            //
            // 不摘的话 SwiftPM 会顺手把它当 **resource** 再编一遍，产出
            // `.build/out/Products/<配置>/SafeOutApp_SafeOutApp.bundle`
            // （内含 en / zh-Hans / zh-Hant 三份 Localizable.strings）——
            // 而**没有任何代码读它**：Sources/ 里 `Bundle.module` 出现 0 次，
            // `build_app.sh` 也不把这个 .bundle 拷进 .app。
            //
            // ⚠️ 摘掉之后**必须**同步改 `Plugins/LocalizationGenerator/Plugin.swift`
            //    （它改为扫包目录定位该文件）。只加 `exclude:` 不改插件 ⇒ 插件返回空命令
            //    ⇒ `L10n` 整个类型不存在 ⇒ 编译失败。
            // ⚠️ 也**不加** `defaultLocalization:` —— 那个键是给 resource 用的，这里已无 resource。
            exclude: ["Localization/Localizable.xcstrings"],
            // DiskArbitration：读取设备的 DADeviceInternal / DADeviceProtocol 等属性，
            // 作为「外置可推出」判定的事实来源（替代此前按挂载路径前缀猜测的做法）。
            linkerSettings: [.linkedFramework("DiskArbitration")],
            plugins: ["LocalizationGenerator"]
        ),
        .testTarget(
            name: "SafeOutAppTests",
            dependencies: ["SafeOutApp"],
            // 显式写 path：把「目录名 = target 名」这条**隐含约定**变成写在纸上的契约。
            // 不写也能跑（SPM 会按约定去 Tests/<TargetName> 找），但改了目录名时报错措辞很绕
            // （"Source files for target X should be located under …"），不如显式。
            path: "Tests/SafeOutAppTests"
        ),
        .plugin(
            name: "LocalizationGenerator",
            capability: .buildTool(),
            dependencies: [
                .product(name: "gen_l10n_tool", package: "gen_l10n_tool")
            ],
            // 同上：显式化，别靠 Plugins/<Name> 这条隐含约定。
            path: "Plugins/LocalizationGenerator"
        ),
    ],
    swiftLanguageModes: [.v6]
)
