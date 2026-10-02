import Foundation
import ShareScaleProtocol

/// 発行中の接続コード（記憶の中だけ。Host が終わると無効）
public struct IssuedCode: Equatable, Sendable {
    public let id: PairingID
    public let secret: Bytes32
    public let issuedAt: ContinuousClock.Instant
    public let expiresAt: ContinuousClock.Instant   // Host の単調な時計で判定する
    public let wallExpiry: Int64                     // 接続コードの `x`（表示と見る側の注意にだけ使う）
    public internal(set) var consumed = false        // 最初の名乗りで使用済みになる
}

/// 登録表の変化（PSK の組が変わったので受け側を開き直す、など）。名前・最終接続の保存は 2c（`.meta`）が、この変化を受けて行う
public enum RegistryChange: Equatable, Sendable {
    case codeIssued, codeRevoked, codeExpired
    case codeAbandoned                          // 名乗りが承認されずに終わり、使用済みのコードを捨てた
    case paired(PairingID, name: String)        // 承認されて新しい秘密を保存した（名前は保存した時点の名乗りの名前）
    /// 確定待ちのペアリングが、新しい秘密で初めて照合に成功した。`.seen` を含む（最終接続の更新にも使う）
    case confirmed(PairingID)
    case seen(PairingID)                        // 確定済みのペアリングが照合に成功した（最終接続の更新に使う）
    case unpaired(PairingID)
    case pendingExpired(PairingID)              // 承認から 10 分、新しい秘密で一度も照合に成功しなかったので自動で解除した
    /// PSK の組が変わった（受け側を開き直す必要がある）。新しい case を足したらここで決める（`default` を使わない）
    public var changesPSKSet: Bool {
        switch self {
        case .codeIssued, .codeRevoked, .codeExpired, .codeAbandoned, .paired, .unpaired, .pendingExpired: return true
        case .confirmed, .seen: return false
        }
    }
}

/// Host のペアリングの登録表（仕様「有効期限と時計」「名乗りの後の確定」「解除」）。
/// 秘密は `SecretStore`（role: .host）に置き、この表は記憶の中で持つ。時計は外から渡す（`ContinuousClock.Instant`）。
/// 名前・最終接続は持たない（2c の `.meta` に一本化する。`RegistryChange` で知らせる）
///
/// 可変の状態（表・コード・確定待ち・消し直す id・観測者）は `lock` で守る。保管の読み書き（fsync を含む）と通知はロックの外で行う
public final class PairingRegistry: @unchecked Sendable {
    public let store: SecretStore
    public let codeLifetime: Duration
    public let confirmWithin: Duration   // 承認から、新しい秘密で一度も照合に成功しなければ自動で解除する
    private let lock = NSLock()
    private var registered: [PairingID: Bytes32] = [:]
    private var code: IssuedCode?
    private var pending: [PairingID: ContinuousClock.Instant] = [:]
    /// 表からは外したが、秘密のファイルを消せなかった id（次の `sweep` で消し直す。照合には使わない。捨てない）
    private var retryDelete: Set<PairingID> = []
    /// 表から外し、今ロックの外でファイルを消している id（`load` が消している途中のファイルを表に戻さないように）
    private var deleting: Set<PairingID> = []
    private var observer: (@Sendable (RegistryChange) -> Void)?
    /// 試験用: `completePairing` が保存した後、表に入れる前に呼ぶ
    var afterSaveHook: (@Sendable (PairingID) -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }
    private var hook: (@Sendable (PairingID) -> Void)?

    public init(store: SecretStore, codeLifetime: Duration = .seconds(600), confirmWithin: Duration = .seconds(600)) {
        self.store = store; self.codeLifetime = codeLifetime; self.confirmWithin = confirmWithin
    }

    /// 変化を受け取る相手を 1 つだけ設定する（`HostServer` が自分の `init` で設定する。後から設定したものが前のものに代わる）。
    /// 通知はロックの外で、変化を起こした関数を呼んだスレッドから同期に呼ぶ。
    /// **別々のスレッドで起きた変化の知らせは、表を変えた順に届くとは限らない**（例: 照合の `.seen(X)` が、メニューの解除の `.unpaired(X)` の後に届く）。
    /// 受け取る側は、知らせの id が今 `registeredIDs` にあるかを確かめてから付帯情報を作る・更新すること
    func observe(_ f: @escaping @Sendable (RegistryChange) -> Void) { lock.withLock { observer = f } }
    private func notify(_ c: RegistryChange) {
        let f = lock.withLock { observer }
        f?(c)
    }

    /// 保管から読む。`unconfirmed` は付帯情報（`.meta`）で確定していないもの（読んだ時点から 10 分を数え直す）。
    /// すでに確定待ちのもの（`stop` の後の `start` など、同じ Host の中で読み直した時）は、その期限を保つ（延ばさない）。
    /// この Host の中ですでに確定したもの（読む前から表にあり、確定待ちでないもの）は、`unconfirmed` に入っていても確定待ちに戻さない。
    /// 消し直し待ち・消している途中の id は、ファイルが残っていても表に入れない
    @discardableResult
    public func load(unconfirmed: Set<PairingID> = [], now: ContinuousClock.Instant) -> [StoreProblem] {
        let r = store.loadAll()
        lock.withLock {
            let confirmedHere = Set(registered.keys).subtracting(pending.keys)
            registered = Dictionary(uniqueKeysWithValues: r.pairings.filter { !retryDelete.contains($0.id) && !deleting.contains($0.id) }
                                                                     .map { ($0.id, $0.secret) })
            var next: [PairingID: ContinuousClock.Instant] = [:]
            for id in unconfirmed where registered[id] != nil && !confirmedHere.contains(id) { next[id] = now + confirmWithin }
            for (id, deadline) in pending where registered[id] != nil { next[id] = min(deadline, next[id] ?? deadline) }
            pending = next
        }
        return r.problems
    }

    public var count: Int { lock.withLock { registered.count } }
    public var isFull: Bool { lock.withLock { registered.count >= Limits.maxPairings } }
    public var currentCode: IssuedCode? { lock.withLock { code } }
    public var pendingIDs: Set<PairingID> { lock.withLock { Set(pending.keys) } }
    public var registeredIDs: Set<PairingID> { lock.withLock { Set(registered.keys) } }

    /// 受け側に渡す PSK の組（登録済み＋発行中のコード）
    public var pskSet: [PairingID: Bytes32] {
        lock.withLock {
            var m = registered
            if let c = code { m[c.id] = c.secret }
            return m
        }
    }

    /// 新しいコードを発行する（前のコードは無効になる）。上限に達していれば nil。`wallNow` は表示用の壁時計
    public func issueCode(now: ContinuousClock.Instant, wallNow: Date = Date()) -> IssuedCode? {
        let issued: IssuedCode? = lock.withLock {
            guard registered.count < Limits.maxPairings, let secret = Bytes32.random(), let idRaw = Bytes32.random(),
                  let id = PairingID(bytes: Array(idRaw.data.prefix(PairingID.byteCount))), registered[id] == nil,
                  !retryDelete.contains(id), !deleting.contains(id) else { return nil }
            let c = IssuedCode(id: id, secret: secret, issuedAt: now, expiresAt: now + codeLifetime,
                               wallExpiry: Int64(wallNow.timeIntervalSince1970) + Int64(codeLifetime.components.seconds))
            code = c
            return c
        }
        if issued != nil { notify(.codeIssued) }
        return issued
    }

    public func revokeCode() {
        let had: Bool = lock.withLock { let h = code != nil; code = nil; return h }
        if had { notify(.codeRevoked) }
    }

    /// 照合の時点の表から引く（発行中のコードはコードの秘密、登録済みは登録済みの秘密）
    public func lookup(_ id: PairingID, now: ContinuousClock.Instant) -> (secret: Bytes32, kind: PairingKind)? {
        lock.withLock {
            if let c = code, c.id == id { return now < c.expiresAt ? (c.secret, .code) : nil }
            if let s = registered[id] { return (s, .registered) }
            return nil
        }
    }

    /// 名乗りの proof が通った時点で呼ぶ。この時点でコードを使用済みにする（以後の結果にかかわらず同じコードは使えない）
    public func consumeCode(_ id: PairingID, now: ContinuousClock.Instant) -> Bool {
        lock.withLock {
            guard var c = code, c.id == id, !c.consumed, now < c.expiresAt else { return false }
            c.consumed = true; code = c
            return true
        }
    }

    /// 承認された。新しい秘密を作って保存し、確定待ち（10 分）に入れる。コードは役目を終える。
    /// 保存（fsync を含む）はロックの外で行い、その後にもう一度コードを確かめてから表に入れる。
    /// - 保存に失敗したら nil（コードは残す。その接続の結末の `abandonCode` が捨てる）
    /// - 保存している間にコードが発行し直された・取り消された時は、保存したファイルを消して nil
    ///   （このコードは、結末の `abandonCode` が捨てる。すでに別のコードに代わっていれば、id が違うので何もしない）
    public func completePairing(codeID: PairingID, name: String, now: ContinuousClock.Instant) -> Bytes32? {
        let prepared: (secret: Bytes32, hook: (@Sendable (PairingID) -> Void)?)? = lock.withLock {
            guard let c = code, c.id == codeID, c.consumed, let secret = Bytes32.random() else { return nil }
            return (secret, hook)
        }
        guard let prepared else { return nil }
        let secret = prepared.secret
        do { try store.save(StoredPairing(id: codeID, secret: secret)) } catch { return nil }
        prepared.hook?(codeID)
        let stillCurrent: Bool = lock.withLock {
            guard let c = code, c.id == codeID, c.consumed else { deleting.insert(codeID); return false }
            registered[codeID] = secret
            pending[codeID] = now + confirmWithin
            code = nil
            return true
        }
        guard stillCurrent else { deleteOrRetryLater(codeID); return nil }
        notify(.paired(codeID, name: name))
        return secret
    }

    /// 名乗りが承認されずに終わった（拒否・時間切れ・約束の不一致・切断）。使用済みのコードを捨てる。
    /// 呼ぶのは、そのコードで名乗った接続の結末だけ（無関係な接続の失敗では捨てない。`id` が今のコードと違えば何もしない）
    public func abandonCode(_ id: PairingID) {
        let had: Bool = lock.withLock {
            guard let c = code, c.id == id, c.consumed else { return false }
            code = nil; return true
        }
        if had { notify(.codeAbandoned) }
    }

    /// 登録済みの秘密で照合に成功した。確定待ちなら確定して `.confirmed`、確定済みなら `.seen` を出す（どちらも受け側は開き直さない）。
    /// 確定待ちの期限を過ぎていたら確定しない（次の `sweep` で解除される。仕様「名乗りの後の確定」の境界の扱い）
    public func markSeen(_ id: PairingID, now: ContinuousClock.Instant) {
        let change: RegistryChange? = lock.withLock {
            guard registered[id] != nil else { return nil }
            guard let deadline = pending[id] else { return .seen(id) }
            guard now < deadline else { return nil }
            pending[id] = nil
            return .confirmed(id)
        }
        if let change { notify(change) }
    }

    /// 期限を過ぎたコードと、確定されないペアリングを片付ける（定期的に呼ぶ）。
    /// 使用済みのコード（名乗りの承認待ち）は期限が来ても捨てない。その接続の結末が `abandonCode`・`completePairing` で必ず片付ける。
    /// 秘密のファイルはロックの外で消す。消せなかったものは次の `sweep` で消し直す（その時は変化を知らせない）
    @discardableResult
    public func sweep(now: ContinuousClock.Instant) -> [RegistryChange] {
        var changes: [RegistryChange] = []
        let (expired, retry): ([PairingID], Set<PairingID>) = lock.withLock {
            if let c = code, !c.consumed, now >= c.expiresAt { code = nil; changes.append(.codeExpired) }
            var ids: [PairingID] = []
            for (id, deadline) in pending where now >= deadline {
                pending[id] = nil; registered[id] = nil
                ids.append(id)
            }
            let r = retryDelete; retryDelete = []
            deleting.formUnion(ids); deleting.formUnion(r)
            return (ids, r)
        }
        for id in retry { deleteOrRetryLater(id) }
        for id in expired { deleteOrRetryLater(id); changes.append(.pendingExpired(id)) }
        for c in changes { notify(c) }
        return changes
    }

    /// 解除（メニュー・`unpair`）。表から外してから（照合に使えなくなる）、ロックの外で秘密のファイルを消す。
    /// 消せなければ表に戻して throw する（応答は `busy`）。変化を知らせるのは、表から外して消し終えた 1 回だけ
    /// （同じ id の解除が重なっても 1 回。表に無い id はファイルだけを消し、知らせない）
    public func unpair(_ id: PairingID) throws {
        let taken: (secret: Bytes32, deadline: ContinuousClock.Instant?)? = lock.withLock {
            retryDelete.remove(id)
            deleting.insert(id)
            guard let s = registered.removeValue(forKey: id) else { return nil }
            return (s, pending.removeValue(forKey: id))
        }
        do { try store.delete(id) } catch {
            lock.withLock {
                deleting.remove(id)
                if let taken { registered[id] = taken.secret; if let d = taken.deadline { pending[id] = d } }
            }
            throw error
        }
        lock.withLock { _ = deleting.remove(id) }
        if taken != nil { notify(.unpaired(id)) }
    }

    /// ロックの外で秘密のファイルを消す（呼ぶ前に、ロックの中で表から外し `deleting` に入れておく）。
    /// 消せなければ、次の `sweep` で消し直す（件数で捨てない。消えるまでファイルが残り、次の起動で表に戻るのを防ぐため）
    private func deleteOrRetryLater(_ id: PairingID) {
        let ok = (try? store.delete(id)) != nil
        lock.withLock {
            deleting.remove(id)
            if !ok { retryDelete.insert(id) }
        }
    }
    /// 試験用: 消し直し待ちの id
    var pendingDeletes: Set<PairingID> { lock.withLock { retryDelete } }
}
