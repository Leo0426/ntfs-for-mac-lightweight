import Foundation
import NTFSLiteCore
import NTFSLiteHelperProtocol
import NTFSLiteSystem

func expect(_ condition: Bool, _ message: String) {
    guard condition else { fatalError("CHECK FAILED: " + message) }
}

func writeSessionObservation(_ volume: VolumeInstanceID, includeEFI: Bool = true) -> DiskInventoryObservation {
    let diskName = volume.diskInstanceID.physicalDiskID.rawValue
    let target = ReadOnlyVolumeMapper.map(
        ReadOnlyVolumeEvidence(
            bsdName: volume.volumeID.bsdName, volumeUUID: volume.volumeID.uuid,
            physicalDiskBSDName: diskName, displayName: "NTFSLAB",
            fileSystemName: "ntfs", isInternal: false, roleEvidence: .unknown,
            diskArbitrationMountPoint: "/Volumes/NTFSLAB",
            mediaUUID: "90200000-0000-0000-0000-000000000002",
            mediaContent: "Windows_NTFS",
            mediaContentHint: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7",
            mediaRegistryID: 902
        ),
        mount: ReadOnlyMountEvidence(
            sourceBSDName: volume.volumeID.bsdName,
            mountPoint: "/Volumes/NTFSLAB", access: .readOnly,
            backend: .unknown, isComplete: true, isCanonical: true,
            isSymlink: false
        ),
        mediaGeneration: volume.diskInstanceID.mediaGeneration
    )
    let efi = ReadOnlyVolumeMapper.map(
        ReadOnlyVolumeEvidence(
            bsdName: diskName + "s1", volumeUUID: nil,
            physicalDiskBSDName: diskName, displayName: "EFI",
            fileSystemName: "msdos", isInternal: false, roleEvidence: .unknown,
            diskArbitrationMountPoint: nil,
            mediaUUID: "90100000-0000-0000-0000-000000000001",
            mediaContent: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B",
            mediaContentHint: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B",
            mediaRegistryID: 901
        ),
        mount: nil,
        mediaGeneration: volume.diskInstanceID.mediaGeneration
    )
    return DiskInventoryObservation(
        physicalDisks: [ReadOnlyPhysicalDiskRecord(
            instanceID: volume.diskInstanceID,
            description: DiskArbitrationDescription(
                bsdName: diskName, physicalDiskBSDName: diskName,
                isWholeDisk: true, isInternal: false,
                isEjectable: true, isRemovable: true,
                mediaSize: 1_000_000, mediaUUID: nil,
                volumeUUID: nil, volumeName: nil,
                fileSystemName: nil, mountPoint: nil,
                mediaContent: "GUID_partition_scheme", mediaRegistryID: 900
            ),
            volumes: includeEFI ? [efi, target] : [target], issues: []
        )],
        issues: []
    )
}

@main struct SessionEjectChecks {
    static func main() {
        let volume = VolumeInstanceID(volumeID: VolumeID(uuid: "4e6d1fc6-d631-3bd7-ae52-e7fca880a904", bsdName: "disk6s2"), diskInstanceID: DiskInstanceID(physicalDiskID: PhysicalDiskID(rawValue: "disk6"), mediaGeneration: MediaGeneration(rawValue: 3)))
        let observation = writeSessionObservation(volume)
        let binding = WriteSession.diskIdentity(volume.diskInstanceID, target: volume, in: observation)!
        func check(_ records: [ReadOnlyVolumeRecord], _ expected: Bool, _ message: String, issues: [DiskInventoryIssue] = [], diskIssues: [DiskInventoryIssue] = [], instance: DiskInstanceID? = nil, description: DiskArbitrationDescription? = nil) {
            let disk = ReadOnlyPhysicalDiskRecord(instanceID: instance ?? volume.diskInstanceID, description: description ?? observation.physicalDisks[0].description, volumes: records, issues: diskIssues)
            expect(WriteSession.canOfferSessionEject(volume.diskInstanceID, binding: binding, in: DiskInventoryObservation(physicalDisks: [disk], issues: issues)) == expected, message)
        }
        let efi = observation.physicalDisks[0].volumes[0]
        let old = observation.physicalDisks[0].volumes[1]
        func target(uuid: String? = nil, registry: UInt64 = 902, media: String = "90200000-0000-0000-0000-000000000002", content: String = "Windows_NTFS", role: VolumeRoleEvidence = .unknown, point: String? = nil, mount: ReadOnlyMountEvidence? = nil) -> ReadOnlyVolumeRecord {
            ReadOnlyVolumeMapper.map(ReadOnlyVolumeEvidence(bsdName: "disk6s2", volumeUUID: uuid, physicalDiskBSDName: "disk6", displayName: "NTFSLAB", fileSystemName: "ntfs", isInternal: false, roleEvidence: role, diskArbitrationMountPoint: point, mediaUUID: media, mediaContent: content, mediaContentHint: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", mediaRegistryID: registry), mount: mount, mediaGeneration: volume.diskInstanceID.mediaGeneration)
        }
        let supplemental = target(point: "/Volumes/NTFSLAB", mount: ReadOnlyMountEvidence(sourceBSDName: "disk6s2", mountPoint: "/Volumes/NTFSLAB", access: .readOnly, backend: .unknown, isComplete: true, isCanonical: true, isSymlink: false, fileSystemUUID: volume.volumeID.uuid))
        expect(supplemental.evidence.volumeUUID == nil && supplemental.candidate != nil, "first mounted supplemental UUID is candidate-only")
        let supplementalDisk = ReadOnlyPhysicalDiskRecord(instanceID: volume.diskInstanceID, description: observation.physicalDisks[0].description, volumes: [efi, supplemental], issues: [])
        let supplementalBinding = WriteSession.diskIdentity(volume.diskInstanceID, target: volume, in: DiskInventoryObservation(physicalDisks: [supplementalDisk], issues: []))
        expect(supplementalBinding == binding, "first supplemental candidate binds physical partition identity")
        let unmounted = target()
        expect(unmounted.candidate == nil && unmounted.snapshot == nil, "unmount loses supplemental UUID")
        check([efi, unmounted], true, "same exact live partitions permit bound session eject after UUID disappears")
        let unmountedDisk = ReadOnlyPhysicalDiskRecord(instanceID: volume.diskInstanceID, description: observation.physicalDisks[0].description, volumes: [efi, unmounted], issues: [])
        expect(WriteSession.diskIdentity(volume.diskInstanceID, target: volume, in: DiskInventoryObservation(physicalDisks: [unmountedDisk], issues: [])) == nil, "old UUID never authorizes another write")
        check([efi, old], true, "original candidate remains valid")
        check([], true, "hidden partition rows retain helper-revalidated eject entrance")
        check([unmounted], true, "hidden EFI still requires helper full partition revalidation")
        check([efi, unmounted, unmounted], false, "duplicate partition fails closed")
        check([efi, target(registry: 999)], false, "replacement registry fails closed")
        check([efi, target(media: "90200000-0000-0000-0000-000000000003")], false, "replacement partition UUID fails closed")
        check([efi, target(content: "Apple_APFS")], false, "changed content fails closed")
        check([efi, target(role: .protected)], false, "protected role fails closed")
        check([efi, target(role: .conflicting)], false, "conflicting role fails closed")
        check([efi, target(uuid: "bad")], false, "invalid current UUID fails closed")
        check([efi, target(point: "/Volumes/NTFSLAB")], false, "missing current mount table fails closed")
        let unknownMount = ReadOnlyMountEvidence(sourceBSDName: "disk6s2", mountPoint: "/Volumes/NTFSLAB", access: .readOnly, backend: .unknown, isComplete: false, isCanonical: true, isSymlink: false)
        check([efi, target(point: "/Volumes/NTFSLAB", mount: unknownMount)], false, "incomplete current mount fails closed")
        let nextInstance = DiskInstanceID(physicalDiskID: volume.diskInstanceID.physicalDiskID, mediaGeneration: MediaGeneration(rawValue: 4))
        check([efi, unmounted], false, "new media generation fails closed", instance: nextInstance)
        let replacementWhole = DiskArbitrationDescription(bsdName: "disk6", physicalDiskBSDName: "disk6", isWholeDisk: true, isInternal: false, isEjectable: true, isRemovable: true, mediaSize: 1_000_000, mediaUUID: nil, volumeUUID: nil, volumeName: nil, fileSystemName: nil, mountPoint: nil, mediaContent: "GUID_partition_scheme", mediaRegistryID: 999)
        check([efi, unmounted], false, "replacement whole IOMedia fails closed", description: replacementWhole)
        let mountedEFI = ReadOnlyVolumeMapper.map(ReadOnlyVolumeEvidence(bsdName: "disk6s1", volumeUUID: nil, physicalDiskBSDName: "disk6", displayName: "EFI", fileSystemName: "msdos", isInternal: false, roleEvidence: .unknown, diskArbitrationMountPoint: "/Volumes/EFI", mediaUUID: "90100000-0000-0000-0000-000000000001", mediaContent: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", mediaContentHint: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", mediaRegistryID: 901), mount: ReadOnlyMountEvidence(sourceBSDName: "disk6s1", mountPoint: "/Volumes/EFI", access: .readOnly, backend: .unknown, isComplete: true, isCanonical: true, isSymlink: false), mediaGeneration: volume.diskInstanceID.mediaGeneration)
        check([mountedEFI, unmounted], false, "mounted EFI sibling in full layout fails closed")
        let replacedEFI = ReadOnlyVolumeMapper.map(ReadOnlyVolumeEvidence(bsdName: "disk6s1", volumeUUID: nil, physicalDiskBSDName: "disk6", displayName: "EFI", fileSystemName: "msdos", isInternal: false, roleEvidence: .unknown, diskArbitrationMountPoint: nil, mediaUUID: "90100000-0000-0000-0000-000000000003", mediaContent: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", mediaContentHint: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", mediaRegistryID: 901), mount: nil, mediaGeneration: volume.diskInstanceID.mediaGeneration)
        check([replacedEFI, unmounted], false, "replaced EFI sibling in full layout fails closed")
        let staleMount = ReadOnlyMountEvidence(sourceBSDName: "disk6s2", mountPoint: "/Volumes/NTFSLAB", access: .readOnly, backend: .unknown, isComplete: true, isCanonical: true, isSymlink: false)
        check([efi, target(mount: staleMount)], false, "unexpected mount with nil DA point fails closed")
        for (source, point, access, canonical, symlink, name) in [
            ("disk7s2", "/Volumes/NTFSLAB", MountAccess.readOnly, true, false, "foreign source"),
            ("disk6s2", "/Volumes/Other", .readOnly, true, false, "point mismatch"),
            ("disk6s2", "/Volumes/NTFSLAB", .unmounted, true, false, "mount access mismatch"),
            ("disk6s2", "/Volumes/NTFSLAB", .readOnly, false, false, "noncanonical point"),
            ("disk6s2", "/Volumes/NTFSLAB", .readOnly, true, true, "symlink point")
        ] {
            let mount = ReadOnlyMountEvidence(sourceBSDName: source, mountPoint: point, access: access, backend: .unknown, isComplete: true, isCanonical: canonical, isSymlink: symlink)
            check([efi, target(uuid: volume.volumeID.uuid, point: "/Volumes/NTFSLAB", mount: mount)], false, name + " fails closed")
        }
        check([efi, unmounted], false, "unverified enumeration fails closed", issues: [.enumerationCoverageUnverified])
        check([efi, unmounted], false, "whole disk incomplete facts fail closed", diskIssues: [.missingRemovability(bsdName: "disk6")])
        for issue: ReadOnlyObservationIssue in [.missingBSDName, .invalidBSDName, .invalidVolumeUUID, .missingPhysicalDiskBSDName, .invalidPhysicalDiskBSDName, .invalidMediaGeneration, .missingFileSystemName, .missingLocation, .conflictingVolumeRole, .missingMountTableEntry, .mountTableReadFailed, .duplicateMountTableEntry, .unexpectedMountTableEntry, .incompleteMountTableEntry, .mountAccessMismatch, .sourceDeviceMismatch, .mountPointMismatch, .nonCanonicalMountPoint, .symbolicLinkMountPoint] {
            let incomplete = ReadOnlyVolumeRecord(evidence: unmounted.evidence, snapshot: nil, mountObservation: nil, issues: unmounted.issues + [issue])
            check([efi, incomplete], false, "current observation issue fails closed: " + String(describing: issue))
        }
        print("PASS: bound session eject validates exact live topology without reusing volume UUID for writing")
    }
}
