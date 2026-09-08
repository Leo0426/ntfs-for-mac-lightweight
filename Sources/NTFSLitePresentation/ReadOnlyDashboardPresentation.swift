import Foundation
import NTFSLiteCore
import NTFSLiteSystem

public enum ReadOnlyDashboardPhase: Equatable, Sendable {
    case scanning
    case limited
    case settled
}

public struct ReadOnlyVolumePresentation: Equatable, Identifiable, Sendable {
    public let id: VolumeInstanceID
    public let title: String
    public let accessText: String
    public let detail: String

    public init(
        id: VolumeInstanceID,
        title: String,
        accessText: String,
        detail: String
    ) {
        self.id = id
        self.title = title
        self.accessText = accessText
        self.detail = detail
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

    /// This slice is intentionally observation-only. A writable UI cannot be
    /// enabled by incomplete system integration or presentation state.
    public var writeControlsAvailable: Bool {
        false
    }
}

public enum ReadOnlyDashboardPresenter {
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

        let projection = displayableNTFSPhysicalDisks(in: observation)
        let physicalDisks = projection.physicalDisks
        let volumeCount = physicalDisks.reduce(0) { $0 + $1.volumes.count }

        guard observation.isComplete else {
            if let reason = unconfirmedNTFSIdentityReason(in: observation) {
                let availableText = volumeCount > 0 ? "可查看 \(volumeCount) 个 NTFS 卷。" : ""
                return ReadOnlyDashboardPresentation(
                    phase: .limited,
                    title: volumeCount > 0 ? "部分 NTFS 卷身份尚未确认" : "检测到 NTFS，但卷身份尚未确认",
                    detail: "\(availableText)\(reason)身份未确认的卷暂时无法选择，所有变更操作保持关闭。",
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
                        ? "卷身份和只读状态已经核对，但用途仍未确认。可以查看状态，所有变更操作继续关闭。"
                        : "这些卷的只读信息已经核对，但其他系统事实仍不完整。可以查看状态，所有变更操作继续关闭。",
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
            detail: "当前版本只读取并展示系统状态；写入和推出功能尚未开放。",
            physicalDisks: physicalDisks,
            setup: setup
        )
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
    }

    private struct DashboardDiskProjection {
        let physicalDisks: [ReadOnlyPhysicalDiskPresentation]
        let unknownPurposeCount: Int
    }

    private static func displayableNTFSPhysicalDisks(
        in observation: DiskInventoryObservation
    ) -> DashboardDiskProjection {
        let grouped: [(id: DiskInstanceID, volumes: [DisplayableVolume])] = observation
            .physicalDisks.compactMap { disk in
            let volumes = disk.volumes.compactMap { record -> DisplayableVolume? in
                if let snapshot = record.snapshot, snapshot.fileSystem == .ntfs {
                    return DisplayableVolume(
                        id: snapshot.instanceID,
                        title: snapshot.displayName,
                        location: snapshot.location,
                        role: snapshot.role,
                        mountAccess: snapshot.mountAccess,
                        hasUnknownPurpose: false
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
                    hasUnknownPurpose: true
                )
            }
            guard !volumes.isEmpty else {
                return nil
            }
            return (id: disk.instanceID, volumes: volumes)
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
            return ReadOnlyPhysicalDiskPresentation(
                id: group.id,
                title: "物理磁盘 \(index + 1)",
                detail: detail,
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
            accessDetail = "系统当前未挂载这个卷。"
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
            detail: "\(locationText)。\(purposeDetail)\(accessDetail)当前应用不会更改磁盘状态。"
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
                detail: volume.detail
            )
        }
    }
}
