import Foundation
import ShareScaleHostCore

/// 表示言語。macOS の言語設定の並びの中で、日本語か英語の最初のもの（どちらも無ければ英語）。決め方は `HostLanguage.detect` の 1 か所
/// （標準のメニューの言語と同じになる。計画 2h の点検）。
///
/// 翻訳ファイル（.strings / Bundle.module）を使わず、訳をコードに並べて持つ。
/// このアプリは .app を手作業で組み立てるため、SwiftPM のリソース束を入れ忘れると
/// 起動時に落ちる。しかも開発機ではビルド先の束が見つかって正常に動いて見えるので、
/// 他人の環境でだけ落ちる見つけにくい壊れ方になる。それを構造的に避けるための選択。
public enum AppLanguage: Sendable {
    case ja, en
    private static let lock = NSLock()
    nonisolated(unsafe) private static var value: AppLanguage = HostLanguage.detect(Locale.preferredLanguages) == .ja ? .ja : .en
    /// テストでは切り替えて使う（ロックで守る。どのスレッドから読んでもよい）
    public static var current: AppLanguage {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// 日本語と英語を並べて書き、現在の言語の方を返す
public func tr(_ ja: String, _ en: String) -> String {
    AppLanguage.current == .ja ? ja : en
}

/// 日本語の文で、名前の直後に助詞を続ける（DESIGN.md「文言」。点検 2f-2）。名前が英数字で終われば空白を入れ（「2x Retina に」「ShareScale を」と同じ）、
/// 日本語で終われば入れない（「1x 等倍に」）。名前の中の空白はそのまま
public func jaName(_ name: String, _ particle: String) -> String {
    guard let last = name.unicodeScalars.last else { return particle }
    let asciiWord = last.isASCII && (CharacterSet.alphanumerics.contains(last) || last == ")")
    return name + (asciiWord ? " " : "") + particle
}

extension AppLanguage {
    /// `ShareScaleHostCore` の言語（`HostControlClient.notRunningGuidance` など、Host 側の文言を使う時に渡す）
    public var host: HostLanguage { self == .ja ? .ja : .en }
}
