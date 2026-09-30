import Foundation

/// Fixed identities for the privileged helper and its only permitted client (ADR 0010).
///
/// Both sides pin the same Apple-issued signing team; neither accepts ad-hoc or foreign code.
public enum HelperServiceIdentity {
    // A distinct service identity prevents a still-running legacy helper from
    // receiving requests from this release before its deployment checks run.
    public static let helperIdentifier = "com.leolu.ntfslite.helper.v2"
    public static let appIdentifier = "com.leolu.ntfslite.readonly"
    public static let teamIdentifier = "NP3U2GYHWL"
    public static let machServiceName = helperIdentifier
    public static let daemonPlistName = helperIdentifier + ".plist"

    /// Requirement the helper applies to incoming connections.
    public static var clientRequirement: String { requirement(identifier: appIdentifier) }

    /// Requirement the app applies to the helper it connects to.
    public static var helperRequirement: String { requirement(identifier: helperIdentifier) }

    private static func requirement(identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

/// A read-only challenge proves that the approved, signed helper is reachable.
/// It does not inspect a disk or imply that any disk is safe to change.
public enum HelperHealthCheck {
    public static let challengeByteCount = 16
    private static let prefix = Data("NTFSLite:helper:v2:".utf8)

    public static func response(for challenge: Data) -> Data? {
        guard challenge.count == challengeByteCount else { return nil }
        return prefix + challenge
    }

    public static func accepts(_ reply: Data, for challenge: Data) -> Bool {
        guard let expected = response(for: challenge) else { return false }
        return reply == expected
    }
}

/// The health entry point is read-only; only submit can reach disk actions.
@objc public protocol NTFSLiteHelperXPC {
    func healthCheck(_ challenge: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func submit(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}

/// Runs the atomic admission step and hands only admitted requests to the executor.
public struct HelperRequestProcessor: Sendable {
    public typealias Executor = @Sendable (AdmittedHelperRequest) async -> HelperResponseEnvelope

    private let admission: HelperRequestAdmission
    private let executionLease: HelperDiskExecutionLease
    private let uncertainty: HelperProcessUncertainty
    private let executor: Executor

    public init(executor: @escaping Executor) {
        admission = .processLifetime
        executionLease = .processLifetime
        uncertainty = .processLifetime
        self.executor = executor
    }

    package init(
        admission: HelperRequestAdmission,
        uncertainty: HelperProcessUncertainty = HelperProcessUncertainty(),
        executor: @escaping Executor
    ) {
        self.admission = admission
        executionLease = HelperDiskExecutionLease()
        self.uncertainty = uncertainty
        self.executor = executor
    }

    public func hasFrozenDisk() async -> Bool {
        if uncertainty.isUnknown { return true }
        return await executionLease.hasFrozenDisk()
    }

    public func respond(to data: Data) async -> Data {
        let response: HelperResponseEnvelope
        switch await admission.admit(data) {
        case let .failure(rejection):
            response = HelperResponseEnvelope(resultCode: rejection.responseCode, exitStatus: 1)
        case let .success(request):
            let diskName: String
            switch request.target {
            case let .disk(disk): diskName = disk.physicalDiskBSDName
            case let .volume(volume): diskName = volume.disk.physicalDiskBSDName
            }
            guard !uncertainty.isUnknown, await executionLease.begin(diskName) else {
                return (try? JSONEncoder().encode(HelperResponseEnvelope(
                    resultCode: .rejectedDiskBusy, exitStatus: 1
                ))) ?? Data()
            }
            if uncertainty.isUnknown {
                await executionLease.freeze(diskName)
                response = HelperResponseEnvelope(resultCode: .postconditionFailed, exitStatus: 1)
            } else {
                let executed = await executor(request)
                if uncertainty.isUnknown {
                    response = HelperResponseEnvelope(resultCode: .postconditionFailed, exitStatus: 1)
                    await executionLease.freeze(diskName)
                } else {
                    response = executed
                    if response.resultCode == .postconditionFailed {
                        await executionLease.freeze(diskName)
                    } else {
                        await executionLease.end(diskName)
                    }
                }
            }
        }
        // Encoding a fixed three-field envelope cannot fail; an empty reply is rejected by the client.
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
}

/// Covers the entire async executor call, including slow health probes and
/// multi-step whole-disk release. Every XPC connection in this daemon shares it.
private actor HelperDiskExecutionLease {
    static let processLifetime = HelperDiskExecutionLease()
    private var occupied: Set<String> = []
    private var frozen: Set<String> = []

    func begin(_ diskName: String) -> Bool {
        occupied.insert(diskName).inserted
    }

    func end(_ diskName: String) {
        if !frozen.contains(diskName) { occupied.remove(diskName) }
    }

    func freeze(_ diskName: String) {
        occupied.insert(diskName)
        frozen.insert(diskName)
    }

    func hasFrozenDisk() -> Bool {
        !frozen.isEmpty
    }
}
