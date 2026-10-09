import DiskArbitration
import Foundation
import Testing

@testable import SafeOutApp

/// `DiskService` 里**不碰硬件的那两层**：判定折叠与组装规则。
///
/// ## 为什么只测这两层
///
/// `DiskService` 现在分成三层（2026-09-17 拆开，见 `DESIGN-SPEC.md` §8.30）：
///
/// | 层 | 内容 | 怎么测 |
/// |---|---|---|
/// | **胶水** | `DASessionCreate` / `DADiskCreateFromVolumePath` | 只能靠真机 —— `IntegrationEjectTests` 自己挂一个 dmg 卷 |
/// | **判定 + 折叠** | `assembleDisks` / `classifyAndBuild` | **本文件** —— 喂假描述字典即可 |
/// | **组装** | `makeDiskInfo(url:values:description:)` | **本文件** —— 喂构造出的 `URLResourceValues` |
///
/// 本文件本身就是一次事故的产物：2026-09-17 发现 `DiskService` 的那 77 行
/// **从来不是被单测覆盖的** —— 是「某个测试构造 `ContentView` → 摸到生产单例
/// → 本机恰好插着盘」蹭来的（`DESIGN-SPEC.md` §8.28.6）。
/// 把那条暗道堵掉后它诚实地掉到 **0/94**，于是把真正能测的这一层补上。
///
/// > **判据**：**覆盖率掉了不等于回归，也可能是「原来那部分覆盖率是假的」。**
/// > 区分方法：看它原来是被**断言**覆盖的，还是被**副作用**覆盖的 ——
/// > 后者会在有人整理依赖关系时整块蒸发。
///
/// > **判据**：**「测不到」通常不是「不可测」，而是「依赖写死在函数体里」。**
/// > 把碰系统的那几行挤到最外层的胶水里，中间那层自然就成了纯函数 ——
/// > 本文件从 3 条长到 11 条，靠的就是这一步，而不是去造一块真盘。
struct DiskServiceTests {

    private let service = DiskService()

    /// 一个必然存在的目录。
    ///
    /// 用临时目录而不是 `/Volumes/...`：**测试不能依赖本机插了什么盘** ——
    /// 这正是本文件要守的那条纪律，夹具自己先得做到。
    private var tempDir: URL { FileManager.default.temporaryDirectory }

    /// 一份 DiskArbitration 描述字典。
    ///
    /// 默认值刻意写成**一块真实外置 USB 硬盘的形状**（本机 SanDisk Extreme 55AE 的实测属性）：
    /// `DADeviceInternal = false` 是唯一可靠的「外置」信号，而
    /// `DAMediaEjectable` / `DAMediaRemovable` 对 USB 硬盘全是 `false` ——
    /// 若按「可推出」过滤，会把用户的外置硬盘整个过滤掉。
    private func description(
        bsdName: String? = "disk9s2",
        model: String? = "SanDisk Extreme 55AE",
        protocolName: String? = "USB",
        deviceInternal: Bool? = false,
        isNetwork: Bool? = false,
        isEjectable: Bool? = false
    ) -> [String: Any] {
        var d: [String: Any] = [:]
        if let bsdName { d[kDADiskDescriptionMediaBSDNameKey as String] = bsdName }
        if let model { d[kDADiskDescriptionDeviceModelKey as String] = model }
        if let protocolName { d[kDADiskDescriptionDeviceProtocolKey as String] = protocolName }
        if let deviceInternal { d[kDADiskDescriptionDeviceInternalKey as String] = deviceInternal }
        if let isNetwork { d[kDADiskDescriptionVolumeNetworkKey as String] = isNetwork }
        if let isEjectable { d[kDADiskDescriptionMediaEjectableKey as String] = isEjectable }
        return d
    }

    // MARK: - 组装层：`makeDiskInfo`

    @Test func 描述齐全时按字典组装() throws {
        let info = try #require(service.makeDiskInfo(url: tempDir, description: description()))

        #expect(
            info.id == tempDir.path,
            "id 必须就是挂载路径 —— 它是占用结论那张字典的键，错一次就张冠李戴")
        #expect(info.mountPath == tempDir.path)
        #expect(info.bsdName == "disk9s2")
        #expect(info.deviceProtocol == "USB")
        #expect(info.deviceModel == "SanDisk Extreme 55AE")
        #expect(!info.volumeName.isEmpty, "卷名取自 URL 资源值，真实卷一定有名字")
        #expect(info.totalBytes > 0, "总容量取自 URL 资源值，真实卷一定 > 0")
        #expect(
            info.usedBytes + info.freeBytes == info.totalBytes,
            "已用 + 可用必须等于总量 —— 三者由同一次读数的 total 与 available 得到，对不上就是算错了")
    }

    /// **静默退化 1**：描述里没有 BSD 名时，回退成 `url.lastPathComponent`。
    ///
    /// 这条断言的作用不是「证明回退是对的」，而是**把这个行为钉住**：
    /// 它会让界面上显示的设备名从 `disk9s2` 变成卷名 —— 不报错，只是看着像另一块盘。
    /// 以后谁想改成「缺了就跳过这块盘」，会在这里看见自己改动了什么。
    @Test func 描述缺BSD名时回退成路径末段() throws {
        let info = try #require(
            service.makeDiskInfo(url: tempDir, description: description(bsdName: nil)))
        #expect(info.bsdName == tempDir.lastPathComponent)
        #expect(info.bsdName != "disk9s2")
    }

    /// **静默退化 2**：读不到容量就整块跳过（宁可漏列，也不列一块容量未知的盘）。
    ///
    /// 用一个**不存在的路径**逼出这条：`resourceValues` 要么抛错、要么给不出容量，
    /// 两条路都应当收成 `nil`，而不是崩掉、也不是返回一块 `totalBytes == 0` 的盘。
    @Test func 读不到容量时返回nil而不是零容量() {
        let missing = tempDir.appendingPathComponent("SafeOut-不存在的路径-\(UUID().uuidString)")
        let info = service.makeDiskInfo(url: missing, description: description())
        #expect(
            info == nil,
            "容量读不到时必须返回 nil —— 返回一块 0 字节的盘，用户会以为盘是空的")
    }

    /// **静默退化 3**：容量键缺失 → 同样返回 `nil`。
    ///
    /// 这一条走的是**纯组装**入口，所以能直接喂 `nil` ——
    /// 不必去造一个「存在但报不出容量」的真卷（那既难造又依赖具体文件系统实现）。
    /// 两种缺法都要试：全缺、只缺可用容量。
    @Test func 容量缺失时返回nil() {
        let none = DiskService.makeDiskInfo(
            url: tempDir, totalCapacity: nil, availableCapacity: nil,
            volumeName: "TestDisk", description: description())
        #expect(none == nil, "总量与可用量都缺时必须返回 nil")

        let halfMissing = DiskService.makeDiskInfo(
            url: tempDir, totalCapacity: 1000, availableCapacity: nil,
            volumeName: "TestDisk", description: description())
        #expect(
            halfMissing == nil,
            "只缺可用量也必须返回 nil —— 否则会算出一块「已用 = 总量」的假盘，看着像盘满了")
    }

    /// **静默退化 4**：卷名缺失 → 回落成空串，而不是崩、也不是拿设备名顶上。
    ///
    /// 下游 `displayName` 会把空卷名换成 `bsdName`，所以这里钉住的是「`volumeName` 保持为空」
    /// 这个契约 —— 若哪天改成「拿 bsdName 填进 volumeName」，详情页会把设备名当卷名显示。
    @Test func 卷名缺失时回落成空串() throws {
        let info = try #require(
            DiskService.makeDiskInfo(
                url: tempDir, totalCapacity: 1000, availableCapacity: 400,
                volumeName: nil, description: description()))
        #expect(info.volumeName.isEmpty)
        #expect(info.totalBytes == 1000)
        #expect(info.freeBytes == 400)
        #expect(info.usedBytes == 600)
        #expect(info.displayName == "disk9s2", "卷名为空时 displayName 应当回落到设备名")
    }

    // MARK: - 判定 + 折叠层：`assembleDisks`

    /// 空列表进、空列表出（不是崩、也不是返回一块占位盘）。
    @Test func 空挂载点列表返回空数组() {
        let disks = service.assembleDisks(urls: []) { _ in self.description() }
        #expect(disks.isEmpty)
    }

    /// 拿不到 DiskArbitration 描述的卷 → 跳过。
    @Test func 取不到描述时跳过该卷() {
        let disks = service.assembleDisks(urls: [tempDir]) { _ in nil }
        #expect(
            disks.isEmpty,
            "拿不到 DA 描述时必须跳过 —— 宁可漏列，也不能把性质不明的卷当成外置盘交给用户去推出")
    }

    /// 内置盘（`DADeviceInternal = true`）→ 排除。判错的后果是用户去「推出」系统盘。
    @Test func 内置盘被跳过() {
        let disks = service.assembleDisks(urls: [tempDir]) { _ in
            self.description(deviceInternal: true)
        }
        #expect(disks.isEmpty, "内置盘绝不能进列表 —— 它不能被推出")
    }

    /// 网络卷 → 排除。它应当卸载而非推出设备，且失败时的报错会误导用户以为硬盘坏了。
    @Test func 网络卷被跳过() {
        let disks = service.assembleDisks(urls: [tempDir]) { _ in
            self.description(protocolName: "SMB", isNetwork: true)
        }
        #expect(disks.isEmpty, "网络卷应当卸载而非推出设备")
    }

    /// 外置盘（`DADeviceInternal = false`）→ 列出，且三个跳过分支都没误伤它。
    @Test func 外置盘被列出() throws {
        let disks = service.assembleDisks(urls: [tempDir]) { _ in self.description() }
        let info = try #require(disks.first)
        #expect(disks.count == 1)
        #expect(info.mountPath == tempDir.path)
        #expect(info.bsdName == "disk9s2")
    }

    /// 多卷混合时**逐个判定** —— 一块被跳过不能把后面的也一起带走。
    ///
    /// 这条守的是循环的**短路方向**：`continue` 写成 `break`、或把判定提到循环外，
    /// 都会让「列表里只有第一块盘」这种 bug 溜过去，而单卷测试发现不了。
    @Test func 混合列表里跳过一块不影响其它块() throws {
        let root = URL(fileURLWithPath: "/")
        let disks = service.assembleDisks(urls: [root, tempDir]) { url in
            // `/` 伪装成内置盘（它本来就是内置卷），必须被跳过；临时目录照常列出。
            url.path == "/" ? self.description(deviceInternal: true) : self.description()
        }
        #expect(disks.count == 1, "内置卷被跳过时不能把后面的外置卷一起带走")
        #expect(disks.first?.mountPath == tempDir.path)
    }

    // MARK: - 胶水层：只做冒烟，不做断言主力

    /// 喂一个**不是磁盘**的路径，必须安全返回而不是崩。
    ///
    /// 这条刻意不依赖本机插了什么盘：注入的挂载点列表只有一个临时目录。
    ///
    /// ⚠️ **它实际走到哪里**（用 segment 计数核对过，别凭想象写注释）：
    /// `DADiskCreateFromVolumePath` 对临时目录**是会成功的** —— DiskArbitration 沿着路径
    /// 找到了它所在的那个卷（系统盘），并给出了描述。所以这条测试真的走了一遍
    /// **真实 DiskArbitration 查询 + 真实 `DiskClassifier` 判定**，最后靠「内置盘」被排除。
    ///
    /// 我原先的注释写的是「拿到 nil 描述、走跳过分支」—— **那是错的**，
    /// segment 计数显示 `DADiskCopyDescription` 的 `else` 分支 count 为 0。
    /// > **判据**：「测试通过」不等于「测试按你想的那条路通过」。**把实际执行路径量出来。**
    ///
    /// 它守的性质是：**不能把系统盘所在卷上的任意路径当成一块可推出的外置盘**。
    ///
    /// ⚠️ 断言里带**自证**：若 `DASessionCreate` 在这台机器上建不出来，函数会在第一步就
    /// 返回空数组 —— 那样这个测试会因为**别的原因**变绿。所以把「session 有没有建出来」
    /// 也断言掉，把「静默地没牙」换成一条明确的红字。
    @Test func 喂非磁盘路径时不崩且不列出() {
        let session = DASessionCreate(kCFAllocatorDefault)
        #expect(
            session != nil,
            "本机 DASessionCreate 建不出来 —— 这条冒烟测试无从谈起，先查环境（而不是让它假装通过）")

        let url = tempDir
        let disks = service.fetchExternalDisks(mountedVolumeURLs: { [url] })
        #expect(
            disks.isEmpty,
            "临时目录不是磁盘，不该被列成外置卷 —— 列出它就说明判定把系统盘所在卷放行了")
    }

    /// 生产用的默认挂载点来源：**它必须真的问系统要一次**，而不是被测试永久绕过。
    ///
    /// 前面所有测试都注入 `mountedVolumeURLs`（那是刻意的），代价是这段生产代码在单测里
    /// 一次都不执行 —— 覆盖率的死行判定会把它点出来。补这一条把它拉回：
    /// 断言「至少有一个挂载卷」，这是**任何一台 Mac 都成立**的性质，不依赖插了什么盘。
    ///
    /// > **判据**：**为可测性注入之后，别忘了给「生产默认实现」本身留一条测试。**
    /// > 否则你测的是你注入的那个假东西，真实那条路成了盲区。
    @Test func 默认挂载点来源能问出系统卷() {
        let urls = DiskService.liveMountedVolumeURLs()
        #expect(!urls.isEmpty, "系统盘总是挂载着的 —— 空列表说明这个查询坏了，而不是本机没插盘")
        #expect(
            urls.contains { $0.path == "/" },
            "根卷一定在挂载列表里；缺了它说明 mountedVolumeURLs 的参数用错了")
    }
}
