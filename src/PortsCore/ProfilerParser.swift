import Foundation

public enum ProfilerParser {
    public static func parse(_ data: Data, builtInDisplayIDs: Set<String> = []) throws -> [PortDevice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        var devices: [PortDevice] = []
        for bus in root["SPThunderboltDataType"] as? [[String: Any]] ?? [] {
            let busID = bus["domain_uuid_key"] as? String ?? bus["_name"] as? String ?? "unknown"
            let ports = bus.keys.filter { $0.hasPrefix("receptacle_") && $0.hasSuffix("_tag") }.sorted()
            let rootNumbers = ports.compactMap { key -> Int? in
                guard let port = bus[key] as? [String: Any], let number = port["receptacle_id_key"] as? String
                else { return nil }
                return Int(number)
            }
            let rootRoute =
                ports.count == 1 && rootNumbers.count == 1 && rootNumbers[0] > 0
                ? PortRoute(connector: .thunderbolt, number: rootNumbers[0]) : nil
            for key in ports {
                guard let port = bus[key] as? [String: Any] else { continue }
                let number = port["receptacle_id_key"] as? String ?? String(ports.firstIndex(of: key) ?? 0)
                let status = port["receptacle_status_key"] as? String ?? "unknown"
                let disconnected = status == "receptacle_no_devices_connected"
                let fields = [
                    DeviceField("端口信息", "系统端口编号", number),
                    DeviceField("端口信息", "总线", bus["_name"] as? String ?? "Thunderbolt / USB4"),
                    DeviceField("端口信息", "链路能力", port["current_speed_key"] as? String ?? "系统未提供"),
                    DeviceField("端口信息", "雷雳链路", disconnected ? "未建立雷雳链路" : status),
                    DeviceField("端口信息", "说明", "普通 USB / DP 设备可能仍在使用此 USB-C 接口"),
                ]
                devices.append(
                    PortDevice(
                        id: "tb-port:\(busID):\(key)", kind: .thunderbolt,
                        name: "Thunderbolt / USB4 · \(number)", subtitle: disconnected ? "未建立雷雳链路" : "雷雳端口",
                        connection: port["current_speed_key"] as? String ?? "系统未提供",
                        isPort: true, fields: fields,
                        route: (port["receptacle_id_key"] as? String).flatMap(Int.init).flatMap {
                            $0 > 0 ? PortRoute(connector: .thunderbolt, number: $0) : nil
                        }
                    ))
            }
            parseThunderboltChildren(
                bus["_items"] as? [[String: Any]] ?? [], parent: busID, route: rootRoute, into: &devices)
        }
        for gpu in root["SPDisplaysDataType"] as? [[String: Any]] ?? [] {
            for display in gpu["spdisplays_ndrvs"] as? [[String: Any]] ?? [] {
                if display["spdisplays_connection_type"] as? String == "spdisplays_internal" { continue }
                let id =
                    display["_spdisplays_displayID"] as? String
                    ?? [
                        display["_spdisplays_display-vendor-id"], display["_spdisplays_display-product-id"],
                        display["_name"],
                    ]
                    .compactMap { $0 as? String }.joined(separator: ":")
                if builtInDisplayIDs.contains(id) { continue }
                let name = display["_name"] as? String ?? "外接显示器"
                let resolution =
                    display["_spdisplays_resolution"] as? String
                    ?? display["spdisplays_resolution"] as? String ?? "系统未提供"
                var fields = [
                    DeviceField("显示信息", "桌面分辨率", resolution),
                    DeviceField(
                        "显示信息", "GPU", gpu["sppci_model"] as? String ?? gpu["_name"] as? String ?? "系统未提供"),
                    DeviceField(
                        "显示信息", "主显示器", display["spdisplays_main"] as? String == "spdisplays_yes" ? "是" : "否"),
                    DeviceField(
                        "显示信息", "镜像显示", display["spdisplays_mirror"] as? String == "spdisplays_on" ? "是" : "否"
                    ),
                ]
                for (key, label) in [
                    ("_spdisplays_pixels", "渲染像素"),
                    ("_spdisplays_display-vendor-id", "厂商 ID"),
                    ("_spdisplays_display-product-id", "产品 ID"),
                    ("_spdisplays_display-serial-number", "序列号"),
                    ("spdisplays_connection_type", "连接类型"),
                ] {
                    if let value = display[key] as? String {
                        fields.append(DeviceField("显示信息", label, value))
                    }
                }
                devices.append(
                    PortDevice(
                        id: "display:\(id)", kind: .display, name: name,
                        subtitle: "外接显示器", connection: resolution, fields: fields
                    ))
            }
        }
        return devices
    }

    private static func parseThunderboltChildren(
        _ children: [[String: Any]], parent: String, route: PortRoute?, parentID: String? = nil,
        into devices: inout [PortDevice]
    ) {
        for (index, item) in children.enumerated() {
            let uid = item["switch_uid_key"] as? String ?? item["route_string_key"] as? String ?? "\(index)"
            let id = "tb:\(parent):\(uid)"
            let name = item["device_name_key"] as? String ?? item["_name"] as? String ?? "雷雳设备"
            var fields = [DeviceField("连接信息", "上级总线 / 设备", parent)]
            for (key, label) in [
                ("vendor_name_key", "厂商"), ("device_name_key", "设备型号"),
                ("switch_uid_key", "设备 UID"), ("route_string_key", "路由"),
                ("current_speed_key", "链路速率"), ("link_speed_key", "协商速率"),
                ("device_revision_key", "设备版本"), ("firmware_version_key", "固件版本"),
            ] {
                if let value = item[key] as? String { fields.append(DeviceField("设备信息", label, value)) }
            }
            devices.append(
                PortDevice(
                    id: id, kind: .thunderbolt, name: name, subtitle: "Thunderbolt / USB4 设备",
                    connection: item["current_speed_key"] as? String ?? item["link_speed_key"] as? String
                        ?? "已连接",
                    parentID: parentID, fields: fields, route: route
                ))
            parseThunderboltChildren(
                item["_items"] as? [[String: Any]] ?? [], parent: id, route: route, parentID: id,
                into: &devices)
        }
    }
}
