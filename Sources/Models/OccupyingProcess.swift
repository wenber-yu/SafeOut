import Foundation

/// 一个正在访问外置卷的进程。
///
/// **关于命名**：此前该类型叫 `ProcessInfo`，与 Foundation 的 `ProcessInfo` 同名，
/// 导致测试文件里不得不写 `private typealias AppProcessInfo = SafeOutApp.ProcessInfo`
/// 来消除歧义——命名冲突的成本已经外溢到调用方，这本身就是该改名的信号。
///
/// **关于「名字」有两个**（这是用户报过的一个 bug 的根因）：
/// - ``processName`` 是进程自己的可执行名（`lsof` 的 `c` 字段），如 `IMVIDEO`；
/// - ``displayName`` 是**用户在 Dock / 菜单栏里看到的应用名**，如 `Bunny`。
///
/// 二者不等价：`/Applications/IMVIDEO.app` 的 bundle 与可执行文件都叫 `IMVIDEO`，
/// 但它的本地化显示名是 `Bunny`。**UI 一律用 ``displayName``**，``processName``
/// 只用于展示「为什么两个名字不一样」以及诊断输出。解析逻辑见 ``ProcessAppResolver``。
struct OccupyingProcess: Identifiable, Sendable, Equatable {

    /// 占用者的种类。
    ///
    /// **为什么需要区分**：磁盘映像（DMG）不是进程——它没有可发信号的 pid，
    /// 「关闭」它的动作是 `hdiutil detach` 而不是 `SIGTERM`。
    /// 若把映像伪装成普通进程混在列表里，清场流程会向一个合成 pid 发信号，
    /// 而 POSIX 里 `kill(0)` / `kill(负值)` 的语义是「**整个进程组**」——这是本仓库
    /// 最危险的一类误操作（见 ``ProcessTerminator`` 的双重防线）。
    enum Kind: Sendable, Equatable {
        /// 普通进程，`pid` 是真实 pid。
        case process
        /// 磁盘映像（DMG）占用，`pid` 是合成负值（仅作 `Identifiable` 身份，**不可发信号**）。
        case diskImage(device: String)
    }

    /// 进程标识符，同时作为 `Identifiable` 的 id。
    ///
    /// 此前是 `let id = UUID()`，与基于 pid 的 `==` / `hash` 语义冲突：两个 pid 相同的实例
    /// 被判为相等，id 却不同。SwiftUI 的 diff 依赖 `Identifiable`，这类不一致会在列表刷新时
    /// 表现为「整行被重建」的闪烁。
    ///
    /// ⚠️ 对 ``Kind/diskImage(device:)`` 条目这是**合成负值**（由 device 路径哈希，稳定、
    /// 不与真 pid 冲突），只在检测/展示链路作身份用；``ProcessTerminator`` 绝不会向它发信号。
    var id: Int32 { pid }

    let pid: Int32

    /// 进程自身的可执行名（`lsof` 的 `c` 字段），如 `IMVIDEO`。
    ///
    /// ⚠️ **这不是用户认识的应用名**，不要在 UI 里直接展示——请用 ``displayName``。
    let processName: String

    /// 用户可见名称 —— UI 的**单一事实来源**。
    ///
    /// 能定位到所属应用时是应用显示名（`Bunny`）；定位不到（`tail` / `ffmpeg` 这类
    /// 非 app 内的 CLI 进程）时回落为 ``processName``，保证任何情况下都不为空。
    var displayName: String

    /// 所属应用的 bundle 路径（`/Applications/IMVIDEO.app`）；非 app 内进程为 `nil`。
    ///
    /// 图标必须从这个路径取（实测取可执行文件路径会拿到另一个图标）。
    var appBundlePath: String?

    /// 进程可执行文件路径（`…/IMVIDEO.app/Contents/MacOS/IMVIDEO`）；解析失败为 `nil`。
    var executablePath: String?

    /// 该进程访问卷内文件的代表路径（UI 目前不展示，仅诊断/排查用）。
    ///
    /// 对 ``Kind/diskImage(device:)`` 条目：backing 文件（`.dmg`）的完整路径，
    /// 芯片悬停提示会展示它（用户可自证「是哪张映像在占」）。
    let path: String

    /// 占用者种类（默认 ``Kind/process``，既有调用点零改动）。
    let kind: Kind

    /// - Parameter displayName: 省略或传 `nil` 表示「尚未解析应用身份」，此时回落为
    ///   ``processName``。这条默认规则保证 UI 永远不会显示空白名字。
    init(
        pid: Int32,
        processName: String,
        displayName: String? = nil,
        appBundlePath: String? = nil,
        executablePath: String? = nil,
        path: String,
        kind: Kind = .process
    ) {
        self.pid = pid
        self.processName = processName
        self.displayName = displayName ?? processName
        self.appBundlePath = appBundlePath
        self.executablePath = executablePath
        self.path = path
        self.kind = kind
    }

    /// 构造一个「磁盘映像占用」条目。
    ///
    /// - `pid` 用**合成负值**：`-1 - (fnv1a32(device) & 0x3FFFFFFF)`。
    ///   - 负值永不与真实 pid 冲突（真 pid 恒 > 0）；
    ///   - 由 device 路径决定 ⇒ 同一张映像每轮检测得到**相同** id，SwiftUI 列表不闪行。
    ///     ⚠️ 不能用 Swift 自带 `hashValue`——它每次进程启动都随机化，id 会每轮都变。
    /// - `processName` / `displayName` = backing 文件名（如 `Game.dmg`）：
    ///   映像没有「应用身份」可解析，文件名就是用户唯一能认出的名字。
    static func diskImage(imagePath: String, device: String) -> OccupyingProcess {
        let name = URL(fileURLWithPath: imagePath).lastPathComponent
        return OccupyingProcess(
            pid: -1 - Int32(fnv1a32(device) & 0x3FFF_FFFF),
            processName: name,
            path: imagePath,
            kind: .diskImage(device: device)
        )
    }

    /// FNV-1a 32 位哈希——跨进程启动**稳定**的字符串哈希（合成 pid 的种子）。
    private static func fnv1a32(_ string: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in string.utf8 {
            hash = (hash ^ UInt32(byte)) &* 0x0100_0193
        }
        return hash
    }
}
