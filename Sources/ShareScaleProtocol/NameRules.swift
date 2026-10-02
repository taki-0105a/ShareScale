import Foundation

/// 見る側の名前（`hello` の `name`）の規則: NFC、1〜64 Unicode スカラー値、UTF-8 で 128 バイト以下、Cc・Cf・Zl・Zp を含まない
public enum NameRules: Sendable {
    public static let maxScalars = 64
    public static let maxBytes = 128

    static func forbidden(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// Host が検査する。規則どおりなら NFC にしたものを、違えば nil を返す
    public static func validate(_ name: String) -> String? {
        let n = name.precomposedStringWithCanonicalMapping
        let scalars = n.unicodeScalars
        guard (1...maxScalars).contains(scalars.count), n.utf8.count <= maxBytes,
              !scalars.contains(where: forbidden),
              !n.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }   // 空白だけの名前は拒否
        return n
    }

    /// 見る側が送る前に整える。許されない文字を除き、長さを切り詰め、空なら "Mac"
    public static func sanitize(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        var bytes = 0
        for u in name.precomposedStringWithCanonicalMapping.unicodeScalars where !forbidden(u) {
            let len = UTF8.width(u)
            guard out.count < maxScalars, bytes + len <= maxBytes else { break }
            out.append(u); bytes += len
        }
        let s = String(out).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Mac" : (validate(s) ?? "Mac")
    }
}

/// 相手とやりとりする文字列の整え方
public enum TextRules: Sendable {
    /// 制御文字（Cc・Cf・Zl・Zp）を除く。相手から来た文字列を記録・メニューに出す前に使う
    public static func stripControls(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !NameRules.forbidden($0) }))
    }

    /// 制御文字を除き、UTF-8 で `maxBytes` 以下に切り詰める（文字の途中では切らない）。相手に渡す文字列を書き出す前に使う
    public static func clip(_ s: String, maxBytes: Int = Limits.textMaxBytes) -> String {
        var out = String.UnicodeScalarView()
        var bytes = 0
        for u in stripControls(s).unicodeScalars {
            let len = UTF8.width(u)
            guard bytes + len <= maxBytes else { break }
            out.append(u); bytes += len
        }
        return String(out)
    }
}
