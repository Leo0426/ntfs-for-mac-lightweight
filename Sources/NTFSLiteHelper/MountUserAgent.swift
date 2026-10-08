import Darwin
import Foundation
import NTFSLiteHelperExecution
import NTFSLiteSystem

enum MountUserOperation: String {
    case volumeUUID = "volume-uuid"
    case writable
    case unmount
}

/// Child mode of the helper binary: permanently drop to the fixed mount user, then run exactly
/// one fixed operation on a mount point under /Volumes. FSKit mounts are per user and refuse root.
enum MountUserAgent {
    static let flag = "--as-mount-user"

    static func isAcceptedMountPoint(_ path: String) -> Bool {
        path.hasPrefix("/Volumes/") && !path.contains("/../") && !path.hasSuffix("/..")
            && !path.dropFirst("/Volumes/".count).contains("/") && path.count > "/Volumes/".count
    }

    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 4, arguments[1] == flag,
              let operation = MountUserOperation(rawValue: arguments[2]),
              isAcceptedMountPoint(arguments[3])
        else { return 64 }
        var groups: [gid_t] = [WritableMountExecutor.mountGID]
        guard setgroups(1, &groups) == 0, setgid(WritableMountExecutor.mountGID) == 0,
              setuid(WritableMountExecutor.mountUID) == 0,
              getuid() == WritableMountExecutor.mountUID, geteuid() == WritableMountExecutor.mountUID,
              getgid() == WritableMountExecutor.mountGID, getegid() == WritableMountExecutor.mountGID,
              setuid(0) != 0
        else { return 70 }
        let mountPoint = arguments[3]
        switch operation {
        case .volumeUUID:
            guard let entry = LiveWritableMountSystem.statfsEntry(mountPoint: mountPoint),
                  let uuid = MountedFileSystemUUIDReader.read(for: entry)
            else { return 1 }
            print(uuid)
            return 0
        case .writable:
            var root = stat(), parent = stat(), volume = statvfs()
            let writable = lstat(mountPoint, &root) == 0 && root.st_mode & S_IFMT == S_IFDIR
                && stat("/Volumes", &parent) == 0 && root.st_dev != parent.st_dev
                && statvfs(mountPoint, &volume) == 0 && volume.f_flag & UInt(ST_RDONLY) == 0
            return writable ? 0 : 1
        case .unmount:
            // Standard unmount only: no MNT_FORCE.
            return unmount(mountPoint, 0) == 0 ? 0 : 1
        }
    }
}
