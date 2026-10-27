import Darwin
import Foundation
import IOKit

enum MachineReader {
    static func identifier() throws -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func read(identifier: String) throws -> MachineInfo {
        var locations: [Int: String] = [:]
        let hpms = try Registry.entries(matching: "AppleHPMBusDevice")
        defer { for entry in hpms { IOObjectRelease(entry) } }
        for entry in hpms {
            let p = Registry.properties(entry)
            if let number = integer(p["port-number"]), let location = text(p["port-location"]) {
                locations[number] = location
            }
        }
        let ports = try Registry.entries(matching: "IOPort")
        defer { for entry in ports { IOObjectRelease(entry) } }
        var observations: [ConnectorObservation] = []
        var seen = Set<String>()
        for entry in ports {
            let p = Registry.properties(entry)
            guard let route = route(properties: p), seen.insert(route.key).inserted else { continue }
            let transports = p["TransportsActive"] as? [String] ?? []
            observations.append(
                ConnectorObservation(
                    route: route, location: route.connector == .usbC ? locations[route.number] : nil,
                    activeTransports: transports,
                    hasDisplaySignal: transports.contains("DisplayPort") || p["HPDAsserted"] as? Bool == true
                        || p["HDMI_HPD"] as? Bool == true
                ))
        }
        return MachineInfo(
            identifier: identifier, connectors: observations.sorted { $0.route.key < $1.route.key })
    }

    static func route(properties: [String: Any]) -> PortRoute? {
        guard properties["BuiltIn"] as? Bool == true,
            let number = integer(properties["PortNumber"]), number > 0,
            let type = properties["PortTypeDescription"] as? String
        else { return nil }
        let connector: PortConnector
        switch type {
        case "USB-C": connector = .usbC
        case "USB-A": connector = .usbA
        case "HDMI": connector = .hdmi
        default: return nil
        }
        return PortRoute(connector: connector, number: number)
    }

    static func route(at path: String) -> PortRoute? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return route(properties: Registry.properties(entry))
    }

    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        guard let data = value as? Data, data.count == 4 else { return nil }
        return data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
    }

    private static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let data = value as? Data else { return nil }
        return String(bytes: data.prefix { $0 != 0 }, encoding: .utf8)
    }
}
