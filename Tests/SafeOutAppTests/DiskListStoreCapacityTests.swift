import Foundation
import Testing

@testable import SafeOutApp

/// 「只刷容量、不重枚举磁盘」这条轻量路径的守卫。
///
/// **为什么需要它**：`disks` 原来只在插拔事件里重建，于是拷贝几个 GB 之后，
/// 行上仍写着「已用 3.4 MB · 剩余 1.07 GB」，而旁边已经显示「正在写入 · 约 2.1 MB/s」——
/// 进度条一动不动，用户读到的是自相矛盾的两句话。
///
/// 而这条路径**必须**能被 `OccupancyStore` 认出来：只换数字的发布若也触发一轮 `lsof`，
/// 检测成本翻倍，还会让「正在写入」的速率采样落空、界面来回闪。所以这里同时钉住
/// ``DiskListStore/lastPublishWasCapacityOnly`` 的三种取值（容量 / 完整枚举 / 人工替换）。
@MainActor
struct DiskListStoreCapacityTests {

    /// 一块「数字可以随便写」的卷。真实容量由 `statfs` 决定，所以判据只比「有没有更新」。
    private func makeDisk(
        path: String,
        total: Int64 = 100_000_000_000,
        used: Int64 = 1,
        free: Int64? = nil
    ) -> DiskInfo {
        DiskInfo(
            id: path,
            bsdName: "disk9s1",
            volumeName: "容量测试卷",
            mountPath: path,
            totalBytes: total,
            usedBytes: used,
            freeBytes: free ?? (total - used),
            deviceProtocol: "USB",
            deviceModel: "TestModel"
        )
    }

    /// 造一个不挂系统监听、列表可手动灌入的 store。
    private func makeStore() -> DiskListStore {
        DiskListStore(monitoring: false)
    }

    /// 正常路径：真的读到了 `statfs`，数字更新、身份字段不变、并标记为「只换容量」。
    ///
    /// 用 `/` 这个**一定存在**的挂载点：这里验的是「有没有去读、读到后有没有换算」，
    /// 不是在验某块外置盘，所以用系统卷做锚最稳。
    @Test func 容量刷新会更新数字且标记为容量发布() throws {
        let store = makeStore()
        let path = "/"
        let realFree = try #require(VolumeWriteActivityDetector.availableBytes(atMountPath: path))
        // 总量必须比真实可用空间大，否则「已用 = 总量 − 可用」会被夹成 0，
        // 断言就分不清「换算没做」和「数字本来就不合理」。
        let total = realFree + 5_000_000_000
        store.replaceDisksForTesting([makeDisk(path: path, total: total, used: 1)])
        #expect(store.lastPublishWasCapacityOnly == false, "人工替换整条列表不是容量刷新")

        store.refreshCapacities()

        let disk = try #require(store.disks.first)
        #expect(disk.freeBytes == realFree, "可用空间必须换成 statfs 的实时读数")
        #expect(
            disk.usedBytes == total - realFree,
            "已用 = 总量 − 可用（与 DiskService 同口径）；停在旧值就说明换算没做")
        #expect(
            store.lastPublishWasCapacityOnly,
            "这次发布必须能被 OccupancyStore 认成「只换容量」——否则会白跑一轮 lsof")

        // 身份字段不许被容量刷新改写：它是「同一颗卷」的锚。
        #expect(disk.id == path)
        #expect(disk.bsdName == "disk9s1")
        #expect(disk.volumeName == "容量测试卷")
        #expect(disk.deviceModel == "TestModel")
    }

    /// 读不到容量（卷已卸载 / 路径失效）时**保留旧值、不发布**。
    ///
    /// 若此时发布一个「归零」的读数，界面会把一块不在的盘画成「空盘」；
    /// 换掉整条列表是挂载/卸载通知的职责，这条轻量路径只负责「数字要新鲜」。
    @Test func 读不到容量时保留旧值且不发布() throws {
        let store = makeStore()
        let path = "/Volumes/SafeOut-NoSuch-Volume-\(UUID().uuidString)"
        store.replaceDisksForTesting([makeDisk(path: path, total: 1000, used: 400, free: 600)])
        let before = store.disks

        store.refreshCapacities()

        #expect(store.disks == before, "读不到容量就必须原样保留，不能发布半截数据")
        #expect(
            store.lastPublishWasCapacityOnly == false,
            "什么都没改就不能打「容量发布」的标记——否则真有人改了列表也会被当成容量抖动")
    }

    /// 数字没变就**不发布**：闲着的机器上不该每 15s 白刷一次界面。
    @Test func 数字没变时不发布() throws {
        let store = makeStore()
        let path = "/"
        let realFree = try #require(VolumeWriteActivityDetector.availableBytes(atMountPath: path))
        let total = realFree + 5_000_000_000
        // 先把读数摆成「已经是实时的」，于是这一轮刷新应当无事可做。
        store.replaceDisksForTesting([
            makeDisk(path: path, total: total, used: total - realFree, free: realFree)
        ])
        #expect(store.lastPublishWasCapacityOnly == false)

        store.refreshCapacities()

        #expect(store.lastPublishWasCapacityOnly == false, "没有变化时不该打出容量发布的标记")
    }

    /// 完整枚举（`refresh()`）必须把标记复位成「不是容量发布」。
    ///
    /// 这一条是防回归的：若容量刷新留下的 `true` 一直不动，紧接着的一次**真正的**
    /// 列表变更就会被 `OccupancyStore` 误判成容量抖动 → 插上新盘却一直显示旧结论。
    @Test func 完整枚举会复位容量发布标记() async throws {
        let store = makeStore()
        let path = "/"
        store.replaceDisksForTesting([makeDisk(path: path, used: 1)])
        store.refreshCapacities()
        #expect(store.lastPublishWasCapacityOnly, "前置条件：这一轮确实是容量刷新")

        // 注入的枚举入口返回空列表：这里只关心「发布性质」，不关心列表内容。
        let empty = DiskListStore(fetch: { [] }, monitoring: false)
        await empty.refresh()
        #expect(
            empty.lastPublishWasCapacityOnly == false,
            "完整枚举之后必须复位，否则下一次真实变更会被当成容量抖动跳过检测")
    }
}
