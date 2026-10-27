import CoreFoundation
import Foundation
import IOKit

public struct SystemPowerReading: Codable, Sendable {
    public let systemWatts: Double?
    public let inputWatts: Double?
    public let externalConnected: Bool?
    public let sampledAt: Date
    public let unavailableReason: String?

    public init(
        systemWatts: Double?, inputWatts: Double? = nil, externalConnected: Bool? = nil,
        sampledAt: Date = Date(), unavailableReason: String? = nil
    ) {
        self.systemWatts = systemWatts
        self.inputWatts = inputWatts
        self.externalConnected = externalConnected
        self.sampledAt = sampledAt
        self.unavailableReason = unavailableReason
    }

    public var report: String {
        [
            "iPorts · 整机功率（系统遥测）",
            "整机负载：\(systemWatts.map { String(format: "%.2f W", $0) } ?? "系统未提供")",
            "外部电源输入：\(inputWatts.map { String(format: "%.2f W", $0) } ?? "系统未提供")",
            "数据来源：AppleSmartBattery / PowerTelemetryData",
            "整机负载来自 SystemLoad；外部输入来自 SystemPowerIn，可能包含电池充电。均非插座实测功率。",
            unavailableReason ?? "固件报告值；刷新频率与精度取决于机型和系统。",
        ].joined(separator: "\n")
    }
}

enum SystemPowerReader {
    static func read() -> SystemPowerReading {
        do {
            let entries = try Registry.entries(matching: "AppleSmartBattery")
            defer { for entry in entries { IOObjectRelease(entry) } }
            guard let entry = entries.first else {
                return SystemPowerReading(systemWatts: nil, unavailableReason: "此机型未提供可读取的整机功率遥测。")
            }
            // Read only the needed properties; do not open an SMC user client or poll a privileged tool.
            let telemetry =
                IORegistryEntryCreateCFProperty(
                    entry, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? [String: Any]
            let external =
                IORegistryEntryCreateCFProperty(
                    entry, "ExternalConnected" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? Bool
            return parse(telemetry, externalConnected: external)
        } catch {
            return SystemPowerReading(
                systemWatts: nil, unavailableReason: "整机功率读取失败：\(error.localizedDescription)")
        }
    }

    static func parse(_ telemetry: [String: Any]?, externalConnected: Bool?) -> SystemPowerReading {
        let system = watts(telemetry?["SystemLoad"])
        return SystemPowerReading(
            systemWatts: system,
            inputWatts: externalConnected == true ? watts(telemetry?["SystemPowerIn"]) : nil,
            externalConnected: externalConnected,
            unavailableReason: system == nil ? "系统未提供有效的整机负载遥测；不以充电器额定功率或电池功率替代。" : nil)
    }

    private static func watts(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let milliwatts = number.doubleValue
        // Firmware fields are not a stable API. Reject malformed values, including unsigned error sentinels.
        guard milliwatts.isFinite, milliwatts >= 0, milliwatts <= 10_000_000 else { return nil }
        return milliwatts / 1_000
    }
}
