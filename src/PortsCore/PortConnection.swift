import Foundation

public struct ConnectionLink: Hashable, Sendable {
    public let protocolName: String
    public let speed: String?
    public var description: String {
        if let speed, !speed.isEmpty, speed != "系统未提供", speed != "已连接" {
            return "\(protocolName) · \(speed)"
        }
        return protocolName
    }
}

public struct PortConnection: Identifiable, Sendable {
    public let id: String
    public let portID: String?
    public let devices: [PortDevice]
    public let capabilities: [PortDevice]
    public let links: [ConnectionLink]
    public let capabilityLocationInferred: Bool

    public var primary: PortDevice? {
        let roots = devices.filter { item in !devices.contains { $0.id == item.parentID } }
        if let thunderbolt = roots.first(where: { $0.kind == .thunderbolt }) { return thunderbolt }
        if let hub = roots.first(where: {
            $0.kind == .usb && $0.fields.contains { $0.label == "设备类型" && $0.value.contains("集线器") }
        }) {
            return hub
        }
        if let display = devices.first(where: { $0.kind == .display }) { return display }
        if let disk = devices.first(where: { $0.kind == .storage }) { return disk }
        return roots.first ?? devices.first
    }

    public var isInternal: Bool { devices.first?.isInternal ?? false }
    public var isConnected: Bool {
        devices.contains { $0.kind.isNetwork ? $0.linkActive == true : !$0.isPort }
    }
    public var connectionDescription: String {
        links.isEmpty ? "未观察到连接" : links.map(\.description).joined(separator: "；")
    }

    public var report: String {
        var sections = [
            primary?.kind.isWireless == true ? "iPorts · 无线连接" : "iPorts · 端口连接",
            "当前连接方式 / 协议：\(connectionDescription)",
        ]
        sections += devices.map(\.report)
        if !capabilities.isEmpty {
            sections.append("端口能力与通道信息（不代表当前连接协议）：")
            sections += capabilities.map { item in
                ([item.name] + item.fields.map { "\($0.label)：\($0.value)" }).joined(separator: "\n")
            }
        }
        return sections.joined(separator: "\n\n")
    }
}

public enum PortConnectionBuilder {
    public static func build(
        devices: [PortDevice], machine: MachineInfo?, profile: MacModelProfile?,
        associations: [String: PortAssociation]
    ) -> [PortConnection] {
        var seenIDs = Set<String>()
        let ports = profile?.ports ?? []
        var grouped: [String: [PortDevice]] = [:]
        var portIDs: [String: String] = [:]
        var order: [String] = []

        for device in devices where seenIDs.insert(device.id).inserted {
            let association = associations[device.id]
            let port = ports.first { $0.id == association?.portID }
            let key: String
            if device.kind.isWireless {
                key = "wireless:\(device.id)"
            } else if let port, !port.isLogical {
                key = "physical:\(port.id)"
            } else {
                // USB and Thunderbolt numbers are separate namespaces; join them only after physical mapping.
                let root = rootDevice(for: device, in: devices)
                let routeKey = PortMapper.calibrationKey(for: root, devices: devices)
                key = routeKey.hasPrefix("session:") ? "device:\(root.id)" : "route:\(routeKey)"
            }
            let groupID = device.isInternal ? "internal:\(key)" : key
            if grouped[groupID] == nil { order.append(groupID) }
            grouped[groupID, default: []].append(device)
            if let port, !device.kind.isWireless { portIDs[groupID] = port.id }
        }

        return order.compactMap { id in
            guard let records = grouped[id] else { return nil }
            let attached = records.filter { !($0.kind == .thunderbolt && $0.isPort) }
            let capabilities = records.filter { $0.kind == .thunderbolt && $0.isPort }
            let portID = portIDs[id]
            let port = ports.first { $0.id == portID }
            let roots = attached.filter { item in !attached.contains { $0.id == item.parentID } }
            let linkSources = roots.isEmpty ? attached : roots
            var seen = Set<ConnectionLink>()
            let links = linkSources.compactMap { item -> ConnectionLink? in
                let link = link(for: item, port: port, machine: machine)
                return seen.insert(link).inserted ? link : nil
            }
            return PortConnection(
                id: id, portID: portID, devices: attached, capabilities: capabilities, links: links,
                capabilityLocationInferred: capabilities.contains {
                    associations[$0.id]?.confidence == .inferred
                })
        }
    }

    private static func rootDevice(for device: PortDevice, in devices: [PortDevice]) -> PortDevice {
        var current = device
        var visited: [PortDevice] = []
        while !visited.contains(where: { $0.id == current.id }) {
            visited.append(current)
            guard
                let parent = devices.first(where: {
                    $0.id == current.parentID && $0.isInternal == current.isInternal
                })
            else { return current }
            current = parent
        }
        return visited.min { $0.id < $1.id } ?? device
    }

    private static func link(for device: PortDevice, port: ModelPort?, machine: MachineInfo?)
        -> ConnectionLink
    {
        switch device.kind {
        case .usb:
            let speed = device.connection
            let name: String
            if ["5 Gb/s", "10 Gb/s", "20 Gb/s"].contains(speed) {
                name = "USB 3"
            } else if speed == "480 Mb/s" {
                name = "USB 2"
            } else {
                name = "USB"
            }
            return ConnectionLink(protocolName: name, speed: speed)
        case .thunderbolt:
            return ConnectionLink(protocolName: "Thunderbolt / USB4", speed: device.connection)
        case .display:
            let name: String
            if port?.connector == .hdmi || device.route?.connector == .hdmi {
                name = "HDMI"
            } else if port?.connector == .usbC,
                machine?.connectors.contains(where: {
                    $0.hasDisplaySignal && $0.route.connector == .usbC
                        && port?.locationTokens.contains($0.location ?? "") == true
                }) == true
            {
                name = "DisplayPort"
            } else {
                name = port?.connector == .displayPort ? "DisplayPort" : "显示输出"
            }
            return ConnectionLink(protocolName: name, speed: nil)
        case .network:
            return ConnectionLink(protocolName: "以太网", speed: device.connection)
        case .wifi:
            let reported = device.fields.first { $0.label == "当前协议" }?.value
            let protocolName = reported.flatMap { $0 == "系统未提供" || $0.isEmpty ? nil : $0 } ?? "Wi-Fi"
            return ConnectionLink(
                protocolName: protocolName, speed: device.linkActive == true ? device.connection : nil)
        case .storage:
            return ConnectionLink(protocolName: device.connection, speed: nil)
        case .bluetooth:
            return ConnectionLink(protocolName: device.connection, speed: nil)
        }
    }
}
