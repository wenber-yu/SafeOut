import AppKit
import CoreServices
import Darwin
import Foundation
import Testing

@testable import SafeOutApp

/// 把 `NSImage` 的**光栅化**搬到独立执行体上。
///
/// ## 为什么（2026-09-22 实测，账本第 35 行剩下的那一段）
///
/// `NSImage.tiffRepresentation` 会**强制光栅化**。对一张刚从 `iconservicesagent`
/// 取来的**新 bundle** 图标，这一步实测 **3.93s**（同一张图标的通用版只要 0.39s）——
/// 而且它是**同步阻塞**的。留在主 actor 上（本套件整体 `@MainActor`）就会把这 3.9 秒
/// 转嫁给**所有** `@MainActor` 用例。判别实验：
///
/// - `--skip` 掉那条取图标的测试后，本文件 + `OccupancyStoreTests` 的其余 **27** 条
///   耗时从 ~4.8s 全部掉到 **≤0.71s**；
/// - 临时挂一个「主 actor 心跳」用例（`Task.yield()` × 80 拍、每拍 50ms）量到：
///   主 actor 被占住时它实际跑了 **8.7s**（自身只要 4.0s），多出的 ~4.7s 正落在这里；
///   把光栅化搬走之后回到 **4.38s**（只剩 0.38s 调度噪声）。
///
/// ⇒ 搬到独立执行体（`DispatchQueue.global`）——**不是**协作线程池：池大小 ≈ 核数，
/// 占一根就少一根（§8.114 第 6 节）。与 ``Fixture/warmUpLaunchServices`` 同一条理由。
///
/// ⚠️ `NSImage` 不是 `Sendable` ⇒ 用 `@unchecked Sendable` 的盒子**显式**承担这个判断：
/// 这里只在一个执行体上**读**它，且传进去之前已完全构造好、之后不再改。
private struct ImageBox: @unchecked Sendable { let image: NSImage }

/// 见 ``ImageBox`` 的说明。
///
/// ⚠️ `nonisolated` 在这里**不是**装饰：`MainActorBlockingTests` 的口径第 2 条要求
/// 「阻塞调用所在的最近一个声明同时含 `nonisolated` 与 `async`」才算离开主 actor ——
/// 本文件整体算 `@MainActor`（套件那个 `@MainActor`），所以少了这个词，
/// 守卫会把这一处判成违规。语义上也对：这是个**文件级函数**，本来就不在主 actor 上。
private nonisolated func tiffDataOffMainActor(_ image: NSImage) async -> Data? {
    let box = ImageBox(image: image)
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: box.image.tiffRepresentation)
        }
    }
}

/// 「进程 → 应用身份」解析的测试（``ProcessAppResolver``）。
///
/// **为什么需要**：这里修的是一个真机 bug —— 磁盘被 `Bunny` 占用，界面却显示 `IMVIDEO`
/// 且没有图标。根因是「拿进程可执行名当应用名」，而二者经常不同：
/// `/Applications/IMVIDEO.app` 的 `CFBundleName` 与可执行文件都叫 `IMVIDEO`，
/// 但它的本地化显示名（`zh-Hans.lproj/InfoPlist.strings`）是 `Bunny`。
///
/// 断言分三层，各自钉死一环：
/// ① 可执行路径 → **最外层** `.app`（helper 的嵌套 `.app` 必须回到主应用）；
/// ② bundle → 显示名（**必须走本地化字典**，走 `infoDictionary` 会退回读到原始名）；
/// ③ 解析不出来时回落进程名 —— 任何情况下都不允许出现空名字。
///
/// 第 ④ 组是**端到端**的：真的造一个「显示名 ≠ 可执行名」的 `.app` 并启动它，
/// 再解析那个真实 PID。这样这条 bug 的判据不依赖机器上装了什么应用、也不依赖系统语言。
@MainActor
struct ProcessAppResolverTests {

    // MARK: - 夹具

    /// 一个只用于测试的 `.app`：**显示名与可执行名故意不同**（复刻 `Bunny` / `IMVIDEO`）。
    private struct Fixture {
        /// 本地化显示名（`InfoPlist.strings`），即「用户看到的那个名字」。
        static let localizedDisplayName = "Localized Bunny"
        /// 可执行文件名（`lsof` 的 `c` 字段会给这个），即「旧实现错误显示的那个名字」。
        static let executableFileName = "IMVIDEO-LIKE-EXEC"

        let root: URL
        let bundlePath: String
        let executablePath: String

        /// ⚠️ `async` 是为了 `adhocSign`（见那里的说明）：签名等待必须离开主 actor。
        init() async throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory
                .appendingPathComponent("resolver-fixture-\(UUID().uuidString)", isDirectory: true)
            let bundle = root.appendingPathComponent("Bunny Fixture.app", isDirectory: true)
            let macos = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try fm.createDirectory(at: macos, withIntermediateDirectories: true)

            let info = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
                "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                <key>CFBundleName</key><string>RAW-NAME-NOT-WANTED</string>
                <key>CFBundleExecutable</key><string>\(Self.executableFileName)</string>
                <key>CFBundlePackageType</key><string>APPL</string>
                <key>CFBundleIdentifier</key><string>com.example.resolverfixture</string>
                </dict></plist>
                """
            try info.write(
                to: bundle.appendingPathComponent("Contents/Info.plist"),
                atomically: true, encoding: .utf8)

            // 两种语言都写成同一个值：这样无论测试机的首选语言是哪个，结果都确定，
            // 而「值来自 InfoPlist.strings 而不是 Info.plist」仍然可被断言。
            for language in ["zh-Hans", "en"] {
                let lproj = bundle.appendingPathComponent(
                    "Contents/Resources/\(language).lproj", isDirectory: true)
                try fm.createDirectory(at: lproj, withIntermediateDirectories: true)
                try "\"CFBundleName\" = \"\(Self.localizedDisplayName)\";\n"
                    .write(
                        to: lproj.appendingPathComponent("InfoPlist.strings"),
                        atomically: true, encoding: .utf8)
            }

            bundlePath = bundle.path
            executablePath = macos.appendingPathComponent(Self.executableFileName).path
            // 用系统的 /bin/sleep 当可执行体：我们只关心「这个 PID 会被解析成什么身份」，
            // 不关心它具体在干什么。
            try fm.copyItem(atPath: "/bin/sleep", toPath: executablePath)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executablePath)
            await Self.adhocSign(bundlePath)
        }

        /// 给夹具打 **ad-hoc 签名**：未签名的 `.app` 会让 Gatekeeper 弹「已损坏，无法打开」。
        ///
        /// **为什么必须有这一步**：`ProcessAppResolver.icon(for:)` 走的是
        /// `NSWorkspace.shared.icon(forFile:)`，它会让 **LaunchServices 登记并校验这个 bundle**。
        /// 夹具原本完全未签名（可执行体是 `/bin/sleep` 的副本）→ 校验失败 →
        /// macOS 弹「"Bunny Fixture.app"已损坏，无法打开」。
        /// 每跑一次这套测试就弹一次，跑得多就成了「频繁弹窗」（2026-09-17 用户反馈）。
        ///
        /// ad-hoc 签名（`-s -`）只表示「本地有效的自有签名」，不影响被测的任何逻辑 ——
        /// 我们测的是「可执行路径 → bundle → 本地化显示名 → 图标」，与签名身份无关。
        ///
        /// ⚠️ **签名失败不要因此让测试红**：签名只是消除系统弹窗的副作用，
        /// 不是被测行为。用 `guard` + 打印，别把它变成一条会误报的断言。
        ///
        /// ⚠️ **`nonisolated` + `async` 是必需的，不是风格问题**（2026-09-20，§8.99）：
        /// 本套件整体标着 `@MainActor`（`enrich` / `icon` 必须主 actor），
        /// 所以这段等待只要留在主 actor 上，就会把**别的 `@MainActor` 用例**全堵住（§8.97.3）。
        ///
        /// ⚠️ **但「搬进 `nonisolated async`」不是终点**（2026-09-22，§8.114 第 6 节）：
        /// 原来这里写的是 `try task.run()` + `task.waitUntilExit()` —— 后者**同步阻塞、不让路**，
        /// 搬走之后它占的是**协作线程池**里的一根线程（池大小 ≈ 核数）。
        /// CI 上核数更少 ⇒ 几处并发阻塞就让整个进程停摆：本文件那条 `waitForExecutablePath`
        /// （`nonisolated async`，跑在同一个池上）因此等 2 秒等不到 `proc_pidpath`，
        /// 被报成「进程还没就绪」。
        /// ⇒ 现在走 ``runAndAwaitExit``：等的是**回调**（`terminationHandler`），一个线程都不占。
        nonisolated static func adhocSign(_ path: String) async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            task.arguments = ["--force", "--deep", "-s", "-", path]
            task.standardOutput = nil
            task.standardError = nil
            guard let status = await runAndAwaitExit(task) else {
                print("  [夹具] 无法调用 codesign —— 不影响被测逻辑")
                return
            }
            if status != 0 {
                print(
                    "  [夹具] ad-hoc 签名失败（\(status)）——"
                        + "不影响被测逻辑，但 macOS 可能仍会弹「已损坏」")
            }
            // 签名之后再登记一次（见 ``warmUpLaunchServices``）。
            await warmUpLaunchServices(path)
        }

        /// 让 LaunchServices **先登记**这个新造的 bundle —— 这是**预热**，不是被测行为。
        ///
        /// ## 为什么预热（2026-09-22 实测）
        ///
        /// 不预热的话，**第一处** `NSWorkspace.shared.icon(forFile:)`
        /// （`ProcessAppResolver.icon(for:)`，`@MainActor`）要**自己**触发 LaunchServices 登记，
        /// 实测 **0.88s**；预热之后同一处只要 **0.088s**（10×）。
        ///
        /// ⚠️ 这 0.88s 是**在主 actor 上**花的（那个调用是 `@MainActor`）⇒ 期间所有
        /// `@MainActor` 用例排队。搬到 `nonisolated` 的 `adhocSign` 里预热，
        /// 就把它挪出了主 actor。
        ///
        /// ⚠️ **别把本文件的 5 秒记到这一步头上** —— 真凶是
        /// ``tiffDataOffMainActor`` 里那段**光栅化**（3.93s），不是登记。
        /// 这条预热只是把 0.88s 的登记也挪出主 actor（订正记录见 `DESIGN-SPEC` §8.127）。
        ///
        /// ⚠️ 这**不是**在改被测行为：登记是 `NSWorkspace` 自己也会做的事，
        /// 这里只是把它提前到主 actor 之外。失败也不让测试红（与 `adhocSign` 同一条理由）。
        ///
        /// ⚠️ **跑在独立执行体上，不是协作线程池**：`LSRegisterURL` 是**同步阻塞**的，
        /// 而协作池大小 ≈ **核数** —— 占住一根就少一根，正是 §8.114 第 6 节
        /// 「搬出主 actor 不等于搬出瓶颈」那条教训。`DispatchQueue.global` 是
        /// libdispatch 自己的池（会按需长），与 ``SubprocessOutput`` 选独立执行体同一条理由。
        nonisolated static func warmUpLaunchServices(_ path: String) async {
            let status: OSStatus = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        returning: LSRegisterURL(URL(fileURLWithPath: path) as CFURL, true))
                }
            }
            if status != noErr {
                print("  [夹具] LaunchServices 预热返回 \(status) —— 不影响被测逻辑")
            }
        }

        /// 启动夹具进程（跑 30s，测试结束前会被 terminate）。
        func launch() throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["30"]
            try process.run()
            return process
        }

        // MARK: - 共用夹具（只建一次）

        /// 整个测试进程共用一份夹具。
        ///
        /// **为什么共享**（2026-09-22，§8.114 第 5 节）：`Fixture.init()` 里那次 `codesign`
        /// 是本套件最贵的一步（首个冷启动实测 ~4.8s，其余各 ~0.3s；CI 上更慢），
        /// 而原来 **4 条测试各建一份** ⇒ 4 次签名 + 4 次 LaunchServices 登记。
        /// §8.114 量到那 4 条**恰好**落在整轮最长的零完成窗口里（4.805s），
        /// 而窗口里**别的所有用例**都排在这串重活后面 —— 那正是账本第 35 行那条 flaky 的土壤。
        ///
        /// ⚠️ **`static let` 的 `Task` 保证「只建一次」**：`static let` 本身惰性且线程安全，
        /// 而缓存一个 `Task` 还顺带保证**并发进入时也只建一份** —— 缓存 `Fixture?` 做不到：
        /// `init` 里有 `await`，两条测试会在那里交错、各建一份。
        static let sharedTask = Task { try await Fixture() }

        /// 取共用夹具。
        ///
        /// ⚠️ **用完不许删** —— 多条测试同时在用同一份，谁先跑完就删会让别的用例读到
        /// 不存在的路径。临时目录交给系统回收（一个几 KB 的夹具目录，不值得为它做引用计数）。
        static func shared() async throws -> Fixture {
            try await sharedTask.value
        }
    }

    // MARK: - 等待（⚠️ 必须离开主 actor，见下）

    /// 等 `proc_pidpath` 能取到该 PID 的可执行路径（进程刚 `run()` 时可能还没就绪）。
    ///
    /// **为什么是 `nonisolated` + `async`，而不是一段 `usleep` 轮询**（2026-09-20，§8.99）：
    ///
    /// - `usleep` 是**同步阻塞、不让路**。本套件整体标着 `@MainActor`（因为 `enrich` / `icon`
    ///   走 `NSWorkspace` / `NSRunningApplication`，只能主 actor），所以原先那两段轮询是把
    ///   **主 actor** 占住最多 2 秒。
    /// - 而**当时** `OccupancyStoreTests.waitUntil`（`@MainActor`，靠 `await Task.sleep` 轮询推进）
    ///   同样会被主 actor 排队拖垮：它等的链（`sink → Task { @MainActor } → refresh`）
    ///   **必须由主 actor 调度**（§8.97.3），主 actor 被占住时它回不到手里 —— 只能干等到超时。
    ///   这正是 2026-09-17 CI 上「`磁盘列表一变就重测占用` 失败（`arrived` 为 false）」的候选根因。
    ///   ⚠️ **2026-09-22 起那条等待已改成「等事件」**（`OccupancyStoreTests.waitForNextRound`，
    ///   §8.127）⇒ 上面这段是**史实**，那个 helper 已经不存在了。本类型现在只服务
    ///   **真在等条件成立**的那几条轮询。
    /// - 加 `async` 后，`await` 会把这个函数调度到**协作线程池**上，主 actor 不再被占；
    ///   循环体内换成 `Task.sleep`（**让路**），连线程池的线程都不占住。
    ///
    /// 只收基本类型参数、不碰 `self` —— 这样它在 `nonisolated` 下没有任何隔离问题。
    ///
    /// **返回「有没有等到」**（2026-09-21，§8.113.9）—— 超时**不许静默**：
    /// 2026-09-20 CI 上它等不到就一声不吭地返回，于是下游
    /// `#require(resolved.appBundlePath)` 炸出来的信息是「必须解析出所属 app bundle」，
    /// 而**真因是「进程还没就绪」**（失败输出里 `executablePath: nil` 就是证据）。
    /// 报错指错方向，排查就绕远路 —— 而**「报错指名真因」正是当初修 §8.86 装置缺陷
    /// 的全部目的**。⇒ 等不到必须让调用方知道，由调用方自己去断言。
    ///
    /// ⚠️ **返回值从 `Bool` 换成 ``WaitOutcome``**（2026-09-21）：上一条只做到
    /// 「知道没等到」，没做到「知道为什么没等到」。失败时 `ready` 为 false 同样分不清
    /// 「进程真没起来」与「主 actor 被别的用例占住、这几拍没轮到」——
    /// 现在带上「等了多久、求值几次」，两条路的区别一眼可见（口径见 ``WaitOutcome``）。
    ///
    /// ## ⚠️ 2026-09-23：退出条件从「墙钟窗口」换成「轮询预算」（§8.132）
    ///
    /// 原来这个函数收 `timeoutMS: Int = 2000`，循环是 `while Date() < deadline`。
    /// **那是个墙钟窗口，不是「愿意看几次」** —— 而 CI 上**一次** `Task.sleep(50ms)`
    /// 实测能拖到 ~6.1s（§8.118）⇒ 整个窗口被一次睡眠吃掉，第 2 拍都轮不到
    /// ⇒ 「进程其实早就绪了」被报成「等不到」（`polls: 2, elapsed: 6.14` 就是这个形状）。
    ///
    /// ⇒ 现在拆成两个参数，各管一件事：
    ///
    /// | 参数 | 含义 | 与负载的关系 |
    /// |---|---|---|
    /// | `pollBudget` | **看几次**（默认 40 ≈ 旧 2s 窗口 / 50ms） | **无关** —— 它决定退出 |
    /// | `hardCeilingMS` | **最长挂多久**（安全网，只防挂死） | 有关，但它只在病态时才到点 |
    ///
    /// ⚠️ **`hardCeilingMS` 的默认值由 ``WaitOutcome/derivedCeilingMS`` 派生**（72s），
    /// 不再写死 20s：CI 上一拍（一次 `Task.sleep(50ms)`）实测能拖到 ~7.2s ⇒ 20s 只剩
    /// **2.8 拍**余量，而「安全网一响，它就又变成判据」（§8.135.4）。细节见
    /// ``WaitOutcome/worstObservedPollMS``（§8.136）。
    ///
    /// 于是「进程没就绪」与「我排不上队」在 ``WaitOutcome/stopReason`` 上**分得开**：
    /// 前者是 ``WaitOutcome/StopReason/budgetExhausted``（看够了），
    /// 后者是 ``WaitOutcome/StopReason/ceilingHit``（没看够）。
    ///
    /// ⚠️ **默认预算 40 是「与旧行为等价」的取值**（40 × 50ms = 2s）：未加载时这个函数
    /// 的耗时与改前**一样**，改的只是**谁说了算**。别把它当成新门槛。
    @discardableResult
    nonisolated static func waitForExecutablePath(
        pid: Int32,
        pollBudget: Int = 40,
        hardCeilingMS: Int = WaitOutcome.derivedCeilingMS
    ) async -> WaitOutcome {
        let started = Date()
        let ceiling = started.addingTimeInterval(Double(hardCeilingMS) / 1000)
        var polls = 0
        // ⚠️ 默认值就是「预算花完」：`while` 的条件先判，所以「预算已满」时
        // 绝不会被误报成 `ceilingHit`（两个出口在结构上互斥，见下面补查那段）。
        var stopReason = WaitOutcome.StopReason.budgetExhausted
        while polls < pollBudget {
            if Date() >= ceiling {
                stopReason = .ceilingHit
                break
            }
            polls += 1
            if ProcessAppResolver.executablePath(forPid: pid) != nil {
                return WaitOutcome(
                    stopReason: .conditionMet, polls: polls,
                    elapsed: Date().timeIntervalSince(started))
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // 退出循环时可能刚好是最后一拍就绪 —— 再查一次，别把「刚好赶上」误报成超时。
        polls += 1
        if ProcessAppResolver.executablePath(forPid: pid) != nil {
            return WaitOutcome(
                stopReason: .conditionMet, polls: polls,
                elapsed: Date().timeIntervalSince(started))
        }
        return WaitOutcome(
            stopReason: stopReason, polls: polls, elapsed: Date().timeIntervalSince(started))
    }

    // MARK: - ① 可执行路径 → 最外层 .app

    @Test func 从可执行路径取出所属应用bundle() {
        #expect(
            ProcessAppResolver.owningAppBundlePath(
                executablePath: "/Applications/IMVIDEO.app/Contents/MacOS/IMVIDEO")
                == "/Applications/IMVIDEO.app"
        )
    }

    /// helper 自己在 `.app` 里还套了一个 `.app`：必须回到**最外层**——
    /// 用户认知里的应用是 `Google Chrome`，不是 `Google Chrome Helper (Renderer)`。
    @Test func 嵌套helper回到最外层应用() throws {
        let helper =
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework"
            + "/Versions/Current/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper"
        let found = try #require(ProcessAppResolver.owningAppBundlePath(executablePath: helper))
        #expect(found == "/Applications/Google Chrome.app", "实际取到：\(found)")
        #expect(!found.contains("Helper"), "取到了嵌套 helper.app，而不是用户认知里的主应用")
    }

    /// 非 app 内进程（CLI）不该被硬塞一个应用名。
    @Test func 非应用内进程没有bundle() {
        for path in ["/usr/bin/tail", "/opt/homebrew/bin/ffmpeg", "/bin/sleep"] {
            #expect(
                ProcessAppResolver.owningAppBundlePath(executablePath: path) == nil,
                "\(path) 不在任何 .app 内，不应解析出 bundle"
            )
        }
    }

    /// 相对路径 / 空路径不应崩，也不该拼出一个假的绝对路径。
    @Test func 非绝对路径不解析出bundle() {
        #expect(ProcessAppResolver.owningAppBundlePath(executablePath: "") == nil)
        #expect(ProcessAppResolver.owningAppBundlePath(executablePath: "tail") == nil)
        // 目录名里带 `.app` 但不是后缀（`notes.app.txt`）不算 bundle。
        #expect(ProcessAppResolver.owningAppBundlePath(executablePath: "/Users/me/notes.app.txt/x") == nil)
    }

    /// `NSRunningApplication.bundleURL` **不保证**是 bundle：只有 `.app` 才配当 `appBundlePath`。
    ///
    /// ⚠️ 样本是**真实踩到**的那一个（2026-09-21）：CLT 工具链下测试进程是
    /// `…/CommandLineTools/usr/libexec/swift/pm/swiftpm-testing-helper`，
    /// 它的 `bundleURL` 返回的就是**可执行文件自己的路径**。
    /// 少了这条过滤，`appBundlePath` 会变成「一个可执行文件」，
    /// 图标与显示名两处下游都会跑偏（详见 ``ProcessAppResolver/appBundlePath(fromRunningAppBundleURL:)``）。
    ///
    /// （变异：把 `hasSuffix(".app")` 那半句去掉，本断言立刻变红。）
    @Test func 非app的运行中应用路径不被当成bundle() {
        let helper =
            "/Library/Developer/CommandLineTools/usr/libexec/swift/pm/swiftpm-testing-helper"
        #expect(
            ProcessAppResolver.appBundlePath(fromRunningAppBundleURL: helper) == nil,
            "非 `.app` 的路径不许被当成应用 bundle，实际：\(helper)")
        #expect(ProcessAppResolver.appBundlePath(fromRunningAppBundleURL: nil) == nil)
        #expect(
            ProcessAppResolver.appBundlePath(fromRunningAppBundleURL: "/Applications/Bunny.app")
                == "/Applications/Bunny.app",
            "真正的 `.app` 必须原样保留（否则上面那条可能只是恒 nil）")
    }

    // MARK: - ② 显示名规整与优先级

    /// `FileManager.displayName` 会带上 `.app`（实测 `/Applications/IMVIDEO.app` → `"Bunny.app"`），
    /// 直接展示就变成 `Bunny.app`。
    @Test func 显示名规整剥掉app后缀与空白() {
        #expect(ProcessAppResolver.normalizedDisplayName("Bunny.app") == "Bunny")
        #expect(ProcessAppResolver.normalizedDisplayName("  Bunny  ") == "Bunny")
        #expect(ProcessAppResolver.normalizedDisplayName("Bunny") == "Bunny")
    }

    @Test func 候选名按优先级跳过空值() {
        #expect(ProcessAppResolver.firstDisplayName(among: [nil, "", "   ", "Bunny"]) == "Bunny")
        #expect(ProcessAppResolver.firstDisplayName(among: ["Bunny", "IMVIDEO"]) == "Bunny")
        #expect(ProcessAppResolver.firstDisplayName(among: [nil, ""]) == nil)
        #expect(ProcessAppResolver.firstDisplayName(among: []) == nil)
    }

    /// **这条是本 bug 的核心判据**：bundle 里的显示名必须优先于
    /// `Info.plist` 的原始名、可执行名、目录名。
    ///
    /// 变异测试（改 `localizedInfoDictionary` → `infoDictionary`）会让本断言变红：
    /// 那时拿到的是 `RAW-NAME-NOT-WANTED`。
    @Test func 显示名取本地化值而不是原始名() async throws {
        // 共用夹具（只建一次，见 ``Fixture/shared()``）——**不删**：别的用例还在用它。
        let fixture = try await Fixture.shared()

        let name = try #require(ProcessAppResolver.appDisplayName(bundlePath: fixture.bundlePath))
        #expect(name == Fixture.localizedDisplayName, "实际取到：\(name)")
        #expect(name != Fixture.executableFileName, "拿到了可执行名——正是旧实现显示 IMVIDEO 的原因")
        #expect(name != "RAW-NAME-NOT-WANTED", "拿到了 Info.plist 原始名，说明没走本地化字典")
        #expect(!name.hasSuffix(".app"), "显示名不该带 .app 后缀")
    }

    // MARK: - ③ 解析不出来时回落进程名

    @Test func 未解析时回落为进程名() {
        let process = OccupyingProcess(pid: 4242, processName: "tail", path: "/Volumes/Demo/x.mp4")
        #expect(process.displayName == "tail")
        #expect(process.appBundlePath == nil)
        #expect(process.executablePath == nil)
    }

    @Test func 显示名可以显式给出而不改进程名() {
        let process = OccupyingProcess(
            pid: 75019, processName: "IMVIDEO", displayName: "Bunny",
            appBundlePath: "/Applications/IMVIDEO.app", path: "/Volumes/wenbo-data/x.mp4")
        #expect(process.displayName == "Bunny")
        #expect(process.processName == "IMVIDEO", "进程名要保留，用于「为什么两个名字不同」的说明")
        #expect(process.id == 75019)
    }

    /// 拿**真实 PID** 解析：任何一支都不允许产出空名字。
    @Test func 真实进程解析出的名字必不为空() {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let resolved = ProcessAppResolver.enrich(
            OccupyingProcess(pid: pid, processName: "test-runner", path: ""))
        #expect(!resolved.displayName.isEmpty)
        #expect(resolved.executablePath != nil, "自己进程的 proc_pidpath 必须取得到")
        if let bundle = resolved.appBundlePath {
            #expect(bundle.hasSuffix(".app"))
        }
    }

    /// **不在任何 `.app` 内**的 CLI 进程：名字必须回落为进程名。
    ///
    /// 这条专门盯住 `enrich` 末尾那条回落分支。它必须真的用一个 `appBundlePath == nil`
    /// 的进程来测——多数进程都躲在某个 `.app` 里，而 `appDisplayName` 的最后一个候选
    /// （`FileManager.displayName` = 目录名）**总会返回非空**，于是选错样本时
    /// 「名字不为空」会被自动满足，回落分支等于没测。
    /// （变异：把 `?? process.processName` 改成 `?? ""`，本断言立刻变红。）
    ///
    /// ⚠️ **这一处曾经把 `waitForExecutablePath` 的返回值丢掉**（2026-09-22 修）：
    /// `@discardableResult` 让它编得过，于是超时**一声不吭**，失败落到下面那句
    /// 「`executablePath` 不是 `/bin/sleep`」上 —— 报错指向「回落分支坏了」，
    /// 而真因是**进程还没就绪**。2026-09-22 CI 就是这么红的（报在 `:331`）。
    /// ⇒ §8.113.9 的口径（「等不到必须让调用方知道」）当时**漏了这个调用点**，
    /// 现在与 `端到端把可执行名解析成应用名` 那条统一走 ``expectArrived``。
    @Test func 非应用内进程回落为进程名() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }
        let ready = await Self.waitForExecutablePath(pid: process.processIdentifier)
        expectArrived(
            ready,
            """
            `proc_pidpath` 在超时前没取到可执行路径 —— 这是**「进程还没就绪」**，
            不是「回落分支坏了」（§8.113.9）。分开报，是为了下次红的时候一眼看出是哪一半。
            """)

        let resolved = ProcessAppResolver.enrich(
            OccupyingProcess(pid: process.processIdentifier, processName: "sleep", path: ""))
        #expect(
            resolved.appBundlePath == nil,
            "/bin/sleep 不在任何 .app 内，不应解析出 bundle；实际：\(resolved.appBundlePath ?? "nil")")
        #expect(resolved.displayName == "sleep", "应回落为进程名，实际：\(resolved.displayName)")
        #expect(resolved.executablePath == "/bin/sleep")
    }

    /// 真实运行中的 GUI 应用：显示名必须等于该应用自己的 `localizedName`。
    ///
    /// 用 `localizedName` 做期望值而不是写死字符串——系统语言换成英文/繁体时断言依然成立。
    /// Finder 一直在跑；万一没有 GUI 会话（无头 CI）就跳过，不制造假红。
    @Test func 运行中应用的显示名等于其localizedName() throws {
        guard
            let finder = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.apple.finder"
            }),
            let finderBundlePath = finder.bundleURL?.path,
            let finderName = finder.localizedName
        else {
            return
        }
        let resolved = ProcessAppResolver.enrich(
            OccupyingProcess(pid: finder.processIdentifier, processName: "Finder", path: ""))
        #expect(
            resolved.displayName == finderName,
            "显示名应取运行中应用的 localizedName（\(finderName)），实际 \(resolved.displayName)")
        #expect(resolved.appBundlePath == finderBundlePath)
    }

    // MARK: - ④ 端到端：真的有一个「显示名 ≠ 可执行名」的进程在跑

    /// 复刻用户报的现象：进程可执行名是 `IMVIDEO-LIKE-EXEC`，而它所属应用叫 `Localized Bunny`。
    /// 解析结果必须是 **应用名**，并且带上可定位图标的 bundle 路径。
    @Test func 端到端把可执行名解析成应用名() async throws {
        // 共用夹具（只建一次，见 ``Fixture/shared()``）——**不删**：别的用例还在用它。
        let fixture = try await Fixture.shared()
        let process = try fixture.launch()
        defer { process.terminate() }
        let ready = await Self.waitForExecutablePath(pid: process.processIdentifier)
        // ⚠️ 走 ``expectArrived``：消息里那句「等了多久、求值几次」由 ``WaitOutcome``
        // 唯一决定，调用处漏不掉（手写 `#expect(ready.ok, "…")` 就会漏）。
        expectArrived(
            ready,
            """
            `proc_pidpath` 在超时前没取到可执行路径 —— 这是**「进程还没就绪」**，
            不是「解析不出 bundle」（§8.113.9）。CI 比本地慢约 8 倍（本地 5.0s / CI 41.9s），
            所以这一条会偶发超时：连续出现 ⇒ 该按 CI 速度重定超时阈值，
            而不是 `enrich` 有问题。分开报，是为了下次红的时候一眼看出是哪一半。
            """)

        let resolved = ProcessAppResolver.enrich(
            OccupyingProcess(
                pid: process.processIdentifier,
                processName: Fixture.executableFileName,
                path: "/Volumes/Demo/clip.mp4"))

        let bundle = try #require(
            resolved.appBundlePath,
            """
            解析不出所属 app bundle（图标就没来源了）。
            ⚠️ 若上面那条「进程还没就绪」也红了，那**这一条是被它连累的** ——
            进程还没就绪时 `enrich` 自然拿不到 bundle，先看上面那条。
            """)
        #expect(bundle.hasSuffix("/Bunny Fixture.app"), "实际：\(bundle)")
        #expect(
            resolved.executablePath?.hasSuffix("/\(Fixture.executableFileName)") == true,
            "实际：\(resolved.executablePath ?? "nil")")
        #expect(
            resolved.displayName == Fixture.localizedDisplayName,
            "界面应显示应用名 \(Fixture.localizedDisplayName)，实际 \(resolved.displayName)")
        #expect(resolved.displayName != resolved.processName)
    }

    /// 批量解析与单个解析必须一致（``OccupancyDetector`` 走的是批量那条）。
    @Test func 批量解析与单个解析结果一致() async throws {
        // 共用夹具（只建一次，见 ``Fixture/shared()``）——**不删**：别的用例还在用它。
        let fixture = try await Fixture.shared()
        let process = try fixture.launch()
        defer { process.terminate() }
        let one = OccupyingProcess(
            pid: process.processIdentifier, processName: Fixture.executableFileName, path: "")

        let singly = ProcessAppResolver.enrich(one)
        let batch = ProcessAppResolver.enrich([one])
        #expect(batch == [singly])
    }

    // MARK: - 图标

    /// 解析不出任何路径时返回 `nil`，让视图回落到 SF Symbol（而不是塞一张白纸通用图标）。
    @Test func 无路径时图标为nil() {
        let process = OccupyingProcess(pid: 0, processName: "ghost", path: "")
        #expect(ProcessAppResolver.icon(for: process) == nil)
    }

    /// 有应用 bundle 时取到**真图标**：与「通用应用图标」不是同一张。
    @Test func 应用bundle取到真图标() async throws {
        // 共用夹具（只建一次，见 ``Fixture/shared()``）——**不删**：别的用例还在用它。
        let fixture = try await Fixture.shared()
        let process = OccupyingProcess(
            pid: 1, processName: Fixture.executableFileName, appBundlePath: fixture.bundlePath, path: "")
        let icon = try #require(ProcessAppResolver.icon(for: process))
        let generic = NSWorkspace.shared.icon(for: .application)
        // ⚠️ **光栅化必须离开主 actor**（见 ``tiffDataOffMainActor`` 的说明）：冷启动实测 3.93s。
        let realTiff = await tiffDataOffMainActor(icon)
        let genericTiff = await tiffDataOffMainActor(generic)
        #expect(realTiff != genericTiff)
    }

    // MARK: - 文案格式
    /// `String(format:)` 的占位符数量必须与传参一致，否则会渲染出乱码或崩在格式化上。
    @Test func 进程名提示格式串含两个占位符() {
        let format = L10n.tr(.processExecutableNameFormat)
        #expect(
            format.components(separatedBy: "%@").count - 1 == 2,
            "格式串应有 2 个 %@，实际：\(format)")
    }

    // MARK: - 等待 helper 自己的守卫

    /// `waitForExecutablePath` 的返回值必须**带得出数字**。
    ///
    /// ⚠️ **2026-09-22 起本文件是「轮询」这一族的唯一守卫**：`OccupancyStoreTests` 那条
    /// 等待换成了**等事件**（它的守卫也随之换成 `等事件的装置必须分开报事件到了与接线断了`）。
    /// 现在用 ``WaitOutcome`` 的只剩这里与 `IntegrationEjectTests.waitForDisk`。
    ///
    /// ⚠️ 「`failureNote` 拼出来的那句话里有没有数字」的断言**也搬到了这里**
    /// （原先写在 `OccupancyStoreTests` 那条里）—— 它断的是 ``WaitOutcome/failureNote``
    /// 这个**纯函数**，而该函数现在只被 ``expectArrived`` 用，也就是只被本文件与
    /// `IntegrationEjectTests` 用 ⇒ 断言跟着它的主体走，**一处真相 + 一处指针**。
    ///
    /// **为什么这条值得单独写**：本文件里唯一「守装置而不是守产品」的测试。少了它，
    /// 「失败信息里到底有没有数字」只能靠**下次 CI 真红**才发现 —— 而 2026-09-20 CI
    /// 上真红过一次，当时报的是「必须解析出所属 app bundle」，真因却是「进程还没就绪」
    /// （见 `waitForExecutablePath` 的文档注释）。报错指错方向，排查就绕远路。
    ///
    /// ⚠️ 样本是**确定性**的，不依赖机器快慢，也不依赖被测逻辑：
    /// - 正路：一个**不可能存在**的 PID（`kern.maxproc` 上限约 10 万，所以 `999_999` 必不存在）
    ///   + **极小的轮询预算**（1 拍）⇒ 一定放弃，且轮询次数下界由代码结构决定；
    /// - 反路（阴性对照）：**当前进程自己的 PID** ⇒ 第一次求值就成立，恰好 1 拍。
    ///
    /// ⚠️ **2026-09-23（§8.132）**：参数从 `timeoutMS: 50` 换成 `pollBudget: 1`。
    /// 旧写法是「墙钟窗口 50ms」，而墙钟会被调度拖长（一次 `Task.sleep(50ms)` 在 CI 上
    /// 实测能拖到 ~6.1s）⇒ 那条 `elapsed >= 0.05` 是**被拖出来的**，不是「窗口到了」。
    /// 现在预算 1 拍 ⇒ 恰好一次 50ms 睡眠 ⇒ 那条断言量的才是它自己说的话。
    @Test func 等待可执行路径超时时必须报出轮询次数与耗时() async {
        let timedOut = await Self.waitForExecutablePath(pid: 999_999, pollBudget: 1)

        #expect(!timedOut.ok, "999999 不可能有进程，`ok` 必须是 false")
        #expect(
            timedOut.polls >= 2,
            "至少要有「循环里那次」与「放弃后那次补查」两次求值，实得 \(timedOut.polls)")
        #expect(timedOut.elapsed >= 0.05, "预算 1 拍 ⇒ 恰好一次 50ms 睡眠，实得 \(timedOut.elapsed)")
        #expect(
            timedOut.stopReason == .budgetExhausted,
            "预算花完而放弃 ⇒ 必须是「看够了」，实得 \(timedOut.stopReason)")
        // ⚠️ 只断言 ok/polls/elapsed **还不够**：`diagnostic` 才是给下一个排查的人看的那句话，
        // 而它完全可能被写成一句不带数字的空话（那样等于没改）。
        #expect(
            timedOut.diagnostic.contains("\(timedOut.polls)") && timedOut.diagnostic.contains("s、"),
            "诊断串里没带出实际数字：\(timedOut.diagnostic)")

        // ⚠️ `diagnostic` 有数字**还不够**：真正给排查的人看的是 `failureNote` 拼出来的
        // 那句话（``expectArrived`` 用它当 `#expect` 的消息），它完全可能把 `diagnostic`
        // 整个丢掉 —— 那样等于没改，而且不会有任何东西变红。所以这里直接断言拼出来的结果。
        // （断言只挑**与 locale 无关**的部分：`%.2f` 的小数点在某些 locale 下会变逗号。）
        let note = WaitOutcome(stopReason: .budgetExhausted, polls: 7, elapsed: 1.25)
            .failureNote("在等 X")
        #expect(
            note.contains("在等 X") && note.contains("7") && note.contains("s、"),
            "失败信息没把「在等什么」与数字拼在一起：\(note)")

        // 阴性对照（反向）：上面那条 `polls >= 2` 必须能区分「等到了」与「没等到」，
        // 否则它可能只是恒真。
        let immediate = await Self.waitForExecutablePath(pid: getpid())
        #expect(immediate.ok, "当前进程自己的可执行路径必须取得到")
        #expect(immediate.polls == 1, "第一次求值就成立 ⇒ 恰好 1 拍，实得 \(immediate.polls)")
        #expect(
            immediate.stopReason == .conditionMet,
            "等到了 ⇒ 必须是「条件成立」，实得 \(immediate.stopReason)")
        #expect(
            !immediate.diagnostic.contains("始终不成立"),
            "成立的等待不该报「始终不成立」：\(immediate.diagnostic)")
    }

    /// **安全网先到时也必须报「没看够」**（2026-09-23，§8.136）。
    ///
    /// ⚠️ 补的是**一直开着的缺口**：本文件原来只守了 `.budgetExhausted`（「看够了」）那一个
    /// 出口，`.ceilingHit`（「没看够」）**没有任何守卫** ⇒ 谁把安全网的判断改坏
    /// （让它永不发生、或反过来永远发生），**不会有任何东西变红**。
    /// `IntegrationEjectTests` 那边两个出口都有牙（§8.132），这边缺一个 ⇒ 补上。
    ///
    /// 判据**刻意写成「拍数远小于预算」而不是某个具体数字**：撞安全网时拍数本来就随负载变
    /// （那正是「没看够」的定义），钉死数字等于把调度延迟写进判据。
    ///
    /// ⚠️ 拍间隔**保持默认 50ms**：这条要的就是「一拍比安全网长」—— 压到 1ms ⇒ 100 拍只花
    /// 100ms ⇒ 变成预算先到，这条守卫就没了。
    @Test func 安全网先到时必须报没看够() async {
        let starved = await Self.waitForExecutablePath(
            pid: 999_999, pollBudget: 100, hardCeilingMS: 200)

        #expect(
            starved.stopReason == .ceilingHit,
            "安全网先到 ⇒ 必须是「没看够」，实得 \(starved.stopReason)")
        #expect(
            starved.polls < 100,
            "撞安全网时拍数必须**远小于**预算 —— 这正是「没看够」的判据，实得 \(starved.polls)")
        #expect(!starved.ok, "恒不成立 ⇒ `ok` 必须是 false")
        #expect(
            starved.diagnostic.contains("没看够"),
            "「没看够」这句话必须出现在诊断里 —— 它是给下一个排查的人看的：\(starved.diagnostic)")
    }

    /// **`ok` 必须是从 ``WaitOutcome/StopReason`` 派生的**（2026-09-23，§8.132）。
    ///
    /// 为什么值得单独一条：`ok` 与 `stopReason` 表达的是**同一件事**（条件到底成没成立）。
    /// 一旦有人把它们写成两个各自赋值的存储属性，就会出现「`ok == true` 但
    /// `stopReason == .ceilingHit`」这种自相矛盾的组合 —— 而**没有任何东西会红**。
    /// 这条守卫用三个构造样本把「派生关系」钉死。
    @Test func ok必须由stopReason派生() {
        let met = WaitOutcome(stopReason: .conditionMet, polls: 1, elapsed: 0.01)
        let exhausted = WaitOutcome(stopReason: .budgetExhausted, polls: 40, elapsed: 2.0)
        let starved = WaitOutcome(stopReason: .ceilingHit, polls: 2, elapsed: 20.0)

        #expect(met.ok, "`conditionMet` ⇒ `ok` 必须为 true")
        #expect(!exhausted.ok && !starved.ok, "两种「放弃」⇒ `ok` 必须为 false")

        // ⚠️ **两种放弃必须说成两句不同的话**：它们在 ok/polls/elapsed 上都可能逐字相同，
        // 只有这句话能把下一个排查的人指向正确的方向（被测逻辑 vs 环境）。
        #expect(
            exhausted.diagnostic.contains("看够了") && !exhausted.diagnostic.contains("没看够"),
            "「预算花完」必须说成「看够了」：\(exhausted.diagnostic)")
        #expect(
            starved.diagnostic.contains("没看够") && !starved.diagnostic.contains("看够了"),
            "「撞上安全网」必须说成「没看够」：\(starved.diagnostic)")
        #expect(
            exhausted.diagnostic != starved.diagnostic,
            "两种放弃说成了同一句话 ⇒ 分辨力为零：\(exhausted.diagnostic)")
    }
}
