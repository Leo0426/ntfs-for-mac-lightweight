import Foundation
import NTFSLiteHelperProtocol
import NTFSLiteProtectedInstall

@main
struct ProtectedInstallVerifier {
    static func main() {
        guard CommandLine.arguments.count == 1,
              SecureHelperDeployment.verifyInstalled(
                  appIdentifier: HelperServiceIdentity.appIdentifier,
                  helperIdentifier: HelperServiceIdentity.helperIdentifier,
                  driverIdentifier: SecureHelperDeployment.driverIdentifier,
                  probeIdentifier: SecureHelperDeployment.probeIdentifier,
                  teamIdentifier: HelperServiceIdentity.teamIdentifier
              )
        else {
            fputs("FAIL: 受保护 App 的属主、权限、ACL、文件清单或签名核验失败。\n", stderr)
            exit(1)
        }
        print("PASS: 受保护 App 的完整树、权限和固定签名已核验。")
    }
}
