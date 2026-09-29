import Foundation
import NTFSLiteHelperExecution
import NTFSLiteHelperProtocol

// Privileged launchd daemon registered through SMAppService (ADR 0010). It accepts only the
// pinned app signature and executes only admitted ADR 0002 requests.

func deploymentIsTrusted(requireRootProcess: Bool) -> Bool {
    SecureHelperDeployment.verifyCurrent(
        requireRootProcess: requireRootProcess,
        helperIdentifier: HelperServiceIdentity.helperIdentifier,
        driverIdentifier: LiveWritableMountSystem.driverIdentifier,
        probeIdentifier: LiveWritableMountSystem.probeIdentifier,
        teamIdentifier: HelperServiceIdentity.teamIdentifier
    )
}

let isMountUserAgent = CommandLine.arguments.count > 1
    && CommandLine.arguments[1] == MountUserAgent.flag
guard deploymentIsTrusted(requireRootProcess: !isMountUserAgent) else { exit(97) }

if isMountUserAgent {
    exit(MountUserAgent.run(arguments: CommandLine.arguments))
}

let system = LiveWritableMountSystem()

/// Only admitted requests arrive here; an action/target mismatch fails closed.
let processor = HelperRequestProcessor { request in
    // The daemon may outlive an app update. Recheck before every mutation;
    // a missing or changed deployment cannot reuse an earlier decision.
    guard deploymentIsTrusted(requireRootProcess: true) else {
        return HelperResponseEnvelope(resultCode: .executionFailed, exitStatus: 97)
    }
    switch (request.action, request.target) {
    case let (.mountReadWrite, .volume(target)):
        guard let system else { return HelperResponseEnvelope(resultCode: .executionFailed, exitStatus: 99) }
        return await WritableMountExecutor.run(target: target, system: system)
    case let (.unmountVolume, .volume(target)):
        guard let system else { return HelperResponseEnvelope(resultCode: .executionFailed, exitStatus: 99) }
        return await DiskReleaseExecutor.unmountVolume(target: target, system: system)
    case let (.unmountDisk, .disk(target)):
        guard let system else { return HelperResponseEnvelope(resultCode: .executionFailed, exitStatus: 99) }
        return await DiskReleaseExecutor.unmountDisk(target: target, system: system)
    case let (.ejectDisk, .disk(target)):
        guard let system else { return HelperResponseEnvelope(resultCode: .executionFailed, exitStatus: 99) }
        return await DiskReleaseExecutor.ejectDisk(target: target, system: system)
    default:
        return HelperResponseEnvelope(resultCode: .executionFailed, exitStatus: 98)
    }
}

/// launchd starts the helper on demand; it exits when idle so no root process lingers and an
/// updated app binary takes effect. Drivers it started are reparented to launchd, and mounts are
/// recognized from process and mount facts, not from helper memory.
final class IdleExit: @unchecked Sendable {
    static let shared = IdleExit()
    private let gate = HelperIdleExitGate()

    func begin() -> Bool { gate.begin() }
    func end() { gate.end() }

    func start(idleSeconds: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [self] in
            guard gate.isIdle(idleSeconds: idleSeconds) else { return }
            Task {
                // A timed-out DA operation or unconfirmed child may still act
                // after its XPC response. Keep the process-scoped disk lease.
                guard await !processor.hasFrozenDisk() else { return }
                if gate.beginExitIfIdle(idleSeconds: idleSeconds) { exit(0) }
            }
        }
        timer.resume()
        self.timer = timer
    }

    private var timer: DispatchSourceTimer?
}

final class HelperService: NSObject, NTFSLiteHelperXPC {
    func submit(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        guard IdleExit.shared.begin() else {
            reply((try? JSONEncoder().encode(HelperResponseEnvelope(
                resultCode: .executionFailed, exitStatus: 97
            ))) ?? Data())
            return
        }
        Task {
            reply(await processor.respond(to: request))
            IdleExit.shared.end()
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: NTFSLiteHelperXPC.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: HelperServiceIdentity.machServiceName)
listener.setConnectionCodeSigningRequirement(HelperServiceIdentity.clientRequirement)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
IdleExit.shared.start(idleSeconds: 120)
dispatchMain()
