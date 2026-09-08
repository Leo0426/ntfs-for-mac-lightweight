import Darwin
import Foundation
import NTFSLiteCore

public struct MountPathAssessment: Equatable, Sendable {
    public let isCanonical: Bool
    public let isSymlink: Bool

    public init(isCanonical: Bool, isSymlink: Bool) {
        self.isCanonical = isCanonical
        self.isSymlink = isSymlink
    }
}

public enum MountPathValidator {
    public static func assess(_ path: String) -> MountPathAssessment {
        let url = URL(fileURLWithPath: path)
        let standardizedPath = url.standardizedFileURL.path
        guard let resolvedPath = resolvedPath(for: path) else {
            return MountPathAssessment(isCanonical: false, isSymlink: false)
        }
        let isSymlink = standardizedPath != resolvedPath
        return MountPathAssessment(
            isCanonical: path.hasPrefix("/")
                && path == standardizedPath
                && !isSymlink,
            isSymlink: isSymlink
        )
    }

    private static func resolvedPath(for path: String) -> String? {
        path.withCString { pathPointer in
            guard let resolvedPointer = Darwin.realpath(pathPointer, nil) else {
                return nil
            }
            defer {
                free(resolvedPointer)
            }
            return String(cString: resolvedPointer)
        }
    }
}

public struct SystemMountRecord: Equatable, Sendable {
    public let sourcePath: String
    public let sourceBSDName: String?
    public let mountPoint: String
    public let fileSystemName: String
    public let access: MountAccess
    public let backend: ObservedMountBackend
    public let isCanonical: Bool
    public let isSymlink: Bool
    public let fileSystemUUID: String?
    public let isComplete: Bool

    public init(
        sourcePath: String,
        sourceBSDName: String?,
        mountPoint: String,
        fileSystemName: String,
        access: MountAccess,
        backend: ObservedMountBackend,
        isCanonical: Bool,
        isSymlink: Bool,
        fileSystemUUID: String? = nil,
        isComplete: Bool = true
    ) {
        self.sourcePath = sourcePath
        self.sourceBSDName = sourceBSDName
        self.mountPoint = mountPoint
        self.fileSystemName = fileSystemName
        self.access = access
        self.backend = backend
        self.isCanonical = isCanonical
        self.isSymlink = isSymlink
        self.fileSystemUUID = fileSystemUUID
        self.isComplete = isComplete
    }

    public var volumeEvidence: ReadOnlyMountEvidence? {
        guard let sourceBSDName else {
            return nil
        }
        return ReadOnlyMountEvidence(
            sourceBSDName: sourceBSDName,
            mountPoint: mountPoint,
            access: access,
            backend: backend,
            isComplete: isComplete,
            isCanonical: isCanonical,
            isSymlink: isSymlink,
            fileSystemUUID: fileSystemUUID
        )
    }
}

public struct SystemMountTableSnapshot: Equatable, Sendable {
    public let records: [SystemMountRecord]

    public init(records: [SystemMountRecord]) {
        self.records = records
    }

    public func evidence(forBSDName bsdName: String) -> ReadOnlyMountEvidence? {
        let matchingRecords = records.filter { $0.sourceBSDName == bsdName }
        guard matchingRecords.count == 1 else {
            return nil
        }
        return matchingRecords[0].volumeEvidence
    }
}

public enum SystemMountTableReadError: Error, Equatable, Sendable {
    case countFailed(Int32)
    case snapshotFailed(Int32)
    case changedDuringRead
}

public struct SystemMountTableReader: Sendable {
    private let maximumSamples: Int
    private let loadSnapshot: @Sendable () throws -> SystemMountTableSnapshot

    public init() {
        maximumSamples = 6
        loadSnapshot = Self.readSingleSnapshot
    }

    package init(
        maximumSamples: Int,
        _ loadSnapshot: @escaping @Sendable () throws -> SystemMountTableSnapshot
    ) {
        self.maximumSamples = max(2, maximumSamples)
        self.loadSnapshot = loadSnapshot
    }

    public func currentSnapshot() throws -> SystemMountTableSnapshot {
        var previousSnapshot: SystemMountTableSnapshot?
        for _ in 0..<maximumSamples {
            let currentSnapshot: SystemMountTableSnapshot
            do {
                currentSnapshot = try loadSnapshot()
            } catch SystemMountTableReadError.changedDuringRead {
                previousSnapshot = nil
                continue
            } catch {
                throw error
            }
            if currentSnapshot == previousSnapshot {
                return currentSnapshot
            }
            previousSnapshot = currentSnapshot
        }

        throw SystemMountTableReadError.changedDuringRead
    }

    private static func readSingleSnapshot() throws -> SystemMountTableSnapshot {
        let requestedCount = getfsstat(nil, 0, MNT_NOWAIT)
        guard requestedCount >= 0 else {
            throw SystemMountTableReadError.countFailed(errno)
        }

        let capacity = max(Int(requestedCount) + 8, 8)
        var fileSystems = Array(repeating: statfs(), count: capacity)
        let byteCount = capacity * MemoryLayout<statfs>.stride
        let copiedCount = fileSystems.withUnsafeMutableBufferPointer { buffer in
            getfsstat(buffer.baseAddress, Int32(byteCount), MNT_NOWAIT)
        }
        guard copiedCount >= 0 else {
            throw SystemMountTableReadError.snapshotFailed(errno)
        }

        let countAfterRead = getfsstat(nil, 0, MNT_NOWAIT)
        guard countAfterRead >= 0 else {
            throw SystemMountTableReadError.countFailed(errno)
        }
        guard Int(copiedCount) < capacity,
              Int(countAfterRead) < capacity,
              copiedCount == countAfterRead
        else {
            throw SystemMountTableReadError.changedDuringRead
        }

        let records = fileSystems.prefix(Int(copiedCount)).map(Self.makeRecord)
        return SystemMountTableSnapshot(
            records: records.sorted {
                if $0.mountPoint != $1.mountPoint {
                    return $0.mountPoint < $1.mountPoint
                }
                return $0.sourcePath < $1.sourcePath
            }
        )
    }

    private static func makeRecord(_ fileSystem: statfs) -> SystemMountRecord {
        var fileSystem = fileSystem
        let sourcePath = string(from: &fileSystem.f_mntfromname)
        let mountPoint = string(from: &fileSystem.f_mntonname)
        let fileSystemName = string(from: &fileSystem.f_fstypename)
        let pathAssessment = MountPathValidator.assess(mountPoint)
        let readsIdentity = fileSystemName.lowercased() == "ntfs"
        let fileSystemUUID = readsIdentity ? MountedFileSystemUUIDReader.read(for: fileSystem) : nil

        return SystemMountRecord(
            sourcePath: sourcePath,
            sourceBSDName: MountSourceParser.bsdName(from: sourcePath),
            mountPoint: mountPoint,
            fileSystemName: fileSystemName,
            access: (fileSystem.f_flags & UInt32(MNT_RDONLY)) == 0 ? .readWrite : .readOnly,
            backend: backend(forFileSystemName: fileSystemName),
            isCanonical: pathAssessment.isCanonical,
            isSymlink: pathAssessment.isSymlink,
            fileSystemUUID: fileSystemUUID,
            isComplete: !readsIdentity || fileSystemUUID != nil
        )
    }

    private static func backend(forFileSystemName fileSystemName: String) -> ObservedMountBackend {
        switch fileSystemName.lowercased() {
        case "lifs":
            return .fsKit
        case "osxfuse", "fusefs":
            return .kernelExtension
        default:
            return .unknown
        }
    }

    private static func string<T>(from value: inout T) -> String {
        withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
}
