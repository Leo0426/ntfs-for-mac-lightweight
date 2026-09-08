import Foundation

/// The only human policy statement this flow accepts. It deliberately does
/// not classify the volume as system evidence.
public enum DataVolumeDeclarationMeaning: Equatable, Sendable {
    case selectedVolumeIsDataAndNotWindowsBootOrSystemVolume
}

public struct DataVolumeDeclarationSessionID: Equatable, Hashable, Sendable {
    fileprivate let rawValue: UUID

    fileprivate init() {
        rawValue = UUID()
    }
}

public struct DataVolumeObservationRevision: Equatable, Hashable, Sendable {
    fileprivate let rawValue: UUID

    fileprivate init() {
        rawValue = UUID()
    }
}

/// A request nonce is distinct from a reusable mutation `OperationID`.
public struct DataVolumeRequestNonce: Equatable, Hashable, Sendable {
    fileprivate let rawValue: UUID

    fileprivate init() {
        rawValue = UUID()
    }
}

public struct SiblingVolumeRoleFact: Equatable, Sendable {
    public let instanceID: VolumeInstanceID
    public let location: VolumeLocation
    public let roleEvidence: VolumeRoleEvidence

    public init(
        instanceID: VolumeInstanceID,
        location: VolumeLocation,
        roleEvidence: VolumeRoleEvidence
    ) {
        self.instanceID = instanceID
        self.location = location
        self.roleEvidence = roleEvidence
    }
}

/// Fresh role and topology facts for one selected read-only candidate.
public struct DataVolumeRoleObservation: Equatable, Sendable {
    public let candidate: ReadOnlyVolumeCandidate
    public let siblingFacts: [SiblingVolumeRoleFact]
    public let isComplete: Bool

    public init(
        candidate: ReadOnlyVolumeCandidate,
        siblingFacts: [SiblingVolumeRoleFact],
        isComplete: Bool
    ) {
        self.candidate = candidate
        self.siblingFacts = siblingFacts
        self.isComplete = isComplete
    }
}

private struct DataVolumeDeclarationBinding: Equatable, Sendable {
    let sessionID: DataVolumeDeclarationSessionID
    let observationRevision: DataVolumeObservationRevision
    let target: VolumeInstanceID
    let diskInstanceID: DiskInstanceID
    let siblingInstanceIDs: Set<VolumeInstanceID>
    let requestNonce: DataVolumeRequestNonce
}

public struct DataVolumeDeclarationRequest: Equatable, Sendable {
    fileprivate let binding: DataVolumeDeclarationBinding

    public var sessionID: DataVolumeDeclarationSessionID { binding.sessionID }
    public var observationRevision: DataVolumeObservationRevision {
        binding.observationRevision
    }
    public var target: VolumeInstanceID { binding.target }
    public var diskInstanceID: DiskInstanceID { binding.diskInstanceID }
    public var siblingInstanceIDs: Set<VolumeInstanceID> {
        binding.siblingInstanceIDs
    }
    public var requestNonce: DataVolumeRequestNonce { binding.requestNonce }

    public func confirmSelectedVolumeIsDataAndNotWindowsBootOrSystemVolume()
        -> DataVolumeDeclaration
    {
        DataVolumeDeclaration(binding: binding)
    }
}

public struct DataVolumeDeclaration: Equatable, Sendable {
    fileprivate let binding: DataVolumeDeclarationBinding

    public let meaning: DataVolumeDeclarationMeaning

    fileprivate init(binding: DataVolumeDeclarationBinding) {
        self.binding = binding
        self.meaning = .selectedVolumeIsDataAndNotWindowsBootOrSystemVolume
    }
}

/// Opaque proof that the fixed human role statement passed for one request.
/// It is not a `VolumeSnapshot`, system evidence, or a mutation capability.
public struct DataRoleApproval: Equatable, Sendable {
    public let sessionID: DataVolumeDeclarationSessionID
    public let observationRevision: DataVolumeObservationRevision
    public let target: VolumeInstanceID
    public let diskInstanceID: DiskInstanceID
    public let siblingInstanceIDs: Set<VolumeInstanceID>
    public let requestNonce: DataVolumeRequestNonce

    fileprivate init(binding: DataVolumeDeclarationBinding) {
        self.sessionID = binding.sessionID
        self.observationRevision = binding.observationRevision
        self.target = binding.target
        self.diskInstanceID = binding.diskInstanceID
        self.siblingInstanceIDs = binding.siblingInstanceIDs
        self.requestNonce = binding.requestNonce
    }
}

public enum DataVolumeDeclarationRejection: Equatable, Sendable {
    case confirmationRequired
    case requestUnavailable
    case requestAlreadyConsumed
    case sessionChanged
    case staleObservation
    case targetChanged
    case siblingTopologyChanged
    case observationIncomplete
    case candidateNotEligible
    case protectedSibling
    case conflictingSiblingEvidence
    case invalidSiblingTopology
}

public enum DataVolumeDeclarationResolution: Equatable, Sendable {
    case approved(DataRoleApproval)
    case rejected(DataVolumeDeclarationRejection)
}

public actor DataVolumeDeclarationResolver {
    private struct CurrentRequest: Sendable {
        let request: DataVolumeDeclarationRequest
        let observation: DataVolumeRoleObservation
    }

    private var sessionID = DataVolumeDeclarationSessionID()
    private var currentRequest: CurrentRequest?
    private var consumedCurrentRequestNonce: DataVolumeRequestNonce?

    public init() {}

    /// Starts a new in-memory observation session. Callers use this for wake
    /// and resubscribe boundaries; no declaration survives the rotation.
    public func rotateSession() {
        sessionID = DataVolumeDeclarationSessionID()
        currentRequest = nil
        consumedCurrentRequestNonce = nil
    }

    public func beginRequest(
        observing observation: DataVolumeRoleObservation
    ) -> DataVolumeDeclarationRequest {
        let binding = DataVolumeDeclarationBinding(
            sessionID: sessionID,
            observationRevision: DataVolumeObservationRevision(),
            target: observation.candidate.instanceID,
            diskInstanceID: observation.candidate.diskInstanceID,
            siblingInstanceIDs: Set(observation.siblingFacts.map(\.instanceID)),
            requestNonce: DataVolumeRequestNonce()
        )
        let request = DataVolumeDeclarationRequest(binding: binding)
        currentRequest = CurrentRequest(request: request, observation: observation)
        consumedCurrentRequestNonce = nil
        return request
    }

    public func resolve(
        _ declaration: DataVolumeDeclaration?
    ) -> DataVolumeDeclarationResolution {
        guard let declaration else {
            return .rejected(.confirmationRequired)
        }
        guard declaration.binding.sessionID == sessionID else {
            return .rejected(.sessionChanged)
        }
        guard let currentRequest else {
            return .rejected(.requestUnavailable)
        }
        let currentBinding = currentRequest.request.binding
        guard declaration.binding.target == currentBinding.target,
              declaration.binding.diskInstanceID == currentBinding.diskInstanceID
        else {
            return .rejected(.targetChanged)
        }
        guard declaration.binding.siblingInstanceIDs
            == currentBinding.siblingInstanceIDs
        else {
            return .rejected(.siblingTopologyChanged)
        }
        guard declaration.binding.observationRevision
            == currentBinding.observationRevision
        else {
            return .rejected(.staleObservation)
        }
        guard declaration.binding.requestNonce == currentBinding.requestNonce else {
            return .rejected(.staleObservation)
        }
        guard consumedCurrentRequestNonce != declaration.binding.requestNonce else {
            return .rejected(.requestAlreadyConsumed)
        }
        consumedCurrentRequestNonce = declaration.binding.requestNonce
        if let rejection = Self.currentFactRejection(
            for: currentRequest.observation
        ) {
            return .rejected(rejection)
        }
        return .approved(DataRoleApproval(binding: declaration.binding))
    }

    private static func currentFactRejection(
        for observation: DataVolumeRoleObservation
    ) -> DataVolumeDeclarationRejection? {
        guard observation.isComplete else {
            return .observationIncomplete
        }
        let candidate = observation.candidate
        guard candidate.fileSystem == .ntfs, candidate.location == .external else {
            return .candidateNotEligible
        }
        let siblingFacts = observation.siblingFacts
        let siblingInstanceIDs = siblingFacts.map(\.instanceID)
        guard Set(siblingInstanceIDs).count == siblingInstanceIDs.count,
              siblingFacts.allSatisfy({ sibling in
                  sibling.instanceID != candidate.instanceID
                      && sibling.instanceID.diskInstanceID == candidate.diskInstanceID
              })
        else {
            return .invalidSiblingTopology
        }
        if siblingFacts.contains(where: { sibling in
            sibling.location == .internal || sibling.roleEvidence == .protected
        }) {
            return .protectedSibling
        }
        if siblingFacts.contains(where: { sibling in
            sibling.roleEvidence == .conflicting
        }) {
            return .conflictingSiblingEvidence
        }
        return nil
    }
}
