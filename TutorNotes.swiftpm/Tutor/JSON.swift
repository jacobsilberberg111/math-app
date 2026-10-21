import Foundation

/// A small, dependency-free JSON value used for everything that talks to the Claude API.
///
/// We parse and serialize JSON ourselves (instead of `JSONSerialization`) for three reasons:
/// 1. Deterministic output (sorted keys) so the conversation history we replay is byte-stable,
///    which keeps the prompt cache warm and preserved thinking valid.
/// 2. No `NSNumber` bool/number ambiguity.
/// 3. A tolerant "partial" mode for streaming tool inputs (`input_json_delta`), so the tutor's
///    writing can appear on the canvas while it is still being generated.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Accessors

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let items) = self, index >= 0, index < items.count { return items[index] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var intValue: Int? {
        guard let d = doubleValue, d.isFinite else { return nil }
        return Int(d.rounded())
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true" ? true : (s == "false" ? false : nil)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    // MARK: Builders

    static func obj(_ pairs: KeyValuePairs<String, JSONValue?>) -> JSONValue {
        var dict: [String: JSONValue] = [:]
        for (k, v) in pairs { if let v { dict[k] = v } }
        return .object(dict)
    }

    static func str(_ s: String) -> JSONValue { .string(s) }
    static func num(_ n: Double) -> JSONValue { .number(n) }
    static func int(_ n: Int) -> JSONValue { .number(Double(n)) }

    // MARK: Serialization

    func serialized(pretty: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(256)
        JSONValue.write(self, into: &out, pretty: pretty, indent: 0)
        return out
    }

    var data: Data { Data(serialized().utf8) }

    private static func write(_ value: JSONValue, into out: inout String, pretty: Bool, indent: Int) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += formatNumber(n)
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                write(item, into: &out, pretty: pretty, indent: indent + 1)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "]"
        case .object(let dict):
            if dict.isEmpty { out += "{}"; return }
            out += "{"
            for (i, key) in dict.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                writeString(key, into: &out)
                out += pretty ? ": " : ":"
                write(dict[key]!, into: &out, pretty: pretty, indent: indent + 1)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "}"
        }
    }

    static func formatNumber(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == n.rounded(), abs(n) < 1e15 {
            return String(Int64(n))
        }
        return "\(n)"
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: Parsing

    enum ParseError: Error, CustomStringConvertible {
        case unexpectedEnd
        case unexpectedCharacter(Character, Int)
        case invalidNumber(Int)
        case invalidEscape(Int)
        case trailingCharacters(Int)

        var description: String {
            switch self {
            case .unexpectedEnd: return "Unexpected end of JSON"
            case .unexpectedCharacter(let c, let i): return "Unexpected character '\(c)' at \(i)"
            case .invalidNumber(let i): return "Invalid number at \(i)"
            case .invalidEscape(let i): return "Invalid escape at \(i)"
            case .trailingCharacters(let i): return "Trailing characters at \(i)"
            }
        }
    }

    /// Strict parse. Throws on any malformed or truncated input.
    static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(Array(text.utf8), partial: false)
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        if parser.index < parser.bytes.count { throw ParseError.trailingCharacters(parser.index) }
        return value
    }

    static func parse(_ data: Data) throws -> JSONValue {
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.unexpectedEnd }
        return try parse(text)
    }

    /// Tolerant parse for streaming fragments: closes any open strings, arrays and objects and
    /// drops a dangling key or partial literal. Returns nil only if nothing usable was found.
    static func parsePartial(_ text: String) -> JSONValue? {
        var parser = Parser(Array(text.utf8), partial: true)
        parser.skipWhitespace()
        if parser.index >= parser.bytes.count { return nil }
        return try? parser.parseValue()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        let partial: Bool
        /// False when the most recent string ran into the end of input (partial mode only).
        var lastStringClosed = true

        init(_ bytes: [UInt8], partial: Bool) {
            self.bytes = bytes
            self.partial = partial
        }

        var atEnd: Bool { index >= bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count {
                let b = bytes[index]
                if b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 { index += 1 } else { break }
            }
        }

        mutating func parseValue() throws -> JSONValue {
            skipWhitespace()
            guard !atEnd else { throw ParseError.unexpectedEnd }
            let b = bytes[index]
            switch b {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): return try parseLiteral("true", .bool(true))
            case UInt8(ascii: "f"): return try parseLiteral("false", .bool(false))
            case UInt8(ascii: "n"): return try parseLiteral("null", .null)
            default:
                if b == UInt8(ascii: "-") || (b >= 0x30 && b <= 0x39) { return try parseNumber() }
                throw ParseError.unexpectedCharacter(Character(UnicodeScalar(b)), index)
            }
        }

        mutating func parseLiteral(_ word: String, _ value: JSONValue) throws -> JSONValue {
            let w = Array(word.utf8)
            var i = 0
            while i < w.count {
                if index >= bytes.count {
                    if partial { throw ParseError.unexpectedEnd }
                    throw ParseError.unexpectedEnd
                }
                if bytes[index] != w[i] { throw ParseError.unexpectedCharacter(Character(UnicodeScalar(bytes[index])), index) }
                index += 1
                i += 1
            }
            return value
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            while index < bytes.count {
                let b = bytes[index]
                let isDigit = b >= 0x30 && b <= 0x39
                if isDigit || b == UInt8(ascii: ".") || b == UInt8(ascii: "e") || b == UInt8(ascii: "E")
                    || b == UInt8(ascii: "+") || b == UInt8(ascii: "-") {
                    index += 1
                } else { break }
            }
            if partial && index >= bytes.count {
                // A number at the very end of a stream may still be growing; treat as incomplete
                // only if it ends in a non-digit (e.g. "12." or "1e").
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                if let d = Double(text) { return .number(d) }
                throw ParseError.unexpectedEnd
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let d = Double(text) else { throw ParseError.invalidNumber(start) }
            return .number(d)
        }

        mutating func parseString() throws -> String {
            // Assumes bytes[index] == '"'
            index += 1
            lastStringClosed = true
            var scalars = String.UnicodeScalarView()
            var runStart = index
            func flushRun(_ end: Int, into s: inout String.UnicodeScalarView, bytes: [UInt8]) {
                if end > runStart {
                    let chunk = String(decoding: bytes[runStart..<end], as: UTF8.self)
                    s.append(contentsOf: chunk.unicodeScalars)
                }
            }
            while true {
                guard index < bytes.count else {
                    if partial {
                        // Drop a trailing incomplete UTF-8 sequence before closing.
                        var end = index
                        while end > runStart, (bytes[end - 1] & 0xC0) == 0x80 { end -= 1 }
                        if end > runStart, bytes[end - 1] >= 0xC0 { end -= 1 }
                        flushRun(end, into: &scalars, bytes: bytes)
                        lastStringClosed = false
                        return String(scalars)
                    }
                    throw ParseError.unexpectedEnd
                }
                let b = bytes[index]
                if b == UInt8(ascii: "\"") {
                    flushRun(index, into: &scalars, bytes: bytes)
                    index += 1
                    return String(scalars)
                }
                if b == UInt8(ascii: "\\") {
                    flushRun(index, into: &scalars, bytes: bytes)
                    index += 1
                    guard index < bytes.count else {
                        if partial { lastStringClosed = false; return String(scalars) }
                        throw ParseError.unexpectedEnd
                    }
                    let e = bytes[index]
                    index += 1
                    switch e {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        guard let code = readHex4() else {
                            if partial && index + 4 > bytes.count { index = bytes.count; lastStringClosed = false; return String(scalars) }
                            throw ParseError.invalidEscape(index)
                        }
                        if code >= 0xD800 && code < 0xDC00 {
                            // High surrogate: expect a low surrogate.
                            if index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                                index += 2
                                if let low = readHex4(), low >= 0xDC00 && low < 0xE000 {
                                    let combined = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                                    if let s = UnicodeScalar(combined) { scalars.append(s) }
                                } else {
                                    scalars.append("\u{FFFD}")
                                }
                            } else if partial && index + 6 > bytes.count {
                                index = bytes.count
                                lastStringClosed = false
                                return String(scalars)
                            } else {
                                scalars.append("\u{FFFD}")
                            }
                        } else if let s = UnicodeScalar(code) {
                            scalars.append(s)
                        } else {
                            scalars.append("\u{FFFD}")
                        }
                    default:
                        throw ParseError.invalidEscape(index - 1)
                    }
                    runStart = index
                    continue
                }
                index += 1
            }
        }

        mutating func readHex4() -> UInt32? {
            guard index + 4 <= bytes.count else { return nil }
            var value: UInt32 = 0
            for i in 0..<4 {
                let c = bytes[index + i]
                value <<= 4
                switch c {
                case 0x30...0x39: value |= UInt32(c - 0x30)
                case 0x41...0x46: value |= UInt32(c - 0x41 + 10)
                case 0x61...0x66: value |= UInt32(c - 0x61 + 10)
                default: return nil
                }
            }
            index += 4
            return value
        }

        mutating func parseArray() throws -> JSONValue {
            index += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                if atEnd {
                    if partial { return .array(items) }
                    throw ParseError.unexpectedEnd
                }
                do {
                    items.append(try parseValue())
                } catch {
                    if partial { return .array(items) }
                    throw error
                }
                skipWhitespace()
                if atEnd {
                    if partial { return .array(items) }
                    throw ParseError.unexpectedEnd
                }
                let b = bytes[index]
                if b == UInt8(ascii: ",") { index += 1; continue }
                if b == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw ParseError.unexpectedCharacter(Character(UnicodeScalar(b)), index)
            }
        }

        mutating func parseObject() throws -> JSONValue {
            index += 1
            var dict: [String: JSONValue] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(dict) }
            while true {
                skipWhitespace()
                if atEnd {
                    if partial { return .object(dict) }
                    throw ParseError.unexpectedEnd
                }
                guard bytes[index] == UInt8(ascii: "\"") else {
                    throw ParseError.unexpectedCharacter(Character(UnicodeScalar(bytes[index])), index)
                }
                let key = try parseString()
                // In partial mode a key whose closing quote never arrived is unusable.
                if partial && !lastStringClosed { return .object(dict) }
                skipWhitespace()
                if atEnd {
                    if partial { return .object(dict) }
                    throw ParseError.unexpectedEnd
                }
                guard bytes[index] == UInt8(ascii: ":") else {
                    throw ParseError.unexpectedCharacter(Character(UnicodeScalar(bytes[index])), index)
                }
                index += 1
                skipWhitespace()
                if atEnd {
                    if partial { return .object(dict) }
                    throw ParseError.unexpectedEnd
                }
                do {
                    dict[key] = try parseValue()
                } catch {
                    if partial { return .object(dict) }
                    throw error
                }
                skipWhitespace()
                if atEnd {
                    if partial { return .object(dict) }
                    throw ParseError.unexpectedEnd
                }
                let b = bytes[index]
                if b == UInt8(ascii: ",") { index += 1; continue }
                if b == UInt8(ascii: "}") { index += 1; return .object(dict) }
                throw ParseError.unexpectedCharacter(Character(UnicodeScalar(b)), index)
            }
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        var dict: [String: JSONValue] = [:]
        for (k, v) in elements { dict[k] = v }
        self = .object(dict)
    }
    init(nilLiteral: ()) { self = .null }
}
