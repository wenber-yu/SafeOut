import Foundation
import Testing

@testable import SafeOutApp

/// ``EjectNotificationPolicy`` 的幂等判据。
///
/// **为什么值得单测**：它判错的表现是「访达每重试一次就多投一条系统通知」——
/// 刷屏、且**没有任何编译错**。访达的重试间隔约 2s，用户会在一分钟内收到几十条。
///
/// 这里只测**判据本身**，不碰 `UNUserNotificationCenter`（那需要真机授权，
/// 而且无法在测试进程里观察投递结果）。
///
/// ⚠️ **每个断言都先把调用结果绑到局部变量**：`shouldPost` 是 `mutating`，
/// 而 `#expect` 宏会把表达式搬进一个闭包执行 —— 直接写 `#expect(policy.shouldPost(…))`
/// 会报「cannot use mutating member on immutable value: '$0' is immutable」。
@Suite("占用通知的幂等判据")
struct EjectNotificationPolicyTests {

    @Test func 同一块盘只投一条() {
        var policy = EjectNotificationPolicy()
        let first = policy.shouldPost(mountPath: "/Volumes/A")
        // 访达重试：同一路径再来 —— 必须**不再**投递。
        let second = policy.shouldPost(mountPath: "/Volumes/A")
        let third = policy.shouldPost(mountPath: "/Volumes/A")
        #expect(first)
        #expect(!second)
        #expect(!third)
    }

    @Test func 不同的盘互不影响() {
        var policy = EjectNotificationPolicy()
        let a = policy.shouldPost(mountPath: "/Volumes/A")
        let b = policy.shouldPost(mountPath: "/Volumes/B")
        // A 已经投过，B 的投递不该把它顺带「解锁」。
        let aAgain = policy.shouldPost(mountPath: "/Volumes/A")
        #expect(a)
        #expect(b)
        #expect(!aAgain)
    }

    @Test func 撤回之后可以重新投() {
        var policy = EjectNotificationPolicy()
        let before = policy.shouldPost(mountPath: "/Volumes/A")
        policy.forget(mountPath: "/Volumes/A")
        // 盘推出去又被重新插上、再被占用 —— 该再提醒一次。
        let after = policy.shouldPost(mountPath: "/Volumes/A")
        #expect(before)
        #expect(after)
    }

    @Test func 撤回一块盘不影响另一块() {
        var policy = EjectNotificationPolicy()
        _ = policy.shouldPost(mountPath: "/Volumes/A")
        let b = policy.shouldPost(mountPath: "/Volumes/B")
        policy.forget(mountPath: "/Volumes/A")
        let bAgain = policy.shouldPost(mountPath: "/Volumes/B")
        #expect(b)
        #expect(!bAgain)
    }
}

/// ``SystemEjectDialogDismisser/mentionsDisk(_:name:)`` 的判据。
///
/// **为什么值得单测**：它判错的表现是「去关**别的盘**的系统框」—— 用户明明在处理 A 盘，
/// B 盘的占用提示却消失了。同样没有任何编译错，日志上也看不出异常。
@Suite("系统占用框的归属判据")
struct SystemEjectDialogDismisserTests {

    /// 真机抓下来的框正文（`UnmountAssistantAgent` 的 `AXStaticText`）。
    private let realDialogTexts = [
        "磁盘“SpikeVol”没有被推出，因为一个或多个程序可能正在使用它。",
        "要立即推出该磁盘，请点按“强制推出”按钮。",
        "正在尝试推出",
    ]

    @Test func 正文提到这块盘就算它() {
        #expect(SystemEjectDialogDismisser.mentionsDisk(realDialogTexts, name: "SpikeVol"))
    }

    @Test func 正文没提到就不算() {
        #expect(!SystemEjectDialogDismisser.mentionsDisk(realDialogTexts, name: "wenbo-data"))
    }

    /// ⚠️ **空名字是 `String.contains` 的万能匹配**：放过去等于「任何窗口都算这块盘」，
    /// 会把别的盘的框一起关掉。所以必须显式拒绝。
    @Test func 空盘名一律不算() {
        #expect(!SystemEjectDialogDismisser.mentionsDisk(realDialogTexts, name: ""))
        #expect(!SystemEjectDialogDismisser.mentionsDisk([], name: ""))
    }

    @Test func 空文本列表不算() {
        #expect(!SystemEjectDialogDismisser.mentionsDisk([], name: "SpikeVol"))
    }

    /// 框的正文里盘名带**弯引号**（真机是 `“SpikeVol”`）—— 匹配的是子串，
    /// 引号不该影响判定（真机上就是这么匹配上的）。
    @Test func 带弯引号的盘名照样匹配() {
        let texts = ["磁盘“My Passport”没有被推出，因为一个或多个程序可能正在使用它。"]
        #expect(SystemEjectDialogDismisser.mentionsDisk(texts, name: "My Passport"))
    }
}

/// ``SystemEjectDialogDismisser/pressPlan(hasCancelButton:titledButtonCount:)`` 的判据。
///
/// **为什么这条最要紧**：它是本段里唯一会「按错按钮」的地方 —— 形态 A 的
/// `AXDefaultButton` 是 **「强制推出…」**，按下去＝强制卸载＝**可能丢数据**。
/// 所以兜底**只认「带标题的按钮恰好一个」**这条边界，两个方向都要钉。
@Suite("系统框该按哪个按钮")
struct SystemEjectDialogPressPlanTests {

    @Test func 有取消按钮时优先按取消() {
        // 形态 A：取消 + 强制推出…（两个带标题的按钮）
        #expect(SystemEjectDialogDismisser.pressPlan(hasCancelButton: true, titledButtonCount: 2) == .cancel)
        // 即便只有它一个，也该走「取消」而不是兜底
        #expect(SystemEjectDialogDismisser.pressPlan(hasCancelButton: true, titledButtonCount: 1) == .cancel)
    }

    /// ⚠️ **这条守的是数据安全**：形态 A 的两个按钮里，「强制推出…」是
    /// `AXDefaultButton`。取消按钮一旦读不到（形态变了 / AX 抖动），兜底若放行，
    /// 就会替用户按「强制推出」。
    @Test func 多个带标题按钮且没有取消时不动手() {
        #expect(SystemEjectDialogDismisser.pressPlan(hasCancelButton: false, titledButtonCount: 2) == .none)
        #expect(SystemEjectDialogDismisser.pressPlan(hasCancelButton: false, titledButtonCount: 3) == .none)
    }

    @Test func 只有一个带标题按钮时按它() {
        // 形态 B：只剩一个「好」
        #expect(SystemEjectDialogDismisser.pressPlan(hasCancelButton: false, titledButtonCount: 1) == .soleButton)
    }

    @Test func 一个按钮都没有时不动手() {
        // 「帮助」那种只有描述、没有标题的按钮不算数 ⇒ 清单可能是空的。
        #expect(SystemEjectDialogDismisser.pressPlan(hasCancelButton: false, titledButtonCount: 0) == .none)
    }
}

/// ``SystemEjectDialogDismisser/allowsTerminateFallback(windowCount:)`` 的判据。
///
/// **为什么值得单测**：真实场景里应用**没有**辅助功能授权是常态
/// （self-signed 应用每次重建后授权失效），兜底路径才是实际走的那条。
/// 它判错的表现是「把**别的盘**的框一起关掉」—— 一次误伤就足以让用户
/// 认定这个功能不可靠，而它的错误没有任何编译期信号。
@Suite("无授权时的关框兜底")
struct SystemEjectDialogFallbackTests {

    @Test func 只挂一个框的进程可以结束() {
        #expect(SystemEjectDialogDismisser.allowsTerminateFallback(windowCount: 1))
    }

    /// ⚠️ 要求的是**恰好一个**：0 个（框已消失）没有动手的对象，
    /// ≥2 个（同时挂着两块盘的框）分不清哪块，结束进程会误伤无关的框。
    /// 两头都必须拒绝。
    @Test func 零个或多个框都不动手() {
        #expect(!SystemEjectDialogDismisser.allowsTerminateFallback(windowCount: 0))
        #expect(!SystemEjectDialogDismisser.allowsTerminateFallback(windowCount: 2))
        #expect(!SystemEjectDialogDismisser.allowsTerminateFallback(windowCount: 5))
    }
}

/// ``ResultNotificationContent`` —— 推出结果通知的内容判据。
///
/// **为什么值得单测**：两条铁律判错了都没有编译错 ——
/// ① 失败通知的正文必须与失败弹窗**同源**（都出自
/// ``EjectFailure/reasonText(diskName:)``），各拼一份必然漂移，
/// 用户会在弹窗与通知里看到两种说法；
/// ② ``EjectOutcome/busy(occupying:)`` 必须不产生内容（发 `nil`）——
/// 忙是中间态，「关闭并推出」的落定结果会再走一次通知，中间态发一条必然重复。
@Suite("推出结果通知的内容判据")
struct ResultNotificationContentTests {

    private let disk = DiskInfo(
        id: "/Volumes/A", bsdName: "disk9s1", volumeName: "A", mountPath: "/Volumes/A",
        totalBytes: 1, usedBytes: 1, freeBytes: 0, deviceProtocol: "USB", deviceModel: nil)

    @Test func 成功通知带盘名且不带提示音() {
        let content = ResultNotificationContent.make(
            diskName: disk.displayName, outcome: .ejected)
        #expect(content != nil)
        #expect(content?.title.contains(disk.displayName) == true)
        #expect(content?.playsSound == false)
    }

    /// ⚠️ **同源判据**：失败通知正文必须**逐字等于** `reasonText` 的产出 ——
    /// 将来有人往通知里另拼一份失败说明，这条就红。
    @Test func 失败通知正文与失败弹窗同源() {
        let failures: [EjectFailure] = [
            .inUse, .notPermitted, .notFound, .other("I/O error"),
        ]
        for failure in failures {
            let content = ResultNotificationContent.make(
                diskName: disk.displayName, outcome: .failed(reason: failure))
            #expect(content != nil)
            #expect(content?.body == failure.reasonText(diskName: disk.displayName))
            #expect(content?.playsSound == true)
            #expect(content?.title.contains(disk.displayName) == true)
        }
    }

    @Test func 忙是中间态不产生内容() {
        let content = ResultNotificationContent.make(
            diskName: disk.displayName, outcome: .busy(occupying: []))
        #expect(content == nil)
    }
}

/// 提醒卡片与系统通知共用的占用者摘要。
@Suite("占用者摘要")
struct EjectAttentionSummaryTests {

    private func makeAttention(names: [String]) -> EjectAttention {
        EjectAttention(
            disk: DiskInfo(
                id: "/Volumes/A", bsdName: "disk9s1", volumeName: "A", mountPath: "/Volumes/A",
                totalBytes: 1, usedBytes: 1, freeBytes: 0, deviceProtocol: "USB",
                deviceModel: nil),
            processes: names.enumerated().map { index, name in
                OccupyingProcess(pid: Int32(index + 1), processName: name, path: "/Volumes/A/x")
            },
            notedAt: Date(timeIntervalSince1970: 0))
    }

    /// ⚠️ **分隔符是顿号**：菜单面板的提醒卡片与系统通知正文读的是**同一个**属性
    /// （``EjectAttention/processSummary``）。两处各拼一份必然漂移 —— 用户会为
    /// 同一件事看到两种说法。
    @Test func 多个占用者用顿号连接() {
        let summary = makeAttention(names: ["Final Cut Pro", "访达"]).processSummary
        #expect(summary == "Final Cut Pro、访达")
    }

    @Test func 单个占用者不带分隔符() {
        let summary = makeAttention(names: ["访达"]).processSummary
        #expect(summary == "访达")
    }

    @Test func 没有占用者是空串() {
        let summary = makeAttention(names: []).processSummary
        #expect(summary == "")
    }
}
