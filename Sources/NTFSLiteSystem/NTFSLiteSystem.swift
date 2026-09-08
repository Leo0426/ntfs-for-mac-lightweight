import Foundation
import NTFSLiteCore

public struct ReadOnlyVolumeEvidence: Equatable, Sendable {
    public let bsdName: String?
    public let volumeUUID: String?
    public let physicalDiskBSDName: String?
    public let displayName: String?
    public let fileSystemName: String?
    public let isInternal: Bool?
    public let roleEvidence: VolumeRoleEvidence
    public let diskArbitrationMountPoint: String?

    public init(
        bsdName: String?,
        volumeUUID: String?,
        physicalDiskBSDName: String?,
        displayName: String?,
        fileSystemName: String?,
        isInternal: Bool?,
        roleEvidence: VolumeRoleEvidence,
        diskArbitrationMountPoint: String?
    ) {
        self.bsdName = bsdName
        self.volumeUUID = volumeUUID
        self.physicalDiskBSDName = physicalDiskBSDName
        self.displayName = displayName
        self.fileSystemName = fileSystemName
        self.isInternal = isInternal
        self.roleEvidence = roleEvidence
        self.diskArbitrationMountPoint = diskArbitrationMountPoint
    }
}

public struct ReadOnlyMountEvidence: Equatable, Sendable {
    public let sourceBSDName: String
    public let mountPoint: String
    public let access: MountAccess
    public let backend: ObservedMountBackend
    public let isComplete: Bool
    public let isCanonical: Bool
    public let isSymlink: Bool
    public let fileSystemUUID: String?

    public init(
        sourceBSDName: String,
        mountPoint: String,
        access: MountAccess,
        backend: ObservedMountBackend,
        isComplete: Bool,
        isCanonical: Bool,
        isSymlink: Bool,
        fileSystemUUID: String? = nil
    ) {
        self.sourceBSDName = sourceBSDName
        self.mountPoint = mountPoint
        self.access = access
        self.backend = backend
        self.isComplete = isComplete
        self.isCanonical = isCanonical
        self.isSymlink = isSymlink
        self.fileSystemUUID = fileSystemUUID
    }
}

public enum ReadOnlyObservationIssue: Equatable, Sendable {
    case missingBSDName
    case invalidBSDName
    case missingVolumeUUID
    case invalidVolumeUUID
    case missingPhysicalDiskBSDName
    case invalidPhysicalDiskBSDName
    case invalidMediaGeneration
    case missingDisplayName
    case missingFileSystemName
    case missingLocation
    case unknownVolumeRole
    case conflictingVolumeRole
    case missingMountTableEntry
    case mountTableReadFailed
    case duplicateMountTableEntry
    case unexpectedMountTableEntry
    case incompleteMountTableEntry
    case mountAccessMismatch
    case sourceDeviceMismatch
    case mountPointMismatch
    case nonCanonicalMountPoint
    case symbolicLinkMountPoint
}

public struct ReadOnlyVolumeRecord: Equatable, Sendable {
    public let evidence: ReadOnlyVolumeEvidence
    public let candidate: ReadOnlyVolumeCandidate?
    public let snapshot: VolumeSnapshot?
    public let mountObservation: MountObservation?
    public let issues: [ReadOnlyObservationIssue]

    public init(
        evidence: ReadOnlyVolumeEvidence,
        candidate: ReadOnlyVolumeCandidate? = nil,
        snapshot: VolumeSnapshot?,
        mountObservation: MountObservation?,
        issues: [ReadOnlyObservationIssue]
    ) {
        self.evidence = evidence
        self.candidate = candidate
        self.snapshot = snapshot
        self.mountObservation = mountObservation
        self.issues = issues
    }

    public var isComplete: Bool {
        snapshot != nil && issues.isEmpty
    }
}

public enum ReadOnlyVolumeMapper {
    public static func map(
        _ evidence: ReadOnlyVolumeEvidence,
        mount: ReadOnlyMountEvidence?,
        mediaGeneration: MediaGeneration
    ) -> ReadOnlyVolumeRecord {
        var issues: [ReadOnlyObservationIssue] = []

        let rawBSDName = required(
            evidence.bsdName,
            issue: .missingBSDName,
            into: &issues
        )
        let bsdName: String?
        if let rawBSDName, isValidVolumeBSDName(rawBSDName) {
            bsdName = rawBSDName
        } else {
            bsdName = nil
            if rawBSDName != nil {
                issues.append(.invalidBSDName)
            }
        }

        // Supplemental filesystem identity is scoped to mounted external
        // unknown-role NTFS candidates, never to a mutation snapshot.
        let supplementalUUID = evidence.isInternal == false
            && evidence.roleEvidence == .unknown
            && normalized(evidence.fileSystemName)?.lowercased() == "ntfs"
            && normalized(evidence.diskArbitrationMountPoint) != nil
            ? mount?.fileSystemUUID : nil
        let rawVolumeUUID = required(
            evidence.volumeUUID ?? supplementalUUID,
            issue: .missingVolumeUUID,
            into: &issues
        )
        let volumeUUID: String?
        if let rawVolumeUUID,
           rawVolumeUUID.utf8.count == 36,
           let parsedUUID = UUID(uuidString: rawVolumeUUID)
        {
            volumeUUID = parsedUUID.uuidString.lowercased()
        } else {
            volumeUUID = nil
            if rawVolumeUUID != nil {
                issues.append(.invalidVolumeUUID)
            }
        }

        if let reportedUUID = evidence.volumeUUID,
           let fileSystemUUID = mount?.fileSystemUUID,
           UUID(uuidString: reportedUUID) != UUID(uuidString: fileSystemUUID),
           !issues.contains(.invalidVolumeUUID)
        {
            issues.append(.invalidVolumeUUID)
        }

        let rawPhysicalDiskBSDName = required(
            evidence.physicalDiskBSDName,
            issue: .missingPhysicalDiskBSDName,
            into: &issues
        )
        let physicalDiskBSDName: String?
        if let rawPhysicalDiskBSDName,
           isValidWholeDiskBSDName(rawPhysicalDiskBSDName)
        {
            physicalDiskBSDName = rawPhysicalDiskBSDName
        } else {
            physicalDiskBSDName = nil
            if rawPhysicalDiskBSDName != nil {
                issues.append(.invalidPhysicalDiskBSDName)
            }
        }
        if let bsdName,
           let physicalDiskBSDName,
           !bsdName.hasPrefix(physicalDiskBSDName + "s")
        {
            issues.append(.invalidBSDName)
        }
        if mediaGeneration.rawValue == 0 {
            issues.append(.invalidMediaGeneration)
        }
        let displayName = required(
            evidence.displayName,
            issue: .missingDisplayName,
            into: &issues
        )
        let fileSystemName = required(
            evidence.fileSystemName,
            issue: .missingFileSystemName,
            into: &issues
        )
        if evidence.isInternal == nil {
            issues.append(.missingLocation)
        }

        let role: VolumeRole?
        switch (evidence.roleEvidence, evidence.isInternal) {
        case (.trustedData, false):
            role = .data
        case (.protected, true):
            role = .protected
        case (.unknown, _):
            role = nil
            issues.append(.unknownVolumeRole)
        case (.conflicting, _), (.trustedData, true), (.protected, false):
            role = nil
            issues.append(.conflictingVolumeRole)
        case (.trustedData, nil), (.protected, nil):
            role = nil
        }

        let diskArbitrationMountPoint = normalized(evidence.diskArbitrationMountPoint)
        var mountObservation: MountObservation?
        var mountAccess: MountAccess = .unmounted

        switch (diskArbitrationMountPoint, mount) {
        case (.some, .none):
            issues.append(.missingMountTableEntry)
        case (.none, .some):
            issues.append(.unexpectedMountTableEntry)
        case let (.some(expectedMountPoint), .some(observedMount)):
            if !observedMount.isComplete {
                issues.append(.incompleteMountTableEntry)
            }
            if observedMount.access == .unmounted {
                issues.append(.mountAccessMismatch)
            }
            if normalized(observedMount.sourceBSDName) != bsdName {
                issues.append(.sourceDeviceMismatch)
            }
            if normalized(observedMount.mountPoint) != expectedMountPoint {
                issues.append(.mountPointMismatch)
            }
            if !observedMount.isCanonical {
                issues.append(.nonCanonicalMountPoint)
            }
            if observedMount.isSymlink {
                issues.append(.symbolicLinkMountPoint)
            }
            mountAccess = observedMount.access

            if let bsdName, let volumeUUID, let physicalDiskBSDName {
                mountObservation = MountObservation(
                    volumeID: VolumeID(uuid: volumeUUID, bsdName: bsdName),
                    physicalDiskID: PhysicalDiskID(rawValue: physicalDiskBSDName),
                    mediaGeneration: mediaGeneration,
                    access: observedMount.access,
                    backend: observedMount.backend,
                    mountPoint: observedMount.mountPoint,
                    isComplete: observedMount.isComplete,
                    sourceBSDName: observedMount.sourceBSDName,
                    isCanonical: observedMount.isCanonical,
                    isSymlink: observedMount.isSymlink
                )
            }
        case (.none, .none):
            break
        }

        let fileSystem = fileSystemName.map { name in
            name.caseInsensitiveCompare("ntfs") == .orderedSame
                ? FileSystemKind.ntfs
                : FileSystemKind.other
        }
        let location = evidence.isInternal.map { isInternal in
            isInternal ? VolumeLocation.internal : VolumeLocation.external
        }

        let snapshot: VolumeSnapshot?
        if issues.isEmpty,
           let bsdName,
           let volumeUUID,
           let physicalDiskBSDName,
           let displayName,
           let fileSystem,
           let location,
           let role
        {
            snapshot = VolumeSnapshot(
                id: VolumeID(uuid: volumeUUID, bsdName: bsdName),
                physicalDiskID: PhysicalDiskID(rawValue: physicalDiskBSDName),
                mediaGeneration: mediaGeneration,
                displayName: displayName,
                fileSystem: fileSystem,
                location: location,
                role: role,
                health: .unknown,
                mountAccess: mountAccess
            )
        } else {
            snapshot = nil
        }

        let candidate: ReadOnlyVolumeCandidate?
        if issues == [.unknownVolumeRole],
           let bsdName,
           let volumeUUID,
           let physicalDiskBSDName,
           let displayName,
           fileSystem == .ntfs,
           location == .external
        {
            candidate = ReadOnlyVolumeCandidate(
                id: VolumeID(uuid: volumeUUID, bsdName: bsdName),
                physicalDiskID: PhysicalDiskID(rawValue: physicalDiskBSDName),
                mediaGeneration: mediaGeneration,
                displayName: displayName,
                fileSystem: .ntfs,
                location: .external,
                mountAccess: mountAccess
            )
        } else {
            candidate = nil
        }

        return ReadOnlyVolumeRecord(
            evidence: evidence,
            candidate: candidate,
            snapshot: snapshot,
            mountObservation: issues.isEmpty ? mountObservation : nil,
            issues: issues
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isValidWholeDiskBSDName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count > 4,
              bytes.count <= 255,
              bytes.starts(with: Array("disk".utf8))
        else {
            return false
        }
        return bytes.dropFirst(4).allSatisfy { (48 ... 57).contains($0) }
    }

    private static func isValidVolumeBSDName(_ value: String) -> Bool {
        // `diskNsM` (a partition) or `diskNsMsK` (an APFS snapshot volume, which
        // macOS mounts for the sealed system volume). Anything else — a path
        // fragment, a whole disk, a trailing/empty group — is rejected.
        guard value.hasPrefix("disk") else {
            return false
        }
        let groups = value.dropFirst("disk".count).split(
            separator: "s",
            omittingEmptySubsequences: false
        )
        guard groups.count == 2 || groups.count == 3 else {
            return false
        }
        return groups.allSatisfy { group in
            !group.isEmpty && group.utf8.allSatisfy { (48 ... 57).contains($0) }
        }
    }

    private static func required(
        _ value: String?,
        issue: ReadOnlyObservationIssue,
        into issues: inout [ReadOnlyObservationIssue]
    ) -> String? {
        guard let value = normalized(value) else {
            issues.append(issue)
            return nil
        }
        return value
    }
}

public enum MountSourceParser {
    public static func bsdName(from sourcePath: String) -> String? {
        let prefix = "/dev/"
        guard sourcePath.hasPrefix(prefix) else {
            return nil
        }

        let candidate = String(sourcePath.dropFirst(prefix.count))
        let fullRange = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        let expression = try? NSRegularExpression(
            pattern: #"^disk[0-9]+(?:s[0-9]+)*$"#
        )
        guard expression?.firstMatch(
            in: candidate,
            range: fullRange
        )?.range == fullRange else {
            return nil
        }
        return candidate
    }
}
