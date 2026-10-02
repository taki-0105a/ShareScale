import Foundation

/// 記録・診断・ほかの Mac への応答に載せるエラーの文（計画 2h の点検と、その後の直し）。
/// 読める文（`localizedDescription`）を主にして、後ろにエラーの種類と番号を括弧で添える（例「アクセス権がありません (NSCocoaErrorDomain 513)」）。
/// - 読める文の言語は、組み立てたアプリでは画面の文言の言語と同じになる（Info.plist の言語の宣言から macOS が選ぶ言語と、
///   アプリ自身の言語 `HostLanguage.detect` を同じ決まりにしたため）。宣言の無い `swift run` と試験では、macOS が英語で返す
/// - 種類と番号は言語に依らない（別の言語の Mac で読む時・問い合わせの時の手がかり。試験もここだけを見る）
/// - 改行は空白 1 つに置き換え（続いていても 1 つ。語がつながらないように）、ほかの制御文字は除く（1 行の記録・画面の 1 行に載せるため。
///   表示の側の `TextRules.stripControls`・`clip` はそのまま）。
///   `userInfo` のパスなどは足さない
public enum ErrorText {
    public static func readable(_ error: Error) -> String {
        var scalars = String.UnicodeScalarView()
        var afterNewline = false
        for u in error.localizedDescription.unicodeScalars {
            if CharacterSet.newlines.contains(u) {
                if !afterNewline { scalars.append(" ") }
                afterNewline = true
            } else if !CharacterSet.controlCharacters.contains(u) {
                scalars.append(u)
                afterNewline = false
            }
        }
        let text = String(scalars).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? code(error) : "\(text) (\(code(error)))"
    }

    /// エラーの種類と番号（言語に依らない。元になったエラーがあれば、それも）
    public static func code(_ error: Error) -> String {
        let e = error as NSError
        var text = "\(e.domain) \(e.code)"
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { text += ", \(u.domain) \(u.code)" }
        return text
    }
}
