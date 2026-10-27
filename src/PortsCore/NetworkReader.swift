import Darwin
import Foundation
import IOKit
import SystemConfiguration

struct NetworkCounter {
    let bytes: ByteCounters
}

enum NetworkReader {
    static func read() throws -> RegistrySnapshot {
        var result = RegistrySnapshot()
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return result }
        var counters: [UInt32: NetworkCounter] = [:]
        do { counters = try readCounters() } catch {
            result.notices.append("网络流量计数读取失败，连接信息仍可查看：\(error.localizedDescription)")
        }
        for interface in interfaces {
            guard
                let kind = kind(for: SCNetworkInterfaceGetInterfaceType(interface) as String?),
                let bsd = SCNetworkInterfaceGetBSDName(interface) as String?
            else { continue }
            if kind == .wifi {
                let device = WiFiReader.read(interface, name: bsd)
                result.devices.append(device)
                if device.linkActive == true, let counter = counters[if_nametoindex(bsd)] {
                    result.counters[device.id] = counter.bytes
                }
                continue
            }
            let entry = IOServiceGetMatchingService(
                kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
            guard entry != 0 else { continue }
            defer { IOObjectRelease(entry) }
            var model: String?
            var parentID: String?
            var physical = false
            Registry.ancestors(entry) { ancestor in
                let properties = Registry.properties(ancestor)
                if IOObjectConformsTo(ancestor, "IONetworkController") != 0,
                    excludesController(
                        model: properties["IOModel"] as? String,
                        provider: properties["IOProviderClass"] as? String)
                {
                    return false
                }
                if IOObjectConformsTo(ancestor, "IOPCIDevice") != 0
                    || IOObjectConformsTo(ancestor, "IOUSBHostDevice") != 0
                    || IOObjectConformsTo(ancestor, "AppleARMIODevice") != 0
                {
                    physical = true
                }
                if model == nil { model = properties["IOModel"] as? String }
                if parentID == nil, IOObjectConformsTo(ancestor, "IOUSBHostDevice") != 0 {
                    parentID = "usb:\(Registry.id(ancestor))"
                }
                return true
            }
            guard physical else { continue }
            let registryID = Registry.id(entry)
            let builtIn = Registry.properties(entry)["IOBuiltin"] as? Bool == true
            let id = "network:\(registryID):\(bsd)"
            let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? "以太网"
            let state =
                SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(bsd)/Link" as CFString)
                as? [String: Any]
            let active = state?[kSCPropNetLinkActive as String] as? Bool
            let status = active.map { $0 ? "链路已连接" : "未连接网线" } ?? "链路状态未提供"
            var currentMedia: Unmanaged<CFDictionary>?
            var activeMedia: Unmanaged<CFDictionary>?
            let mediaAvailable = SCNetworkInterfaceCopyMediaOptions(
                interface, &currentMedia, &activeMedia, nil, false)
            let current = currentMedia?.takeRetainedValue() as NSDictionary?
            let media = activeMedia?.takeRetainedValue() as NSDictionary?
            var connection = status
            if mediaAvailable, let subtype = media?[kSCPropNetEthernetMediaSubType] as? String,
                subtype != "none"
            {
                connection = subtype
            }
            var fields = [
                DeviceField("网络信息", "接口名称", bsd),
                DeviceField("网络信息", "链路状态", status),
                DeviceField("网络信息", "控制器", model ?? name),
                DeviceField("网络信息", "统计口径", "网卡累计字节的采样差值；并非互联网测速"),
            ]
            if let subtype = current?[kSCPropNetEthernetMediaSubType] as? String {
                fields.append(DeviceField("网络信息", "配置模式", subtype))
            }
            if let options = media?[kSCPropNetEthernetMediaOptions] as? [String], !options.isEmpty {
                fields.append(DeviceField("网络信息", "链路选项", options.joined(separator: "、")))
            }
            if let mac = SCNetworkInterfaceGetHardwareAddressString(interface) as String? {
                fields.append(DeviceField("网络信息", "MAC 地址", mac))
            }
            let index = if_nametoindex(bsd)
            if let counter = counters[index] { result.counters[id] = counter.bytes }
            result.devices.append(
                PortDevice(
                    id: id, kind: .network, name: "\(name) · \(bsd)", subtitle: status,
                    connection: connection, isPort: true, parentID: parentID, fields: fields,
                    route: builtIn && parentID == nil
                        ? PortRoute(connector: .ethernet, number: 1, topologyPath: Registry.path(entry))
                        : nil,
                    linkActive: active
                ))
        }
        return result
    }

    static func excludesController(model: String?, provider: String?) -> Bool {
        // USB device-mode interfaces belong to the Mac itself, not to an attached Ethernet adapter.
        model == "ThunderboltIP" || provider == "IOUSBDeviceInterface"
    }

    static func kind(for interfaceType: String?) -> DeviceKind? {
        if interfaceType == kSCNetworkInterfaceTypeEthernet as String { return .network }
        if interfaceType == kSCNetworkInterfaceTypeIEEE80211 as String { return .wifi }
        return nil
    }

    private static func readCounters() throws -> [UInt32: NetworkCounter] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // Interfaces may change between the size query and the actual read.
        for _ in 0..<3 {
            var length = 0
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { buffer in
                sysctl(&mib, u_int(mib.count), buffer.baseAddress, &length, nil, 0)
            }
            if status == 0 {
                data.count = length
                return parseCounters(data, time: ProcessInfo.processInfo.systemUptime)
            }
            if errno != ENOMEM { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw POSIXError(.ENOMEM)
    }

    static func parseCounters(_ data: Data, time: TimeInterval) -> [UInt32: NetworkCounter] {
        data.withUnsafeBytes { buffer in
            var result: [UInt32: NetworkCounter] = [:]
            var offset = 0
            while offset + 4 <= buffer.count {
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, length <= buffer.count - offset else { break }
                if buffer[offset + 3] == UInt8(RTM_IFINFO2), length >= MemoryLayout<if_msghdr2>.size {
                    let message = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    result[UInt32(message.ifm_index)] = NetworkCounter(
                        bytes: ByteCounters(
                            read: message.ifm_data.ifi_ibytes, written: message.ifm_data.ifi_obytes,
                            time: time)
                    )
                }
                offset += length
            }
            return result
        }
    }
}
