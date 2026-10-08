import Foundation

@main struct RuntimeProbeSeedChecks {
    static func main() {
        let path = CommandLine.arguments[1]
        let compressed = try! Data(contentsOf: URL(fileURLWithPath: path))
        guard let seed = RuntimeProbeSeed.decode(compressed), seed.count == 134217728,
              seed[3..<11] == Data("NTFS    ".utf8) else {
            print("CHECK FAILED: fixed sealed blank NTFS seed must decode to 128 MiB"); exit(1)
        }
        var changed = compressed
        changed[changed.count / 2] ^= 1
        guard RuntimeProbeSeed.decode(changed) == nil,
              RuntimeProbeSeed.decode(compressed.dropLast()) == nil,
              RuntimeProbeSeed.decode(compressed + Data([0])) == nil,
              RuntimeProbeSeed.readProtected(at: path) == nil else {
            print("CHECK FAILED: altered, truncated, appended or user-owned seed must be refused"); exit(1)
        }
        print("PASS: fixed blank NTFS seed decodes")
    }
}
