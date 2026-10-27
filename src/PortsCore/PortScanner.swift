import CoreGraphics
import Foundation
import OSLog

public actor PortScanner {
    private var sampler = TransferSampler()
    private var details: [PortDevice] = []
    private var lastDetails: TimeInterval = -.infinity
    private var detailNotice: String?
    private let modelIdentifier: String
    private let identityNotice: String?
    private let logger = Logger(subsystem: "local.iports.app", category: "discovery")

    public init() {
        do {
            modelIdentifier = try MachineReader.identifier()
            identityNotice = nil
        } catch {
            modelIdentifier = "unknown"
            identityNotice = "读取 Mac 型号失败：\(error.localizedDescription)"
        }
    }

    public func resetSampling() { sampler.reset() }

    public func scan(forceDetails: Bool = false) async -> ScanSnapshot {
        guard !Task.isCancelled else { return ScanSnapshot(devices: []) }
        let capturedAt = Date()
        var registry = RegistryReader.read()
        let systemPower = SystemPowerReader.read()
        var machine = MachineInfo(identifier: modelIdentifier)
        if let identityNotice { registry.notices.append(identityNotice) }
        do { machine = try MachineReader.read(identifier: modelIdentifier) } catch {
            registry.notices.append("读取机身端口拓扑失败：\(error.localizedDescription)")
        }
        let now = ProcessInfo.processInfo.systemUptime
        let refreshDetails = forceDetails || now - lastDetails >= 30
        var bluetooth: [PortDevice] = []
        do {
            let data = try await ProfilerProcess.read(
                dataTypes: refreshDetails
                    ? ["SPBluetoothDataType", "SPThunderboltDataType", "SPDisplaysDataType"]
                    : ["SPBluetoothDataType"])
            do {
                bluetooth = try BluetoothParser.parse(data)
            } catch {
                registry.notices.append("蓝牙信息读取失败，本次不展示蓝牙设备：\(error.localizedDescription)")
                logger.error("Bluetooth report failed: \(error.localizedDescription, privacy: .public)")
            }
            if refreshDetails {
                var count: UInt32 = 0
                var builtInDisplayIDs = Set<String>()
                if CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 {
                    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
                    if CGGetOnlineDisplayList(count, &ids, &count) == .success {
                        builtInDisplayIDs = Set(
                            ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }.map(String.init))
                    }
                }
                do {
                    details = try ProfilerParser.parse(data, builtInDisplayIDs: builtInDisplayIDs)
                    detailNotice = nil
                } catch {
                    detailNotice = "雷雳 / 显示器信息读取失败，保留上次结果：\(error.localizedDescription)"
                    logger.error(
                        "Hardware profiler parsing failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch is CancellationError {
            return ScanSnapshot(devices: [])
        } catch {
            registry.notices.append("硬件信息读取失败，本次不更新蓝牙、雷雳和显示器设备：\(error.localizedDescription)")
            if refreshDetails {
                detailNotice = "雷雳 / 显示器信息读取失败，保留上次结果：\(error.localizedDescription)"
            }
            logger.error("Hardware profiler failed: \(error.localizedDescription, privacy: .public)")
        }
        if refreshDetails {
            lastDetails = ProcessInfo.processInfo.systemUptime
        }
        let rates = sampler.sample(registry.counters)
        for index in registry.devices.indices {
            registry.devices[index].transfer = rates[registry.devices[index].id]
        }
        if let detailNotice { registry.notices.append(detailNotice) }
        let all = (registry.devices + details + bluetooth).sorted {
            if $0.isPort != $1.isPort { return !$0.isPort }
            if $0.kind != $1.kind {
                return (DeviceKind.allCases.firstIndex(of: $0.kind) ?? 0)
                    < (DeviceKind.allCases.firstIndex(of: $1.kind) ?? 0)
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        // Treat duplicate identifiers from unusual profiler output as a single system entry.
        var seen = Set<String>()
        return ScanSnapshot(
            devices: all.filter { seen.insert($0.id).inserted }, capturedAt: capturedAt,
            notices: registry.notices, machine: machine, systemPower: systemPower)
    }
}

enum ProfilerProcess {
    static func read(dataTypes: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "-detailLevel", "full", "-timeout", "12"] + dataTypes
        process.environment = [
            "LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        return try await run(process)
    }

    static func run(_ process: Process) async throws -> Data {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try read(process: process)
        } onCancel: {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private static func read(process: Process) throws -> Data {
        let output = Pipe()
        process.standardOutput = output
        // A separate file avoids deadlocking on a full stderr pipe.
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "iports-\(UUID().uuidString).log")
        guard
            FileManager.default.createFile(
                atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: errorURL) }
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }
        process.standardError = errorHandle
        try Task.checkCancellation()
        try process.run()
        if Task.isCancelled, process.isRunning { process.terminate() }
        let terminate = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let kill = DispatchWorkItem {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: terminate)
        DispatchQueue.global().asyncAfter(deadline: .now() + 17, execute: kill)
        defer {
            terminate.cancel()
            kill.cancel()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let stderr = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw ProfilerError.failed(process.terminationStatus, String(stderr.prefix(300)))
        }
        return data
    }
}

private enum ProfilerError: LocalizedError {
    case failed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .failed(let code, let details): "system_profiler 超时或失败（\(code)）。\(details)"
        }
    }
}
