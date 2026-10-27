import Foundation

public enum PortConnector: String, Codable, CaseIterable, Sendable {
    case usbC = "usb-c"
    case usbA = "usb-a"
    case hdmi, ethernet, audio, power
    case usb, thunderbolt, thunderbolt2, displayPort, miniDisplayPort, sd, firewire, dvi, vga, unknown

    public var title: String {
        switch self {
        case .usbC: "USB-C / 雷雳"
        case .usbA: "USB-A"
        case .hdmi: "HDMI"
        case .ethernet: "以太网"
        case .audio: "音频"
        case .power: "电源 / MagSafe"
        case .usb: "USB（接口类型未确定）"
        case .thunderbolt: "雷雳（接口类型未确定）"
        case .thunderbolt2: "Thunderbolt 1 / 2"
        case .displayPort: "DisplayPort"
        case .miniDisplayPort: "Mini DisplayPort"
        case .sd: "SD / SDXC"
        case .firewire: "FireWire"
        case .dvi: "DVI"
        case .vga: "VGA"
        case .unknown: "未确定接口"
        }
    }

    public var shortLabel: String {
        switch self {
        case .usbC: "USB-C"
        case .usbA: "USB-A"
        case .power: "电源"
        case .thunderbolt2: "TB 1/2"
        case .miniDisplayPort: "Mini DP"
        case .displayPort: "DP"
        case .usb: "USB"
        case .thunderbolt: "雷雳"
        case .unknown: "待定位"
        default: title
        }
    }
}

public struct PortRoute: Codable, Equatable, Sendable {
    public let connector: PortConnector
    public let number: Int
    public let topologyPath: String?
    public var key: String {
        topologyPath.map { "\(connector.rawValue):path:\($0)" } ?? "\(connector.rawValue):\(number)"
    }

    public init(connector: PortConnector, number: Int, topologyPath: String? = nil) {
        self.connector = connector
        self.number = number
        self.topologyPath = topologyPath
    }
}

public struct ConnectorObservation: Codable, Sendable {
    public let route: PortRoute
    public let location: String?
    public let activeTransports: [String]
    public let hasDisplaySignal: Bool

    public init(
        route: PortRoute, location: String? = nil, activeTransports: [String] = [],
        hasDisplaySignal: Bool = false
    ) {
        self.route = route
        self.location = location
        self.activeTransports = activeTransports
        self.hasDisplaySignal = hasDisplaySignal
    }
}

public struct MachineInfo: Codable, Sendable {
    public let identifier: String
    public let connectors: [ConnectorObservation]
    public var profile: MacModelProfile? { MacModelCatalog.profile(for: identifier) }
    public var displayName: String { profile?.name ?? identifier }

    public init(identifier: String, connectors: [ConnectorObservation] = []) {
        self.identifier = identifier
        self.connectors = connectors
    }
}

public struct ImageCrop: Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct ModelPort: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let title: String
    public let connector: PortConnector
    public let x: Double
    public let y: Double
    public let locationTokens: [String]
    public var routeKey: String? = nil
    public var isLogical: Bool { routeKey != nil }
}

public struct ModelDiagram: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let crop: ImageCrop
    public let ports: [ModelPort]
    public var isSchematic: Bool = false
}

public struct MacModelProfile: Identifiable, Sendable {
    public let id: String
    public let identifiers: [String]
    public let name: String
    public let imageName: String
    public let imageURL: URL
    public let sourceURL: URL
    public let diagrams: [ModelDiagram]
    public let supportsNumberedRearPorts: Bool
    public var family: MacFamily = .macMini
    public var officialModel: OfficialMacModel? = nil
    public var layoutDescription: String = "机身照片 · 插孔位置"
    public var ports: [ModelPort] { diagrams.flatMap(\.ports) }
}

public enum MacModelCatalog {
    public static func profile(for identifier: String) -> MacModelProfile? {
        if let profile = profiles.first(where: { $0.identifiers.contains(identifier) }) { return profile }
        guard let official = AppleMacCatalog.models(for: identifier).first else { return nil }
        return UniversalPortLayout.profile(
            machine: MachineInfo(identifier: identifier), devices: [], official: official)
    }

    public static func artworkURL(for profile: MacModelProfile) -> URL? {
        guard !profile.imageName.isEmpty else { return nil }
        // Packaged apps carry the resource bundle in Contents/Resources; SwiftPM also supports CLI runs.
        return AppleMacCatalog.resourceURL(
            name: profile.imageName, extension: "png", directory: "ModelArtwork")
            ?? AppleMacCatalog.cachedArtworkURL(name: profile.imageName)
    }

    public static func resolvedProfile(
        machine: MachineInfo, devices: [PortDevice], records: [OfficialMacModel] = AppleMacCatalog.bundled,
        variantID: String? = nil, customLayout: CustomPortLayout? = nil
    ) -> MacModelProfile {
        let variants = AppleMacCatalog.models(for: machine.identifier, in: records)
        let official = variants.first { $0.id == variantID } ?? variants.first
        if customLayout == nil,
            var verified = profiles.first(where: { $0.identifiers.contains(machine.identifier) })
        {
            verified.officialModel = official
            return verified
        }
        return UniversalPortLayout.profile(
            machine: machine, devices: devices, official: official, custom: customLayout)
    }

    public static let profiles: [MacModelProfile] = [
        mini2023(pro: true), mini2023(pro: false), miniM1(), mini2024(),
    ]

    private static func port(
        _ id: String, _ label: String, _ title: String, _ connector: PortConnector,
        _ x: Double, _ y: Double = 0.40, locations: [String] = []
    ) -> ModelPort {
        ModelPort(
            id: id, label: label, title: title, connector: connector, x: x, y: y, locationTokens: locations)
    }

    private static func make(
        id: String, identifiers: [String], name: String, image: String,
        diagrams: [ModelDiagram], numbered: Bool = true
    ) -> MacModelProfile {
        // These fixed URLs are part of the reviewed catalog, not constructed from device identifiers.
        guard let source = URL(string: "https://support.apple.com/en-us/102852"),
            let url = URL(string: "https://cdsassets.apple.com/live/7WUAS350/images/mac-mini/\(image).png")
        else { preconditionFailure("Invalid bundled Apple artwork URL") }
        return MacModelProfile(
            id: id, identifiers: identifiers, name: name, imageName: image, imageURL: url,
            sourceURL: source, diagrams: diagrams, supportsNumberedRearPorts: numbered
        )
    }

    private static func mini2023(pro: Bool) -> MacModelProfile {
        var ports = [
            port("rear.power.1", "电源", "电源接口", .power, 0.145),
            port("rear.ethernet.1", "网口", "背面 · 以太网", .ethernet, 0.243),
        ]
        let xs = pro ? [0.329, 0.407, 0.484, 0.562] : [0.407, 0.484]
        let locations =
            pro
            ? ["back-left", "back-left-middle", "back-right-middle", "back-right"]
            : ["back-left", "back-right"]
        for (index, x) in xs.enumerated() {
            ports.append(
                port(
                    "rear.usb-c.\(index + 1)", "C\(index + 1)", "背面 · USB-C / 雷雳 \(index + 1)", .usbC, x,
                    locations: [locations[index]]))
        }
        ports += [
            port("rear.hdmi.1", "HDMI", "背面 · HDMI", .hdmi, pro ? 0.653 : 0.576),
            port("rear.usb-a.1", "A1", "背面 · USB-A 1", .usbA, 0.755),
            port("rear.usb-a.2", "A2", "背面 · USB-A 2", .usbA, 0.848),
            port("rear.audio.1", "耳机", "背面 · 3.5 mm 耳机", .audio, 0.803, 0.72),
        ]
        return make(
            id: pro ? "mini-m2-pro" : "mini-m2", identifiers: [pro ? "Mac14,12" : "Mac14,3"],
            name: pro ? "Mac mini · M2 Pro（2023）" : "Mac mini · M2（2023）",
            image: pro ? "mac-mini-2023-m2-pro" : "mac-mini-2023-m2",
            diagrams: [
                ModelDiagram(
                    id: "rear", title: "背面 · 正视", crop: ImageCrop(x: 620, y: 98, width: 580, height: 96),
                    ports: ports)
            ]
        )
    }

    private static func miniM1() -> MacModelProfile {
        let ports = [
            port("rear.power.1", "电源", "电源接口", .power, 0.149),
            port("rear.ethernet.1", "网口", "背面 · 以太网", .ethernet, 0.246),
            port("rear.usb-c.1", "C1", "背面 · USB-C / 雷雳 1", .usbC, 0.410, locations: ["back-left"]),
            port("rear.usb-c.2", "C2", "背面 · USB-C / 雷雳 2", .usbC, 0.488, locations: ["back-right"]),
            port("rear.hdmi.1", "HDMI", "背面 · HDMI", .hdmi, 0.579),
            port("rear.usb-a.1", "A1", "背面 · USB-A 1", .usbA, 0.759),
            port("rear.usb-a.2", "A2", "背面 · USB-A 2", .usbA, 0.852),
            port("rear.audio.1", "耳机", "背面 · 3.5 mm 耳机", .audio, 0.807, 0.72),
        ]
        return make(
            id: "mini-m1", identifiers: ["Macmini9,1"], name: "Mac mini · M1（2020）",
            image: "mac-mini-2020-m1",
            diagrams: [
                ModelDiagram(
                    id: "rear", title: "背面 · 正视", crop: ImageCrop(x: 620, y: 98, width: 580, height: 96),
                    ports: ports)
            ]
        )
    }

    private static func mini2024() -> MacModelProfile {
        let front = [
            port("front.usb-c.1", "前 C1", "正面 · USB-C 1", .usbC, 0.208, 0.405, locations: ["front-left"]),
            port("front.usb-c.2", "前 C2", "正面 · USB-C 2", .usbC, 0.326, 0.405, locations: ["front-right"]),
            port("front.audio.1", "耳机", "正面 · 3.5 mm 耳机", .audio, 0.787, 0.405),
        ]
        let rear = [
            port("rear.power.1", "电源", "电源接口", .power, 0.245, 0.405),
            port("rear.ethernet.1", "网口", "背面 · 以太网", .ethernet, 0.421, 0.405),
            port("rear.hdmi.1", "HDMI", "背面 · HDMI", .hdmi, 0.571, 0.405),
            port("rear.usb-c.1", "C1", "背面 · USB-C / 雷雳 1", .usbC, 0.687, 0.405, locations: ["back-left"]),
            port(
                "rear.usb-c.2", "C2", "背面 · USB-C / 雷雳 2", .usbC, 0.755, 0.405,
                locations: ["back-middle", "back-center"]),
            port("rear.usb-c.3", "C3", "背面 · USB-C / 雷雳 3", .usbC, 0.824, 0.405, locations: ["back-right"]),
        ]
        return make(
            id: "mini-2024", identifiers: ["Mac16,10", "Mac16,11"], name: "Mac mini（2024）",
            image: "mac-mini-2024",
            diagrams: [
                ModelDiagram(
                    id: "rear", title: "背面 · 正视", crop: ImageCrop(x: 420, y: 50, width: 380, height: 84),
                    ports: rear),
                ModelDiagram(
                    id: "front", title: "正面 · 正视", crop: ImageCrop(x: 0, y: 50, width: 380, height: 84),
                    ports: front),
            ], numbered: false
        )
    }
}
