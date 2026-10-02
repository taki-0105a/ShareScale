import Foundation
import ShareScaleProtocol

/// 接続先に利用者が付ける名前（設定 › 接続先 の「名前を変更…」。計画 2f-1 案 6。純粋な関数）。
/// - 前後の空白を除いて空なら nil（接続先（Host）の名前に戻す）。接続先の名前と同じでも nil（Host で名前を変えた時についていくため）
/// - 規則は `NameRules`（1〜64 文字・128 バイト・改行などの特殊な文字を含まない。NFC にしたもの）
public enum TargetAlias {
    public enum Problem: Error, Equatable, Sendable { case invalid }

    public static func validate(_ text: String, hostName: String) -> Result<String?, Problem> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .success(nil) }
        guard let v = NameRules.validate(t) else { return .failure(.invalid) }
        return .success(v == hostName.precomposedStringWithCanonicalMapping ? nil : v)
    }

    public static var invalidMessage: String {
        tr("名前は 64 文字以内で入力してください（改行などの特殊な文字は使えません）。",
           "Enter a name of up to 64 characters (without line breaks or other special characters).")
    }
}

extension ViewerMeta {
    /// 付けた名前だけを差し替えた形（名前の規則に合わなければ nil）
    public func withAlias(_ alias: String?) -> ViewerMeta? {
        ViewerMeta(name: name, port: port, addresses: addresses, manual: manual, lastOKAddress: lastOKAddress, confirmed: confirmed, alias: alias)
    }
}
