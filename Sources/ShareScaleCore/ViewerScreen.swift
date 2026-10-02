import Foundation
import ShareScaleHostCore

extension ViewerModel {
    /// 案内を「注意」（`exclamationmark.triangle`・orange）で出すか。偽なら「お知らせ」（`info.circle`・secondary）。
    /// 失敗・未確定・一時停止・直近の失敗・特定できない・見つからないは注意、画面共有が未接続・ほかの見る側が変えた・未登録はお知らせ
    public var noticeIsWarning: Bool {
        guard hasTarget else { return false }
        if failure != nil || targetUnconfirmed { return true }
        guard let s = state else { return false }
        return s.paused || s.lastError != nil || s.virtualAmbiguous || (s.sessionActive && s.virtualDisplay == nil)
    }

    /// 案内に添える「〜の設定を開く…」（ローカルネットワークが許可されていない時だけ。計画 2f-1 案 5）
    public var noticeAction: DiagnosticAction? {
        hasTarget && failure == .localNetworkDenied ? .openLocalNetworkSettings : nil
    }
}
