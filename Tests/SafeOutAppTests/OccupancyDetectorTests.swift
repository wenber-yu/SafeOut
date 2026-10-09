import Testing

@testable import SafeOutApp

/// `lsof` 输出解析的测试。
///
/// 这些夹具取自本机**真实**执行 `lsof -Fpcn0 /Volumes/wenbo-data` 的原始字节，
/// 不是凭格式文档臆造——解析契约一旦与实际情况有偏差，测试必须能发现。
///
/// 断言的是 ``OccupyingProcess/processName``（`lsof` 的 `c` 字段，可执行名）。
/// 这个阶段还没有「应用身份」可言：把 `IMVIDEO` 还原成应用名 `Bunny` 是
/// ``ProcessAppResolver`` 的职责，它的测试在 `ProcessAppResolverTests`。
@Suite("lsof 输出解析")
struct LsofParsingTests {

    /// 单进程、单文件，取自 IINA 播放 wenbo-data 上视频的真实输出。
    @Test func 解析单进程记录() {
        // 真实输出：p17917\0cIINA\0\nf9\0n/Volumes/.../03.mp4\0
        let output = "p17917\0cIINA\0\nf9\0n/Volumes/wenbo-data/X/03.mp4\0"
        let result = OccupancyDetector.parseLsof(output)

        #expect(result.count == 1)
        #expect(result.first?.pid == 17917)
        #expect(result.first?.processName == "IINA")
        #expect(result.first?.path == "/Volumes/wenbo-data/X/03.mp4")
    }

    /// **进程名含空格**——这是改用 `-F` 格式的根本原因。
    /// 默认表格格式按空格切列时，"Google Chrome" 会让 PID 列错位到第 3 列，
    /// 导致 `Int32` 转换失败、该进程被静默丢弃。
    @Test func 进程名含空格仍正确解析() {
        let output = "p421\0cGoogle Chrome\0\nf12\0n/Volumes/Test/a.mp4\0"
        let result = OccupancyDetector.parseLsof(output)

        #expect(result.count == 1)
        #expect(result.first?.pid == 421)
        #expect(result.first?.processName == "Google Chrome")
    }

    /// 同一进程通过多个 fd 访问同一卷：输出里会有多组字段，应按 PID 去重。
    ///
    /// **夹具必须是真实字节**：lsof 会在第二条记录组前插入 `\n`（`\np100`），
    /// 早期夹具漏掉了这个 `\n`，导致解析器把 `\np100` 当未知字段丢弃的 bug 不被发现。
    @Test func 同一进程多fd时去重() {
        let output =
            "p100\0cFinder\0\nf1\0n/Volumes/T/a.txt\0"
            + "\np100\0cFinder\0\nf2\0n/Volumes/T/b.txt\0"
        let result = OccupancyDetector.parseLsof(output)

        #expect(result.count == 1)
        #expect(result.first?.pid == 100)
        // 保留首个路径，不重复展示
        #expect(result.first?.path == "/Volumes/T/a.txt")
    }

    /// 多个不同进程（真实字节格式，含 lsof 的 `\n` 前缀）。
    @Test func 多进程按PID排序() {
        let output =
            "p300\0cBBB\0\nf1\0n/Volumes/T/b\0"
            + "\np100\0cAAA\0\nf1\0n/Volumes/T/a\0"
        let result = OccupancyDetector.parseLsof(output)

        #expect(result.map(\.pid) == [100, 300])
        #expect(result.map(\.processName) == ["AAA", "BBB"])
    }

    /// **回归**：多进程同时占用时不得塌缩成一条、也不得张冠李戴。
    ///
    /// 夹具取自本机真实输出（IINA 播视频 + tail -f 持有临时文件）：
    /// `p5340\0cIINA\0\nf9\0n.../09.mp4\0\np39298\0ctail\0\nf3\0n.../.de_occ_test.tmp\0\n`
    /// 修复前解析结果错误地变成 `[5340:tail]`（只有一条，且名字取自最后一个进程）。
    @Test func 多进程同时占用不塌缩且名字正确() {
        let output =
            "p5340\0cIINA\0\nf9\0n/Volumes/wenbo-data/X/09.mp4\0"
            + "\np39298\0ctail\0\nf3\0n/Volumes/wenbo-data/.de_occ_test.tmp\0\n"
        let result = OccupancyDetector.parseLsof(output)

        #expect(result.count == 2)
        #expect(result.map(\.pid) == [5340, 39298])
        #expect(result.map(\.processName) == ["IINA", "tail"])
        #expect(result.first { $0.pid == 5340 }?.processName == "IINA")
        #expect(result.first { $0.pid == 39298 }?.processName == "tail")
    }

    /// PID 非法时该条记录应被丢弃，而不是崩溃或产生脏数据。
    @Test func 非法PID被丢弃() {
        let output = "pnotapid\0cBad\0n/Volumes/T/x\0" + "p200\0cGood\0n/Volumes/T/y\0"
        let result = OccupancyDetector.parseLsof(output)

        #expect(result.count == 1)
        #expect(result.first?.processName == "Good")
    }

    /// 空输出（无占用）应得到空数组。
    @Test func 空输出得到空结果() {
        #expect(OccupancyDetector.parseLsof("").isEmpty)
    }

    /// 只有 PID 没有命令名的残缺记录不应产出进程。
    @Test func 缺少命令名的记录被丢弃() {
        let output = "p123\0n/Volumes/T/x\0"
        #expect(OccupancyDetector.parseLsof(output).isEmpty)
    }
}
