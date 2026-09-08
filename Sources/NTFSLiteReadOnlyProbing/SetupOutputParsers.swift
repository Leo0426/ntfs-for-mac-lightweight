import Foundation
import NTFSLiteCore

public struct SetupCommandOutput: Equatable, Sendable {
    public let standardOutput: String
    public let standardError: String
    public let terminationStatus: Int32
    public let wasTruncated: Bool

    public init(
        standardOutput: String,
        standardError: String = "",
        terminationStatus: Int32,
        wasTruncated: Bool
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationStatus = terminationStatus
        self.wasTruncated = wasTruncated
    }
}

public enum SetupOutputParseFailure: Equatable, Sendable {
    case commandFailed
    case truncated
    case invalidAllowlist
    case unexpectedOutput
    case duplicateRecord
    case inconsistentRecordCount
}

public enum SetupOutputParseResult<Value: Equatable & Sendable>: Equatable, Sendable {
    case parsed(Value)
    case failedClosed(SetupOutputParseFailure)
}

public enum NTFS3GVersionParser {
    public static func parse(
        _ output: SetupCommandOutput
    ) -> SetupOutputParseResult<SemanticVersion> {
        if let failure = SetupOutputParserSupport.completionFailure(for: output) {
            return .failedClosed(failure)
        }

        guard let lines = SetupOutputParserSupport.lines(
            joining: output.standardOutput,
            and: output.standardError
        ) else {
            return .failedClosed(.unexpectedOutput)
        }

        let prefix = "ntfs-3g "
        var versions: [SemanticVersion] = []

        for line in lines {
            let normalized = line.trimmingCharacters(in: .whitespaces)
            guard normalized.hasPrefix(prefix) else {
                continue
            }

            let remainder = normalized.dropFirst(prefix.count)
            guard let token = remainder.split(whereSeparator: \.isWhitespace).first,
                  let version = SetupOutputParserSupport.semanticVersion(
                      fromStrictToken: String(token)
                  )
            else {
                return .failedClosed(.unexpectedOutput)
            }
            versions.append(version)
        }

        guard versions.count == 1 else {
            return .failedClosed(versions.isEmpty ? .unexpectedOutput : .duplicateRecord)
        }
        return .parsed(versions[0])
    }
}

public enum PlugInKitElection: Equatable, Sendable {
    case defaultElection
    case use
    case ignore
    case debuggerUse
    case superseded
}

public struct PlugInKitRecord: Equatable, Sendable {
    public let identifier: String
    public let election: PlugInKitElection

    public init(identifier: String, election: PlugInKitElection) {
        self.identifier = identifier
        self.election = election
    }
}

public enum PlugInKitListingParser {
    public static func parse(
        _ output: SetupCommandOutput,
        allowedIdentifiers: Set<String>
    ) -> SetupOutputParseResult<[PlugInKitRecord]> {
        if let failure = SetupOutputParserSupport.listingFailure(
            for: output,
            allowedIdentifiers: allowedIdentifiers
        ) {
            return .failedClosed(failure)
        }
        guard let lines = SetupOutputParserSupport.lines(in: output.standardOutput) else {
            return .failedClosed(.unexpectedOutput)
        }

        var recordsByIdentifier: [String: PlugInKitRecord] = [:]
        for line in lines {
            let normalized = line.trimmingCharacters(in: .whitespaces)
            guard !normalized.isEmpty else {
                continue
            }
            guard let record = record(from: normalized),
                  allowedIdentifiers.contains(record.identifier)
            else {
                return .failedClosed(.unexpectedOutput)
            }
            guard recordsByIdentifier.updateValue(record, forKey: record.identifier) == nil else {
                return .failedClosed(.duplicateRecord)
            }
        }

        return .parsed(recordsByIdentifier.values.sorted { $0.identifier < $1.identifier })
    }

    private static func record(from line: String) -> PlugInKitRecord? {
        var remainder = line[...]
        let election: PlugInKitElection

        switch remainder.first {
        case "+":
            election = .use
        case "-":
            election = .ignore
        case "!":
            election = .debuggerUse
        case "=":
            election = .superseded
        case "?":
            return nil
        default:
            election = .defaultElection
        }

        if election != .defaultElection {
            remainder.removeFirst()
            guard remainder.first?.isWhitespace == true else {
                return nil
            }
            remainder = remainder.drop(while: \.isWhitespace)
        }

        guard let versionStart = remainder.firstIndex(of: "(") else {
            return nil
        }
        let identifier = String(remainder[..<versionStart])
            .trimmingCharacters(in: .whitespaces)
        let versionDescription = String(remainder[versionStart...])

        guard SetupOutputParserSupport.isSafeBundleIdentifier(identifier),
              SetupOutputParserSupport.isParenthesizedToken(versionDescription)
        else {
            return nil
        }
        return PlugInKitRecord(identifier: identifier, election: election)
    }
}

public enum SystemExtensionState: Equatable, Sendable {
    case activatedEnabled
    case activatedWaitingForUser
    case activatedDisabled
    case terminatedWaitingForUninstallOnReboot
}

public struct SystemExtensionRecord: Equatable, Sendable {
    public let identifier: String
    public let isEnabled: Bool
    public let isActive: Bool
    public let state: SystemExtensionState

    public init(
        identifier: String,
        isEnabled: Bool,
        isActive: Bool,
        state: SystemExtensionState
    ) {
        self.identifier = identifier
        self.isEnabled = isEnabled
        self.isActive = isActive
        self.state = state
    }
}

public enum SystemExtensionListingParser {
    public static func parse(
        _ output: SetupCommandOutput,
        allowedIdentifiers: Set<String>
    ) -> SetupOutputParseResult<[SystemExtensionRecord]> {
        if let failure = SetupOutputParserSupport.listingFailure(
            for: output,
            allowedIdentifiers: allowedIdentifiers
        ) {
            return .failedClosed(failure)
        }
        guard let lines = SetupOutputParserSupport.lines(in: output.standardOutput) else {
            return .failedClosed(.unexpectedOutput)
        }

        let nonemptyLines = lines.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard let header = nonemptyLines.first,
              let expectedCount = extensionCount(from: header)
        else {
            return .failedClosed(.unexpectedOutput)
        }

        var allIdentifiers: Set<String> = []
        var allowedRecords: [SystemExtensionRecord] = []
        var observedCount = 0

        for line in nonemptyLines.dropFirst() {
            let normalized = line.trimmingCharacters(in: .whitespaces)
            if normalized.hasPrefix("--- ") || isColumnHeader(normalized) {
                continue
            }
            guard let record = record(from: normalized) else {
                return .failedClosed(.unexpectedOutput)
            }
            guard allIdentifiers.insert(record.identifier).inserted else {
                return .failedClosed(.duplicateRecord)
            }
            observedCount += 1
            if allowedIdentifiers.contains(record.identifier) {
                allowedRecords.append(record)
            }
        }

        guard observedCount == expectedCount else {
            return .failedClosed(.inconsistentRecordCount)
        }
        return .parsed(allowedRecords.sorted { $0.identifier < $1.identifier })
    }

    private static func extensionCount(from line: String) -> Int? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2,
              fields[1] == "extension(s)",
              let count = Int(fields[0]),
              count >= 0,
              count <= SetupOutputParserSupport.maximumRecordCount
        else {
            return nil
        }
        return count
    }

    private static func isColumnHeader(_ line: String) -> Bool {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            == "enabled active teamID bundleID (version) name [state]"
    }

    private static func record(from line: String) -> SystemExtensionRecord? {
        guard line.hasSuffix("]"),
              let stateStart = line.lastIndex(of: "[")
        else {
            return nil
        }

        let stateDescription = String(line[line.index(after: stateStart)..<line.index(before: line.endIndex)])
        let state: SystemExtensionState
        switch stateDescription {
        case "activated enabled":
            state = .activatedEnabled
        case "activated waiting for user":
            state = .activatedWaitingForUser
        case "activated disabled":
            state = .activatedDisabled
        case "terminated waiting for uninstall on reboot":
            state = .terminatedWaitingForUninstallOnReboot
        default:
            return nil
        }

        let fields = line[..<stateStart].split(whereSeparator: \.isWhitespace)
        guard fields.count >= 6,
              let isEnabled = flag(fields[0]),
              let isActive = flag(fields[1])
        else {
            return nil
        }

        let identifier = String(fields[3])
        guard SetupOutputParserSupport.isSafeBundleIdentifier(identifier),
              SetupOutputParserSupport.isParenthesizedToken(String(fields[4]))
        else {
            return nil
        }

        return SystemExtensionRecord(
            identifier: identifier,
            isEnabled: isEnabled,
            isActive: isActive,
            state: state
        )
    }

    private static func flag(_ field: Substring) -> Bool? {
        switch field {
        case "*": true
        case "-": false
        default: nil
        }
    }
}

public struct LoadedKextRecord: Equatable, Sendable {
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}

public enum LoadedKextParser {
    public static func parse(
        _ output: SetupCommandOutput,
        allowedIdentifiers: Set<String>
    ) -> SetupOutputParseResult<[LoadedKextRecord]> {
        if let failure = SetupOutputParserSupport.completionFailure(for: output) {
            return .failedClosed(failure)
        }
        guard SetupOutputParserSupport.validAllowlist(allowedIdentifiers),
              let lines = SetupOutputParserSupport.lines(
                  joining: output.standardOutput,
                  and: output.standardError
              )
        else {
            return .failedClosed(
                SetupOutputParserSupport.validAllowlist(allowedIdentifiers)
                    ? .unexpectedOutput
                    : .invalidAllowlist
            )
        }

        var allIdentifiers: Set<String> = []
        var allowedRecords: [LoadedKextRecord] = []
        var observedRecord = false

        for line in lines {
            let normalized = line.trimmingCharacters(in: .whitespaces)
            guard !normalized.isEmpty else {
                continue
            }
            if normalized == "No variant specified, falling back to release"
                || isColumnHeader(normalized)
            {
                continue
            }
            guard let identifier = identifier(from: normalized) else {
                return .failedClosed(.unexpectedOutput)
            }
            observedRecord = true
            guard allIdentifiers.insert(identifier).inserted else {
                return .failedClosed(.duplicateRecord)
            }
            if allowedIdentifiers.contains(identifier) {
                allowedRecords.append(LoadedKextRecord(identifier: identifier))
            }
        }

        guard observedRecord else {
            return .failedClosed(.unexpectedOutput)
        }
        return .parsed(allowedRecords.sorted { $0.identifier < $1.identifier })
    }

    private static func isColumnHeader(_ line: String) -> Bool {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            == "Index Refs Address Size Wired Name (Version) UUID <Linked Against>"
    }

    private static func identifier(from line: String) -> String? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 9,
              Int(fields[0]) != nil,
              Int(fields[1]) != nil,
              fields[2...4].allSatisfy(SetupOutputParserSupport.isUnsignedNumericToken),
              SetupOutputParserSupport.isParenthesizedToken(String(fields[6])),
              UUID(uuidString: String(fields[7])) != nil
        else {
            return nil
        }

        let identifier = String(fields[5])
        let linkedIdentifiers = fields[8...].joined(separator: " ")
        guard SetupOutputParserSupport.isSafeBundleIdentifier(identifier),
              linkedIdentifiers.hasPrefix("<"),
              linkedIdentifiers.hasSuffix(">")
        else {
            return nil
        }
        return identifier
    }
}

private enum SetupOutputParserSupport {
    static let maximumRecordCount = 10_000
    private static let maximumOutputSize = 1_048_576
    private static let maximumLineSize = 16_384

    static func completionFailure(
        for output: SetupCommandOutput
    ) -> SetupOutputParseFailure? {
        if output.wasTruncated {
            return .truncated
        }
        if output.terminationStatus != 0 {
            return .commandFailed
        }
        return nil
    }

    static func listingFailure(
        for output: SetupCommandOutput,
        allowedIdentifiers: Set<String>
    ) -> SetupOutputParseFailure? {
        if let failure = completionFailure(for: output) {
            return failure
        }
        guard validAllowlist(allowedIdentifiers) else {
            return .invalidAllowlist
        }
        guard output.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unexpectedOutput
        }
        return nil
    }

    static func validAllowlist(_ identifiers: Set<String>) -> Bool {
        !identifiers.isEmpty && identifiers.allSatisfy(isSafeBundleIdentifier)
    }

    static func lines(in text: String) -> [String]? {
        guard text.utf8.count <= maximumOutputSize,
              !text.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            return nil
        }

        let lines = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        )
            .map(String.init)
        guard lines.allSatisfy({ $0.utf8.count <= maximumLineSize }) else {
            return nil
        }
        return lines
    }

    static func lines(joining first: String, and second: String) -> [String]? {
        guard let firstLines = lines(in: first),
              let secondLines = lines(in: second),
              first.utf8.count + second.utf8.count <= maximumOutputSize
        else {
            return nil
        }
        return firstLines + secondLines
    }

    static func semanticVersion(fromStrictToken token: String) -> SemanticVersion? {
        let fields = token.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields.allSatisfy({
                  !$0.isEmpty && $0.unicodeScalars.allSatisfy { scalar in
                      scalar.value >= 48 && scalar.value <= 57
                  }
              }),
              let major = Int(fields[0]),
              let minor = Int(fields[1]),
              let patch = Int(fields[2])
        else {
            return nil
        }
        return SemanticVersion(major: major, minor: minor, patch: patch)
    }

    static func isSafeBundleIdentifier(_ identifier: String) -> Bool {
        let scalars = identifier.unicodeScalars
        guard !scalars.isEmpty,
              scalars.count <= 255,
              identifier.contains("."),
              !identifier.hasPrefix("."),
              !identifier.hasSuffix("."),
              !identifier.contains("..")
        else {
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

    static func isParenthesizedToken(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        guard scalars.count >= 3,
              scalars.count <= 128,
              scalars.first?.value == 40,
              scalars.last?.value == 41
        else {
            return false
        }

        var depth = 0
        for (index, scalar) in scalars.enumerated() {
            switch scalar.value {
            case 40:
                depth += 1
            case 41:
                depth -= 1
                if depth < 0 || (depth == 0 && index != scalars.index(before: scalars.endIndex)) {
                    return false
                }
            case 33...126:
                guard depth > 0 else {
                    return false
                }
            default:
                return false
            }
        }
        return depth == 0
    }

    static func isUnsignedNumericToken(_ token: Substring) -> Bool {
        guard !token.isEmpty else {
            return false
        }
        if token == "0" {
            return true
        }
        if token.hasPrefix("0x") {
            let digits = token.dropFirst(2)
            return !digits.isEmpty && digits.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 48...57, 65...70, 97...102:
                    true
                default:
                    false
                }
            }
        }
        return token.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 48 && scalar.value <= 57
        }
    }
}
