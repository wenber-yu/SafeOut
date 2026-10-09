import Foundation
import Testing

@testable import SafeOutApp

/// 推出失败原因的归类测试。
///
/// 归类决定了用户看到的引导文案：「磁盘正被使用」应当提示关闭程序后重试，
/// 而「设备已消失」提示重试毫无意义。归类错了，引导就错了。
struct EjectFailureTests {

    /// 实测：对正被进程占用的卷调用 `unmountAndEjectDevice` 抛出
    /// `NSOSStatusErrorDomain code = -47`（fBsyErr）。
    @Test func OSStatus负47归类为磁盘被占用() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: -47)
        #expect(EjectFailure.classify(error) == .inUse)
    }

    @Test func POSIX_EBUSY归类为磁盘被占用() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: 16)
        #expect(EjectFailure.classify(error) == .inUse)
    }

    @Test func fnfErr归类为设备不存在() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: -43)
        #expect(EjectFailure.classify(error) == .notFound)
    }

    @Test func permErr归类为权限不足() {
        #expect(EjectFailure.classify(NSError(domain: NSOSStatusErrorDomain, code: -54)) == .notPermitted)
        #expect(EjectFailure.classify(NSError(domain: NSOSStatusErrorDomain, code: -5000)) == .notPermitted)
    }

    @Test func 未知错误保留原始描述() {
        let error = NSError(
            domain: "CustomDomain",
            code: 999,
            userInfo: [NSLocalizedDescriptionKey: "something odd"]
        )
        guard case .other(let detail) = EjectFailure.classify(error) else {
            Issue.record("未归类错误应保留原始描述")
            return
        }
        #expect(detail == "something odd")
    }

    /// 兜底路径：系统未给出结构化错误码时，按描述文本匹配。
    @Test func 描述含inUse时归为占用() {
        let error = NSError(
            domain: "CustomDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The disk is in use by another process"]
        )
        #expect(EjectFailure.classify(error) == .inUse)
    }

    /// 磁盘名出现在**能给出可执行下一步**的那几档正文里（设备已消失 / 系统不允许 /
    /// 未归类），用户据此确认「说的就是这块盘」。
    ///
    /// **`.inUse` 是例外，且是有意的**：它走设计稿原文，正文只讲「怎么解决」，
    /// 盘名交给弹窗标题（设计稿文案原则：「标题带磁盘名」）。早前正文与标题重复报同一个
    /// 盘名，正文那行被浪费掉了。
    @Test func 失败原因含磁盘名() {
        let disk = makeDisk(name: "测试盘")
        for failure in [EjectFailure.notFound, .notPermitted, .other("boom")] {
            let text = failure.reasonText(diskName: disk.displayName)
            #expect(text.contains("测试盘"), "\(failure.logText) 的正文应带磁盘名，实际：\(text)")
        }
    }

    /// `.inUse` 的正文不重复磁盘名（盘名归标题）。
    @Test func 被占用的正文不含磁盘名() {
        let text = EjectFailure.inUse.reasonText(diskName: "测试盘")
        #expect(!text.contains("测试盘"), "实际：\(text)")
    }
}

/// 容量格式化的一致性测试。
///
/// 此前项目存在三套实现（两处手写 1024 进制 + 一处系统 1000 进制），
/// 同一块盘在不同界面显示不同数字。收敛后不可能再出现口径分歧。
struct ByteFormatTests {

    /// `.file` 风格使用 1000 进制；MB 及以上与 Finder「显示简介」完全一致。
    /// 1000 字节处为 SI 标准写法 `kB`（小写 k），这是系统 API 的实际输出。
    ///
    /// ⚠️ **别给「MB 以下」补字面量断言**。`ByteCountFormatStyle` 的输出是本地化的，
    /// 但本地化**只发生在 MB 以下**。2026-09-18 实测（见 `ByteFormat.string`）：
    ///
    /// | 值 | zh-Hans | en |
    /// |---|---|---|
    /// | 1 kB / 1 MB / 1 GB / 4 TB | 完全相同 | 完全相同 |
    /// | 0 | `0字节` | `0 bytes` |
    /// | 500 | `500字节` | `500 bytes` |
    ///
    /// 所以下面四条是**侥幸落在一致区**，并不代表这些字面量是安全的。
    /// 要给小容量写断言，得先给 `ByteFormat.string` 加 locale 参数并显式指定，
    /// 否则就是重演 2026-09-17 那次「本地绿、CI 红」—— 见 `TestLanguage`。
    @Test func 千进制与Finder一致() {
        #expect(ByteFormat.string(1_000) == "1 kB")
        #expect(ByteFormat.string(1_000_000) == "1 MB")
        #expect(ByteFormat.string(1_000_000_000) == "1 GB")
        #expect(ByteFormat.string(4_000_000_000_000) == "4 TB")
    }

    /// 旧的手写实现用 1024 进制，1e9 字节会显示成 `953.7 MB`；
    /// 收敛后只可能有一种口径。
    @Test func 不再出现1024进制口径() {
        let text = ByteFormat.string(1_000_000_000)
        #expect(!text.contains("953"), "不应再出现 1024 进制换算结果，实际为 \(text)")
    }

    @Test func 零容量不会产生NaN() {
        #expect(ByteFormat.usagePercent(used: 0, total: 0) == 0)
    }

    @Test func 容量为零时百分比为0() {
        #expect(ByteFormat.usagePercent(used: 100, total: 0) == 0)
    }

    @Test func 百分比计算正确() {
        #expect(abs(ByteFormat.usagePercent(used: 250, total: 1_000) - 0.25) < 0.0001)
    }
}

// MARK: - Fixtures

private func makeDisk(name: String) -> DiskInfo {
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
