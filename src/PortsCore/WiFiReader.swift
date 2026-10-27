import CoreWLAN
import Foundation
import SystemConfiguration

struct WiFiObservation {
    let interfaceName: String
    var poweredOn: Bool?
    var serviceEnabled: Bool?
    var linkActive: Bool?
    var ssid: String?
    var bssid: String?
    var mac: String?
    var rate: Double = 0
    var phy: CWPHYMode = .modeNone
    var channel: Int = 0
    var band: CWChannelBand = .bandUnknown
    var width: CWChannelWidth = .widthUnknown
    var rssi: Int = 0
    var noise: Int = 0
    var security: CWSecurity = .unknown
    var country: String?
    var addresses: [String] = []

    var connected: Bool? {
        if poweredOn == false { return false }
        if let linkActive { return linkActive }
        // SSID/BSSID may be hidden by Location Services; a missing name is not a disconnection.
        if ssid?.isEmpty == false || bssid?.isEmpty == false
            || (phy != .modeNone && channel > 0)
        {
            return true
        }
        return nil
    }
}

enum WiFiReader {
    static func read(_ interface: SCNetworkInterface, name: String) -> PortDevice {
        let wlan = CWWiFiClient.shared().interface(withName: name)
        let state =
            SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(name)/Link" as CFString)
            as? [String: Any]
        let channel = wlan?.wlanChannel()
        var observation = WiFiObservation(interfaceName: name)
        observation.poweredOn = wlan?.powerOn()
        observation.serviceEnabled = wlan?.serviceActive()
        observation.linkActive = state?[kSCPropNetLinkActive as String] as? Bool
        observation.ssid = wlan?.ssid()
        observation.bssid = wlan?.bssid()
        observation.mac =
            wlan?.hardwareAddress() ?? SCNetworkInterfaceGetHardwareAddressString(interface) as String?
        observation.rate = wlan?.transmitRate() ?? 0
        observation.phy = wlan?.activePHYMode() ?? .modeNone
        observation.channel = channel?.channelNumber ?? 0
        observation.band = channel?.channelBand ?? .bandUnknown
        observation.width = channel?.channelWidth ?? .widthUnknown
        observation.rssi = wlan?.rssiValue() ?? 0
        observation.noise = wlan?.noiseMeasurement() ?? 0
        observation.security = wlan?.security() ?? .unknown
        observation.country = wlan?.countryCode()
        for family in ["IPv4", "IPv6"] {
            let value =
                SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(name)/\(family)" as CFString)
                as? [String: Any]
            observation.addresses += value?["Addresses"] as? [String] ?? []
        }
        return device(from: observation)
    }

    static func device(from value: WiFiObservation) -> PortDevice {
        let connected = value.connected
        let status: String
        if value.poweredOn == false {
            status = "Wi-Fi 已关闭"
        } else if connected == true {
            status = "已连接无线网络"
        } else if value.serviceEnabled == false {
            status = "网络服务未启用"
        } else {
            status = connected == false ? "未连接无线网络" : "无线连接状态未提供"
        }
        let rate =
            connected == true && value.rate.isFinite && value.rate > 0
            ? String(format: "%g Mb/s", value.rate) : "系统未提供"
        var fields = [
            DeviceField("无线网络", "接口名称", value.interfaceName),
            DeviceField("无线网络", "连接状态", status),
            DeviceField("无线网络", "Wi-Fi 电源", value.poweredOn.map { $0 ? "已开启" : "已关闭" } ?? "系统未提供"),
            DeviceField("无线网络", "网络服务", value.serviceEnabled.map { $0 ? "已启用" : "未启用" } ?? "系统未提供"),
            DeviceField(
                "无线网络", "网络名称 (SSID)",
                connected == true
                    ? available(value.ssid) ?? "系统未提供（可能受定位权限限制）" : "未连接或状态未提供"),
            DeviceField(
                "无线网络", "接入点 (BSSID)",
                connected == true
                    ? available(value.bssid) ?? "系统未提供（可能受定位权限限制）" : "未连接或状态未提供"),
            DeviceField("无线链路", "发送链路速率", rate),
        ]
        if connected == true {
            fields.append(DeviceField("无线链路", "当前协议", protocolName(value.phy)))
            if value.channel > 0 { fields.append(DeviceField("无线链路", "信道", "\(value.channel)")) }
            if let band = bandName(value.band) { fields.append(DeviceField("无线链路", "频段", band)) }
            if let width = widthName(value.width) { fields.append(DeviceField("无线链路", "信道宽度", width)) }
            if (-127 ... -1).contains(value.rssi) {
                fields.append(DeviceField("无线链路", "信号强度 (RSSI)", "\(value.rssi) dBm"))
            }
            if (-127 ... -1).contains(value.noise) {
                fields.append(DeviceField("无线链路", "噪声", "\(value.noise) dBm"))
                if (-127 ... -1).contains(value.rssi), value.rssi >= value.noise {
                    fields.append(DeviceField("无线链路", "信噪比", "\(value.rssi - value.noise) dB"))
                }
            }
            fields.append(DeviceField("无线链路", "安全模式", securityName(value.security)))
            if let country = available(value.country) {
                fields.append(DeviceField("无线链路", "国家 / 地区", country))
            }
            if !value.addresses.isEmpty {
                fields.append(DeviceField("网络信息", "IP 地址", value.addresses.joined(separator: "\n")))
            }
        }
        if let mac = available(value.mac) { fields.append(DeviceField("网络信息", "接口 MAC 地址", mac)) }
        fields.append(DeviceField("网络信息", "统计口径", "接口累计收发字节的采样差值；包含本地网络流量，并非互联网测速。"))
        return PortDevice(
            id: "wifi:\(value.interfaceName)", kind: .wifi, name: "Wi-Fi · \(value.interfaceName)",
            subtitle: status, connection: rate, isPort: true, fields: fields, linkActive: connected)
    }

    static func protocolName(_ mode: CWPHYMode) -> String {
        switch mode {
        case .mode11a: "802.11a"
        case .mode11b: "802.11b"
        case .mode11g: "802.11g"
        case .mode11n: "802.11n · Wi-Fi 4"
        case .mode11ac: "802.11ac · Wi-Fi 5"
        case .mode11ax: "802.11ax · Wi-Fi 6 / 6E"
        case .modeNone: "系统未提供"
        default: "802.11（系统模式 \(mode.rawValue)）"
        }
    }

    private static func available(_ text: String?) -> String? { text?.isEmpty == false ? text : nil }

    private static func bandName(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: nil
        }
    }

    private static func widthName(_ width: CWChannelWidth) -> String? {
        switch width {
        case .width20MHz: "20 MHz"
        case .width40MHz: "40 MHz"
        case .width80MHz: "80 MHz"
        case .width160MHz: "160 MHz"
        default: nil
        }
    }

    private static func securityName(_ security: CWSecurity) -> String {
        switch security {
        case .none: "开放网络"
        case .WEP: "WEP"
        case .wpaPersonal: "WPA Personal"
        case .wpaPersonalMixed: "WPA / WPA2 Personal"
        case .wpa2Personal: "WPA2 Personal"
        case .personal: "Personal"
        case .dynamicWEP: "Dynamic WEP"
        case .wpaEnterprise: "WPA Enterprise"
        case .wpaEnterpriseMixed: "WPA / WPA2 Enterprise"
        case .wpa2Enterprise: "WPA2 Enterprise"
        case .enterprise: "Enterprise"
        case .wpa3Personal: "WPA3 Personal"
        case .wpa3Enterprise: "WPA3 Enterprise"
        case .wpa3Transition: "WPA2 / WPA3 Personal"
        default: "系统未提供"
        }
    }
}
