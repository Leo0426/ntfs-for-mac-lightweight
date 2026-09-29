import Foundation
import NTFSLiteHelperExecution
import NTFSLiteHelperProtocol

// Privileged launchd daemon registered through SMAppService (ADR 0010). It accepts only the
// pinned app signature and executes only admitted ADR 0002 requests.

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == MountUserAgent.flag {
    exit(MountUserAgent.run(arguments: CommandLine.arguments))
}

let system = LiveWritableMountSystem()

/// Only admitted requests arrive here; an action/target mismatch fails closed.
let processor = HelperRequestProcessor { request in
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
    private let lock = NSLock()
    private var inFlight = 0
    private var lastActivity = Date()

    func begin() { lock.withLock { inFlight += 1; lastActivity = Date() } }
    func end() { lock.withLock { inFlight -= 1; lastActivity = Date() } }

    func start(idleSeconds: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [self] in
            let idle = lock.withLock { inFlight == 0 && Date().timeIntervalSince(lastActivity) > idleSeconds }
            if idle { exit(0) }
        }
        timer.resume()
        self.timer = timer
    }

    private var timer: DispatchSourceTimer?
}

final class HelperService: NSObject, NTFSLiteHelperXPC {
    func submit(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        IdleExit.shared.begin()
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
