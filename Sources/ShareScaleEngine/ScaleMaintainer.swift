import Foundation

/// ディスプレイの一覧を読んだ結果
public struct DisplayReading: Equatable, Sendable {
    public var displays: [DisplaySnapshot]
    /// 子プロセスで読めず、プロセスの中の一覧に戻った理由（読めた時は nil）
    public var fallbackReason: String?
    public init(displays: [DisplaySnapshot], fallbackReason: String? = nil) { self.displays = displays; self.fallbackReason = fallbackReason }
}

/// 倍率の維持が使う口（実物は `ChildProcessDisplayProvider`、試験は偽物）。どれも呼んだスレッドで同期に動き、数秒かかることがある
public protocol DisplayProvider: Sendable {
    /// 今のディスプレイの一覧（常駐のプロセスの中では古いことがあるので、実物は子プロセスで読む）
    func listFresh() -> DisplayReading
    /// 倍率を変える（実物は子プロセスで。打ち切りあり）。失敗なら理由
    func apply(uuid: String, factor: Int) -> String?
    /// この Mac が画面共有（5900 番）を受けているか。`maxAge` 秒以内の前回の結果を使ってよい
    func portSession(maxAge: TimeInterval) -> Bool
}

/// 倍率を変えない外からの理由（一時停止は `EngineState.paused` で持つ）
public enum ExternalHold: String, Equatable, Hashable, Sendable, CaseIterable {
    case updating    // `--apply-once` の子が版か CDHash の違いで何もせずに終わった（入れ替えの途中。新版の Host に替わるまで倍率を変えない）
}

/// 倍率の維持の今の様子（`status`・メニュー・診断が読む）
public struct EngineSnapshot: Equatable, Sendable {
    public struct Target: Equatable, Sendable {
        public var uuid: String
        public var width: Int, height: Int
        public var scale: Int
        public var source: SelectionSource   // .signature か .learned
    }
    public var session = false
    public var target: Target?
    public var ambiguous = false
    public var lastError: String?
    public var mode: ScaleMode = .x1
    public var paused = false
    public var holds: Set<ExternalHold> = []
    public var contention = false
    public var setBy: EngineState.SetRecord?
    /// この写しまでに判定を終えた `requestMode` の番号（`requestMode` が返す番号以上なら、その指示は判定された）
    public var coveredRequest = 0
    /// engine.json を読めない・保存できない（診断に出す）
    public var stateProblem: String?
    public var evaluations = 0
    public init() {}
}

/// 倍率の維持の本体（1 回分の判定 `evaluate` と、それを予定して回す常駐の部分）。
/// - 判定（`evaluate`）は 1 つずつ行う（`evalLock`）。予定した判定は自分の直列のキューで動く
/// - 設定（mode・一時停止・set_by）は `requestMode`・`setPaused` で変え、engine.json に保存する
/// - 「倍率が繰り返し戻される」を `ContentionDetector` で見つけ、写しの `contention` に出す
///
/// 可変の状態のうち、`state`・`holds`・`requestSeq`・`pendingRetry`・`snap`・予定の判定（`pendingJob`・`scheduleGen`）・`timer` は `lock` で守る。
/// `limiter`・`backoff`・`contention`・`userRetryPending`・`lastLogged`・`lastFallback` は `evalLock` の中（判定の中）だけで触る。
/// 保存は `saveLock` で直列にし、その時点の `state` を書く（後から保存した方が新しい）
public final class ScaleMaintainer: @unchecked Sendable {
    public struct Settings: Sendable {
        public var learnStableSeconds: TimeInterval = 10   // 学習するには、画面共有していない同じ構成がこの秒数以上続くこと
        public var maxApplies = 4                           // 短い間に何度も切り替えない（20 秒に 4 回まで）
        public var applyWindow: TimeInterval = 20
        public var backoffBase: TimeInterval = 30           // 失敗が続く時の待ち時間（30 秒→…→10 分）
        public var backoffMax: TimeInterval = 600
        public var contentionWindow: TimeInterval = 60      // 60 秒に 3 回以上戻されたら奪い合い
        public var contentionThreshold = 3
        public var coalesceDelay: TimeInterval = 0.3        // 通知は 1 回の変更で何度も届くので、少し待ってまとめる
        public var checkInterval: TimeInterval = 2          // 通知を取りこぼした時の保険の見回り
        public var checkPortMaxAge: TimeInterval = 10       // 見回りでは netstat の結果を 10 秒使い回す
        public init() {}
        public static let standard = Settings()
    }

    public enum ModeRequest: Equatable, Sendable {
        case accepted(Int)   // 判定を待つ番号（`EngineSnapshot.coveredRequest` がこれ以上になれば判定済み）
        case busy            // 前の指示がまだ判定されていない
    }

    public let settings: Settings
    private let provider: DisplayProvider
    private let file: EngineStateFile
    private let now: @Sendable () -> TimeInterval
    private let bootTime: Int?
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "sharescale.engine")
    private let lock = NSLock(), evalLock = NSLock(), saveLock = NSLock()
    // lock で守る
    private var state: EngineState
    private var holds: Set<ExternalHold> = []
    private var requestSeq = 0
    private var pendingRetry = false
    private var snap = EngineSnapshot()
    private var pendingJob: PendingEvaluation?
    private var scheduleGen = 0
    private var timer: DispatchSourceTimer?
    // evalLock の中だけで触る
    private var limiter: ApplyLimiter
    private var backoff: Backoff
    private var contention: ContentionDetector
    private var userRetryPending = false
    private var lastLogged = ""
    private var lastFallback: String?

    /// - `now`: 単調な時計の秒（スリープ中も進み、壁時計を戻しても戻らない）
    /// - `bootTime`: 起動時刻（kern.boottime の秒。学習の候補が前の起動のものなら数え直す）
    /// - `log`: 記録の 1 行（任意のスレッドから同期に呼ぶ。重い処理をしない）
    public init(provider: DisplayProvider, file: EngineStateFile, settings: Settings = .standard,
                now: @escaping @Sendable () -> TimeInterval = { ScaleMaintainer.monotonicNow() },
                bootTime: Int? = ScaleMaintainer.systemBootTime(),
                log: @escaping @Sendable (String) -> Void) {
        self.provider = provider; self.file = file; self.settings = settings; self.now = now; self.bootTime = bootTime; self.log = log
        limiter = ApplyLimiter(maxApplies: settings.maxApplies, window: settings.applyWindow)
        backoff = Backoff(base: settings.backoffBase, maxWait: settings.backoffMax)
        contention = ContentionDetector(window: settings.contentionWindow, threshold: settings.contentionThreshold)
        let loaded = file.load()
        state = loaded.state
        snap.mode = loaded.state.mode; snap.paused = loaded.state.paused; snap.lastError = loaded.state.lastError
        snap.setBy = loaded.state.setBy; snap.stateProblem = loaded.problem
        if let p = loaded.problem { log(p) }
    }
    deinit { timer?.cancel() }

    public static func monotonicNow() -> TimeInterval { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }
    public static func systemBootTime() -> Int? {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        return sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 ? Int(tv.tv_sec) : nil
    }

    // ---- 外からの操作 ----

    /// 今の様子
    public var snapshot: EngineSnapshot { lock.withLock { snap } }

    /// 起動時の判定と、`checkInterval` 秒ごとの見回りを始める（2 回目は何もしない）
    public func start() {
        let t: DispatchSourceTimer? = lock.withLock {
            guard timer == nil else { return nil }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + settings.checkInterval, repeating: settings.checkInterval)
            timer = t
            return t
        }
        guard let t else { return }
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.schedule("check", portMaxAge: self.settings.checkPortMaxAge)
        }
        t.resume()
        schedule("startup")
    }
    /// 見回りと予定した判定を止める（判定の途中なら、その判定は最後まで行う）
    public func stop() {
        lock.withLock { timer?.cancel(); timer = nil; pendingJob = nil; scheduleGen += 1 }
    }

    /// 少し待って判定する（`coalesceDelay` 秒の間に来た要求は 1 回にまとめる）
    public func schedule(_ reason: String, portMaxAge: TimeInterval = 0) {
        let new = PendingEvaluation(reason: reason, portMaxAge: portMaxAge)
        let gen: Int = lock.withLock {
            pendingJob = pendingJob.map { $0.merged(with: new) } ?? new
            scheduleGen += 1
            return scheduleGen
        }
        queue.asyncAfter(deadline: .now() + settings.coalesceDelay) { [weak self] in
            guard let self else { return }
            let job: PendingEvaluation? = self.lock.withLock {
                guard self.scheduleGen == gen else { return nil }
                defer { self.pendingJob = nil }
                return self.pendingJob
            }
            if let job { self.evaluate(reason: job.reason, portMaxAge: job.portMaxAge, retryRequested: job.retryRequested) }
        }
    }

    /// 倍率の指示（見る側の `set`）。設定と set_by を保存し、待ち時間を捨てて判定を予定する。
    /// 前の指示がまだ判定されていなければ `.busy`。保存に失敗しても、この起動の間は指示どおりに動く（問題は写しと記録に出す）
    public func requestMode(_ mode: ScaleMode, by: String, at: Int64) -> ModeRequest {
        let result: (seq: Int, changed: Bool)? = lock.withLock {
            guard requestSeq <= snap.coveredRequest else { return nil }
            let changed = state.mode != mode
            state.mode = mode
            state.setBy = EngineState.SetRecord(by: by, at: at)
            requestSeq += 1
            pendingRetry = true
            snap.mode = mode; snap.setBy = state.setBy
            return (requestSeq, changed)
        }
        guard let result else { return .busy }
        persist()
        schedule(result.changed ? "mode changed to \(mode.rawValue)" : "retry requested")
        return .accepted(result.seq)
    }

    /// `requestMode` の番号が判定されるまで待つ（最大 `timeout` 秒）。待ち終えた時の写しを返す。
    /// 待っているタスクが取り消されたら、その時点の写しを返す（`Task.sleep` は取り消されると即座に戻るので、確かめないと空回りする）
    public func waitUntilCovered(_ seq: Int, timeout: Double) async -> EngineSnapshot {
        let end = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while !Task.isCancelled, ContinuousClock.now < end {
            let s = snapshot
            if s.coveredRequest >= seq { return s }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return snapshot
    }

    /// 一時停止（倍率を変えない）。保存して判定し直す
    public func setPaused(_ paused: Bool) {
        let changed: Bool = lock.withLock {
            guard state.paused != paused else { return false }
            state.paused = paused; snap.paused = paused
            return true
        }
        guard changed else { return }
        persist()
        schedule(paused ? "paused" : "resumed")
    }

    /// 外からの理由で倍率を変えない（入れ替えの途中、など）
    public func setHold(_ hold: ExternalHold, _ on: Bool) {
        let changed: Bool = lock.withLock {
            let had = holds.contains(hold)
            guard had != on else { return false }
            if on { holds.insert(hold) } else { holds.remove(hold) }
            snap.holds = holds
            return true
        }
        if changed { schedule(on ? "hold \(hold.rawValue)" : "release \(hold.rawValue)") }
    }

    // ---- 判定 ----

    /// 1 回分の判定: 画面共有していなければ物理モニタを学習し、仮想ディスプレイの倍率を保存どおりに直す。
    /// 呼んだスレッドで同期に動く（子プロセスの完了を待つので最大 10 秒ほどかかる）。並行に呼ばれたら 1 つずつ行う
    public func evaluate(reason: String, portMaxAge: TimeInterval = 0, retryRequested: Bool = false) {
        evalLock.lock(); defer { evalLock.unlock() }
        let (current, holdsNow, seq, retryFlag): (EngineState, Set<ExternalHold>, Int, Bool) = lock.withLock {
            let r = pendingRetry; pendingRetry = false
            return (state, holds, requestSeq, r)
        }
        // 利用者の新しい指示: 待ち時間を捨て、回数の上限の記録を正しく書き、奪い合いを数え直す
        if retryFlag { backoff.reset(); userRetryPending = true; contention.reset() }
        let retry = retryRequested || retryFlag
        var outcome = Outcome(target: nil, ambiguous: false, session: false)
        defer { finish(outcome, covered: seq) }

        let reading = provider.listFresh()
        if reading.fallbackReason != lastFallback {   // 同じ失敗が続く間は 1 回だけ記録する
            if let r = reading.fallbackReason { log("fresh display list unavailable (\(r)); using in-process list") }
            lastFallback = reading.fallbackReason
        }
        let displays = reading.displays
        // 仮想ディスプレイの識別情報が見えていれば画面共有中と分かるので、netstat は呼ばない
        let port = displays.contains(where: \.isScreenSharingVirtual) ? true : provider.portSession(maxAge: portMaxAge)
        // 画面共有の仮想ディスプレイとして見えた ID は、以前に物理として覚えていても忘れる（誤学習の後始末）
        let seenVirtual = Set(displays.filter(\.isScreenSharingVirtual).map(\.uuid))
        let wrong = Set(current.learned).intersection(seenVirtual)
        if !wrong.isEmpty {
            update { $0.learned.removeAll { wrong.contains($0) } }
            log("forgot learned (seen as screen sharing): \(wrong.sorted().joined(separator: ","))")
        }
        // 同じ構成が learnStableSeconds 秒以上続いた時だけ学習する（切断直後に数秒残る仮想ディスプレイを覚えないように）
        let learnedNow = lock.withLock { state.learned }
        let step = Decision.stableLearn(observed: Decision.learn(displays: displays, portSession: port),
                                        candidate: current.learnCandidate, now: now(), minInterval: settings.learnStableSeconds, boot: bootTime)
        if step.candidate != current.learnCandidate { update { $0.learnCandidate = step.candidate } }
        if let ids = step.learn {
            let merged = Decision.mergeLearned(previous: learnedNow, current: ids)
            if merged != learnedNow {
                update { $0.learned = merged }
                log("learned physical: \(ids.sorted().joined(separator: ",")) (known \(merged.count))")
            }
        }
        let sel = Decision.select(displays: displays, learned: Set(lock.withLock { state.learned }), portSession: port)
        let session = Decision.sessionActive(portSession: port, displays: displays)
        outcome = Outcome(target: sel.target.map { EngineSnapshot.Target(uuid: $0.uuid, width: $0.width, height: $0.height,
                                                                           scale: $0.scaleFactor, source: sel.source) },
                          ambiguous: sel.ambiguous, session: session)
        // 画面共有が終わり仮想ディスプレイも無ければ、前の失敗の記録と待ち時間は意味がないので捨てる
        if sel.target == nil, !session {
            if lock.withLock({ state.lastError }) != nil { update { $0.lastError = nil } }
            backoff.reset(); userRetryPending = false; contention.reset()
        }
        let summary = sel.target.map { "\($0.width)x\($0.height)@\($0.scaleFactor)x" } ?? (sel.ambiguous ? "ambiguous" : "none")
        guard let act = Decision.action(mode: current.mode, selection: sel) else {
            // 設定どおりになっていれば、以前の失敗の記録は意味がないので消す
            if sel.target != nil {
                if lock.withLock({ state.lastError }) != nil { update { $0.lastError = nil } }
                backoff.reset(); userRetryPending = false; contention.settled(at: now())
            }
            logOnChange(reason, "ok (\(sel.source.rawValue) \(summary), mode \(current.mode.rawValue))")
            return
        }
        // 状況＝設定と仮想ディスプレイの大きさ。窓の大きさを変えると選べる倍率が変わるので、変われば待たずに試す
        let target = sel.target!   // action が nil でなければ target はある
        let condition = "\(current.mode.rawValue) \(target.width)x\(target.height)"
        contention.needsCorrection(condition: "\(target.uuid) \(target.width)x\(target.height)", at: now())
        if current.paused || !holdsNow.isEmpty {
            let why = current.paused ? "paused" : holdsNow.map(\.rawValue).sorted().joined(separator: ",")
            logOnChange(reason, "not changing the scale (\(why)); \(summary), mode \(current.mode.rawValue)")
            return
        }
        lastLogged = ""
        if backoff.shouldWait(condition: condition, now: now()) { return }
        guard limiter.allow(at: now()) else {
            let msg = Decision.limitMessage(retryRequested: retry || userRetryPending)
            update { $0.lastError = msg }
            log("\(reason): \(msg)")
            return
        }
        userRetryPending = false   // 実際に試す（成功・失敗とも、依頼には応えた）
        let started = now()
        let result = provider.apply(uuid: act.uuid, factor: act.factor)
        let took = String(format: "%.2fs", now() - started)
        if let err = result {
            let wait = backoff.failed(condition: condition, now: now())
            update { $0.lastError = err }
            log("\(reason): apply \(act.factor)x FAILED after \(took): \(err) (next try in \(Int(wait))s)")
        } else {
            backoff.reset()
            if lock.withLock({ state.lastError }) != nil { update { $0.lastError = nil } }
            contention.applied(condition: "\(target.uuid) \(target.width)x\(target.height)", at: now())
            log("\(reason): applied \(act.factor)x in \(took) (was \(summary))")
            outcome.target?.scale = act.factor   // 次の判定で確かめ直す（画面構成の変化の通知と見回り）
        }
    }

    private struct Outcome { var target: EngineSnapshot.Target?; var ambiguous: Bool; var session: Bool }

    /// 判定の結果を写しに書く（`seq` までの指示は判定済み）
    private func finish(_ o: Outcome, covered seq: Int) {
        let contended = contention.active
        let (was, now): (Bool, Bool) = lock.withLock {
            let was = snap.contention
            snap.session = o.session; snap.target = o.target; snap.ambiguous = o.ambiguous
            snap.lastError = state.lastError; snap.mode = state.mode; snap.paused = state.paused; snap.holds = holds
            snap.setBy = state.setBy; snap.contention = contended
            snap.coveredRequest = max(snap.coveredRequest, seq)
            snap.evaluations += 1
            return (was, contended)
        }
        if !was && now { log("the scale keeps being changed back (something else may be changing it)") }
        if was && !now { log("the scale is no longer being changed back") }
    }

    /// 変化がない時は記録しない（2 秒ごとの見回りで記録が膨らまないように）。理由は比べない
    private func logOnChange(_ reason: String, _ body: String) {
        if body != lastLogged { log("\(reason): \(body)"); lastLogged = body }
    }

    /// 状態を変えて保存する（保存に失敗しても記憶の中の値で動き続ける）
    private func update(_ change: (inout EngineState) -> Void) {
        lock.withLock { change(&state) }
        persist()
    }

    private func persist() {
        saveLock.lock(); defer { saveLock.unlock() }
        let s = lock.withLock { state }
        do {
            try file.save(s)
            lock.withLock { if snap.stateProblem?.hasPrefix("engine.json: could not save") == true { snap.stateProblem = nil } }
        } catch {
            let msg = "engine.json: could not save (\(ErrorText.readable(error)))"
            let first: Bool = lock.withLock { defer { snap.stateProblem = msg }; return snap.stateProblem != msg }
            if first { log(msg) }
        }
    }
}
