import Darwin
import Foundation
import NTFSLiteHelperExecution

/// Recovers a missing executable path by proving current storage-handle absence,
/// not by trusting a process name or a launch path. Never used for permission errors.
enum HelperProcessResourceReader {
    struct Identity: Equatable {
        let pid: UInt32
        let startedSeconds: UInt64
        let startedMicroseconds: UInt64
        let imageUUID: [UInt8]
        let imageStarted: UInt64
        let arguments: HelperKernelArguments
    }
    struct Descriptor: Equatable {
        let number: Int32
        let kind: UInt32
        let device: UInt32
        let inode: UInt64
        let mode: UInt16
        let rawDevice: UInt32
        var path: String? = nil
        var owner: UInt32 = 0
        var group: UInt32 = 0
        var links: UInt16 = 0
    }
    struct Sample: Equatable {
        let identity: Identity
        let descriptors: [Descriptor]
    }

    struct PTMXNode: Equatable {
        let device: UInt32
        let inode: UInt64
        let mode: UInt16
        let rawDevice: UInt32
        let owner: UInt32
        let group: UInt32
        let links: UInt16
        let fsid0: Int32
        let fsid1: Int32
        let maximum: Int32
    }

    /// XNU tty_ptmx.c registers a dynamic character major and a devfs clone node.
    /// Every master clone retains that node's inode/path; only its minor differs.
    /// No existing PTY is opened or touched to obtain this proof.
    static func isPTMX(vnode: vnode_info, path: String?, node: PTMXNode) -> Bool {
        let v = vnode.vi_stat
        return path == "/dev/ptmx" && vnode.vi_type == 4 // VCHR
            && v.vst_mode == node.mode && node.mode == UInt16(S_IFCHR | 0o666)
            && v.vst_dev == node.device && v.vst_ino == node.inode && node.inode > 0
            && v.vst_uid == node.owner && node.owner == 0
            && v.vst_gid == node.group && node.group == 4 // XNU GID_TTY
            && v.vst_nlink == node.links && node.links == 1
            && vnode.vi_fsid.val.0 == node.fsid0 && vnode.vi_fsid.val.1 == node.fsid1
            && (v.vst_rdev >> 24) == (node.rawDevice >> 24)
            && (node.rawDevice >> 24) > 0 && node.maximum > 0
            && (v.vst_rdev & 0x00ff_ffff) < UInt32(node.maximum)
    }

    static func completePath(_ bytes: [UInt8]) -> String? {
        guard let end = bytes.firstIndex(of: 0), end < bytes.count - 1,
              let value = String(bytes: bytes[..<end], encoding: .utf8),
              value == "/dev/ptmx" else { return nil }
        return value
    }

    private static func ptmxNode() -> PTMXNode? {
        var info = stat()
        var fs = statfs()
        var maximum: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard lstat("/dev/ptmx", &info) == 0,
              statfs("/dev/ptmx", &fs) == 0,
              withUnsafeBytes(of: fs.f_fstypename, { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }) == "devfs",
              sysctlbyname("kern.tty.ptmx_max", &maximum, &length, nil, 0) == 0,
              length == MemoryLayout<Int32>.size, maximum > 0 else { return nil }
        return PTMXNode(device: UInt32(bitPattern: info.st_dev), inode: info.st_ino,
                        mode: info.st_mode, rawDevice: UInt32(bitPattern: info.st_rdev),
                        owner: info.st_uid, group: info.st_gid, links: info.st_nlink,
                        fsid0: fs.f_fsid.val.0, fsid1: fs.f_fsid.val.1, maximum: maximum)
    }

    static func confirmedNoDeviceHandles(pid: pid_t) -> Bool? {
        var null = stat()
        guard lstat("/dev/null", &null) == 0,
              null.st_mode & S_IFMT == S_IFCHR else { return nil }
        let nullDevice = UInt32(bitPattern: null.st_rdev)
        // PTMX evidence is optional for processes without PTMX descriptors.
        let ptmx = ptmxNode()
        guard let first = sample(pid: pid, nullDevice: nullDevice, ptmx: ptmx),
              let second = sample(pid: pid, nullDevice: nullDevice, ptmx: ptmx),
              confirmsStableAbsence(first, second) == true,
              ptmxNode() == ptmx else { return nil }
        var nullAfter = stat()
        guard lstat("/dev/null", &nullAfter) == 0,
              nullAfter.st_dev == null.st_dev, nullAfter.st_ino == null.st_ino,
              nullAfter.st_mode == null.st_mode, nullAfter.st_rdev == null.st_rdev else { return nil }
        return true
    }

    static func confirmsStableAbsence(_ first: Sample?, _ second: Sample?) -> Bool? {
        guard let first, let second, first == second else { return nil }
        return true
    }

    private static func identity(pid: pid_t) -> Identity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid),
              [UInt32(SIDL), UInt32(SRUN), UInt32(SSLEEP), UInt32(SSTOP)].contains(info.pbi_status),
              info.pbi_start_tvsec > 0,
              let args = kernelArguments(pid: pid),
              let image = executableIdentity(pid: pid),
              !([args.executablePath] + args.arguments).contains(where: { $0.contains("ntfs-3g") || $0.contains("/dev/disk") || $0.contains("/dev/rdisk") })
        else { return nil }
        return Identity(pid: info.pbi_pid, startedSeconds: info.pbi_start_tvsec,
                        startedMicroseconds: info.pbi_start_tvusec, imageUUID: image.0,
                        imageStarted: image.1, arguments: args)
    }

    private static func kernelArguments(pid: pid_t) -> HelperKernelArguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= 1_048_576 else { return nil }
        let capacity = size
        var bytes = [UInt8](repeating: 0, count: capacity)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= capacity else { return nil }
        return HelperKernelArguments.decode(Array(bytes.prefix(size)))
    }

    private static func executableIdentity(pid: pid_t) -> ([UInt8], UInt64)? {
        var usage = rusage_info_v0()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
            }
        }
        guard status == 0, usage.ri_proc_start_abstime > 0 else { return nil }
        let uuid = withUnsafeBytes(of: usage.ri_uuid) { Array($0) }
        guard uuid.contains(where: { $0 != 0 }) else { return nil }
        return (uuid, usage.ri_proc_start_abstime)
    }

    static func sample(pid: pid_t, nullDevice: UInt32, ptmx: PTMXNode?) -> Sample? {
        guard let before = identity(pid: pid) else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let estimate = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimate > 0, estimate < 4_000_000, Int(estimate) % stride == 0 else { return nil }
        let count = Int(estimate) / stride + 64
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let capacity = Int32(count * stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, capacity)
        guard filled > 0, filled < capacity, Int(filled) % stride == 0 else { return nil }
        let nonVnodeTypes: Set<UInt32> = [
            UInt32(PROX_FDTYPE_SOCKET), UInt32(PROX_FDTYPE_PSHM), UInt32(PROX_FDTYPE_PSEM),
            UInt32(PROX_FDTYPE_KQUEUE), UInt32(PROX_FDTYPE_PIPE), UInt32(PROX_FDTYPE_FSEVENTS),
            UInt32(PROX_FDTYPE_NETPOLICY), UInt32(PROX_FDTYPE_CHANNEL), UInt32(PROX_FDTYPE_NEXUS)
        ]
        var descriptors: [Descriptor] = []
        var numbers: Set<Int32> = []
        for fd in fds.prefix(Int(filled) / stride) {
            guard fd.proc_fd >= 0, numbers.insert(fd.proc_fd).inserted else { return nil }
            if fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var vnode = vnode_fdinfo()
                let size = Int32(MemoryLayout<vnode_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEINFO, &vnode, size) == size else { return nil }
                let v = vnode.pvi.vi_stat
                var descriptor = Descriptor(number: fd.proc_fd, kind: fd.proc_fdtype,
                    device: v.vst_dev, inode: v.vst_ino, mode: v.vst_mode, rawDevice: v.vst_rdev)
                if !HelperProcessInspectionPolicy.isNonDeviceVnode(
                    mode: v.vst_mode, device: v.vst_rdev, nullDevice: nullDevice
                ) {
                    guard let ptmx else { return nil }
                    var full = vnode_fdinfowithpath()
                    let fullSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                    guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &full, fullSize) == fullSize,
                          withUnsafeBytes(of: full.pvip.vip_vi.vi_stat, { Array($0) }) ==
                            withUnsafeBytes(of: v, { Array($0) }),
                          let path = completePath(withUnsafeBytes(of: full.pvip.vip_path) { Array($0) }),
                          isPTMX(vnode: full.pvip.vip_vi, path: path, node: ptmx) else { return nil }
                    descriptor.path = path
                    descriptor.owner = v.vst_uid
                    descriptor.group = v.vst_gid
                    descriptor.links = v.vst_nlink
                }
                descriptors.append(descriptor)
            } else {
                guard nonVnodeTypes.contains(fd.proc_fdtype) else { return nil }
                descriptors.append(Descriptor(number: fd.proc_fd, kind: fd.proc_fdtype,
                    device: 0, inode: 0, mode: 0, rawDevice: 0))
            }
        }
        guard identity(pid: pid) == before else { return nil }
        return Sample(identity: before, descriptors: descriptors.sorted { $0.number < $1.number })
    }
}
