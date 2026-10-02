import Foundation
import Network

/// 受け側の状態（メニューと診断に出す）
public enum ListenerStatus: Equatable, Sendable {
    case stopped
    case starting
    case listening(port: UInt16)
    case waitingForNetwork          // 「Tailscale 経由だけ」で Tailscale のインターフェースが見つからない（受け付けない）
    case portInUse(port: UInt16, retryIn: Double)
    case failed(String, retryIn: Double)
}

/// 受け側（NWListener）の面倒を見る（仕様「受け側の開き直し」）。
/// - 開き直しは 200 ミリ秒以内の要求を 1 回にまとめ、1 つずつ行う。開き直している間に来た要求は、終わってからもう 1 回だけ行う
/// - 受け側を閉じても受け付け済みの接続は切れない（試作 7）。受け付けの方針や登録表は、この外で持つ
/// - 開き直しは、古い受け側が閉じ終えてから新しい受け側を開く（閉じ終える前に同じ通信口で開くと、使用中で失敗することがある）
/// - 開けない時は 1・2・4・8・16・32・60 秒（以後 60 秒ごと）の間隔でやり直し、成功したら間隔を戻す
/// - `makeParameters` が nil を返した時（Tailscale のインターフェースが無い）は受け付けず、次の要求まで待つ
/// - `currentStatus`・`openCount` は別のロックで写した値を返す（`onStatus`・`onConnection` の通知の中から読んでも止まらない）
/// - `stop()` を呼ばずに手放しても、受け側を閉じる（`deinit`）
///
/// 可変の状態は `queue` の上だけで触る（`deinit` を除く）。外から読むための写し（`mirroredOpens`・`mirroredStatus`）は `mirrorLock` で守る
public final class ListenerSupervisor: @unchecked Sendable {
    public static let standardRetryDelays: [Double] = [1, 2, 4, 8, 16, 32, 60]
    public static let standardCoalesceWindow: Double = 0.2
    /// 古い受け側が閉じ終えるのを待つ上限（秒）。過ぎたら、閉じ終えた知らせを待たずに開く
    public static let closeWaitLimit: Double = 1
    /// 開き直しの要求から新しい受け側を開き始めるまでの、最悪の秒数: まとめる窓＋閉じ終えるのを待つ上限＋（閉じ終える前に開いて
    /// 「使用中」になった時の）1 回目のやり直しの間隔。開くのにかかる時間とキューの遅れは含まない。
    /// **含めないもの**: 開き直している間に重なった要求（`pendingReopen`。終わってからもう 1 回開き直す）と、2 回目以降のやり直し（2・4・8 秒…。
    /// 通信口をほかが占め続けている時）。その時は見る側の確定の 3 回が外れうるが、未確定のまま残り、後の `status` で確定する。
    /// 見る側の「名乗りの後の確定」の猶予（`PairingFlow.Settings.confirmWindow`）は、これより十分に長くする
    public static let standardReopenWorstCase: Double = standardCoalesceWindow + closeWaitLimit + standardRetryDelays[0]
    public let retryDelays: [Double]
    public let coalesceWindow: Double
    let queue: DispatchQueue
    private let makeParameters: @Sendable () -> NWParameters?
    private let onConnection: @Sendable (NWConnection) -> Void
    private let onStatus: @Sendable (ListenerStatus) -> Void
    // 以下はすべて queue の上で触る
    private var listener: NWListener?
    private var generation = 0
    private var started = false
    private var reopening = false
    private var coalescing = false
    private var pendingReopen = false
    private var retryIndex = 0
    private var retryTimer: DispatchWorkItem?
    private var closingGeneration: Int?   // 古い受け側が閉じ終えるのを待っている開き直しの世代
    private var draining: NWListener?     // `stop` で閉じ、まだ閉じ終えていない受け側（次の `start` はこれが閉じ終えてから開く）
    private var opens = 0 { didSet { mirrorLock.withLock { mirroredOpens = opens } } }
    private var status: ListenerStatus = .stopped {
        didSet {
            mirrorLock.withLock { mirroredStatus = status }   // 通知より先に写す（通知の中で読んだ値が通知と一致するように）
            if status != oldValue { onStatus(status) }
        }
    }
    // 外から読むための写し（queue の外。queue.sync を使わない）
    private let mirrorLock = NSLock()
    private var mirroredOpens = 0
    private var mirroredStatus: ListenerStatus = .stopped

    /// - `retryDelays`: 開けない時のやり直しの間隔（秒。最後の値を以後くり返す）。空にはできない
    /// - `coalesceWindow`: この秒数の中に重なった開き直しの要求を 1 回にまとめる
    public init(queue: DispatchQueue = DispatchQueue(label: "sharescale.host.listener"),
                retryDelays: [Double] = ListenerSupervisor.standardRetryDelays,
                coalesceWindow: Double = ListenerSupervisor.standardCoalesceWindow,
                makeParameters: @escaping @Sendable () -> NWParameters?,
                onConnection: @escaping @Sendable (NWConnection) -> Void,
                onStatus: @escaping @Sendable (ListenerStatus) -> Void) {
        precondition(!retryDelays.isEmpty, "retryDelays は空にできない")
        self.queue = queue; self.retryDelays = retryDelays; self.coalesceWindow = coalesceWindow
        self.makeParameters = makeParameters; self.onConnection = onConnection; self.onStatus = onStatus
    }
    /// 手放された時に受け側を閉じる。queue に積んだ処理は `self` を強く持つか（`start`・`requestReopen`）弱く持つ（やり直し・閉じ終えるのを待つ処理・受け側の通知）ので、
    /// ここに来た時点で queue の上の処理がこのオブジェクトに触ることは無い
    deinit { retryTimer?.cancel(); listener?.cancel(); draining?.cancel() }

    /// 始める。やり直しの間隔は最初から数える。`stop` で閉じた受け側がまだ閉じ終えていなければ、閉じ終えてから開く
    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true; retryIndex = 0
            guard let old = draining else { open(); return }
            draining = nil; reopening = true; generation += 1
            closeThenOpen(old)
        }
    }
    public func stop() {
        queue.async { [self] in
            started = false; retryTimer?.cancel(); retryTimer = nil; reopening = false; pendingReopen = false; closingGeneration = nil
            generation += 1; status = .stopped
            guard let old = listener else { return }
            listener = nil
            draining = old
            // `old.start(queue: queue)` なので `queue` の上で呼ばれる
            old.stateUpdateHandler = { [weak self, weak old] st in
                guard case .cancelled = st, let self, let old, self.draining === old else { return }
                self.draining = nil
            }
            old.cancel()
        }
    }
    /// 開き直す（PSK の組が変わった、設定が変わった、ネットワークが変わった）
    public func requestReopen() {
        queue.async { [self] in
            guard started else { return }
            if reopening { pendingReopen = true; return }
            guard !coalescing else { return }
            coalescing = true
            queue.asyncAfter(deadline: .now() + coalesceWindow) { [self] in
                coalescing = false
                guard started else { return }
                if reopening { pendingReopen = true } else { reopen() }
            }
        }
    }
    /// 診断用: 開いた回数（通知の中から読んでも止まらない）
    public var openCount: Int { mirrorLock.withLock { mirroredOpens } }
    /// 今の状態（通知の中から読んでも止まらない）
    public var currentStatus: ListenerStatus { mirrorLock.withLock { mirroredStatus } }

    private func reopen() {
        reopening = true
        retryTimer?.cancel(); retryTimer = nil   // やり直しの間隔は戻さない（戻すのは開けた時 = .ready だけ）
        generation += 1
        guard let old = listener else { open(); return }
        listener = nil
        closeThenOpen(old)
    }
    /// 古い受け側が閉じ終えてから（`.cancelled`）新しい受け側を開く。閉じ終える前に同じ通信口で開くと、
    /// 使用中（EADDRINUSE）で失敗することがある。閉じ終えた知らせが 1 秒（`closeWaitLimit`）で来なければ、そのまま開く（使用中ならやり直しの間隔で開き直す）
    private func closeThenOpen(_ old: NWListener) {
        let gen = generation
        closingGeneration = gen
        let proceed: @Sendable () -> Void = { [weak self] in
            guard let self, self.closingGeneration == gen, self.generation == gen else { return }
            self.closingGeneration = nil
            self.open()
        }
        // `old.start(queue: queue)` なので `queue` の上で呼ばれる
        old.stateUpdateHandler = { st in if case .cancelled = st { proceed() } }
        old.cancel()
        queue.asyncAfter(deadline: .now() + Self.closeWaitLimit, execute: proceed)
    }
    private func open() {
        guard started else { return }
        // 開くのは受け側が無い時だけ（世代の照合で守っている。残っていたら、通信口を持ったまま表から消えないよう閉じる）
        if let stale = listener {
            assertionFailure("open() の時に前の受け側が残っている")
            stale.cancel(); listener = nil
        }
        guard let params = makeParameters() else {
            listener = nil; reopening = false; status = .waitingForNetwork
            afterOpen(); return
        }
        params.allowLocalEndpointReuse = true   // 受け付け済みの接続が残っていても同じ通信口で開き直せる
        // 使用中の時に知らせる通信口（失敗した受け側の `port` は 0 になりがちなので、指定した値を使う。指定が無ければ 0）
        let requestedPort: UInt16 = { if case let .hostPort(_, p)? = params.requiredLocalEndpoint { return p.rawValue }; return 0 }()
        let gen = generation
        let l: NWListener
        do { l = try NWListener(using: params) } catch { scheduleRetry(.failed("\(error)", retryIn: nextDelay())); return }
        opens += 1
        status = .starting
        l.newConnectionHandler = { [weak self] c in
            guard let self, self.generation == gen else { c.cancel(); return }
            self.onConnection(c)
        }
        // `l.start(queue: queue)` なので `queue` の上で呼ばれる（queue の上の状態をそのまま触ってよい）。
        // 古い受け側の通知は世代で見分けて捨てる
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, let l, self.generation == gen else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            switch st {
            case .ready:
                self.retryIndex = 0; self.reopening = false
                self.status = .listening(port: l.port?.rawValue ?? 0)
                self.afterOpen()
            case let .failed(e): self.failedOpen(e, listener: l, port: requestedPort)
            case let .waiting(e): self.failedOpen(e, listener: l, port: requestedPort)
            case .cancelled: break
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
    }
    private func failedOpen(_ e: NWError, listener l: NWListener, port: UInt16) {
        l.cancel(); if listener === l { listener = nil }
        let delay = nextDelay()
        if case let .posix(code) = e, code == .EADDRINUSE {
            scheduleRetry(.portInUse(port: port, retryIn: delay))
        } else {
            scheduleRetry(.failed("\(e)", retryIn: delay))
        }
    }
    private func nextDelay() -> Double {
        let d = retryDelays[min(retryIndex, retryDelays.count - 1)]
        retryIndex += 1
        return d
    }
    private func scheduleRetry(_ st: ListenerStatus) {
        status = st
        reopening = false
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.started, !self.reopening else { return }
            self.reopening = true; self.generation += 1; self.open()
        }
        retryTimer?.cancel(); retryTimer = item
        let delay: Double = { if case let .portInUse(_, r) = st { return r }; if case let .failed(_, r) = st { return r }; return 1 }()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        afterOpen()
    }
    /// 開き直している間に来た要求を、終わってからもう 1 回だけ行う
    private func afterOpen() {
        guard pendingReopen, !reopening else { return }
        pendingReopen = false
        reopen()
    }
}
