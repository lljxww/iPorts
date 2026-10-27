import AppKit
import Foundation
import XCTest

@testable import PortsCore

final class ModelCatalogTests: XCTestCase {
    func testExactModelIdentifierDistinguishesM2AndM2Pro() throws {
        let pro = try XCTUnwrap(MacModelCatalog.profile(for: "Mac14,12"))
        let standard = try XCTUnwrap(MacModelCatalog.profile(for: "Mac14,3"))
        XCTAssertEqual(pro.ports.filter { $0.connector == .usbC }.count, 4)
        XCTAssertEqual(standard.ports.filter { $0.connector == .usbC }.count, 2)
        XCTAssertNotEqual(pro.imageName, standard.imageName)
        XCTAssertNil(MacModelCatalog.profile(for: "Mac14,999"))
        XCTAssertNotNil(MacModelCatalog.profile(for: "MacBookPro18,1"))
    }

    func testOfficialArtworkExistsAndHotspotsStayWithinCrops() throws {
        for profile in MacModelCatalog.profiles {
            XCTAssertEqual(profile.sourceURL.host, "support.apple.com")
            XCTAssertEqual(profile.imageURL.host, "cdsassets.apple.com")
            XCTAssertEqual(profile.imageURL.scheme, "https")
            let url = try XCTUnwrap(MacModelCatalog.artworkURL(for: profile))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
            XCTAssertEqual(Set(profile.ports.map(\.id)).count, profile.ports.count)
            for diagram in profile.diagrams {
                XCTAssertGreaterThan(diagram.crop.width, 0)
                XCTAssertGreaterThan(diagram.crop.height, 0)
                XCTAssertGreaterThanOrEqual(diagram.crop.x, 0)
                XCTAssertGreaterThanOrEqual(diagram.crop.y, 0)
                XCTAssertLessThanOrEqual(diagram.crop.x + diagram.crop.width, Double(bitmap.pixelsWide))
                XCTAssertLessThanOrEqual(diagram.crop.y + diagram.crop.height, Double(bitmap.pixelsHigh))
                for port in diagram.ports {
                    XCTAssertTrue((0...1).contains(port.x), port.id)
                    XCTAssertTrue((0...1).contains(port.y), port.id)
                }
            }
        }
    }

    func test2024ModelHasSeparateFrontAndRearDiagrams() throws {
        let profile = try XCTUnwrap(MacModelCatalog.profile(for: "Mac16,10"))
        XCTAssertEqual(profile.diagrams.map(\.id), ["rear", "front"])
        XCTAssertEqual(profile.ports.filter { $0.connector == .usbC }.count, 5)
        XCTAssertFalse(profile.supportsNumberedRearPorts)
    }

    func testOlderSnapshotWithoutModelAndRouteFieldsStillDecodes() throws {
        let json = """
            {"devices":[{"id":"usb:1","kind":"usb","name":"Test","subtitle":"USB",
             "connection":"480 Mb/s","isInternal":false,"isPort":false,"fields":[]}],
             "capturedAt":0,"notices":[]}
            """
        let snapshot = try JSONDecoder().decode(ScanSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.machine)
        XCTAssertNil(snapshot.devices.first?.route)
        XCTAssertNil(snapshot.devices.first?.linkActive)
    }
}

final class MachineReaderTests: XCTestCase {
    func testFirmwarePortNumberUsesLittleEndianAndRejectsMalformedData() {
        XCTAssertEqual(MachineReader.integer(Data([2, 0, 0, 0])), 2)
        XCTAssertEqual(MachineReader.integer(NSNumber(value: 4)), 4)
        XCTAssertNil(MachineReader.integer(Data([2])))
        XCTAssertNil(MachineReader.integer("2"))
    }

    func testOnlyExplicitlyBuiltInKnownConnectorsBecomePhysicalRoutes() {
        let valid: [String: Any] = ["BuiltIn": true, "PortNumber": 2, "PortTypeDescription": "USB-C"]
        XCTAssertEqual(MachineReader.route(properties: valid), PortRoute(connector: .usbC, number: 2))
        for change: [String: Any] in [
            ["BuiltIn": false], ["PortNumber": 0], ["PortNumber": -1], ["PortTypeDescription": "Unknown"],
        ] {
            XCTAssertNil(MachineReader.route(properties: valid.merging(change) { _, new in new }))
        }
        XCTAssertNil(MachineReader.route(properties: [:]))
    }
}

final class PortMapperTests: XCTestCase {
    private func device(
        _ id: String = "device", kind: DeviceKind = .usb, route: PortRoute? = nil,
        parent: String? = nil, internalDevice: Bool = false
    ) -> PortDevice {
        PortDevice(
            id: id, kind: kind, name: id, subtitle: "Test", connection: "Test",
            isInternal: internalDevice, parentID: parent, route: route)
    }

    private let c2 = PortRoute(connector: .usbC, number: 2)
    private let c4 = PortRoute(connector: .usbC, number: 4)

    func testUSBRouteAndFirmwareLocationMapToOfficialDiagram() throws {
        let machine = MachineInfo(
            identifier: "Mac14,12",
            connectors: [
                ConnectorObservation(route: c2, location: "back-left-middle")
            ])
        let mapping = try XCTUnwrap(
            PortMapper.associations(devices: [device(route: c2)], machine: machine)["device"])
        XCTAssertEqual(mapping.portID, "rear.usb-c.2")
        XCTAssertEqual(mapping.confidence, .system)
    }

    func testMissingPhysicalLocationIsAlwaysLabelledInferred() throws {
        let item = device(route: PortRoute(connector: .usbA, number: 2))
        let mapping = try XCTUnwrap(
            PortMapper.associations(devices: [item], machine: MachineInfo(identifier: "Mac14,12"))[item.id])
        XCTAssertEqual(mapping.portID, "rear.usb-a.2")
        XCTAssertEqual(mapping.confidence, .inferred)
    }

    func testDownstreamStorageAndNetworkInheritHubRootAndCalibrationKey() throws {
        let hub = device("hub", route: c2)
        let storage = device("disk", kind: .storage, parent: "hub")
        let network = device("net", kind: .network, parent: "hub")
        let devices = [hub, storage, network]
        let mapped = PortMapper.associations(
            devices: devices, machine: MachineInfo(identifier: "Mac14,12"),
            overrides: ["usb-c:2": "rear.usb-c.4"])
        for item in devices {
            XCTAssertEqual(mapped[item.id]?.portID, "rear.usb-c.4")
            XCTAssertEqual(mapped[item.id]?.confidence, .manual)
            XCTAssertEqual(PortMapper.calibrationKey(for: item, devices: devices), "usb-c:2")
        }
    }

    func testParentCycleAndMissingParentHaveNoInventedRoute() {
        let a = device("a", parent: "b")
        let b = device("b", parent: "a")
        XCTAssertNil(PortMapper.resolvedRoute(for: a, devices: [a, b]))
        XCTAssertNil(PortMapper.resolvedRoute(for: a, devices: [a]))
        XCTAssertEqual(PortMapper.calibrationKey(for: a, devices: [a, b]), "session:a")
    }

    func testSingleDisplayAndSingleVideoSignalGiveAnExplicitInference() throws {
        let machine = MachineInfo(
            identifier: "Mac14,12",
            connectors: [
                ConnectorObservation(route: c4, location: "back-right", hasDisplaySignal: true)
            ])
        let mapping = try XCTUnwrap(
            PortMapper.associations(devices: [device(kind: .display)], machine: machine)["device"])
        XCTAssertEqual(mapping.portID, "rear.usb-c.4")
        XCTAssertEqual(mapping.confidence, .inferred)
    }

    func testMultipleDisplaysOrVideoSignalsDoNotGuessIdentity() {
        let display = device(kind: .display)
        let video = ConnectorObservation(route: c4, hasDisplaySignal: true)
        let another = ConnectorObservation(
            route: PortRoute(connector: .hdmi, number: 1), hasDisplaySignal: true)
        XCTAssertTrue(
            PortMapper.associations(
                devices: [display, device("other", kind: .display)],
                machine: MachineInfo(identifier: "Mac14,12", connectors: [video])
            ).isEmpty)
        XCTAssertTrue(
            PortMapper.associations(
                devices: [display],
                machine: MachineInfo(identifier: "Mac14,12", connectors: [video, another])
            ).isEmpty)
        XCTAssertTrue(
            PortMapper.associations(devices: [display], machine: MachineInfo(identifier: "Mac14,12")).isEmpty)
    }

    func testUniqueHDMISignalMapsSingleDisplayAsInferred() {
        let machine = MachineInfo(
            identifier: "Mac14,12",
            connectors: [
                ConnectorObservation(route: PortRoute(connector: .hdmi, number: 1), hasDisplaySignal: true)
            ])
        XCTAssertEqual(
            PortMapper.associations(devices: [device(kind: .display)], machine: machine)["device"]?.portID,
            "rear.hdmi.1")
    }

    func testIncompatibleOrUnknownManualOverridesAreIgnored() {
        let item = device(route: c2)
        let machine = MachineInfo(identifier: "Mac14,12")
        for target in ["rear.hdmi.1", "rear.usb-c.99", "front.usb-c.1"] {
            let mapping = PortMapper.associations(
                devices: [item], machine: machine, overrides: ["usb-c:2": target])[item.id]
            XCTAssertEqual(mapping?.portID, "rear.usb-c.2")
            XCTAssertEqual(mapping?.confidence, .inferred)
        }
    }

    func testDisplayWithoutStableRouteCanBeCalibratedForSession() {
        let item = device(kind: .display)
        let mapping = PortMapper.associations(
            devices: [item], machine: MachineInfo(identifier: "Mac14,12"),
            overrides: ["session:device": "rear.hdmi.1"])[item.id]
        XCTAssertEqual(mapping?.confidence, .manual)
        XCTAssertEqual(mapping?.portID, "rear.hdmi.1")
        XCTAssertTrue(mapping?.explanation.contains("本次运行") == true)
    }

    func testInternalDevicesAndUnknownModelsHaveNoAssociations() {
        XCTAssertTrue(
            PortMapper.associations(
                devices: [device(route: c2, internalDevice: true)],
                machine: MachineInfo(identifier: "Mac14,12")
            ).isEmpty)
        XCTAssertTrue(
            PortMapper.associations(
                devices: [device(route: c2)], machine: MachineInfo(identifier: "Mac99,99"),
                overrides: ["usb-c:2": "rear.usb-c.1"]
            ).isEmpty)
    }

    func test2024DoesNotGuessFrontOrRearFromPortNumber() {
        let item = device(route: c2)
        XCTAssertTrue(
            PortMapper.associations(devices: [item], machine: MachineInfo(identifier: "Mac16,10")).isEmpty)
        let mapped = PortMapper.associations(
            devices: [item],
            machine: MachineInfo(
                identifier: "Mac16,10", connectors: [ConnectorObservation(route: c2, location: "front-right")]
            ))
        XCTAssertEqual(mapped[item.id]?.portID, "front.usb-c.2")
    }

    func testUnexpectedFirmwareLocationDoesNotFallBackToOrdinalGuess() {
        let machine = MachineInfo(
            identifier: "Mac14,12", connectors: [ConnectorObservation(route: c2, location: "unrecognized")])
        XCTAssertTrue(PortMapper.associations(devices: [device(route: c2)], machine: machine).isEmpty)
    }

    func testThunderboltReceptacleNumberIsInferredAndCalibrationIsSeparateFromIOPort() {
        let item = device(kind: .thunderbolt, route: c2)
        let machine = MachineInfo(
            identifier: "Mac14,12",
            connectors: [ConnectorObservation(route: c2, location: "back-left-middle")])
        let mapping = PortMapper.associations(
            devices: [item], machine: machine, overrides: ["usb-c:2": "rear.usb-c.4"])[item.id]
        XCTAssertEqual(mapping?.confidence, .inferred)
        XCTAssertEqual(mapping?.portID, "rear.usb-c.2")
        XCTAssertEqual(mapping?.calibrationKey, "thunderbolt:usb-c:2")
    }
}

final class ThunderboltRouteTests: XCTestCase {
    func testSingleReceptaclePassesReportedRouteToDaisyChain() throws {
        let json = """
            {"SPThunderboltDataType":[{"_name":"bus0",
              "receptacle_1_tag":{"receptacle_id_key":"2"},
              "_items":[{"device_name_key":"Dock","_items":[{"device_name_key":"Drive"}]}]}]}
            """
        let devices = try ProfilerParser.parse(Data(json.utf8))
        XCTAssertEqual(devices.count, 3)
        XCTAssertTrue(devices.allSatisfy { $0.route == PortRoute(connector: .thunderbolt, number: 2) })
        XCTAssertEqual(devices.last?.parentID, devices.dropFirst().first?.id)
    }

    func testMultipleReceptaclesDoNotAssignChildrenToAnArbitraryRoot() throws {
        let json = """
            {"SPThunderboltDataType":[{"_name":"bus0",
              "receptacle_1_tag":{"receptacle_id_key":"1"}, "receptacle_2_tag":{},
              "_items":[{"device_name_key":"Dock"}]}]}
            """
        let devices = try ProfilerParser.parse(Data(json.utf8))
        XCTAssertNil(devices.last?.route)
        XCTAssertNil(
            devices.first { $0.name == "Thunderbolt / USB4 · 1" && $0.id.hasSuffix("receptacle_2_tag") }?
                .route)
        XCTAssertEqual(devices.filter { $0.route != nil }.count, 1)
    }
}
