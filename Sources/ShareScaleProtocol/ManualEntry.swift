import Foundation

/// 手入力の「アドレス」と「キー」
public enum ManualEntry: Sendable {
    /// Crockford base32 の文字（値 0〜31）と検査文字（値 32〜36 の記号を加える）
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let checkSymbols = alphabet + Array("*~$=U")

    /// NFKC（全角を半角に）にしてから前後の空白を除く
    public static func normalize(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: キー（ペアリングID 16 バイト ‖ 秘密 32 バイト → 77 文字 ＋ 検査文字 1 文字）

    public static func encodeKey(id: PairingID, secret: Bytes32) -> String {
        let data = id.bytes + secret.data
        var bits = 0, acc = 0
        var out = ""
        for byte in data {
            acc = (acc << 8) | Int(byte); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(acc >> bits) & 31]) }
            acc &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(acc << (5 - bits)) & 31]) }
        out.append(checkSymbols[mod37(data)])
        return out
    }

    /// 4 文字ずつ空けた表示
    public static func grouped(_ key: String) -> String {
        stride(from: 0, to: key.count, by: 4).map { i in
            let s = key.index(key.startIndex, offsetBy: i)
            return String(key[s..<(key.index(s, offsetBy: 4, limitedBy: key.endIndex) ?? key.endIndex)])
        }.joined(separator: " ")
    }

    public enum KeyError: Error, Equatable, Sendable { case badLength, badCharacter, badPadding, checksumMismatch }

    /// 空白とハイフンを除き、大文字小文字を区別せず、I・L は 1、O は 0 として読む
    public static func decodeKey(_ input: String) throws -> (id: PairingID, secret: Bytes32) {
        let s = normalize(input).uppercased().filter { $0 != " " && $0 != "-" }
        guard s.count == 78 else { throw KeyError.badLength }
        var values: [Int] = []
        for ch in s.dropLast() {
            guard let v = alphabet.firstIndex(of: readingAlias(ch)) else { throw KeyError.badCharacter }
            values.append(v)
        }
        var bytes: [UInt8] = []
        var acc = 0, bits = 0
        for v in values {
            acc = (acc << 5) | v; bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8((acc >> bits) & 0xff)); acc &= (1 << bits) - 1 }
        }
        guard bytes.count == 48, acc == 0 else { throw KeyError.badPadding }
        guard let last = s.last, let check = checkSymbols.firstIndex(of: readingAlias(last)) else { throw KeyError.badCharacter }
        guard check == mod37(bytes) else { throw KeyError.checksumMismatch }
        guard let id = PairingID(bytes: Array(bytes[0..<PairingID.byteCount])),
              let secret = Bytes32(Data(bytes[PairingID.byteCount...])) else { throw KeyError.badLength }
        return (id, secret)
    }

    /// Crockford の読み替え（大文字にした後）: `I`・`L` は 1、`O` は 0
    static func readingAlias(_ c: Character) -> Character {
        switch c {
        case "I", "L": return "1"
        case "O": return "0"
        default: return c
        }
    }

    static func mod37<S: Sequence>(_ bytes: S) -> Int where S.Element == UInt8 {
        bytes.reduce(0) { ($0 * 256 + Int($1)) % 37 }
    }

    // MARK: アドレス（`<ホスト名>`・`<IPv4>`・`[<IPv6>]` の後に任意で `:<通信口>`）

    public enum AddressError: Error, Equatable, Sendable { case empty, badHost, badPort, ipv6NeedsBrackets }

    public static func parseAddress(_ input: String) throws -> (host: String, port: Int) {
        let s = normalize(input)
        guard !s.isEmpty else { throw AddressError.empty }
        var host: String, portText: String?
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { throw AddressError.badHost }
            host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if !rest.isEmpty {
                guard rest.first == ":" else { throw AddressError.badHost }
                portText = String(rest.dropFirst())
            }
            // 角括弧の中は IPv6 の字句だけ（ゾーンは不可）。書き直した形で返す（`[FD7A::1]` → `fd7a::1`）
            guard host.contains(":"), !host.contains("%"), let a = IPAddress(host) else { throw AddressError.badHost }
            host = a.text
        } else {
            let colons = s.filter { $0 == ":" }.count
            if colons > 1 { throw AddressError.ipv6NeedsBrackets }
            if colons == 1 {
                let parts = s.split(separator: ":", omittingEmptySubsequences: false)
                host = String(parts[0]); portText = String(parts[1])
            } else {
                host = s
            }
            if let a = IPAddress(host) {
                host = a.text
            } else {
                guard CandidateAddress.isValid(host) else { throw AddressError.badHost }
            }
        }
        var port = Limits.defaultPort
        if let p = portText {
            guard !p.isEmpty, p.count <= 5, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p), Limits.portRange.contains(n) else { throw AddressError.badPort }
            port = n
        }
        return (host, port)
    }
}
