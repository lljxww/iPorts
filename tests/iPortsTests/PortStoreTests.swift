import Foundation
import PortsCore
import XCTest

@testable import iPorts

final class PortStoreTests: XCTestCase {
    @MainActor
    private func fixture(_ identifier: String = "Mac999,99", devices: [PortDevice] = []) throws -> (
        PortStore, UserDefaults, String
    ) {
        let domain = "local.iports.tests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
        let store = PortStore(
            snapshot: ScanSnapshot(devices: devices, machine: MachineInfo(identifier: identifier)),
            preferences: preferences)
        return (store, preferences, domain)
    }

    @MainActor
    func testCancelEditingDoesNotChangeSavedOrDefaultLayout() async throws {
        let (store, preferences, domain) = try fixture("MacBookPro18,1")
        defer { preferences.removePersistentDomain(forName: domain) }
        let initial = store.modelProfile?.ports.map(\.id)
        store.beginLayoutEditing()
        store.addLayoutPort(side: .front, connector: .usbA)
        store.cancelLayoutEdits()
        XCTAssertNil(store.customLayout)
        XCTAssertEqual(initial, store.modelProfile?.ports.map(\.id))
        XCTAssertNil(preferences.data(forKey: "port-layout.v1.MacBookPro18,1"))
    }

    @MainActor
    func testUnknownMacCustomLayoutAndCalibrationSurviveRelaunch() async throws {
        let route = PortRoute(connector: .usb, number: 0, topologyPath: "IOService:/XHC/HS01")
        let device = PortDevice(
            id: "usb", kind: .usb, name: "Keyboard", subtitle: "USB", connection: "12 Mb/s", route: route)
        let (store, preferences, domain) = try fixture(devices: [device])
        defer { preferences.removePersistentDomain(forName: domain) }
        store.beginLayoutEditing()
        store.addLayoutPort(side: .left, connector: .usbA)
        store.applyLayoutEdits()
        let slot = try XCTUnwrap(store.calibrationPorts(for: device).first)
        store.calibrate(device, portID: slot.id)
        store.selectPort(slot)
        XCTAssertEqual(store.visibleDevices.map(\.id), [device.id])
        XCTAssertEqual(store.modelDiagramID, "left")
        let reopened = PortStore(snapshot: store.snapshot, preferences: preferences)
        XCTAssertEqual(reopened.associations[device.id]?.portID, slot.id)
        XCTAssertEqual(reopened.associations[device.id]?.confidence, .manual)
        reopened.beginLayoutEditing()
        reopened.removeLayoutPort(slot.id)
        reopened.applyLayoutEdits()
        XCTAssertEqual(reopened.associations[device.id]?.confidence, .topology)
    }

    @MainActor
    func testFutureMacTopologyCanFilterDevicesAndRestoreAfterEmptySlotSelection() async throws {
        let route = PortRoute(connector: .usbC, number: 1)
        let devices = [
            PortDevice(
                id: "hub", kind: .usb, name: "Hub", subtitle: "USB", connection: "5 Gb/s", route: route),
            PortDevice(
                id: "disk", kind: .storage, name: "Disk", subtitle: "USB", connection: "5 Gb/s",
                parentID: "hub"),
        ]
        let (store, preferences, domain) = try fixture(devices: devices)
        defer { preferences.removePersistentDomain(forName: domain) }
        let logical = try XCTUnwrap(store.modelProfile?.ports.first)
        store.selectPort(logical)
        XCTAssertEqual(Set(store.visibleDevices.map(\.id)), Set(["hub", "disk"]))
        store.selectedPortID = nil
        XCTAssertEqual(store.visibleDevices.count, 2)
    }

    @MainActor
    func testRackVariantChoicePersistsAndUsesFrontInsteadOfTopPorts() async throws {
        let (store, preferences, domain) = try fixture("Mac14,8")
        defer { preferences.removePersistentDomain(forName: domain) }
        let rack = try XCTUnwrap(store.modelVariants.first { $0.name.contains("Rack") })
        store.chooseModelVariant(rack.id)
        XCTAssertTrue(store.modelProfile?.diagrams.contains { $0.id == "front" } == true)
        XCTAssertFalse(store.modelProfile?.diagrams.contains { $0.id == "top" } == true)
        let reopened = PortStore(snapshot: store.snapshot, preferences: preferences)
        XCTAssertEqual(reopened.modelVariantID, rack.id)
        XCTAssertEqual(reopened.modelProfile?.imageName, rack.imageName)
    }

    @MainActor
    func testReorderingPortsPreservesCalibrationAndRestoreDefaultRemovesCustomLayout() async throws {
        let device = PortDevice(
            id: "usb", kind: .usb, name: "USB", subtitle: "USB", connection: "Test",
            route: PortRoute(connector: .usbC, number: 1))
        let (store, preferences, domain) = try fixture(devices: [device])
        defer { preferences.removePersistentDomain(forName: domain) }
        store.beginLayoutEditing()
        store.addLayoutPort(side: .left, connector: .usbC)
        store.addLayoutPort(side: .left, connector: .usbC)
        store.applyLayoutEdits()
        let slot = try XCTUnwrap(store.calibrationPorts(for: device).first)
        store.calibrate(device, portID: slot.id)
        store.beginLayoutEditing()
        store.moveLayoutPort(slot.id, offset: 1)
        store.applyLayoutEdits()
        XCTAssertEqual(store.associations[device.id]?.portID, slot.id)
        store.restoreDefaultLayout()
        XCTAssertNil(store.customLayout)
        XCTAssertNil(preferences.data(forKey: "port-layout.v1.Mac999,99"))
        XCTAssertEqual(store.associations[device.id]?.confidence, .topology)
    }

    @MainActor
    func testSelectedDeviceHighlightsOnlyPhysicalPortNotMatchingLogicalRoot() async throws {
        let device = PortDevice(
            id: "usb", kind: .usb, name: "USB", subtitle: "USB", connection: "5 Gb/s",
            route: PortRoute(connector: .usbC, number: 1))
        let (store, preferences, domain) = try fixture("MacBookPro18,1", devices: [device])
        defer { preferences.removePersistentDomain(forName: domain) }
        let physical = try XCTUnwrap(store.calibrationPorts(for: device).first)
        let logical = try XCTUnwrap(store.modelProfile?.ports.first { $0.isLogical })
        store.calibrate(device, portID: physical.id)
        XCTAssertEqual(store.devices(at: logical.id).map(\.id), [device.id])
        XCTAssertEqual(store.modelProfile?.ports.filter(store.isSelectedPort).map(\.id), [physical.id])
    }

    @MainActor
    func testExplicitLogicalSelectionStaysSingleWhenSelectingItsDevice() async throws {
        let device = PortDevice(
            id: "usb", kind: .usb, name: "USB", subtitle: "USB", connection: "5 Gb/s",
            route: PortRoute(connector: .usbC, number: 1))
        let (store, preferences, domain) = try fixture("MacBookPro18,1", devices: [device])
        defer { preferences.removePersistentDomain(forName: domain) }
        let physical = try XCTUnwrap(store.calibrationPorts(for: device).first)
        let logical = try XCTUnwrap(store.modelProfile?.ports.first { $0.isLogical })
        store.calibrate(device, portID: physical.id)
        store.selectPort(logical)
        store.selectDevice(device)
        XCTAssertEqual(store.modelDiagramID, "topology")
        XCTAssertEqual(store.modelProfile?.ports.filter(store.isSelectedPort).map(\.id), [logical.id])
        let topology = try XCTUnwrap(store.modelProfile?.diagrams.first { $0.id == "topology" })
        XCTAssertEqual(store.ports(in: topology).map(\.id), [logical.id])
    }

    @MainActor
    func testSeveralConnectedPortsDoNotHighlightTogetherAndSelectionCanMove() async throws {
        let devices = [
            PortDevice(
                id: "usb", kind: .usb, name: "USB", subtitle: "USB", connection: "5 Gb/s",
                route: PortRoute(connector: .usbC, number: 1)),
            PortDevice(
                id: "display", kind: .display, name: "Display", subtitle: "HDMI", connection: "HDMI",
                route: PortRoute(connector: .hdmi, number: 1)),
        ]
        let (store, preferences, domain) = try fixture("Mac14,12", devices: devices)
        defer { preferences.removePersistentDomain(forName: domain) }
        XCTAssertEqual(store.associations["usb"]?.confidence, .inferred)
        XCTAssertEqual(store.associations["display"]?.confidence, .system)
        for device in devices {
            store.selectDevice(device)
            XCTAssertEqual(
                store.modelProfile?.ports.filter(store.isSelectedPort).map(\.id),
                [try XCTUnwrap(store.associations[device.id]?.portID)])
        }
        let empty = try XCTUnwrap(store.modelProfile?.ports.first { !store.hasConnectedDevice(at: $0.id) })
        store.selectPort(empty)
        XCTAssertTrue(store.visibleDevices.isEmpty)
        XCTAssertEqual(store.modelProfile?.ports.filter(store.isSelectedPort).map(\.id), [empty.id])
    }

    @MainActor
    func testEmptySnapshotHasNoHighlightedPort() async throws {
        let (store, preferences, domain) = try fixture("MacBookPro18,1")
        defer { preferences.removePersistentDomain(forName: domain) }
        XCTAssertNil(store.highlightedPortID)
        XCTAssertEqual(store.modelProfile?.ports.filter(store.isSelectedPort).count, 0)
    }

    @MainActor
    func testUSBConnectionDoesNotListIdleUSB4CapabilityAsAnotherDevice() async throws {
        let devices = [
            PortDevice(
                id: "usb", kind: .usb, name: "USB SSD", subtitle: "USB", connection: "5 Gb/s",
                route: PortRoute(connector: .usbC, number: 1)),
            PortDevice(
                id: "tb-port", kind: .thunderbolt, name: "USB4 Port", subtitle: "未建立雷雳链路",
                connection: "Up to 40 Gb/s", isPort: true,
                route: PortRoute(connector: .thunderbolt, number: 1)),
        ]
        let (store, preferences, domain) = try fixture("Mac14,12", devices: devices)
        defer { preferences.removePersistentDomain(forName: domain) }
        XCTAssertEqual(store.visibleConnections.count, 1)
        XCTAssertEqual(store.visibleDevices.map(\.id), ["usb"])
        XCTAssertEqual(store.deviceCount, 1)
        XCTAssertEqual(store.count(.thunderbolt), 0)
        XCTAssertEqual(store.selectedConnection?.capabilities.count, 1)
        XCTAssertEqual(store.selectedConnection?.connectionDescription, "USB 3 · 5 Gb/s")
        store.search = "USB 3"
        XCTAssertEqual(store.visibleConnections.count, 1)
    }

    @MainActor
    func testGroupedStorageAndNetworkFunctionsRemainSelectableAfterFiltering() async throws {
        let devices = [
            PortDevice(
                id: "hub", kind: .usb, name: "Dock", subtitle: "Hub", connection: "5 Gb/s",
                fields: [DeviceField("设备信息", "设备类型", "USB 集线器")],
                route: PortRoute(connector: .usbC, number: 1)),
            PortDevice(
                id: "disk", kind: .storage, name: "SSD", subtitle: "disk4", connection: "USB",
                parentID: "hub",
                disk: DiskIdentity(
                    bsdName: "disk4", registryID: 42, isInternal: false, isWhole: true, isPhysical: true)),
            PortDevice(
                id: "net", kind: .network, name: "Ethernet", subtitle: "en5", connection: "1 Gb/s",
                isPort: true,
                parentID: "hub", linkActive: true),
        ]
        let (store, preferences, domain) = try fixture("Mac14,12", devices: devices)
        defer { preferences.removePersistentDomain(forName: domain) }
        let connection = try XCTUnwrap(store.visibleConnections.first)
        XCTAssertEqual(store.visibleConnections.count, 1)
        XCTAssertEqual(store.deviceCount, 1)
        store.filter = .usb
        store.selectConnection(connection)
        XCTAssertEqual(store.selected?.id, "hub")
        store.selectFunction(devices[1], in: connection)
        XCTAssertEqual(store.selected?.id, "disk")
        XCTAssertTrue(store.selected?.disk?.canEject == true)
        XCTAssertEqual(store.selectedConnection?.id, connection.id)
        store.selectFunction(devices[2], in: connection)
        XCTAssertEqual(store.selected?.id, "net")
        XCTAssertEqual(store.selectedConnection?.id, connection.id)
    }

    @MainActor
    func testCapabilityOnlyPortCanBeInspectedWithoutAnExtraDeviceRow() async throws {
        let port = PortDevice(
            id: "tb-port", kind: .thunderbolt, name: "USB4 Port", subtitle: "未建立雷雳链路",
            connection: "Up to 40 Gb/s", isPort: true, route: PortRoute(connector: .thunderbolt, number: 1))
        let (store, preferences, domain) = try fixture("Mac14,12", devices: [port])
        defer { preferences.removePersistentDomain(forName: domain) }
        XCTAssertTrue(store.visibleConnections.isEmpty)
        XCTAssertEqual(store.deviceCount, 0)
        let physical = try XCTUnwrap(store.modelProfile?.ports.first { $0.id == "rear.usb-c.1" })
        store.selectPort(physical)
        XCTAssertNil(store.selected)
        XCTAssertEqual(store.selectedConnection?.capabilities.count, 1)
    }

    @MainActor
    func testWiFiRemainsVisibleAndSeparateFromWiredPortsAndBluetooth() async throws {
        let ethernet = PortDevice(
            id: "ethernet", kind: .network, name: "Ethernet", subtitle: "en0", connection: "1 Gb/s",
            isPort: true, route: PortRoute(connector: .ethernet, number: 1), linkActive: true)
        let wifi = PortDevice(
            id: "wifi:en1", kind: .wifi, name: "Wi-Fi · en1", subtitle: "已连接无线网络",
            connection: "864 Mb/s", isPort: true,
            fields: [DeviceField("无线网络", "网络名称 (SSID)", "Test Network")], linkActive: true)
        let bluetooth = PortDevice(
            id: "bluetooth:one", kind: .bluetooth, name: "Mouse", subtitle: "鼠标",
            connection: "Bluetooth", linkActive: true)
        for identifier in ["Mac14,12", "Mac999,99"] {
            let (store, preferences, domain) = try fixture(identifier, devices: [ethernet, wifi, bluetooth])
            defer { preferences.removePersistentDomain(forName: domain) }
            XCTAssertFalse(store.showInternal)
            XCTAssertEqual(store.visibleConnections.count, 3)
            XCTAssertEqual(store.deviceCount, 3)
            XCTAssertEqual(store.wiredConnectionCount, 1)
            XCTAssertEqual(store.count(.wifi), 1)
            XCTAssertEqual(store.count(.network), 1)
            XCTAssertEqual(store.connectionCountDescription, "1 个有线连接 · 1 个 Wi-Fi 连接 · 1 个蓝牙设备")
            XCTAssertNil(store.associations[wifi.id])
            XCTAssertTrue(store.calibrationPorts(for: wifi).isEmpty)
            XCTAssertFalse(
                store.modelProfile?.ports.contains { $0.routeKey?.contains("wifi:") == true } == true)
            let portID = try XCTUnwrap(store.associations[ethernet.id]?.portID)
            let port = try XCTUnwrap(store.modelProfile?.ports.first { $0.id == portID })
            store.selectPort(port)
            XCTAssertEqual(store.visibleDevices.map(\.id), [ethernet.id])
            store.selectDevice(wifi)
            XCTAssertNil(store.selectedPortID)
            XCTAssertNil(store.highlightedPortID)
            XCTAssertNil(store.selectedConnection?.portID)
            XCTAssertEqual(store.selected?.id, wifi.id)
            store.filter = .wifi
            store.search = "test network"
            XCTAssertEqual(store.visibleDevices.map(\.id), [wifi.id])
        }
    }

    @MainActor
    func testOfflineAndUnknownWiFiAreListedWithoutCountingAsConnections() async throws {
        let devices = [false, nil].enumerated().map { index, active in
            PortDevice(
                id: "wifi:en\(index)", kind: .wifi, name: "Wi-Fi", subtitle: "未连接或状态未知",
                connection: "系统未提供", isPort: true, linkActive: active)
        }
        let (store, preferences, domain) = try fixture(devices: devices)
        defer { preferences.removePersistentDomain(forName: domain) }
        XCTAssertEqual(store.visibleConnections.count, 2)
        XCTAssertEqual(store.count(.wifi), 2)
        XCTAssertEqual(store.deviceCount, 0)
        XCTAssertEqual(store.wiredConnectionCount, 0)
        XCTAssertEqual(store.connectionCountDescription, "0 个端口连接")
        XCTAssertTrue(store.connections.allSatisfy { !$0.isConnected && $0.portID == nil })
    }

    @MainActor
    func testBluetoothDevicesStaySeparateFromPortsAndAreCountedAsWireless() async throws {
        let usb = PortDevice(
            id: "usb", kind: .usb, name: "Dock", subtitle: "USB", connection: "5 Gb/s",
            route: PortRoute(connector: .usbC, number: 1))
        let headphones = PortDevice(
            id: "bluetooth:one", kind: .bluetooth, name: "Headphones", subtitle: "耳机",
            connection: "Bluetooth", linkActive: true)
        let mouse = PortDevice(
            id: "bluetooth:two", kind: .bluetooth, name: "Mouse", subtitle: "鼠标",
            connection: "Bluetooth LE", linkActive: true)
        for identifier in ["Mac14,12", "Mac999,99"] {
            let (store, preferences, domain) = try fixture(identifier, devices: [usb, headphones, mouse])
            defer { preferences.removePersistentDomain(forName: domain) }
            XCTAssertEqual(store.visibleConnections.count, 3)
            XCTAssertEqual(store.deviceCount, 3)
            XCTAssertEqual(store.wiredConnectionCount, 1)
            XCTAssertEqual(store.count(.bluetooth), 2)
            XCTAssertEqual(store.connectionCountDescription, "1 个有线连接 · 2 个蓝牙设备")
            XCTAssertNil(store.associations[headphones.id])
            XCTAssertTrue(store.calibrationPorts(for: headphones).isEmpty)
            XCTAssertFalse(
                store.modelProfile?.ports.contains { $0.routeKey?.contains("bluetooth:") == true } == true)
            let portID = try XCTUnwrap(store.associations[usb.id]?.portID)
            let port = try XCTUnwrap(store.modelProfile?.ports.first { $0.id == portID })
            store.selectPort(port)
            XCTAssertEqual(store.visibleDevices.map(\.id), [usb.id])
            store.selectDevice(headphones)
            XCTAssertEqual(store.selected?.id, headphones.id)
            XCTAssertNil(store.highlightedPortID)
            XCTAssertNil(store.selectedConnection?.portID)
            store.filter = .bluetooth
            store.search = "鼠标"
            XCTAssertEqual(store.visibleConnections.count, 1)
            XCTAssertEqual(store.selected?.id, mouse.id)
        }
    }
}
