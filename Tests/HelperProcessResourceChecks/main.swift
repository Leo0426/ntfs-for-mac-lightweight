import Darwin
import Foundation

func check(_ value: Bool, _ message: String) {
    guard value else { fatalError(message) }
}
check(HelperProcessResourceReader.confirmedNoDeviceHandles(pid: -1) == nil,
      "invalid process identity cannot recover an unavailable path")
if CommandLine.arguments.contains("--exit-regression") {
    let done = DispatchSemaphore(value: 0)
    Task {
        let system = LiveWritableMountSystem()!
        check(await system.waitForDriverExit(pid: 0) == false,
              "invalid PID / incomplete process facts must never confirm driver exit")
        done.signal()
    }
    check(done.wait(timeout: .now() + 35) == .success, "exit test must finish")
    print("PASS: unknown driver exit remains closed")
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--inspect-target"),
   CommandLine.arguments.count > index + 1,
   let target = Int32(CommandLine.arguments[index + 1]) {
    check(HelperProcessResourceReader.confirmedNoDeviceHandles(pid: target) == true,
          "live target resource evidence remains unverified")
    print("PASS: live target has complete stable non-storage resources")
    exit(0)
}
let pid = getpid()
check(HelperProcessResourceReader.confirmedNoDeviceHandles(pid: pid) == true,
      "complete stable pipe/regular/null descriptors must provide current non-device evidence")
let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
check(null >= 0, "null fixture must open")
check(HelperProcessResourceReader.confirmedNoDeviceHandles(pid: pid) == true,
      "independently identified null descriptor must remain supported")
close(null)
let zero = open("/dev/zero", O_RDONLY | O_CLOEXEC)
check(zero >= 0, "character-device fixture must open")
check(HelperProcessResourceReader.confirmedNoDeviceHandles(pid: pid) == nil,
      "a live process holding another character device must block fallback")
close(zero)
check(HelperProcessResourceReader.confirmedNoDeviceHandles(pid: pid) == true,
      "after closing the character device a new current sample may recover; no failed/positive cache")
print("PASS: native process resource inspection distinguishes stable harmless descriptors from device handles")

let terminal = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)
check(terminal >= 0, "own PTY fixture must open")
check(HelperProcessResourceReader.confirmedNoDeviceHandles(pid: pid) == true,
      "kernel-bound PTMX clone must not be mistaken for a storage device")
close(terminal)
print("PASS: independently bound PTMX master is non-storage")

// Only the exact current devfs node and dynamic PTMX major may classify a clone.
var nodeStat = stat()
check(lstat("/dev/ptmx", &nodeStat) == 0, "current PTMX node must exist")
var fileSystem = statfs()
check(statfs("/dev/ptmx", &fileSystem) == 0, "devfs metadata must be complete")
let ownedTerminal = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)
check(ownedTerminal >= 0, "second own terminal fixture must open")
var full = vnode_fdinfowithpath()
let fullSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
check(proc_pidfdinfo(pid, ownedTerminal, PROC_PIDFDVNODEPATHINFO, &full, fullSize) == fullSize,
      "PTY fixture requires complete native vnode metadata")
var nativeMaximum: Int32 = 0
var nativeMaximumSize = MemoryLayout<Int32>.size
check(sysctlbyname("kern.tty.ptmx_max", &nativeMaximum, &nativeMaximumSize, nil, 0) == 0
      && nativeMaximumSize == MemoryLayout<Int32>.size && nativeMaximum > 0,
      "native clone limit must be complete")
let node = HelperProcessResourceReader.PTMXNode(
    device: UInt32(bitPattern: nodeStat.st_dev), inode: nodeStat.st_ino,
    mode: nodeStat.st_mode, rawDevice: UInt32(bitPattern: nodeStat.st_rdev),
    owner: nodeStat.st_uid, group: nodeStat.st_gid, links: nodeStat.st_nlink,
    fsid0: fileSystem.f_fsid.val.0, fsid1: fileSystem.f_fsid.val.1, maximum: nativeMaximum)
check(HelperProcessResourceReader.isPTMX(vnode: full.pvip.vip_vi, path: "/dev/ptmx", node: node),
      "complete native clone metadata must match the current node")
for path in [nil, "", "/dev/zero", "/dev/ptmx/", "/private/dev/ptmx"] as [String?] {
    check(!HelperProcessResourceReader.isPTMX(vnode: full.pvip.vip_vi, path: path, node: node),
          "unknown or other vnode path must remain unverified")
}
var wrong = full.pvip.vip_vi
wrong.vi_stat.vst_mode = UInt16(S_IFBLK | 0o666)
check(!HelperProcessResourceReader.isPTMX(vnode: wrong, path: "/dev/ptmx", node: node),
      "block device must never be classified as PTMX")
wrong = full.pvip.vip_vi
wrong.vi_stat.vst_rdev ^= 0x0100_0000
check(!HelperProcessResourceReader.isPTMX(vnode: wrong, path: "/dev/ptmx", node: node),
      "different dynamic major must remain unverified")
wrong = full.pvip.vip_vi
wrong.vi_stat.vst_ino += 1
check(!HelperProcessResourceReader.isPTMX(vnode: wrong, path: "/dev/ptmx", node: node),
      "another vnode with the PTMX major must remain unverified")
wrong = full.pvip.vip_vi
wrong.vi_fsid.val.0 ^= 1
check(!HelperProcessResourceReader.isPTMX(vnode: wrong, path: "/dev/ptmx", node: node),
      "another filesystem must remain unverified")
wrong = full.pvip.vip_vi
wrong.vi_type = 0
check(!HelperProcessResourceReader.isPTMX(vnode: wrong, path: "/dev/ptmx", node: node),
      "unknown kernel vnode type must remain unverified")
let pathBytes = Array("/dev/ptmx".utf8)
check(HelperProcessResourceReader.completePath(pathBytes) == nil,
      "truncated path without NUL must fail closed")
check(HelperProcessResourceReader.completePath(pathBytes + [0]) == nil,
      "path ending at buffer boundary cannot establish absence of truncation")
check(HelperProcessResourceReader.completePath(pathBytes + [0, 0]) == "/dev/ptmx",
      "bounded complete path must decode")
close(ownedTerminal)
var nullStat = stat()
check(lstat("/dev/null", &nullStat) == 0, "null reference exists")
let nullNumber = UInt32(bitPattern: nullStat.st_rdev)
let before = HelperProcessResourceReader.sample(pid: pid, nullDevice: nullNumber, ptmx: nil)
check(before != nil, "stable descriptor fixture must be complete")
let extra = open("/dev/null", O_RDONLY | O_CLOEXEC)
check(extra >= 0, "changing descriptor fixture opens")
let changed = HelperProcessResourceReader.sample(pid: pid, nullDevice: nullNumber, ptmx: nil)
check(changed != nil, "changed snapshot is independently complete")
check(HelperProcessResourceReader.confirmsStableAbsence(before, changed) == nil,
      "two individually complete but changing descriptor snapshots must fail closed")
check(HelperProcessResourceReader.confirmsStableAbsence(before, nil) == nil,
      "missing or truncated second snapshot must fail closed")
close(extra)
print("PASS: PTMX block/unknown/path/metadata and changing/incomplete snapshots remain closed")

if let before {
    let old = before.identity
    let changedIdentity = HelperProcessResourceReader.Identity(
        pid: old.pid, startedSeconds: old.startedSeconds + 1,
        startedMicroseconds: old.startedMicroseconds, imageUUID: old.imageUUID,
        imageStarted: old.imageStarted, arguments: old.arguments)
    let replaced = HelperProcessResourceReader.Sample(identity: changedIdentity, descriptors: before.descriptors)
    check(HelperProcessResourceReader.confirmsStableAbsence(before, replaced) == nil,
          "matching descriptors under a changed process lifecycle cannot prove stable absence")
}
print("PASS: changing process identity remains closed")
