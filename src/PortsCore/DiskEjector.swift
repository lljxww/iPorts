import DiskArbitration
import Foundation
import IOKit
import OSLog

public enum EjectError: LocalizedError, Sendable {
    case rejected(String)
    case system(String, Int32, String)

    public var errorDescription: String? {
        switch self {
        case .rejected(let message): message
        case .system(let stage, let code, let reason): "\(stage)失败（\(code)）：\(reason)"
        }
    }
}

@MainActor
public enum DiskEjector {
    public static func eject(_ expected: DiskIdentity) async throws {
        guard expected.canEject else { throw EjectError.rejected("仅支持安全推出已确认的外接物理整盘。") }
        guard let session = DASessionCreate(kCFAllocatorDefault),
            let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, expected.bsdName)
        else { throw EjectError.rejected("磁盘已断开或无法创建磁盘会话。") }
        try validate(disk, expected: expected)
        DASessionSetDispatchQueue(session, .main)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = EjectOperation(
                session: session, disk: disk, expected: expected, continuation: continuation)
            let context = Unmanaged.passRetained(operation).toOpaque()
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), unmountCallback, context)
        }
    }

    fileprivate static func validate(_ disk: DADisk, expected: DiskIdentity) throws {
        guard let desc = DADiskCopyDescription(disk) as NSDictionary? else {
            throw EjectError.rejected("无法重新验证磁盘身份，已取消推出。")
        }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { throw EjectError.rejected("磁盘已离线。") }
        defer { IOObjectRelease(media) }
        let current = DiskIdentity(
            bsdName: desc[kDADiskDescriptionMediaBSDNameKey] as? String ?? "",
            registryID: Registry.id(media),
            isInternal: desc[kDADiskDescriptionDeviceInternalKey] as? Bool,
            isWhole: desc[kDADiskDescriptionMediaWholeKey] as? Bool == true,
            isPhysical: Registry.hasPhysicalStorageAncestor(media)
        )
        guard expected.matchesForEjection(current) else {
            throw EjectError.rejected("磁盘身份或连接状态已改变，已取消推出；请刷新后重试。")
        }
    }
}

@MainActor
private final class EjectOperation {
    let session: DASession
    let disk: DADisk
    let expected: DiskIdentity
    let continuation: CheckedContinuation<Void, Error>

    init(
        session: DASession, disk: DADisk, expected: DiskIdentity,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.session = session
        self.disk = disk
        self.expected = expected
        self.continuation = continuation
    }

    func finish(_ error: Error? = nil) {
        DASessionSetDispatchQueue(session, nil)
        if let error {
            Logger(subsystem: "local.iports.app", category: "ejection").error(
                "\(error.localizedDescription, privacy: .public)")
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

private let unmountCallback: DADiskUnmountCallback = { disk, dissenter, context in
    guard let context else { return }
    let operation = Unmanaged<EjectOperation>.fromOpaque(context).takeRetainedValue()
    let error = dissenter.map { dissenterError($0, stage: "卸载") }
    // Disk Arbitration schedules these callbacks on the main queue selected above.
    MainActor.assumeIsolated {
        if let error {
            operation.finish(error)
            return
        }
        do {
            try DiskEjector.validate(operation.disk, expected: operation.expected)
            let nextContext = Unmanaged.passRetained(operation).toOpaque()
            DADiskEject(
                operation.disk, DADiskEjectOptions(kDADiskEjectOptionDefault), ejectCallback, nextContext)
        } catch {
            operation.finish(error)
        }
    }
}

private let ejectCallback: DADiskEjectCallback = { _, dissenter, context in
    guard let context else { return }
    let operation = Unmanaged<EjectOperation>.fromOpaque(context).takeRetainedValue()
    let error = dissenter.map { dissenterError($0, stage: "推出（磁盘可能已卸载）") }
    MainActor.assumeIsolated {
        operation.finish(error)
    }
}

private func dissenterError(_ dissenter: DADissenter, stage: String) -> EjectError {
    let reason = DADissenterGetStatusString(dissenter) as String? ?? "设备正忙、权限不足，或驱动拒绝了操作。"
    return .system(stage, DADissenterGetStatus(dissenter), reason)
}
