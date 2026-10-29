import Foundation
import Testing

@testable import SafeOutApp

// MARK: - hdiutil info -plist 解析

/// `hdiutil info -plist` 输出解析的测试。
///
/// 夹具按本机真实 `hdiutil info -plist` 的结构构造（顶层 `images` 数组，
/// 每项含 `image-path` 与 `system-entities[].dev-entry`），
/// 不是凭格式文档臆造——解析契约一旦与实际输出有偏差，测试必须能发现。
@Suite("hdiutil info 解析")
struct DiskImageInfoParsingTests {

    /// 构造一张映像的 plist 字典。
    private func imageEntry(_ imagePath: String, devEntries: [String]) -> [String: Any] {
        [
            "image-path": imagePath,
            "system-entities": devEntries.map { ["dev-entry": $0] as [String: Any] },
        ]
    }

    private func plistData(_ images: [[String: Any]]) -> Data {
        // swiftlint:disable:next force_try
        try! PropertyListSerialization.data(
            fromPropertyList: ["images": images], format: .xml, options: 0)
    }

    /// 两张映像：一张 backing 在目标卷上、一张在别处，都应解析出正确的路径与顶层 device。
    @Test func 解析出路径与顶层设备() {
        let data = plistData([
            imageEntry("/Volumes/wenbo-data/Games/GameA.dmg", devEntries: ["/dev/disk6", "/dev/disk6s1"]),
            imageEntry("/Users/wenbo/Downloads/GameB.dmg", devEntries: ["/dev/disk7s1", "/dev/disk7"]),
        ])

        let images = DiskImageInfoParser.parse(plist: data)

        #expect(images.count == 2)
        #expect(images[0].imagePath == "/Volumes/wenbo-data/Games/GameA.dmg")
        #expect(images[1].imagePath == "/Users/wenbo/Downloads/GameB.dmg")
    }

    /// **顶层 device 必须选整盘节点**（`/dev/disk6`），不是分区节点（`/dev/disk6s1`）：
    /// `hdiutil detach` 以整盘为单位，拿分区节点去 detach 会留下其余分区仍占着 backing。
    /// system-entities 的顺序不保证整盘在前，夹具故意把分区排在前面。
    @Test func 顶层设备选整盘节点而不是分区() {
        let data = plistData([
            imageEntry("/V/x.dmg", devEntries: ["/dev/disk6s2", "/dev/disk6s1", "/dev/disk6"])
        ])

        let images = DiskImageInfoParser.parse(plist: data)

        #expect(images.first?.device == "/dev/disk6")
    }

    /// 无 `image-path` 或没有任何 `dev-entry` 的映像必须跳过——
    /// 留一个「定位不了也分离不了」的条目只会让 UI 显示出无法操作的占用者。
    @Test func 缺路径或缺设备的映像被跳过() {
        let data = plistData([
            ["system-entities": [["dev-entry": "/dev/disk8"]]],  // 无 image-path
            ["image-path": "/V/y.dmg"],  // 无 system-entities
            imageEntry("/V/z.dmg", devEntries: ["/dev/disk9"]),
        ])

        let images = DiskImageInfoParser.parse(plist: data)

        #expect(images.map(\.imagePath) == ["/V/z.dmg"])
    }

    /// 坏输入（不是 plist / 结构不符）返回空数组而不是崩——
    /// 子进程输出永远不可信，解析器不许把「输出异常」升级成崩溃。
    @Test func 坏输入返回空() {
        #expect(DiskImageInfoParser.parse(plist: Data("not a plist".utf8)).isEmpty)
        #expect(DiskImageInfoParser.parse(plist: Data()).isEmpty)
    }
}

// MARK: - backing(under:) 卷匹配

@Suite("backing 卷匹配")
struct DiskImageBackingMatchTests {

    private let images = [
        AttachedDiskImage(imagePath: "/Volumes/data/games/a.dmg", device: "/dev/disk6"),
        AttachedDiskImage(imagePath: "/Volumes/data2/b.dmg", device: "/dev/disk7"),
        AttachedDiskImage(imagePath: "/Users/wenbo/c.dmg", device: "/dev/disk8"),
    ]

    /// **前缀误匹配回归**：`/Volumes/data2/b.dmg` 以 `/Volumes/data` 开头，
    /// 不带尾斜杠的前缀判断会把它误算到 `/Volumes/data` 上——
    /// 那会让「关闭并推出」去 detach 一张与本盘无关的映像。
    @Test func 卷名是别的卷的前缀时不误中() {
        let matched = DiskImageInfoParser.backing(under: "/Volumes/data", of: images)
        #expect(matched.map(\.device) == ["/dev/disk6"])
    }

    /// 子目录里的 backing 必须命中（DMG 不总是放在卷根）。
    @Test func 深层子路径命中() {
        let matched = DiskImageInfoParser.backing(under: "/Volumes/data2", of: images)
        #expect(matched.map(\.imagePath) == ["/Volumes/data2/b.dmg"])
    }

    /// 卷上没有任何映像时返回空（上层据此走「无 DMG 贡献」的原兜底）。
    @Test func 无匹配返回空() {
        let matched = DiskImageInfoParser.backing(under: "/Volumes/else", of: images)
        #expect(matched.isEmpty)
    }
}

// MARK: - 与 lsof 结果合并（OccupancyDetector.merging）

@Suite("lsof 与磁盘映像合并")
struct OccupancyMergingTests {

    private let mount = "/Volumes/wenbo-data"
    // ⚠️ 不能是 `lazy var`——lazy 属性的 getter 是 `mutating`，
    // 而 struct 的 @Test 方法是非 mutating 上下文，访问会直接编译失败。
    private var image: AttachedDiskImage {
        AttachedDiskImage(imagePath: "\(mount)/Games/GameA.dmg", device: "/dev/disk6")
    }

    /// 核心修复场景（2026-10-13 事故）：无 FDA 时 lsof 一行都没有，
    /// 但卷上有 DMG ⇒ 合并结果非空 ⇒ 上层给 `.occupied` 而不是 `.needsFullDiskAccess`。
    @Test func lsof空但卷上有映像时结果非空() {
        let merged = OccupancyDetector.merging(lsof: [], diskImages: [image], mountPath: mount)
        #expect(merged.count == 1)
        guard case .diskImage(let device) = merged.first?.kind else {
            Issue.record("合并结果应是磁盘映像条目，实际 \(String(describing: merged.first))")
            return
        }
        #expect(device == "/dev/disk6")
        #expect(merged.first?.displayName == "GameA.dmg")
    }

    /// 有 FDA 时 lsof 会列出 `diskimagesiod`（系统 holder）——
    /// 用户无权终止它（EPERM），列出来只会误导；映像条目才是「可关闭」的那个，必须替换它。
    @Test func 有映像时diskimagesiod被剔除() {
        let lsof = [
            OccupyingProcess(pid: 500, processName: "diskimagesiod", path: "\(mount)/Games/GameA.dmg"),
            OccupyingProcess(pid: 501, processName: "IINA", path: "\(mount)/X/03.mp4"),
        ]
        let merged = OccupancyDetector.merging(lsof: lsof, diskImages: [image], mountPath: mount)

        #expect(!merged.contains { $0.processName == "diskimagesiod" })
        #expect(merged.contains { $0.processName == "IINA" }, "真实用户进程必须保留")
        #expect(merged.contains { $0.kind == .diskImage(device: "/dev/disk6") })
    }

    /// 卷上没有映像时合并必须是恒等——不能凭空多出条目，也不能丢掉进程。
    @Test func 无映像时原样返回() {
        let lsof = [OccupyingProcess(pid: 501, processName: "IINA", path: "\(mount)/X/03.mp4")]
        let merged = OccupancyDetector.merging(lsof: lsof, diskImages: [], mountPath: mount)
        #expect(merged == lsof)
    }

    /// 映像在**别的**卷上时不计入本卷（与 backing 匹配的联动）。
    @Test func 别卷映像不计入() {
        let elsewhere = AttachedDiskImage(imagePath: "/Volumes/other/x.dmg", device: "/dev/disk9")
        let merged = OccupancyDetector.merging(lsof: [], diskImages: [elsewhere], mountPath: mount)
        #expect(merged.isEmpty)
    }
}

// MARK: - OccupyingProcess.diskImage 工厂

@Suite("磁盘映像占用条目")
struct DiskImageOccupantTests {

    /// 合成 pid 必须为**负**（真 pid 恒 > 0，负值永不冲突），
    /// 且同一 device 两次构造必须得到**相同** pid——SwiftUI 按 id diff，id 每轮都变会导致列表闪行。
    @Test func 合成pid为负且按device稳定() {
        let a = OccupyingProcess.diskImage(imagePath: "/V/g.dmg", device: "/dev/disk6")
        let b = OccupyingProcess.diskImage(imagePath: "/V/g.dmg", device: "/dev/disk6")
        let c = OccupyingProcess.diskImage(imagePath: "/V/h.dmg", device: "/dev/disk7")

        #expect(a.pid < 0)
        #expect(a.pid == b.pid, "同一 device 每轮检测应得到相同 id")
        #expect(a.pid != c.pid, "不同 device 应得到不同 id")
    }

    /// 显示名必须是 backing 文件名（含扩展名）——映像没有「应用身份」可解析，
    /// 文件名是用户唯一能认出的名字；`EjectFlowController.record` 的日志也用它。
    @Test func 显示名是backing文件名() {
        let entry = OccupyingProcess.diskImage(
            imagePath: "/Volumes/wenbo-data/Games/Machine.Mind.v1.0.3.dmg", device: "/dev/disk6")
        #expect(entry.displayName == "Machine.Mind.v1.0.3.dmg")
        #expect(entry.path == "/Volumes/wenbo-data/Games/Machine.Mind.v1.0.3.dmg")
        #expect(entry.kind == .diskImage(device: "/dev/disk6"))
    }
}

// MARK: - ProcessTerminator 防线

@Suite("清场信号防线")
struct TerminatorDiskImageGuardTests {

    /// **kill(0) 灾难防线**：磁盘映像条目的合成负 pid 若漏进 `kill()`，
    /// POSIX 语义是「信号发给整个进程组」——这是本仓库最危险的一类误操作。
    /// 替身必须**零调用**，且映像条目不得计入「无法终止」（它由 detach 流程负责）。
    @Test func 磁盘映像条目不发信号也不计入失败() {
        var killCalls: [(pid: Int32, signal: Int32)] = []
        let image = OccupyingProcess.diskImage(imagePath: "/V/g.dmg", device: "/dev/disk6")
        let real = OccupyingProcess(pid: 4242, processName: "IINA", path: "/V/x")

        let unkillable = ProcessTerminator.signal(
            [image, real], signal: SIGTERM,
            kill: { pid, sig in
                killCalls.append((pid, sig))
                return 0
            })

        #expect(killCalls.map(\.pid) == [4242], "只有真进程能收到信号，实际 \(killCalls)")
        #expect(unkillable.isEmpty, "映像条目不是「关不掉」——它由 detach 负责")
    }

    /// 防御纵深：哪怕 `kind` 防线未来被改坏，`pid <= 0` 也必须被拦在 `kill()` 之外。
    @Test func 非正pid一律不发信号() {
        var killCalls: [Int32] = []
        let zero = OccupyingProcess(pid: 0, processName: "kernel", path: "")
        let negative = OccupyingProcess(pid: -100, processName: "synthetic", path: "")

        _ = ProcessTerminator.signal(
            [zero, negative], signal: SIGKILL,
            kill: { pid, _ in
                killCalls.append(pid)
                return 0
            })

        #expect(killCalls.isEmpty, "kill(0)/kill(负值) 是进程组信号，绝不允许发出，实际 \(killCalls)")
    }
}

// MARK: - Provider 缓存与单飞

@Suite("映像抓取缓存与单飞")
struct DiskImageProviderTests {

    /// `detect(mountPath:)` 被按盘并行调用，`hdiutil info` 又是全局调用——
    /// 并发调用方必须共享**一次**真实抓取（单飞），否则 N 块盘就是 N 个子进程风暴。
    @Test func 并发调用只抓取一次() async {
        let counter = FetchCounter()
        let provider = DiskImageOccupancyProvider(fetch: {
            await counter.increment()
            // 模拟真实抓取耗时，让并发调用必然撞上 in-flight 窗口
            try? await Task.sleep(nanoseconds: 200_000_000)
            return #"{"images": []}"#
        })

        async let first = provider.images()
        async let second = provider.images()
        async let third = provider.images()
        let results = await [first, second, third]

        // ⚠️ #expect 的 autoclosure 不支持并发，actor 取值必须先落进本地常量。
        let fetchCount = await counter.value
        #expect(results.allSatisfy { $0 != nil })
        #expect(fetchCount == 1, "三次并发应共享一次抓取，实际抓取 \(fetchCount) 次")
    }

    /// TTL 内第二次调用必须命中缓存（不再抓取）；
    /// 这是「一轮轮询里所有盘共享一次 hdiutil」的兑现。
    @Test func TTL内命中缓存() async {
        let counter = FetchCounter()
        let provider = DiskImageOccupancyProvider(fetch: {
            await counter.increment()
            return #"{"images": []}"#
        })

        _ = await provider.images()
        _ = await provider.images()

        let fetchCount = await counter.value
        #expect(fetchCount == 1)
    }

    /// 抓取失败返回 `nil`（上层按「无 DMG 贡献」降级），
    /// 且**不写缓存**——下一次调用必须重试，不能让一次瞬断把检测打残一个 TTL。
    @Test func 失败不写缓存且下次重试() async {
        let counter = FetchCounter()
        let provider = DiskImageOccupancyProvider(fetch: {
            await counter.increment()
            return nil
        })

        let first = await provider.images()
        let second = await provider.images()

        let fetchCount = await counter.value
        #expect(first == nil && second == nil)
        #expect(fetchCount == 2, "失败不缓存，每次调用都应重试")
    }
}

/// 线程安全的抓取计数替身。
private actor FetchCounter {
    private var count = 0
    var value: Int { count }
    func increment() { count += 1 }
}
