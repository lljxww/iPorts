import Foundation

public struct LiveMetricsSnapshot: Codable, Sendable {
    public let networkDevices: [PortDevice]
    public let systemPower: SystemPowerReading
    public let capturedAt: Date
    public let notices: [String]

    public init(
        networkDevices: [PortDevice], systemPower: SystemPowerReading,
        capturedAt: Date = Date(), notices: [String] = []
    ) {
        self.networkDevices = networkDevices
        self.systemPower = systemPower
        self.capturedAt = capturedAt
        self.notices = notices
    }
}

public actor LiveMetricsReader {
    private var sampler = TransferSampler()

    public init() {}

    public func resetSampling() { sampler.reset() }

    public func sample() -> LiveMetricsSnapshot {
        var network = RegistrySnapshot()
        do { network = try NetworkReader.read() } catch {
            network.notices.append("实时网速读取失败：\(error.localizedDescription)")
        }
        let activeIDs = Set(network.devices.filter { $0.linkActive == true }.map(\.id))
        let rates = sampler.sample(network.counters.filter { activeIDs.contains($0.key) })
        for index in network.devices.indices {
            network.devices[index].transfer = rates[network.devices[index].id]
        }
        return LiveMetricsSnapshot(
            networkDevices: network.devices, systemPower: SystemPowerReader.read(), notices: network.notices)
    }
}

extension ScanSnapshot {
    public func updatingLiveMetrics(_ live: LiveMetricsSnapshot) -> ScanSnapshot {
        ScanSnapshot(
            devices: devices.filter { !$0.kind.isNetwork } + live.networkDevices,
            capturedAt: live.capturedAt, notices: notices, machine: machine, systemPower: live.systemPower)
    }

    public func resettingLiveMetrics() -> ScanSnapshot {
        var devices = devices
        for index in devices.indices { devices[index].transfer = nil }
        return ScanSnapshot(devices: devices, capturedAt: capturedAt, notices: notices, machine: machine)
    }
}
