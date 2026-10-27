import Foundation

public enum PortSide: String, Codable, CaseIterable, Sendable {
    case left, right, front, rear, top, adapter

    public var title: String {
        switch self {
        case .left: "左侧"
        case .right: "右侧"
        case .front: "正面"
        case .rear: "背面"
        case .top: "顶部"
        case .adapter: "电源适配器"
        }
    }
}

public struct CustomLayoutPort: Codable, Identifiable, Sendable {
    public let id: String
    public var side: PortSide
    public let connector: PortConnector

    public init(id: String = UUID().uuidString, side: PortSide, connector: PortConnector) {
        self.id = id
        self.side = side
        self.connector = connector
    }
}

public struct CustomPortLayout: Codable, Sendable {
    public var version = 1
    public var ports: [CustomLayoutPort]

    public init(ports: [CustomLayoutPort]) { self.ports = ports }

    public var isValid: Bool {
        version == 1 && ports.count <= 64 && Set(ports.map(\.id)).count == ports.count
            && ports.allSatisfy { !$0.id.isEmpty && $0.id.count <= 100 }
    }

    public static func from(_ profile: MacModelProfile) -> CustomPortLayout {
        let ports = profile.diagrams.flatMap { diagram -> [CustomLayoutPort] in
            guard let side = PortSide(rawValue: diagram.id) else { return [] }
            return diagram.ports.filter { !$0.isLogical }.map {
                CustomLayoutPort(side: side, connector: $0.connector)
            }
        }
        return CustomPortLayout(ports: ports)
    }
}

public enum UniversalPortLayout {
    public static func profile(
        machine: MachineInfo, devices: [PortDevice], official: OfficialMacModel?,
        custom: CustomPortLayout? = nil
    ) -> MacModelProfile {
        let family = official?.family ?? .unknown
        let specification = official.flatMap { Self.specification(for: machine.identifier, model: $0) }
        var diagrams: [ModelDiagram] = []
        if let custom, custom.isValid {
            for side in PortSide.allCases {
                let entries = custom.ports.filter { $0.side == side }
                if !entries.isEmpty { diagrams.append(diagram(side: side, entries: entries)) }
            }
        } else if let specification {
            for (side, connectors) in specification {
                let entries = connectors.enumerated().map {
                    CustomLayoutPort(
                        id: "\(side.rawValue).\($0.element.rawValue).\($0.offset)", side: side,
                        connector: $0.element)
                }
                diagrams.append(diagram(side: side, entries: entries))
            }
        }
        // Logical roots remain usable even when firmware exposes no physical connector positions.
        var logical: [(String, PortConnector)] = []
        var seen = Set<String>()
        for connector in machine.connectors where seen.insert(connector.route.key).inserted {
            logical.append((connector.route.key, connector.route.connector))
        }
        for device in devices where !device.isInternal && !device.kind.isWireless {
            let key = PortMapper.calibrationKey(for: device, devices: devices)
            if seen.insert(key).inserted {
                logical.append(
                    (key, PortMapper.resolvedRoute(for: device, devices: devices)?.connector ?? .unknown))
            }
        }
        let logicalPorts = logical.sorted { $0.0 < $1.0 }.enumerated().map { index, entry in
            ModelPort(
                id: "logical:\(entry.0)", label: "\(entry.1.shortLabel) \(index + 1)",
                title: "系统拓扑 · \(entry.1.shortLabel) \(index + 1)", connector: entry.1, x: 0, y: 0,
                locationTokens: [], routeKey: entry.0)
        }
        diagrams.append(
            ModelDiagram(
                id: "topology", title: "系统拓扑", crop: ImageCrop(x: 0, y: 0, width: 1, height: 1),
                ports: logicalPorts, isSchematic: true))
        let description =
            custom != nil
            ? "自定义机身布局 · 按实际插孔校准"
            : specification != nil
                ? "机身端口示意 · 同侧顺序可编辑校准"
                : "系统拓扑示意 · 物理位置未确定，可编辑布局"
        return MacModelProfile(
            id: "universal:\(machine.identifier):\(official?.id ?? "unknown")",
            identifiers: [machine.identifier],
            name: official?.name ?? "Mac · \(machine.identifier)", imageName: official?.imageName ?? "",
            imageURL: official?.imageURL ?? MacFamily.unknown.sourceURL,
            sourceURL: official?.sourceURL ?? MacFamily.unknown.sourceURL,
            diagrams: diagrams, supportsNumberedRearPorts: false, family: family, officialModel: official,
            layoutDescription: description
        )
    }

    private static func diagram(side: PortSide, entries: [CustomLayoutPort]) -> ModelDiagram {
        var counts: [PortConnector: Int] = [:]
        let ports = entries.map { entry in
            counts[entry.connector, default: 0] += 1
            let number = counts[entry.connector, default: 1]
            // A single connector of its type has an unambiguous side; repeated ports need calibration.
            let unique = entries.filter { $0.connector == entry.connector }.count == 1
            return ModelPort(
                id: "slot:\(entry.id)", label: "\(entry.connector.shortLabel) \(number)",
                title: "\(side.title) · \(entry.connector.title) \(number)", connector: entry.connector, x: 0,
                y: 0,
                locationTokens: unique
                    ? [side.rawValue, "\(side.rawValue)-middle", "\(side.rawValue)-center"] : [])
        }
        return ModelDiagram(
            id: side.rawValue, title: side.title, crop: ImageCrop(x: 0, y: 0, width: 1, height: 1),
            ports: ports, isSchematic: true)
    }

    private static func specification(for id: String, model: OfficialMacModel) -> [(
        PortSide, [PortConnector]
    )]? {
        let name = model.name
        switch model.family {
        case .macBookAir:
            if ["Mac14,2", "Mac14,15", "Mac15,12", "Mac15,13", "Mac16,12", "Mac16,13", "Mac17,3", "Mac17,4"]
                .contains(id)
            {
                return [(.left, [.power, .usbC, .usbC]), (.right, [.audio])]
            }
            if ["MacBookAir8,1", "MacBookAir8,2", "MacBookAir9,1", "MacBookAir10,1"].contains(id) {
                return [(.left, [.usbC, .usbC]), (.right, [.audio])]
            }
        case .macBookPro:
            let modern = [
                "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4", "Mac14,5", "Mac14,6",
                "Mac14,9", "Mac14,10", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
                "Mac16,1", "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8", "Mac17,2", "Mac17,6", "Mac17,7",
                "Mac17,8", "Mac17,9",
            ]
            if modern.contains(id) {
                return [(.left, [.power, .usbC, .usbC, .audio]), (.right, [.sd, .usbC, .hdmi])]
            }
            if id == "Mac15,3" { return [(.left, [.power, .usbC, .usbC, .audio]), (.right, [.sd, .hdmi])] }
            if ["MacBookPro17,1", "Mac14,7"].contains(id) || name.contains("Two Thunderbolt 3 ports") {
                return [(.left, [.usbC, .usbC]), (.right, [.audio])]
            }
            if name.contains("Four Thunderbolt 3 ports")
                || [
                    "MacBookPro13,3", "MacBookPro14,3", "MacBookPro15,1", "MacBookPro15,3", "MacBookPro16,1",
                    "MacBookPro16,4",
                ].contains(id)
            {
                return [(.left, [.usbC, .usbC]), (.right, [.usbC, .usbC, .audio])]
            }
        case .macBook:
            if ["MacBook8,1", "MacBook9,1", "MacBook10,1"].contains(id) {
                return [(.left, [.usbC]), (.right, [.audio])]
            }
        case .macStudio:
            if ["Mac13,1", "Mac13,2", "Mac14,13", "Mac14,14", "Mac15,14", "Mac16,9", "Mac17,14", "Mac17,15"]
                .contains(id)
            {
                return [
                    (.front, [.usbC, .usbC, .sd]),
                    (.rear, [.usbC, .usbC, .usbC, .usbC, .ethernet, .power, .usbA, .usbA, .hdmi, .audio]),
                ]
            }
        case .iMac:
            if ["iMac21,1", "Mac15,5", "Mac16,3"].contains(id) {
                return [
                    (.rear, [.usbC, .usbC, .usbC, .usbC, .power]), (.left, [.audio]), (.adapter, [.ethernet]),
                ]
            }
            if ["iMac21,2", "Mac15,4", "Mac16,2"].contains(id) {
                return [(.rear, [.usbC, .usbC, .power]), (.left, [.audio])]
            }
            if id == "iMacPro1,1" {
                return [
                    (
                        .rear,
                        [
                            .audio, .sd, .usbA, .usbA, .usbA, .usbA, .usbC, .usbC, .usbC, .usbC, .ethernet,
                            .power,
                        ]
                    )
                ]
            }
            if ["iMac18,1", "iMac18,2", "iMac18,3", "iMac19,1", "iMac19,2", "iMac20,1", "iMac20,2"].contains(
                id)
            {
                return [(.rear, [.audio, .sd, .usbA, .usbA, .usbA, .usbA, .usbC, .usbC, .ethernet, .power])]
            }
        case .macMini:
            if id == "Macmini8,1" {
                return [
                    (.rear, [.power, .ethernet, .usbC, .usbC, .usbC, .usbC, .hdmi, .usbA, .usbA, .audio])
                ]
            }
        case .macPro:
            if id == "Mac14,8" {
                return [
                    (name.contains("Rack") ? .front : .top, [.usbC, .usbC]),
                    (
                        .rear,
                        [
                            .usbC, .usbC, .usbC, .usbC, .usbC, .usbC, .usbA, .usbA, .hdmi, .hdmi, .ethernet,
                            .ethernet, .audio, .power,
                        ]
                    ),
                ]
            }
            if id == "MacPro7,1" {
                return [
                    (name.contains("Rack") ? .front : .top, [.usbC, .usbC]),
                    (.rear, [.usbC, .usbC, .usbA, .usbA, .ethernet, .ethernet, .audio, .power]),
                ]
            }
        case .unknown: break
        }
        return nil
    }
}
