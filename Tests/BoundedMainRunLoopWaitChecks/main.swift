import Dispatch
import Foundation

@main
struct BoundedMainRunLoopWaitChecks {
    static func main() {
        let delivered = BoundedMainRunLoopWait.wait(timeout: 1) { finish in
            DispatchQueue.main.async { finish(true) }
        }
        precondition(delivered == true, "main-queue FSKit-style completion must be delivered")

        let start = Date()
        let missing = BoundedMainRunLoopWait.wait(timeout: 0.02) { _ in }
        precondition(missing == nil, "missing callback must remain unverified")
        precondition(Date().timeIntervalSince(start) < 0.5, "missing callback must respect its deadline")
        print("PASS: FSKit callback wait pumps the main run loop and times out")
    }
}
