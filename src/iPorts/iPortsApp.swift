import AppKit
import Foundation
import PortsCore
import SwiftUI

@main
enum IPortsApp {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--diagnose-live") {
            let reader = LiveMetricsReader()
            var samples: [LiveMetricsSnapshot] = []
            for index in 0..<3 {
                if index > 0 {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
                samples.append(await reader.sample())
            }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                FileHandle.standardOutput.write(try encoder.encode(samples))
                FileHandle.standardOutput.write(Data("\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("实时诊断输出失败：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--refresh-model-catalog") {
            do {
                let service = AppleCatalogService()
                let models = try await service.refresh()
                print("已从 Apple 更新 \(models.count) 个外观版本、\(Set(models.flatMap(\.identifiers)).count) 个型号标识。")
                if let identifier = argument("--download-model="),
                    let model = AppleMacCatalog.models(for: identifier, in: models).first
                {
                    try await service.cacheArtwork(model)
                    print("已缓存 \(model.name) 的官方图片。")
                }
            } catch {
                FileHandle.standardError.write(Data("机型目录更新失败：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            let scanner = PortScanner()
            _ = await scanner.scan(forceDetails: true)
            try? await Task.sleep(for: .seconds(1))
            let snapshot = await scanner.scan()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(snapshot)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                if !snapshot.notices.isEmpty { exit(2) }
            } catch {
                FileHandle.standardError.write(Data("诊断输出失败：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                FileHandle.standardError.write(Data("需要指定 PNG 输出路径。\n".utf8))
                exit(1)
            }
            NSApplication.shared.setActivationPolicy(.accessory)
            let snapshot: ScanSnapshot
            if let path = argument("--preview-snapshot=") {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    snapshot = try decoder.decode(ScanSnapshot.self, from: data)
                } catch {
                    FileHandle.standardError.write(Data("读取预览快照失败：\(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            } else if let model = argument("--preview-model=") {
                snapshot = ScanSnapshot(
                    devices: [],
                    machine: MachineInfo(identifier: model))
            } else {
                let scanner = PortScanner()
                _ = await scanner.scan(forceDetails: true)
                try? await Task.sleep(for: .seconds(1))
                snapshot = await scanner.scan()
            }
            let previewDomain = "local.iports.preview.\(UUID().uuidString)"
            guard let preferences = UserDefaults(suiteName: previewDomain) else { exit(1) }
            defer { preferences.removePersistentDomain(forName: previewDomain) }
            let store = PortStore(snapshot: snapshot, preferences: preferences)
            if let variant = argument("--preview-variant=") { store.chooseModelVariant(variant) }
            if let diagram = argument("--preview-diagram="),
                store.modelProfile?.diagrams.contains(where: { $0.id == diagram }) == true
            {
                store.modelDiagramID = diagram
            }
            if CommandLine.arguments.contains("--preview-edit-layout") { store.beginLayoutEditing() }
            if let selection = CommandLine.arguments.first(where: { $0.hasPrefix("--select-kind=") }),
                let kind = DeviceKind(rawValue: String(selection.dropFirst("--select-kind=".count)))
            {
                if let device = snapshot.devices.first(where: { $0.kind == kind }) {
                    store.selectDevice(device)
                }
            }
            if let selection = CommandLine.arguments.first(where: { $0.hasPrefix("--select-port=") }),
                let port = store.modelProfile?.ports.first(where: {
                    $0.id == String(selection.dropFirst("--select-port=".count))
                })
            {
                store.selectPort(port)
            }
            if CommandLine.arguments.contains("--hide-map") { store.showModelMap = false }
            if CommandLine.arguments.contains("--select-system-power") { store.selectSystemPower() }
            if let profile = store.modelProfile, let url = MacModelCatalog.artworkURL(for: profile) {
                print("机身图片：\(url.path)")
            }
            let hosting = NSHostingView(rootView: PortsPanel(store: store))
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.frame = NSRect(x: 0, y: 0, width: PanelLayout.width, height: PanelLayout.height)
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                FileHandle.standardError.write(Data("面板渲染失败。\n".utf8))
                exit(1)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            do {
                try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("写入预览失败：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            print("已生成面板渲染预览。")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func argument(_ prefix: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let store = PortStore()
    private let updater = AppUpdater()
    private var panelController: PopoverHostingController<PortsPanel>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: 30)
        statusItem = item
        if let button = item.button {
            let image =
                NSImage(
                    systemSymbolName: "cable.connector.horizontal", accessibilityDescription: "iPorts 外接端口")
                ?? NSImage(systemSymbolName: "cable.connector", accessibilityDescription: "iPorts")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "iPorts · 外接设备与端口"
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityIdentifier("iPortsStatusButton")
        }
        popover.contentSize = NSSize(width: PanelLayout.width, height: PanelLayout.height)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let controller = PopoverHostingController(rootView: PortsPanel(store: store, updater: updater))
        panelController = controller
        popover.contentViewController = controller
        popover.appearance = NSAppearance(named: .darkAqua)
        updater.start()
        if CommandLine.arguments.contains("--show-popover") { togglePopover() }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            let window = popover.contentViewController?.view.window
            window?.makeKey()
            panelController?.resetFocus()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        panelController?.resetFocus()
        store.setVisible(true)
    }
    func popoverWillClose(_ notification: Notification) { store.setVisible(false) }
    func popoverDidClose(_ notification: Notification) { store.setVisible(false) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.ejectingID == nil else { return .terminateCancel }
        store.setVisible(false)
        return .terminateNow
    }
}
