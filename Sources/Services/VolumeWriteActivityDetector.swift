import Darwin
import Foundation

/// 用「可用空间的变化」判断一块卷是否正在被写入。
///
/// ## 为什么用这个信号，而不是再想办法看进程
///
/// 见 ``VolumeWriteActivity`` 抬头那段实测：访达拷贝期间 `lsof` 零命中、容量却在稳定增长。
/// 也就是说，在**没有完全磁盘访问**的前提下，「谁在写」这个问题根本答不出来；
/// 但「有没有在写」答得出——只要比较两次 `statfs` 的可用空间。
///
/// 这条信号是**只读**的：`statfs` 只查元数据，不碰用户的数据文件。
///
/// ## 阈值为什么是 0.5 MB/s 而不是 0
///
/// 外置卷在系统手里总有些零碎写入（Spotlight 索引、日志、元数据缓存回写）。
/// 若把「任何减少」都报成写入，每块闲盘都会常年挂着「正在写入」，
/// 用户会学会无视这条提示——那比不显示更糟。
/// 0.5 MB/s 是实测的折中：拷贝实测 33 MB/s 远高于它，而空闲盘的抖动通常是个位 MB/分钟。
enum VolumeWriteActivityDetector {

    /// 低于这个速率不算「正在写入」。见上方说明。
    nonisolated static let minimumBytesPerSecond: Int64 = 500_000

    /// 两次采样至少要隔这么久才计算速率。
    ///
    /// 间隔太短时速率是两个相邻读数的差分，任何一次延迟抖动都会放大成假的高速率；
    /// 15s 的轮询周期远大于它，这一条只在**手动连点刷新**时生效。
    nonisolated static let minimumInterval: TimeInterval = 1

    /// 读一个卷的**可用空间**（字节）。读不到（卷已卸载等）返回 `nil`。
    ///
    /// 用 `/usr/bin/df` 同源的 `statfs`：这是唯一不需要权限的容量口径，
    /// 且与 ``DiskInfo/freeBytes``（走 `URLResourceValues`）在 1024 进制上一致。
    nonisolated static func availableBytes(atMountPath path: String) -> Int64? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }

    /// 比较两次采样，判断是否正在写入。**纯函数**，时间由调用方传入。
    ///
    /// - Returns: 达到阈值时返回活动证据；否则 `nil`（含「空间变大」= 删除/清理，
    ///   那确实也是一次磁盘操作，但它的方向与「即将拔盘」的风险相反，
    ///   这里刻意不报，避免把「刚清空回收站」说成「正在拷贝」）。
    nonisolated static func detect(
        previousBytes: Int64,
        previousAt: Date,
        currentBytes: Int64,
        currentAt: Date
    ) -> VolumeWriteActivity? {
        let interval = currentAt.timeIntervalSince(previousAt)
        guard interval >= minimumInterval else { return nil }

        // 可用空间变小 ⇒ 有字节被写进来。
        let delta = previousBytes - currentBytes
        guard delta > 0 else { return nil }

        let rate = Int64(Double(delta) / interval)
        guard rate >= minimumBytesPerSecond else { return nil }
        return VolumeWriteActivity(bytesPerSecond: rate, sampledAt: currentAt)
    }
}
