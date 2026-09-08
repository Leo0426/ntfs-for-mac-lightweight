import Darwin
import Foundation

package enum ReadOnlyCommandCompletion: Equatable, Sendable {
    case exited(Int32)
    case timedOut
    case outputLimitExceeded
    case outputUnreadable
    case terminationUnconfirmed
    case launchFailed
}

package struct ReadOnlyCommandResult: Equatable, Sendable {
    package let completion: ReadOnlyCommandCompletion
    package let standardOutput: String
    package let standardError: String

    package init(
        completion: ReadOnlyCommandCompletion,
        standardOutput: String,
        standardError: String
    ) {
        self.completion = completion
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

package struct BoundedReadOnlyCommandRunner: Sendable {
    package init() {}

    package func run(invocation: SetupProbeInvocation) async -> ReadOnlyCommandResult {
        let process = Process()
        let processController = ReadOnlyProcessController(process: process)
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputLimitTracker = OutputLimitTracker()

        guard Self.makeNonBlocking(outputPipe.fileHandleForReading),
              Self.makeNonBlocking(errorPipe.fileHandleForReading)
        else {
            return ReadOnlyCommandResult(
                completion: .outputUnreadable,
                standardOutput: "",
                standardError: ""
            )
        }

        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = [
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputTask = Task.detached {
            await Self.read(
                outputPipe.fileHandleForReading,
                maximumBytes: invocation.maximumOutputBytes,
                outputLimitTracker: outputLimitTracker
            )
        }
        let errorTask = Task.detached {
            await Self.read(
                errorPipe.fileHandleForReading,
                maximumBytes: invocation.maximumOutputBytes,
                outputLimitTracker: outputLimitTracker
            )
        }

        do {
            try process.run()
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            outputTask.cancel()
            errorTask.cancel()
            let output = await outputTask.value
            let error = await errorTask.value
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            return result(
                completion: .launchFailed,
                output: output,
                error: error
            )
        }
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        var processCompletion = await waitForProcessCompletion(
            controller: processController,
            outputLimitTracker: outputLimitTracker,
            timeout: invocation.timeout
        )

        switch processCompletion {
        case .timedOut, .outputLimitExceeded:
            let stopped = await stopAndConfirmExit(controller: processController)
            if !stopped {
                processCompletion = .terminationUnconfirmed
            }
        case .exited, .outputUnreadable, .terminationUnconfirmed, .launchFailed:
            break
        }

        if case .exited = processCompletion {
            // A direct child can exit while a descendant still owns a pipe.
            // Give buffered bytes a small fixed drain window, then close our
            // read ends rather than waiting for an untrusted EOF.
            try? await Task.sleep(for: .milliseconds(50))
        }

        outputTask.cancel()
        errorTask.cancel()
        let output = await outputTask.value
        let error = await errorTask.value
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()
        let finalCompletion: ReadOnlyCommandCompletion
        if processCompletion == .terminationUnconfirmed {
            finalCompletion = .terminationUnconfirmed
        } else if processCompletion == .timedOut {
            finalCompletion = .timedOut
        } else if outputLimitTracker.exceededLimit
                    || output.exceededLimit
                    || error.exceededLimit
        {
            finalCompletion = .outputLimitExceeded
        } else if output.readFailed
                    || error.readFailed
                    || !output.reachedEndOfFile
                    || !error.reachedEndOfFile
                    || String(data: output.data, encoding: .utf8) == nil
                    || String(data: error.data, encoding: .utf8) == nil
        {
            finalCompletion = .outputUnreadable
        } else {
            finalCompletion = processCompletion
        }

        return result(
            completion: finalCompletion,
            output: output,
            error: error
        )
    }

    private func waitForProcessCompletion(
        controller: ReadOnlyProcessController,
        outputLimitTracker: OutputLimitTracker,
        timeout: Duration
    ) async -> ReadOnlyCommandCompletion {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: max(timeout, .zero))

        while true {
            if outputLimitTracker.exceededLimit {
                return .outputLimitExceeded
            }
            if Task.isCancelled {
                return .timedOut
            }
            if let status = controller.statusIfExited() {
                return .exited(status)
            }
            if clock.now >= deadline {
                return .timedOut
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func stopAndConfirmExit(
        controller: ReadOnlyProcessController
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        controller.killIfRunning()

        while controller.statusIfExited() == nil {
            guard clock.now < deadline else {
                return false
            }
            controller.killIfRunning()
            await Task.detached {
                try? await Task.sleep(for: .milliseconds(5))
            }.value
        }
        return true
    }

    private static func read(
        _ fileHandle: FileHandle,
        maximumBytes: Int,
        outputLimitTracker: OutputLimitTracker
    ) async -> BoundedCommandData {
        let limit = max(0, maximumBytes)
        var data = Data()
        var exceededLimit = false
        var reachedEndOfFile = false
        let fileDescriptor = fileHandle.fileDescriptor
        var buffer = Data(count: 4_096)

        while !Task.isCancelled {
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if readCount > 0 {
                let remainingCapacity = max(0, limit - data.count)
                if readCount > remainingCapacity {
                    exceededLimit = true
                    outputLimitTracker.markExceeded()
                }
                if remainingCapacity > 0 {
                    data.append(buffer.prefix(min(readCount, remainingCapacity)))
                }
                if exceededLimit {
                    break
                }
                continue
            }
            if readCount == 0 {
                reachedEndOfFile = true
                break
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                try? await Task.sleep(for: .milliseconds(2))
                continue
            }
            return BoundedCommandData(
                data: data,
                exceededLimit: exceededLimit,
                readFailed: true,
                reachedEndOfFile: false
            )
        }

        return BoundedCommandData(
            data: data,
            exceededLimit: exceededLimit,
            readFailed: false,
            reachedEndOfFile: reachedEndOfFile
        )
    }

    private static func makeNonBlocking(_ fileHandle: FileHandle) -> Bool {
        let fileDescriptor = fileHandle.fileDescriptor
        let existingFlags = fcntl(fileDescriptor, F_GETFL)
        guard existingFlags >= 0 else {
            return false
        }
        return fcntl(fileDescriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0
    }

    private func result(
        completion: ReadOnlyCommandCompletion,
        output: BoundedCommandData,
        error: BoundedCommandData
    ) -> ReadOnlyCommandResult {
        ReadOnlyCommandResult(
            completion: completion,
            standardOutput: String(data: output.data, encoding: .utf8) ?? "",
            standardError: String(data: error.data, encoding: .utf8) ?? ""
        )
    }
}

private struct BoundedCommandData: Sendable {
    let data: Data
    let exceededLimit: Bool
    let readFailed: Bool
    let reachedEndOfFile: Bool
}

private final class OutputLimitTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var didExceedLimit = false

    var exceededLimit: Bool {
        lock.withLock { didExceedLimit }
    }

    func markExceeded() {
        lock.withLock {
            didExceedLimit = true
        }
    }
}

private final class ReadOnlyProcessController: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()

    init(process: Process) {
        self.process = process
    }

    func statusIfExited() -> Int32? {
        lock.withLock {
            process.isRunning ? nil : process.terminationStatus
        }
    }

    func killIfRunning() {
        lock.withLock {
            let processIdentifier = process.processIdentifier
            if process.isRunning, processIdentifier > 0 {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }
    }
}
