import Testing

@testable import SafeOutApp

/// 外置卷判定规则的回归测试。
///
/// **这组测试是安全底线**：判错会把系统盘或网络卷当成可推出的外置盘交给用户。
/// 规则之所以抽成 ``DiskClassifier`` 这个无依赖的纯函数，就是为了让这些场景
/// 能脱离 DiskArbitration 直接断言。
struct DiskClassifierTests {

    // MARK: - 工具

    private static func attrs(
        internal isInternal: Bool?,
        proto: String?,
        network: Bool? = false,
        ejectable: Bool? = false,
        mount: String? = "/Volumes/TEST"
    ) -> DiskClassifier.Attributes {
        DiskClassifier.Attributes(
            deviceInternal: isInternal, deviceProtocol: proto,
            isNetworkVolume: network, isEjectable: ejectable, mountPath: mount
        )
    }

    // MARK: - 物理外置设备

    /// 本机实测场景：SanDisk Extreme 55AE 4TB USB 外置硬盘。
    ///
    /// 关键事实是 `DAMediaRemovable = 0`、`DAMediaEjectable = 0`、
    /// `NSURLVolumeIsEjectableKey = false`——**「可移动」「可推出」两个信号对外置
    /// USB 硬盘都是 false**，唯一可靠的外置信号是 `DADeviceInternal = 0`。
    @Test func USB外置硬盘判定为外置() {
        // isEjectable 为 false 也必须判定为外置——这正是 USB 硬盘的实际情况
        #expect(DiskClassifier.isExternalVolume(Self.attrs(internal: false, proto: "USB")))
    }

    @Test func 雷电外置硬盘判定为外置() {
        #expect(DiskClassifier.isExternalVolume(Self.attrs(internal: false, proto: "Thunderbolt")))
    }

    /// 物理外置设备不受挂载点限制（不强制要求在 /Volumes 下）。
    @Test func 物理外置设备不受挂载点限制() {
        let attrs = Self.attrs(internal: false, proto: "USB", mount: "/Volumes/wenbo-data")
        #expect(DiskClassifier.isExternalVolume(attrs))
    }

    @Test func 内置盘一律排除() {
        for proto in ["SATA", "PCI-Express", "Apple Fabric"] {
            let attrs = Self.attrs(internal: true, proto: proto, mount: "/")
            #expect(!DiskClassifier.isExternalVolume(attrs), "内置盘(\(proto))不应被列入")
        }
    }

    // MARK: - 虚拟卷（磁盘映像）

    /// 磁盘映像实测属性：`DADeviceInternal` **不存在**（虚拟设备没有内部/外部概念），
    /// `DADeviceProtocol = Virtual Interface`，`DAMediaEjectable = 1`，`DAVolumeNetwork = 0`。
    ///
    /// 早期版本只依据 DADeviceInternal 判定，导致磁盘映像被漏掉。
    @Test func 挂载在Volumes下的磁盘映像判定为外置() {
        let attrs = Self.attrs(
            internal: nil, proto: "Virtual Interface",
            ejectable: true, mount: "/Volumes/EJECT-TEST"
        )
        #expect(DiskClassifier.isExternalVolume(attrs))
    }

    /// 实测踩过的坑：仅按「可推出」筛选虚拟卷时，Xcode 的 iOS 模拟器映像与 Apple 的
    /// cryptex 组件映像都会被收入列表，而推出它们会破坏 Xcode 与系统组件。
    /// 这些系统映像的挂载点都不在 /Volumes。
    @Test func 系统内部映像一律排除() {
        let systemImages = [
            "/Library/Developer/CoreSimulator/Volumes/iOS_22D8075",
            "/Library/Developer/CoreSimulator/Cryptex/Images/bundle/SimRuntimeBundle-XXXX",
            "/private/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain",
        ]
        for path in systemImages {
            let attrs = Self.attrs(
                internal: nil, proto: "Virtual Interface",
                ejectable: true, mount: path
            )
            #expect(!DiskClassifier.isExternalVolume(attrs), "\(path) 是系统映像，不应被列入")
        }
    }

    /// 虚拟卷但未标记可推出：不列入，避免把系统合成卷之类的东西交给用户。
    @Test func 虚拟卷但不可推出时排除() {
        let attrs = Self.attrs(internal: nil, proto: "Virtual Interface", ejectable: false)
        #expect(!DiskClassifier.isExternalVolume(attrs))
    }

    /// 虚拟卷缺少挂载点信息时不猜测。
    @Test func 虚拟卷缺少挂载路径时排除() {
        let attrs = Self.attrs(
            internal: nil, proto: "Virtual Interface",
            ejectable: true, mount: nil
        )
        #expect(!DiskClassifier.isExternalVolume(attrs))
    }

    /// 属性完全缺失时不猜测：宁可漏列，也不把性质不明的卷交给用户去「推出」。
    @Test func 属性全部缺失时排除() {
        #expect(!DiskClassifier.isExternalVolume(.empty))
    }

    // MARK: - 网络卷

    /// 网络卷在 DiskArbitration 里也常表现为「非内部设备」，但推出设备对它没有意义。
    @Test func 按DAVolumeNetwork标记的网络卷排除() {
        let attrs = Self.attrs(internal: false, proto: "SMB", network: true, ejectable: true)
        #expect(!DiskClassifier.isExternalVolume(attrs))
    }

    @Test func 按协议识别的网络卷排除() {
        for proto in ["SMB", "AFP", "NFS", "WebDAV", "FTP", "SFTP", "CIFS"] {
            let attrs = Self.attrs(internal: false, proto: proto, ejectable: true)
            #expect(
                !DiskClassifier.isExternalVolume(attrs),
                "\(proto) 网络卷不应被列为可推出磁盘"
            )
        }
    }

    /// 内置标记优先于一切：即使协议异常也不能放行。
    @Test func 内置标记优先于其他信号() {
        let attrs = Self.attrs(internal: true, proto: nil, ejectable: true)
        #expect(!DiskClassifier.isExternalVolume(attrs))
    }
}
