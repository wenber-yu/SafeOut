import AppKit
import Foundation
import SwiftUI
import Testing

@testable import SafeOutApp

// MARK: - Mock 服务

/// 拦截 eject 调用的 mock，不触发真实推出。
private final class MockEjectService: EjectService, @unchecked Sendable {
    var ejectResult: Result<Void, EjectFailure> = .success(())
    var capturedDisk: DiskInfo?
    var ejectCalled = false

    override func eject(disk: DiskInfo) async -> Result<Void, EjectFailure> {
        ejectCalled = true
        capturedDisk = disk
        return ejectResult
    }
}

/// 拦截占用检测的 mock，不跑真实 lsof。
private final class MockOccupancyDetector: OccupancyDetector, @unchecked Sendable {
    var result: OccupancyResult = .none
    var capturedMountPath: String?
    var detectCalled = false

    override func detect(mountPath: String) async -> OccupancyResult {
        detectCalled = true
        capturedMountPath = mountPath
        return result
    }
}

/// 记录型日志替身。
///
/// **为什么不直接用 `LogService.shared`**：它写的是**用户真实**的
/// `~/Library/Logs/SafeOut/error.log`。测试若走它，一是把测试造的假失败
/// 混进用户日志（用户打开日志会看到一堆没发生过的失败），二是断言要读磁盘文件、
/// 与其它用例互相干扰。注入这个替身后，断言只看内存里的数组。
private final class LogRecorder {
    struct Entry {
        let disk: String?
        let message: String
    }

    private(set) var entries: [Entry] = []

    func record(disk: String?, message: String) {
        entries.append(Entry(disk: disk, message: message))
    }
}

// MARK: - Fixtures

private func makeDisk(name: String = "测试盘") -> DiskInfo {
    DiskInfo(
        id: "/Volumes/TEST",
        bsdName: "disk4s2",
        volumeName: name,
        mountPath: "/Volumes/TEST",
        totalBytes: 1_000,
        usedBytes: 400,
        freeBytes: 600,
        deviceProtocol: "USB",
        deviceModel: nil
    )
}

// MARK: - 测试

/// 文案断言**一律不显式指定 locale**，而是用与产品代码完全相同的解析方式
/// （`L10n.tr(key)`，默认走 `Locale.current`）。
///
/// 为什么必须这样：CI 的 workflow 设了 `LC_ALL=en_US.UTF-8`，会让 `Locale.current`
/// 解析成 `en`；中文机器上则是 `zh-Hans`。若测试里写死 `locale: zhHans`，
/// 就变成「换台机器必红」的环境依赖——2026-09-12 CI 首次运行即因此红了 4 条。
/// 这些断言要钉的是「用了哪个 key、占位符填了什么」，而不是「文案恰好等于某个中文字符串」；
/// 后者既脆弱（文案随时会改），又把测试和运行环境绑死。
@MainActor
struct EjectFlowControllerTests {

    // MARK: checkOccupancy

    @Test func checkOccupancy透传检测结果与挂载路径() async {
        let mock = MockOccupancyDetector()
        let expected = [OccupyingProcess(pid: 42, processName: "IINA", path: "/Applications/IINA.app")]
        mock.result = .occupied(expected)
        let controller = EjectFlowController(occupancyDetector: mock)

        let result = await controller.checkOccupancy(mountPath: "/Volumes/TEST")

        #expect(mock.detectCalled)
        #expect(mock.capturedMountPath == "/Volumes/TEST")
        #expect(result == .occupied(expected))
    }

    /// 沙盒下检测能力缺失必须显式表现为 `.unknown`，
    /// 不能被折叠成「无占用」——否则上层会据此直接推出。
    @Test func checkOccupancy沙盒下返回unknown而非空列表() async {
        let mock = MockOccupancyDetector()
        mock.result = .unknown
        let controller = EjectFlowController(occupancyDetector: mock)

        let result = await controller.checkOccupancy(mountPath: "/Volumes/TEST")

        #expect(result == .unknown)
        #expect(result.processes.isEmpty)
        #expect(result != .none, "unknown 与 none 必须是可区分的状态")
    }

    // MARK: eject

    @Test func eject成功时返回ejected() async {
        let disk = makeDisk()
        let mock = MockEjectService()
        mock.ejectResult = .success(())
        let controller = EjectFlowController(ejectService: mock)

        let result = await controller.eject(disk: disk)

        #expect(mock.ejectCalled)
        #expect(mock.capturedDisk == disk)
        guard case .ejected = result else {
            Issue.record("期望 ejected，实际 \(result)")
            return
        }
    }

    /// 占用（fBsyErr）必须映射为 `.busy` 且携带检测到的进程，供弹窗列出「是谁」。
    @Test func eject占用时返回busy并携带进程() async {
        let disk = makeDisk()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .failure(.inUse)
        let mockDetect = MockOccupancyDetector()
        let expected = [OccupyingProcess(pid: 42, processName: "IINA", path: "/x.mp4")]
        mockDetect.result = .occupied(expected)
        let controller = EjectFlowController(ejectService: mockEject, occupancyDetector: mockDetect)

        let result = await controller.eject(disk: disk)

        guard case .busy(let occupying) = result else {
            Issue.record("期望 busy，实际 \(result)")
            return
        }
        #expect(occupying == expected)
    }

    /// 非占用类的失败（如设备已消失）仍映射为 `.failed`，不应被误判为占用。
    /// ⚠️ 显式注入 `volumeMounted: { _ in true }`：测试的挂载路径是编的、不在真实
    /// 挂载列表里，默认实现会把它判成「盘已消失 ⇒ 兜底算成功」——那正是
    /// 「报错但盘已不在时视作成功」那条独立测试的职责，不是本条的。
    /// 本条只测「盘还在时的报错 = 真失败」这条映射本身。
    @Test func eject非占用类失败映射为failed() async {
        let disk = makeDisk()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .failure(.notFound)
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .none
        let controller = EjectFlowController(
            ejectService: mockEject, occupancyDetector: mockDetect, volumeMounted: { _ in true })

        let result = await controller.eject(disk: disk)

        guard case .failed(let reason) = result else {
            Issue.record("期望 failed，实际 \(result)")
            return
        }
        #expect(reason == .notFound)
    }

    // MARK: 报错后验盘兜底（2026-09-29 用户真机实测的误报修复）

    /// **场景**：接管开关开着，Finder 重试风暴进行中，用户点提醒卡片「关闭并推出」
    /// → 我们清场（恰好帮 Finder 扫清了路）→ **Finder 的下一轮重试抢先推出** →
    /// 我们这次 `unmountAndEjectDevice` 撞上已消失的卷报 `OSStatus -36`。
    /// 盘已推出 = 用户要的结果已达成 ⇒ **必须算成功**，弹「无法推出」是误报。
    /// （真机日志铁证：`10:31:38.132 推出失败: other(OSStatus -36)` 而盘已推出。）
    @Test func eject报错但盘已不在挂载列表时视作成功() async {
        let disk = makeDisk()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .failure(.other("未能完成操作。（OSStatus 错误 -36。）"))
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .none
        let controller = EjectFlowController(
            ejectService: mockEject, occupancyDetector: mockDetect, volumeMounted: { _ in false })

        let result = await controller.eject(disk: disk)

        guard case .ejected = result else {
            Issue.record("盘已不在挂载列表，报错应兜底为成功，实际 \(result)")
            return
        }
    }

    /// 提醒卡片「关闭并推出」走的正是这条链路：清场后重试报错 + 盘已不在 ⇒ 算成功。
    /// 用不存在的 PID（kill 返回 ESRCH，被视为已退出）避免真实杀进程。
    @Test func terminateAndEject报错但盘已不在时视作成功() async {
        let disk = makeDisk()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .failure(.other("未能完成操作。（OSStatus 错误 -36。）"))
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .none
        let controller = EjectFlowController(
            ejectService: mockEject, occupancyDetector: mockDetect, volumeMounted: { _ in false })

        let processes = [OccupyingProcess(pid: 9_999_999, processName: "Ghost", path: "")]
        let result = await controller.terminateAndEject(disk: disk, processes: processes)

        guard case .ejected = result else {
            Issue.record("盘已不在挂载列表，报错应兜底为成功，实际 \(result)")
            return
        }
    }

    /// **反向守卫**：盘还在挂载列表里的报错是真失败，兜底不许吞掉它 ——
    /// 否则真故障（权限不足等）会被静默成「成功」，用户以为推出去了而盘还挂着。
    @Test func terminateAndEject报错且盘还在时仍报失败() async {
        let disk = makeDisk()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .failure(.notPermitted)
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .none
        let controller = EjectFlowController(
            ejectService: mockEject, occupancyDetector: mockDetect, volumeMounted: { _ in true })

        let processes = [OccupyingProcess(pid: 9_999_999, processName: "Ghost", path: "")]
        let result = await controller.terminateAndEject(disk: disk, processes: processes)

        guard case .failed = result else {
            Issue.record("盘还在挂载列表，报错必须如实报失败，实际 \(result)")
            return
        }
    }

    // MARK: 失败留痕（弹窗与设置面板都向用户承诺了这件事）

    /// 失败弹窗写着「已记入日志，可在『设置 › 诊断』中查看」。
    /// 这句承诺只有在 `record(_:disk:)` 真的调用日志写入时才成立 ——
    /// 之前 `LogService` 与 `EjectFailure.logText` 都已就绪却从未接上，
    /// 日志里一条推出失败都没有，而没有任何测试会红。
    @Test func 推出失败会写进用户日志() async {
        let recorder = LogRecorder()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .failure(.notPermitted)
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .none
        let controller = EjectFlowController(
            ejectService: mockEject, occupancyDetector: mockDetect, log: recorder.record,
            volumeMounted: { _ in true })

        _ = await controller.eject(disk: makeDisk())

        #expect(recorder.entries.count == 1, "一次失败应恰好写一条日志，实际 \(recorder.entries.count) 条")
        let entry = recorder.entries.first
        #expect(entry?.disk == "测试盘", "日志必须带磁盘名，否则用户分不清是哪块盘出的问题")
        #expect(
            entry?.message.contains(EjectFailure.notPermitted.logText) == true,
            "日志要带失败类型（\(EjectFailure.notPermitted.logText)），否则查日志也定位不了原因；实际 \(entry?.message ?? "无")"
        )
    }

    /// 设置面板的诊断分组承诺「记录**每次**推出失败」，而「被占用」是最常见的那种。
    /// 只记 `.failed` 会让用户报「磁盘推不出来」时在日志里查无此事。
    @Test func 推出被占用也写进日志且用应用名() async {
        let recorder = LogRecorder()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .failure(.inUse)
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .occupied([
            OccupyingProcess(pid: 42, processName: "IMVIDEO", displayName: "Bunny", path: "/x.mp4")
        ])
        let controller = EjectFlowController(
            ejectService: mockEject, occupancyDetector: mockDetect, log: recorder.record)

        _ = await controller.eject(disk: makeDisk())

        let message = recorder.entries.first?.message ?? ""
        #expect(message.contains("Bunny"), "日志要写应用显示名，实际 \(message)")
        #expect(
            !message.contains("IMVIDEO"),
            "不能写进程可执行名（IMVIDEO）—— 用户看到这个名字无法对上是哪个应用"
        )
    }

    /// 成功不该往日志里写东西，否则日志会被正常操作淹没，真出问题时翻不出来。
    @Test func 推出成功不写日志() async {
        let recorder = LogRecorder()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .success(())
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .none
        let controller = EjectFlowController(
            ejectService: mockEject, occupancyDetector: mockDetect, log: recorder.record)

        _ = await controller.eject(disk: makeDisk())

        #expect(recorder.entries.isEmpty, "成功推出不该留日志，实际写了 \(recorder.entries.count) 条")
    }

    /// 终止占用进程后推出成功，应返回 `.ejected`。
    /// 用不存在的 PID（kill 返回 ESRCH，被视为已退出）避免真实杀进程。
    @Test func terminateAndEject关闭进程后成功推出() async {
        let disk = makeDisk()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .success(())
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .none  // 复检认为已无占用
        let controller = EjectFlowController(ejectService: mockEject, occupancyDetector: mockDetect)

        let processes = [OccupyingProcess(pid: 9_999_999, processName: "Ghost", path: "")]
        let result = await controller.terminateAndEject(disk: disk, processes: processes)

        guard case .ejected = result else {
            Issue.record("期望 ejected，实际 \(result)")
            return
        }
        #expect(mockEject.ejectCalled)
    }

    // MARK: busyMessage

    @Test func busyMessage带进程时返回引导句不含进程列表() {
        let controller = EjectFlowController()
        let disk = makeDisk()
        let processes = [OccupyingProcess(pid: 42, processName: "IINA", path: "")]
        let message = controller.busyMessage(disk: disk, occupying: processes)
        // 引导句是设计稿"推出确认对话框"的固定文案（不带磁盘名——磁盘名已放在弹窗标题里）。
        let expected = L10n.tr(.ejectBusyMessageFormat)
        #expect(message == expected)
        #expect(!message.contains("PID"), "弹窗正文不应再拼 PID（进程列表改由 accessoryView 渲染图标+名称）")
    }

    @Test func busyMessage无进程时提示授权() {
        let controller = EjectFlowController()
        let disk = makeDisk()
        let message = controller.busyMessage(disk: disk, occupying: [])

        // ⚠️ 这里**不能**写 `message == String(format: L10n.tr(…), …)` ——
        // 那是拿文案和它自己比：值里删掉一个 %@，两边一起变，断言照样绿（2026-10-10 变异实测）。
        // 判据必须是**与文案无关**的东西：占位符全部替换掉 + 两个实参都真的进去了。
        #expect(!message.contains("%@"), "占位符必须全部被替换，少传一个参数就会残留字面量")
        #expect(message.contains("测试盘"), "说明句要指名是哪块盘，否则多盘时用户不知道在说哪一块")
        #expect(message.contains(L10n.tr(.appName)), "授权说明要点名应用，否则用户不知道要给谁授权")

        // 格式串**三语**都必须恰好两个占位符 —— 改了文案却忘了改这里的参数个数时，这条会先红。
        // ⚠️ 必须逐语查：2026-10-10 实际漏过繁体与英文（各只有 1 个 %@），只查运行语言会漏。
        for identifier in ["zh-Hans", "zh-Hant", "en"] {
            let format = L10n.tr(
                .ejectBusyNoProcessInfo, locale: Locale(identifier: identifier))
            #expect(
                format.components(separatedBy: "%@").count - 1 == 2,
                "\(identifier) 的格式串应恰好有 2 个 %@（磁盘名 + 应用名），实际：\(format)")
        }
    }

    // MARK: failureMessage

    /// 卷名为空时 `displayName` 回落到 bsdName，正文与标题都必须用这个回落值。
    ///
    /// **为什么用 `.notFound` 而不是 `.inUse`**：`.inUse` 的文案已按设计稿改成不带磁盘名
    /// （盘名归标题），拿它验证「回落」会得到永远成立的假绿。`.notFound` 的正文里带盘名，
    /// 才真的能验证回落。
    @Test func failureMessage卷名为空时回退到bsdName() {
        let controller = EjectFlowController()
        let disk = DiskInfo(
            id: "/Volumes/TEST", bsdName: "disk4s2", volumeName: "",
            mountPath: "/Volumes/TEST", totalBytes: 0, usedBytes: 0, freeBytes: 0,
            deviceProtocol: "USB", deviceModel: nil
        )

        let message = controller.failureMessage(disk: disk, failure: .notFound)
        let expected = String(format: L10n.tr(.ejectFailedNotFoundReason), "disk4s2")
        #expect(message == expected)
    }

    @Test func failureMessage按失败原因给出不同文案() {
        let controller = EjectFlowController()
        let disk = makeDisk()

        let busy = controller.failureMessage(disk: disk, failure: .inUse)
        let gone = controller.failureMessage(disk: disk, failure: .notFound)

        #expect(busy != gone, "不同失败原因必须给出不同引导，不能都显示同一句")
        #expect(busy == L10n.tr(.ejectFailedInUseReason))
    }

    /// 正文不再重复磁盘名：设计稿文案原则是「标题带磁盘名」，正文那一行留给「怎么解决」。
    /// 早前正文写的是「磁盘 "Samsung T7" 正被其他程序使用…」，与标题重复报同一个盘名。
    @Test func 被占用时正文不重复磁盘名() {
        let controller = EjectFlowController()
        let message = controller.failureMessage(disk: makeDisk(name: "Samsung T7"), failure: .inUse)
        #expect(!message.contains("Samsung T7"), "盘名只该出现在标题里，实际正文：\(message)")
    }

    // MARK: EjectFailure.possibleCauses（设计稿 03-eject-flow.html B 变体）

    /// 设计稿给「被占用」这一类列了两条原因，其中一条专门讲 Spotlight 索引 ——
    /// 这是最容易被误判为「程序卡住」的情形（用户会反复点重试），必须出现在清单里。
    @Test func 被占用时给出可执行的原因清单() {
        let causes = EjectFailure.inUse.possibleCauses
        #expect(causes.count == 2)
        #expect(causes.contains { $0.contains("Spotlight") }, "缺少「Spotlight 正在建立索引」这条")
        #expect(causes.allSatisfy { !$0.isEmpty })
    }

    /// 「系统不允许」是最让人困惑的一类失败（用户会反复重试），也要给清单。
    @Test func 系统不允许时也给出原因清单() {
        #expect(EjectFailure.notPermitted.possibleCauses.count == 2)
    }

    /// 原因句本身已经把话说完了的分类不再凑一屏清单 —— 空数组表示 UI 只显示原因句与日志提示。
    @Test func 原因已明确的分类不再给清单() {
        #expect(EjectFailure.notFound.possibleCauses.isEmpty)
        #expect(EjectFailure.other("boom").possibleCauses.isEmpty)
    }

    /// 清单走本地化表，缺一档就会中英混排。
    @Test func 原因清单三语都不为空() {
        let keys: [L10n.Key] = [
            .ejectFailedCausesTitle, .ejectFailedCauseFileOpen, .ejectFailedCauseSpotlight,
            .ejectFailedCauseNotRemovable, .ejectFailedCauseSystemHold,
            .ejectFailedTitleFormat, .ejectBusyOccupiedHeaderFormat, .ejectBusyIrreversibleCaption,
        ]
        for identifier in ["zh-Hans", "zh-Hant", "en"] {
            let locale = Locale(identifier: identifier)
            for key in keys {
                #expect(!L10n.tr(key, locale: locale).isEmpty, "\(key.rawValue) 缺 \(identifier)")
            }
        }
    }

    // MARK: 弹窗内容契约（设计稿 03-eject-flow.html）
    //
    // 弹窗是自绘的，文案没法像 `NSAlert.messageText` 那样直接读。所以断言打在
    // ``EjectAlertModel`` 上 —— 它是纯数据，不渲染、不驱动窗口，照样能把
    // 「标题带不带盘名」「清单有没有」「按钮是哪个」这些契约钉死。

    /// 标题必须带磁盘名：多块盘时用户要能确认操作对象没选错（设计稿文案原则）。
    @MainActor
    @Test func 失败弹窗标题带磁盘名() {
        let model = EjectAlertModel.failure(disk: makeDisk(name: "Samsung T7"), failure: .inUse)
        #expect(
            model.title.contains("Samsung T7"),
            "标题必须出现磁盘名，实际：\(model.title)")
    }

    /// 按钮是「查看日志」+「好」，且「好」是默认按钮 —— 否则回车会直接打开访达打断用户。
    @MainActor
    @Test func 失败弹窗按钮是查看日志加好() {
        let model = EjectAlertModel.failure(disk: makeDisk(), failure: .inUse)
        #expect(model.actions.map(\.title) == [L10n.tr(.viewLog), L10n.tr(.okAcknowledge)])
        #expect(model.actions.map(\.choice) == [.viewLog, .dismiss])
        #expect(model.actions.first(where: \.isDefault)?.choice == .dismiss, "默认按钮应是「好」")
        #expect(!model.actions.contains { $0.isCancel }, "失败弹窗没有取消路径")
    }

    /// 「可能的原因」必须成区块出现在正文与提示块**之间** —— 这是设计稿的信息层级。
    @MainActor
    @Test func 失败弹窗有原因清单区块与日志提示块() {
        let model = EjectAlertModel.failure(disk: makeDisk(), failure: .inUse)
        guard case .causes(let label, let items) = model.section else {
            Issue.record("期望原因清单区块，实际：\(String(describing: model.section))")
            return
        }
        #expect(label == L10n.tr(.ejectFailedCausesTitle))
        #expect(items.count == 2)
        #expect(model.callout?.kind == .info, "日志提示是信息块，不是警示块")
        #expect(model.callout?.text == L10n.tr(.ejectFailedLoggedHint))
    }

    /// 没有清单可给的分类不硬凑空标题，但仍要保留日志提示块（失败必须留痕）。
    @MainActor
    @Test func 无清单的分类只显示日志提示() {
        let model = EjectAlertModel.failure(disk: makeDisk(), failure: .notFound)
        #expect(model.section == nil)
        #expect(model.callout?.text == L10n.tr(.ejectFailedLoggedHint))
    }

    /// 占用弹窗：破坏性按钮标红、默认按钮是「关闭并推出」、「取消」是逃生口，
    /// 操作区左侧带「此操作不可撤销」小标。
    @MainActor
    @Test func 占用弹窗按钮与不可撤销小标() {
        let model = EjectAlertModel.busy(
            disk: makeDisk(),
            occupying: [
                OccupyingProcess(pid: 1234, processName: "IINA", path: "")
            ])
        #expect(model.actions.map(\.variant) == [.outline, .danger], "破坏性按钮必须标红")
        #expect(model.actions.map(\.choice) == [.cancel, .closeAndEject])
        #expect(model.actions.first(where: \.isDefault)?.choice == .closeAndEject, "回车即确认")
        #expect(model.actions.first(where: \.isCancel)?.choice == .cancel, "Esc 是逃生口")
        #expect(model.footNote == L10n.tr(.ejectBusyIrreversibleCaption))
    }

    /// 进程行必须同时给出应用名与 PID，且条数写进分组头。
    @MainActor
    @Test func 占用弹窗进程区块含应用名与PID() {
        let processes = [
            OccupyingProcess(pid: 1234, processName: "IINA", displayName: "IINA", path: ""),
            OccupyingProcess(pid: 5678, processName: "tail", displayName: "tail", path: ""),
        ]
        let model = EjectAlertModel.busy(disk: makeDisk(), occupying: processes)
        guard case .processes(let label, let items) = model.section else {
            Issue.record("期望进程区块，实际：\(String(describing: model.section))")
            return
        }
        #expect(label == String(format: L10n.tr(.ejectBusyOccupiedHeaderFormat), 2))
        #expect(items.map(\.displayName) == ["IINA", "tail"])
        #expect(items.map(\.pid) == [1234, 5678])
    }

    /// 无法列出进程时（未授予完全磁盘访问）不给空区块，说明句本身已带授权引导。
    @MainActor
    @Test func 无法列出进程时不给空区块() {
        let model = EjectAlertModel.busy(disk: makeDisk(), occupying: [])
        #expect(model.section == nil)

        // 与语言无关的两条：占位符已替换、带上了磁盘名。
        #expect(!model.subtitle.contains("%@"), "格式化占位符必须已被替换")
        #expect(model.subtitle.contains("测试盘"), "说明句要指名是哪块盘，否则多盘时用户不知道在说哪一块")

        // 「说明句自带授权引导」是**中文设计稿的文案契约**，所以显式在中文下解析再核对。
        // 不能直接写 `model.subtitle.contains("完全磁盘访问")` —— 那样结论会随运行机器的
        // 系统语言变（英文版文案里没有这几个字），于是本地绿、CI 红。见 `TestLanguage`。
        //
        // ⚠️ 也**不能**拿 `model.subtitle == String(format: 同一份文案, …)` ——
        // 那是拿文案和它自己比，改了值两边一起变、断言永真（2026-10-10 变异实测）。
        // 这里断言的是**格式串本身**含该路径，与最终渲染结果无关。
        let designFormat = L10n.tr(
            .ejectBusyNoProcessInfo, locale: Locale(identifier: TestLanguage.design))
        #expect(
            designFormat.contains("完全磁盘访问"),
            "说明句必须指明去「完全磁盘访问」授权，否则用户不知道该给什么权限")
        #expect(
            model.subtitle.contains(L10n.tr(.appName)),
            "说明句要点名应用，否则用户不知道要给谁授权")
    }

    /// 警示必须写清动作序列（设计稿文案原则），且与 ``EjectFlowController/terminateAndEject``
    /// 的真实三步一致：SIGTERM → 等 1.5s → SIGKILL → 普通重试。
    /// 改实现忘改文案，或反过来，都会让这句承诺变成假话。
    @MainActor
    @Test func 占用弹窗警示写清动作序列() {
        let text = EjectUI.busyWarningText
        // 与语言无关的两条：品牌名走本地化键、占位符已替换。
        #expect(text.contains(L10n.tr(.appName)), "品牌名应走本地化，而不是硬编码 SafeOut")
        #expect(!text.contains("%@"), "格式化占位符必须已被替换")

        // 三步动作序列是**中文设计稿的文案契约**，显式在中文下核对（见 `TestLanguage`）。
        // ⚠️ 只认动作本身，不认整句（2026-10-10：文案去掉「重新尝试」的冗余后变「重试推出」，
        // 守卫随之放宽到「重试 + 推出」两个词 —— 契约是"说清第三步"，不是"逐字复述"）。
        let design = L10n.tr(.ejectBusyWarning, locale: Locale(identifier: TestLanguage.design))
        #expect(design.contains("正常退出"), "缺少第一步「先请求正常退出」")
        #expect(design.contains("强制结束"), "缺少第二步「强制结束」")
        #expect(
            design.contains("重试") && design.contains("推出"),
            "缺少第三步「重试推出」")
    }

    // MARK: 弹窗版式契约

    /// 版式（宽 / 逐块高 / 行高 / 图标列）的契约集中在 `AlertLayoutTests`。
    ///
    /// **为什么搬走**：原先这里只有一条「总高 ±12pt」的断言。它看着很稳，实际**掩盖了两处
    /// 十几 pt 的偏差** —— 一是基准值本身取自「设计稿图标还没水合」时的量测（312 而非 330），
    /// 二是 ±12 的容差刚好兜住了 B 变体少掉的 11pt。逐块断言才拦得住这类偏差。

    // MARK: 弹窗窗口（自绘弹窗最容易漏的两步）

    /// 无边框窗口默认**不能**成为 key window，于是回车 / Esc / 按钮点击会全部失效 ——
    /// 这是自绘弹窗最容易漏的一步。同时 `canBecomeMain` 必须保持 false：
    /// 弹窗不该被当成主窗口（会顶掉主窗口的标题栏与菜单行为）。
    @MainActor
    @Test func 弹窗窗口能成为key但不是主窗口() {
        let panel = EjectAlertPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        #expect(panel.canBecomeKey, "不能成为 key → 回车/Esc/点击全都失效")
        #expect(!panel.canBecomeMain)
    }

    /// 窗口配置逐条钉住：这些都是「删掉也不会让任何断言变红、但界面会静默坏掉」的设置。
    ///
    /// **不真的把窗口显示出来**：那会弹窗抢走用户焦点，`swift test` 不该有这个副作用。
    /// 真正的上屏验证走 `SafeOutApp --preview-alerts`（会打印 key / 上屏 / 尺寸 / 圆角）。
    @MainActor
    @Test func 弹窗窗口的透明圆角配置() {
        let model = EjectAlertModel.failure(disk: makeDisk(), failure: .inUse)
        let hosting = NSHostingController(rootView: EjectAlertView(model: model, onAction: { _ in }))
        let panel = EjectAlertPresenter.shared.makePanel(hosting: hosting, height: 314, title: model.title)

        #expect(panel.styleMask.contains(.borderless), "自绘弹窗不能带系统标题栏")
        #expect(!panel.isOpaque, "不透明窗口会把圆角外的区域填成白色")
        #expect(panel.backgroundColor == .clear, "窗口底色必须清掉，否则圆角外露出白底")
        #expect(panel.hasShadow, "弹窗要有投影才有浮层感（设计稿 e3）")
        #expect(panel.contentView?.layer?.cornerRadius == DesignTokens.Radius.lg, "窗口圆角 14")
        #expect(panel.contentView?.layer?.masksToBounds == true, "不遮罩则阴影按矩形算")
        #expect(panel.title == model.title, "无边框窗口没有标题栏，VoiceOver 只能从这里拿标题")
        #expect(panel.frame.width == DesignTokens.Size.alertWidth)
        // **`NSPanel` 的默认值与 `NSWindow` 不同**：`hidesOnDeactivate` 默认是 `true`，
        // 于是「应用一失去焦点，弹窗就被系统从屏幕上摘掉」—— 用户 2026-09-16 报告
        // 「点别处弹窗就被遮挡了」，根因就是它。这条断言是那个坑的唯一守卫。
        #expect(!panel.hidesOnDeactivate, "失焦隐藏 → 用户点一下别的窗口，弹窗就从屏幕上消失了")
        // 切 Space / 别的应用进全屏时，弹窗也得跟着用户走（同一诉求的另一半）。
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces), "切 Space 后弹窗会留在原地")
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary), "别的应用全屏时弹窗会被压在下面")
    }

    /// Esc 的兜底出口：`cancelOperation(_:)` 是 AppKit 在 Esc 时的标准入口，
    /// 挂在这里可以保证「无论焦点在哪，Esc 都能退出」。
    @MainActor
    @Test func 弹窗Esc走cancelOperation出口() {
        let panel = EjectAlertPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        var cancelled = false
        panel.onCancel = { cancelled = true }
        panel.cancelOperation(nil)
        #expect(cancelled)
    }

    /// 每个弹窗必须**恰好**有一个默认按钮（回车）—— 两个默认按钮会让回车行为不确定。
    @MainActor
    @Test func 每个弹窗恰好一个默认按钮() {
        let busy = EjectAlertModel.busy(disk: makeDisk(), occupying: [])
        let failure = EjectAlertModel.failure(disk: makeDisk(), failure: .inUse)
        for model in [busy, failure] {
            #expect(model.actions.filter(\.isDefault).count == 1, "\(model.title)")
        }
    }

    // MARK: - 「此刻有没有卷正在推出」（§8.146）

    /// 推出进行中计数为 1，结束后归零。
    ///
    /// **为什么这个信号必须是「派生」的**：更新那条路拿它决定「能不能现在自动重启」
    /// （``UpdateController/readyHandling(userChoseInstallAndRestart:activeEjections:)``）。
    /// 它若是个「用户点过按钮没有」的布尔开关，就会与真实情况脱节 ——
    /// 点了按钮但操作早已结束、或操作由别的入口发起，都会答错。
    @MainActor
    @Test func 推出进行中计数为一结束后归零() async {
        let service = BlockingEjectService()
        let controller = EjectFlowController(
            ejectService: service, occupancyDetector: MockOccupancyDetector())
        var entered = service.entered.makeAsyncIterator()

        let task = Task { await controller.eject(disk: makeDisk()) }
        // 等它**真的进了** `eject`（而不是「已经跑完了」）—— 那时计数必然已经 +1。
        _ = await entered.next()
        #expect(
            controller.activeEjectionCount == 1,
            """
            推出进行中计数是 \(controller.activeEjectionCount)，不是 1 ——
            更新那条路会据此认为「没有卷在推出」，于是一次自动重启会把
            正在跑的 `unmountAndEjectDevice` 腰斩（§8.146）
            """)

        _ = await task.value
        #expect(
            controller.activeEjectionCount == 0,
            """
            推出结束后计数没归零（\(controller.activeEjectionCount)）——
            计数只增不减会让自动重启**永远**被推迟，而弹窗已经承诺过会自动重启
            """)
    }

    /// `waitUntilIdle()` 在计数归零时**被唤醒**（而不是永远挂着）。
    ///
    /// ⚠️ **这是「推迟自动重启」那条路的唯一出口**：`driverIsReady` 遇到「有卷在推出」
    /// 会推迟，然后 `await waitUntilIdle()`。若这里不唤醒，界面就停在一个
    /// **永远不自动重启**的 `.ready` 上 —— 而弹窗已经向用户承诺过会自动重启。
    ///
    /// ⚠️ **为什么用「有界轮询」而不是 `withTaskGroup` 竞速**：挂住的那个等待是
    /// `withCheckedContinuation`，**不响应取消** —— 竞速的输家会一直挂着，
    /// 而 `withTaskGroup` 退出时要等所有子任务 ⇒ **整个测试挂死**（比红更难查）。
    /// 这里改成「等一个由 waiter 自己置位的标志，超时上限 3s」，最坏情况是**红**，不是挂。
    ///
    /// ⚠️ **同理，这里绝不能 `await waiter.value`**：waitUntilIdle 的唤醒一旦被改坏
    /// （变异 M3e 删掉 `endEjection` 里唤醒等待者那三行），waiter 就**永远不返回**，
    /// 整个测试进程挂死 —— 挂死既不会让门槛变红、又会拖垮 CI。所以只轮询标志位，
    /// 那个挂着的 waiter 由测试进程退出时一并终止（测试里唯一一处刻意留下的悬挂任务）。
    @MainActor
    @Test func 等推出结束会等到计数归零才返回() async {
        let service = BlockingEjectService()
        let controller = EjectFlowController(
            ejectService: service, occupancyDetector: MockOccupancyDetector())
        var entered = service.entered.makeAsyncIterator()

        let task = Task { await controller.eject(disk: makeDisk()) }
        _ = await entered.next()

        let flag = WaitFlag()
        let waiter = Task { @MainActor in
            await controller.waitUntilIdle()
            flag.done = true
        }
        _ = await task.value  // 推出结束 ⇒ 计数归零 ⇒ 应该唤醒 waiter

        for _ in 0..<150 where !flag.done {
            try? await Task.sleep(nanoseconds: 20_000_000)  // 上限 3s
        }
        // 只用来表达「这个任务还存在」，不 await 它（见上面的 ⚠️）。
        withExtendedLifetime(waiter) {}
        #expect(
            flag.done,
            """
            推出结束之后 `waitUntilIdle()` 没被唤醒 —— 那条「推迟自动重启」的路
            会永远停在那里，用户等不到承诺过的自动重启（§8.146）
            """)
    }

    /// 没有推出在进行时 `waitUntilIdle()` **立即返回**（不挂）。
    @MainActor
    @Test func 没有推出时等待立即返回() async {
        let controller = EjectFlowController(
            ejectService: MockEjectService(), occupancyDetector: MockOccupancyDetector())
        await controller.waitUntilIdle()
        #expect(controller.activeEjectionCount == 0)
    }

    // MARK: - Bug 3：占用弹窗不许等系统那十几秒（§8.146）

    /// 只有「非空的占用缓存」才配得上提前弹窗。
    ///
    /// 真机日志坐实：`unmountAndEjectDevice` 在卷真被占用时要 **12.5 秒**才返回 `fBsyErr`
    /// （`22:53:30.884 请求推出卷` → `22:53:43.377 推出失败: inUse(fBsyErr)`），
    /// 而弹窗原先必须等它返回。窗口里显示得快，是因为 ``OccupancyStore`` 每 15s
    /// 后台跑 `lsof` 并把结论缓存在 `results` 里。
    ///
    /// ⚠️ **反例与正例同样重要**：`.occupied([])` 与 `.unknown` 若被判成「该提前弹」，
    /// 前者会弹一个**没有进程列表**的占用窗，后者把「还没测出来」渲染成「被占用」——
    /// 那是本应用最不能犯的错误（见 ``OccupancyStore/result(for:)`` 的兜底说明）。
    @Test func 只有非空的占用缓存才配得上提前弹窗() {
        let processes = [
            OccupyingProcess(pid: 42, processName: "IINA", path: "/Applications/IINA.app")
        ]
        #expect(
            EjectUI.preemptivelyOccupied(.occupied(processes)) == processes,
            "缓存已判定「被占用」却不提前弹 —— 用户又要盯着界面等系统那十几秒（§8.146）")
        #expect(
            EjectUI.preemptivelyOccupied(.occupied([])) == nil,
            """
            `occupied([])`（系统说忙、但本应用列不出进程）被当成「该提前弹」了 ——
            那会弹一个没有进程列表的占用窗，用户只能看到「无法列出具体程序」，
            而系统那条权威结论本来可能几秒后就到了
            """)
        #expect(
            EjectUI.preemptivelyOccupied(.none) == nil,
            "`.none`（已确认没有占用）被当成该提前弹 —— 会给一块没被占用的盘弹占用窗")
        #expect(
            EjectUI.preemptivelyOccupied(.unknown) == nil,
            """
            `.unknown`（还没测出来）被当成该提前弹 —— 把「不知道」渲染成「被占用」
            是本应用最不能犯的错误（同 `OccupancyStore.result(for:)` 的兜底判据）
            """)
        // ⚠️ **这一格是 2026-09-25 补的**（QA 探针 Q11 实测：漏了它，全量测试仍绿）：
        // 上面四条覆盖了 `.none` / `.unknown` / `.occupied([])`，**唯独漏了它** ——
        // 而它与 `.unknown` 是**不同**的一格：`.unknown` 是环境硬限制（沙盒），
        // `.needsFullDiskAccess` 是用户可补救的权限缺口（见 `OccupancyResult` 的说明）。
        // 两格的正确处理是一样的（**不弹**），但判据必须各写一条：把 `.needsFullDiskAccess`
        // 当成「有占用」会给一块**根本没被占用**的盘弹占用窗，而它列不出任何进程。
        #expect(
            EjectUI.preemptivelyOccupied(.needsFullDiskAccess) == nil,
            """
            `.needsFullDiskAccess`（lsof 拿不到别的进程，是权限缺口不是占用）被当成该提前弹了 ——
            那会弹一个**列不出任何进程**的占用窗，用户照着它点「关闭并推出」只会白杀进程（§8.146.7）
            """)
    }

    /// 预弹窗的 `present` **一返回**就必须落闸 —— **按 Esc 也一样**。
    ///
    /// ## 为什么这条必须钉住（2026-09-25，§8.146.6）
    ///
    /// 「闸门落了」= 这个预弹窗不再等用户。watcher 靠它决定「系统那次推出成功时
    /// 要不要去收窗」—— 而 **Esc 不会取消系统那次推出**，它只是「不做激进动作」。
    /// 若落闸被写成「点了『关闭并推出』才算」（原来那一行在 `guard` **之后**，就是这个效果），
    /// 按 Esc 之后闸门永远不落 ⇒ 那次推出成功时 watcher 会 `respond(.cancel)`，
    /// **收掉用户之后才打开的那个弹窗** ⇒ 用户按了按钮却**什么都没发生**。
    ///
    /// ⚠️ **对每一个 choice 都断言**（不是只测 `.cancel`）：落闸的判据是
    /// 「`present` 返回了」，与 choice **无关** —— 只测一支会漏掉「按 choice 分档」的写法。
    @MainActor
    @Test func 预弹窗一返回就落闸_按Esc也一样() async {
        let choices: [EjectAlertChoice] = [.cancel, .closeAndEject, .dismiss, .viewLog]
        for choice in choices {
            let gate = EjectUI.PreemptiveAlertGate()
            let returned = await EjectUI.awaitPreemptiveChoice(gate: gate) { choice }
            #expect(
                returned == choice,
                "`awaitPreemptiveChoice` 把用户的选择改了：进 \(choice)、出 \(returned)")
            #expect(
                gate.isSettled,
                """
                \(choice) 之后闸门没落 —— 这个预弹窗已经不在等用户了，watcher 却会以为它还在等：
                那次后台推出一旦成功就会 `respond(.cancel)`，收掉的是**之后才打开的那个弹窗**（§8.146.6）
                """)
        }
    }

    /// 「收窗」的判据：**这个预弹窗还在等用户**（闸门未落）**且**「结果已经让它那句
    /// 『被占用』站不住」时才收。
    ///
    /// 这是 §8.146.6 那条漏判的另一半 —— 闸门落了之后 watcher 必须**什么都不做**。
    /// 反例（闸门已落 + 成功）就是「按 Esc ⇒ 收掉后续弹窗」那条路径本身。
    ///
    /// ⚠️ **「站不住」那一侧是 2026-09-25 复核**（§8.146.7）**改判过的**：
    /// `.failed(.notFound)`（盘已经不在了）**也收** —— 一个关于不存在的磁盘的弹窗没有可问的事；
    /// `.busy` 与其它失败（`.notPermitted` / `.other`）**留窗**（`.busy` 时那句话是对的；
    /// 其它失败让用户点「关闭并推出」时由重试撞到真相，见 §8.146.7 判断②）。
    @MainActor
    @Test func 闸门落了之后系统成功也不许去收窗() {
        let processes = [
            OccupyingProcess(pid: 42, processName: "IINA", path: "/Applications/IINA.app")
        ]
        // 该收的两格 / 该留的四格 —— 分成两组写，`expected` 就不必再写一遍判据
        // （写第二遍判据 = 拿实现跟自己比，改了实现两边一起变、断言照样绿）。
        let shouldCollect: [EjectOutcome] = [.ejected, .failed(reason: .notFound)]
        let shouldKeep: [EjectOutcome] = [
            .busy(occupying: processes),
            .failed(reason: .notPermitted),
            .failed(reason: .other("磁盘映像忙")),
        ]

        // 判据的**全矩阵**：闸门（未落 / 已落）× 六种结果。
        var expectations: [Bool] = []
        for settled in [false, true] {
            for outcome in shouldCollect + shouldKeep {
                let gate = EjectUI.PreemptiveAlertGate()
                if settled { gate.settle() }
                let expected = !settled && shouldCollect.contains(outcome)
                expectations.append(expected)
                let actual = EjectUI.shouldDismissPreemptivePopup(gate: gate, outcome: outcome)
                #expect(
                    actual == expected,
                    """
                    闸门\(settled ? "已落" : "未落") + \(outcome)：该收=\(expected)、实际=\(actual)。
                    闸门已落 ⇒ 这个预弹窗早就不在等用户了，再收一次收掉的是**之后才打开的那个弹窗**
                    （用户按了按钮却什么都没发生）；闸门未落但结果没让窗上那句话站不住 ⇒
                    用户可能正看着这个窗，收掉它等于把「他还需要的那条线索」拿掉（§8.146.6 / §8.146.7）
                    """)
            }
        }
        // **自证**：矩阵里必须既有「该收」也有「该留」，否则上面那些断言全在验同一边，
        // 「这个函数永远返回 false / 永远返回 true」都能绿。
        #expect(
            expectations.contains(true) && expectations.contains(false),
            "矩阵里「该收 / 该留」有一边是空的 —— 断言测不出「永远收」或「永远不收」")
    }

    /// **真正把那条路径跑一遍**：用户按 Esc（`.cancel`）之后，那次在跑的推出返回 `.ejected`
    /// ⇒ **不许**收窗、**也不许**刷新列表。
    ///
    /// 另外三格也在同一条测试里（`2026-09-25` 复核后补）：`.failed(.notFound)`（盘已不在）
    /// **该收**、同一格在闸门已落时**不许收**（新支不许绕过闸门）、`.failed(.notPermitted)`
    /// **留窗**（§8.146.7 判断②）。
    ///
    /// ## 为什么还要这一条（2026-09-25，§8.146.6）
    ///
    /// 上一条测的是**判据本身**；这一条测的是**判据 + 两个动作的接线** ——
    /// 把 `guard` 写反、或把 `dismiss()` 提到 `guard` 之前，都会在这里红。
    /// 它跑的是 `eject` 里那个 watcher 的**同一段代码**（``EjectUI/dismissPreemptivePopupIfNeeded``），
    /// 不是另写一份判据。
    ///
    /// ⚠️ **阳性对照必须在同一条测试里**（闸门未落 + 成功 ⇒ 收窗与刷新各跑一次）：
    /// 少了它，「这个函数永远直接 `return`」也能让反例那一半绿。
    @MainActor
    @Test func 按Esc之后那次推出成功不许去收窗也不许刷新() async {
        // —— 反例：用户按 Esc（闸门已落），那次推出成功了 ——
        let settled = EjectUI.PreemptiveAlertGate()
        settled.settle()
        var dismissCalls = 0
        var refreshCalls = 0
        await EjectUI.dismissPreemptivePopupIfNeeded(
            gate: settled,
            outcome: .ejected,
            dismiss: { dismissCalls += 1 },
            refresh: { refreshCalls += 1 })
        #expect(
            dismissCalls == 0,
            """
            按 Esc 之后那次推出成功了，却还是调了「收窗」—— `EjectAlertPresenter.respond(.cancel)`
            收的是**当前屏上那个弹窗**，而它已经不是这个预弹窗了：用户之后点开的那块盘的弹窗会被收掉，
            那块盘的推出于是拿到 `.cancel` 直接返回、**一个进程都没碰**（§8.146.6）
            """)
        #expect(
            refreshCalls == 0,
            """
            闸门落了之后连 `refresh()` 也跑了 —— 这条链现在的判据是「收窗与刷新同生同死」：
            按 Esc 之后列表由 `NSWorkspace.didUnmountNotification` 那条链刷新
            （守卫见 `卸载通知必须能自己刷新列表`，§8.146.6）
            """)

        // —— 阳性对照：闸门未落（用户还没表态），那次推出成功了 ——
        let open = EjectUI.PreemptiveAlertGate()
        await EjectUI.dismissPreemptivePopupIfNeeded(
            gate: open,
            outcome: .ejected,
            dismiss: { dismissCalls += 1 },
            refresh: { refreshCalls += 1 })
        #expect(
            dismissCalls == 1 && refreshCalls == 1,
            """
            系统那次推出成功了、用户还没表态，却没把那个谎报「被占用」的弹窗收掉并刷新
            （收窗 \(dismissCalls) 次、刷新 \(refreshCalls) 次）——
            盘已经推出去了，用户还看着一个说它被占用的窗
            """)

        // —— 阳性对照 ②：**盘已经不在了**（`.failed(.notFound)`）⇒ 同样要收窗 + 刷新 ——
        // （2026-09-25 复核改判加上的那一支，§8.146.7：关于一块不存在的磁盘的弹窗没有可问的事）
        await EjectUI.dismissPreemptivePopupIfNeeded(
            gate: EjectUI.PreemptiveAlertGate(),
            outcome: .failed(reason: .notFound),
            dismiss: { dismissCalls += 1 },
            refresh: { refreshCalls += 1 })
        #expect(
            dismissCalls == 2 && refreshCalls == 2,
            """
            设备已不在（`.failed(.notFound)`）时没把预弹窗收掉（收窗 \(dismissCalls) 次、刷新 \(refreshCalls) 次）——
            用户面对一个关于一块**已经不在**的磁盘的弹窗，而列表里那块盘早就不见了（§8.146.7）
            """)

        // —— 反例 ②：闸门已落 + `.notFound` ⇒ 仍然**不许**动（闸门判据优先）——
        let settledGone = EjectUI.PreemptiveAlertGate()
        settledGone.settle()
        await EjectUI.dismissPreemptivePopupIfNeeded(
            gate: settledGone,
            outcome: .failed(reason: .notFound),
            dismiss: { dismissCalls += 1 },
            refresh: { refreshCalls += 1 })
        #expect(
            dismissCalls == 2 && refreshCalls == 2,
            """
            新加的那一支（`.notFound`）**绕过了闸门** —— 用户按 Esc 之后设备又恰好不在时，
            它会去收掉**之后才打开的那个弹窗**（§8.146.6 那条漏判换了个入口复发）
            """)

        // —— 反例 ③：其它失败（`.notPermitted`）**留窗**（§8.146.7 判断②）——
        var keptCalls = 0
        await EjectUI.dismissPreemptivePopupIfNeeded(
            gate: EjectUI.PreemptiveAlertGate(),
            outcome: .failed(reason: .notPermitted),
            dismiss: { keptCalls += 1 },
            refresh: { keptCalls += 1 })
        #expect(
            keptCalls == 0,
            """
            `.notPermitted` 也去收窗了 —— 本轮的判断是**留窗**：让用户点「关闭并推出」时
            由重试撞到真相（§8.146.7 判断②）。收掉它等于把用户正看着的那条线索拿掉
            """)
    }

    /// **接线守卫**：`EjectUI.eject` 的五条关键接线。
    ///
    /// ⚠️ 为什么行为测试之外还要这条：`EjectUI.eject` 的端到端行为要**真弹窗**
    /// （`EjectAlertPresenter.present` 会 `makeKeyAndOrderFront`），
    /// 测试进程里不能跑 ⇒ 只能钉接线。五条各自防一个不同的回归：
    /// ① 系统推出**照常发起**（不许因为「缓存说占用」就跳过系统调用）；
    /// ② 结果让窗上那句话站不住时**收窗**（成功 / 设备已不在，不许留一个谎报「被占用」的弹窗）；
    /// ③ 用户点「关闭并推出」时把那次还在跑的推出**传下去**（不许并发调 `unmountAndEjectDevice`）；
    /// ④ 落闸那一句**必须走** `awaitPreemptiveChoice` —— 就地写回 `eject` 里（尤其写回
    ///    `guard` 之后）会让 §8.146.6 那条漏判复活，而上面那条纯函数守卫**看不见**
    ///    `eject` 本体的顺序；
    /// ⑤ 收窗那一句**必须走** `dismissPreemptivePopupIfNeeded`（同理：判据就地写反、
    ///    漏掉 `!gate.isSettled`，不会有任何编译错）。
    @Test func 提前弹窗的五条接线() throws {
        let source = try String(
            contentsOf: repoRootForEjectTests.appendingPathComponent("Sources/Services/EjectUI.swift"),
            encoding: .utf8)
        #expect(
            source.contains("await EjectFlowController.shared.eject(disk: disk)"),
            """
            `EjectUI.eject` 里没有发起系统推出 —— 缓存结论**只决定何时弹窗**，
            「能不能推出」仍必须由系统的 `fBsyErr` 说了算（§8.146）
            """)
        #expect(
            source.contains("EjectAlertPresenter.shared.respond(.cancel)"),
            """
            系统推出**成功**时没有收掉预弹的占用窗 —— 用户会看到一个
            谎报「被占用」的弹窗（而盘其实已经推出去了）
            """)
        #expect(
            source.contains("awaiting: inFlight"),
            """
            用户点「关闭并推出」时没把那次还在跑的推出传下去 ——
            两次 `unmountAndEjectDevice` 并发对同一卷行为未定义，
            第二次会因「设备已不在」报 notFound，把一次成功写成失败
            """)
        #expect(
            source.contains("await Self.awaitPreemptiveChoice(gate: gate)"),
            """
            落闸那一句没有走 `awaitPreemptiveChoice` —— 就地写回 `eject` 里
            （尤其在 `guard choice == .closeAndEject` **之后**）会让 §8.146.6 那条漏判复活：
            按 Esc 时闸门永不落，之后那次推出成功会收掉别的弹窗
            """)
        #expect(
            source.contains("await Self.dismissPreemptivePopupIfNeeded("),
            """
            收窗那一句没有走 `dismissPreemptivePopupIfNeeded` —— 就地写回 `eject` 里、
            判据写反（漏掉 `!gate.isSettled`）不会有任何编译错，
            而它会去收掉之后才打开的那个弹窗（§8.146.6）
            """)
    }

    /// **接线守卫（Q10）**：缓存**没**说被占用那条**主干**（绝大多数盘走它）必须把系统结果
    /// 交给 `handle` —— 去掉它，失败与占用就**再也不弹窗**了。
    ///
    /// ⚠️ **为什么单开一条**（2026-09-25，§8.146.7）：`提前弹窗的五条接线` 里那句
    /// `source.contains("await EjectFlowController.shared.eject(disk: disk)")` 命中的是
    /// **抢占分支**里那一次调用，主干这条 `handle` 接线**无人守** —— QA 探针 Q10 实测：
    /// 把主干改成 `_ = await …eject(…)`，全量测试**仍绿**。
    /// 那条路的症状很重：盘推不出去、用户**既看不到占用窗也看不到失败窗**。
    @Test func 缓存没占用那条主干必须把结果交给handle() throws {
        let source = try String(
            contentsOf: repoRootForEjectTests.appendingPathComponent("Sources/Services/EjectUI.swift"),
            encoding: .utf8)
        let mainPath = "await handle(await EjectFlowController.shared.eject(disk: disk), disk: disk)"
        let preemptiveAnchor = "let inFlight = Task {"

        guard let callRange = source.range(of: mainPath) else {
            Issue.record(
                """
                `EjectUI.eject` 的**主干**（缓存没说被占用）没有把系统结果交给 `handle` ——
                那条路上失败与占用**再也不会弹窗**：用户点了「推出」，盘没动，
                而屏幕上没有任何提示（§8.146.7）
                """)
            return
        }
        // 锚点自证：确认那句调用在**抢占分支之前**（主干），不是别处一句巧合的同名调用。
        guard let anchorRange = source.range(of: preemptiveAnchor) else {
            Issue.record("找不到抢占分支的起点 `\(preemptiveAnchor)` —— 解析锚点坏了，上面那条结论作废")
            return
        }
        #expect(
            callRange.lowerBound < anchorRange.lowerBound,
            """
            那句 `handle` 调用不在抢占分支**之前** —— 主干那条路上它已经不存在了：
            缓存说「没被占用」的盘（绝大多数）点了推出之后，失败与占用都不会有任何提示（§8.146.7）
            """)
    }

    /// **接线守卫（Q9）**：`waitUntilIdle()` 必须用 `while` 而不是 `if`。
    ///
    /// ⚠️ **为什么只能钉源码**（2026-09-25，§8.146.7）：`endEjection()` 里
    /// 「计数归零 → 唤醒」之间**没有 `await`**，被唤醒那一支在 `while` 条件之前也**没有 `await`**
    /// ⇒ 「被唤醒时计数已经又 > 0」这个窗口落在主 actor 的**同一段同步执行**里 ——
    /// 而主 actor 底下的 `DispatchQueue.main` 是 FIFO（在唤醒之前入队的任务一定先跑完）
    /// ⇒ **这个窗口不存在**，也就**造不出**能区分 `while` / `if` 的行为测试。
    ///
    /// ⚠️ 但它不是废话：`while` 防的是**将来有人**在「归零」与「唤醒」之间插一个 `await`
    /// （那时 `if` 会在一轮推出刚起步时放行自动重启、把 `unmountAndEjectDevice` 腰斩）。
    /// 源码守卫的价值就在这里 —— **改动不会静默**。
    @Test func 等推出结束必须用while而不是if() throws {
        let source = try String(
            contentsOf: repoRootForEjectTests.appendingPathComponent("Sources/Services/EjectFlowController.swift"),
            encoding: .utf8)
        #expect(
            source.contains("while activeEjectionCount > 0 {"),
            """
            `waitUntilIdle()` 不再用 `while` 等计数归零了 —— 用 `if` 的话，
            唤醒那一刻若又有一轮推出进来，它会直接返回、放行自动重启，
            把刚起步的 `unmountAndEjectDevice` 腰斩（§8.146.7）
            """)
        #expect(
            !source.contains("if activeEjectionCount > 0"),
            "`waitUntilIdle()` 里出现了 `if activeEjectionCount > 0` —— 这正是上面那条要防的写法（§8.146.7）")
    }

    /// 用户按 Esc、系统那次推出**成功**之后，列表靠 `NSWorkspace` 的卸载通知刷新。
    ///
    /// ## 为什么这条链是「本轮修法」的一部分（2026-09-25，§8.146.6）
    ///
    /// 落闸之后 watcher 不再 `respond`，**也就不再刷新列表**；而按 Esc 这一支同样走不到
    /// `handle`（那个函数才是 `.ejected` 的刷新点）。此时唯一会刷新列表的就是产品自己那条链：
    /// 卷被卸载 ⇒ `NSWorkspace.didUnmountNotification` ⇒ ``DiskListStore/setupMonitoring()``
    /// 的观察者 ⇒ `refresh()`。
    ///
    /// ⇒ 这条链正是「**不必**把 `refresh()` 从 `respond` 里拆出来」的依据：它一断，
    /// 按 Esc 之后盘推出了、列表却还挂着那块盘，而**没有任何东西会报错**。
    /// `IntegrationEjectTests` 的文件头把「挂载通知之后那次 `refresh()`」记成了产品的判定时点，
    /// 但那份是**集成**测试（要真挂载磁盘映像），CI 沙盒里会被跳过 ⇒ 这里钉**接线**。
    @Test func 卸载通知必须能自己刷新列表() throws {
        let source = try String(
            contentsOf: repoRootForEjectTests.appendingPathComponent("Sources/Services/DiskListStore.swift"),
            encoding: .utf8)
        #expect(
            source.contains(
                "[NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification]"),
            """
            `DiskListStore` 不再同时监听挂载与卸载通知了 —— 按 Esc 之后那次推出若成功，
            watcher 已经被闸门挡住、不再刷新列表，于是列表会一直挂着那块**已经推出**的盘，
            而没有任何东西会报错（§8.146.6）
            """)
        #expect(
            source.contains("Task { @MainActor in await self?.refresh() }"),
            """
            监听里不再调 `refresh()` —— 通知收到了却什么都不做，与「没监听」逐字相同
            """)
    }

    /// 那次在跑的推出已经成功 ⇒ `terminateAndEject` 直接返回 `.ejected`，**不再调一次**系统推出。
    ///
    /// ⚠️ 用不存在的 PID（kill 返回 ESRCH，被视为已退出）避免真实杀进程 ——
    /// 与 ``terminateAndEject关闭进程后成功推出`` 同一条约定。
    @Test func 已有一次成功推出在跑时不再重复调系统推出() async {
        let mock = MockEjectService()
        mock.ejectResult = .success(())
        let controller = EjectFlowController(
            ejectService: mock, occupancyDetector: MockOccupancyDetector())
        let processes = [OccupyingProcess(pid: 9_999_999, processName: "Ghost", path: "")]

        // 模拟「先弹窗那条路」已经发起、并且**已经成功返回**的那一次系统推出。
        let inFlight = Task { @MainActor in EjectOutcome.ejected }
        let result = await controller.terminateAndEject(
            disk: makeDisk(), processes: processes, awaiting: inFlight)

        guard case .ejected = result else {
            Issue.record("那次推出已经成功了，这里却返回 \(result)")
            return
        }
        #expect(
            !mock.ejectCalled,
            """
            那次推出已经成功、却还是又调了一次 `unmountAndEjectDevice` ——
            两次并发调用对同一卷行为未定义，第二次会因「设备已不在」报 notFound，
            把一次成功写成失败（§8.146）
            """)
    }
}

/// `EjectUI.swift` 所在仓库根。
///
/// ⚠️ 本文件原先只读 `Sources/...` 的源码，没有这个锚；加它是因为新守卫要读
/// `Sources/Services/EjectUI.swift`（同 `UpdateSettingsTests` 里那个 `repoRoot` 的口径）。
private var repoRootForEjectTests: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

/// 一个「完成了没有」的标志。
///
/// 只在主 actor 上读写（测试与它派生的 `Task { @MainActor in }` 都在主 actor 上），
/// 所以 `@unchecked Sendable` 在这里是安全的 —— 加锁反而会把测试写成并发练习。
private final class WaitFlag: @unchecked Sendable {
    var done = false
}

/// 一个「进了 `eject` 就通知、然后短暂挂住」的替身。
///
/// **为什么要它**：``EjectFlowController/activeEjectionCount`` 只在推出**进行中**为正，
/// 而 `MockEjectService` 立刻返回 ⇒ 计数瞬间归零，测不到那个窗口。
/// 这里用 `AsyncStream` 通知「真的进来了」，再用 `Task.sleep`（**让路**，不阻塞线程）
/// 把窗口撑开够测试观察。
private final class BlockingEjectService: EjectService, @unchecked Sendable {

    /// 每次进入 `eject` 时投递一个元素。
    let entered: AsyncStream<Void>

    private let enteredContinuation: AsyncStream<Void>.Continuation

    override init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.entered = stream
        self.enteredContinuation = continuation
        super.init()
    }

    override func eject(disk: DiskInfo) async -> Result<Void, EjectFailure> {
        enteredContinuation.yield()
        try? await Task.sleep(nanoseconds: 300_000_000)
        return .success(())
    }
}
