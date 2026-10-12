import Darwin
import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
let pid = getpid()
let size = Int32(MemoryLayout<proc_bsdinfo>.size)
var info = proc_bsdinfo()
check(proc_pidinfo(pid, PROC_PIDTBSDINFO, 1, &info, size) == size, "native live info is complete")
func interpreted(_ bytes: Int32, _ value: proc_bsdinfo, _ result: Int32 = 0,
                 _ code: Int32 = 0) -> HelperProcessExitFact {
    HelperProcessExitReader.interpret(pid: pid, signalResult: result, signalError: code,
                                     infoBytes: bytes, info: value)
}
check(HelperProcessExitReader.read(pid: pid) == .alive, "native live process remains alive")
check(HelperProcessExitReader.read(pid: 0) == .unknown, "zero is not a process identity")
check(interpreted(0, info) == .unknown, "failed procinfo is unknown")
check(interpreted(size - 1, info) == .unknown, "truncated procinfo is unknown")
check(interpreted(size, info, -1, EPERM) == .unknown, "permission failure is unknown")
check(interpreted(0, info, -1, ESRCH) == .exited, "only ESRCH independently proves absent")
var mismatched = info
mismatched.pbi_pid += 1
check(interpreted(size, mismatched) == .unknown, "mismatched PID is unknown")
mismatched = info
mismatched.pbi_uid ^= 1
mismatched.pbi_gid ^= 1
check(interpreted(size, mismatched) == .alive, "changed credentials do not establish exit")
var zombie = info
zombie.pbi_status = UInt32(SZOMB)
check(interpreted(size, zombie) == .exited, "complete exact zombie proves quiescence")
check(interpreted(size - 1, zombie) == .unknown, "partial zombie does not prove exit")
var unknown = info
unknown.pbi_status = UInt32.max
check(interpreted(size, unknown) == .unknown, "unknown process status fails closed")
// A child exits naturally; no signals are sent to any process.
var child: pid_t = 0
let childPath = strdup("/usr/bin/true")!
var args: [UnsafeMutablePointer<CChar>?] = [childPath, nil]
let spawned = posix_spawn(&child, childPath, nil, nil, &args, environ)
free(childPath)
check(spawned == 0 && child > 0, "isolated naturally terminating child fixture starts")
var observed: HelperProcessExitFact = .unknown
for _ in 0..<100 {
    observed = HelperProcessExitReader.read(pid: child)
    if observed == .exited { break }
    usleep(10_000)
}
check(observed == .exited, "native complete unreaped zombie is confirmed exited")
var status: Int32 = 0
check(waitpid(child, &status, 0) == child, "our exited child is reaped")
check(HelperProcessExitReader.read(pid: child) == .exited, "native ESRCH after reap confirms absence")
print("PASS: driver exit requires ESRCH or complete exact zombie; unknown/partial/credential mismatch remains closed")
