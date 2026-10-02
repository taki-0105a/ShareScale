import Foundation

/// 設定の窓のタブの高さの決め方（計画 2h。実機確認 A: 「接続先」のタブから「この Mac の接続先」のタブに移っても、窓が前のタブの高さのままで、
/// 中身の大半がスクロールしないと見えなかった）。
/// タブの高さは「中身の高さ」と「画面に収まる上限」の小さい方にする（上限を超える分は、タブの中をスクロールする。接続元の Mac が 32 台の時など）
public enum SettingsLayout {
    /// 上限の最大（大きい画面でも、これより高くしない）。「一般」のタブのいちばん高い形（英語・通知が許可されていない・ログイン項目の承認待ち）が、
    /// スクロールなしで収まる高さ（試験で縛る。点検 2h で 760 から上げた）
    public static let tallest: Double = 820
    /// 上限の最小（とても小さい画面でも、これより低くしない）
    public static let shortest: Double = 280
    /// 画面の見える高さから引く分（窓の題名とタブの並びの高さ、画面の端との余白）
    public static let reserved: Double = 120
    /// 画面の見える高さが分からない時の上限
    public static let fallback: Double = 600

    /// タブの中身の高さの上限。`visibleHeight` は画面の見える高さ（メニューバーと Dock を除いたもの。分からなければ nil）。
    /// 高さ 800pt ほどの画面（見える高さ 700pt 前後）でも、窓が画面からはみ出さない
    public static func maxPaneHeight(visibleHeight: Double?) -> Double {
        guard let v = visibleHeight, v.isFinite, v > 0 else { return fallback }
        return min(tallest, max(shortest, v - reserved))
    }

    /// 入れ物が上限の計算に使っている画面（その窓のある画面の見える高さ）と、それを切り替えた時刻
    public struct PaneScreen: Equatable, Sendable {
        public var visibleHeight: Double?
        /// 画面を切り替えた時刻（単調な時計の秒。最初に決めた時は nil）
        public var changedAt: Double?
        public init(visibleHeight: Double? = nil, changedAt: Double? = nil) { self.visibleHeight = visibleHeight; self.changedAt = changedAt }
    }
    /// 画面を切り替えた後、大きくなる向きの切り替えを受け付けない時間（秒）
    public static let settle: Double = 1

    /// 窓のある画面が変わった知らせを採り入れる（純粋な関数。点検 2h・再点検 2h）。
    /// 上限が変わると窓の高さが変わり、2 つの画面の境目では、それで窓の載る画面がまた変わることがある。
    /// 切り替えた直後（`settle` 秒）は、**小さくなる向きの知らせだけを採り、大きくなる向きは捨てる**:
    /// - 入れ替わりは多くても 2 回（大きい方へ切り替えた直後に小さい方へ戻る 1 回まで）で止まる
    /// - 捨てて残る値は、必ず小さい側（上限が小さい＝窓がどちらの画面にも収まる側）。捨てた値は後で読み直さないが、
    ///   残るのが小さい側なので、窓が画面からはみ出すことはない（次に画面が変わった知らせで取り直す）
    /// - 大きい画面から小さい画面へ移った知らせは、直後でも採る（はみ出さないことを優先する）
    /// 最初の 1 回と、落ち着いた後の知らせは、どちらの向きも採る
    public static func adopt(_ visibleHeight: Double?, at now: Double, into screen: PaneScreen) -> PaneScreen {
        guard let v = visibleHeight, v.isFinite, v > 0, v != screen.visibleHeight else { return screen }
        guard let current = screen.visibleHeight else { return PaneScreen(visibleHeight: v, changedAt: nil) }
        if v > current, let t = screen.changedAt, now - t < settle { return screen }
        return PaneScreen(visibleHeight: v, changedAt: now)
    }
}
