import Foundation

/// パディングなしの base64url（RFC 4648 §5）。読む時は厳密に確かめる（`=`・空白・標準の `+` `/` は拒否）
public enum Base64URL: Sendable {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 正しくなければ nil。長さの余りが 1 の文字列や、最後の文字に余りのビットが立っているものも拒否する
    public static func decode(_ text: String) -> Data? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard text.allSatisfy({ allowed.contains($0) }), text.count % 4 != 1 else { return nil }
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let data = Data(base64Encoded: s), encode(data) == text else { return nil }
        return data
    }

    /// ちょうど `count` バイトに復号できる時だけ返す
    public static func decode(_ text: String, byteCount count: Int) -> Data? {
        guard let d = decode(text), d.count == count else { return nil }
        return d
    }
}
