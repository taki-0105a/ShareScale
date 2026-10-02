import Foundation
import Network
import ShareScaleEngine
import ShareScaleNet
import ShareScaleProtocol

/// Host の診断（メニューと ShareScale.app の「この Mac の接続先」が読む。計画 2c-2 が表示する）
public struct HostDiagnostics: Equatable, Sendable {
    public var listener: ListenerStatus = .stopped
    public var binding: ListenBinding?
    public var tailscaleOnly = false
    public var allowGlobal = false
    public var tailscale: TailscaleDetection = .none
    public var paused = false
    public var updating = false                     // `--apply-once` の子が版違いで終わった（入れ替えの途中。新版の Host に替わるまで倍率を変えない）
    public var contention = false
    public var lastError: String?
    public var storeProblems: [StoreProblem] = []   // 読めないペアリングのファイル・付帯情報
    public var engineProblem: String?               // engine.json を読めない・保存できない
    public var logProblem: String?                  // 記録ファイルを開けない
    public var rejectedGlobalLast24h = 0            // グローバルアドレスからの接続を断った件数（直近 24 時間）
    public var staleNotices: [PairingID] = []       // 80 日使われていない見る側
    public var pairingCount = 0
    /// 待ち受けに使う通信口（待ち受けていない時は設定の値）。診断が、一時の通信口の範囲（`Limits.ephemeralPortRange`）なら注意を出す
    public var port = Limits.defaultPort
    /// 書き出し（`ShareScaleSnapshots`）がメニューの文言を組み立てるためにも使う
    public init() {}
}

/// Host の中核の組み立て役（画面の無い部分だけ）。計画 2c-2 の実行体がこれを作って `start` する。
/// 保管（秘密と付帯情報）・登録表・受け付けの本体・倍率の維持・記録・ネットワークの見張り・80 日の知らせをつなぐ。
///
/// - `HostEvent` は自分の直列のキュー（`events`）で処理する（`HostServer` の `onEvent` の中では重い処理をしないため）
/// - `start`・`stop` は並行に呼ばない（順に呼ぶ。`start` は `events` のキューを同期に待つので、`onChange` の中からは呼ばない）
/// - `onChange` は `events` のキュー・見張りのキュー・呼び出し元のスレッドから同期に呼ばれる。中で呼び出し元（main）を同期に待たない
///   （`DispatchQueue.main.async` で受ける）。`stop` の後も少しの間 `onChange` が届きうる
/// - `setPaused`・`unpair` は呼び出し元のスレッドで fsync を含む書き込みをする（メニューから呼ぶと main で数ミリ秒）
/// - 「Tailscale 経由だけ」「インターネットからも受け付ける」「通信口」の設定の永続化は 2c-2 の責任（`Configuration` で渡す）。
///   通信口の変更は、2c-2 が `HostRuntime` を作り直す
/// - `server`・`controller`・`monitor` は `init` の中で 1 回だけ設定し、以後は変えない。
///   ほかの可変の状態（`ctx`）は `lock` で守る。タイマーは `events` の上で動く
public final class HostRuntime: @unchecked Sendable {
    public enum ListenScope: Sendable {
        case allInterfaces   // 製品（受け付けるネットワークの設定と送り元の分類で決める）
        case loopbackOnly    // 試験（127.0.0.1 だけで待ち受ける。ほかの口で待ち受ける実行体を作らないため）
    }
    public struct Configuration: Sendable {
        public var supportDirectory: URL            // ~/Library/Application Support/ShareScale（engine.json と pairings/host/）
        public var logDirectory: URL?               // ~/Library/Logs/ShareScale（nil ならファイルに書かない）
        public var machine: String                  // この Mac の IOPlatformUUID
        /// 待ち受ける通信口。0 なら OS が選んだもの（最初に開けた通信口を使い続ける）。0 は、OS が一時の通信口の範囲（`Limits.ephemeralPortRange`）から選ぶので
        /// 使わない（試験も使わない。計画 2g）。製品は環境設定の `port`（既定 47651）を渡す
        public var port: UInt16 = UInt16(Limits.defaultPort)
        public var listenScope: ListenScope = .allInterfaces
        public var tailscaleOnly = false            // 受け付けるネットワークの設定の唯一の入口（下の `server.network` は使わない）
        public var allowGlobal = false
        /// 受け付けの上限・時間の上限など。`server.network` は `init` が `tailscaleOnly`・`allowGlobal` で上書きする（使わない）
        public var server: HostServer.Configuration = .standard
        public var engine: ScaleMaintainer.Settings = .standard
        public var codeLifetime: Duration = .seconds(600)
        public var confirmWithin: Duration = .seconds(600)
        public var staleCheckInterval: TimeInterval = 86_400   // 80 日の知らせの判定（起動時と 1 日 1 回）
        public var logFlushInterval: TimeInterval = 60
        public init(supportDirectory: URL, logDirectory: URL?, machine: String) {
            self.supportDirectory = supportDirectory; self.logDirectory = logDirectory; self.machine = machine
        }
        /// 既定の置き場所で作る（この Mac の識別子が読めなければ nil）
        public static func standard() -> Configuration? {
            guard let machine = MachineIdentity.platformUUID() else { return nil }
            let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ShareScale", isDirectory: true)
            return Configuration(supportDirectory: support, logDirectory: HostLog.standardDirectory(), machine: machine)
        }
    }

    public let configuration: Configuration
    public let log: HostLog
    public let store: SecretStore
    public let metaBook: MetaBook
    public let registry: PairingRegistry
    public let maintainer: ScaleMaintainer
    public private(set) var controller: HostController!
    public private(set) var server: HostServer!
    public private(set) var monitor: NetworkMonitor!
    private let approver: PairingApprover?   // 強く持つ（窓のオブジェクトが runtime を持たない前提）
    private let identity: HostIdentity
    private let localHostName: @Sendable () -> String?
    private let wallClock: @Sendable () -> Date
    private let onChange: @Sendable () -> Void
    private let events = DispatchQueue(label: "sharescale.host.events")
    private let lock = NSLock()
    private struct Context {
        var running = false
        var boundPort: UInt16?
        var binding: ListenBinding?          // 最後に受け側を作った時の結び付け（`makeParameters` が記録）
        var code: (id: PairingID, text: String, expires: Date)?   // 発行中のコード（再表示用）
        var lastNetwork = NetworkSnapshot()
        var storeProblems: [StoreProblem] = []
        var stale: [PairingID] = []
        var updating = false
        var timers: [DispatchSourceTimer] = []
    }
    private var ctx = Context()

    /// - `displays`: 倍率の維持の口（2c-2 は `ChildProcessDisplayProvider`、試験は偽物）
    /// - `approver`: 確認の窓（強く持つ。窓のオブジェクトが `HostRuntime` を持つと循環するので、窓は持たない）
    /// - `readAddresses`・`localHostName`: 試験で差し替える（既定は getifaddrs・LocalHostName）
    /// - `onChange`: メニューに出すものが変わった（`diagnostics`・`pairings` を読み直す）。任意のスレッドから呼ぶ
    /// - `onEvent`: 受け付けで起きたことの観測口（`HostEvent`。受け付けた接続の結末を数える試験のため。既定は何もしない）。
    ///   `HostServer.onEvent` と同じく任意のスレッドから同期に呼ばれるので、重い処理をしない
    public init(configuration: Configuration, displays: DisplayProvider, approver: PairingApprover?, identity: HostIdentity = .system,
                readAddresses: @escaping @Sendable () -> [InterfaceAddress] = { InterfaceAddresses.read() },
                localHostName: @escaping @Sendable () -> String? = { SystemNames.localHostName() },
                wallClock: @escaping @Sendable () -> Date = { Date() },
                onChange: @escaping @Sendable () -> Void = {},
                onEvent: @escaping @Sendable (HostEvent) -> Void = { _ in }) {
        self.configuration = configuration; self.approver = approver; self.identity = identity; self.localHostName = localHostName
        self.wallClock = wallClock; self.onChange = onChange
        let log = HostLog(directory: configuration.logDirectory, wallClock: wallClock)
        self.log = log
        store = SecretStore(base: configuration.supportDirectory, role: .host, machine: configuration.machine)
        let registry = PairingRegistry(store: store, codeLifetime: configuration.codeLifetime, confirmWithin: configuration.confirmWithin)
        self.registry = registry
        metaBook = MetaBook(store: store, isRegistered: { registry.registeredIDs.contains($0) }, problem: { log.write($0) })
        maintainer = ScaleMaintainer(provider: displays, file: EngineStateFile(url: configuration.supportDirectory.appendingPathComponent("engine.json")),
                                     settings: configuration.engine, log: { log.write($0, topic: .engine) })
        // ここから下は self を使う閉包（すべて弱く持つ）
        controller = HostController(maintainer: maintainer, log: log, approver: approver, identity: identity,
                                    addresses: { [weak self] in self?.currentAddresses() ?? (Limits.defaultPort, []) }, wallClock: wallClock)
        var serverConfig = configuration.server
        serverConfig.network = NetworkPolicy(tailscaleOnly: configuration.tailscaleOnly, allowGlobal: configuration.allowGlobal)
        server = HostServer(registry: registry, app: controller, configuration: serverConfig,
                            makeParameters: { [weak self] policy in self?.makeParameters(policy) },
                            onEvent: { [weak self] e in
                                guard let self else { return }
                                // 開いた通信口は通知の中で同期に記録する（次の開き直しが同じ通信口を使うように。ロックを短く取るだけ）
                                if case let .listener(.listening(p)) = e { self.lock.withLock { if self.ctx.boundPort == nil { self.ctx.boundPort = p } } }
                                onEvent(e)
                                self.events.async { self.handle(e) }
                            })
        monitor = NetworkMonitor(readAddresses: readAddresses, onChange: { [weak self] s in self?.networkChanged(s) })
    }
    deinit { lock.withLock { ctx.timers.forEach { $0.cancel() } } }

    // ---- 起動と停止 ----

    /// 付帯情報を読み、保管から登録表を作って受け付けを始め、倍率の維持・ネットワークの見張り・80 日の知らせの判定を始める。
    /// `onChange` の中からは呼ばない（`events` のキューを同期に待つため）
    public func start() {
        let started: Bool = events.sync {
            guard !lock.withLock({ ctx.running }) else { return false }
            lock.withLock { ctx.running = true }
            let metas = metaBook.load()
            let problems = server.start(unconfirmed: metas.unconfirmed)
            metaBook.reconcile(registered: registry.registeredIDs, now: wallClock())
            lock.withLock { ctx.storeProblems = problems + metas.problems }
            log.write("host started (pairings \(registry.count))")
            return true
        }
        guard started else { return }
        // 機種名（system_profiler）は最初の 1 回が遅いので、最初の `status` より前に裏で読んでおく（1 接続の上限 10 秒に掛からないように）
        let identity = identity
        DispatchQueue.global(qos: .utility).async { _ = identity.model() }
        monitor.start()
        maintainer.start()
        let stale = timer(every: configuration.staleCheckInterval, startNow: true, wall: true) { [weak self] in self?.checkStale() }
        let flush = timer(every: configuration.logFlushInterval, startNow: false) { [weak self] in self?.log.flush() }
        lock.withLock { ctx.timers = [stale, flush] }
    }

    /// 受け付けを閉じ、見張りと倍率の維持を止める（接続中の通信は取り消す）。もう一度 `start` できる。
    /// 記録の締めは `events` に積むだけ（同期に待たない）。動いていなければ（未起動・二重の停止）何もしない
    public func stop() {
        let timers: [DispatchSourceTimer]? = lock.withLock {
            guard ctx.running else { return nil }
            ctx.running = false; ctx.binding = nil
            defer { ctx.timers = [] }
            return ctx.timers
        }
        guard let timers else { return }
        timers.forEach { $0.cancel() }
        server.stop()
        maintainer.stop()
        monitor.stop()
        events.async { [self] in log.write("host stopped"); log.flush() }
    }

    /// 記録の締め（`events` に積んだ書き込みを待ち、まとめを書き出す。終了の直前に呼ぶ。`events` の上からは呼ばない）
    public func flushLog() { events.sync { log.flush() } }

    /// `wall` なら壁時計（スリープ中も数える。80 日の判定）、そうでなければ起動してからの時計
    private func timer(every interval: TimeInterval, startNow: Bool, wall: Bool = false, _ f: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: events)
        if wall { t.schedule(wallDeadline: .now() + (startNow ? 0 : interval), repeating: interval) }
        else { t.schedule(deadline: .now() + (startNow ? 0 : interval), repeating: interval) }
        t.setEventHandler(handler: f)
        t.resume()
        return t
    }

    // ---- メニュー（2c-2）からの操作 ----

    /// 新しい接続コードを出す（前のコードは無効）。上限（32 件）に達している・候補アドレスが無い・コードを作れない時は nil。
    /// 作れない条件（通信口の範囲・候補の件数と形）は登録表に発行させる前に確かめ、それでも作れなければ発行したコードを取り消す
    public func issueCode() -> PairingCode? {
        let (port, addrs) = currentAddresses()
        guard Limits.portRange.contains(port), (1...Limits.maxCandidateAddresses).contains(addrs.count),
              addrs.allSatisfy(CandidateAddress.isValid) else { return nil }
        guard let c = registry.issueCode(now: ContinuousClock.now, wallNow: wallClock()) else { return nil }
        guard let code = PairingCode(id: c.id, secret: c.secret, port: port, addresses: addrs, expiresAt: c.wallExpiry) else {
            registry.revokeCode(); return nil
        }
        lock.withLock { ctx.code = (c.id, code.encoded(), Date(timeIntervalSince1970: TimeInterval(c.wallExpiry))) }
        return code
    }
    public func revokeCode() { registry.revokeCode() }
    /// 発行中のコード（メニューの「コードをもう一度表示」用。文字列と壁時計の期限）。期限切れ・取り消し・名乗りの結末で消える
    public var currentCode: (text: String, expires: Date)? {
        lock.withLock { ctx.code.map { ($0.text, $0.expires) } }
    }
    /// 見る側を解除する（秘密と付帯情報を消し、受け側を開き直し、その見る側の接続を切る）。
    /// 呼び出し元のスレッドで fsync を含む書き込みをする（メニューから呼ぶと main で数ミリ秒）
    public func unpair(_ id: PairingID) throws { try registry.unpair(id) }
    /// 一時停止（倍率を変えない）。呼び出し元のスレッドで engine.json を書く（fsync を含む。メニューから呼ぶと main で数ミリ秒）
    public func setPaused(_ paused: Bool) { maintainer.setPaused(paused); onChange() }
    /// 80 日の知らせの「あとで」（30 日は出さない）
    public func snoozeNotice(_ id: PairingID) {
        events.async { [self] in
            let now = Int64(wallClock().timeIntervalSince1970)
            metaBook.snooze(id, until: Date(timeIntervalSince1970: TimeInterval(StaleNotice.snoozeUntil(now: now))))
            checkStale()
        }
    }
    public func setTailscaleOnly(_ on: Bool) { server.updateNetwork { $0.tailscaleOnly = on }; onChange() }
    public func setAllowGlobal(_ on: Bool) { server.updateNetwork { $0.allowGlobal = on }; onChange() }
    /// `--apply-once` の子が版か CDHash の違いで終わった（入れ替えの途中）。以後、この Host は倍率を変えない（新版の Host に替わるまで）。
    /// 何度呼んでも 1 回だけ記録する。任意のスレッドから呼べる
    public func noteUpdating() {
        let first: Bool = lock.withLock { defer { ctx.updating = true }; return !ctx.updating }
        maintainer.setHold(.updating, true)
        if first {
            events.async { [self] in log.write("apply-once child is a different version or build (update in progress); not changing the scale until the new Host starts") }
            onChange()
        }
    }
    /// 画面構成が変わった（2c-2 の実行体が CGDisplayRegisterReconfigurationCallback で受けて呼ぶ）
    public func displayConfigurationChanged() { maintainer.schedule("display changed") }
    /// スリープから戻った（期限を片付け、ネットワークを読み直し、80 日の知らせを判定し直し、倍率を判定する）
    public func didWake() {
        server.sweep(); monitor.refresh(); maintainer.schedule("wake")
        events.async { [weak self] in self?.checkStale() }
    }

    /// ペアリング済みの見る側（名前・最終接続など）
    public var pairings: [PairingID: HostMeta] { metaBook.entries }

    public var diagnostics: HostDiagnostics {
        let c = lock.withLock { ctx }
        let e = maintainer.snapshot
        var d = HostDiagnostics()
        d.listener = server.listenerStatus; d.binding = c.binding
        d.tailscaleOnly = server.network.tailscaleOnly; d.allowGlobal = server.network.allowGlobal; d.tailscale = monitor.snapshot.tailscale
        d.paused = e.paused; d.updating = e.holds.contains(.updating); d.contention = e.contention
        d.lastError = HostController.lastError(e)
        d.storeProblems = c.storeProblems; d.engineProblem = e.stateProblem; d.logProblem = log.problem
        d.rejectedGlobalLast24h = server.rejectionCounts(since: ContinuousClock.now - .seconds(86_400))[.sourceNotAccepted] ?? 0
        d.staleNotices = c.stale; d.pairingCount = registry.count
        d.port = Int(c.boundPort ?? configuration.port)
        return d
    }

    // ---- 内部 ----

    /// 今の通信口と候補アドレス（接続コードと `status` の `addrs`）
    func currentAddresses() -> (port: Int, addresses: [String]) {
        let port = Int(lock.withLock { ctx.boundPort } ?? configuration.port)
        let addrs = NetworkEnvironment.candidates(localHostName: localHostName(), snapshot: monitor.snapshot, tailscaleOnly: server.network.tailscaleOnly)
        return (port, addrs)
    }

    /// 受け側の設定（開き直すたびに呼ばれる）。「Tailscale 経由だけ」で Tailscale が無ければ nil（受け付けない）
    private func makeParameters(_ policy: NetworkPolicy) -> NWParameters? {
        let binding = NetworkEnvironment.binding(tailscaleOnly: policy.tailscaleOnly, snapshot: monitor.snapshot)
        let requested = lock.withLock { () -> UInt16 in ctx.binding = binding; return ctx.boundPort ?? configuration.port }
        let port = NWEndpoint.Port(rawValue: requested) ?? .any
        let params = TLSSettings.parameters(psks: registry.pskSet)
        switch (configuration.listenScope, binding) {
        case (_, .unavailable):
            return nil
        case (.loopbackOnly, _):
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        case (.allInterfaces, .anyInterface):
            params.requiredLocalEndpoint = .hostPort(host: .ipv6(.any), port: port)
        case let (.allInterfaces, .interface(name)):
            guard let i = monitor.interface(named: name) else { return nil }
            params.requiredInterface = i
            params.requiredLocalEndpoint = .hostPort(host: .ipv6(.any), port: port)
        case let (.allInterfaces, .localAddress(v4)):
            guard let a = IPv4Address(Data(v4.bytes)) else { return nil }
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(a), port: port)
        }
        return params
    }

    /// ネットワークが変わった: 同じネットワークの範囲は開き直さずに更新し、受け側の結び付け（`ListenBinding`）が変わる時だけ開き直す
    /// （「Tailscale 経由だけ」で Tailscale の utun が出現・消失・付け替えられた時。既定の受け付けでは結び付けは変わらない）。
    /// まだ受け側を作っていない（`ctx.binding` が nil）なら、作る時に今の様子を読むので開き直さない
    private func networkChanged(_ s: NetworkSnapshot) {
        let previous: NetworkSnapshot = lock.withLock { defer { ctx.lastNetwork = s }; return ctx.lastNetwork }
        let network = server.network
        if network.localNetworks != s.localNetworks { server.updateLocalNetworks(s.localNetworks) }
        let binding = NetworkEnvironment.binding(tailscaleOnly: network.tailscaleOnly, snapshot: s)
        let reopen: Bool = lock.withLock { ctx.binding.map { $0 != binding } ?? false }
        if reopen { server.requestReopen() }
        if previous.tailscale != s.tailscale { events.async { [self] in log.write("tailscale: \(Self.describe(s.tailscale))") } }
        onChange()
    }

    private func checkStale() {
        let due = StaleNotice.due(metaBook.entries, now: Int64(wallClock().timeIntervalSince1970))
        let changed: Bool = lock.withLock { defer { ctx.stale = due }; return ctx.stale != due }
        if changed { onChange() }
    }

    /// `HostEvent` を記録・付帯情報・診断へ（`events` の上で）
    private func handle(_ e: HostEvent) {
        switch e {
        case let .rejected(source, reason):
            log.noteFailure(source: source?.text ?? "?", reason: "rejected (\(reason.rawValue))")
        case let .finished(source, id, sourceClass, outcome):
            if outcome.countsAsFailure {
                log.noteFailure(source: "\(source.text) (\(sourceClass.rawValue))", reason: Self.describe(outcome))
            } else {
                switch outcome {
                case .served, .paired: break   // set は HostController が、名乗りの完了は登録表の変化が書く
                case let .badRequest(pid): log.write("bad request", topic: .pairing(pid))
                default: log.write("connection from \(source.text) (\(sourceClass.rawValue))\(id.map { " (\($0.hex.prefix(8)))" } ?? "") ended: \(Self.describe(outcome))")
                }
            }
        case let .registry(change):
            let name: (PairingID) -> String = { [metaBook] id in metaBook.meta(id)?.name ?? MetaBook.unknownName }
            switch change {
            case .codeIssued: log.write("pairing code issued")
            case .codeRevoked: log.write("pairing code revoked")
            case .codeExpired: log.write("pairing code expired")
            case .codeAbandoned: log.write("pairing code discarded (pairing not completed)")
            case let .paired(id, n): log.write("paired \"\(n)\" (waiting for confirmation)", topic: .pairing(id))
            case let .confirmed(id): log.write("pairing confirmed", topic: .pairing(id))
            case .seen: break
            case let .unpaired(id): log.write("unpaired \"\(name(id))\"")
            case let .pendingExpired(id): log.write("unpaired \"\(name(id))\" automatically (not confirmed within 10 minutes)")
            }
            metaBook.handle(change, now: wallClock())
            switch change {
            case .codeExpired, .codeRevoked, .codeAbandoned, .paired:
                // 発行中のコードの写しを消す（登録表を正とし、その間に出し直した新しいコードは消さない）
                let current = registry.currentCode?.id
                lock.withLock { if ctx.code?.id != current { ctx.code = nil } }
            default: break
            }
            if case .seen = change {} else { checkStale(); onChange() }
        case let .listener(st):
            log.write("listener: \(Self.describe(st))")
            onChange()
        case let .storeProblems(ps):
            for p in ps { log.write("pairing file \(p.name): \(p.reason.rawValue)") }
        }
    }

    static func describe(_ o: HostOutcome) -> String {
        switch o {
        case let .served(_, kind): return "served \(kind.rawValue)"
        case .paired: return "paired"
        case .handshakeFailed: return "TLS handshake failed"
        case .handshakeTimeout: return "TLS handshake timed out"
        case .sessionRejected: return "TLS version or cipher rejected"
        case .noRequest: return "no request"
        case .dropped: return "unreadable request"
        case .unsupportedVersion: return "unsupported version"
        case let .notPaired(r): return "not paired (\(r.rawValue))"
        case .badRequest: return "bad request"
        case .sendFailed: return "reply not sent"
        case .delegateTimeout: return "reply not ready in time"
        case .cancelled: return "cancelled"
        case .saveFailed: return "new secret not saved"
        case .randomFailed: return "random numbers unavailable"
        }
    }
    static func describe(_ s: ListenerStatus) -> String {
        switch s {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case let .listening(p): return "listening on port \(p)"
        case .waitingForNetwork: return "waiting for Tailscale"
        case let .portInUse(p, r): return "port \(p) is in use (retry in \(Int(r))s)"
        case let .failed(e, r): return "failed: \(e) (retry in \(Int(r))s)"
        }
    }
    static func describe(_ t: TailscaleDetection) -> String {
        switch t {
        case .none: return "not found"
        case let .ipv4Only(i, v4): return "\(i) has only IPv4 \(v4.text) (IPv6 is off in the tailnet)"
        case let .found(i, v4, _): return "\(i) \(v4.text)"
        }
    }
}
