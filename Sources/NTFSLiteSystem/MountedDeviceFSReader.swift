import Darwin
import Foundation

/// Binds the stable-table DeviceFS record to the current mounted directory object.
package enum MountedDeviceFSReader {
    package static func isBound(to expected: statfs) -> Bool {
        var expected = expected
        guard string(&expected.f_fstypename) == "devicefs",
              let path = string(&expected.f_mntonname),
              MountPathValidator.assess(path).isCanonical
        else { return false }
        let descriptor = openDirectory(path)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var before = statfs()
        guard fstatfs(descriptor, &before) == 0, matches(before, expected) else { return false }

        let currentDescriptor = openDirectory(path)
        guard currentDescriptor >= 0 else { return false }
        defer { close(currentDescriptor) }
        var after = statfs()
        var currentPath = statfs()
        return fstatfs(descriptor, &after) == 0 && matches(after, expected)
            && fstatfs(currentDescriptor, &currentPath) == 0 && matches(currentPath, expected)
            && MountPathValidator.assess(path).isCanonical
    }

    private static func openDirectory(_ path: String) -> Int32 {
        path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
    }

    private static func matches(_ first: statfs, _ second: statfs) -> Bool {
        var first = first
        var second = second
        return first.f_fsid.val.0 == second.f_fsid.val.0 && first.f_fsid.val.1 == second.f_fsid.val.1
            && first.f_type == second.f_type && first.f_flags == second.f_flags
            && first.f_flags_ext == second.f_flags_ext
            && string(&first.f_fstypename) == string(&second.f_fstypename)
            && string(&first.f_mntfromname) == string(&second.f_mntfromname)
            && string(&first.f_mntonname) == string(&second.f_mntonname)
    }

    private static func string<T>(_ value: inout T) -> String? {
        withUnsafeBytes(of: &value) { bytes in
            guard let end = bytes.firstIndex(of: 0), end > 0, end < bytes.count - 1 else { return nil }
            return String(bytes: bytes.prefix(end), encoding: .utf8)
        }
    }
}
