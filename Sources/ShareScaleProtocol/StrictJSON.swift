import Foundation

/// 字句の型を区別する JSON の値。オブジェクトはキーの順を保ち、同じキーを許さない
public enum JSONValue: Equatable, Sendable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case bool(Bool)
    case null

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(x), .array(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.integer(x), .integer(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    /// オブジェクトの中身を辞書で返す。オブジェクトでない時と、同じキーがある時（手で作った値）は nil
    public func members() -> [String: JSONValue]? {
        guard case let .object(pairs) = self else { return nil }
        var out: [String: JSONValue] = [:]
        for (key, value) in pairs {
            guard out.updateValue(value, forKey: key) == nil else { return nil }
        }
        return out
    }

    /// キーの集合がちょうど `keys` の時だけ中身を返す（知らないキー・足りないキーは nil）
    public func exactKeys(_ keys: Set<String>) -> [String: JSONValue]? {
        guard let m = members(), Set(m.keys) == keys else { return nil }
        return m
    }
}

public enum StrictJSONError: Error, Equatable, Sendable {
    case invalidUTF8, byteOrderMark, unexpectedEnd, unexpectedCharacter(Int)
    case duplicateKey(String), notInteger, integerOverflow, invalidEscape, controlCharacter
    case loneSurrogate, tooDeep, trailingData
}

/// 厳密な JSON の読み取り（整数だけの数・同じキーの拒否・深さの上限）。`JSONSerialization` の数値の変換には頼らない
public enum StrictJSON: Sendable {
    public static let maxDepth = 8

    public static func parse(_ data: Data) throws -> JSONValue {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { throw StrictJSONError.byteOrderMark }
        guard String(data: data, encoding: .utf8) != nil else { throw StrictJSONError.invalidUTF8 }
        var p = Parser(bytes: [UInt8](data))
        p.skipSpace()
        let v = try p.value(depth: 0)
        p.skipSpace()
        guard p.i == p.bytes.count else { throw StrictJSONError.trailingData }
        return v
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0
        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }
        func peek() throws -> UInt8 {
            guard i < bytes.count else { throw StrictJSONError.unexpectedEnd }
            return bytes[i]
        }
        mutating func expect(_ s: String) throws {
            for b in s.utf8 {
                guard try peek() == b else { throw StrictJSONError.unexpectedCharacter(i) }
                i += 1
            }
        }
        mutating func value(depth: Int) throws -> JSONValue {
            guard depth <= StrictJSON.maxDepth else { throw StrictJSONError.tooDeep }
            switch try peek() {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .integer(try integer())
            default: throw StrictJSONError.unexpectedCharacter(i)
            }
        }
        mutating func object(depth: Int) throws -> JSONValue {
            i += 1
            var members: [(String, JSONValue)] = []
            var seen = Set<String>()
            skipSpace()
            if try peek() == UInt8(ascii: "}") { i += 1; return .object(members) }
            while true {
                skipSpace()
                guard try peek() == UInt8(ascii: "\"") else { throw StrictJSONError.unexpectedCharacter(i) }
                let key = try string()
                guard seen.insert(key).inserted else { throw StrictJSONError.duplicateKey(key) }
                skipSpace()
                try expect(":")
                skipSpace()
                members.append((key, try value(depth: depth + 1)))
                skipSpace()
                let c = try peek(); i += 1
                if c == UInt8(ascii: "}") { return .object(members) }
                guard c == UInt8(ascii: ",") else { throw StrictJSONError.unexpectedCharacter(i - 1) }
            }
        }
        mutating func array(depth: Int) throws -> JSONValue {
            i += 1
            var items: [JSONValue] = []
            skipSpace()
            if try peek() == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipSpace()
                items.append(try value(depth: depth + 1))
                skipSpace()
                let c = try peek(); i += 1
                if c == UInt8(ascii: "]") { return .array(items) }
                guard c == UInt8(ascii: ",") else { throw StrictJSONError.unexpectedCharacter(i - 1) }
            }
        }
        /// 整数の字句だけ（-?(0|[1-9][0-9]*)）。小数点・指数は拒否
        mutating func integer() throws -> Int64 {
            let start = i
            if bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) else { throw StrictJSONError.notInteger }
            if bytes[i] == UInt8(ascii: "0") {
                i += 1
            } else {
                while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
            }
            // 整数の字句の直後に小数点・指数・数字（`01` の `1`）が続くものは拒否する
            if i < bytes.count {
                let next = bytes[i]
                let continuesNumber = next == UInt8(ascii: ".") || next == UInt8(ascii: "e") || next == UInt8(ascii: "E")
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(next)
                if continuesNumber { throw StrictJSONError.notInteger }
            }
            guard let v = Int64(String(decoding: bytes[start..<i], as: UTF8.self)) else { throw StrictJSONError.integerOverflow }
            return v
        }
        /// `\u` の後のちょうど 4 桁の 16 進（大文字・小文字）。`+` や `-` などは受け付けない
        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count else { throw StrictJSONError.invalidEscape }
            var v: UInt32 = 0
            for c in bytes[i..<i + 4] {
                let digit: UInt8
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = c - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = c - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = c - UInt8(ascii: "A") + 10
                default: throw StrictJSONError.invalidEscape
                }
                v = v << 4 | UInt32(digit)
            }
            i += 4
            return v
        }
        mutating func string() throws -> String {
            i += 1
            var out = [UInt8]()
            while true {
                let c = try peek(); i += 1
                switch c {
                case UInt8(ascii: "\""):
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    let e = try peek(); i += 1
                    switch e {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var u = try hex4()
                        if (0xD800...0xDBFF).contains(u) {
                            guard try peek() == UInt8(ascii: "\\") else { throw StrictJSONError.loneSurrogate }
                            i += 1
                            guard try peek() == UInt8(ascii: "u") else { throw StrictJSONError.loneSurrogate }
                            i += 1
                            let lo = try hex4()
                            guard (0xDC00...0xDFFF).contains(lo) else { throw StrictJSONError.loneSurrogate }
                            u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(u) {
                            throw StrictJSONError.loneSurrogate
                        }
                        guard let scalar = Unicode.Scalar(u) else { throw StrictJSONError.invalidEscape }
                        out.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default: throw StrictJSONError.invalidEscape
                    }
                default:
                    guard c >= 0x20 else { throw StrictJSONError.controlCharacter }
                    out.append(c)
                }
            }
        }
    }
}

/// 決まった形で書き出す（キーは渡した順。空白なし。ASCII 以外はそのまま UTF-8）
public enum JSONWriter: Sendable {
    public static func write(_ v: JSONValue) -> String {
        switch v {
        case let .object(members): return "{" + members.map { quote($0.0) + ":" + write($0.1) }.joined(separator: ",") + "}"
        case let .array(items): return "[" + items.map(write).joined(separator: ",") + "]"
        case let .string(s): return quote(s)
        case let .integer(n): return String(n)
        case let .bool(b): return b ? "true" : "false"
        case .null: return "null"
        }
    }
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 || u.value == 0x7F || (0x2028...0x2029).contains(u.value) {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}

/// 1 行（改行で終わる UTF-8）の取り出し。`\r` を含む・改行の後にバイトが続く・上限を超える行は拒否
public enum LineFraming: Sendable {
    /// 切断する理由（記録に使う）
    public enum FrameRejection: String, Equatable, Sendable {
        case tooLarge = "too_large", bytesAfterNewline = "bytes_after_newline", carriageReturn = "carriage_return"
    }

    public enum Result: Equatable, Sendable {
        case needMore                 // まだ改行が来ていない（上限以下）
        case line(Data)               // 改行を除いた 1 行
        case reject(FrameRejection)   // 切断する（応答しない）
    }

    public static func extract(_ buffer: Data, limit: Int) -> Result {
        if let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            if line.count + 1 > limit { return .reject(.tooLarge) }
            if buffer.index(after: nl) != buffer.endIndex { return .reject(.bytesAfterNewline) }
            if line.contains(0x0D) { return .reject(.carriageReturn) }
            return .line(Data(line))
        }
        return buffer.count >= limit ? .reject(.tooLarge) : .needMore
    }
}
