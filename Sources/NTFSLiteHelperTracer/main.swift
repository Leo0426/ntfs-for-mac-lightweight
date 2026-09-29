import Foundation
import NTFSLiteHelperProtocol
import ServiceManagement

// Issue 02 tracer: proves SMAppService registration and the signed XPC channel. It sends a
// request for a non-existent disk; the helper has no executor yet and performs no disk action.

func emit(_ values: [String: String]) {
    let data = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data()
    print(String(decoding: data, as: UTF8.self))
}

func statusName(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown"
    }
}

let service = SMAppService.daemon(plistName: HelperServiceIdentity.daemonPlistName)

func send(_ request: Data) -> String {
    let connection = NSXPCConnection(machServiceName: HelperServiceIdentity.machServiceName, options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: NTFSLiteHelperXPC.self)
    connection.setCodeSigningRequirement(HelperServiceIdentity.helperRequirement)
    connection.resume()
    defer { connection.invalidate() }
    final class Box: @unchecked Sendable { var value = "timeout" }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        box.value = "connectionError:" + String((error as NSError).code)
        done.signal()
    } as? NTFSLiteHelperXPC
    proxy?.submit(request) { reply in
        switch HelperResponseDecoder().decode(reply) {
        case let .success(response): box.value = "resultCode:" + String(response.resultCode.rawValue)
        case let .failure(rejection): box.value = "invalidResponse:" + String(rejection.rawValue)
        }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 10)
    return box.value
}

switch CommandLine.arguments.dropFirst().first {
case "status":
    emit(["stage": "status", "status": statusName(service.status)])
case "register":
    do {
        try service.register()
        emit(["stage": "registered", "status": statusName(service.status)])
    } catch {
        emit(["stage": "registerFailed", "status": statusName(service.status), "code": String((error as NSError).code)])
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
case "ping":
    let request = try! HelperRequestEnvelope(
        operationID: HelperOperationID(), action: .ejectDisk,
        target: .disk(HelperDiskInstanceIdentity(physicalDiskBSDName: "disk999", mediaGeneration: 1))
    )
    let data = try! JSONEncoder().encode(request)
    emit(["stage": "firstRequest", "reply": send(data)])
    emit(["stage": "replayedRequest", "reply": send(data)])
case "unregister":
    do {
        try service.unregister()
        emit(["stage": "unregistered", "status": statusName(service.status)])
    } catch {
        emit(["stage": "unregisterFailed", "code": String((error as NSError).code)])
    }
default:
    emit(["stage": "usage", "commands": "status|register|ping|unregister"])
}
