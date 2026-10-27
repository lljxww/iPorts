import Foundation
import XCTest

@testable import PortsCore

final class SystemPowerTests: XCTestCase {
    func testTelemetryConvertsMilliwattsAndSeparatesInputFromSystemLoad() throws {
        let reading = SystemPowerReader.parse(
            ["SystemLoad": 10_406, "SystemPowerIn": 30_000], externalConnected: true)
        XCTAssertEqual(reading.systemWatts, 10.406)
        XCTAssertEqual(reading.inputWatts, 30)
        XCTAssertNil(reading.unavailableReason)
        XCTAssertTrue(reading.report.contains("可能包含电池充电"))
        XCTAssertTrue(reading.report.contains("非插座实测"))
        XCTAssertEqual(SystemPowerReader.parse(["SystemLoad": 0], externalConnected: false).systemWatts, 0)
    }

    func testDisconnectedAndUnknownExternalPowerSuppressStaleInput() {
        for connected in [false, nil] {
            let reading = SystemPowerReader.parse(
                ["SystemLoad": 12_000, "SystemPowerIn": 100_000], externalConnected: connected)
            XCTAssertEqual(reading.systemWatts, 12)
            XCTAssertNil(reading.inputWatts)
        }
    }

    func testMalformedAndMissingTelemetryDoesNotBecomeZeroOrAdapterRating() {
        let invalid: [Any] = [-1, Double.nan, Double.infinity, UInt64.max, true, "12000"]
        for value in invalid {
            let reading = SystemPowerReader.parse(
                ["SystemLoad": value, "SystemPowerIn": value], externalConnected: true)
            XCTAssertNil(reading.systemWatts)
            XCTAssertNil(reading.inputWatts)
            XCTAssertNotNil(reading.unavailableReason)
        }
        for telemetry in [nil, [:], ["Watts": 140], ["SystemPowerIn": 30_000], ["BatteryPower": 10_000]] {
            XCTAssertNil(SystemPowerReader.parse(telemetry, externalConnected: true).systemWatts)
        }
    }

    func testOldSnapshotsDecodeWithoutPowerAndNewSnapshotsRoundTrip() throws {
        let old = Data(#"{"devices":[],"capturedAt":0,"notices":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ScanSnapshot.self, from: old).systemPower)
        let snapshot = ScanSnapshot(
            devices: [], systemPower: SystemPowerReader.parse(["SystemLoad": 12_500], externalConnected: true)
        )
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(
            try JSONDecoder().decode(ScanSnapshot.self, from: encoded).systemPower?.systemWatts, 12.5)
    }

    func testLiveMetricsReplaceOnlyNetworksAndPreservePhysicalDevicesAndNotices() {
        let usb = PortDevice(id: "usb", kind: .usb, name: "Dock", subtitle: "USB", connection: "5 Gb/s")
        let old = PortDevice(id: "wifi:en0", kind: .wifi, name: "Old", subtitle: "", connection: "")
        let wifi = PortDevice(
            id: "wifi:en1", kind: .wifi, name: "Wi-Fi", subtitle: "", connection: "864 Mb/s",
            transfer: TransferRate(readBytesPerSecond: 10_000, writeBytesPerSecond: 20_000), linkActive: true)
        let snapshot = ScanSnapshot(
            devices: [usb, old], notices: ["Discovery notice"], machine: MachineInfo(identifier: "Mac14,12"))
        let live = LiveMetricsSnapshot(
            networkDevices: [wifi], systemPower: SystemPowerReading(systemWatts: 10))
        let updated = snapshot.updatingLiveMetrics(live)
        XCTAssertEqual(updated.devices.map(\.id), [usb.id, wifi.id])
        XCTAssertEqual(updated.machine?.identifier, "Mac14,12")
        XCTAssertEqual(updated.notices, snapshot.notices)
        XCTAssertEqual(updated.systemPower?.systemWatts, 10)
        let reset = updated.resettingLiveMetrics()
        XCTAssertEqual(reset.devices.map(\.id), updated.devices.map(\.id))
        XCTAssertTrue(reset.devices.allSatisfy { $0.transfer == nil })
        XCTAssertNil(reset.systemPower)
    }
}

final class ProfilerCancellationTests: XCTestCase {
    func testCancellingOwnedProcessStopsItPromptly() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let task = Task { try await ProfilerProcess.run(process) }
        for _ in 0..<200 {
            if process.isRunning { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard process.isRunning else {
            task.cancel()
            XCTFail("The test child process did not start")
            return
        }
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled process should throw CancellationError")
        } catch is CancellationError {
        }
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }
}
