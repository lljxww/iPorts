import AppKit
import Combine
import OSLog
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyInstalls: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func start() {
        // Plain `swift run`, tests and offscreen previews aren't installed application bundles.
        guard Bundle.main.bundleURL.pathExtension == "app",
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String
        else { return }
        do {
            try controller.updater.start()
            controller.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
        } catch {
            Logger(subsystem: "local.iports.app", category: "updates")
                .error("无法启动应用更新：\(error.localizedDescription, privacy: .public)")
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}

struct AppUpdateMenu: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Menu {
            Text(
                "iPorts \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")"
            )
            Button("检查更新…", action: updater.checkForUpdates)
                .disabled(!updater.canCheckForUpdates)
            Divider()
            Toggle("自动检查更新", isOn: $updater.automaticallyChecks)
            Toggle("自动下载并安装", isOn: $updater.automaticallyInstalls)
                .disabled(!updater.automaticallyChecks)
        } label: {
            Image(systemName: "arrow.down.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("应用版本与更新")
        .accessibilityLabel("应用更新")
        .accessibilityIdentifier("appUpdateMenu")
    }
}
