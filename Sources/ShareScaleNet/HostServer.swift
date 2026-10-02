import Foundation
import Network
import ShareScaleProtocol

/// Host の本体（計画 2c）が担う部分: 確認の窓と、指示への応答（倍率の維持・状態・記録）
public protocol HostApplication: AnyObject, Sendable {
    /// 確認の窓を出し、「追加する」なら true。取り消されたら窓を取り下げる。複数の接続から同時に呼ばれうる。
    /// `sourceClass` は送り元の分類（窓に「同じネットワーク」「Tailscale」などを添えるため）
    func approvePairing(codeID: PairingID, name: String, confirmationCode: Int, source: String, sourceClass: SourceClass) async -> Bool
    /// `status`・`set`・`log` への応答（`unpair` は HostServer が扱う）
    func respond(to request: Request, from id: PairingID) async -> Response
}

/// Host の受け付けで起きたこと（記録・メニュー・診断へ。秘密の値は含まない）
public enum HostEvent: Equatable, Sendable {
    case rejected(source: ShareScaleProtocol.IPAddress?, reason: RejectReason)   // TLS の前に断った
    /// 受け付けた接続の結末。`id` は照合に成功したペアリング（照合の前に終わったら nil）、`sourceClass` は受け付けた時の送り元の分類
    case finished(source: ShareScaleProtocol.IPAddress, id: PairingID?, sourceClass: SourceClass, outcome: HostOutcome)
    case registry(RegistryChange)
    case listener(ListenerStatus)
    case storeProblems([StoreProblem])   // `start` で保管から読めなかったペアリング・フォルダ（Host は止めない）
}

/// Host の受け付けの本体（仕様「攻撃への備え」「受け側の開き直し」「有効期限と時計」「名乗りの後の確定」「解除」）。
/// 受け側 → 送り元の判定（TLS の前）→ `HostConnection.serve` → 結末の記録、を接続ごとに行う。
/// 登録表（`PairingRegistry`）の変化を自分で受けて受け側を開き直し、期限切れを定期的に片付ける。
///
/// - `app` は強く持つ。2c の app が `HostServer` を持つ時は、どちらかを弱く持つか、1 つの常駐オブジェクトとして生涯を同じくする
/// - `start`・`stop` は並行に呼ばない（2c は同じスレッドから順に呼ぶ）。`stop` の後にもう一度 `start` できる
///
/// 可変の状態（`policy`・`connections`・`sweeper`・`running`）は `lock` で守る。`listener` は `init` の中で 1 回だけ設定し、以後は変えない
public final class HostServer: HostConnectionDelegate, @unchecked Sendable {
    /// 生成時に決める設定（受け付けるネットワークだけは、あとから `network` で変えられる）
    public struct Configuration: Sendable {
        public var limits: AdmissionLimits
        public var network: NetworkPolicy        // 始めの値（今の値は `HostServer.network`）
        public var timeouts: HostTimeouts
        public var sweepInterval: Double         // 期限切れを片付ける間隔（秒）
        public var listenerRetryDelays: [Double] // 受け側を開けない時のやり直しの間隔（`ListenerSupervisor`）
        public var coalesceWindow: Double        // 開き直しの要求をまとめる窓（`ListenerSupervisor`）
        public init(limits: AdmissionLimits = .standard, network: NetworkPolicy = NetworkPolicy(), timeouts: HostTimeouts = .standard,
                    sweepInterval: Double = 5, listenerRetryDelays: [Double] = ListenerSupervisor.standardRetryDelays,
                    coalesceWindow: Double = ListenerSupervisor.standardCoalesceWindow) {
            self.limits = limits; self.network = network; self.timeouts = timeouts; self.sweepInterval = sweepInterval
            self.listenerRetryDelays = listenerRetryDelays; self.coalesceWindow = coalesceWindow
        }
        public static let standard = Configuration()

        /// 使える範囲に収めた値（`HostServer.init` がこれを使う。非有限・負・空の値で落ちたり空回りしたりしないように）。
        /// 片付けの間隔は 0.05〜3600 秒、やり直しの間隔は各 0.05〜3600 秒（有効な値が 1 つも無ければ既定）、まとめる窓は 0〜5 秒
        public func validated() -> Configuration {
            func clamp(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double { v.isFinite ? min(max(v, lo), hi) : fallback }
            var c = self
            c.sweepInterval = clamp(sweepInterval, 0.05, 3600, 5)
            let delays = listenerRetryDelays.filter(\.isFinite).map { clamp($0, 0.05, 3600, 1) }
            c.listenerRetryDelays = delays.isEmpty ? ListenerSupervisor.standardRetryDelays : delays
            c.coalesceWindow = clamp(coalesceWindow, 0, 5, ListenerSupervisor.standardCoalesceWindow)
            return c
        }
    }

    public let registry: PairingRegistry
    public let configuration: Configuration
    private let app: HostApplication
    private let onEvent: @Sendable (HostEvent) -> Void
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let resolveSource: @Sendable (NWConnection) -> ShareScaleProtocol.IPAddress?
    private let lock = NSLock()
    private var policy: AdmissionPolicy
    private var listener: ListenerSupervisor!
    /// 受け付けた接続の記録（`accept` で `Task` と同じロックの中で登録し、結末で消す）
    private struct Record {
        let task: Task<Void, Never>
        let sourceClass: SourceClass      // 受け付けた時の送り元の分類（`ticket` から。確認の窓に渡す）
        var id: PairingID?               // 照合に成功したペアリング（解除で切るため。`authenticated` で記録）
        var authenticated = false        // この接続で照合に成功した（「知っている送り元」に入れる）
        var consumedCode: PairingID?     // この接続の名乗りで使用済みにしたコード（結末が `.paired` でなければ捨てる）
    }
    private var connections: [UUID: Record] = [:]
    private var sweeper: Task<Void, Never>?
    private var running = false

    /// 今扱っている接続の記録の鍵（`authenticated`・`consumeCode`・`approvePairing` から記録を引き、解除で切る時に自分を除くため）
    @TaskLocal static var currentConnection: UUID?

    /// - `makeParameters`: 受け側の設定（通信口・受け付けるネットワーク）。開き直すたびに、その時点の `network` を渡して呼ぶ。
    ///   nil なら「Tailscale のインターフェースが無い」（受け付けず、次の開き直しまで待つ）
    /// - `resolveSource`: 送り元の取り出し（試験で差し替える）。既定は接続の相手のアドレス
    /// - `onEvent`: 任意のスレッドから同期に呼ぶ（受け側のキュー・接続のタスク・`issueCode` などを呼んだスレッド・sweeper）。
    ///   重い処理・`DispatchQueue.main.sync`・このオブジェクトのロックを待つ処理をしない（状態を読む `listenerStatus` などは呼んでよい）。
    ///   **別々のスレッドから出た事象は、起きた順に届くとは限らない**（例: 照合の `.registry(.seen(X))` が、解除の `.registry(.unpaired(X))` の後に届く）。
    ///   付帯情報（`.meta`）を作る・更新する時は、その id が今 `registry.registeredIDs` にあるかを確かめる
    /// - `configuration`: `validated()` で使える範囲に収めてから使う
    public init(registry: PairingRegistry, app: HostApplication, configuration: Configuration = .standard,
                makeParameters: @escaping @Sendable (NetworkPolicy) -> NWParameters?,
                clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                resolveSource: @escaping @Sendable (NWConnection) -> ShareScaleProtocol.IPAddress? = { HostConnection.sourceAddress(of: $0.endpoint) },
                onEvent: @escaping @Sendable (HostEvent) -> Void) {
        let configuration = configuration.validated()
        self.registry = registry; self.app = app; self.configuration = configuration; self.clock = clock
        self.resolveSource = resolveSource; self.onEvent = onEvent
        self.policy = AdmissionPolicy(limits: configuration.limits, network: configuration.network, origin: clock())
        self.listener = ListenerSupervisor(retryDelays: configuration.listenerRetryDelays, coalesceWindow: configuration.coalesceWindow,
                                           makeParameters: { [weak self] in
                                               guard let self else { return nil }
                                               return makeParameters(self.lock.withLock { self.policy.network })
                                           },
                                           onConnection: { [weak self] c in self?.accept(c) },
                                           onStatus: { [weak self] st in self?.onEvent(.listener(st)) })
        registry.observe { [weak self] in self?.registryChanged($0) }
    }
    deinit { sweeper?.cancel() }

    /// 受け付けるネットワーク。変えると受け側を開き直す（「Tailscale 経由だけ」「インターネットからも受け付ける」の設定の変更に使う）
    public var network: NetworkPolicy {
        get { lock.withLock { policy.network } }
        set { lock.withLock { policy.network = newValue }; listener.requestReopen() }
    }
    /// 受け付けるネットワークをロックの中で変えてから、受け側を開き直す（読んで書き戻す間にほかのスレッドの変更を失わない）
    public func updateNetwork(_ change: (inout NetworkPolicy) -> Void) {
        lock.withLock { change(&policy.network) }
        listener.requestReopen()
    }
    /// 「同じネットワークのグローバル」の範囲だけを更新する（受け側は開き直さない。送り元の判定は次の接続から新しい範囲で行う）。
    /// 2c が、ネットワークの変化で Wi‑Fi・有線のプレフィックスが変わった時に呼ぶ
    public func updateLocalNetworks(_ networks: [IPNetwork]) { lock.withLock { policy.network.localNetworks = networks } }
    public var listenerStatus: ListenerStatus { listener.currentStatus }
    public var openConnections: Int { lock.withLock { policy.openConnections } }
    public func rejectionCounts(since: ContinuousClock.Instant) -> [RejectReason: Int] { lock.withLock { policy.rejectionCounts(since: since) } }

    /// 受け側を開き直す（2c が、Tailscale のインターフェースの出現・消失・番号の付け替え、通信口の設定の変更で呼ぶ）。
    /// 重なった要求は 1 回にまとめる。止まっている間は何もしない
    public func requestReopen() { listener.requestReopen() }

    /// 保管から読み（`unconfirmed` は `.meta` で確定していないもの）、受け側を開き、期限切れの片付けを始める。
    /// 読めないファイルがあれば `.storeProblems` を出して返す（Host は止めない）。すでに動いていれば何もしない（空を返す）
    @discardableResult
    public func start(unconfirmed: Set<PairingID> = []) -> [StoreProblem] {
        guard lock.withLock({ () -> Bool in
            guard !running else { return false }
            running = true; return true
        }) else { return [] }
        let problems = registry.load(unconfirmed: unconfirmed, now: clock())
        if !problems.isEmpty { onEvent(.storeProblems(problems)) }
        listener.start()
        let interval = configuration.sweepInterval
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
                guard let self else { return }   // 手放されたら終わる（強く持つのは 1 回の sweep の間だけ）
                self.sweep()
            }
        }
        lock.withLock { if running { sweeper = task } else { task.cancel() } }
        return problems
    }
    /// 受け側を閉じ、片付けを止め、接続中の通信を取り消す。もう一度 `start` できる
    public func stop() {
        let (sweeperTask, tasks): (Task<Void, Never>?, [Task<Void, Never>]) = lock.withLock {
            running = false
            let s = sweeper; sweeper = nil
            return (s, connections.values.map(\.task))
        }
        sweeperTask?.cancel()
        listener.stop()
        tasks.forEach { $0.cancel() }
    }
    /// 登録表が変わった（`init` で `PairingRegistry.observe` に渡す）
    private func registryChanged(_ change: RegistryChange) {
        onEvent(.registry(change))
        if change.changesPSKSet { listener.requestReopen() }
        switch change {
        case let .unpaired(id), let .pendingExpired(id): disconnect(id)
        default: break
        }
    }
    /// 期限切れのコードと確定されないペアリングを片付ける（sweeper が定期的に呼ぶ。スリープからの復帰などで 2c が呼んでもよい）
    public func sweep() { registry.sweep(now: clock()) }

    // ---- 受け付け ----
    private func accept(_ c: NWConnection) {
        let now = clock()
        let source = resolveSource(c)
        let key = UUID()
        let acceptedAt = DispatchTime.now()
        // `running` の判定・受け付けの判定・`Task` の生成・記録の登録を同じロックの中で行う
        // （タスクの中の `lookup` などが記録より先に走らないように。タスクの本体は同期には走らない）
        let decision: AdmissionDecision? = lock.withLock {
            guard running else { return nil }
            let d = policy.decide(source: source, now: now)
            if case let .admit(ticket) = d {
                connections[key] = Record(task: Task { [self] in await run(c, key: key, ticket: ticket, acceptedAt: acceptedAt) },
                                          sourceClass: ticket.sourceClass)
            }
            return d
        }
        guard let decision else { c.cancel(); return }
        if case let .reject(reason) = decision { onEvent(.rejected(source: source, reason: reason)); c.cancel() }
    }
    /// 1 接続を最後まで扱い、結末を方針・登録表・記録に返す
    private func run(_ c: NWConnection, key: UUID, ticket: AdmissionTicket, acceptedAt: DispatchTime) async {
        let outcome = await HostServer.$currentConnection.withValue(key) {
            await HostConnection.serve(c, delegate: self, timeouts: configuration.timeouts, acceptedAt: acceptedAt)
        }
        let end = clock()
        let record = lock.withLock { () -> Record? in
            let r = connections.removeValue(forKey: key)
            policy.finish(ticket, outcome: outcome, authenticated: r?.authenticated ?? false, now: end)
            return r
        }
        // この接続の名乗りで使用済みにしたコードは、承認されずに終わったらここで捨てる（ほかの接続の結末では捨てない）
        if let id = record?.consumedCode { if case .paired = outcome {} else { registry.abandonCode(id) } }
        onEvent(.finished(source: ticket.source, id: record?.id, sourceClass: ticket.sourceClass, outcome: outcome))
    }
    /// 解除したペアリングの接続中の通信を切る（解除の指示を送ってきた接続そのものは除く）
    private func disconnect(_ id: PairingID) {
        let me = HostServer.currentConnection
        let tasks = lock.withLock { connections.filter { $0.value.id == id && $0.key != me }.map(\.value.task) }
        tasks.forEach { $0.cancel() }
    }

    // ---- HostConnectionDelegate（登録表へ。承認と応答は app へ）----
    public func lookup(_ id: PairingID) -> (secret: Bytes32, kind: PairingKind)? { registry.lookup(id, now: clock()) }
    /// 照合が通った: 接続と id を結び付け（解除で切るため）、登録済みの秘密ならこの時点で確定・最終接続を更新する
    public func authenticated(_ id: PairingID, kind: PairingKind) {
        if let key = HostServer.currentConnection { lock.withLock { connections[key]?.id = id; connections[key]?.authenticated = true } }
        if kind == .registered { registry.markSeen(id, now: clock()) }
    }
    public func consumeCode(_ id: PairingID) -> Bool {
        guard registry.consumeCode(id, now: clock()) else { return false }
        if let key = HostServer.currentConnection { lock.withLock { connections[key]?.consumedCode = id } }
        return true
    }
    /// 確認の窓は app へ。送り元の分類は、この接続を受け付けた時の記録から渡す（記録が無ければ承認しない）
    public func approvePairing(codeID: PairingID, name: String, confirmationCode: Int, source: String) async -> Bool {
        guard let key = HostServer.currentConnection, let sourceClass = lock.withLock({ connections[key]?.sourceClass }) else { return false }
        return await app.approvePairing(codeID: codeID, name: name, confirmationCode: confirmationCode, source: source, sourceClass: sourceClass)
    }
    /// 新しい秘密を作って保存する（`PairingRegistry.completePairing`）。
    /// nil を返す理由には、保存の失敗のほか、承認待ちの間に新しいコードが発行された・取り消されたも含む。結末は `.saveFailed` になる
    public func completePairing(codeID: PairingID, name: String, source: String) -> Bytes32? {
        registry.completePairing(codeID: codeID, name: name, now: clock())
    }
    public func respond(to request: Request, from id: PairingID) async -> Response {
        if case .unpair = request {
            do { try registry.unpair(id); return .ok } catch { return .error(.busy) }
        }
        return await app.respond(to: request, from: id)
    }
}
