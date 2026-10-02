import Foundation

/// 1x と 2x の通信量の差の目安（実測）。カードに「約50%削減」と添えるための数字と文言。
///
/// 測り方（2026-09-23）: Mac Studio → MacBook、Tailscale 経由・高パフォーマンス画面共有・ダイナミック解像度オン、
/// 仮想ディスプレイ 1920×997。接続先の画面に同じ文書のスクロールを出し、10秒ずつ 1x/2x を
/// 順番の偏りが出ないよう入れ替えながら計12回、接続先の Tailscale の送信量を測った。
/// 平均で 1x は 2x より 48% 少なく（映像そのものの送信量では 52%）、1回ごとの幅は 43〜65%。
/// 画素は 1/4（75%減）だが、映像の圧縮のため通信量は画素ほどには減らない。画素から計算した 75% は使わないこと。
public enum DataSaving {
    public static let reductionPercent = 50
    public static let observedRange = 43...65

    /// カードに添える一文を3つに分けて返す（中央の「約50%削減」だけ強調して表示する）
    public static func summary(chosen: DisplayMode) -> (lead: String, emphasis: String, trail: String)? {
        let pct = tr("約\(reductionPercent)%削減", "~\(reductionPercent)% less data")
        switch chosen {
        case .x1: return (tr("通信量 ", ""), pct, tr("（2x比）", " than 2x"))
        case .x2: return (tr("1x にすると通信量 ", "1x would use "), pct, "")
        case .off: return nil
        }
    }

    /// 倍率の選択肢の名前（1x/2x だけでは何のことか分からないので、意味を併記する）
    public static func optionLabel(_ mode: DisplayMode) -> String {
        switch mode {
        case .x1: return tr("1x 等倍", "1x Standard")
        case .x2: return "2x Retina"
        case .off: return tr("自動調整しない", "Don’t adjust")
        }
    }

    /// 1x と 2x が何を描き分けるか（選択肢にポインタを重ねた時に出す）
    public static var optionHelp: String {
        tr("1x 等倍：画面の 1 点を 1 ピクセルで表示します。通信量は少なくなりますが、Retina ディスプレイでは文字が少しぼやけます。\n2x Retina：1 点を縦横 2 ピクセル（4 ピクセル）で表示します。文字はくっきりしますが、通信量は実測で約 2 倍です。",
           "1x Standard: each point is shown with one pixel. Uses less data, but text looks slightly soft on a Retina display.\n2x Retina: each point is shown with 2×2 pixels. Sharper text, but about twice the data in our measurement.")
    }

    /// 詳しい説明（ポインタを重ねた時に出す）
    public static var detail: String {
        tr("1x で表示するピクセル数は 2x の 1/4 です。通信量は画面の内容で変わり、文書をスクロールする画面での実測では 2x の約半分でした（\(observedRange.lowerBound)〜\(observedRange.upperBound)%減）。macOS は標準では 2x で表示します。回線が遅い時ほど効果が大きくなります。",
           "1x shows a quarter of the pixels of 2x. Data use depends on what’s on screen; measured while scrolling a document, 1x used about half the data of 2x (\(observedRange.lowerBound)–\(observedRange.upperBound)% less). macOS uses 2x by default. The slower the network, the more this helps.")
    }
}
