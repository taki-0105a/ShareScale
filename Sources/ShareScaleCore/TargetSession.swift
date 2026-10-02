import Foundation
import ShareScaleNet
import ShareScaleProtocol

/// 1 つの接続先との通信（`TargetControlling` の本物）。`Connector` で候補を試し、照合済みの `status`／`set` の応答で帳簿の付帯情報を更新する:
/// - 候補と通信口は、照合済みの応答の `addrs` でだけ書き換える（`manual` が真なら書き換えない）
/// - `last_ok_addr` はつながった候補。`confirmed` は照合済みの応答（`paused`・`busy` の失敗の応答を含む）が 1 度通れば真
/// - 名前は応答の `name`（制御文字を除く）
/// - 書く前に帳簿を読み直す（画面で `manual: true` にした手直しを、古い写しで上書きしないため）。同時の `status`／`set` は後勝ちでよい
///   （どちらも照合済みの応答で、候補は Host の今の `addrs`）
/// 削除（`remove`）は `unpair` を送り、`ok`（または `not_paired`＝解除済み）なら `.key`→`.meta` の順に消す。届かなければ見る側だけで消し、
/// 「接続先のメニューからも解除してください」と案内する（`.removedLocally`）
public final class TargetSession: TargetControlling, @unchecked Sendable {
    public let book: TargetBook
    public let id: PairingID
    private let secret: Bytes32
    private let settings: Connector.Settings
    private let lock = NSLock()
    private var meta: ViewerMeta

    public init(book: TargetBook, entry: TargetEntry, settings: Connector.Settings = .standard) {
        self.book = book; id = entry.id; secret = entry.secret; meta = entry.meta; self.settings = settings
    }

    /// 今の付帯情報（応答で更新されたもの）
    public var currentMeta: ViewerMeta { lock.withLock { meta } }
    public var entry: TargetEntry { TargetEntry(id: id, secret: secret, meta: currentMeta) }

    public func status() async -> Result<RemoteState, ViewerFailure> { await request(.status, expecting: .status) }
    public func set(_ mode: DisplayMode) async -> Result<RemoteState, ViewerFailure> { await request(.set(mode.wire), expecting: .set) }

    private func request(_ req: Request, expecting: Response.Expectation) async -> Result<RemoteState, ViewerFailure> {
        let m = currentMeta
        switch await Connector.exchange(req, expecting: expecting, candidates: Connector.Candidates(m), id: id, secret: secret, settings: settings) {
        case let .failure(f): return .failure(f)
        case let .success(ok):
            switch ok.response {
            case let .status(s):
                write { Self.updatedMeta($0, status: s, via: ok.address, confirmed: true) }
                return .success(RemoteState(s))
            case .error(.paused), .error(.busy):
                // 照合は通っている（Host はこのペアリングを確定している）。候補は応答に無いので、確定とつながった候補だけを書く
                write { Self.confirmedMeta($0, via: ok.address) }
                return .failure(ViewerFailure(response: ok.response) ?? .other("unexpected response"))
            case .error, .helloChallenge, .paired, .log, .ok:
                return .failure(ViewerFailure(response: ok.response) ?? .other("unexpected response"))
            }
        }
    }

    /// 帳簿を読み直してから更新して書く（その id が読めない（`problems` に載る）なら今の写しから）。変わらなければ書かない。
    /// 読めた帳簿にその id が無く、`problems` にも無ければ、問い合わせの間に削除されたので書き戻さない（`.meta` だけが残るのを防ぐ）
    /// 読み直しと書き込みは `TargetBook.modify` の 1 つの鍵の中（名前の変更と入れ違っても、付けた名前を古い写しで消さない。点検 2f-1）
    private func write(_ update: (ViewerMeta) -> ViewerMeta) {
        let current = currentMeta
        var updated = update(current)
        let id = id
        try? book.modify(id) { loaded in
            let base: ViewerMeta
            if let m = loaded.entry(id)?.meta {
                base = m
            } else if loaded.problems.contains(where: { $0.name.hasPrefix(id.hex) }) {
                base = current
            } else {
                return nil   // 問い合わせの間に削除された（書き戻さない）
            }
            updated = update(base)
            return updated != base ? updated : nil
        }
        lock.withLock { meta = updated }
    }

    /// 照合済みの応答で付帯情報を更新した形（純粋な関数）。`manual` なら候補と通信口は変えない。名前は応答の名前（空なら今のまま）。
    /// 利用者が付けた名前（`alias`）は Host の名前が変わっても保つ（計画 2f-1 案 6）
    public static func updatedMeta(_ m: ViewerMeta, status s: StatusPayload, via address: String, confirmed: Bool) -> ViewerMeta {
        let name = TextRules.stripControls(s.name)
        let port = m.manual ? m.port : s.port
        let addrs = m.manual ? m.addresses : s.addresses
        return ViewerMeta(name: name.isEmpty ? m.name : name, port: port, addresses: addrs, manual: m.manual, lastOKAddress: address, confirmed: confirmed || m.confirmed,
                          alias: m.alias)
            ?? m
    }

    /// 照合済みの失敗の応答（`paused`・`busy`）で、確定とつながった候補だけを更新した形（純粋な関数）
    public static func confirmedMeta(_ m: ViewerMeta, via address: String) -> ViewerMeta {
        ViewerMeta(name: m.name, port: m.port, addresses: m.addresses, manual: m.manual, lastOKAddress: address, confirmed: true, alias: m.alias) ?? m
    }

    /// 利用者が名前を付け直した（記憶の中の写しにも当てる。帳簿は `ViewerTargets.rename` が書く）。
    /// 帳簿を読めない時に写しから書き戻しても、付けた名前が消えないようにするため
    public func adoptAlias(_ alias: String?) {
        lock.withLock { meta.alias = alias }
    }

    public enum Removal: Equatable, Sendable {
        case removed             // Host にも解除を伝えた（`ok`、または `not_paired`／TLS が成立しない＝解除済み）
        case removedLocally      // 届かなかった（見る側だけで消した。「接続先のメニューからも解除してください」）
    }

    /// 接続先を削除する（`unpair` を送ってから `.key`→`.meta` を消す）。消せなければ throw
    public func remove() async throws -> Removal {
        let m = currentMeta
        let r = await Connector.exchange(.unpair, expecting: .unpair, candidates: Connector.Candidates(m), id: id, secret: secret, settings: settings)
        try book.remove(id)
        switch r {
        case .success(let ok):
            if case .error(.notPaired) = ok.response { return .removed }     // 2 回目の unpair、または Host 側で解除済み
            if case .ok = ok.response { return .removed }
            return .removedLocally
        case .failure(.handshakeFailed): return .removed                     // Host に無い秘密（解除済み）
        case .failure: return .removedLocally
        }
    }
}
