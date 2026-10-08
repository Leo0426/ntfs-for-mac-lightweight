import CryptoKit
import Darwin
import Foundation

/// Fixed blank NTFS template generated once from the pinned mkntfs, sealed by the App signature.
enum RuntimeProbeSeed {
    static let byteCount = 128 * 1024 * 1024
    static let compressedByteCount = 252203
    static let sha256 = "0fa5b73d5f603c9b7c25a9a67f2e003a2cca7cc4c18cbf3e664e76fbe2caff31"
    static let compressedSHA256 = "bc13f484e9bc508733246b1bc2145068041b883a5eaad32273106d54c09d7c34"
    static func decode(_ compressed: Data) -> Data? {
        // Authenticate the small compressed stream before allocating decompression output.
        guard compressed.count == compressedByteCount, digest(compressed) == compressedSHA256,
              let expanded = try? (compressed as NSData).decompressed(using: .zlib),
              expanded.length == byteCount else { return nil }
        let bytes = expanded as Data
        return digest(bytes) == sha256 ? bytes : nil
    }
    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func readProtected(at path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, before.st_mode == mode_t(S_IFREG | 0o644),
              before.st_uid == 0, before.st_gid == 0, before.st_nlink == 1,
              before.st_size == compressedByteCount,
              let compressed = try? handle.read(upToCount: compressedByteCount + 1),
              fstat(fd, &after) == 0, lstat(path, &named) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mode == after.st_mode, before.st_uid == after.st_uid,
              before.st_gid == after.st_gid, before.st_nlink == after.st_nlink,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              named.st_dev == before.st_dev, named.st_ino == before.st_ino,
              named.st_mode == before.st_mode, named.st_nlink == before.st_nlink
        else { return nil }
        return decode(compressed)
    }
}
