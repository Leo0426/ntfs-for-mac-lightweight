import Darwin
import Foundation
import NTFSLiteGateEvidence
import NTFSLiteSystem

private struct CaptureArguments {
    let evidenceID: String
    let applicationVersion: GateEvidenceVersion
    let applicationBuild: UInt32
    let applicationSHA256: String

    init?(_ arguments: [String]) {
        guard arguments.count == 6,
              arguments[1] == "capture",
              let applicationVersion = Self.version(arguments[3]),
              let applicationBuild = UInt32(arguments[4])
        else {
            return nil
        }
        evidenceID = arguments[2]
        self.applicationVersion = applicationVersion
        self.applicationBuild = applicationBuild
        applicationSHA256 = arguments[5]
    }

    private static func version(_ value: String) -> GateEvidenceVersion? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = UInt32(components[0]),
              let minor = UInt32(components[1]),
              let patch = UInt32(components[2])
        else {
            return nil
        }
        return GateEvidenceVersion(major: major, minor: minor, patch: patch)
    }
}

private enum BoundedLineReadResult: Sendable {
    case line(String)
    case tooLong
    case invalidEncoding
    case end
    case readFailure
}

// All mutable parsing state is confined to inputQueue. A blocking descriptor
// read must never occupy the main actor that forwards observation events.
private final class BoundedLineReader: @unchecked Sendable {
    private let inputQueue = DispatchQueue(label: "NTFSLite.Gate1CommandInput")
    private var buffer = Data()
    private var offset = 0
    private var reachedEnd = false

    func next(maximumBytes: Int) async -> BoundedLineReadResult {
        await withCheckedContinuation { continuation in
            inputQueue.async {
                continuation.resume(returning: self.readNext(maximumBytes: maximumBytes))
            }
        }
    }

    private func readNext(maximumBytes: Int) -> BoundedLineReadResult {
        var lineBytes: [UInt8] = []
        lineBytes.reserveCapacity(maximumBytes)
        var discarding = false
        while true {
            if offset >= buffer.count {
                if reachedEnd {
                    if discarding {
                        return .tooLong
                    }
                    guard !lineBytes.isEmpty else {
                        return .end
                    }
                    return decode(lineBytes)
                }
                // Read available bytes without waiting to fill a Foundation
                // read buffer: an operator may keep a pipe open indefinitely.
                var bytes = [UInt8](repeating: 0, count: 4_096)
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return .readFailure
                }
                buffer = Data(bytes.prefix(count))
                offset = 0
                if buffer.isEmpty {
                    reachedEnd = true
                    continue
                }
            }
            let byte = buffer[offset]
            offset += 1
            if byte == 0x0A {
                if discarding {
                    return .tooLong
                }
                if lineBytes.last == 0x0D {
                    lineBytes.removeLast()
                }
                return decode(lineBytes)
            }
            if !discarding {
                if lineBytes.count < maximumBytes {
                    lineBytes.append(byte)
                } else {
                    discarding = true
                }
            }
        }
    }

    private func decode(_ bytes: [UInt8]) -> BoundedLineReadResult {
        guard let line = String(bytes: bytes, encoding: .utf8) else {
            return .invalidEncoding
        }
        return .line(line)
    }
}

private enum LiveCommandResult: Sendable {
    case success
    case recorderFailure(Gate1EvidenceRecorderError)
    case unavailable
}

private enum LiveStatusResult: Sendable {
    case success(Gate1EvidenceRecorderStatus)
    case unavailable
}

private enum LiveSealResult: Sendable {
    case success(Gate1EvidenceArtifact, Gate1EvidenceRecorderStatus)
    case recorderFailure(Gate1EvidenceRecorderError)
    case unavailable
}

private enum LiveEvidenceEvent: @unchecked Sendable {
    case observation(DiskInventoryObservation)
    case sourceFailure(Gate1EvidenceSourceFailure)
    case checkpoint(
        Gate1OperatorCheckpoint,
        CheckedContinuation<LiveCommandResult, Never>
    )
    case status(CheckedContinuation<LiveStatusResult, Never>)
    case seal(CheckedContinuation<LiveSealResult, Never>)
}

private final class LiveEvidenceEventChannel: @unchecked Sendable {
    let stream: AsyncStream<LiveEvidenceEvent>

    private let continuation: AsyncStream<LiveEvidenceEvent>.Continuation
    private let lock = NSLock()
    private var overflowed = false

    init() {
        let pair = AsyncStream.makeStream(
            of: LiveEvidenceEvent.self,
            bufferingPolicy: .bufferingOldest(
                Gate1EvidencePolicy.maximumObservations
                    + Gate1EvidencePolicy.maximumCheckpoints
                    + 32
            )
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func submit(_ event: LiveEvidenceEvent) {
        switch continuation.yield(event) {
        case .enqueued:
            break
        case let .dropped(dropped):
            markOverflowed()
            resumeUnavailable(dropped)
        case .terminated:
            resumeUnavailable(event)
        @unknown default:
            markOverflowed()
            resumeUnavailable(event)
        }
    }

    func takeOverflowed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let result = overflowed
        overflowed = false
        return result
    }

    func finish() {
        continuation.finish()
    }

    private func markOverflowed() {
        lock.lock()
        overflowed = true
        lock.unlock()
    }

    private func resumeUnavailable(_ event: LiveEvidenceEvent) {
        switch event {
        case .observation, .sourceFailure:
            break
        case let .checkpoint(_, response):
            response.resume(returning: .unavailable)
        case let .status(response):
            response.resume(returning: .unavailable)
        case let .seal(response):
            response.resume(returning: .unavailable)
        }
    }
}

@main
private enum Gate1EvidenceTool {
    static func main() async {
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "verify"
        {
            verify(expectedSHA256Digest: CommandLine.arguments[2])
            return
        }
        guard let arguments = CaptureArguments(CommandLine.arguments) else {
            writeError(usage)
            exit(EX_USAGE)
        }
        let operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        let header: Gate1EvidenceHeader
        do {
            header = try Gate1EvidenceHeader(
                evidenceID: arguments.evidenceID,
                applicationVersion: arguments.applicationVersion,
                applicationBuild: arguments.applicationBuild,
                applicationSHA256: arguments.applicationSHA256,
                macOSVersion: GateEvidenceVersion(
                    major: UInt32(operatingSystemVersion.majorVersion),
                    minor: UInt32(operatingSystemVersion.minorVersion),
                    patch: UInt32(operatingSystemVersion.patchVersion)
                )
            )
        } catch {
            writeError("参数不符合固定证据格式。\n\(usage)")
            exit(EX_USAGE)
        }

        let recorder = Gate1EvidenceRecorder(header: header)
        let capture: ReadOnlyDiskObservationCapture
        do {
            capture = try ReadOnlyDiskObserver().capture()
        } catch {
            writeError("无法启动只读系统观察；未生成证据。")
            exit(EX_UNAVAILABLE)
        }

        let channel = LiveEvidenceEventChannel()
        let eventTask = Task {
            for await event in channel.stream {
                if channel.takeOverflowed() {
                    try? await recorder.failClosed(.eventQueueOverflow)
                }
                switch event {
                case let .observation(observation):
                    do {
                        try await recorder.ingest(observation)
                    } catch let error as Gate1EvidenceRecorderError {
                        writeError("只读观察已停止：\(fixedError(error))")
                    } catch {
                        try? await recorder.failClosed(
                            .unclassifiedObservationFailure
                        )
                        writeError("只读观察已因未分类错误停止。")
                    }
                case let .sourceFailure(failure):
                    try? await recorder.failClosed(failure)
                    if failure == .observationStreamEnded {
                        writeError("只读观察流意外结束；证据已失败关闭。")
                    } else if failure == .finalObservationUnverified {
                        writeError("最终只读系统快照未验证；证据已失败关闭。")
                    }
                case let .checkpoint(checkpoint, response):
                    do {
                        try await recorder.record(checkpoint)
                        response.resume(returning: .success)
                    } catch let error as Gate1EvidenceRecorderError {
                        response.resume(returning: .recorderFailure(error))
                    } catch {
                        try? await recorder.failClosed(.unclassifiedOperatorFailure)
                        response.resume(returning: .unavailable)
                    }
                case let .status(response):
                    response.resume(
                        returning: .success(await recorder.status())
                    )
                case let .seal(response):
                    do {
                        let artifact = try await recorder.seal()
                        response.resume(
                            returning: .success(
                                artifact,
                                await recorder.status()
                            )
                        )
                    } catch let error as Gate1EvidenceRecorderError {
                        response.resume(returning: .recorderFailure(error))
                    } catch {
                        response.resume(returning: .unavailable)
                    }
                }
                if channel.takeOverflowed() {
                    try? await recorder.failClosed(.eventQueueOverflow)
                }
            }
        }
        let observationTask = Task {
            var terminal: ReadOnlyDiskObservationCaptureTerminal?
            for await event in capture.events {
                guard !Task.isCancelled else {
                    return terminal
                }
                switch event {
                case let .observation(observation):
                    channel.submit(.observation(observation))
                case let .terminal(value):
                    terminal = value
                    switch value {
                    case let .drained(finalObservationVerified):
                        if !finalObservationVerified {
                            channel.submit(
                                .sourceFailure(.finalObservationUnverified)
                            )
                        }
                    case .sourceEndedUnexpectedly:
                        channel.submit(
                            .sourceFailure(.observationStreamEnded)
                        )
                    }
                }
            }
            return terminal
        }

        writeError(instructions)
        var shouldSeal = false
        let lineReader = BoundedLineReader()
        while !shouldSeal {
            let line: String
            switch await lineReader.next(maximumBytes: 256) {
            case let .line(value):
                line = value
            case .tooLong, .invalidEncoding:
                writeError("命令无效。输入不得超过 256 字节且必须是 UTF-8。")
                continue
            case .end:
                capture.stopImmediately()
                observationTask.cancel()
                _ = await observationTask.value
                channel.finish()
                await eventTask.value
                writeError("命令输入已结束；未收到显式 seal，未生成证据。")
                exit(EX_DATAERR)
            case .readFailure:
                capture.stopImmediately()
                observationTask.cancel()
                _ = await observationTask.value
                channel.finish()
                await eventTask.value
                writeError("无法读取操作命令；未生成证据。")
                exit(EX_IOERR)
            }
            switch Gate1EvidenceOperatorCommandParser.parse(line) {
            case .failure:
                writeError("命令无效。输入 status、seal 或固定 checkpoint 命令。")
            case .success(.status):
                let result: LiveStatusResult = await withCheckedContinuation {
                    channel.submit(.status($0))
                }
                switch result {
                case let .success(status):
                    writeStatus(status)
                case .unavailable:
                    writeError("状态暂不可用；事件队列已失败关闭。")
                }
            case .success(.seal):
                shouldSeal = true
            case let .success(.checkpoint(checkpoint)):
                let result: LiveCommandResult = await withCheckedContinuation {
                    channel.submit(.checkpoint(checkpoint, $0))
                }
                switch result {
                case .success:
                    writeError("检查点已记录：\(checkpoint.kind.rawValue)。")
                case let .recorderFailure(error):
                    writeError("检查点未记录：\(fixedError(error))")
                case .unavailable:
                    writeError("检查点未记录：未分类错误。")
                }
            }
        }

        let drainAccepted = await capture.stopAndDrain()
        let captureTerminal = await observationTask.value
        if !drainAccepted,
           captureTerminal != .sourceEndedUnexpectedly
        {
            channel.submit(.sourceFailure(.observationStreamEnded))
        } else if drainAccepted, captureTerminal == nil {
            channel.submit(.sourceFailure(.unclassifiedObservationFailure))
        }
        let sealResult: LiveSealResult = await withCheckedContinuation {
            channel.submit(.seal($0))
        }
        channel.finish()
        await eventTask.value
        let artifact: Gate1EvidenceArtifact
        let finalStatus: Gate1EvidenceRecorderStatus
        switch sealResult {
        case let .success(sealedArtifact, status):
            artifact = sealedArtifact
            finalStatus = status
        case let .recorderFailure(error):
            writeError("证据无法封存：\(fixedError(error))")
            exit(EX_DATAERR)
        case .unavailable:
            writeError("证据无法封存：未分类错误。")
            exit(EX_SOFTWARE)
        }

        guard case .success = Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: artifact.canonicalJSON,
            expectedSHA256Digest: artifact.sha256Digest
        ) else {
            writeError("内部 canonical 校验失败；未输出证据。")
            exit(EX_SOFTWARE)
        }
        FileHandle.standardOutput.write(artifact.canonicalJSON)
        writeError("SHA-256: \(artifact.sha256Digest)")
        writeStatus(finalStatus)
    }

    private static func verify(expectedSHA256Digest: String) {
        let canonicalJSON = readBoundedCanonicalInput()
        switch Gate1EvidenceArtifactVerifier.verify(
            canonicalJSON: canonicalJSON,
            expectedSHA256Digest: expectedSHA256Digest
        ) {
        case let .success(artifact):
            writeError("canonical 证据校验成功。")
            writeError("SHA-256: \(artifact.sha256Digest)")
            writeError(
                "verdict=\(artifact.bundle.verdict.rawValue) "
                    + "循环=\(artifact.bundle.completedCycleCount)/"
                    + "\(artifact.bundle.requiredCycleCount)"
            )
        case let .failure(failure):
            writeError("canonical 证据校验失败：\(String(describing: failure))")
            exit(EX_DATAERR)
        }
    }

    private static func readBoundedCanonicalInput() -> Data {
        let maximumBytes = Gate1EvidencePolicy.default.maxEncodedBytes
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1_024))
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            let chunk: Data?
            do {
                chunk = try FileHandle.standardInput.read(
                    upToCount: min(remaining, 64 * 1_024)
                )
            } catch {
                writeError("无法读取 canonical 证据。")
                exit(EX_IOERR)
            }
            guard let chunk, !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        return data
    }

    private static func writeStatus(_ status: Gate1EvidenceRecorderStatus) {
        let failureText = status.failureCodes.isEmpty
            ? "none"
            : status.failureCodes.map(\.rawValue).joined(separator: ",")
        writeError(
            "状态=\(status.phase.rawValue) "
                + "观测=\(status.observationCount) "
                + "检查点=\(status.checkpointCount) "
                + "循环=\(status.completedCycleCount)/\(status.requiredCycleCount) "
                + "未确认移除=\(status.openConnectionCount) "
                + "失败码=\(failureText)"
        )
    }

    private static func fixedError(_ error: Gate1EvidenceRecorderError) -> String {
        String(describing: error)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private static let usage = """
    采集：NTFSLiteGate1EvidenceTool capture EVIDENCE-ID APP-VERSION APP-BUILD APP-SHA256
    校验：NTFSLiteGate1EvidenceTool verify EXPECTED-SHA256 < artifact.json
    APP-VERSION 必须是 major.minor.patch；摘要必须是 64 位小写 SHA-256。
    canonical JSON 只写入标准输出，状态和摘要只写入标准错误。
    """

    private static let instructions = """
    Gate 1 只读证据记录已启动。此工具不会挂载、卸载、推出或修改磁盘。
    固定命令：
      status
      seal
      checkpoint <kind> <confirmed|contradicted|notPerformed>
      checkpoint <systemInventoryComparison|mountTableComparison> <1...100> <finding>
    applicationRestart 表示重启正式只读 App；证据工具自身保持运行。
    """
}
