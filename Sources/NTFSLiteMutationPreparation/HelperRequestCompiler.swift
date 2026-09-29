import NTFSLiteCore
import NTFSLiteHelperProtocol

public enum HelperRequestCompilationError: Error, Equatable, Sendable {
    case notMutationEffect
    case invalidOperationID
    case invalidIdentity
    case protocolInvariantViolation
}

/// Converts only coordinator-approved mutation effects into the fixed helper
/// protocol. It does not connect to a helper or execute any disk operation.
public enum HelperRequestCompiler {
    public static func compile(
        effect: VolumeEffect,
        diskBinding: HelperDiskInstanceIdentity? = nil
    ) -> Result<HelperRequestEnvelope, HelperRequestCompilationError> {
        switch effect {
        case let .unmountStandard(operationID, target):
            return compileVolume(
                operationID: operationID,
                target: target,
                action: .unmountVolume,
                diskBinding: diskBinding
            )
        case let .mountReadWrite(plan):
            return compileVolume(
                operationID: plan.operationID,
                target: plan.target,
                action: .mountReadWrite,
                diskBinding: diskBinding
            )
        case let .unmountPhysicalDiskStandard(operationID, target):
            return compileDisk(
                operationID: operationID,
                target: target,
                action: .unmountDisk,
                diskBinding: diskBinding
            )
        case let .ejectPhysicalDiskStandard(operationID, target):
            return compileDisk(
                operationID: operationID,
                target: target,
                action: .ejectDisk,
                diskBinding: diskBinding
            )
        case .none,
            .inspectPhysicalDisk,
            .inspectSafetySnapshot,
            .inspectWriteMount,
            .inspectWriteMutationReconciliation,
            .inspectEjectMutationReconciliation:
            return .failure(.notMutationEffect)
        }
    }

    private static func compileVolume(
        operationID: OperationID,
        target: VolumeInstanceID,
        action: HelperAction,
        diskBinding: HelperDiskInstanceIdentity?
    ) -> Result<HelperRequestEnvelope, HelperRequestCompilationError> {
        do {
            let disk = try helperDiskIdentity(target.diskInstanceID, diskBinding: diskBinding)
            let volume = try HelperVolumeInstanceIdentity(
                volumeUUID: target.volumeID.uuid,
                volumeBSDName: target.volumeID.bsdName,
                disk: disk
            )
            return try envelope(
                operationID: operationID,
                action: action,
                target: .volume(volume)
            )
        } catch let rejection as HelperRequestRejection {
            return .failure(compilationError(for: rejection))
        } catch {
            return .failure(.protocolInvariantViolation)
        }
    }

    private static func compileDisk(
        operationID: OperationID,
        target: DiskInstanceID,
        action: HelperAction,
        diskBinding: HelperDiskInstanceIdentity?
    ) -> Result<HelperRequestEnvelope, HelperRequestCompilationError> {
        do {
            return try envelope(
                operationID: operationID,
                action: action,
                target: .disk(try helperDiskIdentity(target, diskBinding: diskBinding))
            )
        } catch let rejection as HelperRequestRejection {
            return .failure(compilationError(for: rejection))
        } catch {
            return .failure(.protocolInvariantViolation)
        }
    }

    private static func helperDiskIdentity(
        _ target: DiskInstanceID,
        diskBinding: HelperDiskInstanceIdentity?
    ) throws -> HelperDiskInstanceIdentity {
        guard let diskBinding,
              diskBinding.physicalDiskBSDName == target.physicalDiskID.rawValue,
              diskBinding.mediaGeneration == target.mediaGeneration.rawValue
        else { throw HelperRequestRejection.invalidIdentity }
        return diskBinding
    }

    private static func envelope(
        operationID: OperationID,
        action: HelperAction,
        target: HelperTarget
    ) throws -> Result<HelperRequestEnvelope, HelperRequestCompilationError> {
        let request = try HelperRequestEnvelope(
            operationID: HelperOperationID(validating: operationID.rawValue),
            action: action,
            target: target
        )
        return .success(request)
    }

    private static func compilationError(
        for rejection: HelperRequestRejection
    ) -> HelperRequestCompilationError {
        switch rejection {
        case .invalidOperationID:
            return .invalidOperationID
        case .invalidIdentity:
            return .invalidIdentity
        case .malformedEnvelope,
            .unsupportedSchemaVersion,
            .unknownAction,
            .replayedOperation,
            .unexpectedField,
            .actionTargetMismatch,
            .operationCapacityReached:
            return .protocolInvariantViolation
        }
    }
}
