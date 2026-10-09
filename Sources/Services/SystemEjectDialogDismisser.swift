import AppKit
import ApplicationServices
import Foundation
import OSLog

/// 关掉系统那张「磁盘被占用 / 未能推出」框（`UnmountAssistantAgent` 弹的）。
///
/// ## 为什么需要它（2026-09-29 用户需求）
///
/// 访达里点推出 → 盘被占用 → macOS 弹框；用户改用本应用的「关闭并推出」把盘推出后，
/// 那个框**不会**自己消失 —— 真机实测：盘已从 `/Volumes` 消失，框仍挂在屏幕上。
/// 本类在应用把盘推出之后，替用户**按掉那个框**。
///
/// ## ⚠️ 这个框有**两种形态**（2026-09-29 真机抓全，两次 dump 的原文见下）
///
/// 形态 A（推出**正在尝试**中）：
/// ```text
/// 磁盘“SpikeVol”没有被推出，因为一个或多个程序可能正在使用它。
/// 要立即推出该磁盘，请点按“强制推出”按钮。
///   AXButton title=「取消」        ← 窗口暴露 AXCancelButton
///   AXButton title=「强制推出…」   ← 窗口暴露 AXDefaultButton
///   AXButton desc=「帮助」
/// ```
///
/// 形态 B（尝试**已经失败**，占用者被点名）：
/// ```text
/// 磁盘“SpikeVol”未能推出，因为“WorkBuddy”正在使用它。
/// 请退出那个应用程序，然后再次尝试推出该磁盘。
///   AXButton title=「好」          ← **只有这一个带标题的按钮，且没有 AXCancelButton**
///   AXButton desc=「帮助」
/// ```
///
/// ⇒ 只按 `AXCancelButton` **会漏掉形态 B**（实测就是这么漏的）。
/// 兜底判据见 ``pressPlan(hasCancelButton:titledButtonCount:)``。
///
/// ## ⚠️ 绝不能按「强制推出…」
///
/// 形态 A 的 `AXDefaultButton` 是 **「强制推出…」** —— 按下去会强制卸载（可能丢数据）。
/// 所以兜底**只认「带标题的按钮恰好只有一个」**：形态 A 有两个（取消 / 强制推出…）⇒
/// 兜底拒绝动手；形态 B 只有一个（好）⇒ 那它就是唯一出口。这条判据必须单测钉死。
///
/// ## ⚠️ 两条路径：AX 按按钮（首选）/ 结束弹框进程（兜底）
///
/// **真机实测（2026-09-29）**：应用**自身**跑起来时 `AXIsProcessTrusted()` 是
/// `false` —— 从终端跑同一个可执行文件却是 `true`。原因是 TCC 授权**按责任进程**算：
/// 终端启动时算在终端头上，`open` 启动时算在应用自己头上。
///
/// 而本应用是 self-signed 分发，**每次重新构建，辅助功能授权就失效**。
/// ⇒ 如果只有 AX 一条路，这个功能对绝大多数用户**默认就是不工作的**
/// （表现与「逻辑写错了」逐字相同：盘推出了，框还挂着）。
///
/// 所以：
/// 1. **有授权 → 按按钮**：`kAXPressAction` 按「取消」/「好」，语义上等于用户
///    自己放弃这次推出。**首选**，能精确到「哪一块盘的那个框」。
/// 2. **没授权（或按钮按不动）→ 结束弹框进程**（`SIGTERM`）。**不需要任何 TCC 授权**，
///    用户也不需要去系统设置点任何东西。代价是失去「按盘区分」的能力，
///    见 ``allowsTerminateFallback(windowCount:)`` 的边界。
///
/// 两条都不成时本类仍**什么也不做**，只记日志 —— 弹窗残留只是体验瑕疵，
/// 绝不能因此弹错误框、更不能卡住推出链路。
///
/// AX 调用是**跨进程同步**的，所以 ``dismiss(forDiskNamed:)`` 同步阻塞，
/// 调用方须放到后台线程。
enum SystemEjectDialogDismisser {

    private static let logger = Logger(subsystem: "com.safeout.app", category: "DismissDialog")

    /// 弹框进程的**窗口拥有者名**（`kCGWindowOwnerName`）。
    ///
    /// **为什么按名字而不是 bundle id**：该进程是 `LSUIElement`，不在
    /// `NSWorkspace.runningApplications` 里；而窗口列表的拥有者名由窗口服务器直接给出，
    /// 与激活策略无关（与 `Tools/probe/windowid.swift` 同一条理由）。
    static let agentOwnerName = "UnmountAssistantAgent"

    /// 本进程有没有辅助功能授权。**全仓读 `AXIsProcessTrusted()` 只此一处**
    /// （``dismiss(forDiskNamed:)`` 也读它，不是第二处真相）。
    ///
    /// 抽出来是给「要不要引导用户授权」用的（``shouldSuggestAccessibility(isTrusted:)``）：
    /// 授权状态要同时决定「关框走哪条路」与「设置面板提不提示」，
    /// 两处各调一次系统 API 就会在**面板还开着时用户刚授权完**这类时序下分叉。
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// 打开「推出时提醒占用」时，要不要顺带引导用户去授辅助功能权限。
    ///
    /// **唯一的判据是「有没有授权」**：已授权的用户不该再被这件事打扰一次
    /// —— 他刚在系统设置里点过，再提就是纯噪音。
    ///
    /// 反过来「没授权时每次都提」是有意的，理由（以及为什么不做成 FDA 那样的
    /// 一次性标记）见 ``SettingsView/suggestAccessibilityIfNeeded()``。
    static func shouldSuggestAccessibility(isTrusted: Bool) -> Bool { !isTrusted }

    /// AX 调用超时（秒）。卡住的元素不该把推出链路拖住。
    private static let messagingTimeout: Float = 2.0

    /// 一次关框尝试的结果。
    ///
    /// **为什么要把它打出来**：这段逻辑的失败有五种**外观完全相同**的可能
    /// （没授权 / 找不到进程 / 没有窗口 / 窗口不是这块盘的 / 按钮形态没覆盖到），
    /// 而它们都表现为「框还在」。真机验收（`--dismiss-system-dialog <盘名>`）
    /// 靠这几个数字才能分清是哪一种。
    struct DismissReport: Equatable {
        /// 有没有辅助功能授权。**为假时 `matchedWindowCount` / `pressedCount` 必为 0**
        /// （读不到 AX 树），此时只能走结束进程的兜底。
        var isTrusted = false
        /// 找到的 `UnmountAssistantAgent` 进程数。
        var agentProcessCount = 0
        /// 遍历过的窗口数。
        var windowCount = 0
        /// 正文里提到目标盘的窗口数。
        var matchedWindowCount = 0
        /// 成功按下的按钮数（AX 路径）。
        var pressedCount = 0
        /// 结束掉的弹框进程数（兜底路径）。
        var terminatedCount = 0
        /// 因「该进程挂着不止一个框、分不清哪块盘」而**主动放弃**兜底的次数。
        var skippedAmbiguousCount = 0
    }

    /// 关掉「关于这块盘」的系统框。**同步阻塞**，请放到后台线程调用。
    ///
    /// - Parameter name: 磁盘显示名（``DiskInfo/displayName``）。框的正文里含卷名，
    ///   用它把「这块盘的框」与「别的盘的框」区分开。
    /// - Returns: 这次尝试的明细（见 ``DismissReport``）。
    @discardableResult
    static func dismiss(forDiskNamed name: String) -> DismissReport {
        var report = DismissReport()

        // 进程与窗口计数**不需要任何授权**（窗口服务器直接给的），
        // 所以这一步永远能跑，也是两条路径的共同入口。
        let counts = windowCounts(ownerName: agentOwnerName)
        report.agentProcessCount = counts.count
        guard !counts.isEmpty else {
            logger.debug("没有 UnmountAssistantAgent 窗口，无需关框")
            return report
        }

        // ── 路径 1：AX 按按钮（需要辅助功能授权）─────────────────────────
        if isAccessibilityTrusted {
            report.isTrusted = true
            for (pid, _) in counts.sorted(by: { $0.key < $1.key }) {
                pressCancelButton(ofAgent: pid, diskName: name, report: &report)
            }
            if report.pressedCount > 0 { return report }
            logger.notice("AX 路径没按动任何按钮，转兜底（盘=\(name, privacy: .public)）")
        } else {
            logger.notice("没有辅助功能授权，直接走结束进程的兜底（盘=\(name, privacy: .public)）")
        }

        // ── 路径 2：结束弹框进程（不需要任何授权）───────────────────────
        for (pid, windowCount) in counts.sorted(by: { $0.key < $1.key }) {
            guard allowsTerminateFallback(windowCount: windowCount) else {
                report.skippedAmbiguousCount += 1
                logger.notice(
                    "pid \(pid, privacy: .public) 挂着 \(windowCount, privacy: .public) 个框，分不清哪块盘，不动手"
                )
                continue
            }
            if kill(pid, SIGTERM) == 0 {
                report.terminatedCount += 1
                logger.notice("已结束系统占用框进程 pid=\(pid, privacy: .public) 盘=\(name, privacy: .public)")
            } else {
                logger.notice(
                    "结束系统占用框进程失败 pid=\(pid, privacy: .public) errno=\(errno, privacy: .public)")
            }
        }
        return report
    }

    /// AX 路径：在 `pid` 的窗口里找到「关于这块盘」的那个，按掉它该按的按钮。
    ///
    /// 读不到 AX 树时（没授权 / 进程刚退出）所有属性都返回 `nil`，
    /// 这里会自然地什么都不做 —— 不需要额外的授权判断。
    private static func pressCancelButton(
        ofAgent pid: pid_t, diskName name: String, report: inout DismissReport
    ) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        for window in windows(of: app) {
            report.windowCount += 1

            var texts: [String] = []
            collectTexts(of: window, depth: 0, into: &texts)
            guard mentionsDisk(texts, name: name) else { continue }
            report.matchedWindowCount += 1

            let buttons = dialogButtons(in: window)
            let target: AXUIElement?
            switch pressPlan(
                hasCancelButton: buttons.cancel != nil, titledButtonCount: buttons.titled.count)
            {
            case .cancel: target = buttons.cancel
            case .soleButton: target = buttons.titled.first
            case .none: target = nil
            }

            guard let button = target else {
                logger.notice("pid \(pid, privacy: .public) 的框既没有取消按钮、也不止一个按钮，不动手")
                continue
            }
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if result == .success {
                report.pressedCount += 1
                logger.notice("已关闭系统占用框 pid=\(pid, privacy: .public) 盘=\(name, privacy: .public)")
            } else {
                logger.notice(
                    "关闭系统占用框失败 pid=\(pid, privacy: .public) AXError=\(result.rawValue, privacy: .public)"
                )
            }
        }
    }

    // MARK: - 纯判据（可单测）

    /// 该按哪个按钮。
    enum PressPlan: Equatable {
        /// 按「取消」（形态 A）。**首选**：它是「放弃这次推出」的正确回执。
        case cancel
        /// 按**唯一**那个带标题的按钮（形态 B 的「好」）。
        case soleButton
        /// 不动手。
        case none
    }

    /// 「该按哪一个」的**纯判据**。
    ///
    /// ⚠️ **这条判据是全段里最危险的规则**：判错会去按「强制推出…」= 强制卸载 = 可能丢数据。
    /// 所以抽成纯函数、单测钉死（调用点写反不会有任何编译错）。
    ///
    /// - Parameters:
    ///   - hasCancelButton: 窗口有没有暴露 `AXCancelButton`。
    ///   - titledButtonCount: 窗口里**带标题**的按钮有几个（「帮助」那种只有描述的不算）。
    /// - Returns: 见 ``PressPlan``。
    ///
    /// **为什么兜底要求「恰好一个」**：形态 A 有**两个**带标题的按钮
    /// （「取消」「强制推出…」），此时 `AXDefaultButton` 正是「强制推出…」——
    /// 一旦在「取消」缺失时退回默认按钮，就等于替用户强制卸载。
    static func pressPlan(hasCancelButton: Bool, titledButtonCount: Int) -> PressPlan {
        if hasCancelButton { return .cancel }
        return titledButtonCount == 1 ? .soleButton : .none
    }

    /// 这组文本是否提到了这块盘。
    ///
    /// **纯函数**，独立出来是为了让「匹配哪块盘」这条判据能被单测真正跑一遍 ——
    /// 判错了会去关**别的盘**的框，而那种事没有任何编译错、也看不出日志异常。
    ///
    /// - 名称为空一律返回 `false`：空串是 `String.contains` 的**万能匹配**，
    ///   放过去等于「任何窗口都算这块盘」，会误关别的盘的框。
    static func mentionsDisk(_ texts: [String], name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return texts.contains { $0.contains(name) }
    }

    /// 没有辅助功能授权时，「结束这个进程」算不算安全。
    ///
    /// **为什么要求「恰好 1 个窗口」**：读不到 AX 树就读不到框的正文，
    /// 也就**无法判断这个框是关于哪一块盘的**。而结束进程是整锅端 ——
    /// 如果 agent 同时挂着多个框（用户先点了 A 盘、又点了 B 盘），
    /// 会把**跟本次操作无关**的框一起关掉。
    ///
    /// 只有一个窗口时，它必然就是刚才那块盘弹出来的那个（app 的关框紧随
    /// 自己的推出动作之后，不存在「同时挂两个」的窗口期）。
    ///
    /// ⇒ 多窗口时**宁可不动手**：留一个框是体验瑕疵，误关别人的框是错误行为。
    static func allowsTerminateFallback(windowCount: Int) -> Bool {
        windowCount == 1
    }

    /// 当前在屏窗口里，拥有者名匹配的进程，以及**每个进程拥有的窗口数**。
    ///
    /// 计数与取 pid 用同一次窗口列表快照 —— 分成两次调用的话，
    /// 两次之间框可能刚好消失，计数与 pid 会对不上。
    static func windowCounts(ownerName: String) -> [pid_t: Int] {
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [:] }
        var counts: [pid_t: Int] = [:]
        for info in list {
            guard info[kCGWindowOwnerName as String] as? String == ownerName,
                let raw = info[kCGWindowOwnerPID as String] as? NSNumber
            else { continue }
            counts[pid_t(raw.int32Value), default: 0] += 1
        }
        return counts
    }

    /// 当前在屏窗口里，拥有者名匹配的进程 pid（去重，按 pid 升序）。
    ///
    /// 顺序**稳定**（字典本身无序）：反复调用同一现场应当给出同一个数组，
    /// 否则「先关哪个框」会随字典哈希抖动。
    static func pidsOwningWindows(ownerName: String) -> [pid_t] {
        windowCounts(ownerName: ownerName).keys.sorted()
    }

    // MARK: - AX 取属性

    /// 遍历深度上限。这个框的 AX 树只有 2~3 层，8 足够且能防住异常深的自引用。
    private static let maxDepth = 8

    /// 一个窗口里的按钮：取消按钮（可能没有）+ **带标题**的按钮清单。
    private struct DialogButtons {
        var cancel: AXUIElement?
        var titled: [AXUIElement]
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    /// 收集窗口里的按钮：`AXCancelButton` 指的是哪一个，以及**带标题**的按钮有哪些。
    ///
    /// 只认**带标题**的按钮：「帮助」那个按钮只有 `AXDescription`，不该参与
    /// 「是不是只有一个按钮」的计数（算进去的话形态 B 就变成两个了）。
    private static func dialogButtons(in window: AXUIElement) -> DialogButtons {
        var cancel: AXUIElement?
        if let raw = attribute(window, "AXCancelButton"), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            cancel = (raw as! AXUIElement)
        }

        var titled: [AXUIElement] = []
        var stack: [AXUIElement] = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 200 {
            visited += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if role.contains("Button") {
                let title = attribute(element, kAXTitleAttribute) as? String ?? ""
                if !title.isEmpty { titled.append(element) }
            }
            stack.append(contentsOf: (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
        }
        return DialogButtons(cancel: cancel, titled: titled)
    }

    /// 收集子树里所有「像文本」的属性值（`AXValue` / `AXTitle` / `AXDescription`）。
    ///
    /// 三个都收是因为不同形态把正文放在不同属性里：形态 A/B 的正文都是
    /// `AXStaticText` 的 `AXValue`，但标题类元素走 `AXTitle`。
    private static func collectTexts(
        of element: AXUIElement, depth: Int, into acc: inout [String]
    ) {
        guard depth < maxDepth else { return }
        for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = attribute(element, key) as? String, !text.isEmpty {
                acc.append(text)
            }
        }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            collectTexts(of: child, depth: depth + 1, into: &acc)
        }
    }
}
