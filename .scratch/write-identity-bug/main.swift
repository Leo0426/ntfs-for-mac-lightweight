import Foundation
import NTFSLiteHelperExecution

if CommandLine.arguments.count > 1 {
    guard CommandLine.arguments.count == 4, CommandLine.arguments[1] == MountUserAgent.flag,
          CommandLine.arguments[2] == MountUserOperation.volumeUUID.rawValue else { exit(64) }
    exit(MountUserAgent.run(arguments: CommandLine.arguments))
}
Task {
    guard let system = LiveWritableMountSystem() else { exit(1) }
    for bsd in ["disk6", "disk6s1", "disk6s2"] {
        guard let facts = await system.volumeFacts(bsdName: bsd) else { print(bsd + " factsUnavailable"); continue }
        print(bsd + " facts=" + String(reflecting: facts))
        if bsd != "disk6" { print(bsd + " owned=" + String(reflecting: await system.ownedFSKitMounts(devicePath: "/dev/" + bsd))) }
    }
    print("topology=" + String(reflecting: await system.mediaTopology(diskBSDName: "disk6")))
    exit(0)
}
dispatchMain()
