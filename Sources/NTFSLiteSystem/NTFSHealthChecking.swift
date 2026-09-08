import Foundation
import NTFSLiteCore

/// The bounded outcome of a health probe launched by a separate adapter.
///
/// This type deliberately contains no executable, argument, device, or path.
/// It is only evidence for the parser below.
public enum NTFSHealthProbeCompletion: Equatable, Sendable {
    case exited(Int32)
    case timedOut
    case truncated
    case unreadable
    case launchFailed
}

/// Captured output from the fixed, read-only NTFS health probe protocol.
public struct NTFSHealthProbeOutput: Equatable, Sendable {
    public let completion: NTFSHealthProbeCompletion
    public let standardOutput: String
    public let standardError: String

    public init(
        completion: NTFSHealthProbeCompletion,
        standardOutput: String,
        standardError: String = ""
    ) {
        self.completion = completion
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

}

/// Parses version 1 of the machine-readable NTFS health probe protocol.
///
/// A successful probe must emit exactly one canonical record, including its
/// terminating line feed, and nothing on standard error. All other evidence
/// maps to `.unknown`; natural-language output is intentionally unsupported.
public enum NTFSHealthProbeV1OutputParser {
    public static let cleanRecord = "NTFS-LITE-HEALTH/1 clean\n"
    public static let dirtyRecord = "NTFS-LITE-HEALTH/1 dirty\n"
    public static let hibernatedRecord = "NTFS-LITE-HEALTH/1 hibernated\n"
    public static let unknownRecord = "NTFS-LITE-HEALTH/1 unknown\n"

    public static func parse(_ output: NTFSHealthProbeOutput) -> VolumeHealth {
        guard output.completion == .exited(0),
              output.standardError.isEmpty,
              output.standardOutput.utf8.count <= maximumOutputSize,
              !output.standardOutput.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            return .unknown
        }

        switch output.standardOutput {
        case cleanRecord:
            return .clean
        case dirtyRecord:
            return .dirty
        case hibernatedRecord:
            return .hibernated
        case unknownRecord:
            return .unknown
        default:
            return .unknown
        }
    }

    private static let maximumOutputSize = 128
}
