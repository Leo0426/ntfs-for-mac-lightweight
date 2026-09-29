import Foundation
import NTFSLiteCore
import NTFSLiteSystem

public enum ReadOnlyDashboardPhase: Equatable, Sendable {
    case scanning
    case limited
    case settled
}

/// UI eligibility for a new request. The helper independently rechecks all
/// system facts before it performs any disk mutation.
public struct FormalVolumeActionPolicy: Equatable, Sendable {
    public let canEnableWriting: Bool
    public let canSafeEject: Bool
    public let requiresDataDeclaration: Bool
    public let writeReason: String
    public let ejectReason: String

    public init(
        canEnableWriting: Bool,
        canSafeEject: Bool,
        requiresDataDeclaration: Bool,
        writeReason: String,
        ejectReason: String
    ) {
        self.canEnableWriting = canEnableWriting
        self.canSafeEject = canSafeEject
        self.requiresDataDeclaration = requiresDataDeclaration
        self.writeReason = writeReason
        self.ejectReason = ejectReason
    }

    public static let unavailable = FormalVolumeActionPolicy(
        canEnableWriting: false,
        canSafeEject: false,
        requiresDataDeclaration: false,
        writeReason: "正在核对磁盘信息，请重新读取后再试。",
        ejectReason: "正在核对磁盘信息，请重新读取后再试。"
    )
}

public struct ReadOnlyVolumePresentation: Equatable, Identifiable, Sendable {
    public let id: VolumeInstanceID
    public let title: String
    public let accessText: String
    public let detail: String
    public let actions: FormalVolumeActionPolicy

    public init(
        id: VolumeInstanceID,
        title: String,
        accessText: String,
        detail: String,
        actions: FormalVolumeActionPolicy = .unavailable
    ) {
        self.id = id
        self.title = title
        self.accessText = accessText
        self.detail = detail
        self.actions = actions
    }
}

public struct ReadOnlyPhysicalDiskPresentation: Equatable, Identifiable, Sendable {
    public let id: DiskInstanceID
    public let title: String
    public let detail: String
    public let volumes: [ReadOnlyVolumePresentation]

    public init(
        id: DiskInstanceID,
        title: String,
        detail: String,
        volumes: [ReadOnlyVolumePresentation]
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.volumes = volumes
    }
}

public struct ReadOnlyDashboardPresentation: Equatable, Sendable {
    public let phase: ReadOnlyDashboardPhase
    public let title: String
    public let detail: String
    public let physicalDisks: [ReadOnlyPhysicalDiskPresentation]
    public let setup: SetupPresentation

    public var volumes: [ReadOnlyVolumePresentation] {
        physicalDisks.flatMap(\.volumes)
    }

    public init(
        phase: ReadOnlyDashboardPhase,
        title: String,
        detail: String,
        physicalDisks: [ReadOnlyPhysicalDiskPresentation],
        setup: SetupPresentation
    ) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.physicalDisks = physicalDisks
        self.setup = setup
    }

    public var writeControlsAvailable: Bool {
        volumes.contains { $0.actions.canEnableWriting || $0.actions.canSafeEject }
    }
}

public enum ReadOnlyDashboardPresenter {
    /// UI-only eligibility for a disk previously mounted by this app session.
    /// The caller must also hold a successful helper result for this exact volume instance.
    /// It does not promote an unknown-role candidate into general eject authority.
    public static func canOfferSessionEject(
        _ volumeID: VolumeInstanceID,
        in observation: DiskInventoryObservation
    ) -> Bool {
        let disks = observation.physicalDisks.filter { $0.instanceID == volumeID.diskInstanceID }
        guard disks.count == 1, let disk = disks.first else { return false }
        let targets = disk.volumes.filter {
            ($0.snapshot?.instanceID ?? $0.candidate?.instanceID) == volumeID
        }
        guard targets.count == 1, let record = targets.first else { return false }
        if let snapshot = record.snapshot, snapshot.fileSystem == .ntfs {
            return sharedBlockReason(
                targetID: volumeID,
                targetLocation: snapshot.location,
                targetIsProtected: snapshot.role.isProtected,
                targetRecord: record,
                requiredIssues: [],
                on: disk,
                observation: observation
            ) == nil
        }
        if let candidate = record.candidate {
            return sharedBlockReason(
                targetID: volumeID,
                targetLocation: candidate.location,
                targetIsProtected: false,
                targetRecord: record,
                requiredIssues: [.unknownVolumeRole],
                on: disk,
                observation: observation
            ) == nil
        }
        return false
    }

    public static func presentation(
        for observation: DiskInventoryObservation,
        setupAssessment: SetupAssessment,
        isSetupRefreshing: Bool,
        setupReport: SystemSetupReport? = nil
    ) -> ReadOnlyDashboardPresentation {
        let setup = if let setupReport {
            SetupPresenter.presentation(
                for: setupReport,
                isRefreshing: isSetupRefreshing
            )
        } else {
            SetupPresenter.presentation(
                for: setupAssessment,
                isRefreshing: isSetupRefreshing
            )
        }

        if observation.issues.contains(.initialEnumerationPending) {
            return ReadOnlyDashboardPresentation(
                phase: .scanning,
                title: "正在读取磁盘信息",
                detail: "正在等待系统完成本轮只读枚举；结果确认前不提供磁盘操作。",
                physicalDisks: [],
                setup: setup
            )
        }

        // The read-only Setup probe cannot reliably prove runtime FSKit
        // availability. The helper checks it before native unmount.
        let projection = displayableNTFSPhysicalDisks(in: observation)
        let physicalDisks = projection.physicalDisks
        let volumeCount = physicalDisks.reduce(0) { $0 + $1.volumes.count }

        // The system observation remains incomplete for a bare EFI partition.
        // Only this read-only UI projection may recognize its bounded IOMedia
        // facts; `coordinatorInventory` and helper gates remain unchanged.
        guard isPresentableObservationComplete(observation) else {
            if let reason = unconfirmedNTFSIdentityReason(in: observation) {
                let availableText = volumeCount > 0 ? "可查看 \(volumeCount) 个 NTFS 卷。" : ""
                return ReadOnlyDashboardPresentation(
                    phase: .limited,
                    title: volumeCount > 0 ? "部分 NTFS 卷身份尚未确认" : "检测到 NTFS，但卷身份尚未确认",
                    detail: "\(availableText)\(reason)身份未确认的卷暂时无法选择；请在已确认卷的详情中查看可用操作。",
                    physicalDisks: physicalDisks,
                    setup: setup
                )
            }
            if volumeCount > 0 {
                let containsUnknownPurpose = projection.unknownPurposeCount > 0
                return ReadOnlyDashboardPresentation(
                    phase: .limited,
                    title: containsUnknownPurpose
                        ? "检测到 \(volumeCount) 个 NTFS 卷"
                        : "已确认 \(volumeCount) 个 NTFS 卷",
                    detail: containsUnknownPurpose
                        ? "用途未确认的卷可查看当前状态；符合条件时，可在本次请求中声明其为数据卷。帮助程序会在操作前重新核对磁盘事实。"
                        : "这些卷的访问状态已核对，但其他系统事实仍不完整。请在卷详情中查看当前操作资格。",
                    physicalDisks: physicalDisks,
                    setup: setup
                )
            }
            // No NTFS volumes to show. Fail closed when the observation itself
            // is untrustworthy (a top-level issue: enumeration coverage
            // unverified, mount table unreadable, an unidentified disk event, an
            // unknown disk kind, …), or when any incompletely-read physical disk
            // is not a confirmed built-in disk — an external disk we could not
            // fully read might still be carrying the user's NTFS volume.
            //
            // A confirmed built-in disk whose EFI / APFS-container partitions
            // legitimately carry no volume UUID / name / filesystem is expected
            // on every Mac and must not read as "facts failed to read".
            let unresolvedRemovableDisk = observation.physicalDisks.contains { disk in
                !disk.isComplete && disk.description.isInternal != true
            }
            if observation.issues.isEmpty, !unresolvedRemovableDisk {
                return ReadOnlyDashboardPresentation(
                    phase: .settled,
                    title: "未检测到 NTFS 磁盘",
                    detail: "当前系统枚举已经完成。连接外置 NTFS 磁盘后会自动重新读取。",
                    physicalDisks: [],
                    setup: setup
                )
            }
            return ReadOnlyDashboardPresentation(
                phase: .limited,
                title: "磁盘信息尚未确认",
                detail: "部分系统事实读取失败或互相不一致。当前结果不会被当作没有磁盘，所有变更操作保持关闭。",
                physicalDisks: [],
                setup: setup
            )
        }

        if volumeCount == 0 {
            return ReadOnlyDashboardPresentation(
                phase: .settled,
                title: "未检测到 NTFS 磁盘",
                detail: "当前系统枚举已经完成。连接外置 NTFS 磁盘后会自动重新读取。",
                physicalDisks: [],
                setup: setup
            )
        }

        return ReadOnlyDashboardPresentation(
            phase: .settled,
            title: "检测到 \(volumeCount) 个 NTFS 卷",
            detail: "启用写入与安全推出由你手动发起，帮助程序每次都会重新核对磁盘事实。写入路径已有有限实物验证；Windows 复核与长期兼容性验证仍未完成。",
            physicalDisks: physicalDisks,
            setup: setup
        )
    }

    private static func isPresentableObservationComplete(
        _ observation: DiskInventoryObservation
    ) -> Bool {
        observation.issues.isEmpty && observation.physicalDisks.allSatisfy { disk in
            disk.issues.isEmpty && disk.volumes.allSatisfy { record in
                record.isComplete || record.isRecognizedUnMountedEFIPartition(on: disk)
            }
        }
    }

    private static func unconfirmedNTFSIdentityReason(in observation: DiskInventoryObservation) -> String? {
        guard observation.issues.isEmpty else { return nil }
        var missing = false
        var invalid = false
        for disk in observation.physicalDisks {
            guard disk.issues.isEmpty, disk.description.isInternal == false else { continue }
            for record in disk.volumes {
                let fileSystem = record.evidence.fileSystemName?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard record.evidence.isInternal == false, fileSystem == "ntfs",
                      record.candidate == nil, record.snapshot == nil else { continue }
                missing = missing || record.issues.contains(.missingVolumeUUID)
                invalid = invalid || record.issues.contains(.invalidVolumeUUID)
            }
        }
        switch (missing, invalid) {
        case (true, true):
            return "部分 NTFS 卷标识缺失，另有标识无效或互相矛盾。"
        case (true, false):
            return "系统未提供可核对的 NTFS 卷标识。"
        case (false, true):
            return "NTFS 卷标识无效或互相矛盾。"
        case (false, false):
            return nil
        }
    }

    private struct DisplayableVolume {
        let id: VolumeInstanceID
        let title: String
        let location: VolumeLocation
        let role: VolumeRole?
        let mountAccess: MountAccess
        let hasUnknownPurpose: Bool
        let actions: FormalVolumeActionPolicy
    }

    private struct DashboardDiskProjection {
        let physicalDisks: [ReadOnlyPhysicalDiskPresentation]
        let unknownPurposeCount: Int
    }

    private static func displayableNTFSPhysicalDisks(
        in observation: DiskInventoryObservation
    ) -> DashboardDiskProjection {
        let grouped: [(id: DiskInstanceID, volumes: [DisplayableVolume], efiCount: Int, otherPartitionCount: Int)] = observation
            .physicalDisks.compactMap { disk in
            let volumes = disk.volumes.compactMap { record -> DisplayableVolume? in
                if let snapshot = record.snapshot, snapshot.fileSystem == .ntfs {
                    return DisplayableVolume(
                        id: snapshot.instanceID,
                        title: snapshot.displayName,
                        location: snapshot.location,
                        role: snapshot.role,
                        mountAccess: snapshot.mountAccess,
                        hasUnknownPurpose: false,
                        actions: actionPolicy(
                            for: snapshot, record: record, on: disk, observation: observation
                        )
                    )
                }
                guard let candidate = record.candidate else {
                    return nil
                }
                return DisplayableVolume(
                    id: candidate.instanceID,
                    title: candidate.displayName,
                    location: candidate.location,
                    role: nil,
                    mountAccess: candidate.mountAccess,
                    hasUnknownPurpose: true,
                    actions: actionPolicy(
                        for: candidate, record: record, on: disk, observation: observation
                    )
                )
            }
            guard !volumes.isEmpty else {
                return nil
            }
            let efiCount = disk.volumes.count { $0.isRecognizedUnMountedEFIPartition(on: disk) }
            return (
                id: disk.instanceID,
                volumes: volumes,
                efiCount: efiCount,
                otherPartitionCount: disk.volumes.count - volumes.count - efiCount
            )
        }
        .sorted { lhs, rhs in
            diskIdentitySortKey(lhs.id) < diskIdentitySortKey(rhs.id)
        }

        let physicalDisks = grouped.enumerated().map { index, group in
            let volumes = group.volumes
                .map(volumePresentation)
                .sorted {
                    let titleOrder = $0.title.localizedStandardCompare($1.title)
                    if titleOrder == .orderedSame {
                        return volumeIdentitySortKey($0.id)
                            < volumeIdentitySortKey($1.id)
                    }
                    return titleOrder == .orderedAscending
                }
                .addingSiblingOrdinalsWhenNeeded()
            let location = group.volumes.allSatisfy { $0.location == .external }
                ? "外置物理磁盘"
                : "受保护的内置物理磁盘"
            let unknownPurposeCount = group.volumes.count(where: \.hasUnknownPurpose)
            let detail = if unknownPurposeCount == 0 {
                "\(location)，包含 \(volumes.count) 个已确认的 NTFS 卷。"
            } else {
                "\(location)，包含 \(volumes.count) 个 NTFS 卷，其中 \(unknownPurposeCount) 个用途未确认。"
            }
            let efiDetail = group.efiCount > 0
                ? "另有 \(group.efiCount) 个 EFI 分区，当前未挂载。"
                : ""
            let otherDetail = group.otherPartitionCount > 0
                ? "另有 \(group.otherPartitionCount) 个当前不支持操作的同盘分区。"
                : ""
            return ReadOnlyPhysicalDiskPresentation(
                id: group.id,
                title: "物理磁盘 \(index + 1)",
                detail: detail + efiDetail + otherDetail,
                volumes: volumes
            )
        }
        return DashboardDiskProjection(
            physicalDisks: physicalDisks,
            unknownPurposeCount: grouped.reduce(0) { count, group in
                count + group.volumes.count(where: \.hasUnknownPurpose)
            }
        )
    }

    private static func volumePresentation(
        _ volume: DisplayableVolume
    ) -> ReadOnlyVolumePresentation {
        let locationText: String
        switch volume.location {
        case .external:
            locationText = "外置磁盘"
        case .internal:
            locationText = volume.role == .bootCamp ? "内置 Boot Camp 卷" : "内置磁盘"
        }

        let accessText: String
        let accessDetail: String
        switch volume.mountAccess {
        case .unmounted:
            accessText = "未挂载"
            accessDetail = "这次观察未看到原生分区的挂载；若曾启用写入，请在访达核对新挂载。"
        case .readOnly:
            accessText = "只读"
            accessDetail = "系统当前以只读方式挂载。"
        case .readWrite:
            accessText = "已有可写挂载"
            accessDetail = "检测到现有可写挂载，但本应用未验证其来源或安全性。"
        }

        let purposeDetail = volume.hasUnknownPurpose ? "用途未确认。" : ""
        return ReadOnlyVolumePresentation(
            id: volume.id,
            title: volume.title,
            accessText: accessText,
            detail: "\(locationText)。\(purposeDetail)\(accessDetail)",
            actions: volume.actions
        )
    }

    private static func actionPolicy(
        for candidate: ReadOnlyVolumeCandidate,
        record: ReadOnlyVolumeRecord,
        on disk: ReadOnlyPhysicalDiskRecord,
        observation: DiskInventoryObservation
    ) -> FormalVolumeActionPolicy {
        if let reason = sharedBlockReason(
            targetID: candidate.instanceID,
            targetLocation: candidate.location,
            targetIsProtected: false,
            targetRecord: record,
            requiredIssues: [.unknownVolumeRole],
            on: disk,
            observation: observation
        ) {
            return blocked(reason)
        }
        return FormalVolumeActionPolicy(
            canEnableWriting: candidate.mountAccess == .readOnly,
            canSafeEject: false,
            requiresDataDeclaration: candidate.mountAccess == .readOnly,
            writeReason: writeReason(for: candidate.mountAccess, requiresDeclaration: true),
            ejectReason: "卷用途未确认，不能推出整块物理磁盘。"
        )
    }

    private static func actionPolicy(
        for snapshot: VolumeSnapshot,
        record: ReadOnlyVolumeRecord,
        on disk: ReadOnlyPhysicalDiskRecord,
        observation: DiskInventoryObservation
    ) -> FormalVolumeActionPolicy {
        if let reason = sharedBlockReason(
            targetID: snapshot.instanceID,
            targetLocation: snapshot.location,
            targetIsProtected: snapshot.role.isProtected,
            targetRecord: record,
            requiredIssues: [],
            on: disk,
            observation: observation
        ) {
            return blocked(reason)
        }
        return FormalVolumeActionPolicy(
            canEnableWriting: snapshot.mountAccess == .readOnly,
            canSafeEject: true,
            requiresDataDeclaration: false,
            writeReason: writeReason(for: snapshot.mountAccess, requiresDeclaration: false),
            ejectReason: "安全推出会卸载并推出整块物理磁盘上的所有分区。"
        )
    }

    private static func writeReason(
        for access: MountAccess,
        requiresDeclaration: Bool
    ) -> String {
        switch access {
        case .readOnly:
            return requiresDeclaration
                ? "先确认所选卷是数据卷且不是 Windows 系统卷；声明只适用于本次写入请求。"
                : "启用前将重新核对磁盘身份、健康与挂载状态。"
        case .readWrite:
            return "已有可写挂载，但本应用未验证其来源，不能重复启用写入。"
        case .unmounted:
            return "卷当前未挂载，请等待系统以只读方式挂载后重新读取。"
        }
    }

    private static func sharedBlockReason(
        targetID: VolumeInstanceID,
        targetLocation: VolumeLocation,
        targetIsProtected: Bool,
        targetRecord: ReadOnlyVolumeRecord,
        requiredIssues: [ReadOnlyObservationIssue],
        on disk: ReadOnlyPhysicalDiskRecord,
        observation: DiskInventoryObservation
    ) -> String? {
        if let issue = observation.issues.first {
            return issueReason(issue)
        }
        if let issue = disk.issues.first {
            return issueReason(issue)
        }
        let diskName = disk.instanceID.physicalDiskID.rawValue
        if targetID.diskInstanceID != disk.instanceID
            || disk.description.isWholeDisk != true
            || disk.description.bsdName != diskName
            || disk.description.physicalDiskBSDName != diskName
        {
            return "磁盘身份或介质代次已变化，请重新读取后再试。"
        }
        if targetRecord.issues != requiredIssues {
            return "目标卷系统事实不完整，请重新读取后再试。"
        }
        if targetLocation == .internal || disk.description.isInternal == true {
            return "内置磁盘不支持启用写入或安全推出。"
        }
        if targetRecord.evidence.isInternal != false || disk.description.isInternal == nil {
            return "无法确认磁盘是外置设备，请重新读取后再试。"
        }
        if targetIsProtected {
            return "受保护卷不支持启用写入或安全推出。"
        }
        guard targetRecord.isBoundMicrosoftBasicDataNTFS(on: disk) else {
            return "无法确认 NTFS 分区与 GPT 物理磁盘的当前身份，请重新读取后再试。"
        }
        let matchingTargets = disk.volumes.count { record in
            (record.snapshot?.instanceID ?? record.candidate?.instanceID) == targetID
        }
        guard matchingTargets == 1 else {
            return "目标卷记录数量与当前磁盘不一致，请重新读取后再试。"
        }
        let siblings = disk.volumes.filter { record in
            let instanceID = record.snapshot?.instanceID ?? record.candidate?.instanceID
            return instanceID != targetID
        }
        if siblings.contains(where: { sibling in
            sibling.evidence.isInternal == true
                || sibling.evidence.roleEvidence == .protected
                || sibling.snapshot?.location == .internal
                || sibling.snapshot?.role.isProtected == true
        }) {
            return "同盘存在受保护卷，不能对整块物理磁盘操作。"
        }
        if siblings.contains(where: { sibling in
            sibling.evidence.roleEvidence == .conflicting
                || (sibling.candidate != nil
                    || (sibling.evidence.roleEvidence == .unknown
                        && sibling.evidence.fileSystemName?.lowercased() == "ntfs"))
        }) {
            return "同盘 NTFS 卷用途尚未确认，不能对整块物理磁盘操作。"
        }
        if siblings.count(where: { $0.isRecognizedUnMountedEFIPartition(on: disk) }) > 1 {
            return "同盘存在多个 EFI 分区，当前帮助程序不支持这个分区布局。"
        }
        if siblings.contains(where: { sibling in
            !sibling.isRecognizedUnMountedEFIPartition(on: disk)
        }) {
            return "当前只支持目标 NTFS 卷与可选的已识别 EFI 分区；其他同盘分区不能进入操作。"
        }
        if siblings.contains(where: { sibling in
            let instanceID = sibling.snapshot?.instanceID ?? sibling.candidate?.instanceID
            return instanceID != nil && instanceID?.diskInstanceID != disk.instanceID
        }) {
            return "同盘卷身份与当前介质代次不一致，请重新读取后再试。"
        }
        guard let safety = disk.safetySnapshot else {
            return "无法确认物理磁盘的推出能力和可移除性，请重新读取后再试。"
        }
        guard safety.ejectability == .ejectable,
              safety.removability == .removable
        else {
            return "当前物理磁盘不支持软件推出。"
        }
        return nil
    }

    private static func issueReason(_ issue: DiskInventoryIssue) -> String {
        switch issue {
        case .initialEnumerationPending, .enumerationCoverageUnverified:
            return "系统磁盘枚举尚未核对完成，请等待或重新读取。"
        case .eventSourceUnavailable:
            return "系统磁盘事件读取不可用，请重新打开应用并再次检查。"
        case .unidentifiedDiskEvent:
            return "系统报告了身份不明的磁盘变化，请重新读取后再试。"
        case .mountTableReadFailed, .duplicateMountTableEntry:
            return "系统挂载表未能完整核对，请重新读取后再试。"
        case .missingPhysicalDiskDescription, .unknownDiskKind,
             .physicalParentMismatch, .childLocationMismatch:
            return "物理磁盘身份或子卷归属尚未确认，请重新读取后再试。"
        case .missingPhysicalLocation:
            return "物理磁盘的内外置位置尚未确认，请重新读取后再试。"
        case .missingEjectability:
            return "物理磁盘推出能力尚未确认，请重新读取后再试。"
        case .missingRemovability:
            return "物理磁盘可移除性尚未确认，请重新读取后再试。"
        case .contradictoryEjectability:
            return "物理磁盘推出能力与可移除性互相矛盾，请重新读取后再试。"
        }
    }

    private static func blocked(_ reason: String) -> FormalVolumeActionPolicy {
        FormalVolumeActionPolicy(
            canEnableWriting: false,
            canSafeEject: false,
            requiresDataDeclaration: false,
            writeReason: reason,
            ejectReason: reason
        )
    }

    private static func volumeIdentitySortKey(_ id: VolumeInstanceID) -> String {
        "\(id.diskInstanceID.mediaGeneration.rawValue):\(id.volumeID.uuid):\(id.volumeID.bsdName)"
    }

    private static func diskIdentitySortKey(_ id: DiskInstanceID) -> String {
        "\(id.physicalDiskID.rawValue):\(id.mediaGeneration.rawValue)"
    }
}

private extension Array where Element == ReadOnlyVolumePresentation {
    func addingSiblingOrdinalsWhenNeeded() -> [ReadOnlyVolumePresentation] {
        guard count > 1 else {
            return self
        }
        return enumerated().map { index, volume in
            return ReadOnlyVolumePresentation(
                id: volume.id,
                title: "卷 \(index + 1) · \(volume.title)",
                accessText: volume.accessText,
                detail: volume.detail,
                actions: volume.actions
            )
        }
    }
}
