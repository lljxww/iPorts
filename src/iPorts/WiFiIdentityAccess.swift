import AppKit
import CoreLocation
import Foundation

@MainActor
final class WiFiIdentityAccess: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    var onResult: ((String, Bool) -> Void)?

    func request() {
        guard Bundle.main.object(forInfoDictionaryKey: "NSLocationUsageDescription") != nil,
            Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") != nil
        else {
            onResult?("请使用打包后的 iPorts.app 请求网络名称权限；命令行诊断仍可读取 Wi-Fi 连接状态。", true)
            return
        }
        if manager == nil {
            let manager = CLLocationManager()
            self.manager = manager
            manager.delegate = self
        }
        guard let manager else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            NSApplication.shared.activate()
            manager.requestWhenInUseAuthorization()
        default:
            reportAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.reportAuthorization() }
    }

    private func reportAuthorization() {
        guard let manager else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            onResult?("已获得定位授权，正在重新读取 Wi-Fi 网络名称。", false)
        case .denied, .restricted:
            onResult?("网络名称权限未获允许。可在「系统设置 → 隐私与安全性 → 定位服务」中允许 iPorts；连接状态和流量仍可查看。", true)
        case .notDetermined: break
        @unknown default:
            onResult?("系统未提供可识别的定位授权状态；Wi-Fi 连接信息仍可查看。", true)
        }
    }
}
