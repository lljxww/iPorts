import Foundation

public enum DeviceKind: String, CaseIterable, Codable, Sendable {
    case usb, thunderbolt, display, storage, network, wifi, bluetooth

    public var isWireless: Bool { self == .wifi || self == .bluetooth }
    public var isNetwork: Bool { self == .network || self == .wifi }

    public var title: String {
        switch self {
        case .usb: "USB"
        case .thunderbolt: "雷雳 / USB4"
        case .display: "显示器"
        case .storage: "存储"
        case .network: "有线网络"
        case .wifi: "无线网络"
        case .bluetooth: "蓝牙"
        }
    }

    public var symbol: String {
        switch self {
        case .usb: "cable.connector"
        case .thunderbolt: "bolt.horizontal"
        case .display: "display"
        case .storage: "externaldrive"
        case .network: "network"
        case .wifi: "wifi"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        }
    }
}

public struct DeviceField: Identifiable, Codable, Hashable, Sendable {
    public var id: String { group + ":" + label }
    public let group: String
    public let label: String
    public let value: String

    public init(_ group: String, _ label: String, _ value: String) {
        self.group = group
        self.label = label
        self.value = value
    }
}

public struct PowerBudget: Codable, Equatable, Sendable {
    public let milliamps: Double
    public var watts: Double { milliamps * 5 / 1_000 }
    public var formatted: String { String(format: "%.2f W", watts) }

    public init?(milliamps: Double) {
        guard milliamps.isFinite, milliamps >= 0 else { return nil }
        self.milliamps = milliamps
    }
}

public struct TransferRate: Codable, Equatable, Sendable {
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double
    public var isActive: Bool { readBytesPerSecond > 0 || writeBytesPerSecond > 0 }
}

public struct DiskIdentity: Codable, Equatable, Sendable {
    public let bsdName: String
    public let registryID: UInt64
    public let isInternal: Bool?
    public let isWhole: Bool
    public let isPhysical: Bool

    public init(bsdName: String, registryID: UInt64, isInternal: Bool?, isWhole: Bool, isPhysical: Bool) {
        self.bsdName = bsdName
        self.registryID = registryID
        self.isInternal = isInternal
        self.isWhole = isWhole
        self.isPhysical = isPhysical
    }

    public var canEject: Bool {
        isInternal == false && isWhole && isPhysical && registryID != 0
            && bsdName.range(of: #"\Adisk[0-9]+\z"#, options: .regularExpression) != nil
    }

    public func matchesForEjection(_ current: DiskIdentity) -> Bool {
        canEject && current.canEject && self == current
    }
}

public struct PortDevice: Identifiable, Codable, Sendable {
    public let id: String
    public let kind: DeviceKind
    public let name: String
    public let subtitle: String
    public let connection: String
    public let isInternal: Bool
    public let isPort: Bool
    public let parentID: String?
    public let fields: [DeviceField]
    public let power: PowerBudget?
    public var transfer: TransferRate?
    public let disk: DiskIdentity?
    public let route: PortRoute?
    public let linkActive: Bool?

    public init(
        id: String, kind: DeviceKind, name: String, subtitle: String, connection: String,
        isInternal: Bool = false, isPort: Bool = false, parentID: String? = nil,
        fields: [DeviceField] = [], power: PowerBudget? = nil,
        transfer: TransferRate? = nil, disk: DiskIdentity? = nil,
        route: PortRoute? = nil, linkActive: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.subtitle = subtitle
        self.connection = connection
        self.isInternal = isInternal
        self.isPort = isPort
        self.parentID = parentID
        self.fields = fields
        self.power = power
        self.transfer = transfer
        self.disk = disk
        self.route = route
        self.linkActive = linkActive
    }

    public var report: String {
        var lines = ["iPorts · \(name)", "类型: \(kind.title)", "连接: \(connection)"]
        lines += fields.map { "\($0.group) / \($0.label): \($0.value)" }
        if let transfer {
            lines.append(
                "\(kind.isNetwork ? "网络接收" : "磁盘读取"): \(PortFormatting.rate(transfer.readBytesPerSecond))")
            lines.append(
                "\(kind.isNetwork ? "网络发送" : "磁盘写入"): \(PortFormatting.rate(transfer.writeBytesPerSecond))")
        }
        if kind == .bluetooth {
            lines.append("蓝牙设备的实时功耗与传输速率：系统未提供。")
        } else if kind == .wifi {
            lines.append("Wi-Fi 链路速率并非实际吞吐量；接口流量并非互联网测速。实时耗电：系统未提供。")
        } else {
            lines.append("实时功耗: 系统未提供；分配功率不代表实测耗电。")
        }
        return lines.joined(separator: "\n")
    }
}

public struct ScanSnapshot: Codable, Sendable {
    public let devices: [PortDevice]
    public let capturedAt: Date
    public let notices: [String]
    public let machine: MachineInfo?
    public let systemPower: SystemPowerReading?

    public init(
        devices: [PortDevice], capturedAt: Date = Date(), notices: [String] = [], machine: MachineInfo? = nil,
        systemPower: SystemPowerReading? = nil
    ) {
        self.devices = devices
        self.capturedAt = capturedAt
        self.notices = notices
        self.machine = machine
        self.systemPower = systemPower
    }
}

public enum PortFormatting {
    public static func rate(_ bytes: Double) -> String {
        guard bytes.isFinite, bytes >= 0 else { return "不可读取" }
        if bytes < 1_000 { return String(format: "%.0f B/s", bytes) }
        if bytes < 1_000_000 { return String(format: "%.1f KB/s", bytes / 1_000) }
        if bytes < 1_000_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        return String(format: "%.2f GB/s", bytes / 1_000_000_000)
    }

    public static func linkSpeed(bits: UInt64?, code: Int?) -> String {
        if let bits, bits > 0 {
            if bits >= 1_000_000_000 { return String(format: "%g Gb/s", Double(bits) / 1_000_000_000) }
            return String(format: "%g Mb/s", Double(bits) / 1_000_000)
        }
        switch code {
        case 1: return "12 Mb/s"
        case 2: return "1.5 Mb/s"
        case 3: return "480 Mb/s"
        case 4: return "5 Gb/s"
        case 5: return "10 Gb/s"
        case 6: return "20 Gb/s"
        default: return "系统未提供"
        }
    }

    public static func usbClass(_ code: Int) -> String {
        switch code {
        case 0: "复合设备"
        case 1: "音频设备"
        case 2, 10: "通信设备"
        case 3: "人机接口 (HID)"
        case 6: "影像设备"
        case 7: "打印机"
        case 8: "大容量存储"
        case 9: "USB 集线器"
        case 14: "视频设备"
        case 17: "Billboard / 显示转接"
        case 224: "无线控制器"
        case 239: "复合设备"
        case 255: "厂商自定义"
        default: String(format: "设备类别 0x%02X", code)
        }
    }
}
