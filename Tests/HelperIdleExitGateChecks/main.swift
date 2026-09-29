import Foundation

@main
struct HelperIdleExitGateChecks {
    static func main() {
        let lastActivity = Date(timeIntervalSince1970: 0)
        let idleNow = Date(timeIntervalSince1970: 300)
        let gate = HelperIdleExitGate(lastActivity: lastActivity)
        precondition(gate.isIdle(now: idleNow, idleSeconds: 120))
        precondition(gate.beginExitIfIdle(now: idleNow, idleSeconds: 120))
        precondition(
            !gate.begin(now: idleNow),
            "a request arriving after exit selection must not start a disk mutation"
        )
        print("PASS: idle-exit selection closes helper request admission")
    }
}
