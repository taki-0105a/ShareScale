import Foundation
import ShareScaleProtocol

/// 長く使われていない見る側の知らせ（仕様「解除」、利用者の決定 U1: 知らせるだけで自動では解除しない）。
/// 判定は `last_seen` の壁時計で行う（起動時と 1 日 1 回）。自動では消さないので、時計が大きく進んでも失われるものは無い
public enum StaleNotice {
    public static let staleAfter: Int64 = 80 * 86_400
    public static let snoozeFor: Int64 = 30 * 86_400

    /// 知らせる見る側（id の hex の順）:
    /// 確定済みで、最後に使われた時刻（`last_seen`。一度も無ければ `created`）から 80 日以上たち、
    /// その時刻が今より未来でなく、「あとで」の期限の中でないもの
    public static func due(_ metas: [PairingID: HostMeta], now: Int64) -> [PairingID] {
        metas.filter { _, m in
            guard m.confirmed else { return false }
            let last = m.lastSeen ?? m.created
            guard last <= now else { return false }
            let (age, overflow) = now.subtractingReportingOverflow(last)   // `.meta` の時刻は 0...2^40 だが、`now` は外から来るので確かめる
            guard !overflow, age >= staleAfter else { return false }
            if let until = m.noticeSnoozedUntil, now < until { return false }
            return true
        }.keys.sorted { $0.hex < $1.hex }
    }

    /// 「あとで」を選んだ時の、次に知らせてよい時刻
    public static func snoozeUntil(now: Int64) -> Int64 { now + snoozeFor }
}
