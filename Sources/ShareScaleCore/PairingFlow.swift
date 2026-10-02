import Foundation
import ShareScaleNet
import ShareScaleProtocol

/// ペアリングの流れ（仕様「ペアリング」「名乗りと確認番号」「名乗りの後の確定」の見る側）。
/// 入口（接続コードの文字列、または手入力のアドレスとキー）→ 候補を試してつなぐ（コードの秘密。余りは何も送らずに閉じる）→
/// 名乗り（`hello` → 確認番号を `onPhase(.awaitingApproval)` で画面へ → `reveal`）→ 承認の応答 `k` を受けたら `.key`（新しい秘密）と `.meta`（`confirmed: false`）を保存 →
/// すぐ `status` を最大 3 回試し（間は 1 秒・3 秒と広げる＝保存から 0・1・4 秒）、通れば `confirmed: true`（名前と候補は `status` のもの、`last_ok_addr` はつながった候補）。
/// 3 回とも失敗なら未確定のまま残す（「接続先の一覧に出ているか確かめ、出ていなければペアリングし直してください」）。
/// コードの秘密・`r_v`・確認番号は記憶の中だけ（記録に書かない）。保存するのは承認後の新しい秘密だけ
public enum PairingFlow: Sendable {
    /// 入口（読み取りと検査の済んだもの）
    public struct Entry: Equatable, Sendable {
        public let id: PairingID
        public let secret: Bytes32          // コードの秘密（名乗りまでしか使えない）
        public let port: Int
        public let addresses: [String]
        public let expiresAt: Int64?        // 接続コードの `x`（手入力には無い）
        public init(id: PairingID, secret: Bytes32, port: Int, addresses: [String], expiresAt: Int64?) {
            self.id = id; self.secret = secret; self.port = port; self.addresses = addresses; self.expiresAt = expiresAt
        }
        /// 自分の時計で `x` を 10 分以上過ぎているか（注意を出すだけで、拒否しない）
        public func probablyExpired(now: Int64) -> Bool {
            guard let x = expiresAt else { return false }
            let (limit, overflow) = now.subtractingReportingOverflow(600)
            return !overflow && limit >= x
        }
        var candidates: Connector.Candidates { Connector.Candidates(port: port, addresses: addresses) }
    }

    public enum InputError: Error, Equatable, Sendable {
        case code(PairingCode.Invalid)
        case address(ManualEntry.AddressError)
        case key(ManualEntry.KeyError)
    }

    /// 接続コードの文字列から（`PairingCode.decode` の検査）
    public static func entry(code text: String) -> Result<Entry, InputError> {
        do {
            let c = try PairingCode.decode(text)
            return .success(Entry(id: c.id, secret: c.secret, port: c.port, addresses: c.addresses, expiresAt: c.expiresAt))
        } catch let e as PairingCode.Invalid { return .failure(.code(e)) }
        catch { return .failure(.code(.badJSON)) }
    }

    /// 手入力のアドレスとキーから（`ManualEntry.parseAddress`・`decodeKey` の検査）
    public static func entry(address: String, key: String) -> Result<Entry, InputError> {
        let host: String, port: Int
        do { (host, port) = try ManualEntry.parseAddress(address) }
        catch let e as ManualEntry.AddressError { return .failure(.address(e)) }
        catch { return .failure(.address(.badHost)) }
        do {
            let k = try ManualEntry.decodeKey(key)
            return .success(Entry(id: k.id, secret: k.secret, port: port, addresses: [host], expiresAt: nil))
        } catch let e as ManualEntry.KeyError { return .failure(.key(e)) }
        catch { return .failure(.key(.badCharacter)) }
    }

    public struct Settings: Sendable {
        public var connector = Connector.Settings.standard
        public var pairTimeout: Double = 80        // 名乗り全体（確認待ちを含む）
        public var confirmAttempts = 3             // 確定の `status` を試す回数
        public var confirmInterval: Double = 1     // 1 回目と 2 回目の間（秒。Host の受け側の開き直しを待つ）。以後の間は広げる（`confirmWait`）
        public var confirmTotal: Double = 5        // 確定の `status` 1 回の候補の試行全体（つながった候補を先に試すので短くてよい）
        public init() {}
        public static let standard = Settings()

        /// `attempt` 回目（2 から）の確定を試す前に待つ秒数: `confirmInterval` の 1 倍、3 倍、5 倍、…（既定は 1 秒・3 秒）。
        /// n 回目を試し始めるのは、保存から `confirmInterval × (n − 1)²` 秒（既定は 0・1・4 秒）
        public func confirmWait(before attempt: Int) -> Double {
            confirmInterval * Double(2 * max(2, attempt) - 3)
        }
        /// 保存してから最後の確定を試し始めるまでの秒数（待ちの合計。試みそのものにかかる時間は含まない。既定は 4 秒）。
        /// Host の受け側の開き直しの最悪の時間（`ListenerSupervisor.standardReopenWorstCase`。2.2 秒＋開く時間）より十分に長くする:
        /// 1 秒おきに 3 回（2 秒）では、開き直しが 2 秒を超えると 3 回とも外れて、登録できているのに「確認待ち」の注意を出していた（計画 2g）
        public var confirmWindow: Double {
            guard confirmAttempts >= 2 else { return 0 }
            return (2...confirmAttempts).reduce(0) { $0 + confirmWait(before: $1) }
        }
    }

    /// 進み具合（画面が段階を出す）
    public enum Phase: Equatable, Sendable {
        case connecting                          // 候補を試している
        case awaitingApproval(code: Int)         // 確認番号（6 桁）を出して、接続先の承認を待っている（選んだ 1 本の分だけ、1 回）
        case confirming(attempt: Int)            // 新しい秘密で `status` を試している（1 から）
    }

    public enum Outcome: Equatable, Sendable {
        case confirmed(PairingID)                       // 保存し、`status` が通り、帳簿に確定を書けた
        case unconfirmed(PairingID, reason: String)     // 保存したが未確定のまま（`status` が 3 回とも通らない、または確定を帳簿に書けない）
        /// どちらも、追加した接続先を「選んだ接続先」にしている
        public var id: PairingID { switch self { case let .confirmed(i), let .unconfirmed(i, _): return i } }
    }
    public enum Failure: Error, Equatable, Sendable {
        case limitReached                  // 接続先が 32 件（「接続先を追加」を押せない）
        case connection(ViewerFailure)     // どの候補にもつながらない（コードの秘密で TLS が成立しない＝使用済み・期限切れのコードも含む）
        case pairing(ViewerFailure)        // 名乗りが `not_paired` で終わった（拒否・時間切れ・使用済みのコード）・応答が来ない・切れた
        case save(String)                  // 新しい秘密を保存できない（Host には保存済み。10 分で自動解除される）
        case cancelled                     // 呼び出し側の Task が取り消された。保存済みなら、その接続先は未確定（`confirmed: false`）のまま帳簿に残る
    }

    /// ペアリングを行う。`computerName` はこの Mac の名前（`SCDynamicStoreCopyComputerName` 相当。`NameRules.sanitize` を通す）。
    /// `onPhase` は進み具合（確認番号は `.awaitingApproval(code:)` で 1 回だけ渡す）。呼び出し側の Task の取り消しに応じる（`.cancelled`）
    public static func run(_ entry: Entry, book: TargetBook, computerName: @Sendable () -> String?,
                           onPhase: @escaping @Sendable (Phase) -> Void, settings: Settings = .standard) async -> Result<Outcome, Failure> {
        if book.isFull { return .failure(.limitReached) }
        onPhase(.connecting)
        let conn: Connector.Connection
        switch await Connector.connect(entry.candidates, id: entry.id, secret: entry.secret, kind: .code, settings: settings.connector) {
        case .failure(.cancelled): return .failure(.cancelled)
        case let .failure(f): return .failure(.connection(f))
        case let .success(c): conn = c
        }
        if Task.isCancelled { conn.channel.close(); return .failure(.cancelled) }
        let name = NameRules.sanitize(computerName() ?? "Mac")
        let newSecret: Bytes32
        do { newSecret = try await conn.channel.pair(name: name, showCode: { onPhase(.awaitingApproval(code: $0)) }, until: .now() + settings.pairTimeout) }
        catch {
            let f = Connector.classify(error)
            return .failure(f == .cancelled ? .cancelled : .pairing(f))
        }
        guard let initial = ViewerMeta(name: conn.address, port: entry.port, addresses: entry.addresses, lastOKAddress: conn.address, confirmed: false)
        else { return .failure(.save("invalid candidates")) }
        do { try book.add(id: entry.id, secret: newSecret, meta: initial) }
        catch { return .failure(.save("\(error)")) }
        book.selectedID = entry.id
        // 名乗りの後の確定: 新しい秘密で `status`（Host の受け側の開き直しを待つため、間を広げながら最大 3 回。最初の 1 回は開き直しの前で TLS が成立しないことが多い）
        var confirmSettings = settings.connector
        confirmSettings.total = settings.confirmTotal
        var lastReason = "status did not succeed"
        for attempt in 1...max(1, settings.confirmAttempts) {
            if attempt > 1 {
                do { try await Task.sleep(nanoseconds: UInt64(max(0, settings.confirmWait(before: attempt)) * 1e9)) } catch { return .failure(.cancelled) }
            }
            if Task.isCancelled { return .failure(.cancelled) }
            onPhase(.confirming(attempt: attempt))
            let r = await Connector.exchange(.status, expecting: .status, candidates: Connector.Candidates(initial), id: entry.id, secret: newSecret,
                                             settings: confirmSettings)
            switch r {
            case .failure(.cancelled): return .failure(.cancelled)
            case let .failure(f): lastReason = "status failed: \(f)"; continue
            case let .success(ok):
                guard case let .status(s) = ok.response else { lastReason = "status replied \(ok.response)"; continue }
                // 帳簿を読み直してから書く（確定を待つ間に付けた名前（`alias`）を消さない。点検 2f-1 の再点検）
                do {
                    try book.modify(entry.id) { loaded in
                        TargetSession.updatedMeta(loaded.entry(entry.id)?.meta ?? initial, status: s, via: ok.address, confirmed: true)
                    }
                } catch { return .success(.unconfirmed(entry.id, reason: "could not write the book: \(error)")) }
                return .success(.confirmed(entry.id))
            }
        }
        return .success(.unconfirmed(entry.id, reason: lastReason))
    }
}
