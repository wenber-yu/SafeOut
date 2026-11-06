import Foundation
import Testing

@testable import SafeOutApp

/// 「可用空间的变化 → 正在写入」这条判据的纯函数测试。
///
/// 它守的是 2026-10-30 用户报的症：访达在拷贝、`lsof` 零命中、界面说「可安全推出」。
/// 这里有两条互相独立的线：进程线看得到时用进程（可点名、能关闭），
/// 看不到时只能靠容量变化说「确实在写」。
///
/// 判据一旦写松（例如把「任何减少」都报成写入），每块闲盘都会常年挂着「正在写入」，
/// 用户会学会无视这条提示 —— 那比不显示更糟。所以阈值两侧都必须有断言。
@Suite("写入活动的判据")
struct VolumeWriteActivityDetectorTests {

    private let epoch = Date(timeIntervalSince1970: 0)

    @Test("可用空间减少且超过阈值时判为写入，速率 = 差值 ÷ 间隔")
    func 空间减少时判为写入() {
        // 15 秒少 36 MB ⇒ 2.4 MB/s（与实测的访达拷贝同一量级）。
        let activity = VolumeWriteActivityDetector.detect(
            previousBytes: 1_000_000_000,
            previousAt: epoch,
            currentBytes: 964_000_000,
            currentAt: epoch.addingTimeInterval(15))

        #expect(activity?.bytesPerSecond == 2_400_000)
        #expect(activity?.sampledAt == epoch.addingTimeInterval(15))
    }

    /// **阈值下方不报**：空闲盘的元数据抖动必须被挡掉。
    @Test("减少量低于阈值时不判为写入")
    func 低于阈值时不判为写入() {
        // 15 秒只少 3 MB ≈ 0.2 MB/s，低于 0.5 MB/s 的阈值。
        let activity = VolumeWriteActivityDetector.detect(
            previousBytes: 1_000_000_000,
            previousAt: epoch,
            currentBytes: 997_000_000,
            currentAt: epoch.addingTimeInterval(15))

        #expect(activity == nil, "空闲盘的零碎写入不能报成「正在拷贝」")
    }

    /// 空间**变大**是删除，不是写入。方向弄反会让「刚清空回收站」显示成「正在拷贝」。
    @Test("可用空间变大时不判为写入")
    func 空间变大时不判为写入() {
        let activity = VolumeWriteActivityDetector.detect(
            previousBytes: 900_000_000,
            previousAt: epoch,
            currentBytes: 1_000_000_000,
            currentAt: epoch.addingTimeInterval(15))

        #expect(activity == nil)
    }

    /// 间隔太短时差分被延迟抖动放大。手动连点刷新会走到这条。
    @Test("两次采样间隔过短时不判为写入")
    func 间隔过短时不判为写入() {
        let activity = VolumeWriteActivityDetector.detect(
            previousBytes: 1_000_000_000,
            previousAt: epoch,
            currentBytes: 990_000_000,
            currentAt: epoch.addingTimeInterval(0.2))

        #expect(activity == nil)
    }

    /// **真的读一次真实卷**：`statfs` 是只读调用，不会碰到用户数据。
    /// 这条防的是「换口径」——例如把 `f_bavail * f_bsize` 写成 `f_bavail * f_iosize`，
    /// 那会让速率整体偏移一个不可见的比例，而所有注入读数的用例都还是绿的。
    @Test("能从真实挂载点读出可用空间")
    func 能读出真实可用空间() throws {
        let bytes = try #require(VolumeWriteActivityDetector.availableBytes(atMountPath: "/"))
        #expect(bytes > 0, "根卷可用空间必须为正数，实得 \(bytes)")
    }

    @Test("路径不存在时返回 nil，而不是 0")
    func 路径不存在时返回nil() {
        #expect(
            VolumeWriteActivityDetector.availableBytes(atMountPath: "/Volumes/__NOT_MOUNTED__") == nil,
            "读不到必须是 nil：返回 0 会被算成「空间掉到零」，那是最严重的假写入")
    }

    /// 速率的展示形式：`36 MB/s`。`/s` 不本地化（与 ``ByteFormat`` 的 1000 进制同一口径）。
    @Test("速率以字节格式化，单位带 /s")
    func 速率格式化() {
        let activity = VolumeWriteActivity(
            bytesPerSecond: 36_000_000, sampledAt: epoch)
        #expect(activity.formattedRate.hasSuffix("/s"))
        #expect(activity.formattedRate.contains("36"), "36 MB/s 应显示 36：\(activity.formattedRate)")
    }
}
