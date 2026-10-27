import Foundation
import XCTest

@testable import PortsCore
@testable import iPorts

private actor ControlledScanner: PortScanning {
    private(set) var calls = 0
    private(set) var cancelledCalls = 0
    private var pending: [Int: CheckedContinuation<ScanSnapshot, Never>] = [:]

    func resetSampling() {}

    func scan(forceDetails: Bool) async -> ScanSnapshot {
        calls += 1
        let index = calls
        let result = await withCheckedContinuation { pending[index] = $0 }
        if Task.isCancelled { cancelledCalls += 1 }
        return result
    }

    func finish(_ index: Int, with snapshot: ScanSnapshot) {
        pending.removeValue(forKey: index)?.resume(returning: snapshot)
    }

    func finishAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(returning: ScanSnapshot(devices: []))
        }
    }
}

private actor ControlledLiveSampler: LiveSampling {
    private(set) var calls = 0
    private(set) var resets = 0
    private var sessionSamples = 0
    private var holdFirst: Bool
    private var pending: CheckedContinuation<LiveMetricsSnapshot, Never>?

    init(holdFirst: Bool = false) { self.holdFirst = holdFirst }

    func resetSampling() {
        resets += 1
        sessionSamples = 0
    }

    func sample() async -> LiveMetricsSnapshot {
        calls += 1
        sessionSamples += 1
        let sampleNumber = sessionSamples
        if holdFirst {
            holdFirst = false
            return await withCheckedContinuation { pending = $0 }
        }
        return Self.metrics(sampleNumber)
    }

    func finishHeldSample() {
        pending?.resume(returning: Self.metrics(999))
        pending = nil
    }

    private static func metrics(_ sample: Int) -> LiveMetricsSnapshot {
        let wifi = PortDevice(
            id: "wifi:en1", kind: .wifi, name: "Wi-Fi", subtitle: "已连接无线网络",
            connection: "864 Mb/s", isPort: true,
            transfer: sample == 1
                ? nil
                : TransferRate(
                    readBytesPerSecond: Double(sample), writeBytesPerSecond: Double(sample * 2)),
            linkActive: true)
        return LiveMetricsSnapshot(
            networkDevices: [wifi], systemPower: SystemPowerReading(systemWatts: Double(sample)))
    }
}

final class MonitoringTests: XCTestCase {
    @MainActor
    private func fixture(
        scanner: ControlledScanner, live: ControlledLiveSampler, interval: Duration = .milliseconds(15)
    ) throws -> (PortStore, UserDefaults, String) {
        let domain = "local.iports.monitoring-tests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
        let store = PortStore(
            snapshot: ScanSnapshot(devices: [], machine: MachineInfo(identifier: "Mac14,12")),
            preferences: preferences, scanner: scanner, liveSampler: live,
            liveInterval: interval, discoveryInterval: .seconds(60))
        return (store, preferences, domain)
    }

    @MainActor
    private func waitUntil(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line)
        async throws
    {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Monitoring condition timed out", file: file, line: line)
    }

    @MainActor
    func testLiveNetworkAndPowerUpdateWhileDiscoveryIsBlockedAndStopWhenHidden() async throws {
        let scanner = ControlledScanner()
        let live = ControlledLiveSampler()
        let (store, preferences, domain) = try fixture(scanner: scanner, live: live)
        defer {
            store.setVisible(false)
            preferences.removePersistentDomain(forName: domain)
        }
        store.setVisible(true)
        try await waitUntil { store.snapshot.systemPower?.systemWatts ?? 0 >= 3 }
        XCTAssertTrue(store.isRefreshing)
        XCTAssertNotNil(store.snapshot.devices.first?.transfer)
        store.setVisible(false)
        let capturedAt = store.snapshot.capturedAt
        let calls = await live.calls
        try await Task.sleep(for: .milliseconds(80))
        let callsAfterClose = await live.calls
        XCTAssertEqual(callsAfterClose, calls)
        XCTAssertEqual(store.snapshot.capturedAt, capturedAt)
        XCTAssertFalse(store.isRefreshing)
        await scanner.finishAll()
    }

    @MainActor
    func testReopeningResetsBaselineAndRejectsPreviousSessionsLateSample() async throws {
        let scanner = ControlledScanner()
        let live = ControlledLiveSampler(holdFirst: true)
        let (store, preferences, domain) = try fixture(scanner: scanner, live: live, interval: .seconds(60))
        defer {
            store.setVisible(false)
            preferences.removePersistentDomain(forName: domain)
        }
        store.setVisible(true)
        try await waitUntil { await live.calls == 1 }
        store.setVisible(false)
        store.setVisible(true)
        XCTAssertNil(store.snapshot.systemPower)
        XCTAssertTrue(store.snapshot.devices.allSatisfy { $0.transfer == nil })
        try await waitUntil { store.snapshot.systemPower?.systemWatts == 1 }
        await live.finishHeldSample()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.snapshot.systemPower?.systemWatts, 1)
        XCTAssertNil(store.snapshot.devices.first?.transfer)
        let resets = await live.resets
        XCTAssertEqual(resets, 2)
        store.setVisible(false)
        await scanner.finishAll()
    }

    @MainActor
    func testSlowDiscoveryCannotOverwriteNewerLiveValues() async throws {
        let scanner = ControlledScanner()
        let live = ControlledLiveSampler()
        let (store, preferences, domain) = try fixture(scanner: scanner, live: live)
        defer {
            store.setVisible(false)
            preferences.removePersistentDomain(forName: domain)
        }
        store.setVisible(true)
        try await waitUntil { store.snapshot.systemPower?.systemWatts ?? 0 >= 2 }
        let usb = PortDevice(id: "usb", kind: .usb, name: "Dock", subtitle: "USB", connection: "5 Gb/s")
        let oldNetwork = PortDevice(id: "old", kind: .network, name: "Old", subtitle: "", connection: "")
        await scanner.finish(
            1,
            with: ScanSnapshot(
                devices: [usb, oldNetwork], capturedAt: .distantPast,
                machine: MachineInfo(identifier: "Mac14,12"),
                systemPower: SystemPowerReading(systemWatts: 999)))
        try await waitUntil { store.snapshot.devices.contains { $0.id == "usb" } }
        XCTAssertEqual(store.snapshot.devices.filter { $0.kind.isNetwork }.map(\.id), ["wifi:en1"])
        XCTAssertLessThan(store.snapshot.systemPower?.systemWatts ?? 999, 999)
        XCTAssertNotNil(store.snapshot.devices.first { $0.id == "wifi:en1" }?.transfer)
        store.setVisible(false)
        await scanner.finishAll()
    }

    @MainActor
    func testVisibilityChangesAreIdempotentAndHiddenRefreshDoesNotReadHardware() async throws {
        let scanner = ControlledScanner()
        let live = ControlledLiveSampler()
        let (store, preferences, domain) = try fixture(scanner: scanner, live: live)
        defer {
            store.setVisible(false)
            preferences.removePersistentDomain(forName: domain)
        }
        await store.refresh(forceDetails: true)
        let initialScans = await scanner.calls
        let initialSamples = await live.calls
        XCTAssertEqual(initialScans, 0)
        XCTAssertEqual(initialSamples, 0)
        store.setVisible(true)
        store.setVisible(true)
        try await waitUntil { await live.calls >= 2 }
        let resets = await live.resets
        let scans = await scanner.calls
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(scans, 1)
        store.setVisible(false)
        store.setVisible(false)
        await store.refresh(forceDetails: true)
        let finalScans = await scanner.calls
        XCTAssertEqual(finalScans, scans)
        await scanner.finishAll()
    }

    @MainActor
    func testClosingAlsoCancelsManualRefreshAndDiscardsItsLateResult() async throws {
        let scanner = ControlledScanner()
        let live = ControlledLiveSampler()
        let (store, preferences, domain) = try fixture(scanner: scanner, live: live)
        defer {
            store.setVisible(false)
            preferences.removePersistentDomain(forName: domain)
        }
        store.setVisible(true)
        try await waitUntil { await scanner.calls == 1 }
        await scanner.finish(1, with: ScanSnapshot(devices: [], machine: MachineInfo(identifier: "Mac14,12")))
        try await waitUntil { !store.isRefreshing }
        let manual = Task { await store.refresh(forceDetails: true) }
        try await waitUntil { await scanner.calls == 2 }
        store.setVisible(false)
        let capturedAt = store.snapshot.capturedAt
        let stale = PortDevice(
            id: "late", kind: .usb, name: "Late result", subtitle: "USB", connection: "USB")
        await scanner.finish(2, with: ScanSnapshot(devices: [stale]))
        await manual.value
        XCTAssertEqual(store.snapshot.capturedAt, capturedAt)
        XCTAssertFalse(store.snapshot.devices.contains { $0.id == "late" })
        let cancellations = await scanner.cancelledCalls
        XCTAssertGreaterThanOrEqual(cancellations, 1)
        await scanner.finishAll()
    }

    @MainActor
    func testGlobalPowerViewWorksWithoutPhysicalPowerPortAndDeviceSelectionReturnsToDetails() throws {
        let device = PortDevice(id: "wifi", kind: .wifi, name: "Wi-Fi", subtitle: "", connection: "")
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "local.iports.tests.power-selection"))
        defer { preferences.removePersistentDomain(forName: "local.iports.tests.power-selection") }
        let store = PortStore(
            snapshot: ScanSnapshot(devices: [device], machine: MachineInfo(identifier: "Mac999,99")),
            preferences: preferences)
        store.selectSystemPower()
        XCTAssertTrue(store.showsSystemPower)
        XCTAssertNil(store.selected)
        XCTAssertNil(store.selectedConnection)
        XCTAssertNil(store.highlightedPortID)
        store.selectDevice(device)
        XCTAssertFalse(store.showsSystemPower)
        XCTAssertEqual(store.selected?.id, device.id)
    }
}
