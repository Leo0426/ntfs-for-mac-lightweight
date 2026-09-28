import Foundation
import FSKit
import Darwin

// Independent read-only probe. No registration, approval, or mount operations.
@main
struct InspectFSKit {
    static func emit(_ report: FSKitRegistrationReport, exitCode: Int32) -> Never {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data + Data([10]))
            exit(exitCode)
        } catch {
            exit(2)
        }
    }

    static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--help"] {
            print("Usage: inspect-fskit\n只读查询当前进程可见的 macFUSE FSKit 模块；未观察到不表示系统未安装，也不证明挂载或授权写入。")
            return
        }
        guard CommandLine.arguments.count == 1 else {
            FileHandle.standardError.write(Data("Usage: inspect-fskit [--help]\n".utf8))
            exit(64)
        }
        guard #available(macOS 15.4, *) else {
            emit(assessFSKitRegistration(nil), exitCode: 2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            emit(FSKitRegistrationReport(status: "timedOut",
                                        modules: ["standard": "unavailable", "local": "unavailable"]), exitCode: 3)
        }
        FSClient.shared.fetchInstalledExtensions { modules, error in
            let facts: [FSKitModuleObservation]? = error == nil ? modules?.map {
                FSKitModuleObservation(identifier: $0.bundleIdentifier, url: $0.url, enabled: $0.isEnabled)
            } : nil
            let report = assessFSKitRegistration(facts)
            // The callback and timeout serialize output on the main queue.
            DispatchQueue.main.async {
                let code: Int32 = report.status == "observedAndEnabled" ? 0 : (facts == nil ? 2 : 1)
                emit(report, exitCode: code)
            }
        }
        dispatchMain()
    }
}
