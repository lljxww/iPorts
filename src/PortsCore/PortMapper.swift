import Foundation

public enum MappingConfidence: String, Codable, Sendable {
    case system, inferred, manual, topology

    public var title: String {
        switch self {
        case .system: "系统拓扑"
        case .inferred: "推断位置"
        case .manual: "手动校准"
        case .topology: "拓扑接口 · 未定位"
        }
    }
}

public struct PortAssociation: Codable, Sendable {
    public let portID: String
    public let confidence: MappingConfidence
    public let explanation: String
    public let calibrationKey: String
}

public enum PortMapper {
    public static func resolvedRoute(for device: PortDevice, devices: [PortDevice]) -> PortRoute? {
        var current = device
        var seen = Set<String>()
        while seen.insert(current.id).inserted {
            if let route = current.route { return route }
            guard let id = current.parentID, let parent = devices.first(where: { $0.id == id }) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    public static func calibrationKey(for device: PortDevice, devices: [PortDevice]) -> String {
        guard let route = resolvedRoute(for: device, devices: devices) else { return "session:\(device.id)" }
        // Profiler receptacle numbers have not been directly joined to IOPort identities.
        return device.kind == .thunderbolt ? "thunderbolt:\(route.key)" : route.key
    }

    public static func compatiblePorts(
        for device: PortDevice, profile: MacModelProfile, devices: [PortDevice]
    ) -> [ModelPort] {
        guard !device.kind.isWireless else { return [] }
        return profile.ports.filter { port in
            guard !port.isLogical else { return false }
            if port.connector == .unknown { return true }
            if let route = resolvedRoute(for: device, devices: devices) {
                switch route.connector {
                case .usb: return [.usbC, .usbA, .usb].contains(port.connector)
                case .thunderbolt: return [.usbC, .thunderbolt2, .thunderbolt].contains(port.connector)
                default: return port.connector == route.connector
                }
            }
            switch device.kind {
            case .display:
                return [.usbC, .hdmi, .displayPort, .miniDisplayPort, .dvi, .vga, .thunderbolt2].contains(
                    port.connector)
            case .thunderbolt: return [.usbC, .thunderbolt2, .thunderbolt].contains(port.connector)
            case .usb: return [.usbC, .usbA, .usb].contains(port.connector)
            case .storage:
                return [.usbC, .usbA, .usb, .sd, .thunderbolt2, .firewire].contains(port.connector)
            case .network:
                return port.connector == .ethernet || port.connector == .usbC || port.connector == .usbA
            case .bluetooth, .wifi: return false
            }
        }
    }

    public static func associations(
        devices: [PortDevice], machine: MachineInfo, overrides: [String: String] = [:],
        profile suppliedProfile: MacModelProfile? = nil
    ) -> [String: PortAssociation] {
        guard let profile = suppliedProfile ?? machine.profile else { return [:] }
        var result: [String: PortAssociation] = [:]
        for device in devices where !device.isInternal && !device.kind.isWireless {
            let key = calibrationKey(for: device, devices: devices)
            if let override = overrides[key],
                compatiblePorts(for: device, profile: profile, devices: devices).contains(where: {
                    $0.id == override
                })
            {
                result[device.id] = PortAssociation(
                    portID: override, confidence: .manual,
                    explanation: key.hasPrefix("session:")
                        ? "此设备位置仅在本次运行中校准。" : "已按此机型的系统端口保存位置校准；同一端口下的设备共享此位置。",
                    calibrationKey: key
                )
                continue
            }
            if let route = resolvedRoute(for: device, devices: devices),
                let mapped = match(route: route, machine: machine, profile: profile)
            {
                let numberedThunderbolt = device.kind == .thunderbolt
                result[device.id] = PortAssociation(
                    portID: mapped.id, confidence: numberedThunderbolt ? .inferred : mapped.confidence,
                    explanation: numberedThunderbolt
                        ? "根据系统报告的雷雳接口编号关联到同号机身端口；编号与 IOPort 未直接核对，可手动校准。" : mapped.explanation,
                    calibrationKey: key
                )
                continue
            }
            // One display and one active video connector is useful evidence, but not an identity match.
            let displays = devices.filter { $0.kind == .display && !$0.isInternal }
            let video = machine.connectors.filter(\.hasDisplaySignal)
            if device.kind == .display, displays.count == 1, video.count == 1,
                let mapped = match(route: video[0].route, machine: machine, profile: profile)
            {
                result[device.id] = PortAssociation(
                    portID: mapped.id, confidence: .inferred,
                    explanation: "当前仅一台外接显示器，且系统仅报告此接口有视频信号；未直接核对显示器身份，可手动校准。",
                    calibrationKey: key
                )
                continue
            }
            if let logical = profile.ports.first(where: { $0.routeKey == key }) {
                result[device.id] = PortAssociation(
                    portID: logical.id, confidence: .topology,
                    explanation: "按系统根端口或设备条目展示连接关系，尚未确定机身插孔。编辑布局后，可将此设备校准到实际位置。",
                    calibrationKey: key)
            }
        }
        return result
    }

    private static func match(
        route: PortRoute, machine: MachineInfo, profile: MacModelProfile
    ) -> (id: String, confidence: MappingConfidence, explanation: String)? {
        let candidates = profile.ports.filter {
            !$0.isLogical
                && ($0.connector == route.connector
                    || route.connector == .thunderbolt && [.usbC, .thunderbolt2].contains($0.connector))
        }
        let observation = machine.connectors.first {
            $0.route == route
                || route.connector == .thunderbolt && $0.route.connector == .usbC
                    && $0.route.number == route.number
        }
        if let location = observation?.location {
            let matches = candidates.filter { $0.locationTokens.contains(location) }
            guard matches.count == 1 else { return nil }
            return (
                matches[0].id, .system, "设备关联到系统 IOPort \(route.key)，固件位置为 \(location)。图上方向以正视机身照片为准，必要时可校准。"
            )
        }
        if route.connector == .ethernet || route.connector == .hdmi, candidates.count == 1 {
            return (candidates[0].id, .system, "系统关联到机身 \(route.connector.rawValue) 端口；此机型只有一个此类接口。")
        }
        if profile.supportsNumberedRearPorts, [.usbA, .usbC, .thunderbolt].contains(route.connector) {
            let connector = route.connector == .thunderbolt ? PortConnector.usbC : route.connector
            let id = "rear.\(connector.rawValue).\(route.number)"
            if candidates.contains(where: { $0.id == id }) {
                return (id, .inferred, "根据系统端口编号 \(route.key) 和此机型的接口排列推断；系统未报告物理位置，请按实际插孔校准。")
            }
        }
        return nil
    }
}
