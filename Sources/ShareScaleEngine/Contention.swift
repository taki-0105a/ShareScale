import Foundation

/// 「設定した倍率が繰り返し戻される」を見つける（仕様「倍率の維持（引き継ぎ）」の奪い合い防止。原因を問わない）。
/// - 戻された 1 回 = 倍率を直して成功した後、同じ仮想ディスプレイ（id と大きさ）がまた直す必要のある状態で見つかったこと。
///   直した後に 1 回だけ数える（直せずに見ている間は数えない）。窓の大きさが変わったもの（ダイナミック解像度）は数えない
/// - `window` 秒の中に `threshold` 回以上戻されたら立てる。`window` 秒のあいだ戻されなければ下ろす
/// - 利用者の新しい指示（`set`）と画面共有の終わりで数え直す
/// 時刻は単調な時計の秒
public struct ContentionDetector: Equatable, Sendable {
    public let window: TimeInterval
    public let threshold: Int
    public private(set) var active = false
    private var armedCondition: String?   // 直して成功した時の仮想ディスプレイ（「id 幅x高」）。戻されたら nil
    private var reverts: [TimeInterval] = []

    public init(window: TimeInterval = 60, threshold: Int = 3) { self.window = window; self.threshold = threshold }

    /// 倍率を直して成功した
    public mutating func applied(condition: String, at now: TimeInterval) {
        prune(now)
        armedCondition = condition
    }
    /// 直す必要のある状態を見つけた（直す前に呼ぶ）
    public mutating func needsCorrection(condition: String, at now: TimeInterval) {
        prune(now)
        if armedCondition == condition {
            reverts.append(now)
            if reverts.count >= threshold { active = true }
        }
        armedCondition = nil
    }
    /// 設定どおりだった
    public mutating func settled(at now: TimeInterval) {
        prune(now)
        if active && reverts.isEmpty { active = false }
    }
    public mutating func reset() { active = false; armedCondition = nil; reverts = [] }

    private mutating func prune(_ now: TimeInterval) { reverts.removeAll { now - $0 > window || now < $0 } }
}
