import Foundation

/// Complete KERN_PROCARGS2 executable path and argc-delimited arguments; environment is irrelevant.
public struct HelperKernelArguments: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]

    public static func decode(_ bytes: [UInt8]) -> Self? {
        guard bytes.count > MemoryLayout<Int32>.size, bytes.count <= 1_048_576 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 256 else { return nil }
        var index = MemoryLayout<Int32>.size
        func token() -> String? {
            let start = index
            guard let end = bytes[start...].firstIndex(of: 0) else { return nil }
            index = end + 1
            return String(bytes: bytes[start..<end], encoding: .utf8)
        }
        guard let executable = token(), executable.hasPrefix("/"), executable.utf8.count < 1024 else { return nil }
        while index < bytes.count && bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard index < bytes.count, let value = token() else { return nil }
            arguments.append(value)
        }
        guard let first = arguments.first, !first.isEmpty,
              first == executable || (first as NSString).lastPathComponent == (executable as NSString).lastPathComponent
        else { return nil }
        return Self(executablePath: executable, arguments: arguments)
    }
}
