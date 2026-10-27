import DiskArbitration
import Foundation
import IOKit

enum Registry {
    static func entries(matching className: String) throws -> [io_object_t] {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator)
        guard result == KERN_SUCCESS else { throw RegistryError.query(className, result) }
        defer { IOObjectRelease(iterator) }
        var entries: [io_object_t] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 { entries.append(entry) }
        return entries
    }

    static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var value: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &value, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let value
        else { return [:] }
        return value.takeRetainedValue() as NSDictionary as? [String: Any] ?? [:]
    }

    static func id(_ entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    static func name(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "未知设备" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func path(_ entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &buffer) == KERN_SUCCESS else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // Every parent acquired here is released, including when the visitor stops early.
    static func ancestors(_ entry: io_registry_entry_t, visit: (io_registry_entry_t) -> Bool) {
        var current: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &current) == KERN_SUCCESS else { return }
        for _ in 0..<64 {
            let keepGoing = visit(current)
            var parent: io_registry_entry_t = 0
            let result =
                keepGoing ? IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) : KERN_FAILURE
            IOObjectRelease(current)
            guard result == KERN_SUCCESS, parent != 0 else { return }
            current = parent
        }
        IOObjectRelease(current)
    }

    static func hasPhysicalStorageAncestor(_ entry: io_registry_entry_t) -> Bool {
        var found = false
        ancestors(entry) { parent in
            if IOObjectConformsTo(parent, "IOBlockStorageDevice") != 0 {
                found = true
                return false
            }
            return true
        }
        return found
    }
}

enum RegistryError: LocalizedError {
    case query(String, kern_return_t)
    case diskSession

    var errorDescription: String? {
        switch self {
        case .query(let name, let code): "读取 \(name) 失败（IOKit \(code)）。"
        case .diskSession: "无法创建 Disk Arbitration 会话。"
        }
    }
}

struct RegistrySnapshot: Sendable {
    var devices: [PortDevice] = []
    var counters: [String: ByteCounters] = [:]
    var notices: [String] = []
}

enum RegistryReader {
    static func read() -> RegistrySnapshot {
        var snapshot = RegistrySnapshot()
        do { snapshot.devices += try usbDevices() } catch {
            snapshot.notices.append(error.localizedDescription)
        }
        do {
            let disks = try storageDevices()
            snapshot.devices += disks.devices
            snapshot.counters = disks.counters
        } catch { snapshot.notices.append(error.localizedDescription) }
        do {
            let network = try NetworkReader.read()
            snapshot.devices += network.devices
            snapshot.counters.merge(network.counters) { _, new in new }
            snapshot.notices += network.notices
        } catch { snapshot.notices.append("网卡读取失败：\(error.localizedDescription)") }
        return snapshot
    }

    private static func usbDevices() throws -> [PortDevice] {
        let entries = try Registry.entries(matching: "IOUSBHostDevice")
        defer { for entry in entries { IOObjectRelease(entry) } }
        return entries.compactMap { entry in
            let p = Registry.properties(entry)
            let registryID = Registry.id(entry)
            guard registryID != 0 else { return nil }
            let name =
                p["USB Product Name"] as? String ?? p["kUSBProductString"] as? String ?? Registry.name(entry)
            let vendor = p["USB Vendor Name"] as? String ?? p["kUSBVendorString"] as? String ?? "未知厂商"
            let explicitlyBuiltIn = (p["Built-In"] as? Bool) == true
            var rootPortRemovable: Bool?
            var parentID: String?
            var route = "直接连接"
            var controller = "系统未提供"
            var portCurrent: Int?
            var rootRoute: PortRoute?
            var fallbackRoute: PortRoute?
            Registry.ancestors(entry) { ancestor in
                let ap = Registry.properties(ancestor)
                if let path = ap["UsbIOPort"] as? String, let route = MachineReader.route(at: path) {
                    rootRoute = route
                }
                if parentID == nil, IOObjectConformsTo(ancestor, "IOUSBHostDevice") != 0 {
                    parentID = "usb:\(Registry.id(ancestor))"
                    route = ap["USB Product Name"] as? String ?? Registry.name(ancestor)
                }
                if IOObjectConformsTo(ancestor, "IOUSBHostPort") != 0
                    || IOObjectConformsTo(ancestor, "AppleUSBHostPort") != 0
                {
                    // A permanently wired port on an external dock is still external.
                    // Only the last port before the Mac's controller defines built-in status.
                    rootPortRemovable = USBVisibility.removability(ap["removable"])
                    if let path = Registry.path(ancestor) {
                        fallbackRoute = PortRoute(
                            connector: .usb, number: (ap["port"] as? NSNumber)?.intValue ?? 0,
                            topologyPath: path)
                    }
                    if portCurrent == nil {
                        portCurrent = (ap["kUSBWakePortCurrentLimit"] as? NSNumber)?.intValue
                    }
                }
                if IOObjectConformsTo(ancestor, "IOUSBHostController") != 0
                    || ap["UsbHostControllerProtocolRevision"] != nil
                {
                    controller = Registry.name(ancestor)
                    return false
                }
                return true
            }
            let speed = PortFormatting.linkSpeed(
                bits: (p["UsbLinkSpeed"] as? NSNumber)?.uint64Value,
                code: (p["USBSpeed"] as? NSNumber)?.intValue
            )
            let deviceClass = (p["bDeviceClass"] as? NSNumber)?.intValue ?? 0
            var interfaceClasses = Set<Int>()
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS {
                while case let child = IOIteratorNext(iterator), child != 0 {
                    let cp = Registry.properties(child)
                    if let code = (cp["bInterfaceClass"] as? NSNumber)?.intValue {
                        interfaceClasses.insert(code)
                    }
                    IOObjectRelease(child)
                }
                IOObjectRelease(iterator)
            }
            let classes = interfaceClasses.isEmpty ? [deviceClass] : interfaceClasses.sorted()
            let type = classes.map { PortFormatting.usbClass($0) }.joined(separator: "、")
            var fields = [
                DeviceField("连接信息", "链路速率", speed),
                DeviceField("连接信息", "连接路径", route),
                DeviceField("连接信息", "总线控制器", controller),
                DeviceField("连接信息", "传输状态", "已连接；通用 USB 流量未公开"),
                DeviceField("设备信息", "厂商", vendor),
                DeviceField("设备信息", "设备类型", type),
            ]
            if let location = (p["locationID"] as? NSNumber)?.uint32Value {
                fields.append(DeviceField("连接信息", "位置 ID", String(format: "0x%08X", location)))
            }
            for (key, label) in [("idVendor", "厂商 ID"), ("idProduct", "产品 ID")] {
                if let value = p[key] as? NSNumber {
                    fields.append(DeviceField("设备信息", label, String(format: "0x%04X", value.intValue)))
                }
            }
            if let version = (p["bcdUSB"] as? NSNumber)?.intValue {
                fields.append(
                    DeviceField("设备信息", "USB 协议", String(format: "%X.%02X", version >> 8, version & 0xff)))
            }
            if let serial = p["USB Serial Number"] as? String, !serial.isEmpty {
                fields.append(DeviceField("设备信息", "序列号", serial))
            }
            let power = (p["UsbPowerSinkAllocation"] as? NSNumber).flatMap {
                PowerBudget(milliamps: $0.doubleValue)
            }
            if let power {
                fields.append(DeviceField("供电信息", "分配电流", String(format: "%.0f mA", power.milliamps)))
                fields.append(DeviceField("供电信息", "分配功率 · 5 V", power.formatted))
            }
            if let portCurrent { fields.append(DeviceField("供电信息", "端口电流上限", "\(portCurrent) mA")) }
            fields.append(DeviceField("供电信息", "实时功耗", "系统未提供实测值"))
            return PortDevice(
                id: "usb:\(registryID)", kind: .usb, name: name, subtitle: type,
                connection: speed, isInternal: explicitlyBuiltIn || rootPortRemovable == false,
                parentID: parentID, fields: fields,
                power: power, route: rootRoute ?? fallbackRoute
            )
        }
    }

    private static func storageDevices() throws -> RegistrySnapshot {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw RegistryError.diskSession }
        let entries = try Registry.entries(matching: "IOMedia")
        defer { for entry in entries { IOObjectRelease(entry) } }
        var result = RegistrySnapshot()
        let now = ProcessInfo.processInfo.systemUptime
        for entry in entries {
            let p = Registry.properties(entry)
            guard p["Whole"] as? Bool == true,
                let disk = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, entry),
                let desc = DADiskCopyDescription(disk) as NSDictionary?,
                let bsdName = desc[kDADiskDescriptionMediaBSDNameKey] as? String,
                Registry.hasPhysicalStorageAncestor(entry)
            else { continue }
            let internalDevice = desc[kDADiskDescriptionDeviceInternalKey] as? Bool
            guard internalDevice == false else { continue }
            let registryID = Registry.id(entry)
            let id = "disk:\(registryID)"
            let protocolName = desc[kDADiskDescriptionDeviceProtocolKey] as? String ?? "系统未提供"
            let name =
                (desc[kDADiskDescriptionDeviceModelKey] as? String)?.trimmingCharacters(in: .whitespaces)
                ?? desc[kDADiskDescriptionMediaNameKey] as? String ?? bsdName
            let identity = DiskIdentity(
                bsdName: bsdName, registryID: registryID, isInternal: internalDevice,
                isWhole: true, isPhysical: true
            )
            var parentID: String?
            var counters: ByteCounters?
            Registry.ancestors(entry) { ancestor in
                if IOObjectConformsTo(ancestor, "IOUSBHostDevice") != 0, parentID == nil {
                    parentID = "usb:\(Registry.id(ancestor))"
                }
                if counters == nil, let stats = Registry.properties(ancestor)["Statistics"] as? [String: Any],
                    let read = stats["Bytes (Read)"] as? NSNumber,
                    let written = stats["Bytes (Write)"] as? NSNumber
                {
                    counters = ByteCounters(read: read.uint64Value, written: written.uint64Value, time: now)
                }
                return true
            }
            var fields = [
                DeviceField("存储信息", "设备节点", "/dev/\(bsdName)"),
                DeviceField("存储信息", "连接协议", protocolName),
                DeviceField("存储信息", "介质类型", "外接物理磁盘"),
                DeviceField("存储信息", "可写", (p["Writable"] as? Bool) == true ? "是" : "否 / 未报告"),
                DeviceField("连接信息", "推出方式", "卸载全部卷后安全推出整盘"),
            ]
            if let size = desc[kDADiskDescriptionMediaSizeKey] as? NSNumber {
                fields.append(
                    DeviceField(
                        "存储信息", "容量",
                        ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .decimal)))
            }
            if let blockSize = desc[kDADiskDescriptionMediaBlockSizeKey] as? NSNumber {
                fields.append(DeviceField("存储信息", "逻辑块大小", "\(blockSize) B"))
            }
            result.devices.append(
                PortDevice(
                    id: id, kind: .storage, name: name.isEmpty ? bsdName : name, subtitle: bsdName,
                    connection: protocolName, parentID: parentID, fields: fields, disk: identity
                ))
            if let counters { result.counters[id] = counters }
        }
        return result
    }
}
