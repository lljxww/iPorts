import PortsCore

protocol PortScanning: Sendable {
    func scan(forceDetails: Bool) async -> ScanSnapshot
    func resetSampling() async
}

protocol LiveSampling: Sendable {
    func sample() async -> LiveMetricsSnapshot
    func resetSampling() async
}

extension PortScanner: PortScanning {}
extension LiveMetricsReader: LiveSampling {}
