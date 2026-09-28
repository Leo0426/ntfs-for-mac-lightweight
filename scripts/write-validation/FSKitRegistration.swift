import Foundation

struct FSKitModuleObservation: Decodable, Sendable {
    let identifier: String
    let url: URL
    let enabled: Bool
}

struct FSKitRegistrationReport: Encodable, Sendable {
    let status: String
    let modules: [String: String]
    // FSClient visibility can depend on the caller's signing identity/entitlements.
    // An empty response cannot establish system-wide absence.
    let observationScope = "currentProcess"
    let mountVerified = false
    let writeAuthorized = false
}

func assessFSKitRegistration(_ observations: [FSKitModuleObservation]?) -> FSKitRegistrationReport {
    guard let observations else {
        return FSKitRegistrationReport(status: "queryFailed", modules: ["standard": "unavailable", "local": "unavailable"])
    }
    let identifiers = ["standard": "io.macfuse.app.fsmodule.macfuse",
                       "local": "io.macfuse.app.fsmodule.macfuse-local"]
    let base = "/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/Extensions/"
    let states = identifiers.mapValues { identifier -> String in
        let matches = observations.filter { $0.identifier == identifier }
        guard !matches.isEmpty else { return "notObserved" }
        guard matches.count == 1 else { return "ambiguous" }
        let module = matches[0]
        let expected = URL(fileURLWithPath: base + identifier + ".appex", isDirectory: false).absoluteString
        guard [expected, expected + "/"].contains(module.url.absoluteString) else { return "unexpectedLocation" }
        return module.enabled ? "enabled" : "disabled"
    }
    return FSKitRegistrationReport(
        status: states.values.allSatisfy { $0 == "enabled" } ? "observedAndEnabled" : "blocked",
        modules: states
    )
}
