import AppKit
import Foundation
import XCTest

@testable import PortsCore

final class OfficialCatalogTests: XCTestCase {
    func testAllSevenFamiliesHaveExactIdentifiersAndBundledArtwork() throws {
        let models = AppleMacCatalog.bundled
        XCTAssertGreaterThan(models.count, 140)
        XCTAssertEqual(Set(models.map(\.family)), Set(MacFamily.allCases.filter { $0 != .unknown }))
        for model in models {
            XCTAssertTrue(model.isValid, model.id)
            let url = try XCTUnwrap(
                AppleMacCatalog.resourceURL(
                    name: model.imageName, extension: "png", directory: "ModelArtwork"))
            XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: url)), model.name)
        }
        for identifier in [
            "MacBookPro18,1", "Mac14,2", "MacBook10,1", "iMacPro1,1", "Mac13,1", "MacPro7,1", "Mac14,12",
        ] {
            XCTAssertFalse(AppleMacCatalog.models(for: identifier).isEmpty, identifier)
        }
        XCTAssertTrue(AppleMacCatalog.models(for: "Mac999,99").isEmpty)
    }

    func testMultipleVariantsAreRetainedRatherThanInventingAnExactYear() {
        XCTAssertGreaterThan(AppleMacCatalog.models(for: "MacBookPro15,1").count, 1)
        let variants = AppleMacCatalog.models(for: "MacPro7,1")
        XCTAssertEqual(variants.count, 2)
        XCTAssertEqual(Set(variants.map(\.imageName)).count, 2)
    }

    func testParserSeparatesModelsWithinOneYearHeadingAndResolvesRelativeSpecs() throws {
        let html = """
            <h3>2009</h3><img src="https://cdsassets.apple.com/late.png">
            <p>MacBook (13-inch, Late 2009)</p><p><b>Model Identifier:</b> MacBook6,1</p>
            <p><a href="/en-us/111001">Tech Specs: MacBook</a></p>
            <img src="https://cdsassets.apple.com/early.png">
            <p>MacBook (13-inch, Early 2009)</p><p>Model Identifier: MacBook5,2</p>
            <p><a href="https://support.apple.com/en-us/111002">Tech Specs</a></p>
            """
        let records = try AppleArticleParser.parse(html, family: .macBook)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].identifiers, ["MacBook6,1"])
        XCTAssertEqual(records[1].identifiers, ["MacBook5,2"])
        XCTAssertTrue(records[0].imageURL.path.hasSuffix("late.png"))
        XCTAssertTrue(records[1].name.contains("Early"))
        XCTAssertEqual(records[0].specsURL?.absoluteString, "https://support.apple.com/en-us/111001")
    }

    func testChangedMarkupOrThirdPartyImagesCannotReplaceCatalog() throws {
        XCTAssertThrowsError(try AppleArticleParser.parse("<h2>No model data</h2>", family: .macBookPro))
        XCTAssertThrowsError(
            try AppleArticleParser.parse(
                "<h2>MacBook Pro</h2><img src=\"https://example.com/mac.png\"><p>Model Identifier: Mac17,2</p>",
                family: .macBookPro))
        for value in [
            "http://support.apple.com/test", "https://support.apple.com.evil.test/test",
            "https://user@support.apple.com/test", "https://support.apple.com:444/test",
            "file:///tmp/image.png",
        ] {
            XCTAssertFalse(AppleMacCatalog.isAppleURL(try XCTUnwrap(URL(string: value))))
        }
        for identifier in ["", "Mac14", "Mac14,12/../../", "Mac14,12&serial=secret", "Mac14,12\n"] {
            XCTAssertFalse(AppleMacCatalog.isIdentifier(identifier))
        }
    }

    func testInvalidCacheIsReportedAndExistingFileIsNotModified() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = AppleCatalogService(directory: directory)
        let missing = try await service.cachedModels()
        XCTAssertNil(missing)
        let invalid = Data("{\"version\":99,\"updatedAt\":\"today\",\"models\":[]}".utf8)
        let file = directory.appendingPathComponent("catalog.json")
        try invalid.write(to: file)
        do {
            _ = try await service.cachedModels()
            XCTFail("Invalid cache must throw")
        } catch { XCTAssertEqual(try Data(contentsOf: file), invalid) }
    }
}

final class UniversalLayoutTests: XCTestCase {
    private func item(_ id: String, kind: DeviceKind = .usb, route: PortRoute? = nil, parent: String? = nil)
        -> PortDevice
    {
        PortDevice(
            id: id, kind: kind, name: id, subtitle: "Test", connection: "Test", parentID: parent, route: route
        )
    }

    func testUnknownFutureMacRetainsTopologyAndDeviceSelectionWithoutAnOfficialImage() throws {
        let route = PortRoute(connector: .usbC, number: 1)
        let device = item("usb", route: route)
        let machine = MachineInfo(identifier: "Mac999,99", connectors: [ConnectorObservation(route: route)])
        let profile = MacModelCatalog.resolvedProfile(machine: machine, devices: [device])
        XCTAssertEqual(profile.family, .unknown)
        XCTAssertNil(profile.officialModel)
        XCTAssertNil(MacModelCatalog.artworkURL(for: profile))
        let mapping = try XCTUnwrap(
            PortMapper.associations(devices: [device], machine: machine, profile: profile)[device.id])
        XCTAssertEqual(mapping.confidence, .topology)
        XCTAssertEqual(profile.ports.first?.routeKey, route.key)
        XCTAssertEqual(mapping.portID, profile.ports.first?.id)
    }

    func testIntelRootPathsRemainDistinctAndHubChildrenShareOneRoot() {
        let a = PortRoute(connector: .usb, number: 0, topologyPath: "IOService:/PCI/XHC/HS01")
        let b = PortRoute(connector: .usb, number: 0, topologyPath: "IOService:/PCI/XHC/HS02")
        XCTAssertNotEqual(a.key, b.key)
        let devices = [
            item("hub", route: a), item("disk", kind: .storage, parent: "hub"), item("keyboard", route: b),
        ]
        let machine = MachineInfo(identifier: "MacBookPro15,1")
        let profile = MacModelCatalog.resolvedProfile(machine: machine, devices: devices)
        XCTAssertEqual(profile.ports.filter(\.isLogical).count, 2)
        let mappings = PortMapper.associations(devices: devices, machine: machine, profile: profile)
        XCTAssertEqual(mappings["hub"]?.portID, mappings["disk"]?.portID)
        XCTAssertNotEqual(mappings["hub"]?.portID, mappings["keyboard"]?.portID)
    }

    func testCustomLayoutWorksOnUnknownModelAndCanCalibrateUntypedUSBRoot() throws {
        let route = PortRoute(connector: .usb, number: 0, topologyPath: "IOService:/PCI/USB/root")
        let device = item("usb", route: route)
        let machine = MachineInfo(identifier: "Mac999,99")
        let custom = CustomPortLayout(ports: [CustomLayoutPort(id: "one", side: .left, connector: .usbA)])
        let profile = MacModelCatalog.resolvedProfile(
            machine: machine, devices: [device], customLayout: custom)
        let slot = try XCTUnwrap(profile.ports.first { !$0.isLogical })
        let mappings = PortMapper.associations(
            devices: [device], machine: machine, overrides: [route.key: slot.id], profile: profile)
        XCTAssertEqual(mappings[device.id]?.portID, slot.id)
        XCTAssertEqual(mappings[device.id]?.confidence, .manual)
    }

    func testInvalidCustomLayoutIsRejectedAndPortIDsSurviveReordering() {
        let port = CustomLayoutPort(id: "one", side: .left, connector: .usbA)
        XCTAssertFalse(CustomPortLayout(ports: [port, port]).isValid)
        XCTAssertFalse(
            CustomPortLayout(
                ports: (0..<65).map { CustomLayoutPort(id: String($0), side: .left, connector: .usbC) }
            ).isValid)
        let machine = MachineInfo(identifier: "Mac999,99")
        let other = CustomLayoutPort(id: "two", side: .left, connector: .usbA)
        let first = MacModelCatalog.resolvedProfile(
            machine: machine, devices: [], customLayout: CustomPortLayout(ports: [port, other]))
        let moved = MacModelCatalog.resolvedProfile(
            machine: machine, devices: [], customLayout: CustomPortLayout(ports: [other, port]))
        XCTAssertEqual(Set(first.ports.map(\.id)), Set(moved.ports.map(\.id)))
        XCTAssertEqual(first.ports.first?.id, moved.ports.dropFirst().first?.id)
    }

    func testMacBookAirAndProHaveDifferentPhysicalPortLayouts() throws {
        let air = try XCTUnwrap(MacModelCatalog.profile(for: "Mac14,2"))
        let pro = try XCTUnwrap(MacModelCatalog.profile(for: "MacBookPro18,1"))
        XCTAssertEqual(air.ports.filter { $0.connector == .usbC }.count, 2)
        XCTAssertEqual(pro.ports.filter { $0.connector == .usbC }.count, 3)
        XCTAssertTrue(air.diagrams.contains { $0.id == "left" })
        XCTAssertTrue(pro.ports.contains { $0.connector == .sd })
        XCTAssertFalse(air.ports.contains { $0.connector == .hdmi })
    }

    func testM3BaseProAndFourPortIMacDoNotBorrowOtherVariantsPortCounts() throws {
        let base = try XCTUnwrap(MacModelCatalog.profile(for: "Mac15,3"))
        let pro = try XCTUnwrap(MacModelCatalog.profile(for: "Mac15,6"))
        XCTAssertEqual(base.ports.filter { $0.connector == .usbC }.count, 2)
        XCTAssertEqual(pro.ports.filter { $0.connector == .usbC }.count, 3)
        XCTAssertEqual(
            MacModelCatalog.profile(for: "iMac21,1")?.ports.filter { $0.connector == .usbC }.count, 4)
        XCTAssertEqual(
            MacModelCatalog.profile(for: "iMac21,2")?.ports.filter { $0.connector == .usbC }.count, 2)
    }

    func testMultipleNativeEthernetConnectorsDoNotCollapseIntoOnePhysicalPort() {
        let machine = MachineInfo(identifier: "MacPro7,1")
        let first = item(
            "net1", kind: .network,
            route: PortRoute(connector: .ethernet, number: 1, topologyPath: "IOService:/ethernet0"))
        let second = item(
            "net2", kind: .network,
            route: PortRoute(connector: .ethernet, number: 1, topologyPath: "IOService:/ethernet1"))
        let devices = [first, second]
        let profile = MacModelCatalog.resolvedProfile(machine: machine, devices: devices)
        let mappings = PortMapper.associations(devices: devices, machine: machine, profile: profile)
        XCTAssertNotEqual(mappings[first.id]?.portID, mappings[second.id]?.portID)
        XCTAssertEqual(mappings[first.id]?.confidence, .topology)
    }

    func testClassicThunderboltCanBeCalibratedToThunderbolt2RatherThanUSBC() throws {
        let machine = MachineInfo(identifier: "Mac999,99")
        let device = item("tb", kind: .thunderbolt, route: PortRoute(connector: .thunderbolt, number: 1))
        let profile = MacModelCatalog.resolvedProfile(
            machine: machine, devices: [device],
            customLayout: CustomPortLayout(ports: [
                CustomLayoutPort(id: "tb2", side: .rear, connector: .thunderbolt2)
            ]))
        let candidate = try XCTUnwrap(
            PortMapper.compatiblePorts(for: device, profile: profile, devices: [device]).first)
        XCTAssertEqual(candidate.connector, .thunderbolt2)
        let mappings = PortMapper.associations(
            devices: [device], machine: machine,
            overrides: [PortMapper.calibrationKey(for: device, devices: [device]): candidate.id],
            profile: profile)
        XCTAssertEqual(mappings[device.id]?.confidence, .manual)
    }
}
