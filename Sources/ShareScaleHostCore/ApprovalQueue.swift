import Foundation

/// 確認の窓の待ち行列（純粋な状態機械。AppKit を持たない。`ShareScaleHostUI` の窓がこれに従って動く）。
/// 名乗りは複数の接続から同時に届くので、1 つずつ出す。各操作は「窓にしてもらうこと」（`Command`）の列を返す:
/// - `present(r)`: r を窓に出す（既存の表示は差し替える）
/// - `close`: 窓を閉じる
/// - `resume(r, answer)`: r の答えを返す（**1 つの r につき必ず 1 回だけ**。答え・取り下げ・取り消しのどれか最初のもの）
///
/// 決まり:
/// - `answer` は `current` と一致する時だけ効く（二重の答え・取り下げた後の答え・待ち行列の中のものへの答えは何もしない）
/// - `withdraw` は待ち行列の中なら外して `false` を返し、表示中なら `false` を返して閉じ、次があれば出す。
///   知らないものは「先に取り消された」として覚え（`cancelledEarly`。上限 64、超えたら古いものから捨てる）、後から `enqueue` されたら出さずに `false` を返す
///   （取り消しが登録より先に main に届いた時のため）。ただし終えたばかりのもの（`recentlyFinished`。上限 64）は覚えない（答えた後の取り下げ）
/// - 状態の変更はすべて同じ Task（main）の中で行うこと（窓の実装の責任）
public struct ApprovalQueue: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        case present(ApprovalRequest)
        case close
        case resume(ApprovalRequest, Bool)
    }
    public static let maxCancelledEarly = 64
    public private(set) var waiting: [ApprovalRequest] = []
    public private(set) var current: ApprovalRequest?
    public private(set) var cancelledEarly: [ApprovalRequest] = []
    public private(set) var recentlyFinished: [ApprovalRequest] = []
    public init() {}

    /// 新しい名乗り。先に取り消されていれば出さずに `false`。表示中のものが無ければすぐ出す
    public mutating func enqueue(_ r: ApprovalRequest) -> [Command] {
        if let i = cancelledEarly.firstIndex(of: r) { cancelledEarly.remove(at: i); return [.resume(r, false)] }
        if current == nil { current = r; return [.present(r)] }
        waiting.append(r)
        return []
    }

    /// 窓の答え（`true` = 追加する）。表示中のものと一致する時だけ
    public mutating func answer(_ r: ApprovalRequest, _ ok: Bool) -> [Command] {
        guard current == r else { return [] }
        return [.resume(r, ok)] + advance()
    }

    /// 取り下げ・取り消し（時間切れ・見る側が閉じた・Host がその接続を切った・Task の取り消し）
    public mutating func withdraw(_ r: ApprovalRequest) -> [Command] {
        if let i = waiting.firstIndex(of: r) {
            waiting.remove(at: i)
            finished(r)
            return [.resume(r, false)]
        }
        guard current == r else {
            if !cancelledEarly.contains(r), !recentlyFinished.contains(r) {
                cancelledEarly.append(r)
                if cancelledEarly.count > Self.maxCancelledEarly { cancelledEarly.removeFirst() }
            }
            return []
        }
        return [.resume(r, false)] + advance()
    }

    /// 終えた名乗りを覚える（答えた後の取り下げを「先に取り消された」と取り違えないため）
    private mutating func finished(_ r: ApprovalRequest) {
        recentlyFinished.append(r)
        if recentlyFinished.count > Self.maxCancelledEarly { recentlyFinished.removeFirst() }
    }

    /// 表示中のものを終え、次があれば出す
    private mutating func advance() -> [Command] {
        if let r = current { finished(r) }
        current = nil
        guard !waiting.isEmpty else { return [.close] }
        let next = waiting.removeFirst()
        current = next
        return [.close, .present(next)]
    }
}
