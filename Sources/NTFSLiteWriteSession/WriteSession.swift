import Foundation
import NTFSLiteCore
import NTFSLiteHelperExecution
import NTFSLiteHelperProtocol
import NTFSLiteSystem

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
    case helperVersionMismatch
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
    /// The request was rejected before any disk mutation was confirmed.
    case refused(WriteRefusal)
    /// The disk state changed or is unknown; the app must re-read system facts.
    case needsRefresh(WriteRefusal)
}

/// ADR 0011: one operation per physical disk, explicit confirmation, fresh one-shot IDs and only
/// the fixed ADR 0002 actions. The helper re-verifies every system fact itself.
public actor WriteSession {
    private let transport: HelperTransport
    private var busyDisks: Set<PhysicalDiskID> = []
    // A delayed helper may still act on a reused BSD name after media replacement.
    private var unresolvedDisks: Set<PhysicalDiskID> = []
    private var writable: Set<VolumeInstanceID> = []
    private var bindingsByDisk: [DiskInstanceID: HelperDiskInstanceIdentity] = [:]

    public init(transport: HelperTransport) {
        self.transport = transport
    }

    public func writableVolumes() -> Set<VolumeInstanceID> { writable }

    public func isBusy(_ disk: DiskInstanceID) -> Bool { busyDisks.contains(disk.physicalDiskID) }

    public func enableWriting(
        _ target: VolumeInstanceID,
        in observation: DiskInventoryObservation,
        confirmedAsDataVolume: Bool
    ) async -> WriteOutcome {
        guard confirmedAsDataVolume else { return .refused(.notConfirmed) }
        guard let diskBinding = Self.diskIdentity(target.diskInstanceID, target: target, in: observation),
              let helperTarget = Self.volumeIdentity(target, disk: diskBinding)
        else { return .refused(.identityInvalid) }
        guard begin(target.diskInstanceID) else { return .refused(.diskBusy) }
        defer { end(target.diskInstanceID) }
        let outcome = await send(.mountReadWrite, .volume(helperTarget), stage: WriteRefusal.mount)
        if let outcome { retainIfUnresolved(outcome, for: target.diskInstanceID) }
        if outcome == nil {
            writable.insert(target)
            bindingsByDisk[target.diskInstanceID] = diskBinding
        }
        return outcome ?? .writingEnabled
    }

    /// Standard whole-disk unmount (including the helper's FSKit mounts), then standard eject.
    public func safeEject(_ disk: DiskInstanceID, in observation: DiskInventoryObservation) async -> WriteOutcome {
        guard begin(disk) else { return .refused(.diskBusy) }
        defer { end(disk) }
        let helperDisk: HelperDiskInstanceIdentity?
        if let retained = bindingsByDisk[disk] {
            helperDisk = Self.currentDiskMatchesRetainedBinding(disk, retained, in: observation)
                ? retained : nil
        } else {
            let trustedTargets = observation.physicalDisks
                .filter { $0.instanceID == disk }
                .flatMap(\.volumes)
                .compactMap(\.snapshot)
                .filter { $0.fileSystem == .ntfs && $0.role == .data }
            helperDisk = trustedTargets.count == 1
                ? Self.diskIdentity(disk, target: trustedTargets[0].instanceID, in: observation, requireReadOnly: false)
                : nil
        }
        guard let helperDisk else { return .refused(.identityInvalid) }
        if let failure = await send(.unmountDisk, .disk(helperDisk), stage: WriteRefusal.release) {
            if case let .refused(.release(reason)) = failure {
                // An execution failure may follow successful sibling unmounts.
                unresolvedDisks.insert(disk.physicalDiskID)
                return .needsRefresh(.release(reason))
            }
            retainIfUnresolved(failure, for: disk)
            return failure
        }
        writable = writable.filter { $0.diskInstanceID.physicalDiskID != disk.physicalDiskID }
        if let failure = await send(.ejectDisk, .disk(helperDisk), stage: WriteRefusal.release) {
            // The standard whole-disk unmount already succeeded. Even a refused
            // eject leaves changed state that needs more than a normal refresh.
            unresolvedDisks.insert(disk.physicalDiskID)
            if case let .refused(refusal) = failure { return .needsRefresh(refusal) }
            return failure
        }
        bindingsByDisk.removeValue(forKey: disk)
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
            case .rejectedDiskBusy: return .refused(.diskBusy)
            case .rejectedUnsupportedSchema: return .refused(.helperVersionMismatch)
            case .executionFailed:
                if case .unknownStage = refusal { return .needsRefresh(refusal) }
                return .refused(refusal)
            case .postconditionFailed: return .needsRefresh(refusal)
            default: return .refused(.requestRejected)
            }
        }
    }

    private func begin(_ disk: DiskInstanceID) -> Bool {
        guard !unresolvedDisks.contains(disk.physicalDiskID) else { return false }
        return busyDisks.insert(disk.physicalDiskID).inserted
    }
    private func end(_ disk: DiskInstanceID) { busyDisks.remove(disk.physicalDiskID) }

    private func retainIfUnresolved(_ outcome: WriteOutcome, for disk: DiskInstanceID) {
        if case .needsRefresh = outcome { unresolvedDisks.insert(disk.physicalDiskID) }
    }

    public static func diskIdentity(
        _ disk: DiskInstanceID,
        target: VolumeInstanceID,
        in observation: DiskInventoryObservation,
        requireReadOnly: Bool = true
    ) -> HelperDiskInstanceIdentity? {
        guard target.diskInstanceID == disk, observation.issues.isEmpty else { return nil }
        let matches = observation.physicalDisks.filter { $0.instanceID == disk }
        guard matches.count == 1, let observedDisk = matches.first,
              observedDisk.issues.isEmpty,
              observedDisk.description.bsdName == disk.physicalDiskID.rawValue,
              observedDisk.description.physicalDiskBSDName == disk.physicalDiskID.rawValue,
              observedDisk.description.isWholeDisk == true,
              observedDisk.description.isInternal == false,
              observedDisk.description.isRemovable == true,
              observedDisk.description.isEjectable == true,
              observedDisk.description.mediaContent == "GUID_partition_scheme",
              let registryEntryID = observedDisk.description.mediaRegistryID,
              registryEntryID > 0,
              (1...2).contains(observedDisk.volumes.count)
        else { return nil }

        let targetRecords = observedDisk.volumes.filter {
            ($0.snapshot?.instanceID ?? $0.candidate?.instanceID) == target
        }
        guard targetRecords.count == 1, let targetRecord = targetRecords.first,
              targetRecord.issues == [.unknownVolumeRole] || targetRecord.issues.isEmpty,
              targetRecord.candidate != nil || targetRecord.snapshot?.role == .data,
              targetRecord.isBoundMicrosoftBasicDataNTFS(on: observedDisk),
              !requireReadOnly || (targetRecord.candidate?.mountAccess ?? targetRecord.snapshot?.mountAccess) == .readOnly
        else { return nil }

        var partitions: [HelperPartitionIdentity] = []
        for record in observedDisk.volumes {
            let isTarget = (record.snapshot?.instanceID ?? record.candidate?.instanceID) == target
            guard isTarget || record.isRecognizedUnMountedEFIPartition(on: observedDisk),
                  record.evidence.physicalDiskBSDName == disk.physicalDiskID.rawValue,
                  let bsdName = record.evidence.bsdName,
                  let partRegistry = record.evidence.mediaRegistryID,
                  let mediaUUID = record.evidence.mediaUUID,
                  let contentHint = record.evidence.mediaContentHint,
                  let partition = try? HelperPartitionIdentity(
                    bsdName: bsdName,
                    registryEntryID: partRegistry,
                    mediaUUID: mediaUUID,
                    contentHint: contentHint,
                    kind: isTarget ? .ntfsTarget : .efiSystem
                  )
            else { return nil }
            partitions.append(partition)
        }
        return try? HelperDiskInstanceIdentity(
            physicalDiskBSDName: disk.physicalDiskID.rawValue,
            mediaGeneration: disk.mediaGeneration.rawValue,
            registryEntryID: registryEntryID,
            mediaContent: "GUID_partition_scheme",
            partitions: partitions.sorted { $0.bsdName < $1.bsdName }
        )
    }

    private static func currentDiskMatchesRetainedBinding(
        _ disk: DiskInstanceID,
        _ binding: HelperDiskInstanceIdentity,
        in observation: DiskInventoryObservation
    ) -> Bool {
        binding.physicalDiskBSDName == disk.physicalDiskID.rawValue
            && canOfferSessionEject(disk, binding: binding, in: observation)
    }

    /// The original candidate row may disappear under an FSKit placeholder.
    /// Session-only eject remains visible when the same whole-disk IOMedia
    /// object is still observed; the helper checks the retained exact layout.
    public static func canOfferSessionEject(
        _ disk: DiskInstanceID,
        binding: HelperDiskInstanceIdentity,
        in observation: DiskInventoryObservation
    ) -> Bool {
        guard binding.physicalDiskBSDName == disk.physicalDiskID.rawValue,
              binding.mediaGeneration == disk.mediaGeneration.rawValue,
              observation.issues.isEmpty else { return false }
        let matches = observation.physicalDisks.filter { $0.instanceID == disk }
        guard matches.count == 1, let current = matches.first else { return false }
        guard current.issues.isEmpty
            && current.description.bsdName == disk.physicalDiskID.rawValue
            && current.description.physicalDiskBSDName == disk.physicalDiskID.rawValue
            && current.description.isWholeDisk == true
            && current.description.isInternal == false
            && current.description.isRemovable == true
            && current.description.isEjectable == true
            && current.description.mediaRegistryID == binding.registryEntryID
            && current.description.mediaContent == "GUID_partition_scheme"
            && current.volumes.count <= binding.partitions.count
        else { return false }

        var observedPartitions: Set<String> = []
        for record in current.volumes {
            guard let bsdName = record.evidence.bsdName,
                  observedPartitions.insert(bsdName).inserted,
                  let expected = binding.partitions.first(where: { $0.bsdName == bsdName }),
                  record.evidence.physicalDiskBSDName == disk.physicalDiskID.rawValue,
                  record.evidence.isInternal == false,
                  record.evidence.mediaRegistryID == expected.registryEntryID,
                  record.evidence.mediaUUID?.lowercased() == expected.mediaUUID,
                  record.evidence.mediaContentHint?.lowercased() == expected.contentHint
            else { return false }
            switch expected.kind {
            case .efiSystem:
                guard record.isRecognizedUnMountedEFIPartition(on: current) else { return false }
            case .ntfsTarget:
                guard record.isBoundMicrosoftBasicDataNTFS(on: current),
                      record.evidence.roleEvidence != .protected,
                      record.evidence.roleEvidence != .conflicting,
                      record.snapshot?.role.isProtected != true
                else { return false }
            }
        }
        return true
    }

    static func volumeIdentity(_ volume: VolumeInstanceID, disk: HelperDiskInstanceIdentity) -> HelperVolumeInstanceIdentity? {
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
        case .writingEnabled: return "已启用写入。请在访达“位置”中查找新挂载的卷，显示名称可能变化。用完请安全推出整块磁盘，再断开连接。"
        case .ejected: return "已安全推出，可以拔出磁盘。"
        case .refused(.diskBusy): return "本次请求未执行：这块磁盘正在进行另一项操作。请等待状态更新。"
        case let .refused(refusal): return "未进行任何更改：" + reason(refusal)
        case let .needsRefresh(refusal): return reason(refusal) + " 磁盘状态尚未确认。请重新读取；在结果明确前，请勿直接拔出或再次操作。"
        }
    }

    static func reason(_ refusal: WriteRefusal) -> String {
        switch refusal {
        case .notConfirmed: return "需要先确认这是数据卷。"
        case .diskBusy: return "这块磁盘正在进行另一项操作。"
        case .identityInvalid: return "磁盘身份信息不完整。"
        case .helperUnavailable: return "帮助程序未安装或未获批准，请在“运行环境”中安装并在系统设置中允许。"
        case .helperVersionMismatch: return "帮助程序与当前应用版本不匹配。请在“运行环境”中重新启用或更新帮助程序，然后重新读取。"
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
        case .fsKitUnavailable: return "文件系统写入预检未通过。目标卷保持原状态，请在“运行环境”中检查依赖与扩展。"
        case .fsKitProbeUnresolved: return "写入预检的收尾尚未确认，已暂停后续操作。请保留当前状态，在“运行环境”中检查；不要重复启用写入。"
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
