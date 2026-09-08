import Foundation
import IOKit

public struct IOMediaEnumerationSnapshot: Equatable, Sendable {
    public let bsdNames: Set<String>

    public init(bsdNames: Set<String>) {
        self.bsdNames = bsdNames
    }
}

public enum IOMediaEnumerationReadError: Error, Equatable, Sendable {
    case matchingDictionaryCreationFailed
    case serviceEnumerationFailed(code: Int32)
    case missingOrInvalidBSDName
    case duplicateBSDName(String)
    case iteratorInvalidated
    case changedDuringRead
    case timedOut
    case unexpectedFailure
}

public struct IOMediaEnumerationSnapshotProvider: Sendable {
    private let loadSnapshot: @Sendable () throws -> IOMediaEnumerationSnapshot

    public init(
        _ loadSnapshot: @escaping @Sendable () throws -> IOMediaEnumerationSnapshot
    ) {
        self.loadSnapshot = loadSnapshot
    }

    public func currentSnapshot() throws -> IOMediaEnumerationSnapshot {
        try loadSnapshot()
    }

    public static let live = IOMediaEnumerationSnapshotProvider {
        try SystemIOMediaEnumerationReader().currentSnapshot()
    }
}

public struct SystemIOMediaEnumerationReader: Sendable {
    private let maximumSamples: Int
    private let sampler: @Sendable () throws -> IOMediaEnumerationSnapshot

    public init() {
        maximumSamples = 6
        sampler = Self.singleSnapshot
    }

    package init(
        maximumSamples: Int,
        sampler: @escaping @Sendable () throws -> IOMediaEnumerationSnapshot
    ) {
        self.maximumSamples = max(2, maximumSamples)
        self.sampler = sampler
    }

    public func currentSnapshot() throws -> IOMediaEnumerationSnapshot {
        var previous: IOMediaEnumerationSnapshot?
        for _ in 0..<maximumSamples {
            let current: IOMediaEnumerationSnapshot
            do {
                current = try sampler()
            } catch IOMediaEnumerationReadError.iteratorInvalidated {
                previous = nil
                continue
            }
            if current == previous {
                return current
            }
            previous = current
        }
        throw IOMediaEnumerationReadError.changedDuringRead
    }

    private static func singleSnapshot() throws -> IOMediaEnumerationSnapshot {
        guard let matching = IOServiceMatching("IOMedia") else {
            throw IOMediaEnumerationReadError.matchingDictionaryCreationFailed
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        )
        guard result == KERN_SUCCESS else {
            throw IOMediaEnumerationReadError.serviceEnumerationFailed(
                code: Int32(result)
            )
        }
        defer { IOObjectRelease(iterator) }

        var bsdNames: Set<String> = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else {
                break
            }
            defer { IOObjectRelease(service) }

            let property = IORegistryEntryCreateCFProperty(
                service,
                kIOBSDNameKey as NSString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
            guard let bsdName = property as? String,
                  !bsdName.isEmpty,
                  bsdName == bsdName.trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                throw IOMediaEnumerationReadError.missingOrInvalidBSDName
            }
            guard bsdNames.insert(bsdName).inserted else {
                throw IOMediaEnumerationReadError.duplicateBSDName(bsdName)
            }
        }

        guard IOIteratorIsValid(iterator) != 0 else {
            throw IOMediaEnumerationReadError.iteratorInvalidated
        }
        return IOMediaEnumerationSnapshot(bsdNames: bsdNames)
    }
}
