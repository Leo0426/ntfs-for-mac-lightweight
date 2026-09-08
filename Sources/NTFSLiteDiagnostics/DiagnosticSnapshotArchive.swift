import Darwin
import Foundation

public enum DiagnosticSnapshotArchivePolicyError: Error, Equatable, Sendable {
    case directoryMustBeCanonicalAbsolutePath
    case invalidFileName
    case maxBytesMustBePositive
    case maxAgeMustBePositive
}

public struct DiagnosticSnapshotArchivePolicy: Equatable, Sendable {
    public let directoryURL: URL
    public let fileName: String
    public let expectedOwnerID: UInt32
    public let maxBytes: Int
    public let maxAge: TimeInterval

    fileprivate let maxAgeMilliseconds: Int64

    public init(
        directoryURL: URL,
        fileName: String = "diagnostics-v1.json",
        expectedOwnerID: UInt32 = getuid(),
        maxBytes: Int = 256 * 1_024,
        maxAge: TimeInterval = 7 * 24 * 60 * 60
    ) throws {
        let path = directoryURL.path
        guard directoryURL.isFileURL,
              path.hasPrefix("/"),
              path != "/",
              directoryURL.standardizedFileURL.path == path,
              !path.utf8.contains(0)
        else {
            throw DiagnosticSnapshotArchivePolicyError.directoryMustBeCanonicalAbsolutePath
        }
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.utf8.contains(0)
        else {
            throw DiagnosticSnapshotArchivePolicyError.invalidFileName
        }
        guard maxBytes > 0 else {
            throw DiagnosticSnapshotArchivePolicyError.maxBytesMustBePositive
        }
        guard maxAge.isFinite, maxAge > 0 else {
            throw DiagnosticSnapshotArchivePolicyError.maxAgeMustBePositive
        }

        self.directoryURL = directoryURL
        self.fileName = fileName
        self.expectedOwnerID = expectedOwnerID
        self.maxBytes = maxBytes
        self.maxAge = maxAge
        let milliseconds = maxAge * 1_000
        self.maxAgeMilliseconds = milliseconds >= Double(Int64.max)
            ? Int64.max
            : max(1, Int64(milliseconds.rounded(.up)))
    }
}

public enum DiagnosticSnapshotArchiveFailure: Equatable, Sendable {
    case unsafeDirectory
    case unsafeFile
    case oversized
    case malformed
    case unsupportedSchema
    case invalidSnapshot
    case expired
    case futureTimestamp
    case inputOutputFailure
}

public enum DiagnosticSnapshotArchiveLoadResult: Equatable, Sendable {
    case unavailable
    case loaded(DiagnosticSnapshot)
    case failedClosed(DiagnosticSnapshotArchiveFailure)
}

public enum DiagnosticSnapshotArchiveSaveResult: Equatable, Sendable {
    case saved
    case superseded
    case failedClosed(DiagnosticSnapshotArchiveFailure)
}

public enum DiagnosticSnapshotArchiveClearResult: Equatable, Sendable {
    case cleared
    case failedClosed(DiagnosticSnapshotArchiveFailure)
}

public struct DiagnosticSnapshotArchiveGeneration: Equatable, Sendable {
    fileprivate let value: UUID

    fileprivate init(value: UUID) {
        self.value = value
    }
}

public actor DiagnosticSnapshotArchive {
    private enum DirectoryOpenResult {
        case opened(Int32)
        case missing
        case failed(DiagnosticSnapshotArchiveFailure)
    }

    private let policy: DiagnosticSnapshotArchivePolicy
    private let clock: @Sendable () -> Date
    private var generation = DiagnosticSnapshotArchiveGeneration(value: UUID())

    public init(
        policy: DiagnosticSnapshotArchivePolicy,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.policy = policy
        self.clock = clock
    }

    public func load() -> DiagnosticSnapshotArchiveLoadResult {
        let directoryResult = openDirectory(createIfMissing: false)
        guard case let .opened(directoryFD) = directoryResult else {
            switch directoryResult {
            case .missing:
                return .unavailable
            case let .failed(failure):
                return .failedClosed(failure)
            case .opened:
                return .failedClosed(.inputOutputFailure)
            }
        }
        defer { close(directoryFD) }

        let fileFD = policy.fileName.withCString {
            openat(
                directoryFD,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard fileFD >= 0 else {
            return errno == ENOENT
                ? .unavailable
                : .failedClosed(errno == ELOOP ? .unsafeFile : .inputOutputFailure)
        }
        defer { close(fileFD) }

        guard let initialStatus = validatedFileStatus(fileFD) else {
            return .failedClosed(.unsafeFile)
        }
        let size = Int(initialStatus.st_size)
        guard size <= policy.maxBytes else {
            return .failedClosed(.oversized)
        }
        guard let data = readExactly(fileFD, count: size) else {
            return .failedClosed(.inputOutputFailure)
        }
        var finalStatus = stat()
        guard fstat(fileFD, &finalStatus) == 0,
              metadataRemainedStable(from: initialStatus, to: finalStatus)
        else {
            return .failedClosed(.unsafeFile)
        }

        let snapshot: DiagnosticSnapshot
        do {
            snapshot = try JSONDecoder().decode(DiagnosticSnapshot.self, from: data)
            guard try snapshot.encodedJSON() == data else {
                return .failedClosed(.malformed)
            }
        } catch {
            return .failedClosed(.malformed)
        }
        guard snapshot.schemaVersion == DiagnosticSnapshot.currentSchemaVersion else {
            return .failedClosed(.unsupportedSchema)
        }
        guard isSemanticallyValid(snapshot) else {
            return .failedClosed(.invalidSnapshot)
        }

        if let failure = temporalFailure(for: snapshot) {
            return .failedClosed(failure)
        }
        return .loaded(snapshot)
    }

    public func currentGeneration() -> DiagnosticSnapshotArchiveGeneration {
        generation
    }

    public func save(
        _ snapshot: DiagnosticSnapshot,
        generation expectedGeneration: DiagnosticSnapshotArchiveGeneration
    ) -> DiagnosticSnapshotArchiveSaveResult {
        guard expectedGeneration == generation else {
            return .superseded
        }
        guard snapshot.schemaVersion == DiagnosticSnapshot.currentSchemaVersion else {
            return .failedClosed(.unsupportedSchema)
        }
        guard isSemanticallyValid(snapshot) else {
            return .failedClosed(.invalidSnapshot)
        }
        if let failure = temporalFailure(for: snapshot) {
            return .failedClosed(failure)
        }

        let data: Data
        do {
            data = try snapshot.encodedJSON()
        } catch {
            return .failedClosed(.malformed)
        }
        guard data.count <= policy.maxBytes else {
            return .failedClosed(.oversized)
        }

        let directoryResult = openDirectory(createIfMissing: true)
        guard case let .opened(directoryFD) = directoryResult else {
            if case let .failed(failure) = directoryResult {
                return .failedClosed(failure)
            }
            return .failedClosed(.inputOutputFailure)
        }
        defer { close(directoryFD) }

        guard existingTargetIsSafe(directoryFD) else {
            return .failedClosed(.unsafeFile)
        }

        let temporaryName = ".diagnostics-\(UUID().uuidString).tmp"
        let temporaryFD = temporaryName.withCString {
            openat(
                directoryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard temporaryFD >= 0 else {
            return .failedClosed(.inputOutputFailure)
        }
        var shouldRemoveTemporary = true
        defer {
            close(temporaryFD)
            if shouldRemoveTemporary {
                _ = temporaryName.withCString {
                    unlinkat(directoryFD, $0, 0)
                }
            }
        }

        guard fchmod(temporaryFD, mode_t(S_IRUSR | S_IWUSR)) == 0,
              writeAll(data, to: temporaryFD),
              fsync(temporaryFD) == 0
        else {
            return .failedClosed(.inputOutputFailure)
        }

        let renamed = temporaryName.withCString { temporaryPointer in
            policy.fileName.withCString { targetPointer in
                renameat(directoryFD, temporaryPointer, directoryFD, targetPointer)
            }
        }
        guard renamed == 0, fsync(directoryFD) == 0 else {
            return .failedClosed(.inputOutputFailure)
        }
        shouldRemoveTemporary = false
        return .saved
    }

    public func clear() -> DiagnosticSnapshotArchiveClearResult {
        generation = DiagnosticSnapshotArchiveGeneration(value: UUID())
        let directoryResult = openDirectory(createIfMissing: false)
        guard case let .opened(directoryFD) = directoryResult else {
            switch directoryResult {
            case .missing:
                return .cleared
            case let .failed(failure):
                return .failedClosed(failure)
            case .opened:
                return .failedClosed(.inputOutputFailure)
            }
        }
        defer { close(directoryFD) }

        var status = stat()
        let inspected = policy.fileName.withCString {
            fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if inspected != 0 {
            return errno == ENOENT
                ? .cleared
                : .failedClosed(.inputOutputFailure)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == policy.expectedOwnerID,
              status.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0
        else {
            return .failedClosed(.unsafeFile)
        }

        let removed = policy.fileName.withCString {
            unlinkat(directoryFD, $0, 0)
        }
        guard removed == 0, fsync(directoryFD) == 0 else {
            return .failedClosed(.inputOutputFailure)
        }
        return .cleared
    }

    private func openDirectory(createIfMissing: Bool) -> DirectoryOpenResult {
        let components = policy.directoryURL.pathComponents.dropFirst()
        var currentFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard currentFD >= 0 else {
            return .failed(.inputOutputFailure)
        }

        for component in components {
            var nextFD = component.withCString {
                openat(
                    currentFD,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            if nextFD < 0, errno == ENOENT, createIfMissing {
                let created = component.withCString {
                    mkdirat(currentFD, $0, mode_t(S_IRWXU))
                }
                if created != 0, errno != EEXIST {
                    close(currentFD)
                    return .failed(.inputOutputFailure)
                }
                nextFD = component.withCString {
                    openat(
                        currentFD,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
            }
            guard nextFD >= 0 else {
                let failure: DirectoryOpenResult
                if errno == ENOENT {
                    failure = .missing
                } else if errno == ELOOP || errno == ENOTDIR {
                    failure = .failed(.unsafeDirectory)
                } else {
                    failure = .failed(.inputOutputFailure)
                }
                close(currentFD)
                return failure
            }
            close(currentFD)
            currentFD = nextFD
        }

        var status = stat()
        guard fstat(currentFD, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == policy.expectedOwnerID,
              status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
        else {
            close(currentFD)
            return .failed(.unsafeDirectory)
        }
        return .opened(currentFD)
    }

    private func existingTargetIsSafe(_ directoryFD: Int32) -> Bool {
        var status = stat()
        let result = policy.fileName.withCString {
            fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            return errno == ENOENT
        }
        return (status.st_mode & S_IFMT) == S_IFREG
            && status.st_uid == policy.expectedOwnerID
            && status.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0
    }

    private func validatedFileStatus(_ fileFD: Int32) -> stat? {
        var status = stat()
        guard fstat(fileFD, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == policy.expectedOwnerID,
              status.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0,
              status.st_size > 0,
              status.st_size <= off_t(Int.max)
        else {
            return nil
        }
        return status
    }

    private func metadataRemainedStable(from initial: stat, to final: stat) -> Bool {
        initial.st_dev == final.st_dev
            && initial.st_ino == final.st_ino
            && initial.st_mode == final.st_mode
            && initial.st_uid == final.st_uid
            && initial.st_size == final.st_size
            && initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec
            && initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
            && initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec
            && initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
    }

    private func readExactly(_ fileFD: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        let didReadAll = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else {
                return count == 0
            }
            var offset = 0
            while offset < count {
                let result = read(fileFD, baseAddress.advanced(by: offset), count - offset)
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        guard didReadAll else {
            return nil
        }
        var trailingByte: UInt8 = 0
        let trailingCount = read(fileFD, &trailingByte, 1)
        guard trailingCount == 0 else {
            return nil
        }
        return data
    }

    private func writeAll(_ data: Data, to fileFD: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return data.isEmpty
            }
            var offset = 0
            while offset < data.count {
                let result = write(fileFD, baseAddress.advanced(by: offset), data.count - offset)
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func isSemanticallyValid(_ snapshot: DiagnosticSnapshot) -> Bool {
        var previousSequence: UInt64 = 0
        for entry in snapshot.entries {
            guard entry.sequence > previousSequence,
                  entry.occurredAt <= snapshot.generatedAt
            else {
                return false
            }
            if let target = entry.event.target {
                guard target.runID == snapshot.runID,
                      isSemanticallyValid(target)
                else {
                    return false
                }
            }
            previousSequence = entry.sequence
        }
        return true
    }

    private func isSemanticallyValid(_ target: DiagnosticTarget) -> Bool {
        guard target.diskOrdinal > 0, target.mediaGeneration > 0 else {
            return false
        }
        switch target.kind {
        case .disk:
            return target.volumeOrdinal == nil
        case .volume:
            guard let volumeOrdinal = target.volumeOrdinal else {
                return false
            }
            return volumeOrdinal > 0
        }
    }

    private func temporalFailure(
        for snapshot: DiagnosticSnapshot
    ) -> DiagnosticSnapshotArchiveFailure? {
        let now = DiagnosticTimestamp(date: clock()).millisecondsSince1970
        let generated = snapshot.generatedAt.millisecondsSince1970
        guard generated <= now else {
            return .futureTimestamp
        }
        let (age, overflow) = now.subtractingReportingOverflow(generated)
        guard !overflow, age < policy.maxAgeMilliseconds else {
            return .expired
        }
        return nil
    }
}
