// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NTFSLite",
    platforms: [
        .macOS("15.4"),
    ],
    products: [
        .library(name: "NTFSLiteCore", targets: ["NTFSLiteCore"]),
        .library(name: "NTFSLitePresentation", targets: ["NTFSLitePresentation"]),
        .library(name: "NTFSLiteSystem", targets: ["NTFSLiteSystem"]),
        .library(name: "NTFSLiteDiagnostics", targets: ["NTFSLiteDiagnostics"]),
        .library(
            name: "NTFSLiteHelperProtocol",
            targets: ["NTFSLiteHelperProtocol"]
        ),
        .library(
            name: "NTFSLiteMutationPreparation",
            targets: ["NTFSLiteMutationPreparation"]
        ),
        .executable(name: "NTFSLiteCoreChecks", targets: ["NTFSLiteCoreChecks"]),
        .executable(
            name: "NTFSLiteScenarioPrototype",
            targets: ["NTFSLiteScenarioPrototype"]
        ),
        .executable(
            name: "NTFSLiteReadOnlyApp",
            targets: ["NTFSLiteReadOnlyApp"]
        ),
        .executable(
            name: "NTFSLiteGate1EvidenceTool",
            targets: ["NTFSLiteGate1EvidenceTool"]
        ),
        .executable(name: "NTFSLiteHelper", targets: ["NTFSLiteHelper"]),
        .executable(name: "NTFSLiteHelperTracer", targets: ["NTFSLiteHelperTracer"]),
    ],
    targets: [
        .target(name: "NTFSLiteCore"),
        .target(
            name: "NTFSLitePresentation",
            dependencies: ["NTFSLiteCore", "NTFSLiteSystem"]
        ),
        .target(
            name: "NTFSLiteSystem",
            dependencies: ["NTFSLiteCore", "NTFSLiteReadOnlyProbing"],
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "NTFSLiteReadOnlyProbing",
            dependencies: ["NTFSLiteCore"]
        ),
        .target(
            name: "NTFSLiteDiagnostics",
            dependencies: ["NTFSLiteCore", "NTFSLiteSystem"]
        ),
        .target(
            name: "NTFSLiteGateEvidence",
            dependencies: [
                "NTFSLiteCore",
                "NTFSLiteStrictJSON",
                "NTFSLiteSystem",
            ]
        ),
        .target(name: "NTFSLiteStrictJSON"),
        .target(
            name: "NTFSLiteHelperProtocol",
            dependencies: ["NTFSLiteStrictJSON"]
        ),
        .target(
            name: "NTFSLiteMutationPreparation",
            dependencies: [
                "NTFSLiteCore",
                "NTFSLiteHelperProtocol",
                "NTFSLiteSystem",
            ]
        ),
        .executableTarget(
            name: "NTFSLiteCoreChecks",
            dependencies: [
                "NTFSLiteCore",
                "NTFSLiteDiagnostics",
                "NTFSLiteGateEvidence",
                "NTFSLiteHelperExecution",
                "NTFSLiteHelperProtocol",
                "NTFSLiteMutationPreparation",
                "NTFSLitePresentation",
                "NTFSLiteReadOnlyProbing",
                "NTFSLiteSystem",
                "NTFSLiteWriteSession",
            ]
        ),
        .executableTarget(
            name: "NTFSLiteScenarioPrototype",
            dependencies: ["NTFSLiteCore", "NTFSLitePresentation"]
        ),
        .executableTarget(
            name: "NTFSLiteReadOnlyApp",
            dependencies: [
                "NTFSLiteCore",
                "NTFSLiteDiagnostics",
                "NTFSLiteHelperProtocol",
                "NTFSLitePresentation",
                "NTFSLiteSystem",
                "NTFSLiteWriteSession",
            ],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .executableTarget(
            name: "NTFSLiteGate1EvidenceTool",
            dependencies: ["NTFSLiteGateEvidence", "NTFSLiteSystem"]
        ),
        // ADR 0011: app-side write session over an injected helper transport; no mutation APIs.
        .target(
            name: "NTFSLiteWriteSession",
            dependencies: ["NTFSLiteCore", "NTFSLiteHelperExecution", "NTFSLiteHelperProtocol", "NTFSLiteSystem"]
        ),
        // Pure helper execution decisions over injected system operations; no mutation APIs.
        .target(
            name: "NTFSLiteHelperExecution",
            dependencies: ["NTFSLiteHelperProtocol"]
        ),
        // ADR 0010: privileged launchd daemon; the only target allowed disk mutation APIs.
        .executableTarget(
            name: "NTFSLiteHelper",
            dependencies: ["NTFSLiteHelperExecution", "NTFSLiteHelperProtocol", "NTFSLiteSystem"]
        ),
        // Issue 02 tracer for SMAppService registration and the signed XPC channel.
        .executableTarget(
            name: "NTFSLiteHelperTracer",
            dependencies: ["NTFSLiteHelperProtocol", "NTFSLiteSystem"],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
    ]
)
