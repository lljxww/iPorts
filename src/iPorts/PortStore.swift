import AppKit
import Combine
import Foundation
import PortsCore

@MainActor
final class PortStore: ObservableObject {
    @Published private(set) var snapshot = ScanSnapshot(devices: [])
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasScanned = false
    @Published private(set) var isVisible = false
    @Published private(set) var ejectingID: String?
    @Published var selectedID: String?
    @Published var filter: DeviceKind?
    @Published var search = ""
    @Published var showInternal = false
    @Published var pendingEjection: String?
    @Published var message: String?
    @Published var messageIsError = false
    @Published var showModelMap = true
    @Published var selectedPortID: String?
    @Published var showsSystemPower = false
    @Published var modelDiagramID = "rear"
    @Published private(set) var associations: [String: PortAssociation] = [:]
    @Published private(set) var connections: [PortConnection] = []
    @Published private(set) var officialModels = AppleMacCatalog.bundled
    @Published private(set) var isCatalogRefreshing = false
    @Published var catalogMessage: String?
    @Published var editingLayout = false
    @Published private(set) var layoutDraft: CustomPortLayout?
    @Published private(set) var customLayout: CustomPortLayout?
    @Published private(set) var modelVariantID: String?
    @Published private(set) var artworkRevision = 0
    @Published private(set) var modelProfile: MacModelProfile?

    private let scanner: any PortScanning
    private let liveSampler: any LiveSampling
    private let liveInterval: Duration
    private let discoveryInterval: Duration
    private let catalogService = AppleCatalogService()
    private let wifiIdentityAccess = WiFiIdentityAccess()
    private let preferences: UserDefaults
    private var polling: Task<Void, Never>?
    private var livePolling: Task<Void, Never>?
    private var refreshTask: Task<ScanSnapshot, Never>?
    private var refreshID: UUID?
    private var monitoringSession = UUID()
    private var latestLive: LiveMetricsSnapshot?
    @Published private(set) var liveNotices: [String] = []
    private var catalogTask: Task<Void, Never>?
    private var mappingOverrides: [String: String] = [:]
    private var loadedModelIdentifier: String?

    init(
        snapshot: ScanSnapshot? = nil, preferences: UserDefaults = .standard,
        scanner: any PortScanning = PortScanner(), liveSampler: any LiveSampling = LiveMetricsReader(),
        liveInterval: Duration = .seconds(1), discoveryInterval: Duration = .seconds(5)
    ) {
        self.preferences = preferences
        self.scanner = scanner
        self.liveSampler = liveSampler
        self.liveInterval = liveInterval
        self.discoveryInterval = discoveryInterval
        if let snapshot {
            self.snapshot = snapshot
            hasScanned = true
            rebuildMapping()
        }
    }

    var modelVariants: [OfficialMacModel] {
        AppleMacCatalog.models(for: snapshot.machine?.identifier ?? "", in: officialModels)
    }
    var selectedModelPort: ModelPort? { modelProfile?.ports.first { $0.id == selectedPortID } }

    func devices(at portID: String) -> [PortDevice] {
        snapshot.devices.filter { !$0.isInternal && matchesPort(portID, device: $0) }
    }

    private func matchesPort(_ portID: String, device: PortDevice) -> Bool {
        guard !device.kind.isWireless else { return false }
        if let logical = modelProfile?.ports.first(where: { $0.id == portID }), let key = logical.routeKey {
            return key == calibrationKey(for: device)
        }
        return associations[device.id]?.portID == portID
    }

    var highlightedPortID: String? {
        let portID = selectedPortID ?? selected.flatMap { associations[$0.id]?.portID }
        return modelProfile?.ports.first { $0.id == portID }?.id
    }

    func isSelectedPort(_ port: ModelPort) -> Bool { highlightedPortID == port.id }

    func ports(in diagram: ModelDiagram) -> [ModelPort] {
        guard diagram.id == "topology" else { return diagram.ports }
        let selectedLogical = diagram.ports.first { $0.id == selectedPortID && $0.isLogical }
        let ports = connections.filter { !$0.devices.isEmpty && !$0.isInternal }.compactMap {
            connection -> ModelPort? in
            if let selectedLogical,
                connection.devices.contains(where: { matchesPort(selectedLogical.id, device: $0) })
            {
                return selectedLogical
            }
            return modelProfile?.ports.first { $0.id == connection.portID }
        }
        return ports.isEmpty ? diagram.ports : ports
    }

    func hasConnectedDevice(at portID: String) -> Bool {
        devices(at: portID).contains { device in
            device.kind.isNetwork ? device.linkActive == true : !device.isPort
        }
    }

    func selectPort(_ port: ModelPort) {
        showsSystemPower = false
        if selectedPortID == port.id {
            selectedPortID = nil
            return
        }
        selectedPortID = port.id
        if let diagram = modelProfile?.diagrams.first(where: { $0.ports.contains { $0.id == port.id } }) {
            modelDiagramID = diagram.id
        }
        search = ""
        filter = nil
        selectedID = connections.first(where: { $0.portID == port.id && !$0.devices.isEmpty })?.primary?.id
        pendingEjection = nil
    }

    func selectDevice(_ device: PortDevice) {
        showsSystemPower = false
        if let selectedPortID, !matchesPort(selectedPortID, device: device) {
            self.selectedPortID = nil
        }
        selectedID = device.id
        if let portID = highlightedPortID,
            let diagram = modelProfile?.diagrams.first(where: { $0.ports.contains { $0.id == portID } })
        {
            modelDiagramID = diagram.id
        }
    }

    func selectSystemPower() {
        showsSystemPower = true
        selectedPortID = nil
        pendingEjection = nil
    }

    func calibrationKey(for device: PortDevice) -> String {
        PortMapper.calibrationKey(for: device, devices: snapshot.devices)
    }

    func calibrationPorts(for device: PortDevice) -> [ModelPort] {
        guard let modelProfile else { return [] }
        return PortMapper.compatiblePorts(for: device, profile: modelProfile, devices: snapshot.devices)
    }

    func calibrate(_ device: PortDevice, portID: String?) {
        let key = calibrationKey(for: device)
        if let portID, calibrationPorts(for: device).contains(where: { $0.id == portID }) {
            mappingOverrides[key] = portID
        } else {
            mappingOverrides.removeValue(forKey: key)
        }
        if let identifier = snapshot.machine?.identifier {
            preferences.set(
                mappingOverrides.filter { !$0.key.hasPrefix("session:") },
                forKey: "port-mapping.\(identifier)")
        }
        selectedPortID = nil
        rebuildMapping()
        selectDevice(device)
    }

    private func rebuildMapping() {
        guard let machine = snapshot.machine else {
            associations = [:]
            modelProfile = nil
            connections = PortConnectionBuilder.build(
                devices: snapshot.devices, machine: nil, profile: nil, associations: [:])
            return
        }
        if loadedModelIdentifier != machine.identifier {
            mappingOverrides =
                preferences.dictionary(forKey: "port-mapping.\(machine.identifier)")
                as? [String: String] ?? [:]
            for (key, value) in mappingOverrides where key.hasPrefix("thunderbolt:usb-c:") {
                mappingOverrides[
                    key.replacingOccurrences(of: "thunderbolt:usb-c:", with: "thunderbolt:thunderbolt:")] =
                    value
            }
            modelVariantID = preferences.string(forKey: "model-variant.\(machine.identifier)")
            customLayout = nil
            if let data = preferences.data(forKey: "port-layout.v1.\(machine.identifier)") {
                do {
                    let layout = try JSONDecoder().decode(CustomPortLayout.self, from: data)
                    if layout.isValid { customLayout = layout } else { catalogMessage = "已保存的机身布局无效，使用默认布局。" }
                } catch { catalogMessage = "读取机身布局失败：\(error.localizedDescription)" }
            }
            loadedModelIdentifier = machine.identifier
        }
        modelProfile = MacModelCatalog.resolvedProfile(
            machine: machine, devices: snapshot.devices, records: officialModels, variantID: modelVariantID,
            customLayout: customLayout)
        associations = PortMapper.associations(
            devices: snapshot.devices, machine: machine, overrides: mappingOverrides, profile: modelProfile)
        connections = PortConnectionBuilder.build(
            devices: snapshot.devices, machine: machine, profile: modelProfile, associations: associations)
        if modelProfile?.diagrams.contains(where: { $0.id == modelDiagramID }) != true {
            modelDiagramID = modelProfile?.diagrams.first?.id ?? "topology"
        }
    }

    func chooseModelVariant(_ id: String) {
        guard modelVariants.contains(where: { $0.id == id }), let identifier = snapshot.machine?.identifier
        else { return }
        modelVariantID = id
        preferences.set(id, forKey: "model-variant.\(identifier)")
        selectedPortID = nil
        rebuildMapping()
        ensureArtwork()
    }

    func addLayoutPort(side: PortSide, connector: PortConnector) {
        guard let profile = modelProfile else { return }
        var layout = layoutDraft ?? customLayout ?? CustomPortLayout.from(profile)
        guard layout.ports.count < 64 else {
            catalogMessage = "每台 Mac 最多支持 64 个自定义接口。"
            return
        }
        layout.ports.append(CustomLayoutPort(side: side, connector: connector))
        if editingLayout {
            layoutDraft = layout
            return
        }
        saveLayout(layout)
        modelDiagramID = side.rawValue
    }

    func removeLayoutPort(_ id: String) {
        guard var layout = layoutDraft ?? customLayout else { return }
        layout.ports.removeAll { "slot:\($0.id)" == id }
        if editingLayout {
            layoutDraft = layout
            return
        }
        saveLayout(layout)
    }

    func moveLayoutPort(_ id: String, offset: Int) {
        guard var layout = layoutDraft ?? customLayout,
            let index = layout.ports.firstIndex(where: { "slot:\($0.id)" == id })
        else { return }
        let sameSide = layout.ports.indices.filter { layout.ports[$0].side == layout.ports[index].side }
        guard let localIndex = sameSide.firstIndex(of: index), sameSide.indices.contains(localIndex + offset)
        else { return }
        layout.ports.swapAt(index, sameSide[localIndex + offset])
        if editingLayout {
            layoutDraft = layout
            return
        }
        saveLayout(layout)
    }

    func beginLayoutEditing() {
        guard let profile = modelProfile else { return }
        layoutDraft = customLayout ?? CustomPortLayout.from(profile)
        editingLayout = true
    }

    func applyLayoutEdits() {
        if let layoutDraft { saveLayout(layoutDraft) }
        cancelLayoutEdits()
    }

    func cancelLayoutEdits() {
        editingLayout = false
        layoutDraft = nil
    }

    func restoreDefaultLayout() {
        guard let identifier = snapshot.machine?.identifier else { return }
        customLayout = nil
        preferences.removeObject(forKey: "port-layout.v1.\(identifier)")
        selectedPortID = nil
        cancelLayoutEdits()
        rebuildMapping()
    }

    private func saveLayout(_ layout: CustomPortLayout) {
        guard layout.isValid, let identifier = snapshot.machine?.identifier else { return }
        do {
            let data = try JSONEncoder().encode(layout)
            preferences.set(data, forKey: "port-layout.v1.\(identifier)")
            customLayout = layout
            selectedPortID = nil
            rebuildMapping()
        } catch { catalogMessage = "保存机身布局失败：\(error.localizedDescription)" }
    }

    func updateModelCatalog() {
        guard !isCatalogRefreshing else { return }
        isCatalogRefreshing = true
        catalogTask?.cancel()
        catalogTask = Task { [weak self] in
            guard let self else { return }
            catalogMessage = "正在从 Apple 更新机型资料…"
            defer { isCatalogRefreshing = false }
            do {
                let updated = try await catalogService.refresh()
                guard !Task.isCancelled else { return }
                officialModels = AppleMacCatalog.merging(updated)
                rebuildMapping()
                if let model = modelProfile?.officialModel,
                    MacModelCatalog.artworkURL(for: modelProfileForArtwork(model)) == nil
                {
                    try await catalogService.cacheArtwork(model)
                    artworkRevision += 1
                }
                catalogMessage = modelVariants.isEmpty ? "Apple 当前目录中尚无此型号，继续使用通用布局。" : "已更新 Apple 机型资料。"
            } catch {
                guard !Task.isCancelled else { return }
                catalogMessage = "机型资料更新失败，继续使用离线图和端口布局：\(error.localizedDescription)"
            }
        }
    }

    private func modelProfileForArtwork(_ model: OfficialMacModel) -> MacModelProfile {
        UniversalPortLayout.profile(
            machine: MachineInfo(identifier: snapshot.machine?.identifier ?? "unknown"), devices: [],
            official: model)
    }

    private func ensureArtwork() {
        guard let profile = modelProfile, let model = profile.officialModel,
            MacModelCatalog.artworkURL(for: modelProfileForArtwork(model)) == nil
        else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await catalogService.cacheArtwork(model)
                artworkRevision += 1
            } catch { catalogMessage = "图片下载失败，继续显示端口示意：\(error.localizedDescription)" }
        }
    }

    var visibleDevices: [PortDevice] {
        let matchingIDs = Set(
            connections.filter { connection in
                search.isEmpty
                    || ([connection.connectionDescription]
                        + connection.devices.flatMap {
                            [$0.name, $0.subtitle, $0.connection] + $0.fields.map(\.value)
                        }).joined(separator: " ").localizedCaseInsensitiveContains(search)
            }.flatMap { $0.devices.map(\.id) })
        return snapshot.devices.filter { device in
            !(device.kind == .thunderbolt && device.isPort)
                && (showInternal || !device.isInternal) && (filter == nil || device.kind == filter)
                && (selectedPortID == nil || selectedPortID.map { matchesPort($0, device: device) } == true)
                && matchingIDs.contains(device.id)
        }
    }

    var visibleConnections: [PortConnection] {
        let visibleIDs = Set(visibleDevices.map(\.id))
        return connections.filter { $0.devices.contains { visibleIDs.contains($0.id) } }
    }

    var selected: PortDevice? {
        guard !showsSystemPower else { return nil }
        let visible = visibleDevices
        if let device = visible.first(where: { $0.id == selectedID }) { return device }
        guard let connection = visibleConnections.first else { return nil }
        if let primary = connection.primary, visible.contains(where: { $0.id == primary.id }) {
            return primary
        }
        return connection.devices.first { item in visible.contains { $0.id == item.id } }
    }

    var selectedConnection: PortConnection? {
        if let selected {
            return connections.first { $0.devices.contains { $0.id == selected.id } }
        }
        return connections.first { $0.portID == selectedPortID && selectedPortID != nil }
    }

    func selectConnection(_ connection: PortConnection) {
        let visibleIDs = Set(visibleDevices.map(\.id))
        let device =
            connection.primary.flatMap { visibleIDs.contains($0.id) ? $0 : nil }
            ?? connection.devices.first { visibleIDs.contains($0.id) }
        if let device { selectDevice(device) }
    }

    func selectFunction(_ device: PortDevice, in connection: PortConnection) {
        guard connection.devices.contains(where: { $0.id == device.id }) else { return }
        filter = nil
        search = ""
        selectDevice(device)
    }

    var externalDevices: [PortDevice] { snapshot.devices.filter { !$0.isInternal } }
    var deviceCount: Int { connections.filter { !$0.isInternal && $0.isConnected }.count }
    var wiredConnectionCount: Int {
        connections.filter { !$0.isInternal && $0.isConnected && $0.primary?.kind.isWireless != true }.count
    }
    var connectionCountDescription: String {
        let bluetooth = count(.bluetooth)
        let wifi = connections.filter { $0.primary?.kind == .wifi && $0.isConnected }.count
        if bluetooth == 0 && wifi == 0 { return "\(wiredConnectionCount) 个端口连接" }
        var parts = ["\(wiredConnectionCount) 个有线连接"]
        if wifi > 0 { parts.append("\(wifi) 个 Wi-Fi 连接") }
        if bluetooth > 0 { parts.append("\(bluetooth) 个蓝牙设备") }
        return parts.joined(separator: " · ")
    }

    func count(_ kind: DeviceKind) -> Int {
        connections.filter { !$0.isInternal && $0.devices.contains { $0.kind == kind } }.count
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        monitoringSession = UUID()
        let session = monitoringSession
        polling?.cancel()
        polling = nil
        livePolling?.cancel()
        livePolling = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        isRefreshing = false
        latestLive = nil
        liveNotices = []
        pendingEjection = nil
        if visible {
            snapshot = snapshot.resettingLiveMetrics()
            rebuildMapping()
            livePolling = Task { [weak self] in
                guard let self, isVisible, monitoringSession == session, !Task.isCancelled else { return }
                await liveSampler.resetSampling()
                while isVisible, monitoringSession == session, !Task.isCancelled {
                    let live = await liveSampler.sample()
                    guard isVisible, monitoringSession == session, !Task.isCancelled else { return }
                    latestLive = live
                    liveNotices = live.notices
                    snapshot = snapshot.updatingLiveMetrics(live)
                    rebuildMapping()
                    do { try await Task.sleep(for: liveInterval) } catch { return }
                }
            }
            polling = Task { [weak self] in
                guard let self, isVisible, monitoringSession == session, !Task.isCancelled else { return }
                await scanner.resetSampling()
                while isVisible, monitoringSession == session, !Task.isCancelled {
                    await refresh()
                    do { try await Task.sleep(for: discoveryInterval) } catch { return }
                }
            }
        }
    }

    func refresh(forceDetails: Bool = false) async {
        guard isVisible, !isRefreshing, !Task.isCancelled else { return }
        let session = monitoringSession
        let requestID = UUID()
        refreshID = requestID
        isRefreshing = true
        let scanner = scanner
        let task = Task { await scanner.scan(forceDetails: forceDetails) }
        refreshTask = task
        defer {
            if refreshID == requestID {
                isRefreshing = false
                refreshTask = nil
                refreshID = nil
            }
        }
        let updated = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard isVisible, monitoringSession == session, !Task.isCancelled, !task.isCancelled else { return }
        if let latestLive, latestLive.capturedAt >= updated.capturedAt {
            snapshot = updated.updatingLiveMetrics(latestLive)
        } else {
            snapshot = updated
        }
        rebuildMapping()
        hasScanned = true
        if isVisible, catalogTask == nil {
            catalogTask = Task { [weak self] in
                guard let self else { return }
                do {
                    if let cached = try await catalogService.cachedModels() {
                        guard !Task.isCancelled else { return }
                        officialModels = AppleMacCatalog.merging(cached)
                        rebuildMapping()
                    }
                } catch { catalogMessage = "机型缓存不可用，使用内置目录：\(error.localizedDescription)" }
                guard !Task.isCancelled else { return }
                ensureArtwork()
                if modelVariants.isEmpty { updateModelCatalog() }
            }
        }
    }

    func copySelected() {
        guard let connection = selectedConnection else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(connection.report, forType: .string)
        messageIsError = false
        message = "已复制此端口及设备功能信息（包含序列号、MAC 地址等设备标识）。"
    }

    func copySystemPower() {
        guard let power = snapshot.systemPower else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(power.report, forType: .string)
        messageIsError = false
        message = "已复制整机功率与统计口径。"
    }

    func requestWiFiIdentityAccess() {
        wifiIdentityAccess.onResult = { [weak self] text, error in
            guard let self else { return }
            message = text
            messageIsError = error
            if !error { Task { await self.refresh() } }
        }
        wifiIdentityAccess.request()
    }

    func eject(_ device: PortDevice) {
        guard ejectingID == nil, let identity = device.disk else { return }
        pendingEjection = nil
        ejectingID = device.id
        message = nil
        Task {
            do {
                try await DiskEjector.eject(identity)
                messageIsError = false
                message = "\(device.name) 已安全推出，可拔下设备。"
            } catch {
                messageIsError = true
                message = error.localizedDescription
            }
            ejectingID = nil
            await refresh()
        }
    }
}
