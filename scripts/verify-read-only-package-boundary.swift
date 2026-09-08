import Foundation

struct PackageDescription: Decodable {
    let targets: [Target]
}

struct Target: Decodable {
    let name: String
    let targetDependencies: [String]?

    private enum CodingKeys: String, CodingKey {
        case name
        case targetDependencies = "target_dependencies"
    }
}

let input = FileHandle.standardInput.readDataToEndOfFile()
let package: PackageDescription
do {
    package = try JSONDecoder().decode(PackageDescription.self, from: input)
} catch {
    FileHandle.standardError.write(
        Data("FAIL: 无法解析 Swift Package 依赖图。\n".utf8)
    )
    exit(1)
}

let dependencies = Dictionary(
    uniqueKeysWithValues: package.targets.map { target in
        (target.name, Set(target.targetDependencies ?? []))
    }
)
let forbidden = Set(["NTFSLiteMutationPreparation", "NTFSLiteHelperProtocol"])

func reachableTargets(from root: String) -> Set<String> {
    var pending = [root]
    var reachable: Set<String> = []
    while let target = pending.popLast() {
        guard reachable.insert(target).inserted else {
            continue
        }
        pending.append(contentsOf: dependencies[target] ?? [])
    }
    return reachable
}

let readOnlyApp = "NTFSLiteReadOnlyApp"
let gateEvidence = "NTFSLiteGateEvidence"
let gateEvidenceTool = "NTFSLiteGate1EvidenceTool"
let readOnlyRoots = [readOnlyApp, gateEvidence, gateEvidenceTool]
for root in readOnlyRoots {
    guard dependencies[root] != nil else {
        FileHandle.standardError.write(
            Data("FAIL: 缺少只读 root target：\(root)。\n".utf8)
        )
        exit(1)
    }

    let violations = reachableTargets(from: root).intersection(forbidden).sorted()
    guard violations.isEmpty else {
        let message =
            "FAIL: 只读 target \(root) 依赖进入变更边界：" +
            "\(violations.joined(separator: ", "))。\n"
        FileHandle.standardError.write(
            Data(message.utf8)
        )
        exit(1)
    }
}

guard dependencies[gateEvidenceTool]?.contains(gateEvidence) == true else {
    FileHandle.standardError.write(
        Data("FAIL: Gate1 Evidence Tool 必须直接依赖 Gate Evidence target。\n".utf8)
    )
    exit(1)
}

let appForbiddenTargets = Set([gateEvidence, gateEvidenceTool])
let appViolations = reachableTargets(from: readOnlyApp)
    .intersection(appForbiddenTargets)
    .sorted()
guard appViolations.isEmpty else {
    let message =
        "FAIL: 正式只读应用不得依赖 Evidence 工具链：" +
        "\(appViolations.joined(separator: ", "))。\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}

print("PASS: 正式应用、Gate Evidence 与 Evidence Tool 均保持独立只读依赖边界。")
