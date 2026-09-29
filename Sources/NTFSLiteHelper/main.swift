import Foundation
import NTFSLiteHelperProtocol

// Privileged launchd daemon registered through SMAppService (ADR 0010). It accepts only the
// pinned app signature and executes only admitted ADR 0002 requests.

/// No disk executor is wired yet (issues 03/04): every admitted request fails closed.
let processor = HelperRequestProcessor { _ in
    HelperResponseEnvelope(resultCode: .executionFailed, exitStatus: 1)
}

final class HelperService: NSObject, NTFSLiteHelperXPC {
    func submit(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        Task { reply(await processor.respond(to: request)) }
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
dispatchMain()
