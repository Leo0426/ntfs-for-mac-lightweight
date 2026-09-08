import Darwin
import Foundation

/// Only decodes the exact response to RETURNED_ATTRS + VOL_INFO + VOL_UUID.
package enum MountedFileSystemUUIDReader {
    package static func read(for expected: statfs) -> String? {
        guard expected.f_flags & UInt32(MNT_LOCAL) != 0 else { return nil }
        var expected = expected
        guard let path = string(from: &expected.f_mntonname),
              let source = string(from: &expected.f_mntfromname),
              MountSourceParser.bsdName(from: source) != nil
        else { return nil }
        let assessment = MountPathValidator.assess(path)
        guard assessment.isCanonical, !assessment.isSymlink else { return nil }
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var before = statfs()
        guard fstatfs(descriptor, &before) == 0, matches(before, expected),
              let first = readUUID(descriptor), let second = readUUID(descriptor),
              first == second
        else { return nil }
        var after = statfs()
        var currentPath = statfs()
        let currentDescriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard currentDescriptor >= 0 else { return nil }
        defer { Darwin.close(currentDescriptor) }
        guard fstatfs(descriptor, &after) == 0, matches(after, expected),
              fstatfs(currentDescriptor, &currentPath) == 0,
              matches(currentPath, expected)
        else { return nil }
        return first
    }

    private static func readUUID(_ descriptor: Int32) -> String? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
        var bytes = Data(repeating: 0, count: 40)
        let result = bytes.withUnsafeMutableBytes {
            fgetattrlist(descriptor, &attributes, $0.baseAddress, $0.count, 0)
        }
        guard result == 0 else { return nil }
        return decode(bytes)
    }

    private static func matches(_ lhs: statfs, _ rhs: statfs) -> Bool {
        var lhs = lhs
        var rhs = rhs
        return lhs.f_fsid.val.0 == rhs.f_fsid.val.0
            && lhs.f_fsid.val.1 == rhs.f_fsid.val.1
            && lhs.f_flags == rhs.f_flags
            && string(from: &lhs.f_mntfromname) == string(from: &rhs.f_mntfromname)
            && string(from: &lhs.f_mntonname) == string(from: &rhs.f_mntonname)
            && string(from: &lhs.f_fstypename) == string(from: &rhs.f_fstypename)
    }

    private static func string<T>(from value: inout T) -> String? {
        withUnsafeBytes(of: &value) { bytes in
            guard let end = bytes.firstIndex(of: 0), end > 0 else { return nil }
            return String(bytes: bytes.prefix(end), encoding: .utf8)
        }
    }

    package static func decode(_ data: Data) -> String? {
        guard data.count == 40 else { return nil }
        return data.withUnsafeBytes { bytes in
            let expected: [UInt32] = [40, UInt32(ATTR_CMN_RETURNED_ATTRS),
                                      UInt32(ATTR_VOL_UUID), 0, 0, 0]
            for (index, word) in expected.enumerated() {
                guard bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self) == word else {
                    return nil
                }
            }
            guard data.suffix(16).contains(where: { $0 != 0 }) else { return nil }
            let value = bytes.loadUnaligned(fromByteOffset: 24, as: uuid_t.self)
            return UUID(uuid: value).uuidString.lowercased()
        }
    }
}
