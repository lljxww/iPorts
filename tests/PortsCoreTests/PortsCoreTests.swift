import Darwin
import Foundation
import XCTest

@testable import PortsCore

final class TransferSamplerTests: XCTestCase {
    func testFirstSampleIsUnknownRatherThanIdle() {
        var sampler = TransferSampler()
        XCTAssertTrue(sampler.sample(["a": ByteCounters(read: 100, written: 200, time: 1)]).isEmpty)
    }

    func testRatesUseElapsedTimeAndIndependentDirections() throws {
        var sampler = TransferSampler()
        _ = sampler.sample(["a": ByteCounters(read: 100, written: 200, time: 10)])
        let rate = try XCTUnwrap(sampler.sample(["a": ByteCounters(read: 500, written: 800, time: 12)])["a"])
        XCTAssertEqual(rate.readBytesPerSecond, 200)
        XCTAssertEqual(rate.writeBytesPerSecond, 300)
        XCTAssertTrue(rate.isActive)
    }

    func testUnchangedCountersAreIdle() throws {
        var sampler = TransferSampler()
        _ = sampler.sample(["a": ByteCounters(read: 100, written: 200, time: 1)])
        let rate = try XCTUnwrap(sampler.sample(["a": ByteCounters(read: 100, written: 200, time: 3)])["a"])
        XCTAssertFalse(rate.isActive)
    }

    func testCounterResetAndInvalidTimeNeverProduceNegativeRates() {
        for next in [
            ByteCounters(read: 1, written: 2, time: 3),
            ByteCounters(read: 200, written: 300, time: 1),
            ByteCounters(read: 200, written: 300, time: .nan),
        ] {
            var sampler = TransferSampler()
            _ = sampler.sample(["a": ByteCounters(read: 100, written: 200, time: 1)])
            XCTAssertTrue(sampler.sample(["a": next]).isEmpty)
        }
    }

    func testDisconnectAndResumeRequireFreshBaseline() {
        var sampler = TransferSampler()
        _ = sampler.sample(["a": ByteCounters(read: 100, written: 200, time: 1)])
        _ = sampler.sample([:])
        XCTAssertTrue(sampler.sample(["a": ByteCounters(read: 500, written: 600, time: 5)]).isEmpty)
        sampler.reset()
        XCTAssertTrue(sampler.sample(["a": ByteCounters(read: 700, written: 800, time: 7)]).isEmpty)
    }
}

final class EjectionPolicyTests: XCTestCase {
    private func identity(
        name: String = "disk4", id: UInt64 = 42, internalDevice: Bool? = false,
        whole: Bool = true, physical: Bool = true
    ) -> DiskIdentity {
        DiskIdentity(
            bsdName: name, registryID: id, isInternal: internalDevice, isWhole: whole, isPhysical: physical)
    }

    func testOnlyExplicitlyExternalPhysicalWholeDisksAreEligible() {
        XCTAssertTrue(identity().canEject)
        XCTAssertFalse(identity(internalDevice: true).canEject)
        XCTAssertFalse(identity(internalDevice: nil).canEject)
        XCTAssertFalse(identity(whole: false).canEject)
        XCTAssertFalse(identity(physical: false).canEject)
        XCTAssertFalse(identity(id: 0).canEject)
    }

    func testPartitionsPathsAndMalformedNamesAreRejected() {
        for name in ["disk4s1", "/dev/disk4", "disk4;reboot", "disk", "", "disk4\n"] {
            XCTAssertFalse(identity(name: name).canEject, name)
        }
    }

    func testReusedBSDNameCannotEjectReplacementDevice() {
        XCTAssertFalse(identity().matchesForEjection(identity(id: 43)))
        XCTAssertFalse(identity().matchesForEjection(identity(name: "disk5")))
        XCTAssertFalse(identity().matchesForEjection(identity(internalDevice: true)))
        XCTAssertTrue(identity().matchesForEjection(identity()))
    }
}

final class FormattingTests: XCTestCase {
    func testPowerBudgetIsFiveVoltAllocationAndValidatesInput() throws {
        let power = try XCTUnwrap(PowerBudget(milliamps: 500))
        XCTAssertEqual(power.watts, 2.5)
        XCTAssertEqual(power.formatted, "2.50 W")
        XCTAssertEqual(PowerBudget(milliamps: 0)?.watts, 0)
        XCTAssertNil(PowerBudget(milliamps: -1))
        XCTAssertNil(PowerBudget(milliamps: .infinity))
        XCTAssertNil(PowerBudget(milliamps: .nan))
    }

    func testFullAndLowSpeedAreNotSwapped() {
        XCTAssertEqual(PortFormatting.linkSpeed(bits: nil, code: 1), "12 Mb/s")
        XCTAssertEqual(PortFormatting.linkSpeed(bits: nil, code: 2), "1.5 Mb/s")
        XCTAssertEqual(PortFormatting.linkSpeed(bits: nil, code: 6), "20 Gb/s")
        XCTAssertEqual(PortFormatting.linkSpeed(bits: nil, code: 7), "系统未提供")
    }

    func testExplicitLinkSpeedTakesPriorityOverLegacyCode() {
        XCTAssertEqual(PortFormatting.linkSpeed(bits: 10_000_000_000, code: 3), "10 Gb/s")
        XCTAssertEqual(PortFormatting.linkSpeed(bits: 0, code: 3), "480 Mb/s")
    }

    func testRatesClearlyUseBytesRatherThanBits() {
        XCTAssertEqual(PortFormatting.rate(1_500_000), "1.5 MB/s")
        XCTAssertEqual(PortFormatting.rate(0), "0 B/s")
        XCTAssertEqual(PortFormatting.rate(-1), "不可读取")
        XCTAssertEqual(PortFormatting.rate(.nan), "不可读取")
    }
}

final class ProfilerParserTests: XCTestCase {
    private func parse(_ json: String) throws -> [PortDevice] { try ProfilerParser.parse(Data(json.utf8)) }

    func testIdleThunderboltPortDoesNotClaimUSBConnectorIsUnused() throws {
        let devices = try parse(
            """
            {"SPThunderboltDataType": [{"_name": "bus0", "domain_uuid_key": "bus-id",
              "receptacle_1_tag": {"receptacle_id_key": "1", "current_speed_key": "Up to 40 Gb/s",
              "receptacle_status_key": "receptacle_no_devices_connected"}}]}
            """)
        let port = try XCTUnwrap(devices.first)
        XCTAssertTrue(port.isPort)
        XCTAssertEqual(port.subtitle, "未建立雷雳链路")
        XCTAssertTrue(port.fields.contains { $0.value.contains("USB / DP") })
    }

    func testThunderboltHostIsNotListedAsAnExternalDevice() throws {
        let devices = try parse(
            """
            {"SPThunderboltDataType": [{"device_name_key": "Mac", "_name": "bus0", "_items": [
              {"device_name_key": "Dock", "switch_uid_key": "dock", "_items": [
                {"device_name_key": "Drive", "switch_uid_key": "drive"}]}]}]}
            """)
        XCTAssertEqual(devices.map(\.name), ["Dock", "Drive"])
        XCTAssertEqual(Set(devices.map(\.id)).count, 2)
    }

    func testBuiltInDisplayIsExcludedAndExternalDetailsArePreserved() throws {
        let devices = try parse(
            """
            {"SPDisplaysDataType": [{"_name": "GPU", "spdisplays_ndrvs": [
              {"_name": "Built-in", "spdisplays_connection_type": "spdisplays_internal"},
              {"_name": "External", "_spdisplays_displayID": "2", "_spdisplays_resolution": "2560 x 1440 @ 60Hz",
               "_spdisplays_pixels": "5120 x 2880", "spdisplays_main": "spdisplays_yes"}]}]}
            """)
        XCTAssertEqual(devices.count, 1)
        let display = try XCTUnwrap(devices.first)
        XCTAssertEqual(display.name, "External")
        XCTAssertEqual(display.connection, "2560 x 1440 @ 60Hz")
        XCTAssertTrue(display.fields.contains { $0.label == "渲染像素" && $0.value == "5120 x 2880" })
    }

    func testMissingOptionalKeysAndUnknownSectionsAreSafe() throws {
        XCTAssertTrue(try parse("{}").isEmpty)
        XCTAssertTrue(try parse("{\"UnknownDataType\": []}").isEmpty)
        XCTAssertEqual(try parse("{\"SPDisplaysDataType\": [{\"spdisplays_ndrvs\": [{}]}]}").count, 1)
    }

    func testCorruptJSONIsReportedRatherThanSilentlyEmpty() {
        XCTAssertThrowsError(try parse("not json"))
        XCTAssertThrowsError(try parse("[]"))
    }

    func testCoreGraphicsBuiltInIDsExcludeDisplayWithoutProfilerConnectionType() throws {
        let json = Data(
            """
            {"SPDisplaysDataType": [{"spdisplays_ndrvs": [
                {"_name": "Built-in", "_spdisplays_displayID": "1"},
                {"_name": "External", "_spdisplays_displayID": "2"}]}]}
            """.utf8)
        let devices = try ProfilerParser.parse(json, builtInDisplayIDs: ["1"])
        XCTAssertEqual(devices.map(\.name), ["External"])
    }
}

final class BluetoothParserTests: XCTestCase {
    private func parse(_ json: String) throws -> [PortDevice] {
        try BluetoothParser.parse(Data(json.utf8))
    }

    func testOnlyConnectedBluetoothDevicesAreReturnedWithStableAddressIdentity() throws {
        let devices = try parse(
            """
            {"SPBluetoothDataType": [{
              "controller_properties": {"controller_state": "attrib_on"},
              "device_connected": [
                {"Headphones": {"device_address": "aa-bb-cc-dd-ee-ff", "device_minorType": "Headphones",
                  "device_services": "A2DP", "device_batteryLevel": "87"}},
                {"Mouse": {"device_address": "11:22:33:44:55:66", "device_minorType": "Mouse"}}
              ],
              "device_not_connected": [{"Old Keyboard": {"device_address": "00:11:22:33:44:55"}}]
            }]}
            """)
        XCTAssertEqual(devices.count, 2)
        let headphones = try XCTUnwrap(devices.first { $0.name == "Headphones" })
        XCTAssertEqual(headphones.kind, .bluetooth)
        XCTAssertEqual(headphones.id, "bluetooth:AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(headphones.connection, "Bluetooth")
        XCTAssertTrue(headphones.fields.contains { $0.label == "设备类型" && $0.value == "耳机" })
        XCTAssertTrue(headphones.fields.contains { $0.label == "设备电量" && $0.value == "87%" })
        XCTAssertFalse(devices.contains { $0.name == "Old Keyboard" })
    }

    func testBluetoothReportRejectsMalformedConnectedSection() {
        XCTAssertThrowsError(
            try parse("{\"SPBluetoothDataType\":[{\"device_connected\":{}}]}"))
    }

    func testBluetoothSectionMayBeAbsentOnSystemsWithoutAUsableController() throws {
        XCTAssertTrue(try parse("{\"SPDisplaysDataType\": []}").isEmpty)
    }

    func testBluetoothDeviceWithoutAddressGetsStablePerSnapshotFallback() throws {
        let devices = try parse(
            """
            {"SPBluetoothDataType": [{"device_connected": [{"Trackpad": {
              "device_minorType": "Trackpad"}}]}]}
            """)
        let device = try XCTUnwrap(devices.first)
        XCTAssertEqual(device.id, "bluetooth:unaddressed:Trackpad:0")
        XCTAssertTrue(device.fields.contains { $0.label == "蓝牙地址" && $0.value == "系统未提供" })
    }

    func testLegacyReportsRequireExplicitConnectionAndPoweredOffReportsAreEmpty() throws {
        let devices = try parse(
            """
            {"SPBluetoothDataType": [{"devices_list": [
              {"Connected": {"device_address": "00:11:22:33:44:55", "device_connected": "attrib_yes"}},
              {"Disconnected": {"device_connected": false}}, {"Unknown": {"device_paired": true}}
            ]}]}
            """)
        XCTAssertEqual(devices.map(\.name), ["Connected"])
        XCTAssertTrue(
            try parse(
                """
                {"SPBluetoothDataType": [{"controller_properties": {"controller_state": "attrib_off"},
                  "device_connected": [{"Cached": {"device_address": "00:11:22:33:44:55"}}]}]}
                """
            ).isEmpty)
    }

    func testBatteryAndSignalValuesAreValidatedWithoutInventingLinkSpeed() throws {
        let devices = try parse(
            """
            {"SPBluetoothDataType": [{"device_connected": [{"Headphones": {
              "device_batteryLevelLeft": "0%", "device_batteryLevelRight": 100,
              "device_batteryLevelCase": "101", "device_batteryLevel": "NaN",
              "device_rssi": "-63 dBm", "device_isCharging": true,
              "device_connectionType": "LE", "device_services": "A2DP HFP"
            }}, {"Mouse": {"device_rssi": 127, "device_batteryLevel": -1}}]}]}
            """)
        let headphones = try XCTUnwrap(devices.first { $0.name == "Headphones" })
        XCTAssertEqual(headphones.connection, "Bluetooth LE")
        XCTAssertTrue(headphones.fields.contains { $0.label == "左耳电量" && $0.value == "0%" })
        XCTAssertTrue(headphones.fields.contains { $0.label == "右耳电量" && $0.value == "100%" })
        XCTAssertTrue(headphones.fields.contains { $0.label == "RSSI" && $0.value == "-63 dBm" })
        XCTAssertTrue(headphones.fields.contains { $0.label == "充电状态" && $0.value == "正在充电" })
        XCTAssertFalse(headphones.fields.contains { $0.label == "充电盒电量" || $0.label == "设备电量" })
        XCTAssertNil(headphones.power)
        XCTAssertNil(headphones.transfer)
        let mouse = try XCTUnwrap(devices.first { $0.name == "Mouse" })
        XCTAssertFalse(mouse.fields.contains { $0.label == "RSSI" })
        XCTAssertTrue(mouse.fields.contains { $0.label == "设备电量" && $0.value == "系统未提供" })
    }

    func testDuplicateAddressesDeduplicateButIdenticalDeviceNamesStaySeparate() throws {
        let devices = try parse(
            """
            {"SPBluetoothDataType": [{"device_connected": [
              {"Headphones": {"device_address": "00:11:22:33:44:55"}},
              {"Headphones": {"device_address": "00-11-22-33-44-55"}},
              {"Headphones": {"device_address": "00:11:22:33:44:66"}}
            ]}]}
            """)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(Set(devices.map(\.id)).count, 2)
    }
}

final class NetworkReaderTests: XCTestCase {
    func testNetworkCountersPreserve64BitByteCounts() throws {
        var message = if_msghdr2()
        message.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        message.ifm_type = UInt8(RTM_IFINFO2)
        message.ifm_index = 7
        message.ifm_data.ifi_ibytes = 9_000_000_000
        message.ifm_data.ifi_obytes = 8_000_000_000
        let data = withUnsafeBytes(of: message) { Data($0) }
        let counter = try XCTUnwrap(NetworkReader.parseCounters(data, time: 12)[7])
        XCTAssertEqual(counter.bytes.read, 9_000_000_000)
        XCTAssertEqual(counter.bytes.written, 8_000_000_000)
        XCTAssertEqual(counter.bytes.time, 12)
    }

    func testTruncatedAndZeroLengthNetworkMessagesAreRejected() {
        for data in [
            Data(), Data([0, 0, 0, 0]), Data([255, 255, 0, UInt8(RTM_IFINFO2)]),
            Data([4, 0, 0, UInt8(RTM_IFINFO2)]),
        ] {
            XCTAssertTrue(NetworkReader.parseCounters(data, time: 1).isEmpty)
        }
    }

    func testMacDeviceModeAndThunderboltIPAreNotPhysicalEthernetAdapters() {
        XCTAssertTrue(NetworkReader.excludesController(model: "ThunderboltIP", provider: nil))
        XCTAssertTrue(NetworkReader.excludesController(model: nil, provider: "IOUSBDeviceInterface"))
        XCTAssertFalse(NetworkReader.excludesController(model: "Ethernet", provider: "IOUSBHostInterface"))
        XCTAssertFalse(NetworkReader.excludesController(model: "BCM", provider: "IOPCIDevice"))
    }
}

final class USBVisibilityTests: XCTestCase {
    func testRemovabilitySupportsIOKitStringAndBooleanValues() {
        XCTAssertEqual(USBVisibility.removability("yes"), true)
        XCTAssertEqual(USBVisibility.removability("no"), false)
        XCTAssertEqual(USBVisibility.removability(NSNumber(value: true)), true)
        XCTAssertEqual(USBVisibility.removability(NSNumber(value: false)), false)
        XCTAssertNil(USBVisibility.removability(nil))
        XCTAssertNil(USBVisibility.removability("unknown"))
    }
}
