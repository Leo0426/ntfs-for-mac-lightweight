import Darwin
import DiskArbitration
import Foundation
import IOKit
import NTFSLiteHelperExecution
import NTFSLiteHelperProtocol
import NTFSLiteSystem
import Security

private typealias FileSystemStatus = statfs

/// Real system operations for the privileged helper (ADR 0010). Every call reads fresh facts;
/// no forced unmount, recovery or cross-user mount option is ever used.
final class LiveWritableMountSystem: WritableMountSystem, @unchecked Sendable {
    static let driverOptions = "rw,no_def_opts,silent,backend=fskit,norecover,no_detach,local"
    static let driverIdentifier = "com.leolu.ntfslite.ntfs-3g"
    static let probeIdentifier = "com.leolu.ntfslite.ntfs-3g.probe"
    private static let diskCallbacks = HelperOneShotCallbackRegistry()
    private static let diskCallbackTimeout: Duration = .seconds(60)

    private let helpersDirectory: URL
    private let executablePath: String
    private let session: DASession
    private let queue = DispatchQueue(label: "com.leolu.ntfslite.helper.diskarbitration")

    init?() {
        var size = UInt32(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0,
              let session = DASessionCreate(kCFAllocatorDefault)
        else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        executablePath = executable.path
        // Contents/MacOS/NTFSLiteHelper -> Contents/Helpers
        helpersDirectory = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers", isDirectory: true)
        self.session = session
        DASessionSetDispatchQueue(session, queue)
    }

    // MARK: Facts

    func volumeFacts(bsdName: String) async -> HelperVolumeFacts? {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }
        // The BSD name pointer is owned by its DADisk; copy it while the disk is alive.
        let whole = DADiskCopyWholeDisk(disk).flatMap { wholeDisk in
            withExtendedLifetime(wholeDisk) { DADiskGetBSDName(wholeDisk).map { String(cString: $0) } }
        }
        let name = withExtendedLifetime(disk) { DADiskGetBSDName(disk).map { String(cString: $0) } }
        let mountPoint = (description[kDADiskDescriptionVolumePathKey as String] as? URL)?.path
        var writable: Bool?
        var uuid = Self.uuid(for: kDADiskDescriptionVolumeUUIDKey, in: description)
        if let mountPoint {
            guard var info = Self.statfsEntry(mountPoint: mountPoint) else { return nil }
            let source = Self.string(&info.f_mntfromname)
            let devicePath = "/dev/" + bsdName
            let virtualSource = source != devicePath
            let placeholder = virtualSource ? await isFSKitPlaceholder(source: source) : false
            let owned = virtualSource ? await ownedFSKitMounts(devicePath: devicePath) : nil
            guard HelperMountSourceBinding.accepts(
                source: source, devicePath: devicePath, mountPoint: mountPoint,
                ownedMounts: owned, isFSKitPlaceholder: placeholder
            ) else { return nil }
            writable = info.f_flags & UInt32(MNT_RDONLY) == 0
            // FSKit mounts are per user; root is refused, so read as the mount user.
            if uuid == nil, let result = await runAsMountUser(.volumeUUID, mountPoint: mountPoint), result.status == 0 {
                uuid = result.output.trimmingCharacters(in: .newlines)
            }
        }
        return HelperVolumeFacts(
            bsdName: name,
            wholeDiskBSDName: whole,
            isWholeDisk: description[kDADiskDescriptionMediaWholeKey as String] as? Bool,
            isInternal: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool,
            isRemovable: description[kDADiskDescriptionMediaRemovableKey as String] as? Bool,
            isEjectable: description[kDADiskDescriptionMediaEjectableKey as String] as? Bool,
            deviceProtocol: description[kDADiskDescriptionDeviceProtocolKey as String] as? String,
            fileSystemName: description[kDADiskDescriptionVolumeKindKey as String] as? String,
            mountPoint: mountPoint,
            isWritableMount: writable,
            volumeUUID: uuid,
            volumeName: description[kDADiskDescriptionVolumeNameKey as String] as? String,
            mediaUUID: Self.uuid(for: kDADiskDescriptionMediaUUIDKey, in: description),
            mediaContent: description[kDADiskDescriptionMediaContentKey as String] as? String
        )
    }

    func mediaTopology(diskBSDName disk: String) async -> HelperMediaTopology? {
        HelperMediaTopologySettlement.settled {
            Self.mediaTopologySample(diskBSDName: disk, session: session)
        }
    }

    private static func mediaTopologySample(
        diskBSDName disk: String, session: DASession
    ) -> HelperMediaTopology? {
        guard disk.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              let inventory = try? SystemIOMediaEnumerationReader().currentSnapshot(),
              inventory.bsdNames.contains(disk)
        else { return nil }
        let children = inventory.bsdNames.filter { $0.hasPrefix(disk + "s") }.sorted()
        guard !children.isEmpty else { return nil }
        var observed: [HelperObservedMedia] = []
        for bsd in [disk] + children {
            guard let daDisk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else { return nil }
            let ioMedia = DADiskCopyIOMedia(daDisk)
            guard ioMedia != 0 else { return nil }
            defer { IOObjectRelease(ioMedia) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(ioMedia, &entryID) == KERN_SUCCESS,
                  entryID > 0,
                  let isWhole = ioBoolean("Whole", on: ioMedia),
                  isWhole == (bsd == disk)
            else { return nil }
            let parentID = bsd == disk ? nil : parentWholeMediaEntryID(of: ioMedia)
            guard bsd == disk || parentID != nil else { return nil }
            observed.append(HelperObservedMedia(
                bsdName: bsd, registryEntryID: entryID,
                parentRegistryEntryID: parentID, isWholeDisk: isWhole,
                mediaUUID: ioString("UUID", on: ioMedia),
                content: ioString("Content", on: ioMedia),
                contentHint: ioString("Content Hint", on: ioMedia)
            ))
        }
        return HelperMediaTopology(disk: observed[0], partitions: Array(observed.dropFirst()))
    }

    private static func parentWholeMediaEntryID(of media: io_service_t) -> UInt64? {
        var current = media
        for _ in 0..<16 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                if current != media { IOObjectRelease(current) }
                return nil
            }
            if current != media { IOObjectRelease(current) }
            if IOObjectConformsTo(parent, "IOMedia") != 0,
               ioBoolean("Whole", on: parent) == true {
                var entryID: UInt64 = 0
                let result = IORegistryEntryGetRegistryEntryID(parent, &entryID)
                IOObjectRelease(parent)
                return result == KERN_SUCCESS && entryID > 0 ? entryID : nil
            }
            current = parent
        }
        if current != media { IOObjectRelease(current) }
        return nil
    }

    private static func ioString(_ key: String, on media: io_registry_entry_t) -> String? {
        IORegistryEntryCreateCFProperty(media, key as NSString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func ioBoolean(_ key: String, on media: io_registry_entry_t) -> Bool? {
        IORegistryEntryCreateCFProperty(media, key as NSString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    private static func uuid(for key: CFString, in description: [String: Any]) -> String? {
        guard let raw = description[key as String] else { return nil }
        let value = raw as CFTypeRef
        guard CFGetTypeID(value) == CFUUIDGetTypeID() else { return nil }
        return CFUUIDCreateString(nil, (raw as! CFUUID)) as String
    }

    func readBootSector(partitionBSDName bsd: String) async -> Data? {
        // A mounted block device refuses open; read the paired raw node, bound by device number.
        var block = stat(), raw = stat()
        guard bsd.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil,
              lstat("/dev/" + bsd, &block) == 0, lstat("/dev/r" + bsd, &raw) == 0,
              block.st_mode & S_IFMT == S_IFBLK, raw.st_mode & S_IFMT == S_IFCHR,
              block.st_rdev == raw.st_rdev
        else { return nil }
        let fd = open("/dev/r" + bsd, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_rdev == raw.st_rdev, opened.st_ino == raw.st_ino else { return nil }
        var bytes = [UInt8](repeating: 0, count: 512)
        guard read(fd, &bytes, 512) == 512 else { return nil }
        return Data(bytes)
    }

    func fsKitRuntimeReady() async -> Bool? {
        let driver = helpersDirectory.appendingPathComponent("ntfs-3g")
        let probe = helpersDirectory.appendingPathComponent("ntfs-3g.probe")
        guard Self.satisfiesPinnedSignature(driver, identifier: Self.driverIdentifier),
              Self.satisfiesPinnedSignature(probe, identifier: Self.probeIdentifier)
        else { return false }
        // FSKit module selection is per user. Ask the same fixed UID that will
        // own the mount, before removing the native read-only mount.
        guard let result = await runAsMountUser(
            .fsKitReady, mountPoint: MountUserAgent.fsKitCheckPlaceholder,
            timeout: .seconds(5)
        ) else { return nil }
        return result.status == 0
    }

    func healthIsClean(bsdName bsd: String) async -> Bool? {
        let probe = helpersDirectory.appendingPathComponent("ntfs-3g.probe")
        guard Self.satisfiesPinnedSignature(probe, identifier: Self.probeIdentifier),
              let pid = Self.spawn(probe.path, ["ntfs-3g.probe", "--readwrite", "/dev/" + bsd], newSession: false)
        else { return nil }
        // Read-only probe: one deadline owns both the exit and child cleanup.
        switch await BoundedHelperChildIO.run(
            pid: pid, outputFD: nil, timeout: .seconds(60), maximumOutputBytes: 0
        ) {
        case let .completed(exitStatus, _): return exitStatus == 0
        case .timedOutReaped, .ioFailedReaped, .terminationUnconfirmed: return nil
        }
    }

    // MARK: Mutations

    private func boundDADisk(
        bsdName bsd: String, expectedRegistryEntryID: UInt64, isWholeDisk: Bool
    ) -> DADisk? {
        guard expectedRegistryEntryID > 0,
              let named = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd)
        else { return nil }
        let media = DADiskCopyIOMedia(named)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &entryID) == KERN_SUCCESS,
              entryID == expectedRegistryEntryID,
              Self.ioBoolean("Whole", on: media) == isWholeDisk,
              let bound = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, media),
              let boundName = DADiskGetBSDName(bound).map({ String(cString: $0) }),
              boundName == bsd,
              let description = DADiskCopyDescription(bound) as? [String: Any],
              description[kDADiskDescriptionMediaWholeKey as String] as? Bool == isWholeDisk
        else { return nil }
        return bound
    }

    func unmountNative(bsdName bsd: String, expectedRegistryEntryID: UInt64) async -> Bool {
        guard let disk = boundDADisk(
            bsdName: bsd, expectedRegistryEntryID: expectedRegistryEntryID, isWholeDisk: false
        ) else { return false }
        return await withCheckedContinuation { continuation in
            guard let token = Self.diskCallbacks.register(continuation, retainedResource: disk) else {
                continuation.resume(returning: false)
                return
            }
            guard let context = UnsafeMutableRawPointer(bitPattern: token) else {
                Self.diskCallbacks.complete(token, result: false)
                return
            }
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { _, dissenter, context in
                guard let context else { return }
                LiveWritableMountSystem.diskCallbacks.complete(UInt(bitPattern: context), result: dissenter == nil)
            }, context)
            Self.scheduleDiskCallbackTimeout(token)
        }
    }

    private static func scheduleDiskCallbackTimeout(_ token: UInt) {
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: diskCallbackTimeout)
            diskCallbacks.timeout(token)
        }
    }

    func pathExists(_ path: String) async -> Bool {
        var info = stat()
        // Anything other than a definite "does not exist" counts as occupied.
        return lstat(path, &info) == 0 || errno != ENOENT
    }

    func startDriver(bsdName bsd: String, expectedRegistryEntryID: UInt64, mountPoint: String) async -> Int32? {
        let driver = helpersDirectory.appendingPathComponent("ntfs-3g")
        guard Self.satisfiesPinnedSignature(driver, identifier: Self.driverIdentifier),
              let bound = boundDADisk(
                  bsdName: bsd, expectedRegistryEntryID: expectedRegistryEntryID, isWholeDisk: false
              )
        else { return nil }
        let pid = withExtendedLifetime(bound) {
            Self.spawn(driver.path, ["ntfs-3g", "/dev/" + bsd, mountPoint, "-o", Self.driverOptions],
                       newSession: true)
        }
        guard let pid else { return nil }
        DriverRegistry.shared.adopt(pid: pid, mountPoint: mountPoint)
        return pid
    }

    // MARK: Mount verification

    func mountEntry(at mountPoint: String) async -> HelperMountEntry? {
        guard var info = Self.statfsEntry(mountPoint: mountPoint) else { return nil }
        var flags: Set<String> = [Self.string(&info.f_fstypename)]
        let pairs: [(Int32, String)] = [(MNT_RDONLY, "read-only"), (MNT_LOCAL, "local"),
                                        (MNT_NODEV, "nodev"), (MNT_NOSUID, "nosuid")]
        for (bit, name) in pairs where info.f_flags & UInt32(bit) != 0 { flags.insert(name) }
        if info.f_flags_ext & UInt32(MNT_EXT_FSKIT) != 0 { flags.insert("fskit") }
        return HelperMountEntry(source: Self.string(&info.f_mntfromname), mountPoint: mountPoint, flags: flags)
    }

    func isFSKitPlaceholder(source: String) async -> Bool {
        guard source.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil,
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, String(source.dropFirst(5))),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return false }
        return description[kDADiskDescriptionMediaWholeKey as String] as? Bool == true
            // Disk Arbitration reports the FSKit placeholder as a virtual interface (diskutil: "Disk Image").
            && description[kDADiskDescriptionDeviceProtocolKey as String] as? String == "Virtual Interface"
            && (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value == 4096
    }

    func driverState(pid: Int32) async -> HelperDriverState {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != UInt32(SZOMB),
              info.pbi_ruid == info.pbi_uid, info.pbi_rgid == info.pbi_gid
        else { return HelperDriverState(isAlive: false, uid: nil, gid: nil) }
        return HelperDriverState(isAlive: true, uid: info.pbi_uid, gid: info.pbi_gid)
    }

    func driverHolds(pid: Int32, devicePath: String) async -> Bool {
        strictDriverHolds(pid: pid, devicePath: devicePath) == true
    }

    private func strictDriverHolds(pid: Int32, devicePath: String) -> Bool? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 64
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let capacity = Int32(count * MemoryLayout<proc_fdinfo>.stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, capacity)
        guard filled > 0, filled < capacity,
              Int(filled) % MemoryLayout<proc_fdinfo>.stride == 0
        else { return nil }
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnode = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size else {
                return nil
            }
            let path = withUnsafePointer(to: &vnode.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if path == devicePath { return true }
        }
        return false
    }

    func isWritable(mountPoint: String) async -> Bool {
        await runAsMountUser(.writable, mountPoint: mountPoint)?.status == 0
    }

    func pause() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    // MARK: Support

    /// Runs one fixed operation in a child copy of this helper that permanently drops to the
    /// mount user first (FSKit mounts refuse root). Returns the exit status and bounded stdout.
    func runAsMountUser(
        _ operation: MountUserOperation, mountPoint: String,
        timeout: Duration = .seconds(60)
    ) async -> (status: Int32, output: String)? {
        guard MountUserAgent.isAcceptedMountPoint(mountPoint) else { return nil }
        var pipeDescriptors: [Int32] = [0, 0]
        guard pipe(&pipeDescriptors) == 0 else { return nil }
        let pid = Self.spawn(executablePath, ["NTFSLiteHelper", MountUserAgent.flag, operation.rawValue, mountPoint],
                             newSession: false, standardOutput: pipeDescriptors[1])
        close(pipeDescriptors[1])
        guard let pid else {
            close(pipeDescriptors[0])
            return nil
        }
        switch await BoundedHelperChildIO.run(
            pid: pid, outputFD: pipeDescriptors[0], timeout: timeout, maximumOutputBytes: 4096
        ) {
        case let .completed(exitStatus, output):
            guard let text = String(data: output, encoding: .utf8) else { return nil }
            return (exitStatus, text)
        case .timedOutReaped, .ioFailedReaped, .terminationUnconfirmed:
            return nil
        }
    }

    static func statfsEntry(mountPoint: String) -> statfs? {
        func sample() -> statfs? {
            let count = getfsstat(nil, 0, MNT_NOWAIT)
            guard count > 0 else { return nil }
            let capacity = Int(count) + 8
            guard capacity < Int(Int32.max) / MemoryLayout<statfs>.stride else { return nil }
            var entries = [FileSystemStatus](repeating: FileSystemStatus(), count: capacity)
            let filled = getfsstat(&entries, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
            let after = getfsstat(nil, 0, MNT_NOWAIT)
            guard HelperMountTableSnapshotPolicy.isComplete(
                initialCount: Int(count), copiedCount: Int(filled),
                countAfterRead: Int(after), capacity: capacity
            ) else { return nil }
            let matches = entries.prefix(Int(filled)).filter { entry in
                var entry = entry
                return string(&entry.f_mntonname) == mountPoint
            }
            return matches.count == 1 ? matches[0] : nil
        }
        guard var first = sample(), var second = sample(),
              string(&first.f_mntfromname) == string(&second.f_mntfromname),
              string(&first.f_mntonname) == string(&second.f_mntonname),
              string(&first.f_fstypename) == string(&second.f_fstypename),
              first.f_fsid.val.0 == second.f_fsid.val.0,
              first.f_fsid.val.1 == second.f_fsid.val.1,
              first.f_flags == second.f_flags,
              first.f_flags_ext == second.f_flags_ext
        else { return nil }
        return second
    }

    static func string<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }

    static func satisfiesPinnedSignature(_ url: URL, identifier: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(HelperServiceIdentity.teamIdentifier)\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    /// Fixed executable and argument vector only; stdio goes to /dev/null.
    static func spawn(_ path: String, _ arguments: [String], newSession: Bool, standardOutput: Int32? = nil) -> Int32? {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        var flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        if newSession { flags |= Int16(POSIX_SPAWN_SETSID) }
        posix_spawnattr_setflags(&attributes, flags)
        for descriptor: Int32 in 0...2 {
            if descriptor == 1, let standardOutput {
                posix_spawn_file_actions_adddup2(&actions, standardOutput, 1)
            } else {
                posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
            }
        }
        var pid: pid_t = 0
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environment: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { environment.forEach { free($0) } }
        guard posix_spawn(&pid, path, &actions, &attributes, argv, environment) == 0 else { return nil }
        return pid
    }
}

/// Reaps drivers started by this helper so they never linger as zombies, and remembers the
/// mount point each one serves for the standard unmount path.
final class DriverRegistry: @unchecked Sendable {
    static let shared = DriverRegistry()
    private let lock = NSLock()
    private var mountPoints: [Int32: String] = [:]

    func adopt(pid: Int32, mountPoint: String) {
        lock.withLock { mountPoints[pid] = mountPoint }
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            lock.withLock { _ = mountPoints.removeValue(forKey: pid) }
        }
    }

    func driver(servingMountPoint mountPoint: String) -> Int32? {
        lock.withLock { mountPoints.first { $0.value == mountPoint }?.key }
    }
}

extension LiveWritableMountSystem: DiskReleaseSystem {
    func partitions(ofDisk bsd: String) async -> [String]? {
        guard bsd.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev")
        else { return nil }
        return names.filter { $0.range(of: "^\(bsd)s[0-9]+$", options: .regularExpression) != nil }.sorted()
    }

    func ownedFSKitMounts(devicePath: String) async -> [HelperOwnedMount]? {
        let driverPath = helpersDirectory.appendingPathComponent("ntfs-3g").resolvingSymlinksInPath().path
        guard let pids = Self.stableProcessIDs() else { print("[D-LITE] processInventoryUnsettled"); return nil }
        var owned: [HelperOwnedMount] = []
        for pid in pids {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
            if pathLength <= 0 {
                print("[D-LITE] unreadableProcess pid=\(pid) pathErrno=\(errno)")
                let status = kill(pid, 0)
                let code = errno
                guard status != 0, HelperProcessInspectionPolicy.mayIgnoreUnreadableProcess(errno: code) else {
                    return nil
                }
                continue
            }
            guard pathLength < path.count else { return nil }
            let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !executable.isEmpty else { return nil }
            guard (executable as NSString).lastPathComponent == "ntfs-3g" else { continue }
            guard let holds = strictDriverHolds(pid: pid, devicePath: devicePath) else { return nil }
            if !holds {
                // A pinned driver aimed at this partition may be between
                // process creation and opening the device. Do not certify
                // the partition as mount-free in that interval.
                if executable == driverPath {
                    guard let arguments = Self.arguments(of: pid), arguments.count == 5 else { return nil }
                    if arguments[1] == devicePath { return nil }
                }
                continue
            }
            // An NTFS-3G process holding the device that is not our recognizable mount makes the
            // state unknown: never report the partition as released.
            guard executable == driverPath,
                  let arguments = Self.arguments(of: pid), arguments.count == 5,
                  arguments[1] == devicePath, arguments[3] == "-o", arguments[4] == Self.driverOptions,
                  let entry = await mountEntry(at: arguments[2]),
                  entry.flags.isSuperset(of: ["macfuse", "fskit"])
            else { return nil }
            owned.append(HelperOwnedMount(mountPoint: arguments[2], driverPID: pid))
        }
        return owned
    }

    func unmountFileSystem(mountPoint: String) async -> Bool {
        // Standard unmount only (no MNT_FORCE), as the user who owns the FSKit mount.
        await runAsMountUser(.unmount, mountPoint: mountPoint)?.status == 0
    }

    func waitForDriverExit(pid: Int32) async -> Bool {
        for _ in 0..<120 {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            if await !driverState(pid: pid).isAlive { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    func removeEmptyMountPoint(_ path: String) async -> Bool {
        guard MountUserAgent.isAcceptedMountPoint(path) else { return false }
        var info = stat()
        if lstat(path, &info) != 0 { return errno == ENOENT }
        return info.st_mode & S_IFMT == S_IFDIR && rmdir(path) == 0
    }

    func unmountNativeVolume(bsdName: String, expectedRegistryEntryID: UInt64) async -> Bool {
        await unmountNative(bsdName: bsdName, expectedRegistryEntryID: expectedRegistryEntryID)
    }

    func eject(diskBSDName: String, expectedRegistryEntryID: UInt64) async -> Bool {
        guard let disk = boundDADisk(
            bsdName: diskBSDName, expectedRegistryEntryID: expectedRegistryEntryID, isWholeDisk: true
        ) else { return false }
        return await withCheckedContinuation { continuation in
            guard let token = Self.diskCallbacks.register(continuation, retainedResource: disk) else {
                continuation.resume(returning: false)
                return
            }
            guard let context = UnsafeMutableRawPointer(bitPattern: token) else {
                Self.diskCallbacks.complete(token, result: false)
                return
            }
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, context in
                guard let context else { return }
                LiveWritableMountSystem.diskCallbacks.complete(UInt(bitPattern: context), result: dissenter == nil)
            }, context)
            Self.scheduleDiskCallbackTimeout(token)
        }
    }

    func orphanedMounts(diskBSDName disk: String) async -> [HelperOwnedMount]? {
        guard disk.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        let driverPath = helpersDirectory.appendingPathComponent("ntfs-3g").resolvingSymlinksInPath().path
        guard let pids = Self.stableProcessIDs() else { print("[D-LITE] processInventoryUnsettled"); return nil }
        var orphans: [HelperOwnedMount] = []
        for pid in pids {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
            if pathLength <= 0 {
                print("[D-LITE] unreadableProcess pid=\(pid) pathErrno=\(errno)")
                let status = kill(pid, 0)
                let code = errno
                guard status != 0, HelperProcessInspectionPolicy.mayIgnoreUnreadableProcess(errno: code) else {
                    return nil
                }
                continue
            }
            guard pathLength < path.count else { return nil }
            let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !executable.isEmpty else { return nil }
            guard executable == driverPath else { continue }
            guard let arguments = Self.arguments(of: pid), arguments.count == 5,
                  arguments[1].range(of: #"^/dev/disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil,
                  arguments[3] == "-o", arguments[4] == Self.driverOptions
            else { return nil }
            guard arguments[1].range(of: "^/dev/\(disk)s[0-9]+$", options: .regularExpression) != nil else {
                continue
            }
            var info = stat()
            guard lstat(arguments[1], &info) != 0, errno == ENOENT,
                  let entry = await mountEntry(at: arguments[2]), entry.flags.isSuperset(of: ["macfuse", "fskit"])
            else { return nil }
            orphans.append(HelperOwnedMount(mountPoint: arguments[2], driverPID: pid))
        }
        return orphans
    }

    func diskIsPresent(bsdName: String, registryEntryID: UInt64) async -> Bool? {
        guard bsdName.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              registryEntryID > 0
        else { return nil }
        var info = stat()
        if lstat("/dev/" + bsdName, &info) == 0 { return true }
        guard errno == ENOENT,
              let inventory = try? SystemIOMediaEnumerationReader().currentSnapshot(),
              let registryIDs = Self.stableIOMediaEntryIDs()
        else { return nil }
        return HelperDiskPresencePolicy.isPresent(
            deviceNodeExists: false,
            bsdNameInRegistry: inventory.bsdNames.contains(bsdName),
            requestedEntryInRegistry: registryIDs.contains(registryEntryID),
            diskArbitrationHasDisk: DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) != nil
        )
    }

    private static func stableIOMediaEntryIDs() -> Set<UInt64>? {
        guard let first = ioMediaEntryIDs(), let second = ioMediaEntryIDs(), first == second else { return nil }
        return first
    }

    private static func ioMediaEntryIDs() -> Set<UInt64>? {
        guard let matching = IOServiceMatching("IOMedia") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var entryIDs: Set<UInt64> = []
        while true {
            let media = IOIteratorNext(iterator)
            guard media != 0 else { break }
            defer { IOObjectRelease(media) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(media, &entryID) == KERN_SUCCESS,
                  entryID > 0, entryIDs.insert(entryID).inserted
            else { return nil }
        }
        guard IOIteratorIsValid(iterator) != 0, !entryIDs.isEmpty else { return nil }
        return entryIDs
    }

    private static func stableProcessIDs() -> [pid_t]? {
        HelperProcessInventorySettlement.settled {
            let estimate = proc_listallpids(nil, 0)
            guard estimate > 0, estimate < 1_000_000 else { return nil }
            let capacity = Int(estimate) + 64
            var pids = [pid_t](repeating: 0, count: capacity)
            let returned = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
            guard returned > 0 else { return nil }
            print("[D-LITE] processSample count=\(returned) capacity=\(capacity)")
            return HelperProcessInventorySample(
                reportedCount: Int(returned), capacity: capacity, processIDs: pids
            )
        }
    }

    /// argv of a process via KERN_PROCARGS2 (argc followed by exec path and arguments).
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }   // exec path
        while index < size && buffer[index] == 0 { index += 1 }   // padding
        var arguments: [String] = []
        while arguments.count < argc && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == Int(argc) ? arguments : nil
    }
}
