import Foundation
import NTFSLiteHelperProtocol
import NTFSLiteSystem
import ServiceManagement

// Tracer for SMAppService registration and the signed XPC channel (issues 02–04).
// The v2 helper protocol requires a complete, current IOMedia partition binding.
// This tool does not construct that binding for a real disk, so disk commands fail closed.

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
    // The ping tests the signed XPC channel and one-shot replay with a synthetic
    // protocol-valid target. Never use a BSD name that currently exists.
    let syntheticDiskName = "disk99999999999999999999999"
    let syntheticPartitionName = syntheticDiskName + "s1"
    guard let observedMedia = try? IOMediaEnumerationSnapshotProvider.live.currentSnapshot(),
          !observedMedia.bsdNames.contains(syntheticDiskName),
          !observedMedia.bsdNames.contains(syntheticPartitionName),
          let partition = try? HelperPartitionIdentity(
              bsdName: syntheticPartitionName,
              registryEntryID: UInt64.max - 1,
              mediaUUID: "00000000-0000-0000-0000-000000000001",
              contentHint: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7",
              kind: .ntfsTarget
          ),
          let disk = try? HelperDiskInstanceIdentity(
              physicalDiskBSDName: syntheticDiskName,
              mediaGeneration: UInt64.max,
              registryEntryID: UInt64.max,
              mediaContent: "GUID_partition_scheme",
              partitions: [partition]
          ),
          let request = try? HelperRequestEnvelope(
              operationID: HelperOperationID(), action: .ejectDisk,
              target: .disk(disk)
          ),
          let data = try? JSONEncoder().encode(request)
    else {
        emit(["stage": "identityUnavailable", "reason": "syntheticTargetNotProvenAbsent"])
        exit(1)
    }
    emit(["stage": "firstRequest", "syntheticTarget": "true", "reply": send(data)])
    emit(["stage": "replayedRequest", "syntheticTarget": "true", "reply": send(data)])
case "unregister":
    do {
        try service.unregister()
        emit(["stage": "unregistered", "status": statusName(service.status)])
    } catch {
        emit(["stage": "unregisterFailed", "code": String((error as NSError).code)])
    }
case "mount", "unmount":
    guard let volume = CommandLine.arguments.dropFirst(2).first,
          volume.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil
    else { emit(["stage": "usage"]); exit(2) }
    emit(["stage": "identityUnavailable", "reason": "v2TopologyNotObserved"])
    exit(1)
case "unmount-disk", "eject":
    guard let disk = CommandLine.arguments.dropFirst(2).first,
          disk.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil
    else { emit(["stage": "usage"]); exit(2) }
    emit(["stage": "identityUnavailable", "reason": "v2TopologyNotObserved"])
    exit(1)
default:
    emit(["stage": "usage", "commands": "status|register|ping|unregister; disk mutation commands are disabled until complete v2 topology can be observed"])
}
