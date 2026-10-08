import Foundation

@objc protocol ReadOnlyHelperHealth {
    func healthCheck(_ challenge: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}
final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: String?
    let done = DispatchSemaphore(value: 0)
    func finish(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = value
        done.signal()
    }
    func read() -> String {
        lock.lock(); defer { lock.unlock() }
        return result ?? "timeout"
    }
}
let connection = NSXPCConnection(machServiceName: "com.leolu.ntfslite.helper.v2", options: .privileged)
connection.remoteObjectInterface = NSXPCInterface(with: ReadOnlyHelperHealth.self)
connection.setCodeSigningRequirement("anchor apple generic and identifier \"com.leolu.ntfslite.helper.v2\" and certificate leaf[subject.OU] = \"NP3U2GYHWL\"")
let box = ResultBox()
var bytes = UUID().uuid
let challenge = withUnsafeBytes(of: &bytes) { Data($0) }
let expected = Data("NTFSLite:helper:v2:".utf8) + challenge
connection.interruptionHandler = { box.finish("connectionInterrupted") }
connection.invalidationHandler = { box.finish("connectionInvalidated") }
connection.resume()
let proxy = connection.remoteObjectProxyWithErrorHandler { error in
    let e = error as NSError
    box.finish("connectionError:" + e.domain + ":" + String(e.code))
} as? ReadOnlyHelperHealth
if let proxy {
    proxy.healthCheck(challenge) { reply in box.finish(reply == expected ? "verified" : "invalidReply") }
} else { box.finish("proxyUnavailable") }
_ = box.done.wait(timeout: .now() + 10)
let result = box.read()
connection.invalidate()
print("signedHelperHealth=" + result)
exit(result == "verified" ? 0 : 1)
