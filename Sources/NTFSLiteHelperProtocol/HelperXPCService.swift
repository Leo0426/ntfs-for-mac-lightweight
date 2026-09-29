import Foundation

/// Fixed identities for the privileged helper and its only permitted client (ADR 0010).
///
/// Both sides pin the same Apple-issued signing team; neither accepts ad-hoc or foreign code.
public enum HelperServiceIdentity {
    public static let helperIdentifier = "com.leolu.ntfslite.helper"
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

/// The single XPC entry point: raw request bytes in, raw response bytes out.
@objc public protocol NTFSLiteHelperXPC {
    func submit(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}

/// Runs the atomic admission step and hands only admitted requests to the executor.
public struct HelperRequestProcessor: Sendable {
    public typealias Executor = @Sendable (AdmittedHelperRequest) async -> HelperResponseEnvelope

    private let admission: HelperRequestAdmission
    private let executor: Executor

    public init(executor: @escaping Executor) {
        self.init(admission: .processLifetime, executor: executor)
    }

    package init(admission: HelperRequestAdmission, executor: @escaping Executor) {
        self.admission = admission
        self.executor = executor
    }

    public func respond(to data: Data) async -> Data {
        let response: HelperResponseEnvelope
        switch await admission.admit(data) {
        case let .failure(rejection):
            response = HelperResponseEnvelope(resultCode: rejection.responseCode, exitStatus: 1)
        case let .success(request):
            response = await executor(request)
        }
        // Encoding a fixed three-field envelope cannot fail; an empty reply is rejected by the client.
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
}
