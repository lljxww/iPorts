import CoreFoundation
import Foundation

public enum BluetoothParser {
    public static func parse(_ data: Data) throws -> [PortDevice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw BluetoothReportError.invalidStructure }
        guard let rawReports = root["SPBluetoothDataType"] else { return [] }
        guard let reports = rawReports as? [[String: Any]] else {
            throw BluetoothReportError.invalidStructure
        }

        var devices: [PortDevice] = []
        for report in reports {
            let controller = report["controller_properties"] as? [String: Any]
            if text(controller?["controller_state"]) == "attrib_off" { continue }
            // New reports separate connected devices; older reports mark each paired record explicitly.
            for key in ["device_connected", "devices_list"] where report[key] != nil {
                guard let entries = report[key] as? [[String: Any]] else {
                    throw BluetoothReportError.invalidStructure
                }
                for entry in entries {
                    let records: [(String, [String: Any])]
                    if entry["device_address"] != nil || entry["_name"] != nil {
                        records = [(text(entry["_name"]) ?? "蓝牙设备", entry)]
                    } else {
                        records = entry.keys.sorted().compactMap { name in
                            (entry[name] as? [String: Any]).map { (name, $0) }
                        }
                        if records.isEmpty { throw BluetoothReportError.invalidStructure }
                    }
                    for (name, info) in records {
                        let connected = flag(info["device_connected"])
                        if key == "devices_list" ? connected != true : connected == false { continue }
                        devices.append(makeDevice(name: name, info: info, index: devices.count))
                    }
                }
            }
            guard
                report.isEmpty || controller != nil || report["local_device_title"] != nil
                    || report["device_connected"] != nil || report["devices_list"] != nil
                    || report["device_not_connected"] != nil
            else { throw BluetoothReportError.invalidStructure }
        }

        // Addresses, rather than product names, distinguish two identical headphones or mice.
        var seen = Set<String>()
        return devices.filter { seen.insert($0.id).inserted }.sorted {
            if $0.name == $1.name { return $0.id < $1.id }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func makeDevice(name: String, info: [String: Any], index: Int) -> PortDevice {
        let address = text(info["device_address"]).flatMap(normalizedAddress)
        let type = text(info["device_minorType"]) ?? text(info["device_majorType"])
        let transport: String
        switch text(info["device_connectionType"])?.lowercased() {
        case "le", "ble", "low energy", "bluetooth low energy": transport = "Bluetooth LE"
        case "br/edr", "classic", "bluetooth classic": transport = "Bluetooth Classic"
        default: transport = "Bluetooth"
        }
        var fields = [
            DeviceField("蓝牙信息", "连接状态", "已连接"),
            DeviceField("蓝牙信息", "连接方式", transport),
            DeviceField("蓝牙信息", "设备类型", type.map(deviceType) ?? "系统未提供"),
            DeviceField("蓝牙信息", "蓝牙地址", address ?? "系统未提供"),
        ]
        if let paired = flag(info["device_paired"]) {
            fields.append(DeviceField("蓝牙信息", "已配对", paired ? "是" : "否"))
        }
        for (key, label) in [
            ("device_manufacturer", "厂商"), ("device_vendorID", "厂商 ID"),
            ("device_productID", "产品 ID"), ("device_firmwareVersion", "固件版本"),
            ("device_serialNumber", "序列号"), ("device_transportType", "系统传输类型"),
            ("device_connectionType", "系统连接类型"), ("device_services", "服务 / 配置文件"),
            ("device_majorType", "主要类别"), ("device_minorType", "系统设备类型"),
        ] {
            if let value = text(info[key]) { fields.append(DeviceField("设备信息", label, value)) }
        }
        if let rssi = text(info["device_rssi"]) {
            let number = rssi.replacingOccurrences(of: "dBm", with: "").trimmingCharacters(in: .whitespaces)
            if let value = Int(number), (-127 ... -1).contains(value) {
                fields.append(DeviceField("信号", "RSSI", "\(value) dBm"))
            }
        }
        for (key, label) in [
            ("device_batteryLevel", "设备电量"), ("device_batteryLevelMain", "设备电量（主）"),
            ("device_batteryLevelLeft", "左耳电量"), ("device_batteryLevelRight", "右耳电量"),
            ("device_batteryLevelCase", "充电盒电量"),
        ] {
            if let value = text(info[key]), let percentage = batteryPercentage(value) {
                fields.append(DeviceField("电池", label, percentage))
            }
        }
        if !fields.contains(where: { $0.group == "电池" }) {
            fields.append(DeviceField("电池", "设备电量", "系统未提供"))
        }
        if let charging = flag(info["device_isCharging"]) {
            fields.append(DeviceField("电池", "充电状态", charging ? "正在充电" : "未充电"))
        }
        fields.append(DeviceField("信号", "说明", "RSSI 和电量为系统最近报告值，不代表实时功耗或传输速率。"))
        return PortDevice(
            id: "bluetooth:\(address ?? "unaddressed:\(name):\(index)")", kind: .bluetooth,
            name: name.isEmpty ? "蓝牙设备" : name,
            subtitle: type.map(deviceType) ?? "蓝牙设备", connection: transport,
            fields: fields, linkActive: true)
    }

    private static func text(_ raw: Any?) -> String? {
        let value: String?
        switch raw {
        case let string as String: value = string
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            value = number.stringValue
        default: return nil
        }
        guard let result = value?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
            return nil
        }
        return result
    }

    private static func flag(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        switch text(value)?.lowercased() {
        case "yes", "true", "attrib_yes", "1": return true
        case "no", "false", "attrib_no", "0": return false
        default: return nil
        }
    }

    private static func normalizedAddress(_ value: String) -> String? {
        let compact = value.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "").uppercased()
        guard compact.count == 12, compact.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        let characters = Array(compact)
        return stride(from: 0, to: 12, by: 2).map { String(characters[$0...$0 + 1]) }.joined(separator: ":")
    }

    private static func batteryPercentage(_ value: String) -> String? {
        let number = value.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let percentage = Double(number), percentage.isFinite, (0...100).contains(percentage) else {
            return nil
        }
        return String(format: "%g%%", percentage)
    }

    private static func deviceType(_ value: String) -> String {
        switch value.lowercased() {
        case "headphones", "headphone", "headset": "耳机"
        case "mouse": "鼠标"
        case "keyboard": "键盘"
        case "trackpad": "触控板"
        case "speaker", "loudspeaker": "扬声器"
        case "gamepad", "joystick", "game controller": "游戏控制器"
        case "phone": "手机"
        default: value
        }
    }
}

private enum BluetoothReportError: LocalizedError {
    case invalidStructure

    var errorDescription: String? { "系统未返回可识别的完整蓝牙报告。" }
}
