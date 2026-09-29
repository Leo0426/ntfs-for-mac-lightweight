import Darwin
import Foundation
import NTFSLiteHelperProtocol

/// Owns the read descriptor and child reaping. Every read is nonblocking and
/// stdout EOF and process exit share one monotonic deadline.
public enum HelperChildProcessOutcome: Equatable, Sendable {
    case completed(exitStatus: Int32, output: Data)
    case timedOutReaped
    case ioFailedReaped
    case terminationUnconfirmed
}

public enum BoundedHelperChildIO {
    public static func run(
        pid: pid_t, outputFD: Int32?, timeout: Duration,
        maximumOutputBytes: Int, terminationGrace: Duration = .seconds(1),
        killGrace: Duration = .seconds(2)
    ) async -> HelperChildProcessOutcome {
        defer { if let outputFD { close(outputFD) } }
        guard pid > 0, maximumOutputBytes >= 0 else { return unconfirmedTermination() }
        if let outputFD {
            let flags = fcntl(outputFD, F_GETFL)
            guard flags >= 0, fcntl(outputFD, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                return await failureAfterReaping(pid: pid, reason: .ioFailedReaped,
                                                 outputFD: nil, requireStreamProof: true,
                                                 terminationGrace: terminationGrace, killGrace: killGrace)
            }
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        var output = Data()
        var reachedEOF = outputFD == nil
        var reapedStatus: Int32?
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            if let outputFD, !reachedEOF {
                while true {
                    let count = read(outputFD, &buffer, buffer.count)
                    if count > 0 {
                        guard count <= maximumOutputBytes - output.count else {
                            return await failureAfterReaping(
                                pid: pid, alreadyReaped: reapedStatus != nil, reason: .ioFailedReaped,
                                outputFD: outputFD,
                                terminationGrace: terminationGrace, killGrace: killGrace
                            )
                        }
                        output.append(contentsOf: buffer.prefix(count))
                        continue
                    }
                    if count == 0 { reachedEOF = true; break }
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    return await failureAfterReaping(
                        pid: pid, alreadyReaped: reapedStatus != nil, reason: .ioFailedReaped,
                        outputFD: outputFD,
                        terminationGrace: terminationGrace, killGrace: killGrace
                    )
                }
            }
            if reapedStatus == nil {
                switch probeExit(pid: pid) {
                case let .reaped(status): reapedStatus = status
                case .running: break
                case .unknown: return unconfirmedTermination()
                }
            }
            if ContinuousClock.now >= deadline {
                return await failureAfterReaping(
                    pid: pid, alreadyReaped: reapedStatus != nil, reason: .timedOutReaped,
                    outputFD: outputFD,
                    terminationGrace: terminationGrace, killGrace: killGrace
                )
            }
            if let reapedStatus, reachedEOF {
                guard reapedStatus & 0x7f == 0 else { return .ioFailedReaped }
                return .completed(exitStatus: (reapedStatus >> 8) & 0xff, output: output)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private enum ExitProbe {
        case running
        case reaped(Int32)
        case unknown
    }

    private static func probeExit(pid: pid_t) -> ExitProbe {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return .reaped(status) }
        if result == 0 || (result < 0 && errno == EINTR) { return .running }
        return .unknown
    }

    private static func failureAfterReaping(
        pid: pid_t, alreadyReaped: Bool = false, reason: HelperChildProcessOutcome,
        outputFD: Int32?, requireStreamProof: Bool = false,
        terminationGrace: Duration, killGrace: Duration
    ) async -> HelperChildProcessOutcome {
        if !alreadyReaped {
            _ = kill(pid, SIGTERM)
            if await !waitForReap(pid: pid, grace: terminationGrace) {
                _ = kill(pid, SIGKILL)
                guard await waitForReap(pid: pid, grace: killGrace) else {
                    return unconfirmedTermination()
                }
            }
        }
        // A reaped parent is insufficient when another process still holds its
        // stdout pipe and may continue the operation. Demand an explicit EOF.
        if requireStreamProof { return unconfirmedTermination() }
        if let outputFD, !drainToEOF(outputFD) { return unconfirmedTermination() }
        return reason
    }

    private static func drainToEOF(_ fd: Int32) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 512)
        for _ in 0..<256 {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return true }
            if count > 0 { continue }
            if errno == EINTR { continue }
            return false
        }
        return false
    }

    private static func unconfirmedTermination() -> HelperChildProcessOutcome {
        HelperProcessUncertainty.processLifetime.markUnknown()
        return .terminationUnconfirmed
    }

    private static func waitForReap(pid: pid_t, grace: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: grace)
        while true {
            switch probeExit(pid: pid) {
            case .reaped: return true
            case .unknown: return false
            case .running:
                if ContinuousClock.now >= deadline { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
}
