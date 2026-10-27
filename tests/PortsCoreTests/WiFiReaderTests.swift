import CoreWLAN
import Foundation
import SystemConfiguration
import XCTest

@testable import PortsCore

final class WiFiReaderTests: XCTestCase {
    private func connected() -> WiFiObservation {
        var value = WiFiObservation(interfaceName: "en1")
        value.poweredOn = true
        value.serviceEnabled = true
        value.linkActive = true
        value.rate = 864
        value.phy = .mode11ax
        value.channel = 149
        value.band = .band5GHz
        value.width = .width80MHz
        value.rssi = -64
        value.noise = -94
        return value
    }

    private func field(_ label: String, in device: PortDevice) -> String? {
        device.fields.first { $0.label == label }?.value
    }

    func testWiFiAndEthernetAreRecognizedByInterfaceType() {
        XCTAssertEqual(NetworkReader.kind(for: kSCNetworkInterfaceTypeIEEE80211 as String), .wifi)
        XCTAssertEqual(NetworkReader.kind(for: kSCNetworkInterfaceTypeEthernet as String), .network)
        for type in [nil, "", "PPP", "Loopback", "Bridge", "VPN"] {
            XCTAssertNil(NetworkReader.kind(for: type))
        }
    }

    func testHiddenSSIDDoesNotHideConnectedWiFiOrSignal() {
        let device = WiFiReader.device(from: connected())
        XCTAssertEqual(device.kind, .wifi)
        XCTAssertEqual(device.id, "wifi:en1")
        XCTAssertEqual(device.linkActive, true)
        XCTAssertEqual(device.subtitle, "已连接无线网络")
        XCTAssertTrue(field("网络名称 (SSID)", in: device)?.contains("定位权限") == true)
        XCTAssertEqual(device.connection, "864 Mb/s")
        XCTAssertEqual(field("信号强度 (RSSI)", in: device), "-64 dBm")
        XCTAssertEqual(field("信噪比", in: device), "30 dB")
        XCTAssertNil(device.power)
        XCTAssertNil(device.route)
        XCTAssertFalse(device.isInternal)
    }

    func testDisconnectedLinkSuppressesStaleNetworkMeasurements() {
        var value = connected()
        value.ssid = "Previous Network"
        value.bssid = "02:00:00:00:00:01"
        value.addresses = ["192.0.2.1"]
        value.linkActive = false
        let device = WiFiReader.device(from: value)
        XCTAssertEqual(device.linkActive, false)
        XCTAssertEqual(device.subtitle, "未连接无线网络")
        XCTAssertEqual(device.connection, "系统未提供")
        XCTAssertFalse(device.report.contains("Previous Network"))
        for label in ["信号强度 (RSSI)", "当前协议", "信道", "IP 地址"] {
            XCTAssertNil(field(label, in: device))
        }
        value.poweredOn = false
        value.linkActive = true
        let poweredOff = WiFiReader.device(from: value)
        XCTAssertEqual(poweredOff.linkActive, false)
        XCTAssertEqual(poweredOff.subtitle, "Wi-Fi 已关闭")
    }

    func testUnavailableStateIsUnknownAndCoreWLANAssociationCanProvideFallback() {
        var value = WiFiObservation(interfaceName: "en7")
        XCTAssertNil(WiFiReader.device(from: value).linkActive)
        XCTAssertEqual(WiFiReader.device(from: value).subtitle, "无线连接状态未提供")
        value.serviceEnabled = false
        XCTAssertEqual(WiFiReader.device(from: value).subtitle, "网络服务未启用")
        value.serviceEnabled = true
        value.phy = .mode11ac
        XCTAssertNil(value.connected)
        value.channel = 36
        XCTAssertEqual(value.connected, true)
        value.phy = .modeNone
        value.channel = 0
        value.ssid = ""
        XCTAssertNil(value.connected)
        value.bssid = "02:00:00:00:00:01"
        XCTAssertEqual(value.connected, true)
    }

    func testInvalidRatesAndUnknownSignalNeverProduceFabricatedValues() {
        for rate in [0, -1, Double.nan, Double.infinity] {
            var value = connected()
            value.rate = rate
            value.rssi = 0
            value.noise = 0
            let device = WiFiReader.device(from: value)
            XCTAssertEqual(device.connection, "系统未提供")
            XCTAssertNil(field("信号强度 (RSSI)", in: device))
            XCTAssertNil(field("噪声", in: device))
            XCTAssertNil(field("信噪比", in: device))
        }
        var value = connected()
        value.noise = -50
        XCTAssertNil(field("信噪比", in: WiFiReader.device(from: value)))
    }

    func testAuthorizedNetworkDetailsAndStableInterfaceIdentityAcrossRoaming() {
        var value = connected()
        value.ssid = "Test Wi-Fi"
        value.bssid = "02:00:00:00:00:01"
        value.mac = "02:00:00:00:00:02"
        value.security = .wpa3Personal
        value.addresses = ["192.0.2.1", "2001:db8::1"]
        let device = WiFiReader.device(from: value)
        XCTAssertEqual(field("网络名称 (SSID)", in: device), "Test Wi-Fi")
        XCTAssertEqual(field("接入点 (BSSID)", in: device), value.bssid)
        XCTAssertEqual(field("频段", in: device), "5 GHz")
        XCTAssertEqual(field("信道宽度", in: device), "80 MHz")
        XCTAssertEqual(field("安全模式", in: device), "WPA3 Personal")
        XCTAssertEqual(field("IP 地址", in: device), "192.0.2.1\n2001:db8::1")
        XCTAssertEqual(Set(device.fields.map(\.id)).count, device.fields.count)
        value.ssid = "Another Test Network"
        value.bssid = "02:00:00:00:00:03"
        XCTAssertEqual(WiFiReader.device(from: value).id, device.id)
        XCTAssertNotEqual(WiFiReader.device(from: WiFiObservation(interfaceName: "en9")).id, device.id)
    }

    func testUnknownWiFiProtocolStaysWiFiAndReportUsesNetworkTrafficLabels() throws {
        var value = connected()
        value.phy = .modeNone
        var device = WiFiReader.device(from: value)
        device.transfer = TransferRate(readBytesPerSecond: 2_048, writeBytesPerSecond: 1_024)
        let connection = try XCTUnwrap(
            PortConnectionBuilder.build(
                devices: [device], machine: nil, profile: nil, associations: [:]
            ).first)
        XCTAssertEqual(connection.connectionDescription, "Wi-Fi · 864 Mb/s")
        XCTAssertTrue(connection.isConnected)
        XCTAssertNil(connection.portID)
        XCTAssertTrue(connection.report.contains("网络接收"))
        XCTAssertTrue(connection.report.contains("网络发送"))
        XCTAssertFalse(connection.report.contains("磁盘读取"))
        XCTAssertTrue(connection.report.contains("并非互联网测速"))
    }
}
