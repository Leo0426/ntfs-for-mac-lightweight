import Foundation
import Darwin
import NTFSLiteHelperProtocol
import NTFSLiteSystem
import ServiceManagement

// Tracer for SMAppService registration and the signed XPC channel (issues 02–04). Disk actions
// are only for the user-authorized sacrificial disk; the helper re-verifies every fact itself.

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
        case let .success(response): box.value = "resultCode:" + String(response.resultCode.rawValue) + " exitStatus:" + String(response.exitStatus)
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
case "mount", "unmount":
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    guard let volume = arguments.first, let whole = volume.range(of: #"^disk[0-9]+"#, options: .regularExpression)
    else { emit(["stage": "usage"]); exit(2) }
    let uuid = arguments.count > 1 ? arguments[1] : nativeVolumeUUID(bsd: volume)
    guard let uuid,
          let target = try? HelperVolumeInstanceIdentity(
              volumeUUID: uuid, volumeBSDName: volume,
              disk: HelperDiskInstanceIdentity(physicalDiskBSDName: String(volume[whole]), mediaGeneration: 1))
    else { emit(["stage": "identityUnavailable"]); exit(1) }
    let action: HelperAction = CommandLine.arguments[1] == "mount" ? .mountReadWrite : .unmountVolume
    let request = try! HelperRequestEnvelope(operationID: HelperOperationID(), action: action, target: .volume(target))
    emit(["stage": CommandLine.arguments[1], "volumeUUID": uuid, "reply": send(try! JSONEncoder().encode(request))])
case "unmount-disk", "eject":
    guard let disk = CommandLine.arguments.dropFirst(2).first,
          let identity = try? HelperDiskInstanceIdentity(physicalDiskBSDName: disk, mediaGeneration: 1)
    else { emit(["stage": "usage"]); exit(2) }
    let action: HelperAction = CommandLine.arguments[1] == "eject" ? .ejectDisk : .unmountDisk
    let request = try! HelperRequestEnvelope(operationID: HelperOperationID(), action: action, target: .disk(identity))
    emit(["stage": CommandLine.arguments[1], "reply": send(try! JSONEncoder().encode(request))])
default:
    emit(["stage": "usage", "commands": "status|register|ping|mount <diskNsM>|unmount <diskNsM> <uuid>|unmount-disk <diskN>|eject <diskN>|unregister"])
}

/// The same identity the app uses for a natively mounted NTFS candidate (ADR 0008).
func nativeVolumeUUID(bsd: String) -> String? {
    let count = getfsstat(nil, 0, MNT_NOWAIT)
    guard count > 0 else { return nil }
    var entries = [FileSystemStatus](repeating: FileSystemStatus(), count: Int(count))
    let filled = getfsstat(&entries, Int32(MemoryLayout<FileSystemStatus>.stride * Int(count)), MNT_NOWAIT)
    for entry in entries.prefix(Int(max(filled, 0))) {
        var copy = entry
        let source = withUnsafePointer(to: &copy.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
        if source == "/dev/" + bsd { return MountedFileSystemUUIDReader.read(for: entry) }
    }
    return nil
}

typealias FileSystemStatus = statfs
