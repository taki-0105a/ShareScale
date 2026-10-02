import Foundation
import Network
import ShareScaleNet
import ShareScaleProtocol

/// 候補アドレスの試し方（仕様「見る側」）。
/// - 前回つながった候補（`lastOK`）があれば、まずそれだけを試す（1 候補の上限 5 秒）
/// - つながらなければ残りの候補を `stagger`（300 ミリ秒）ずつずらして並行に試す（`.local` の名前解決は 3 秒を超えることがあるため）。
///   すでに始めた候補がすべて失敗していれば、次はずらさずにすぐ始める
/// - 最初に `.ready`＋TLS の版・方式の確認（`SessionCheck`）まで済んだもの（`ViewerChannel.open` が返したもの）を使う
/// - 並行に試した接続は途中で打ち切らない。選ばれなかった接続（余り）が `.ready` まで進んだ時は、
///   登録済みの秘密なら `status` だけを送って応答を捨てて閉じ、コードの秘密なら何も送らずに閉じる（Host では失敗 1 件に数えられるが問題にならない）。
///   全体の上限・呼び出し側の取り消し・全候補の失敗で戻った後に `.ready` になった接続も、同じく余りとして片付ける
/// - 全体の上限（`total`。既定 15 秒）を 1 つ持つ。各接続の上限（`.ready` まで 5 秒）は `ShareScaleNet` の既定に従う。
///   1 往復の締め切り（`exchange`）はつないでから別に取る（10 秒。Host の 1 接続の上限と同じ）
/// - 候補の締め切りは全体の締め切りを超えないので、両方が同じ時刻になることがある。全体の締め切りで打ち切られた候補の時間切れは候補の失敗に数えず、
///   全候補の失敗（`.exhausted`）が全体の締め切りの後に届いた時も、全体の時間切れ（`.timeout`）と同じに扱う（どちらが先に届くかで
///   理由が「届かない」と「時間切れ」に揺れていた。計画 2f-1 の点検）
/// - 候補のどれかがこの Mac 自身を指していれば（同じ Mac の中の Host。`LocalIdentity`）、127.0.0.1 を先頭に足して単独で先に試し、
///   この Mac 自身を指す候補そのものはつながない（同じ Mac の中では受理されるのに通信が進まないため。実機確認 2026-09-30）。
///   127.0.0.1 でつながった時の `Connection.address` は、この Mac 自身を指していた候補（帳簿の `last_ok_addr` が候補の中に留まるように）。
///   127.0.0.1 は帳簿（`.meta`）には書かない（つなぐたびに判定するので、`status` の `addrs` で候補が書き換わっても同じ判定が当たる）
/// - 名前解決や外への通信はここで初めて起きる（試験はループバックだけを候補にする）
public enum Connector: Sendable {
    public struct Settings: Sendable {
        public var readyTimeout: Double = 5      // 候補 1 つの接続（`.ready` まで）
        public var stagger: Double = 0.3         // 並行に試す時のずらし
        public var total: Double = 15            // 候補の試行全体
        public var exchange: Double = 10         // つないでから、1 往復（送信と受信）を終えるまで
        public var surplusTimeout: Double = 5    // 余りの接続で `status` を送って閉じるまで
        /// この Mac 自身（候補がこの Mac を指すかの判定。試験では差し替える）
        public var localIdentity: @Sendable () -> LocalIdentity = { LocalIdentity.current() }
        public init() {}
        public static let standard = Settings()
    }

    /// 試す候補（`ViewerMeta` か `PairingCode` から）
    public struct Candidates: Equatable, Sendable {
        public var port: Int
        public var addresses: [String]
        public var lastOK: String?
        public init(port: Int, addresses: [String], lastOK: String? = nil) {
            self.port = port; self.addresses = addresses; self.lastOK = addresses.contains(lastOK ?? "") ? lastOK : nil
        }
        public init(_ m: ViewerMeta) { self.init(port: m.port, addresses: m.addresses, lastOK: m.lastOKAddress) }
        public init(_ c: PairingCode) { self.init(port: c.port, addresses: c.addresses) }
        /// 試す順（前回つながった候補が先。あとは書かれた順）
        var ordered: [String] {
            guard let l = lastOK, let i = addresses.firstIndex(of: l) else { return addresses }
            var a = addresses; a.remove(at: i); return [l] + a
        }

        /// 1 回の試み（つなぐアドレスと、つながった時に `Connection.address` として返す候補）
        public struct Attempt: Equatable, Sendable {
            public let dial: String
            public let report: String
            public init(dial: String, report: String) { self.dial = dial; self.report = report }
            init(_ a: String) { self.init(dial: a, report: a) }
        }

        /// 試し方（純粋な関数）。`alone` は単独で先に試す 1 つ（つながらなければ `rest` を試す）。
        /// - 候補のどれかがこの Mac 自身を指す: `alone` は 127.0.0.1（`report` はその候補。前回つながった候補がこの Mac 自身ならそれ）。
        ///   `rest` はこの Mac 自身を指さない候補（127.0.0.1 が候補にあっても重ねない）
        /// - そうでなければ従来どおり: 前回つながった候補を `alone`、残りを `rest`
        public func plan(_ me: LocalIdentity) -> (alone: Attempt?, rest: [Attempt]) {
            let order = ordered
            let own = order.filter(me.pointsToSelf)
            if let first = own.first {
                let report = lastOK.flatMap { own.contains($0) ? $0 : nil } ?? first
                let others = order.filter { !me.pointsToSelf($0) && $0 != LocalIdentity.loopback }
                return (Attempt(dial: LocalIdentity.loopback, report: report), others.map(Attempt.init))
            }
            if let l = lastOK, l == order.first { return (Attempt(l), order.dropFirst().map(Attempt.init)) }
            return (nil, order.map(Attempt.init))
        }
    }

    /// 秘密の種類（余りの接続の扱いが違う）
    public enum SecretKind: Sendable { case registered, code }

    /// つながった 1 本（選んだ候補と開いた接続）。`hello`・`set`・`unpair` はこの 1 本にだけ送る
    public struct Connection: Sendable {
        public let address: String
        public let channel: ViewerChannel
    }

    /// 候補を試して、最初につながった 1 本を返す。全部つながらなければ理由（届かない／ローカルネットワーク拒否／TLS が成立しない／時間切れ）。
    /// 呼び出し側の Task が取り消されたら `.cancelled` で戻る（試している接続は打ち切らず、余りとして片付ける）
    public static func connect(_ c: Candidates, id: PairingID, secret: Bytes32, kind: SecretKind,
                               settings: Settings = .standard) async -> Result<Connection, ViewerFailure> {
        await connect(c, id: id, secret: secret, kind: kind, settings: settings, startTask: startImmediately)
    }

    /// 候補 1 つの `Task` の始め方（試験の差し込み口。本体（`body`）の前に待ちを挟んで、`Task` がまだ走っていない間の
    /// ずらしの判定を確かめる）。製品は `startImmediately`
    typealias StartTask = @Sendable (_ address: String, _ body: @escaping @Sendable () async -> Bool) -> Task<Bool, Never>
    static let startImmediately: StartTask = { _, body in Task { await body() } }

    static func connect(_ c: Candidates, id: PairingID, secret: Bytes32, kind: SecretKind,
                        settings: Settings, startTask: @escaping StartTask) async -> Result<Connection, ViewerFailure> {
        let plan = c.plan(settings.localIdentity())
        guard plan.alone != nil || !plan.rest.isEmpty, let port = NWEndpoint.Port(rawValue: UInt16(clamping: c.port)) else { return .failure(.unreachable) }
        let deadline = DispatchTime.now() + settings.total
        let race = Race()
        let (stream, sink) = AsyncStream<Event>.makeStream()
        // 候補 1 つを試す。「始めた」の印は Task を作る前に同期に立てる（ずらしの判定が、まだ走っていない Task を「失敗済み」と見ないように）。
        // `.ready` の後、すでに選ばれた 1 本があれば（または呼び出し側が戻った後なら）余りの扱いをして true を返す
        @Sendable func attempt(_ a: Candidates.Attempt) -> Task<Bool, Never> {
            race.started()
            let address = a.report
            return startTask(a.dial) {
                let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(a.dial), port: port)
                let ch: ViewerChannel
                do { ch = try await ViewerChannel.open(to: endpoint, id: id, secret: secret, until: min(.now() + settings.readyTimeout, deadline)) }
                catch {
                    race.failed()
                    sink.yield(.failed(address, (error as? NetError) ?? (error is CancellationError ? .cancelled : .malformedResponse)))
                    return false
                }
                if race.choose() {
                    // `connect` がすでに戻って流れが閉じていたら、受け手がいないので余りとして片付ける
                    if case .terminated = sink.yield(.ready(Connection(address: address, channel: ch))) {
                        await Self.closeSurplus(ch, kind: kind, timeout: settings.surplusTimeout)
                    }
                } else {
                    await Self.closeSurplus(ch, kind: kind, timeout: settings.surplusTimeout)
                }
                return true
            }
        }
        let scheduler = Task {
            var tasks: [Task<Bool, Never>] = []
            if let first = plan.alone {
                let t = attempt(first); tasks.append(t)
                if await t.value { return }   // つながった（余りは無い）
            }
            for (i, a) in plan.rest.enumerated() {
                if race.isChosen { break }
                if i > 0 { await race.waitStagger(settings.stagger) }
                if race.isChosen { break }
                tasks.append(attempt(a))
            }
            for t in tasks { _ = await t.value }
            sink.yield(.exhausted)
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, settings.total) * 1e9))
            if !Task.isCancelled { sink.yield(.timeout) }
        }
        defer { timer.cancel(); sink.finish() }
        _ = scheduler
        var tally = Tally()
        var result: Result<Connection, ViewerFailure>?
        for await e in stream {
            if case let .ready(conn) = e { return .success(conn) }
            if let f = tally.add(e, pastDeadline: DispatchTime.now() >= deadline) { result = .failure(f); break }
        }
        // `.ready` 以外で戻る（上限・全候補の失敗・呼び出し側の取り消し）。以後に `.ready` になった接続は余りとして片付ける。
        // すでに選ばれて流れに残っている 1 本（戻る直前に `.ready` になったもの）も、取り出して余りとして片付ける
        _ = race.choose()
        sink.finish()
        for await case let .ready(conn) in stream {
            Task { await Self.closeSurplus(conn.channel, kind: kind, timeout: settings.surplusTimeout) }
        }
        if Task.isCancelled { return .failure(.cancelled) }
        return result ?? .failure(.timedOut)
    }

    /// 全体の締め切りで終わった時の理由: 締め切りより前に失敗した候補があればその理由、無ければ時間切れ
    static func atDeadline(_ failures: [NetError]) -> ViewerFailure {
        failures.isEmpty ? .timedOut : classify(failures)
    }

    /// 受け取った出来事（`.ready` 以外）を、つながらなかった理由にまとめる（純粋な値。試験できるように切り出した。点検 2f-1 の再点検）。
    /// - 全体の締め切りの後に届いた候補の時間切れは、候補の失敗に数えない（全体の時間切れとして扱う）
    /// - 全候補の失敗（`.exhausted`）が全体の締め切りの後なら、全体の時間切れ（`.timeout`）と同じ理由
    /// 候補の締め切りと全体の締め切りが同じ時刻の時、どちらが先に届いても理由が揺れないようにするため
    struct Tally {
        private(set) var failures: [NetError] = []
        /// 出来事を 1 つ加える。理由が決まれば返す（`.ready` は呼び出し側が先に扱う）
        mutating func add(_ e: Event, pastDeadline: Bool) -> ViewerFailure? {
            switch e {
            case .ready: return nil
            case let .failed(_, err):
                if case .timedOut = err, pastDeadline { return nil }
                failures.append(err)
                return nil
            case .exhausted:
                return pastDeadline ? Connector.atDeadline(failures) : Connector.classify(failures)
            case .timeout:
                return Connector.atDeadline(failures)
            }
        }
        /// 出来事の並びから理由を決める（試験用。最初に決まった理由）
        static func reason(_ events: [(Event, pastDeadline: Bool)]) -> ViewerFailure? {
            var t = Tally()
            for (e, p) in events { if let f = t.add(e, pastDeadline: p) { return f } }
            return nil
        }
    }

    /// 余りの接続: 登録済みの秘密なら `status` だけを送って応答を捨てて閉じる、コードの秘密なら何も送らずに閉じる
    static func closeSurplus(_ ch: ViewerChannel, kind: SecretKind, timeout: Double) async {
        switch kind {
        case .registered: _ = try? await ch.exchange(.status, expecting: .status, until: .now() + timeout)
        case .code: ch.close()
        }
    }

    /// 1 往復の指示（status・set・log・unpair）を、候補を試してつながった 1 本で行う（締め切りはつないでから `exchange` 秒）。
    /// 成功なら使った候補と応答（Host の失敗の応答 `.error(code)` も照合済みの応答として返す。`ViewerFailure(code)` で案内に直す）
    public static func exchange(_ request: Request, expecting: Response.Expectation, candidates: Candidates, id: PairingID, secret: Bytes32,
                                settings: Settings = .standard) async -> Result<(address: String, response: Response), ViewerFailure> {
        switch await connect(candidates, id: id, secret: secret, kind: .registered, settings: settings) {
        case let .failure(f): return .failure(f)
        case let .success(conn):
            do { return .success((conn.address, try await conn.channel.exchange(request, expecting: expecting, until: .now() + settings.exchange))) }
            catch { return .failure(classify(error)) }
        }
    }

    /// つながらなかった理由をまとめる: ローカルネットワークの許可が無い ＞ TLS の手続きが成立しない（秘密が一致しない・別の機器。届かない候補が混ざればその旨）＞
    /// TLS の版・方式（`SessionCheck`）の拒否 ＞ 届かない
    static func classify(_ failures: [NetError]) -> ViewerFailure {
        if failures.contains(.localNetworkDenied) { return .localNetworkDenied }
        if failures.contains(where: { if case .handshakeFailed = $0 { return true } else { return false } }) {
            let others = failures.contains { if case .handshakeFailed = $0 { return false } else { return true } }
            return .handshakeFailed(othersUnreachable: others)
        }
        if let s = failures.first(where: { if case .session = $0 { return true } else { return false } }) { return .other("\(s)") }
        return .unreachable
    }

    /// 送受信の失敗を案内の区別に直す
    public static func classify(_ error: Error) -> ViewerFailure {
        if error is CancellationError { return .cancelled }
        guard let e = error as? NetError else { return .other("\(error)") }
        switch e {
        case .localNetworkDenied: return .localNetworkDenied
        case .handshakeFailed: return .handshakeFailed(othersUnreachable: false)
        case .unreachable, .closed: return .unreachable
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case let .rejected(code): return ViewerFailure(code)
        case .session, .frame, .invalidRequest, .malformedResponse: return .other("\(e)")
        }
    }

    enum Event: Sendable {
        case ready(Connection)
        case failed(String, NetError)
        case exhausted
        case timeout
    }

    /// 並行に試す接続の間で共有する印（選んだ 1 本・始めた数・失敗した数）。`lock` で守る
    final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var chosen = false
        private var startedCount = 0, failedCount = 0
        var isChosen: Bool { lock.withLock { chosen } }
        /// 最初の 1 本だけ true（`connect` が戻る時にも立て、以後の `.ready` を余りに回す）
        func choose() -> Bool { lock.withLock { if chosen { return false }; chosen = true; return true } }
        func started() { lock.withLock { startedCount += 1 } }
        func failed() { lock.withLock { failedCount += 1 } }
        /// `stagger` 秒待つ。ただし、始めた候補がすべて失敗していれば、すぐ戻る（次の候補をずらさずに始める）
        func waitStagger(_ stagger: Double) async {
            let end = ContinuousClock.now + .milliseconds(Int(stagger * 1000))
            while ContinuousClock.now < end {
                if lock.withLock({ chosen || failedCount >= startedCount }) { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }
}

extension ViewerFailure {
    /// Host の失敗の応答から
    public init(_ code: ErrorCode) {
        switch code {
        case .notPaired: self = .notPaired
        case .unsupportedVersion: self = .unsupportedVersion
        case .paused: self = .paused
        case .busy: self = .busy
        case .badRequest: self = .other("bad_request")
        }
    }
    /// 応答から（失敗の応答なら案内の区別、成功の応答なら nil）
    public init?(response: Response) {
        guard case let .error(code) = response else { return nil }
        self.init(code)
    }
}
