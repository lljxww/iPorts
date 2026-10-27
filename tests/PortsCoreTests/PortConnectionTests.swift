import Foundation
import XCTest

@testable import PortsCore

final class PortConnectionTests: XCTestCase {
    private func usb(
        _ id: String = "usb", number: Int = 1, speed: String = "5 Gb/s",
        parent: String? = nil, fields: [DeviceField] = [], internalDevice: Bool = false
    ) -> PortDevice {
        PortDevice(
            id: id, kind: .usb, name: id, subtitle: "USB", connection: speed,
            isInternal: internalDevice, parentID: parent, fields: fields,
            route: parent == nil ? PortRoute(connector: .usbC, number: number) : nil)
    }

    private func thunderbolt(_ id: String = "tb", number: Int = 1, port: Bool = false) -> PortDevice {
        PortDevice(
            id: id, kind: .thunderbolt, name: id, subtitle: port ? "雷雳端口" : "雷雳设备",
            connection: port ? "Up to 40 Gb/s" : "20 Gb/s", isPort: port,
            fields: port ? [DeviceField("端口信息", "链路能力", "Up to 40 Gb/s")] : [],
            route: PortRoute(connector: .thunderbolt, number: number))
    }

    private func build(
        _ devices: [PortDevice], identifier: String = "Mac14,12",
        machine suppliedMachine: MachineInfo? = nil
    ) -> [PortConnection] {
        let machine = suppliedMachine ?? MachineInfo(identifier: identifier)
        let profile = MacModelCatalog.resolvedProfile(machine: machine, devices: devices)
        let associations = PortMapper.associations(devices: devices, machine: machine, profile: profile)
        return PortConnectionBuilder.build(
            devices: devices, machine: machine, profile: profile, associations: associations)
    }

    func testUSB3AndIdleUSB4CapabilityProduceOneConnectionWithoutClaimingUSB4Use() throws {
        let connections = build([usb(), thunderbolt("port", port: true)])
        let connection = try XCTUnwrap(connections.first)
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connection.devices.map(\.id), ["usb"])
        XCTAssertEqual(connection.capabilities.map(\.id), ["port"])
        XCTAssertEqual(connection.connectionDescription, "USB 3 · 5 Gb/s")
        XCTAssertFalse(connection.connectionDescription.contains("40"))
        XCTAssertFalse(connection.connectionDescription.contains("USB4"))
        XCTAssertTrue(connection.capabilityLocationInferred)
        XCTAssertTrue(connection.report.contains("当前连接方式 / 协议：USB 3 · 5 Gb/s"))
        XCTAssertTrue(connection.report.contains("端口能力与通道信息（不代表当前连接协议）"))
    }

    func testProtocolChangeKeepsPhysicalPortIdentityAndUpdatesCurrentLink() throws {
        let usbConnection = try XCTUnwrap(build([usb(), thunderbolt("port", port: true)]).first)
        let tbConnection = try XCTUnwrap(build([thunderbolt(), thunderbolt("port", port: true)]).first)
        XCTAssertEqual(usbConnection.id, tbConnection.id)
        XCTAssertEqual(tbConnection.devices.map(\.id), ["tb"])
        XCTAssertEqual(tbConnection.connectionDescription, "Thunderbolt / USB4 · 20 Gb/s")
    }

    func testUSBCapabilityVersionDoesNotOverrideNegotiatedUSB2Link() throws {
        let device = usb(speed: "480 Mb/s", fields: [DeviceField("设备信息", "USB 协议", "3.20")])
        XCTAssertEqual(try XCTUnwrap(build([device]).first).connectionDescription, "USB 2 · 480 Mb/s")
    }

    func testUnverifiedMatchingNumbersNeverMergeUSBAndThunderboltDevices() {
        let connections = build(
            [usb(), thunderbolt(), thunderbolt("port", port: true)], identifier: "Mac999,99")
        XCTAssertEqual(connections.count, 2)
        XCTAssertEqual(connections.map { $0.devices.count }.sorted(), [1, 1])
        XCTAssertEqual(connections.first { $0.devices.contains { $0.id == "tb" } }?.capabilities.count, 1)
    }

    func testDockFunctionsStayInOneConnectionAndRetainDiskIdentityAndCounters() throws {
        let hub = usb("hub", fields: [DeviceField("设备信息", "设备类型", "USB 集线器")])
        let identity = DiskIdentity(
            bsdName: "disk4", registryID: 42, isInternal: false, isWhole: true, isPhysical: true)
        let disk = PortDevice(
            id: "disk", kind: .storage, name: "External SSD", subtitle: "disk4", connection: "USB",
            parentID: "hub", transfer: TransferRate(readBytesPerSecond: 1_000, writeBytesPerSecond: 2_000),
            disk: identity)
        let network = PortDevice(
            id: "net", kind: .network, name: "Ethernet", subtitle: "en5", connection: "1 Gb/s",
            isPort: true, parentID: "hub", linkActive: true)
        let connection = try XCTUnwrap(build([hub, disk, network, usb("other", number: 2)]).first)
        XCTAssertEqual(connection.primary?.id, "hub")
        XCTAssertEqual(Set(connection.devices.map(\.id)), ["hub", "disk", "net"])
        XCTAssertEqual(connection.connectionDescription, "USB 3 · 5 Gb/s")
        XCTAssertEqual(connection.devices.first { $0.id == "disk" }?.disk, identity)
        XCTAssertEqual(connection.devices.first { $0.id == "disk" }?.transfer?.writeBytesPerSecond, 2_000)
    }

    func testActiveUSBAndThunderboltRecordsShareOnePhysicalEntryWithBothObservedProtocols() throws {
        let connections = build([usb(), thunderbolt(), thunderbolt("port", port: true)])
        let connection = try XCTUnwrap(connections.first)
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connection.devices.count, 2)
        XCTAssertEqual(connection.links.map(\.protocolName), ["USB 3", "Thunderbolt / USB4"])
        XCTAssertEqual(connection.primary?.id, "tb")
    }

    func testDisplayAndUSBBillboardShareOnePortAndExposeDisplayPortAndUSBLinks() throws {
        let route = PortRoute(connector: .usbC, number: 4)
        let machine = MachineInfo(
            identifier: "Mac14,12",
            connectors: [
                ConnectorObservation(
                    route: route, location: "back-right", activeTransports: ["USB2", "DisplayPort"],
                    hasDisplaySignal: true)
            ])
        let display = PortDevice(
            id: "display", kind: .display, name: "Monitor", subtitle: "Display", connection: "3840 x 2160")
        let connections = build([usb("billboard", number: 4, speed: "12 Mb/s"), display], machine: machine)
        let connection = try XCTUnwrap(connections.first)
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connection.primary?.id, "display")
        XCTAssertEqual(connection.links.map(\.protocolName), ["USB", "DisplayPort"])
        XCTAssertFalse(connection.connectionDescription.contains("3840"))
    }

    func testIdleCapabilitiesAreNotConnectedDevicesOrCurrentProtocols() throws {
        let connection = try XCTUnwrap(build([thunderbolt("port", port: true)]).first)
        XCTAssertTrue(connection.devices.isEmpty)
        XCTAssertNil(connection.primary)
        XCTAssertTrue(connection.links.isEmpty)
        XCTAssertFalse(connection.isConnected)
        XCTAssertEqual(connection.connectionDescription, "未观察到连接")
    }

    func testDuplicateAndCyclicParentRecordsAreBoundedAndDeduplicated() {
        let a = usb("a", parent: "b")
        let b = usb("b", parent: "a")
        let connections = PortConnectionBuilder.build(
            devices: [a, b, a], machine: nil, profile: nil, associations: [:])
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connections.first?.devices.map(\.id), ["a", "b"])
        XCTAssertEqual(connections.first?.connectionDescription, "USB 3 · 5 Gb/s")
    }

    func testInternalAndExternalDevicesWithSameRouteRemainSeparate() {
        let connections = build([usb(), usb("internal", internalDevice: true)])
        XCTAssertEqual(connections.count, 2)
        XCTAssertEqual(connections.filter(\.isInternal).count, 1)
    }

    func testDistinctLegacyRootPathsRemainSeparateEvenWithSamePortNumber() {
        let devices = ["HS01", "HS02"].map { path in
            PortDevice(
                id: path, kind: .usb, name: path, subtitle: "USB", connection: "480 Mb/s",
                route: PortRoute(connector: .usb, number: 1, topologyPath: "IOService:/XHC/\(path)"))
        }
        XCTAssertEqual(build(devices, identifier: "Mac999,99").count, 2)
    }
}
