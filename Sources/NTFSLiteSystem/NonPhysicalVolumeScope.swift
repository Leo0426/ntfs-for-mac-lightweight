import Foundation

/// A finite file-backed DeviceFS scope, not a rule for all BSD-less or FSKit volumes.
/// The caller supplies two complete, independently read mount-table snapshots.
package enum NonPhysicalVolumeScope {
    package static func isVerifiedDeviceFS(
        _ description: DiskArbitrationDescription,
        first: SystemMountTableSnapshot,
        second: SystemMountTableSnapshot
    ) -> Bool {
        guard description.fileSystemName == "devicefs",
              description.isNetworkVolume == false,
              description.ioMediaLookupReturnedObject == false,
              description.hasPhysicalMediaDescription == false,
              description.bsdName == nil, description.physicalDiskBSDName == nil,
              description.isWholeDisk == nil, description.isInternal == nil,
              description.isEjectable == nil, description.isRemovable == nil,
              description.mediaSize == nil, description.mediaUUID == nil,
              description.mediaContent == nil, description.mediaContentHint == nil,
              description.mediaRegistryID == nil, description.volumeUUID == nil,
              let mountPoint = description.mountPoint, !mountPoint.isEmpty,
              first == second
        else { return false }

        let records = first.records.filter { $0.mountPoint == mountPoint }
        guard records.count == 1, let record = records.first,
              record.fileSystemName == "devicefs", record.sourceBSDName == nil,
              record.isComplete, record.isCanonical, !record.isSymlink,
              record.isLocal == true, record.isFSKit == true,
              let fsid = record.fileSystemID, fsid.count == 2,
              fsid.contains(where: { $0 != 0 })
        else { return false }
        return isFileBackedDeviceFSSource(record.sourcePath)
    }

    private static func isFileBackedDeviceFSSource(_ source: String) -> Bool {
        let prefix = "devices -- "
        // f_mntfromname is bounded by MAXPATHLEN. A full buffer may be truncated.
        guard source.hasPrefix(prefix), source.utf8.count < 1_023,
              !source.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let components = URLComponents(string: String(source.dropFirst(prefix.count))),
              components.scheme == "file", components.host == nil || components.host == "",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              !components.path.isEmpty, components.path.hasPrefix("/"),
              components.path != "/dev", !components.path.hasPrefix("/dev/"),
              !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { return false }
        return true
    }
}
