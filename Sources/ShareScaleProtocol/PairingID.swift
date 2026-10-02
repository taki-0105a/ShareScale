import Foundation

/// ペアリングID（16 バイト）。通信では、ちょうど 32 文字の小文字 16 進で書く
public struct PairingID: Hashable, Sendable {
    public static let byteCount = 16

    /// ちょうど 16 バイト
    public let bytes: [UInt8]

    /// ちょうど 16 バイトの時だけ
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    /// ちょうど 32 文字の小文字 16 進（`0-9a-f`）の時だけ。大文字・空白・`0x` などは拒否する
    public init?(hex: String) {
        let u = Array(hex.utf8)
        guard u.count == Limits.idHexLength else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(Self.byteCount)
        for i in stride(from: 0, to: u.count, by: 2) {
            guard let hi = Self.lowerHexValue(u[i]), let lo = Self.lowerHexValue(u[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
        }
        self.bytes = out
    }

    /// 32 文字の小文字 16 進
    public var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(Limits.idHexLength)
        for b in bytes { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 0x0f)]) }
        return String(decoding: out, as: UTF8.self)
    }

    private static func lowerHexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}
