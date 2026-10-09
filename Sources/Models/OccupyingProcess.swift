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

    /// 进程标识符，同时作为 `Identifiable` 的 id。
    ///
    /// 此前是 `let id = UUID()`，与基于 pid 的 `==` / `hash` 语义冲突：两个 pid 相同的实例
    /// 被判为相等，id 却不同。SwiftUI 的 diff 依赖 `Identifiable`，这类不一致会在列表刷新时
    /// 表现为「整行被重建」的闪烁。
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
    let path: String

    /// - Parameter displayName: 省略或传 `nil` 表示「尚未解析应用身份」，此时回落为
    ///   ``processName``。这条默认规则保证 UI 永远不会显示空白名字。
    init(
        pid: Int32,
        processName: String,
        displayName: String? = nil,
        appBundlePath: String? = nil,
        executablePath: String? = nil,
        path: String
    ) {
        self.pid = pid
        self.processName = processName
        self.displayName = displayName ?? processName
        self.appBundlePath = appBundlePath
        self.executablePath = executablePath
        self.path = path
    }
}
