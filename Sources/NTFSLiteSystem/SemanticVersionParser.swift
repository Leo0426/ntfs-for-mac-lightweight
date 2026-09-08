import Foundation
import NTFSLiteCore

public enum SemanticVersionParser {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?<![0-9.\-])([0-9]+)\.([0-9]+)(?:\.([0-9]+))?(?![0-9.])"#
    )

    public static func parse(_ text: String) -> SemanticVersion? {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: fullRange),
              let major = component(at: 1, in: match, text: text),
              let minor = component(at: 2, in: match, text: text)
        else {
            return nil
        }

        let patch: Int
        if match.range(at: 3).location == NSNotFound {
            patch = 0
        } else if let parsedPatch = component(at: 3, in: match, text: text) {
            patch = parsedPatch
        } else {
            return nil
        }

        return SemanticVersion(major: major, minor: minor, patch: patch)
    }

    private static func component(
        at index: Int,
        in match: NSTextCheckingResult,
        text: String
    ) -> Int? {
        guard let range = Range(match.range(at: index), in: text) else {
            return nil
        }
        return Int(text[range])
    }
}
