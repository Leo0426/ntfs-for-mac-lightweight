import Foundation
import NTFSLiteStrictJSON

public enum HelperProtocolVersion: UInt16, Codable, Equatable, Sendable {
    case v1 = 1

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(UInt16.self)
        guard let version = Self(rawValue: rawValue) else {
            throw HelperRequestRejection.unsupportedSchemaVersion
        }
        self = version
    }
}

public enum HelperRequestRejection: UInt16, Codable, Equatable, Error, Sendable {
    case malformedEnvelope = 1
    case unsupportedSchemaVersion = 2
    case unknownAction = 3
    case invalidOperationID = 4
    case replayedOperation = 5
    case invalidIdentity = 6
    case unexpectedField = 7
    case actionTargetMismatch = 8
    case operationCapacityReached = 9

    public var responseCode: HelperResultCode {
        switch self {
        case .malformedEnvelope:
            .rejectedMalformedEnvelope
        case .unsupportedSchemaVersion:
            .rejectedUnsupportedSchema
        case .unknownAction:
            .rejectedUnknownAction
        case .invalidOperationID:
            .rejectedInvalidOperationID
        case .replayedOperation:
            .rejectedReplayedOperation
        case .invalidIdentity:
            .rejectedInvalidIdentity
        case .unexpectedField:
            .rejectedUnexpectedField
        case .actionTargetMismatch:
            .rejectedActionTargetMismatch
        case .operationCapacityReached:
            .rejectedOperationCapacity
        }
    }
}

public enum HelperProtocolLimits {
    public static let maximumRequestBytes = 4_096
    public static let maximumResponseBytes = 256
    public static let maximumOperationIDBytes = 128
    public static let maximumBSDNameBytes = 32
    public static let maximumConsumedOperationIDs = 4_096
}

public struct HelperOperationID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init() {
        self.rawValue = UUID().uuidString.lowercased()
    }

    public init(validating rawValue: String) throws {
        let bytes = rawValue.utf8
        guard !bytes.isEmpty,
              bytes.count <= HelperProtocolLimits.maximumOperationIDBytes,
              bytes.allSatisfy(isAllowedOperationIDByte)
        else {
            throw HelperRequestRejection.invalidOperationID
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct HelperDiskInstanceIdentity: Codable, Equatable, Sendable {
    public let physicalDiskBSDName: String
    public let mediaGeneration: UInt64

    public init(
        physicalDiskBSDName: String,
        mediaGeneration: UInt64
    ) throws {
        guard isValidWholeDiskBSDName(physicalDiskBSDName),
              mediaGeneration > 0
        else {
            throw HelperRequestRejection.invalidIdentity
        }
        self.physicalDiskBSDName = physicalDiskBSDName
        self.mediaGeneration = mediaGeneration
    }

    public init(from decoder: Decoder) throws {
        try rejectUnexpectedKeys(
            from: decoder,
            allowed: ["physicalDiskBSDName", "mediaGeneration"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            physicalDiskBSDName: container.decode(
                String.self,
                forKey: .physicalDiskBSDName
            ),
            mediaGeneration: container.decode(
                UInt64.self,
                forKey: .mediaGeneration
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case physicalDiskBSDName
        case mediaGeneration
    }
}

public struct HelperVolumeInstanceIdentity: Codable, Equatable, Sendable {
    public let volumeUUID: String
    public let volumeBSDName: String
    public let disk: HelperDiskInstanceIdentity

    public init(
        volumeUUID: String,
        volumeBSDName: String,
        disk: HelperDiskInstanceIdentity
    ) throws {
        guard let canonicalUUID = canonicalUUIDString(volumeUUID),
              isValidVolumeBSDName(volumeBSDName, on: disk.physicalDiskBSDName)
        else {
            throw HelperRequestRejection.invalidIdentity
        }
        self.volumeUUID = canonicalUUID
        self.volumeBSDName = volumeBSDName
        self.disk = disk
    }

    public init(from decoder: Decoder) throws {
        try rejectUnexpectedKeys(
            from: decoder,
            allowed: ["volumeUUID", "volumeBSDName", "disk"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            volumeUUID: container.decode(String.self, forKey: .volumeUUID),
            volumeBSDName: container.decode(String.self, forKey: .volumeBSDName),
            disk: container.decode(
                HelperDiskInstanceIdentity.self,
                forKey: .disk
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case volumeUUID
        case volumeBSDName
        case disk
    }
}

public enum HelperAction: String, Codable, Equatable, Sendable {
    case mountReadWrite
    case unmountVolume
    case unmountDisk
    case ejectDisk

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let action = Self(rawValue: rawValue) else {
            throw HelperRequestRejection.unknownAction
        }
        self = action
    }
}

public enum HelperTarget: Codable, Equatable, Sendable {
    case disk(HelperDiskInstanceIdentity)
    case volume(HelperVolumeInstanceIdentity)

    public init(from decoder: Decoder) throws {
        try rejectUnexpectedKeys(
            from: decoder,
            allowed: ["kind", "disk", "volume"]
        )
        let kindContainer = try decoder.container(keyedBy: KindCodingKeys.self)
        let kind = try kindContainer.decode(String.self, forKey: .kind)

        switch kind {
        case "disk":
            try rejectUnexpectedKeys(from: decoder, allowed: ["kind", "disk"])
            let container = try decoder.container(keyedBy: DiskCodingKeys.self)
            self = .disk(
                try container.decode(
                    HelperDiskInstanceIdentity.self,
                    forKey: .disk
                )
            )
        case "volume":
            try rejectUnexpectedKeys(from: decoder, allowed: ["kind", "volume"])
            let container = try decoder.container(keyedBy: VolumeCodingKeys.self)
            self = .volume(
                try container.decode(
                    HelperVolumeInstanceIdentity.self,
                    forKey: .volume
                )
            )
        default:
            throw HelperRequestRejection.invalidIdentity
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .disk(identity):
            var container = encoder.container(keyedBy: DiskCodingKeys.self)
            try container.encode("disk", forKey: .kind)
            try container.encode(identity, forKey: .disk)
        case let .volume(identity):
            var container = encoder.container(keyedBy: VolumeCodingKeys.self)
            try container.encode("volume", forKey: .kind)
            try container.encode(identity, forKey: .volume)
        }
    }

    private enum KindCodingKeys: String, CodingKey {
        case kind
    }

    private enum DiskCodingKeys: String, CodingKey {
        case kind
        case disk
    }

    private enum VolumeCodingKeys: String, CodingKey {
        case kind
        case volume
    }
}

public struct HelperRequestEnvelope: Encodable, Equatable, Sendable {
    public let schemaVersion: HelperProtocolVersion
    public let operationID: HelperOperationID
    public let action: HelperAction
    public let target: HelperTarget

    public init(
        operationID: HelperOperationID,
        action: HelperAction,
        target: HelperTarget
    ) throws {
        guard action.accepts(target) else {
            throw HelperRequestRejection.actionTargetMismatch
        }
        self.schemaVersion = .v1
        self.operationID = operationID
        self.action = action
        self.target = target
    }
}

/// A request that passed strict decoding and consumed its operation ID in the
/// process-lifetime admission actor. There is deliberately no public
/// initializer or decoding conformance: callers cannot manufacture an admitted
/// request by decoding or constructing a wire envelope themselves.
public struct AdmittedHelperRequest: Equatable, Sendable {
    public let schemaVersion: HelperProtocolVersion
    public let operationID: HelperOperationID
    public let action: HelperAction
    public let target: HelperTarget

    fileprivate init(_ request: HelperRequestEnvelope) {
        self.schemaVersion = request.schemaVersion
        self.operationID = request.operationID
        self.action = request.action
        self.target = request.target
    }
}

/// The helper's only public request-admission entry point.
///
/// The singleton first validates the raw JSON boundary, then decodes and
/// validates the fixed protocol, and finally consumes the operation ID without
/// an actor suspension point. A helper executor should accept only
/// `AdmittedHelperRequest`, never `HelperRequestEnvelope`.
public actor HelperRequestAdmission {
    public static let processLifetime = HelperRequestAdmission()

    private var consumedOperationIDs: Set<HelperOperationID> = []

    private init() {}

    public func admit(
        _ data: Data
    ) -> Result<AdmittedHelperRequest, HelperRequestRejection> {
        let decodedRequest = HelperRequestDecoder().decode(data)
        switch decodedRequest {
        case let .failure(rejection):
            return .failure(rejection)
        case let .success(request):
            if consumedOperationIDs.contains(request.operationID) {
                return .failure(.replayedOperation)
            }
            guard consumedOperationIDs.count
                < HelperProtocolLimits.maximumConsumedOperationIDs
            else {
                return .failure(.operationCapacityReached)
            }
            consumedOperationIDs.insert(request.operationID)
            return .success(AdmittedHelperRequest(request))
        }
    }
}

private struct HelperRequestWireEnvelope: Decodable {
    let request: HelperRequestEnvelope

    init(from decoder: Decoder) throws {
        try rejectUnexpectedKeys(
            from: decoder,
            allowed: ["schemaVersion", "operationID", "action", "target"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(
            HelperProtocolVersion.self,
            forKey: .schemaVersion
        )
        let operationID = try container.decode(
            HelperOperationID.self,
            forKey: .operationID
        )
        let action = try container.decode(HelperAction.self, forKey: .action)
        let target = try container.decode(HelperTarget.self, forKey: .target)
        let request = try HelperRequestEnvelope(
            operationID: operationID,
            action: action,
            target: target
        )
        guard request.schemaVersion == version else {
            throw HelperRequestRejection.unsupportedSchemaVersion
        }
        self.request = request
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case operationID
        case action
        case target
    }
}

private struct HelperRequestDecoder: Sendable {
    func decode(
        _ data: Data
    ) -> Result<HelperRequestEnvelope, HelperRequestRejection> {
        guard !data.isEmpty,
              data.count <= HelperProtocolLimits.maximumRequestBytes
        else {
            return .failure(.malformedEnvelope)
        }
        guard StrictJSONEnvelopeValidator.accepts(data) else {
            return .failure(.malformedEnvelope)
        }

        do {
            let wireEnvelope = try JSONDecoder().decode(
                HelperRequestWireEnvelope.self,
                from: data
            )
            return .success(wireEnvelope.request)
        } catch let rejection as HelperRequestRejection {
            return .failure(rejection)
        } catch {
            return .failure(.malformedEnvelope)
        }
    }
}

public enum HelperResultCode: Int32, Codable, Equatable, Sendable {
    case succeeded = 0
    case rejectedMalformedEnvelope = 10
    case rejectedUnsupportedSchema = 11
    case rejectedUnknownAction = 12
    case rejectedInvalidOperationID = 13
    case rejectedReplayedOperation = 14
    case rejectedInvalidIdentity = 15
    case rejectedUnexpectedField = 16
    case rejectedActionTargetMismatch = 17
    case rejectedOperationCapacity = 18
    case executionFailed = 20
    case postconditionFailed = 21

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int32.self)
        guard let resultCode = Self(rawValue: rawValue) else {
            throw HelperRequestRejection.malformedEnvelope
        }
        self = resultCode
    }
}

/// A fixed, non-sensitive reason for rejecting a helper response envelope.
///
/// These values are safe to record in diagnostics. They deliberately contain
/// no free-form text from a helper or an underlying process.
public enum HelperResponseRejection: UInt16, Codable, Equatable, Error, Sendable {
    case malformedEnvelope = 1
    case responseTooLarge = 2
    case unsupportedSchemaVersion = 3
    case unknownResultCode = 4
    case unexpectedField = 5
    case invalidResultSemantics = 6
}

public struct HelperResponseEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: HelperProtocolVersion
    public let resultCode: HelperResultCode
    public let exitStatus: Int32

    public init(resultCode: HelperResultCode, exitStatus: Int32) {
        self.schemaVersion = .v1
        self.resultCode = resultCode
        self.exitStatus = exitStatus
    }

    public init(from decoder: Decoder) throws {
        try rejectUnexpectedResponseKeys(
            from: decoder,
            allowed: ["schemaVersion", "resultCode", "exitStatus"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSchemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard let schemaVersion = HelperProtocolVersion(
            rawValue: rawSchemaVersion
        ) else {
            throw HelperResponseRejection.unsupportedSchemaVersion
        }

        let rawResultCode = try container.decode(
            Int32.self,
            forKey: .resultCode
        )
        guard let resultCode = HelperResultCode(rawValue: rawResultCode) else {
            throw HelperResponseRejection.unknownResultCode
        }

        let exitStatus = try container.decode(Int32.self, forKey: .exitStatus)
        guard resultCode.accepts(exitStatus: exitStatus) else {
            throw HelperResponseRejection.invalidResultSemantics
        }

        self.schemaVersion = schemaVersion
        self.resultCode = resultCode
        self.exitStatus = exitStatus
    }

    public func encode(to encoder: Encoder) throws {
        guard resultCode.accepts(exitStatus: exitStatus) else {
            throw HelperResponseRejection.invalidResultSemantics
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion.rawValue, forKey: .schemaVersion)
        try container.encode(resultCode.rawValue, forKey: .resultCode)
        try container.encode(exitStatus, forKey: .exitStatus)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case resultCode
        case exitStatus
    }
}

public struct HelperResponseDecoder: Sendable {
    public init() {}

    public func decode(
        _ data: Data
    ) -> Result<HelperResponseEnvelope, HelperResponseRejection> {
        guard !data.isEmpty else {
            return .failure(.malformedEnvelope)
        }
        guard data.count <= HelperProtocolLimits.maximumResponseBytes else {
            return .failure(.responseTooLarge)
        }
        guard StrictJSONEnvelopeValidator.accepts(data) else {
            return .failure(.malformedEnvelope)
        }

        do {
            return .success(
                try JSONDecoder().decode(
                    HelperResponseEnvelope.self,
                    from: data
                )
            )
        } catch let rejection as HelperResponseRejection {
            return .failure(rejection)
        } catch {
            return .failure(.malformedEnvelope)
        }
    }
}

private extension HelperResultCode {
    func accepts(exitStatus: Int32) -> Bool {
        switch self {
        case .succeeded:
            exitStatus == 0
        case .postconditionFailed:
            true
        case .rejectedMalformedEnvelope,
            .rejectedUnsupportedSchema,
            .rejectedUnknownAction,
            .rejectedInvalidOperationID,
            .rejectedReplayedOperation,
            .rejectedInvalidIdentity,
            .rejectedUnexpectedField,
            .rejectedActionTargetMismatch,
            .rejectedOperationCapacity,
            .executionFailed:
            exitStatus != 0
        }
    }
}

private extension HelperAction {
    func accepts(_ target: HelperTarget) -> Bool {
        switch (self, target) {
        case (.mountReadWrite, .volume),
            (.unmountVolume, .volume),
            (.unmountDisk, .disk),
            (.ejectDisk, .disk):
            true
        default:
            false
        }
    }
}

private struct AnyHelperCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnexpectedKeys(
    from decoder: Decoder,
    allowed: Set<String>
) throws {
    let container = try decoder.container(keyedBy: AnyHelperCodingKey.self)
    guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw HelperRequestRejection.unexpectedField
    }
}

private func rejectUnexpectedResponseKeys(
    from decoder: Decoder,
    allowed: Set<String>
) throws {
    let container = try decoder.container(keyedBy: AnyHelperCodingKey.self)
    guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw HelperResponseRejection.unexpectedField
    }
}

private enum StrictJSONEnvelopeValidator {
    static func accepts(_ data: Data) -> Bool {
        StrictJSONObjectValidator.accepts(data)
    }
}

private func isAllowedOperationIDByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 45, 48 ... 57, 65 ... 90, 95, 97 ... 122:
        true
    default:
        false
    }
}

private func isValidWholeDiskBSDName(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    let prefix = Array("disk".utf8)
    guard bytes.count > prefix.count,
          bytes.count <= HelperProtocolLimits.maximumBSDNameBytes,
          Array(bytes.prefix(prefix.count)) == prefix
    else {
        return false
    }
    return bytes.dropFirst(prefix.count).allSatisfy { (48 ... 57).contains($0) }
}

private func isValidVolumeBSDName(
    _ value: String,
    on physicalDiskBSDName: String
) -> Bool {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty,
          bytes.count <= HelperProtocolLimits.maximumBSDNameBytes,
          value == physicalDiskBSDName || value.hasPrefix(physicalDiskBSDName + "s")
    else {
        return false
    }

    if value == physicalDiskBSDName {
        return true
    }

    let suffix = value.dropFirst(physicalDiskBSDName.count)
    guard suffix.first == "s" else {
        return false
    }
    let partitionDigits = suffix.dropFirst()
    return !partitionDigits.isEmpty
        && partitionDigits.utf8.allSatisfy { (48 ... 57).contains($0) }
}

private func canonicalUUIDString(_ value: String) -> String? {
    guard value.utf8.count == 36, let uuid = UUID(uuidString: value) else {
        return nil
    }
    return uuid.uuidString.lowercased()
}
