import Foundation

package enum StrictJSONObjectValidator {
    package static func accepts(_ data: Data) -> Bool {
        var parser = StrictJSONParser(bytes: Array(data))
        do {
            try parser.parseTopLevelObject()
            return true
        } catch {
            return false
        }
    }
}

/// A bounded recursive-descent grammar check run before `JSONDecoder`.
/// Foundation accepts duplicate object members; evidence and helper protocols do not.
private struct StrictJSONParser {
    private enum Failure: Error {
        case invalid
    }

    private static let maximumNestingDepth = 32

    private let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parseTopLevelObject() throws {
        skipWhitespace()
        guard currentByte == 0x7B else {
            throw Failure.invalid
        }
        try parseObject(depth: 1)
        skipWhitespace()
        guard index == bytes.count else {
            throw Failure.invalid
        }
    }

    private var currentByte: UInt8? {
        guard index < bytes.count else {
            return nil
        }
        return bytes[index]
    }

    private mutating func parseValue(depth: Int) throws {
        guard let byte = currentByte else {
            throw Failure.invalid
        }

        switch byte {
        case 0x7B:
            try parseObject(depth: depth + 1)
        case 0x5B:
            try parseArray(depth: depth + 1)
        case 0x22:
            _ = try parseString()
        case 0x2D, 0x30 ... 0x39:
            try parseNumber()
        case 0x74:
            try consumeLiteral([0x74, 0x72, 0x75, 0x65])
        case 0x66:
            try consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E:
            try consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
        default:
            throw Failure.invalid
        }
    }

    private mutating func parseObject(depth: Int) throws {
        guard depth <= Self.maximumNestingDepth else {
            throw Failure.invalid
        }
        try consume(0x7B)
        skipWhitespace()
        if consumeIfPresent(0x7D) {
            return
        }

        var memberNames: Set<String> = []
        while true {
            let memberName = try parseString()
            guard memberNames.insert(memberName).inserted else {
                throw Failure.invalid
            }

            skipWhitespace()
            try consume(0x3A)
            skipWhitespace()
            try parseValue(depth: depth)
            skipWhitespace()

            if consumeIfPresent(0x7D) {
                return
            }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws {
        guard depth <= Self.maximumNestingDepth else {
            throw Failure.invalid
        }
        try consume(0x5B)
        skipWhitespace()
        if consumeIfPresent(0x5D) {
            return
        }

        while true {
            try parseValue(depth: depth)
            skipWhitespace()
            if consumeIfPresent(0x5D) {
                return
            }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let literalStart = index
        try consume(0x22)

        while let byte = currentByte {
            switch byte {
            case 0x22:
                index += 1
                let literal = Data(bytes[literalStart ..< index])
                do {
                    return try JSONDecoder().decode(String.self, from: literal)
                } catch {
                    throw Failure.invalid
                }
            case 0x5C:
                index += 1
                guard let escape = currentByte else {
                    throw Failure.invalid
                }
                switch escape {
                case 0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    index += 1
                case 0x75:
                    index += 1
                    for _ in 0 ..< 4 {
                        guard let hexadecimal = currentByte,
                              isHexadecimalDigit(hexadecimal)
                        else {
                            throw Failure.invalid
                        }
                        index += 1
                    }
                default:
                    throw Failure.invalid
                }
            case 0x00 ... 0x1F:
                throw Failure.invalid
            default:
                index += 1
            }
        }

        throw Failure.invalid
    }

    private mutating func parseNumber() throws {
        _ = consumeIfPresent(0x2D)
        guard let integerStart = currentByte else {
            throw Failure.invalid
        }

        if integerStart == 0x30 {
            index += 1
            if let next = currentByte, isDecimalDigit(next) {
                throw Failure.invalid
            }
        } else if (0x31 ... 0x39).contains(integerStart) {
            index += 1
            consumeDecimalDigits()
        } else {
            throw Failure.invalid
        }

        if consumeIfPresent(0x2E) {
            guard let digit = currentByte, isDecimalDigit(digit) else {
                throw Failure.invalid
            }
            consumeDecimalDigits()
        }

        if consumeIfPresent(0x65) || consumeIfPresent(0x45) {
            _ = consumeIfPresent(0x2B) || consumeIfPresent(0x2D)
            guard let digit = currentByte, isDecimalDigit(digit) else {
                throw Failure.invalid
            }
            consumeDecimalDigits()
        }
    }

    private mutating func consumeDecimalDigits() {
        while let byte = currentByte, isDecimalDigit(byte) {
            index += 1
        }
    }

    private mutating func consumeLiteral(_ literal: [UInt8]) throws {
        let end = index + literal.count
        guard end <= bytes.count,
              bytes[index ..< end].elementsEqual(literal)
        else {
            throw Failure.invalid
        }
        index = end
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard consumeIfPresent(expected) else {
            throw Failure.invalid
        }
    }

    private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
        guard currentByte == expected else {
            return false
        }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = currentByte,
              byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        {
            index += 1
        }
    }

    private func isDecimalDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
    }

    private func isHexadecimalDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x46).contains(byte)
            || (0x61 ... 0x66).contains(byte)
    }
}
