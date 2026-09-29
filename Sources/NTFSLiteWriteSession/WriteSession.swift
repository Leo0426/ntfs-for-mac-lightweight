import Foundation
import NTFSLiteCore
import NTFSLiteHelperExecution
import NTFSLiteHelperProtocol

public enum HelperTransportResult: Sendable {
    case reply(Data)
    /// The request was not delivered (helper not registered, connection refused).
    case unavailable
    /// Delivery or completion is unknown; the request must never be retried.
    case timedOut
}

public protocol HelperTransport: Sendable {
    func send(_ request: Data) async -> HelperTransportResult
}

public enum WriteRefusal: Equatable, Sendable {
    case notConfirmed
    case diskBusy
    case identityInvalid
    case helperUnavailable
    case helperTimedOut
    case invalidResponse
    case requestRejected
    case mount(WritableMountFailure)
    case release(DiskReleaseFailure)
    case unknownStage(Int32)
}

public enum WriteOutcome: Equatable, Sendable {
    case writingEnabled
    case ejected
    /// Nothing changed on disk.
    case refused(WriteRefusal)
    /// The disk state changed or is unknown; the app must re-read system facts.
    case needsRefresh(WriteRefusal)
}

/// ADR 0011: one operation per physical disk, explicit confirmation, fresh one-shot IDs and only
/// the fixed ADR 0002 actions. The helper re-verifies every system fact itself.
public actor WriteSession {
    private let transport: HelperTransport
    private var busyDisks: Set<PhysicalDiskID> = []
    private var writable: Set<VolumeInstanceID> = []

    public init(transport: HelperTransport) {
        self.transport = transport
    }

    public func writableVolumes() -> Set<VolumeInstanceID> { writable }

    public func isBusy(_ disk: DiskInstanceID) -> Bool { busyDisks.contains(disk.physicalDiskID) }

    public func enableWriting(_ target: VolumeInstanceID, confirmedAsDataVolume: Bool) async -> WriteOutcome {
        guard confirmedAsDataVolume else { return .refused(.notConfirmed) }
        guard let helperTarget = Self.volumeIdentity(target) else { return .refused(.identityInvalid) }
        guard begin(target.diskInstanceID) else { return .refused(.diskBusy) }
        defer { end(target.diskInstanceID) }
        let outcome = await send(.mountReadWrite, .volume(helperTarget), stage: WriteRefusal.mount)
        if outcome == nil { writable.insert(target) }
        return outcome ?? .writingEnabled
    }

    /// Standard whole-disk unmount (including the helper's FSKit mounts), then standard eject.
    public func safeEject(_ disk: DiskInstanceID) async -> WriteOutcome {
        guard let helperDisk = Self.diskIdentity(disk) else { return .refused(.identityInvalid) }
        guard begin(disk) else { return .refused(.diskBusy) }
        defer { end(disk) }
        if let failure = await send(.unmountDisk, .disk(helperDisk), stage: WriteRefusal.release) { return failure }
        writable = writable.filter { $0.diskInstanceID.physicalDiskID != disk.physicalDiskID }
        if let failure = await send(.ejectDisk, .disk(helperDisk), stage: WriteRefusal.release) { return failure }
        return .ejected
    }

    /// Returns nil on success.
    private func send(_ action: HelperAction, _ target: HelperTarget,
                      stage: (Int32) -> WriteRefusal?) async -> WriteOutcome? {
        guard let request = try? HelperRequestEnvelope(operationID: HelperOperationID(), action: action, target: target),
              let data = try? JSONEncoder().encode(request)
        else { return .refused(.identityInvalid) }
        switch await transport.send(data) {
        case .unavailable:
            return .refused(.helperUnavailable)
        case .timedOut:
            return .needsRefresh(.helperTimedOut)
        case let .reply(reply):
            guard case let .success(response) = HelperResponseDecoder().decode(reply) else {
                return .needsRefresh(.invalidResponse)
            }
            let refusal = stage(response.exitStatus) ?? .unknownStage(response.exitStatus)
            switch response.resultCode {
            case .succeeded: return nil
            case .executionFailed: return .refused(refusal)
            case .postconditionFailed: return .needsRefresh(refusal)
            default: return .refused(.requestRejected)
            }
        }
    }

    private func begin(_ disk: DiskInstanceID) -> Bool { busyDisks.insert(disk.physicalDiskID).inserted }
    private func end(_ disk: DiskInstanceID) { busyDisks.remove(disk.physicalDiskID) }

    static func diskIdentity(_ disk: DiskInstanceID) -> HelperDiskInstanceIdentity? {
        try? HelperDiskInstanceIdentity(physicalDiskBSDName: disk.physicalDiskID.rawValue,
                                        mediaGeneration: disk.mediaGeneration.rawValue)
    }

    static func volumeIdentity(_ volume: VolumeInstanceID) -> HelperVolumeInstanceIdentity? {
        guard let disk = diskIdentity(volume.diskInstanceID) else { return nil }
        return try? HelperVolumeInstanceIdentity(volumeUUID: volume.volumeID.uuid,
                                                 volumeBSDName: volume.volumeID.bsdName, disk: disk)
    }
}

private extension WriteRefusal {
    static func mount(_ status: Int32) -> WriteRefusal? { WritableMountFailure(rawValue: status).map(WriteRefusal.mount) }
    static func release(_ status: Int32) -> WriteRefusal? { DiskReleaseFailure(rawValue: status).map(WriteRefusal.release) }
}

/// Fixed user-facing explanations; no system text is ever shown.
public enum WriteOutcomeText {
    public static func text(_ outcome: WriteOutcome) -> String {
        switch outcome {
        case .writingEnabled: return "已启用写入。可以在 Finder 中读写此卷；用完请点“安全推出”。"
        case .ejected: return "已安全推出，可以拔出磁盘。"
        case let .refused(refusal): return "未进行任何更改：" + reason(refusal)
        case let .needsRefresh(refusal): return reason(refusal) + " 磁盘状态可能已变化，已重新读取；如仍异常请重新插拔后再试。"
        }
    }

    static func reason(_ refusal: WriteRefusal) -> String {
        switch refusal {
        case .notConfirmed: return "需要先确认这是数据卷。"
        case .diskBusy: return "这块磁盘正在进行另一项操作。"
        case .identityInvalid: return "磁盘身份信息不完整。"
        case .helperUnavailable: return "帮助程序未安装或未获批准，请在“运行环境”中安装并在系统设置中允许。"
        case .helperTimedOut: return "帮助程序没有及时响应，操作结果未知。"
        case .invalidResponse: return "帮助程序的响应无法识别。"
        case .requestRejected: return "帮助程序拒绝了该请求。"
        case .unknownStage: return "帮助程序报告了未知的失败阶段。"
        case let .mount(failure): return mountReason(failure)
        case let .release(failure): return releaseReason(failure)
        }
    }

    static func mountReason(_ failure: WritableMountFailure) -> String {
        switch failure {
        case .targetMismatch, .factsUnavailable, .volumeUUIDMismatch: return "磁盘已变化或无法确认是同一个卷，请重新读取后再试。"
        case .notExternalRemovable: return "只支持外置、可移除的 USB 或雷雳磁盘。"
        case .notNTFS: return "这个卷不是 NTFS。"
        case .notNativeReadOnly: return "卷需要先以系统只读方式挂载（重新插拔通常即可）。"
        case .identityUnavailable: return "无法读取卷标识。"
        case .bootSectorInvalid, .bootSectorChanged: return "无法确认 NTFS 启动扇区，已停止。"
        case .nativeUnmountFailed: return "无法卸载系统只读挂载，可能有程序正在使用该卷。"
        case .healthNotClean: return "卷未正常关闭或处于休眠状态。请在 Windows 中完全关机（关闭快速启动）或运行磁盘检查后再试。"
        case .driverStartFailed: return "无法启动 NTFS 驱动，请检查 macFUSE 是否已安装并启用。"
        case .mountNotObserved, .mountNotVerified: return "可写挂载未能通过核验，未报告为可写。"
        }
    }

    static func releaseReason(_ failure: DiskReleaseFailure) -> String {
        switch failure {
        case .targetMismatch, .factsUnavailable: return "磁盘已变化或状态无法确认。"
        case .notExternalRemovable: return "只支持外置、可移除的磁盘。"
        case .ambiguousMount: return "发现无法识别的挂载，已停止以免误操作。"
        case .unmountRefused: return "卷正在被使用，请关闭正在使用它的程序后再试。"
        case .driverNotExited: return "NTFS 驱动尚未退出。"
        case .mountPointNotRemoved: return "挂载点未能清理。"
        case .stillMounted: return "磁盘仍有已挂载的卷。"
        case .ejectRefused: return "系统拒绝推出，可能有程序正在使用该磁盘。"
        case .ejectNotConfirmed: return "推出后磁盘仍然存在。"
        }
    }
}
