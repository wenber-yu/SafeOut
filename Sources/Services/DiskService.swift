import DiskArbitration
import Foundation
import OSLog

/// 外置卷枚举。
///
/// **为什么从「路径前缀判断」换成 DiskArbitration**：
///
/// 旧实现用 `volumeURL.path.hasPrefix("/Volumes")` 判断外置，这在语义上是用「挂载位置」
/// 猜测「设备属性」。挂载位置是系统的安排，不是设备的属性——网络卷、磁盘映像、
/// 部分系统合成卷都会出现在 `/Volumes` 下，而内置盘在未来系统版本里的挂载位置也可能变化。
///
/// DiskArbitration 提供的是设备自身声明的属性，是 macOS 上判断「这块盘能不能拔」的
/// 事实来源（Finder 同样基于它）。实测在 App Sandbox 下 `DADiskCopyDescription` 可正常读取，
/// 因此在受沙盒限制的运行环境下枚举依然成立（本应用不发布沙盒构建，这条只是说明它不依赖沙盒外能力）。
///
/// ## 为什么这个类被拆成「薄胶水 + 纯函数」两层
///
/// 原先整条枚举路径（问挂载点 → 建 `DASession` → 逐卷取 DA 描述 → 判定 → 组装）写在一个
/// 函数体里，于是**单测里一行都跑不到** —— 它要求本机真的插着一块外置盘。
/// 2026-09-17 的覆盖率取证（`DESIGN-SPEC.md` §8.30）把这条依赖暴露了出来：
/// 那 77 行「覆盖率」其实是从生产单例蹭来的**假覆盖**。
///
/// 现在拆成三层：
///
/// | 层 | 内容 | 怎么测 |
/// |---|---|---|
/// | **胶水** | `DASessionCreate` / `DADiskCreateFromVolumePath` | 只能真机（`IntegrationEjectTests` 自挂 dmg） |
/// | **判定 + 折叠** | `assembleDisks` / `classifyAndBuild` | **纯函数**，喂假描述字典即可 |
/// | **组装** | `makeDiskInfo(url:values:description:)` | **纯函数**，喂构造出的 `URLResourceValues` |
///
/// > **判据**：**「测不到」通常不是「不可测」，而是「依赖写死在函数体里」。**
/// > 把碰系统的那几行挤到最外层的胶水里，中间那层自然就成了纯函数。
class DiskService: @unchecked Sendable {
    static let shared = DiskService()

    /// 开放给测试注入 mock 子类；生产环境一律使用 `shared`。
    init() {}

    private static let logger = Logger(subsystem: "com.safeout.app", category: "DiskService")

    /// 枚举当前所有外置可推出卷。
    ///
    /// 该调用涉及磁盘 I/O 与 DiskArbitration 查询，**应在后台线程执行**，不要在主线程调用
    /// （菜单栏每次展开都会触发，主线程卡顿会直接表现为菜单展开迟滞）。
    ///
    /// - Parameter mountedVolumeURLs: 挂载点列表的来源。默认问系统；测试注入空列表或一个
    ///   假路径，就能在**不插任何盘**的前提下把这条路径走到收尾。
    func fetchExternalDisks(
        mountedVolumeURLs: @Sendable () -> [URL] = DiskService.liveMountedVolumeURLs
    ) -> [DiskInfo] {
        let urls = mountedVolumeURLs()

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            Self.logger.error("无法创建 DASession，本次不返回任何磁盘")
            return []
        }

        // 这一段是**唯一**碰 DiskArbitration 的地方：把 URL 换成描述字典。
        // 拿到描述之后的全部判断都在 `assembleDisks` 里，而那部分是纯的、可测的。
        return assembleDisks(urls: urls) { url in
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                let description = DADiskCopyDescription(disk) as? [String: Any]
            else { return nil }
            return description
        }
    }

    /// 生产实现：问系统要挂载点。
    ///
    /// 抽成 `static` 函数（而不是写在 `fetchExternalDisks` 里）是为了能被当作默认参数注入。
    static func liveMountedVolumeURLs() -> [URL] {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
    }

    /// **纯折叠**：把「卷 URL 列表」＋「取描述的办法」折成 `DiskInfo` 列表。
    ///
    /// 三个「不列这块盘」的分支全在这里，且都能用假数据走到：
    ///
    /// 1. **取不到 DiskArbitration 描述** —— 宁可漏列，也不能把性质不明的卷当成外置盘
    ///    交给用户去「推出」；
    /// 2. **`DiskClassifier` 判定为非外置可推出**（内置盘 / 网络卷 / 系统映像）；
    /// 3. **组装失败**（容量读不到）。
    ///
    /// - Parameter description: 返回 `nil` 表示该卷没有 DA 描述。
    func assembleDisks(
        urls: [URL],
        description: (URL) -> [String: Any]?
    ) -> [DiskInfo] {
        var disks: [DiskInfo] = []
        for url in urls {
            guard let description = description(url) else {
                Self.logger.debug("卷缺少 DiskArbitration 描述，跳过: \(url.path, privacy: .public)")
                continue
            }
            guard let info = classifyAndBuild(url: url, description: description) else {
                continue
            }
            disks.append(info)
        }
        return disks
    }

    /// **纯判定 + 组装**：给定卷 URL 与其 DiskArbitration 描述，判断是否外置可推出并组装。
    ///
    /// 返回 `nil` 的两种原因调用方不需要区分（都是「不列这块盘」）：
    /// 判定为不可推出，或容量读不到。
    func classifyAndBuild(url: URL, description: [String: Any]) -> DiskInfo? {
        let attributes = DiskClassifier.Attributes(
            deviceInternal: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool,
            deviceProtocol: description[kDADiskDescriptionDeviceProtocolKey as String] as? String,
            isNetworkVolume: description[kDADiskDescriptionVolumeNetworkKey as String] as? Bool,
            isEjectable: description[kDADiskDescriptionMediaEjectableKey as String] as? Bool,
            mountPath: url.path
        )

        guard DiskClassifier.isExternalVolume(attributes) else {
            return nil
        }

        return makeDiskInfo(url: url, description: description)
    }

    /// 从卷 URL 与 DiskArbitration 描述组装 `DiskInfo`；容量信息缺失时返回 `nil`。
    ///
    /// **对测试开放（`internal` 而非 `private`）**：它是**纯组装**，不碰 DASession、
    /// 不做 I/O 之外的事，只要喂一个 URL 与一个描述字典就能验。
    ///
    /// 这一点是被一次覆盖率事故逼出来的：2026-09-17 发现 `DiskService` 的那 77 行
    /// **从来不是被单测覆盖的** —— 是「某个测试构造了 `ContentView` → 摸到生产单例
    /// → 本机恰好插着盘」蹭来的（见 `DESIGN-SPEC.md` §8.28.6）。
    /// 把那条暗道堵掉之后它诚实地掉到 0%，`DiskServiceTests` 就是补上的那一块。
    ///
    /// ⚠️ 这里有两处**静默退化**值得单独守住：`bsdName` 在描述缺 key 时会回退成
    /// `url.lastPathComponent`（把卷名当设备名用），容量缺失时整块盘被跳过。
    /// 两者都不会报错，只会让界面少一块盘或显示错一个设备名。
    func makeDiskInfo(url: URL, description: [String: Any]) -> DiskInfo? {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
            ])
        } catch {
            Self.logger.warning(
                "读取卷容量失败，跳过 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        return Self.makeDiskInfo(
            url: url,
            totalCapacity: values.volumeTotalCapacity,
            availableCapacity: values.volumeAvailableCapacity,
            volumeName: values.volumeName,
            description: description
        )
    }

    /// **纯组装**：从容量、卷名与描述字典拼 `DiskInfo`；容量缺失时返回 `nil`。
    ///
    /// 参数刻意收成 `Int?` / `String?` 而**不是** `URLResourceValues`：后者的属性是**只读**的，
    /// 只能由 `URL.resourceValues(forKeys:)` 产生，于是「容量缺失」「卷名缺失」这两条
    /// **静默退化**就永远没法用构造出来的值去验 —— 那正是它们最该被测的地方。
    ///
    /// > **判据**：纯函数依赖**基础类型**才真的可测；一旦形参是一个「只能由 I/O 产生」的
    /// > 框架类型，可测性就在签名上丢掉了，哪怕函数体里一行 I/O 都没有。
    static func makeDiskInfo(
        url: URL,
        totalCapacity: Int?,
        availableCapacity: Int?,
        volumeName: String?,
        description: [String: Any]
    ) -> DiskInfo? {
        guard let totalCapacity, let availableCapacity else {
            return nil
        }

        let volumeName = volumeName ?? ""
        let bsdName =
            (description[kDADiskDescriptionMediaBSDNameKey as String] as? String)
            ?? url.lastPathComponent
        let deviceModel = description[kDADiskDescriptionDeviceModelKey as String] as? String

        return DiskInfo(
            id: url.path,
            bsdName: bsdName,
            volumeName: volumeName,
            mountPath: url.path,
            totalBytes: Int64(totalCapacity),
            usedBytes: Int64(totalCapacity - availableCapacity),
            freeBytes: Int64(availableCapacity),
            deviceProtocol: description[kDADiskDescriptionDeviceProtocolKey as String] as? String,
            deviceModel: deviceModel
        )
    }
}
