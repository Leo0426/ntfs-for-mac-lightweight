import Darwin
import Foundation

/// Fixed probe children are never signalled on timeout. The caller keeps their PIDs and
/// qualification until an actual waitpid result; cancellation cannot skip that observation.
public enum RuntimeProbeChildWaiter {
    public static func wait(pid: Int32, pollLimit: Int = 120) async -> RuntimeProbeDriver {
        precondition(pollLimit > 0)
        for _ in 0..<pollLimit {
            let result = reap(pid)
            if result != .running { return result }
            await Task.detached { try? await Task.sleep(for: .milliseconds(250)) }.value
        }
        return .running
    }
    public static func reap(_ pid: Int32) -> RuntimeProbeDriver {
        var status: Int32 = 0
        var result: Int32
        repeat { result = waitpid(pid, &status, WNOHANG) } while result < 0 && errno == EINTR
        if result == 0 { return .running }
        guard result == pid else { return .unknown }
        return .reaped(success: status & 0x7f == 0 && (status >> 8) & 0xff == 0)
    }
}
