import Darwin
import DiskArbitration
import Foundation
import IOKit
import NTFSLiteHelperExecution

func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
let nonexistent = "disk999999"
var node = stat()
check(lstat("/dev/" + nonexistent, &node) == -1 && errno == ENOENT,
      "native fixture must remain a nonexistent device")
let session = DASessionCreate(kCFAllocatorDefault)!
let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, nonexistent)
check(disk != nil, "DA creates a reference even for the nonexistent BSD name")
check(DADiskCopyDescription(disk!) == nil, "DA reference has no current disk description")
let media = DADiskCopyIOMedia(disk!)
check(media == 0, "DA reference has no corresponding IOMedia")
print("PASS: native DA reference allocation does not prove presence")
let done = DispatchSemaphore(value: 0)
Task {
    let system = LiveWritableMountSystem()!
    check(await system.diskIsPresent(bsdName: nonexistent, registryEntryID: UInt64.max) == false,
          "complete kernel absence must remain absent even when DA allocates a reference")
    done.signal()
}
check(done.wait(timeout: .now() + 10) == .success, "native read-only absence probe must finish")
print("PASS: real helper confirms nonexistent device using current kernel absence")
