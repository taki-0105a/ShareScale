import Foundation
import ShareScaleNet
import ShareScaleProtocol

/// Host 側の付帯情報（`pairings/host/<id>.meta`。仕様「保管」）。時刻はすべて UNIX 秒（壁時計。`0...maxTime` の範囲だけ読む）
/// `{"format":1,"name":…,"created":…,"last_seen":…|null,"confirmed":…,"notice_snoozed_until":…|null}`
public struct HostMeta: Equatable, Sendable {
    /// 時刻として読む上限（2^40 秒 ≈ 西暦 36,800 年。壊れた値・極端な値で引き算があふれないように）
    public static let maxTime: Int64 = 1 << 40
    public var name: String
    public var created: Int64
    public var lastSeen: Int64?
    public var confirmed: Bool
    /// 80 日の知らせで「あとで」を選んだ時の、次に知らせてよい時刻
    public var noticeSnoozedUntil: Int64?
    public init(name: String, created: Int64, lastSeen: Int64? = nil, confirmed: Bool, noticeSnoozedUntil: Int64? = nil) {
        self.name = name; self.created = created; self.lastSeen = lastSeen; self.confirmed = confirmed; self.noticeSnoozedUntil = noticeSnoozedUntil
    }

    public func encoded() -> Data {
        func opt(_ v: Int64?) -> JSONValue { v.map { .integer($0) } ?? .null }
        return Data((JSONWriter.write(.object([
            ("format", .integer(1)), ("name", .string(name)), ("created", .integer(created)), ("last_seen", opt(lastSeen)),
            ("confirmed", .bool(confirmed)), ("notice_snoozed_until", opt(noticeSnoozedUntil)),
        ])) + "\n").utf8)
    }

    /// 厳密に読む（知らないキー・型違い・名前の規則違反は nil）
    public static func decode(_ data: Data) -> HostMeta? {
        var bytes = data
        if bytes.last == 0x0A { bytes.removeLast() }
        guard let m = (try? StrictJSON.parse(bytes))?.exactKeys(["format", "name", "created", "last_seen", "confirmed", "notice_snoozed_until"]),
              case .integer(1)? = m["format"], case let .string(raw)? = m["name"], let name = NameRules.validate(raw),
              case let .integer(created)? = m["created"], case let .bool(confirmed)? = m["confirmed"] else { return nil }
        func opt(_ v: JSONValue?) -> Int64?? {
            switch v {
            case .null?: return .some(nil)
            case let .integer(i)? where (0...maxTime).contains(i): return .some(i)
            default: return nil
            }
        }
        guard (0...maxTime).contains(created), let lastSeen = opt(m["last_seen"]), let snoozed = opt(m["notice_snoozed_until"]) else { return nil }
        return HostMeta(name: name, created: created, lastSeen: lastSeen, confirmed: confirmed, noticeSnoozedUntil: snoozed)
    }
}

/// 付帯情報の写し（Host のメニュー・80 日の知らせ・起動時の未確定の一覧が読む）。
/// `PairingRegistry` の変化（`HostEvent.registry`）を受けて更新し、`.meta` に書く:
/// - `.paired` → 作る（未確定）／`.confirmed` → 確定＋最終接続／`.seen` → 最終接続（1 時間に 1 回に間引く）／
///   `.unpaired`・`.pendingExpired` → 写しから落とし、`.meta` も消す（`SecretStore.delete` も消すが、下の後始末のため）
/// - `.meta` が無い `.key` は確定扱い（名前は `unknownName`。書くのは次に変化があった時）
/// - **知らせは起きた順に届くとは限らない**（別々のスレッドで起きた変化。例: 照合の `.seen(X)` が解除の `.unpaired(X)` より後に届く）。
///   そこで、作る・更新する前に、その id が今 `isRegistered` にあるかを確かめ、無ければ何もしない。
///   確かめた直後に解除が割り込んで `.meta` だけが残っても、その解除の知らせ（後から届く）が `.meta` を消す
/// - `handle`・`snooze` は 1 つの直列のキューから呼ぶ（`HostRuntime` の `events`）
///
/// 可変の状態（`book`）は `lock` で守る。ファイルの読み書きはロックの外で行う
public final class MetaBook: @unchecked Sendable {
    /// 名前の無い印（`.meta` に書く値。画面では `HostLanguage.displayName` が言語に合わせた「名前のない Mac」に置き換える）
    public static let unknownName = "名前のない Mac"
    /// 2026-09-30 より前に書いた名前の無い印（画面の呼び名を「接続元の Mac」に改めた。書かれたものはそのまま読み、画面で置き換える）
    public static let legacyUnknownName = "名前の分からない見る側"
    /// 最終接続の書き込みの間隔（秒）
    public static let seenWriteInterval: Int64 = 3600

    public let store: SecretStore
    private let isRegistered: @Sendable (PairingID) -> Bool
    private let problem: @Sendable (String) -> Void
    private let lock = NSLock()
    private var book: [PairingID: HostMeta] = [:]

    /// - `isRegistered`: その id が今の登録表にあるか（`{ registry.registeredIDs.contains($0) }`）
    /// - `problem`: 読み書きの問題の 1 行（記録へ）
    public init(store: SecretStore, isRegistered: @escaping @Sendable (PairingID) -> Bool, problem: @escaping @Sendable (String) -> Void) {
        self.store = store; self.isRegistered = isRegistered; self.problem = problem
    }

    /// `.meta` を読む（`HostServer.start` の前に呼ぶ）。確定していないもの（`start(unconfirmed:)` に渡す）と、読めなかったものを返す
    @discardableResult
    public func load() -> (unconfirmed: Set<PairingID>, problems: [StoreProblem]) {
        let r = store.loadMetas()
        var loaded: [PairingID: HostMeta] = [:], problems = r.problems
        for (id, data) in r.metas {
            if let m = HostMeta.decode(data) { loaded[id] = m } else { problems.append(StoreProblem(name: id.hex + ".meta", reason: .badFormat)) }
        }
        lock.withLock { book = loaded }
        for p in problems { problem("pairing info \(p.name): \(p.reason.rawValue)") }
        return (Set(loaded.filter { !$0.value.confirmed }.keys), problems)
    }

    /// 登録表に合わせる（`HostServer.start` の後に呼ぶ）: `.meta` の無いペアリングは確定扱いで写しに入れて `.meta` を書き
    /// （起動のたびに `created` が今になるのを防ぐ）、登録表に無いものは写しから落とす
    public func reconcile(registered: Set<PairingID>, now: Date) {
        let created: [(PairingID, HostMeta)] = lock.withLock {
            book = book.filter { registered.contains($0.key) }
            var made: [(PairingID, HostMeta)] = []
            for id in registered where book[id] == nil {
                let m = HostMeta(name: Self.unknownName, created: Int64(now.timeIntervalSince1970), confirmed: true)
                book[id] = m; made.append((id, m))
            }
            return made
        }
        for (id, m) in created { write(id, m) }
    }

    /// 登録表の変化を反映する（イベントを処理するキューから呼ぶ。保存を含むので重い）
    public func handle(_ change: RegistryChange, now: Date) {
        let t = Int64(now.timeIntervalSince1970)
        switch change {
        case let .paired(id, _), let .confirmed(id), let .seen(id):
            guard isRegistered(id) else { return }   // 解除の知らせより後に届いた（入れ違い）
        case let .unpaired(id), let .pendingExpired(id):
            lock.withLock { book[id] = nil }
            do { try store.deleteMeta(id) } catch { problem("pairing info \(id.hex).meta: could not delete (\(error))") }
            return
        case .codeIssued, .codeRevoked, .codeExpired, .codeAbandoned:
            return
        }
        let save: (PairingID, HostMeta)? = lock.withLock {
            switch change {
            case let .paired(id, name):
                let m = HostMeta(name: name, created: t, confirmed: false)
                book[id] = m; return (id, m)
            // 写しに無い id も無視する（登録済みのものは `reconcile` と `.paired` で必ず写しにある）
            case let .confirmed(id):
                guard var m = book[id] else { return nil }
                m.confirmed = true; m.lastSeen = t
                book[id] = m; return (id, m)
            case let .seen(id):
                guard var m = book[id] else { return nil }
                // 1 時間に 1 回に間引く。時計が戻って last_seen が未来にある時も、1 時間を超えて離れていれば書き直す
                // （引き算のあふれの確かめは守りのため。`last` は decode の範囲（0...2^40）か壁時計由来で、実際には到達しない。
                // あふれれば「離れている」として書き直す）
                if let last = m.lastSeen {
                    let (diff, overflow) = t.subtractingReportingOverflow(last)
                    if !overflow, diff.magnitude < Self.seenWriteInterval { return nil }
                }
                m.lastSeen = t
                book[id] = m; return (id, m)
            case .unpaired, .pendingExpired, .codeIssued, .codeRevoked, .codeExpired, .codeAbandoned:
                return nil   // 上で扱った
            }
        }
        if let (id, m) = save { write(id, m) }
    }

    /// 80 日の知らせの「あとで」
    public func snooze(_ id: PairingID, until: Date) {
        guard isRegistered(id) else { return }
        let m: HostMeta? = lock.withLock {
            guard var m = book[id] else { return nil }
            m.noticeSnoozedUntil = Int64(until.timeIntervalSince1970)
            book[id] = m; return m
        }
        if let m { write(id, m) }
    }

    public var entries: [PairingID: HostMeta] { lock.withLock { book } }
    public func meta(_ id: PairingID) -> HostMeta? { lock.withLock { book[id] } }

    private func write(_ id: PairingID, _ m: HostMeta) {
        do { try store.saveMeta(id, m.encoded()) } catch { problem("pairing info \(id.hex).meta: could not save (\(error))") }
    }
}
