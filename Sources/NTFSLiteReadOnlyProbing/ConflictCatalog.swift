import Darwin
import Foundation
import NTFSLiteCore

public struct ConflictCatalogEvidenceDate: Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    fileprivate var isValid: Bool {
        guard year >= 2020, (1...12).contains(month) else {
            return false
        }
        let maximumDay: Int
        switch month {
        case 2:
            let isLeapYear = year.isMultiple(of: 400)
                || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
            maximumDay = isLeapYear ? 29 : 28
        case 4, 6, 9, 11:
            maximumDay = 30
        default:
            maximumDay = 31
        }
        return (1...maximumDay).contains(day)
    }
}

public struct ConflictCatalogTarget: Equatable, Sendable {
    public let macOSVersion: SemanticVersion
    public let architecture: RuntimeArchitecture

    public init(
        macOSVersion: SemanticVersion,
        architecture: RuntimeArchitecture
    ) {
        self.macOSVersion = macOSVersion
        self.architecture = architecture
    }

    fileprivate var isValid: Bool {
        macOSVersion.major >= 0
            && macOSVersion.minor >= 0
            && macOSVersion.patch >= 0
            && architecture != .unknown
    }
}

public struct InstalledConflictFootprint: Equatable, Hashable, Sendable {
    public let absolutePath: String
    public let expectedBundleIdentifier: String?

    public init(
        absolutePath: String,
        expectedBundleIdentifier: String?
    ) {
        self.absolutePath = absolutePath
        self.expectedBundleIdentifier = expectedBundleIdentifier
    }

    fileprivate var isValid: Bool {
        ConflictCatalogValidation.isCanonicalAbsolutePath(absolutePath)
            && expectedBundleIdentifier.map(
                ConflictCatalogValidation.isSafeBundleIdentifier
            ) != false
    }
}

public struct ConflictCatalogArtifact: Equatable, Sendable {
    public let artifactID: String
    public let version: SemanticVersion
    public let sha256: Data
    public let loadedSystemExtensionIdentifiers: Set<String>
    public let loadedKextIdentifiers: Set<String>
    public let installedFootprints: [InstalledConflictFootprint]

    public init(
        artifactID: String,
        version: SemanticVersion,
        sha256: Data,
        loadedSystemExtensionIdentifiers: Set<String>,
        loadedKextIdentifiers: Set<String>,
        installedFootprints: [InstalledConflictFootprint]
    ) {
        self.artifactID = artifactID
        self.version = version
        self.sha256 = sha256
        self.loadedSystemExtensionIdentifiers = loadedSystemExtensionIdentifiers
        self.loadedKextIdentifiers = loadedKextIdentifiers
        self.installedFootprints = installedFootprints
    }

    fileprivate var isValid: Bool {
        ConflictCatalogValidation.isSafeToken(artifactID)
            && version.major >= 0
            && version.minor >= 0
            && version.patch >= 0
            && sha256.count == 32
            && !installedFootprints.isEmpty
            && installedFootprints.allSatisfy(\.isValid)
            && loadedSystemExtensionIdentifiers.allSatisfy(
                ConflictCatalogValidation.isSafeBundleIdentifier
            )
            && loadedKextIdentifiers.allSatisfy(
                ConflictCatalogValidation.isSafeBundleIdentifier
            )
    }
}

public struct ConflictCatalogScope: Equatable, Sendable {
    public let scopeID: String
    public let target: ConflictCatalogTarget
    public let evidenceDate: ConflictCatalogEvidenceDate
    public let artifacts: [ConflictCatalogArtifact]

    public init(
        scopeID: String,
        target: ConflictCatalogTarget,
        evidenceDate: ConflictCatalogEvidenceDate,
        artifacts: [ConflictCatalogArtifact]
    ) {
        self.scopeID = scopeID
        self.target = target
        self.evidenceDate = evidenceDate
        self.artifacts = artifacts
    }

    package var isValid: Bool {
        guard ConflictCatalogValidation.isSafeToken(scopeID),
              target.isValid,
              evidenceDate.isValid,
              !artifacts.isEmpty,
              artifacts.count <= 64,
              artifacts.allSatisfy(\.isValid),
              Set(artifacts.map(\.artifactID)).count == artifacts.count
        else {
            return false
        }

        let footprints = artifacts.flatMap(\.installedFootprints)
        guard Set(footprints.map(\.absolutePath)).count == footprints.count else {
            return false
        }
        let loadedIdentifiers = artifacts.flatMap {
            Array($0.loadedSystemExtensionIdentifiers)
                + Array($0.loadedKextIdentifiers)
        }
        return Set(loadedIdentifiers).count == loadedIdentifiers.count
    }

    public var loadedSystemExtensionIdentifiers: Set<String> {
        artifacts.reduce(into: []) {
            $0.formUnion($1.loadedSystemExtensionIdentifiers)
        }
    }

    public var loadedKextIdentifiers: Set<String> {
        artifacts.reduce(into: []) {
            $0.formUnion($1.loadedKextIdentifiers)
        }
    }
}

public struct ConflictCatalogEnvironment: Equatable, Sendable {
    public let macOSVersion: SemanticVersion
    public let architecture: RuntimeArchitecture

    public init(
        macOSVersion: SemanticVersion,
        architecture: RuntimeArchitecture
    ) {
        self.macOSVersion = macOSVersion
        self.architecture = architecture
    }

    public static let unknown = ConflictCatalogEnvironment(
        macOSVersion: SemanticVersion(major: 0, minor: 0, patch: 0),
        architecture: .unknown
    )

    package func matches(_ target: ConflictCatalogTarget) -> Bool {
        macOSVersion == target.macOSVersion && architecture == target.architecture
    }
}

public enum ConflictFootprintIncompleteReason: Equatable, Sendable {
    case invalidPolicy
    case symbolicLink
    case notDirectory
    case permissionDenied
    case changedDuringRead
    case metadataUnavailable
}

public enum ConflictFootprintObservation: Equatable, Sendable {
    case absent
    case presentConflict
    case incomplete(ConflictFootprintIncompleteReason)
}

public struct ConflictFootprintProvider: Sendable {
    private let observeFootprint: @Sendable (
        InstalledConflictFootprint
    ) -> ConflictFootprintObservation

    public init(
        _ observeFootprint: @escaping @Sendable (
            InstalledConflictFootprint
        ) -> ConflictFootprintObservation
    ) {
        self.observeFootprint = observeFootprint
    }

    public func observe(
        _ footprint: InstalledConflictFootprint
    ) -> ConflictFootprintObservation {
        observeFootprint(footprint)
    }

    public static let live = ConflictFootprintProvider { footprint in
        ConflictFootprintTraversal.observe(footprint)
    }
}

private enum ConflictFootprintTraversal {
    static func observe(
        _ footprint: InstalledConflictFootprint
    ) -> ConflictFootprintObservation {
        guard footprint.isValid else {
            return .incomplete(.invalidPolicy)
        }
        let components = footprint.absolutePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            return .incomplete(.invalidPolicy)
        }

        let rootFD = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard rootFD >= 0 else {
            return .incomplete(.metadataUnavailable)
        }
        var directoryDescriptors = [rootFD]
        var openedComponents: [String] = []
        defer {
            for descriptor in directoryDescriptors.reversed() {
                Darwin.close(descriptor)
            }
        }

        for (index, component) in components.enumerated() {
            guard let directoryFD = directoryDescriptors.last else {
                return .incomplete(.metadataUnavailable)
            }
            let isTerminal = index == components.index(before: components.endIndex)
            let openedFD = Darwin.openat(
                directoryFD,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            if openedFD >= 0 {
                if isTerminal {
                    Darwin.close(openedFD)
                    return .presentConflict
                }
                directoryDescriptors.append(openedFD)
                openedComponents.append(component)
                continue
            }

            let openError = errno
            var metadata = stat()
            if Darwin.fstatat(
                directoryFD,
                component,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0 {
                let fileType = metadata.st_mode & mode_t(S_IFMT)
                if fileType == mode_t(S_IFLNK) {
                    return .incomplete(.symbolicLink)
                }
                if isTerminal {
                    return .presentConflict
                }
                if fileType != mode_t(S_IFDIR) {
                    return .incomplete(.notDirectory)
                }
                if openError == EACCES || openError == EPERM {
                    return .incomplete(.permissionDenied)
                }
                return .incomplete(.changedDuringRead)
            }

            let metadataError = errno
            if openError == ENOENT && metadataError == ENOENT {
                if let failure = stableTraversalFailure(
                    descriptors: directoryDescriptors,
                    components: openedComponents
                ) {
                    return .incomplete(failure)
                }
                return .absent
            }
            if openError == EACCES || openError == EPERM
                || metadataError == EACCES || metadataError == EPERM
            {
                return .incomplete(.permissionDenied)
            }
            if openError == ENOENT || metadataError == ENOENT {
                return .incomplete(.changedDuringRead)
            }
            return .incomplete(.metadataUnavailable)
        }
        return .incomplete(.metadataUnavailable)
    }

    private static func stableTraversalFailure(
        descriptors: [Int32],
        components: [String]
    ) -> ConflictFootprintIncompleteReason? {
        guard descriptors.count == components.count + 1 else {
            return .changedDuringRead
        }
        for index in components.indices {
            var openedMetadata = stat()
            guard Darwin.fstat(descriptors[index + 1], &openedMetadata) == 0 else {
                return metadataFailure(errno)
            }

            var linkedMetadata = stat()
            guard Darwin.fstatat(
                descriptors[index],
                components[index],
                &linkedMetadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                return errno == ENOENT
                    ? .changedDuringRead
                    : metadataFailure(errno)
            }
            let linkedType = linkedMetadata.st_mode & mode_t(S_IFMT)
            guard linkedType == mode_t(S_IFDIR),
                  openedMetadata.st_dev == linkedMetadata.st_dev,
                  openedMetadata.st_ino == linkedMetadata.st_ino
            else {
                return .changedDuringRead
            }
        }
        return nil
    }

    private static func metadataFailure(
        _ error: Int32
    ) -> ConflictFootprintIncompleteReason {
        error == EACCES || error == EPERM
            ? .permissionDenied
            : .metadataUnavailable
    }
}

private enum ConflictCatalogValidation {
    static func isSafeToken(_ token: String) -> Bool {
        let scalars = token.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 128 else {
            return false
        }
        return scalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }

    static func isSafeBundleIdentifier(_ identifier: String) -> Bool {
        let scalars = identifier.unicodeScalars
        guard scalars.count <= 255,
              identifier.contains("."),
              !identifier.hasPrefix("."),
              !identifier.hasSuffix("."),
              !identifier.contains("..")
        else {
            return false
        }
        return isSafeToken(identifier)
    }

    static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path != "/",
              path.utf8.count <= 1_024,
              !path.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.first?.isEmpty == true, components.count >= 2 else {
            return false
        }
        return components.dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
