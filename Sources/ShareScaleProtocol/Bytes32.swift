import Foundation
import Security

/// ちょうど 32 バイトの値（約束・乱数・秘密・proof・ekm）。長さの確かめは作る時に 1 回だけ行う
/// `==` は中身によらず同じ手間で比べる（秘密や proof を比べても時間から中身が漏れない）
public struct Bytes32: Hashable, Sendable {
    public static let count = 32

    /// ちょうど 32 バイト（0 から始まる Data）
    public let data: Data

    /// ちょうど 32 バイトの時だけ。切り出した Data も 0 から始まる Data に写して持つ
    public init?(_ data: Data) {
        guard data.count == Self.count else { return nil }
        self.data = Data(data)
    }

    /// パディングなしの base64url で、ちょうど 32 バイトに復号できる時だけ
    public init?(base64URL text: String) {
        guard let d = Base64URL.decode(text, byteCount: Self.count) else { return nil }
        self.init(d)
    }

    public var base64URL: String { Base64URL.encode(data) }

    public static func == (a: Bytes32, b: Bytes32) -> Bool { constantTimeEqual(a.data, b.data) }
    public func hash(into hasher: inout Hasher) { hasher.combine(data) }
}

extension Bytes32 {
    /// 暗号的な乱数（SecRandomCopyBytes）
    public static func random() -> Bytes32? {
        var b = [UInt8](repeating: 0, count: Bytes32.count)
        guard SecRandomCopyBytes(kSecRandomDefault, b.count, &b) == errSecSuccess else { return nil }
        return Bytes32(Data(b))
    }
}
