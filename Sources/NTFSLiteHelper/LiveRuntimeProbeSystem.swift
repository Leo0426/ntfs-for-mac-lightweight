import Darwin
import Foundation
import NTFSLiteHelperExecution
import NTFSLiteProtectedInstall

private typealias RuntimeStatFS = statfs

/// Owns exactly one fixed-template image and its children. Unknown cleanup keeps this object,
/// its descriptors and the persistent root lease alive; another helper cannot start a new probe.
final class LiveRuntimeProbeSystem: RuntimeProbeSystem, @unchecked Sendable {
    static let leasePath = "/private/var/db/com.leolu.ntfslite.runtime-probe"
    static func persistentQualification() -> RuntimeProbeQualification {
        guard safeParent("/private"), safeParent("/private/var"), safeParent("/private/var/db") else {
            return .unknown
        }
        var info = stat()
        if lstat(leasePath, &info) == 0 { return .present }
        return errno == ENOENT ? .absent : .unknown
    }
    private let system: LiveWritableMountSystem
    private let helpersDirectory: URL
    private var directory: stat?
    private var image: stat?
    private var mountDirectory: stat?
    private var imagePath: String?
    private var mountPoint: String?
    private var imageFD: Int32 = -1
    private var driverPID: Int32?
    private var driverExit: Bool?
    private var unmountPID: Int32?
    private var unmountExit: Bool?
    private var mountedRecord: RuntimeProbeMountRecord?
    private var pendingWritableChild: Int32?

    init(system: LiveWritableMountSystem, helpersDirectory: URL) {
        self.system = system; self.helpersDirectory = helpersDirectory
    }
    deinit { if imageFD >= 0 { close(imageFD) } }

    func prepare() async -> Bool? {
        let resource = helpersDirectory.deletingLastPathComponent()
            .appendingPathComponent("Resources/FSKitRuntimeProbe.ntfs.zlib").path
        guard getuid() == 0, Self.safeParent("/private"), Self.safeParent("/private/var"),
              Self.safeParent("/private/var/db"), Self.safeParent("/Volumes"),
              let bytes = RuntimeProbeSeed.readProtected(at: resource) else { return false }
        // mkdir is the cross-process lease: even a crash leaves a barrier until inspected.
        guard mkdir(Self.leasePath, 0o755) == 0 else { return errno == EEXIST ? nil : false }
        var created = stat()
        guard lstat(Self.leasePath, &created) == 0 else { return nil }
        directory = created
        let token = UUID().uuidString
        imagePath = Self.leasePath + "/probe-" + token + ".ntfs"
        mountPoint = "/Volumes/NTFSLiteRuntime-" + token
        guard Self.matches(Self.leasePath, created, owner: 0, type: S_IFDIR),
              Self.noACL(Self.leasePath), let imagePath, let mountPoint else { return nil }
        imageFD = open(imagePath, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard imageFD >= 0 else { return await remove() ? false : nil }
        var createdImage = stat()
        guard fstat(imageFD, &createdImage) == 0 else { return nil }
        image = createdImage
        guard fchown(imageFD, 0, 0) == 0, fchmod(imageFD, 0o600) == 0,
              Self.noACL(imagePath) else { return nil }
        let written = bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let count = write(imageFD, base.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written, fsync(imageFD) == 0, imageIsBound(),
              lseek(imageFD, 0, SEEK_SET) == 0,
              let copied = try? FileHandle(fileDescriptor: imageFD, closeOnDealloc: false).readToEnd(),
              copied.count == RuntimeProbeSeed.byteCount, RuntimeProbeSeed.digest(copied) == RuntimeProbeSeed.sha256,
              mkdir(mountPoint, 0o700) == 0 else { return await remove() ? false : nil }
        var createdMount = stat()
        guard lstat(mountPoint, &createdMount) == 0 else { return nil }
        mountDirectory = createdMount
        guard chown(mountPoint, uid_t(WritableMountExecutor.mountUID), gid_t(WritableMountExecutor.mountGID)) == 0,
              Self.noACL(mountPoint),
              Self.matches(mountPoint, createdMount, owner: uid_t(WritableMountExecutor.mountUID), type: S_IFDIR),
              await mount() == .absent else { return nil }
        return true
    }

    func start() async -> Bool? {
        let driver = helpersDirectory.appendingPathComponent("ntfs-3g")
        guard driverPID == nil, imageIsBound(), let imagePath, let mountPoint,
              await mount() == .absent,
              LiveWritableMountSystem.satisfiesPinnedSignature(driver, identifier: LiveWritableMountSystem.driverIdentifier)
        else { return false }
        driverPID = LiveWritableMountSystem.spawn(driver.path,
            ["ntfs-3g", imagePath, mountPoint, "-o", LiveWritableMountSystem.driverOptions], newSession: true)
        return driverPID != nil
    }

    func mount() async -> RuntimeProbeMount {
        guard let mountPoint, let records = RuntimeProbeMountRecord.stableTable() else { return .unknown }
        let selected = records.filter { $0.entry.mountPoint == mountPoint }
        guard selected.count <= 1 else { return .unknown }
        guard let record = selected.first else { return .absent }
        guard let pid = driverPID, driverExit == nil, imageIsBound(),
              let imagePath, let image,
              record.entry.flags.isSuperset(of: ["macfuse", "local", "fskit", "nodev", "nosuid"]),
              record.owner == WritableMountExecutor.mountUID,
              await system.isFSKitPlaceholder(source: record.entry.source),
              Self.holdsImage(pid: pid, path: imagePath, identity: image)
        else { return .unknown }
        let state = await system.driverState(pid: pid)
        guard state.isAlive, state.uid == WritableMountExecutor.mountUID,
              state.gid == WritableMountExecutor.mountGID,
              LiveWritableMountSystem.arguments(of: pid) ==
                ["ntfs-3g", imagePath, mountPoint, "-o", LiveWritableMountSystem.driverOptions],
              mountedRecord == nil || mountedRecord == record
        else { return .unknown }
        mountedRecord = record
        // Own this read-only child too: an unknown timeout cannot be collapsed to "not writable".
        guard let userWritable = await writableAsMountUser(mountPoint) else { return .unknown }
        let writable = !record.entry.flags.contains("read-only") && userWritable
        return .owned(writable: writable)
    }

    func driver() async -> RuntimeProbeDriver {
        if let driverExit { return .reaped(success: driverExit) }
        guard let driverPID else { return .unknown }
        switch RuntimeProbeChildWaiter.reap(driverPID) {
        case let .reaped(success): self.driverExit = success; return .reaped(success: success)
        case .running: return .running
        case .unknown: return .unknown
        }
    }

    func standardUnmount() async -> Bool? {
        guard case .owned = await mount(), unmountPID == nil, let mountPoint else { return nil }
        unmountPID = LiveWritableMountSystem.spawn(SecureHelperDeployment.executablePath,
            ["NTFSLiteHelper", MountUserAgent.flag, MountUserOperation.unmount.rawValue, mountPoint], newSession: false)
        guard let unmountPID else { return false }
        if case let .reaped(success) = await RuntimeProbeChildWaiter.wait(pid: unmountPID) {
            unmountExit = success
            return success
        }
        // Do not kill a timed-out unmount or let the daemon exit while it may still act.
        return nil
    }

    func remove() async -> Bool {
        guard let directory, Self.matches(Self.leasePath, directory, owner: 0, type: S_IFDIR),
              Self.noACL(Self.leasePath),
              pendingWritableChild == nil,
              driverPID == nil || driverExit != nil,
              unmountPID == nil || unmountExit != nil else { return false }
        if let mountPoint {
            guard await mount() == .absent else { return false }
            if let mountDirectory {
                guard Self.matches(mountPoint, mountDirectory, owner: uid_t(WritableMountExecutor.mountUID), type: S_IFDIR),
                      rmdir(mountPoint) == 0 else { return false }
                self.mountDirectory = nil
            } else {
                var info = stat()
                guard lstat(mountPoint, &info) != 0, errno == ENOENT else { return false }
            }
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: Self.leasePath),
              Set(names) == Set(image == nil ? [] : [(imagePath! as NSString).lastPathComponent])
        else { return false }
        if let image, let imagePath {
            guard Self.matches(imagePath, image, owner: 0, type: S_IFREG),
                  unlink(imagePath) == 0 else { return false }
            self.image = nil
        }
        if imageFD >= 0 { close(imageFD); imageFD = -1 }
        guard rmdir(Self.leasePath) == 0 else { return false }
        self.directory = nil
        return true
    }

    func pause() async {
        // Cleanup must keep waiting even if its caller was cancelled.
        await Task.detached { try? await Task.sleep(for: .milliseconds(250)) }.value
    }

    private func imageIsBound() -> Bool {
        guard let image, let imagePath, imageFD >= 0,
              Self.matches(imagePath, image, owner: 0, type: S_IFREG) else { return false }
        var opened = stat()
        return fstat(imageFD, &opened) == 0 && opened.st_dev == image.st_dev && opened.st_ino == image.st_ino
            && opened.st_mode == mode_t(S_IFREG | 0o600) && opened.st_uid == 0 && opened.st_gid == 0
            && opened.st_nlink == 1 && opened.st_size == RuntimeProbeSeed.byteCount
    }
    private static func matches(_ path: String, _ original: stat, owner: uid_t, type: mode_t) -> Bool {
        var now = stat()
        return lstat(path, &now) == 0 && now.st_dev == original.st_dev && now.st_ino == original.st_ino
            && now.st_mode & S_IFMT == mode_t(type) && now.st_uid == owner
            && now.st_mode & 0o022 == 0 && (type != S_IFREG || now.st_nlink == 1)
    }
    private static func safeParent(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == 0
            && info.st_mode & 0o022 == 0 && noACL(path)
    }
    private static func noACL(_ path: String) -> Bool {
        errno = 0
        if let acl = acl_get_file(path, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl))
            return false
        }
        return errno == ENOENT
    }
    private func writableAsMountUser(_ mountPoint: String) async -> Bool? {
        guard pendingWritableChild == nil else { return nil }
        pendingWritableChild = LiveWritableMountSystem.spawn(SecureHelperDeployment.executablePath,
            ["NTFSLiteHelper", MountUserAgent.flag, MountUserOperation.writable.rawValue, mountPoint], newSession: false)
        guard let pid = pendingWritableChild else { return false }
        guard case let .reaped(success) = await RuntimeProbeChildWaiter.wait(pid: pid) else { return nil }
        pendingWritableChild = nil
        return success
    }
    private static func holdsImage(pid: Int32, path: String, identity: stat) -> Bool {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0, bytes < 1_000_000 else { return false }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 64
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let capacity = Int32(count * MemoryLayout<proc_fdinfo>.stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, capacity)
        guard filled > 0, filled < capacity, Int(filled) % MemoryLayout<proc_fdinfo>.stride == 0 else { return false }
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var node = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &node, size) == size else { return false }
            let actual = LiveWritableMountSystem.string(&node.pvip.vip_path)
            if actual == path {
                return node.pvip.vip_vi.vi_stat.vst_dev == identity.st_dev
                    && node.pvip.vip_vi.vi_stat.vst_ino == identity.st_ino
                    && node.pvip.vip_vi.vi_stat.vst_mode & UInt16(S_IFMT) == UInt16(S_IFREG)
            }
        }
        return false
    }
}

struct RuntimeProbeMountRecord: Equatable {
    let entry: HelperMountEntry
    let owner: UInt32
    let fsid0: Int32
    let fsid1: Int32
    let flags: UInt32
    let extendedFlags: UInt32

    static func stableTable() -> [Self]? {
        func sample() -> [Self]? {
            let count = getfsstat(nil, 0, MNT_NOWAIT)
            guard count > 0, count < 100000 else { return nil }
            let capacity = Int(count) + 8
            var entries = [RuntimeStatFS](repeating: RuntimeStatFS(), count: capacity)
            let copied = getfsstat(&entries, Int32(capacity * MemoryLayout<RuntimeStatFS>.stride), MNT_NOWAIT)
            guard copied == count, copied < capacity, getfsstat(nil, 0, MNT_NOWAIT) == count else { return nil }
            return entries.prefix(Int(copied)).map { raw in
                var info = raw
                var flags: Set<String> = [LiveWritableMountSystem.string(&info.f_fstypename)]
                for (bit, name): (Int32, String) in [(MNT_RDONLY, "read-only"), (MNT_LOCAL, "local"),
                                                     (MNT_NODEV, "nodev"), (MNT_NOSUID, "nosuid")] {
                    if info.f_flags & UInt32(bit) != 0 { flags.insert(name) }
                }
                if info.f_flags_ext & UInt32(MNT_EXT_FSKIT) != 0 { flags.insert("fskit") }
                return Self(entry: HelperMountEntry(source: LiveWritableMountSystem.string(&info.f_mntfromname),
                    mountPoint: LiveWritableMountSystem.string(&info.f_mntonname), flags: flags),
                    owner: info.f_owner, fsid0: info.f_fsid.val.0, fsid1: info.f_fsid.val.1,
                    flags: info.f_flags, extendedFlags: info.f_flags_ext)
            }
        }
        guard let first = sample(), let second = sample(), first == second,
              Set(first.map { $0.entry.mountPoint }).count == first.count else { return nil }
        return second
    }
}
