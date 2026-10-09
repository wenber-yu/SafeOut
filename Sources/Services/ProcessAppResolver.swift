import AppKit
import Darwin
import Foundation
import OSLog

/// 进程 → 应用身份的解析（「这个 PID 在用户眼里是哪个 App」）。
///
/// **为什么必须有这一层**：`lsof` 只给得出进程的**可执行名**（`c` 字段），而用户在
/// Dock / 菜单栏里认识的是**应用显示名**，两者经常不是一回事。真机实测（用户报的 bug）：
/// `/Applications/IMVIDEO.app` 的 `CFBundleName`、可执行文件都叫 `IMVIDEO`，
/// 但它的本地化显示名是 **`Bunny`**（`zh-Hans.lproj/InfoPlist.strings` 覆盖了 `CFBundleName`）。
/// 旧实现直接把 `c` 字段当应用名显示 → 用户看到 `IMVIDEO` 却认不出这就是 `Bunny`；
/// 图标同样拿不到：旧实现拿 `"imvideo"` 去和运行中应用的 `localizedName`（`"Bunny"`）
/// 做包含匹配，永远匹配不上，只能回落到通用图标——用户看到的就是「没有应用图标」。
///
/// **正确姿势是按 PID 解析，而不是按名字猜**：
/// 1. `proc_pidpath` 取可执行文件路径（任何进程都取得到，不需要额外权限）；
/// 2. 从路径里取**最外层** `.app` —— 这恰好是用户在 Dock / Finder 里看到的那个应用
///    （Chrome / Electron 的 helper 自身也是嵌套 `.app`，取最外层才回到主应用）；
/// 3. 名称优先级：运行中应用的 `localizedName`（LaunchServices 显示名，最贴近用户认知）
///    → bundle 的本地化 `CFBundleDisplayName` / `CFBundleName` → 进程名；
/// 4. 图标**只从 `.app` 路径取**：实测 `icon(forFile:)` 传可执行文件路径拿到的是另一个图标，
///    传 `.app` 路径才是应用真图标。
///
/// 非 bundle 内进程（`tail` / `ffmpeg` 这类 CLI）走回落：名称 = 进程名，
/// 图标 = 该可执行文件自身的系统图标（`exec` 图标），不会伪造一个不存在的应用名。
enum ProcessAppResolver {

    private static let logger = Logger(subsystem: "com.safeout.app", category: "ProcessApp")

    /// `proc_pidpath` 的缓冲区大小（`libproc.h` 里的 `PROC_PIDPATHINFO_MAXSIZE` 即 4096）。
    private static let pidPathBufferSize = 4096

    // MARK: - 纯函数（可单测，不依赖运行环境）

    /// 取路径里**最外层**的 `.app` bundle。
    ///
    /// - `/Applications/IMVIDEO.app/Contents/MacOS/IMVIDEO` → `/Applications/IMVIDEO.app`
    /// - `/Applications/Google Chrome.app/…/Helpers/Google Chrome Helper.app/Contents/MacOS/x`
    ///   → `/Applications/Google Chrome.app`（**最外层**：helper 的嵌套 `.app` 不是用户认知里的应用）
    /// - `/usr/bin/tail` → `nil`（不在任何 app 内）
    static func owningAppBundlePath(executablePath: String) -> String? {
        guard executablePath.hasPrefix("/") else { return nil }
        var prefix: [Substring] = []
        for component in executablePath.dropFirst().split(separator: "/") {
            prefix.append(component)
            if component.hasSuffix(".app") {
                return "/" + prefix.joined(separator: "/")
            }
        }
        return nil
    }

    /// 运行中应用报的 `bundleURL` **只有真的是 `.app` 时才可信**。
    ///
    /// **为什么必须过滤**（2026-09-21 实测）：`NSRunningApplication.bundleURL`
    /// **不保证**是 bundle —— 在 Command Line Tools 工具链下，测试进程
    /// `…/CommandLineTools/usr/libexec/swift/pm/swiftpm-testing-helper` 的
    /// `bundleURL` 返回的就是**可执行文件自己的路径**（不带 `.app`）。
    /// 直接采信会让 `appBundlePath` 不再是「app bundle」，而下游两处都会跑偏：
    /// - ``icon(for:)`` 拿一个非 bundle 路径去 `NSWorkspace.icon(forFile:)`；
    /// - ``appDisplayName(bundlePath:)`` 把**目录名**当成应用名读出来。
    ///
    /// ⚠️ 这条缺口在 CI 上是**看不出来**的：Xcode 的 runner 住在
    /// `/Applications/Xcode.app/Contents/Developer/…` 里，路径**恰好**以 `.app` 结尾，
    /// 于是 `真实进程解析出的名字必不为空` 那条断言**碰巧**成立。
    /// 换 CLT 工具链跑就红了 —— 典型的「判据依赖环境」。
    /// ⇒ 过滤后，非 `.app` 的情况一律走文档里写好的回落（进程名）。
    static func appBundlePath(fromRunningAppBundleURL path: String?) -> String? {
        guard let path, path.hasSuffix(".app") else { return nil }
        return path
    }

    /// 把候选名规整成可显示形式：去首尾空白，并剥掉 `FileManager.displayName` 附带的 `.app`。
    ///
    /// 实测 `FileManager.default.displayName(atPath: "/Applications/IMVIDEO.app")` 返回
    /// `"Bunny.app"`（Finder 显示名 + 扩展名），直接用会显示成 `Bunny.app`。
    static func normalizedDisplayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".app") ? String(trimmed.dropLast(4)) : trimmed
    }

    /// 按优先级取第一个非空候选名；全空返回 `nil`（由调用方决定回落）。
    static func firstDisplayName(among candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            let name = normalizedDisplayName(candidate)
            if !name.isEmpty { return name }
        }
        return nil
    }

    // MARK: - 系统查询

    /// 进程的可执行文件路径（`proc_pidpath`）。进程已退出或无权查看时返回 `nil`。
    static func executablePath(forPid pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: pidPathBufferSize)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        // 不能写 `String(cString:)`：本工具链已弃用它（`-warnings-as-errors` 下直接编译失败），
        // 官方替代是先按 NUL 截断再按 UTF-8 解码。`proc_pidpath` 返回值 > 0 已保证有终止符。
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// 读 bundle 的显示名：本地化 `CFBundleDisplayName` → 本地化 `CFBundleName` → Finder 显示名。
    ///
    /// **必须用 `localizedInfoDictionary` 而不是 `infoDictionary`**：前者会叠加
    /// `Resources/<lang>.lproj/InfoPlist.strings` 的覆盖，正是 `IMVIDEO` → `Bunny` 的来源；
    /// 只用 `infoDictionary` 会退回读到 `IMVIDEO`，等于没修。
    static func appDisplayName(bundlePath: String) -> String? {
        let bundle = Bundle(path: bundlePath)
        let localized = bundle?.localizedInfoDictionary
        let raw = bundle?.infoDictionary
        return firstDisplayName(among: [
            localized?["CFBundleDisplayName"] as? String,
            localized?["CFBundleName"] as? String,
            raw?["CFBundleDisplayName"] as? String,
            raw?["CFBundleName"] as? String,
            FileManager.default.displayName(atPath: bundlePath),
        ])
    }

    /// 按 **bundle 路径**在运行中的应用里找（路径相等，不做名字模糊匹配）。
    ///
    /// 旧实现按名字做包含匹配，正是「`Bunny` 匹配不上 `IMVIDEO`」的根源；路径是确定性身份，
    /// 不会误配到名字相近的另一个应用上。`standardizedFileURL` 消除 `..`、重复分隔符等差异。
    @MainActor
    private static func runningApp(bundleURLPath: String) -> NSRunningApplication? {
        let target = URL(fileURLWithPath: bundleURLPath).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL.path == target
        }
    }

    // MARK: - 解析

    /// 补齐单个进程的应用身份（`displayName` / `appBundlePath` / `executablePath`）。
    ///
    /// **必须在主 actor 上执行**：`NSWorkspace` / `NSRunningApplication` 是主 actor 隔离类型。
    @MainActor
    static func enrich(_ process: OccupyingProcess) -> OccupyingProcess {
        var enriched = process
        let executablePath = Self.executablePath(forPid: process.pid)
        let directApp = NSRunningApplication(processIdentifier: process.pid)

        // bundle 有两条来源，任一可用即可；**可执行路径推出的最外层 bundle 优先**——
        // helper 进程的 `directApp.bundleURL` 指向嵌套的 helper.app，只有路径推导才能回到
        // 用户认知里的主应用。
        let bundlePath =
            executablePath.flatMap(Self.owningAppBundlePath(executablePath:))
            ?? Self.appBundlePath(fromRunningAppBundleURL: directApp?.bundleURL?.path)

        var candidates: [String?] = []
        if let bundlePath {
            // ① 进程自身就是这个 app（绝大多数情况）：直接用 LaunchServices 给的显示名。
            if let directApp,
                directApp.bundleURL?.standardizedFileURL.path
                    == URL(fileURLWithPath: bundlePath).standardizedFileURL.path
            {
                candidates.append(directApp.localizedName)
            }
            // ② helper 进程：拿最外层 bundle 去运行中应用里按**路径**找。
            candidates.append(Self.runningApp(bundleURLPath: bundlePath)?.localizedName)
            // ③ 该 app 没被登记为「运行中」：直接读 bundle 的本地化名。
            candidates.append(Self.appDisplayName(bundlePath: bundlePath))
        }

        enriched.executablePath = executablePath
        enriched.appBundlePath = bundlePath
        enriched.displayName = Self.firstDisplayName(among: candidates) ?? process.processName

        if enriched.displayName != process.processName {
            Self.logger.debug(
                "PID \(process.pid, privacy: .public) 进程名 \(process.processName, privacy: .public) → 应用名 \(enriched.displayName, privacy: .public)"
            )
        }
        return enriched
    }

    /// 批量补齐（占用检测每条结果都要过一遍）。
    @MainActor
    static func enrich(_ processes: [OccupyingProcess]) -> [OccupyingProcess] {
        processes.map(enrich)
    }

    // MARK: - 图标

    /// 进程图标：应用 bundle 图标 → 该可执行文件自身的系统图标 → `nil`（调用方回落 SF Symbol）。
    ///
    /// 缓存按路径做：进程列表每 15s 重新检测一次，但涉及的 app 路径集合几乎不变，
    /// 缓存后视图刷新不必反复走 `NSWorkspace`。
    @MainActor
    static func icon(for process: OccupyingProcess) -> NSImage? {
        guard let path = process.appBundlePath ?? process.executablePath else { return nil }
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }

    /// 图标缓存（键 = app bundle 路径或可执行文件路径，取值域受限于机器上装了什么）。
    @MainActor private static var iconCache: [String: NSImage] = [:]
}
