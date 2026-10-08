import Darwin
import Foundation

@main struct RuntimeProbeChildChecks {
    static func spawn(_ path: String, _ arguments: [String]) -> Int32 {
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv = strings + [nil]
        var pid: Int32 = 0
        precondition(posix_spawn(&pid, path, nil, nil, &argv, nil) == 0)
        return pid
    }
    static func main() async {
        let failed = spawn("/usr/bin/false", ["false"])
        guard await RuntimeProbeChildWaiter.wait(pid: failed) == .reaped(success: false) else {
            print("CHECK FAILED: known failed child must actually be reaped and reported failed"); exit(1)
        }
        let delayed = spawn("/bin/sleep", ["sleep", "1"])
        guard await RuntimeProbeChildWaiter.wait(pid: delayed, pollLimit: 1) == .running,
              kill(delayed, 0) == 0 else {
            print("CHECK FAILED: deadline must preserve a live child without signals"); exit(1)
        }
        guard await RuntimeProbeChildWaiter.wait(pid: delayed) == .reaped(success: true),
              RuntimeProbeChildWaiter.reap(delayed) == .unknown else {
            print("CHECK FAILED: only actual waitpid confirms completion; ECHILD is unknown"); exit(1)
        }
        print("PASS: runtime child wait owns real reaping and preserves timed-out children")
    }
}
