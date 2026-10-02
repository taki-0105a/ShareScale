import Darwin
import Foundation

/// IP アドレス。中身は 4 バイト（IPv4）か 16 バイト（IPv6）だけで、IPv4-mapped IPv6（::ffff:a.b.c.d）は必ず IPv4 に直して持つ
public struct IPAddress: Hashable, Sendable {
    /// 4 か 16 バイト（作る時に確かめる）
    public let bytes: [UInt8]

    /// 4 か 16 バイトだけ受け付ける。IPv4-mapped は IPv4 に直す
    public init?(bytes: [UInt8]) {
        switch bytes.count {
        case 4:
            self.bytes = bytes
        case 16:
            let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
            self.bytes = mapped ? Array(bytes[12..<16]) : bytes
        default:
            return nil
        }
    }

    /// 字句を inet_pton で読む。inet_pton は NUL で読むのをやめるので、渡す前に使ってよい文字を限定する
    /// - IPv4: 数字と `.` だけ。先頭が 0 の数（`010` など）は拒否する（8 進として読む実装との食い違いを防ぐ）
    /// - IPv6: 16 進の数字・`:`・`.` だけ。ゾーン（`%en0`）は 1 文字以上の英数字の時だけ除いて読む
    public init?(_ text: String) {
        var s = Substring(text)
        var zone: Substring?
        if let pct = s.firstIndex(of: "%") {
            zone = s[s.index(after: pct)...]
            s = s[..<pct]
        }
        guard !s.isEmpty else { return nil }
        let u = Array(s.utf8)
        if u.contains(UInt8(ascii: ":")) {
            guard u.allSatisfy({ isHexDigit($0) || $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: ".") }) else { return nil }
            if let z = zone {
                guard !z.isEmpty, z.utf8.allSatisfy({ isDigit($0) || isLetter($0) }) else { return nil }
            }
            var a6 = in6_addr()
            guard inet_pton(AF_INET6, String(s), &a6) == 1 else { return nil }
            self.init(bytes: withUnsafeBytes(of: a6) { Array($0) })
        } else {
            guard zone == nil, u.allSatisfy({ isDigit($0) || $0 == UInt8(ascii: ".") }),
                  s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ $0.count == 1 || $0.first != "0" })
            else { return nil }
            var a4 = in_addr()
            guard inet_pton(AF_INET, String(s), &a4) == 1 else { return nil }
            self.init(bytes: withUnsafeBytes(of: a4) { Array($0) })
        }
    }

    public var isV4: Bool { bytes.count == 4 }

    /// 書き直した形（inet_ntop。IPv6 は小文字・0 の省略あり）。表示・記録・候補アドレスに使う
    public var text: String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if isV4 {
            var a = in_addr(); withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: bytes) }
            inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        } else {
            var a = in6_addr(); withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: bytes) }
            inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
        }
        return String(cString: buf)
    }
}

private func isDigit(_ c: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) }
private func isLetter(_ c: UInt8) -> Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(c)
}
private func isHexDigit(_ c: UInt8) -> Bool {
    isDigit(c) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(c) || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(c)
}

/// アドレスの範囲（先頭 prefix ビット）。アドレスは範囲の先頭に切りそろえて持つ（同じ範囲は等しくなる）
public struct IPNetwork: Hashable, Sendable {
    public let address: IPAddress
    public let prefix: Int

    public init?(_ address: IPAddress, prefix: Int) {
        guard prefix >= 0, prefix <= address.bytes.count * 8 else { return nil }
        var b = address.bytes
        for i in 0..<b.count {
            let keep = max(0, min(8, prefix - i * 8))
            b[i] &= keep == 8 ? 0xff : UInt8(truncatingIfNeeded: 0xff << (8 - keep))
        }
        // 切りそろえても長さは変わらない（IPv6 が IPv4-mapped の形になるには先頭 96 ビットを残す必要があり、それは元から IPv4 のもの）
        guard let masked = IPAddress(bytes: b) else { return nil }
        self.address = masked
        self.prefix = prefix
    }
    public init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let a = IPAddress(String(parts[0])),
              !parts[1].isEmpty, parts[1].utf8.allSatisfy(isDigit), let p = Int(parts[1]) else { return nil }
        self.init(a, prefix: p)
    }

    public func contains(_ other: IPAddress) -> Bool {
        guard address.isV4 == other.isV4 else { return false }   // 同じ種類なら長さも同じ
        var bits = prefix
        for (a, b) in zip(address.bytes, other.bytes) where bits > 0 {
            let mask: UInt8 = bits >= 8 ? 0xff : UInt8(truncatingIfNeeded: 0xff << (8 - bits))
            if a & mask != b & mask { return false }
            bits -= 8
        }
        return true
    }
}

/// 接続コード・状態の候補アドレスの規則
public enum CandidateAddress: Sendable {
    /// ホスト名か IP の字句
    /// - IP: 書き直した形（`IPAddress(s)?.text`）と完全に同じ時だけ（大文字・0 を省略しない形・`::ffff:1.2.3.4`・角括弧・ゾーンは拒否）
    /// - ホスト名: `isValidHostname` に加え、最後のラベルが数字だけ、または `0x`・`0X` で始まるものは拒否
    ///   （`0x7f.1`・`a.123` などは getaddrinfo が IPv4 として読むため）
    public static func isValid(_ s: String) -> Bool {
        if let ip = IPAddress(s) { return ip.text == s }
        guard isValidHostname(s), let last = s.split(separator: ".", omittingEmptySubsequences: false).last else { return false }
        return !last.utf8.allSatisfy(isDigit) && !last.hasPrefix("0x") && !last.hasPrefix("0X")
    }

    /// 候補アドレスの一覧として正しいか（1〜8 件で、それぞれ `isValid`）。接続コードの `a` と状態の `addrs.a` で同じ規則
    static func isValidList(_ addresses: [String]) -> Bool {
        (1...Limits.maxCandidateAddresses).contains(addresses.count) && addresses.allSatisfy(isValid)
    }
}

/// ホスト名の字句（ASCII の英数字とハイフンのラベル。各 63 文字以下、全体 253 文字以下。先頭・末尾のハイフンは不可）
func isValidHostname(_ s: String) -> Bool {
    guard !s.isEmpty, s.utf8.count <= 253 else { return false }
    let labels = s.split(separator: ".", omittingEmptySubsequences: false)
    return labels.allSatisfy { l in
        (1...63).contains(l.utf8.count) && l.first != "-" && l.last != "-"
            && l.utf8.allSatisfy { isDigit($0) || isLetter($0) || $0 == UInt8(ascii: "-") }
    }
}

/// Tailscale のアドレスか（100.64.0.0/10、fd7a:115c:a1e0::/48）
public func isTailscaleAddress(_ address: IPAddress) -> Bool {
    SourceClassifier.tailscaleV4.contains(address) || SourceClassifier.tailscaleV6.contains(address)
}
