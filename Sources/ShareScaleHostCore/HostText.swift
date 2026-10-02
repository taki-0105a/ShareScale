import Foundation
import ShareScaleProtocol

/// Host の画面の言語。macOS の言語設定の並びの中で、日本語か英語の最初のもの（どちらも無ければ英語）。
/// Info.plist の言語の宣言（`CFBundleLocalizations`＝`en`・`ja`、開発の言語は `en`）から macOS が標準のメニューと部品の言語を選ぶ決まりと同じにする
/// （計画 2h の点検。前は「先頭が日本語なら日本語、それ以外は英語」で、並びが「日英以外 → 日本語 → 英語」の時に、標準のメニューは日本語・アプリの文言は英語になった）。
/// 翻訳ファイル（.strings）は使わず、訳をコードに並べて持つ（見る側の `AppLanguage` と同じ理由:
/// .app を手作業で組み立てるので、資源の束を入れ忘れても落ちないようにする）
public enum HostLanguage: Equatable, Sendable {
    case ja, en

    /// `Locale.preferredLanguages` から決める（純粋な関数）。並びを上から見て、日本語（`ja`・`ja-JP` など）か英語（`en`・`en-US` など）の最初のもの。
    /// どちらも無ければ英語。macOS が返すふつうの形の並び（言語、言語と地域。大文字小文字と区切り `-`・`_` は問わない）では、
    /// `Bundle.preferredLocalizations(from: ["en", "ja"], forPreferences:)` と同じ答えになる（試験で確かめる範囲）。
    /// 言語の部分（先頭）が `ja`・`en` と同じかだけを見て、文字の指定は 2 番目の部分に 4 文字で書かれた時だけ見る（`ja-Latn` などは、その言語と見ない）。
    /// それ以外の形（`ja-Hira` のような別の文字・`Japanese`・`jpn` のような古い名前）は対象外で、macOS と同じ答えになるとは限らない
    public static func detect(_ preferred: [String]) -> HostLanguage {
        for tag in preferred {
            let parts = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
            guard let language = parts.first else { continue }
            let script = parts.dropFirst().first { $0.count == 4 }
            if language == "ja", script == nil || script == "jpan" { return .ja }
            if language == "en", script == nil || script == "latn" { return .en }
        }
        return .en
    }

    /// 日本語と英語を並べて書き、この言語の方を返す
    public func t(_ ja: String, _ en: String) -> String { self == .ja ? ja : en }

    /// 見る側（画面では「接続元の Mac」）の名前を画面に出す形（制御文字を除く。空、または名前の無い印（`isUnnamedPlaceholder`）なら「名前のない Mac」）
    public func displayName(_ raw: String) -> String {
        let s = TextRules.stripControls(raw).trimmingCharacters(in: .whitespaces)
        return s.isEmpty || Self.isUnnamedPlaceholder(s) ? unnamed : s
    }
    /// 名前の無い接続元の Mac の呼び名
    public var unnamed: String { t("名前のない Mac", "Unnamed Mac") }
    /// `.meta` に書いた「名前の無い印」か（今の `MetaBook.unknownName` と、2026-09-30 より前に書いた「名前の分からない見る側」）。
    /// 画面では言語に合わせた `unnamed` に置き換える
    public static func isUnnamedPlaceholder(_ s: String) -> Bool {
        s == MetaBook.unknownName || s == MetaBook.legacyUnknownName
    }

    /// 英語の数と名詞（「1 day」「3 days」。“day(s)” と書かない）。日本語の文には使わない
    public static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) " + (n == 1 ? one : many) }

    /// 残り時間（秒）を `m:ss` で。負なら `0:00`
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
