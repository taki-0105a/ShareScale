import Darwin
import Foundation
import Network
import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

// ---- 値と時間 ----

func pid(_ n: UInt8) -> PairingID { PairingID(bytes: [UInt8](repeating: n, count: 16))! }
func secret(_ n: UInt8) -> Bytes32 { Bytes32(Data(repeating: n, count: 32))! }

/// 時間を試さない試験の上限（ゆとりを持たせる）。時間を試す試験は、この上で必要な値だけを短くする
func fastTimeouts(_ edit: (inout HostTimeouts) -> Void = { _ in }) -> HostTimeouts {
    var t = HostTimeouts(); t.firstRequest = 2; t.reveal = 2; edit(&t); return t
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// 経過秒数（ContinuousClock）
func secondsSince(_ t0: ContinuousClock.Instant) -> Double { (ContinuousClock.now - t0).seconds }
/// 経過秒数（DispatchTime。製品の締め切り（`acceptedAt` からの秒数）と同じ時計で測る）
func secondsSince(_ t0: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e9 }

/// 条件が満たされるまで待つ（最大 `timeout` 秒）
func waitFor(_ timeout: Double, _ cond: @escaping @Sendable () -> Bool) async {
    let end = ContinuousClock.now + .seconds(timeout)
    while !cond(), ContinuousClock.now < end { try? await Task.sleep(nanoseconds: 10_000_000) }
}

/// 負荷の下で起きる「Host の Task が動き出すまでの遅れ」を、CPU に負荷をかけずに真似る秒数（環境変数 `SHARESCALE_TEST_HOST_LAG`。既定は 0 = 遅らせない）。
/// `LoopbackHost` は `serve` を呼ぶ前に、`ServerHarness` は送り元を読む所（受け側のキューの上）でこの秒数だけ待つ
let testHostLag: Double = ProcessInfo.processInfo.environment["SHARESCALE_TEST_HOST_LAG"].flatMap(Double.init).map { max(0, $0) } ?? 0
func hostLag() async { if testHostLag > 0 { try? await Task.sleep(nanoseconds: UInt64(testHostLag * 1e9)) } }

/// 名乗りを開示まで進めた接続（応答は読まない）
func helloAndReveal(_ h: LoopbackHost, id: PairingID, secret: Bytes32) async throws -> ViewerChannel {
    let ch = try await ViewerChannel.open(to: h.endpoint, id: id, secret: secret)
    let rv = Bytes32.random()!
    try await ch.sendFirst(.hello(name: "MacBook", commitment: Commitment.make(rv)))
    guard case .helloChallenge = try await ch.receive(expecting: .hello, timeout: 5) else { throw NetError.malformedResponse }
    try await ch.sendReveal(rv)
    return ch
}

/// 待ち受けを始め、.ready まで待つ（ループバックだけ）
func startListener(_ listener: NWListener, label: String) throws {
    let ready = DispatchSemaphore(value: 0)
    let failure = Locked<NWError?>(nil)
    // 開けなかった時（使用中など）は、5 秒待たずにその理由で失敗にする
    listener.stateUpdateHandler = { st in
        switch st {
        case .ready: ready.signal()
        case let .failed(e), let .waiting(e): failure.value = e; ready.signal()
        default: break
        }
    }
    listener.start(queue: DispatchQueue(label: label))
    guard ready.wait(timeout: .now() + 5) == .success else { throw NetError.timedOut(.connecting) }
    if let e = failure.value { listener.cancel(); throw e }
}

// ---- 試験の受け側の通信口 ----

/// 試験の受け側（と「誰も待ち受けていない通信口」）に使う通信口を選ぶ: 一時の通信口の範囲（49152〜65535）の**外**（20000〜44999）で、
/// ループバックの IPv4 と IPv6 の両方で bind できたもの（確かめたらすぐ閉じる。待ち受けはしない）。
///
/// 通信口 0（任意）で待ち受けない理由（計画 2g）: 通信口 0 だと、受け側の通信口が、接続の手元の通信口（送り元）と同じ範囲から選ばれる。
/// OS は範囲の中を順に配るが、受け側の順番と接続の順番が同じ辺りに来ると、閉じたばかりの受け側の通信口を次の接続の手元の通信口に、
/// 直前の接続の手元の通信口を次の受け側に配る（役が入れ替わる）。その時、前の接続の Host 側がまだ閉じ終えていないと、新しい接続は
/// 「同じ組（送り元と宛先の 4 つ組）がもうある」として `EADDRINUSE`（`unreachable(posix(48))`）で断られる。受け側を開き直す間に、
/// ほかの接続がその通信口を手元の通信口として取り、開き直せなくなることもある。順番は Mac 全体で 1 つなので、同時に動くほかの試験の
/// プロセスにも及ぶ。製品の Host は 47651（範囲の外）で待ち受けるので、本番では起きない。
///
/// 同時に動く試験のプロセスが同じ通信口を選ばないように、50 個ずつの区画を、一時フォルダのファイルの鍵（`flock`）で 1 つのプロセスが持つ
/// （鍵はプロセスが終わると外れる）。始めの区画はプロセスごとにずらし、区画の中は 1 つずつ進める（同じプロセスの中で使い回さない）。
/// 鍵が効くのは、同じ一時フォルダ（`TMPDIR`）を使うプロセスの間だけ（別の利用者・別の `TMPDIR` の試験とは、bind の確かめだけが頼り）。
///
/// **この型は、3 つの試験群（`ShareScaleNetTests`・`ShareScaleCoreTests`・`ShareScaleHostCoreTests`）の補助に同じものを置いてある**
/// （試験の補助を共有するターゲットを足すと `Package.swift` が変わるため）。直す時は 3 つとも直す
/// （`NetUnitTests.testTestPortsIsTheSameInTheThreeTestTargets` が、3 つが 1 字も違わないことを見る）
final class TestPorts: @unchecked Sendable {
    static let shared = TestPorts()
    static let range: Range<UInt16> = 20000..<45000
    static let blockSize = 50
    static var blocks: Int { range.count / blockSize }
    private let lock = NSLock()
    private var block = Int(UInt32(truncatingIfNeeded: getpid()) &* 7919 % UInt32(TestPorts.blocks))
    private var offset = TestPorts.blockSize   // 最初の 1 つで区画を取る
    private var held: [Int32] = []             // 区画の鍵（開いたまま持つ。プロセスが終わるまで）

    /// 空いている通信口を 1 つ（見つからなければ nil）
    func take() -> UInt16? {
        lock.withLock {
            for _ in 0..<Self.range.count {
                if offset >= Self.blockSize, !nextBlock() { return nil }
                let port = Self.range.lowerBound + UInt16(block * Self.blockSize + offset)
                offset += 1
                if Self.isFree(port) { return port }
            }
            return nil
        }
    }
    /// 次の、ほかのプロセスが持っていない区画を取る
    private func nextBlock() -> Bool {
        let dir = NSTemporaryDirectory() + "sharescale-test-ports"
        mkdir(dir, 0o700)
        for _ in 0..<Self.blocks {
            block = (block + 1) % Self.blocks
            let fd = open("\(dir)/block-\(block).lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)   // 子プロセス（openssl など）に鍵を渡さない
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { held.append(fd); offset = 0; return true }
            close(fd)
        }
        return false
    }
    /// ループバックの IPv4 と IPv6 の両方で bind できるか（確かめるだけで、すぐ閉じる）
    static func isFree(_ port: UInt16) -> Bool { bindable(AF_INET, port) && bindable(AF_INET6, port) }
    private static func bindable(_ family: Int32, _ port: UInt16) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if family == AF_INET {
            var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
            return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        }
        var a = sockaddr_in6(); a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); a.sin6_family = sa_family_t(AF_INET6)
        a.sin6_port = port.bigEndian; a.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } } == 0
    }
}

/// 試験の受け側の通信口（`TestPorts`）。空きが見つからない時（区画が尽きた・一時フォルダに鍵を置けない）は、試験を失敗にして 0（任意）を返す
/// （黙って通信口 0 に戻ると、一時の通信口の範囲から配られて、直す前の揺れが戻る）
func listenPortForTests(file: StaticString = #filePath, line: UInt = #line) -> UInt16 {
    if let port = TestPorts.shared.take() { return port }
    XCTFail("試験の受け側の通信口が見つからない（\(TestPorts.range) の区画が尽きたか、\(NSTemporaryDirectory())sharescale-test-ports に鍵を置けない）。通信口 0 で続ける", file: file, line: line)
    return 0
}

/// 誰も待ち受けていないループバックの通信口（つなぐと ECONNREFUSED）。
/// 「つながらない候補」の役に使う（実際の名前解決や外への通信をしない）。一時の通信口の範囲の外から選ぶ（`TestPorts`）
func closedLoopbackPort() -> UInt16? { TestPorts.shared.take() }

/// ループバックだけで待ち受ける設定（通信口は `TestPorts` から。通信口 0 にしない）
func loopbackParameters(_ p: NWParameters, port: UInt16? = nil) -> NWParameters {
    p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port ?? listenPortForTests()) ?? .any)
    return p
}

/// ループバックの受け側を作って待ち受けを始める。通信口は `ports` から取る（既定は `TestPorts`）。開けなければ（空いていることを確かめてから
/// 開くまでの間に、ほかのプロセスに取られた）通信口を取り直して、3 回まで試す。3 回とも開けなければ、最後の理由（`EADDRINUSE` など）を投げる
/// （5 秒待たない）。`configure` は、始める前の受け側に受け付けの処理を付ける（取り直すたびに呼ぶ）
func openLoopbackListener(label: String, ports: () -> UInt16 = { listenPortForTests() }, parameters: () -> NWParameters,
                          configure: (NWListener) -> Void) throws -> NWListener {
    var last: Error = NetError.timedOut(.connecting)
    for _ in 0..<3 {
        let l = try NWListener(using: loopbackParameters(parameters(), port: ports()))
        configure(l)
        do { try startListener(l, label: label); return l } catch { last = error; l.cancel() }
    }
    throw last
}

// ---- 並行に使う小さな入れ物 ----

/// ロックで守った値
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
    /// 読んで書き換えるまでを 1 つの鍵の中で行う（`value.append(…)` は読むのと書くのが別の鍵になり、同時の通知で片方が失われる）
    @discardableResult
    func update<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&v) } }
}

/// 試験の中で値を 1 つ受け渡す
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T?
    func set(_ x: T) { lock.withLock { v = x } }
    var value: T? { lock.withLock { v } }
}

/// 解放されたかを見る（弱い参照）
final class Weak<T: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var v: T?
    func set(_ x: T) { lock.withLock { v = x } }
    var isGone: Bool { lock.withLock { v == nil } }
}

/// 並行に数える
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// 1 回の呼び出しの取り消しを待つ（呼び出しごとに作る）
final class CancelWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var k: CheckedContinuation<Void, Never>?
    private var cancelled = false
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in if cancelled { return true }; k = c; return false }
            if now { c.resume() }
        }
    }
    func cancel() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in cancelled = true; let x = k; k = nil; return x }
        c?.resume()
    }
}

// ---- Host の相手役 ----

/// 試験用の Host の相手役（登録表・名乗りの承認・保存・応答を差し替えられる。設定値はロックで守る）
final class FakeDelegate: HostConnectionDelegate, @unchecked Sendable {
    /// 承認の振る舞い: すぐ決める／取り消しも無視して止まる／取り消されるまで待つ（取り消しを記録）／
    /// 取り消しを無視して決まった秒数の後に「追加する」を返す
    enum ApproveMode { case decide, stuck, untilCancelled, lateApprove(Double) }
    /// 応答の振る舞い: すぐ返す／取り消しも無視して止まる／取り消されるまで待つ（取り消しを記録）
    enum RespondMode { case immediate, stuck, untilCancelled }

    private let lock = NSLock()
    private var registry: [PairingID: (Bytes32, PairingKind)] = [:]
    private var usedCodes = Set<PairingID>()
    private var shownCodes: [Int] = []
    private var shownSources: [String] = []
    private var approvalStarts: [ContinuousClock.Instant] = []
    private var lateApprovalCount = 0
    private var completed: [(name: String, source: String)] = []
    private var authenticatedList: [(id: PairingID, kind: PairingKind)] = []
    private var respondCount = 0
    private var cancelCount = 0
    private var parked: [CheckedContinuation<Void, Never>] = []

    private let _decide = Locked<@Sendable (String, Int) -> Bool>({ _, _ in false })
    private let _newSecret = Locked<Bytes32?>(secret(0x77))
    private let _respondWith = Locked<@Sendable (Request) -> Response>({ _ in .ok })
    private let _approveMode = Locked<ApproveMode>(.decide)
    private let _respondMode = Locked<RespondMode>(.immediate)

    /// 確認の窓の答え（true = 「追加する」）
    var decide: @Sendable (String, Int) -> Bool { get { _decide.value } set { _decide.value = newValue } }
    /// completePairing が作って保存する秘密（nil = 保存に失敗）
    var newSecret: Bytes32? { get { _newSecret.value } set { _newSecret.value = newValue } }
    var respondWith: @Sendable (Request) -> Response { get { _respondWith.value } set { _respondWith.value = newValue } }
    var approveMode: ApproveMode { get { _approveMode.value } set { _approveMode.value = newValue } }
    var respondMode: RespondMode { get { _respondMode.value } set { _respondMode.value = newValue } }

    var codes: [Int] { lock.withLock { shownCodes } }
    var sources: [String] { lock.withLock { shownSources } }
    /// 承認（`approvePairing`）が呼ばれた時刻（承認待ちの上限はここから数える。受け付けからではない）
    var approvalStartedAt: [ContinuousClock.Instant] { lock.withLock { approvalStarts } }
    /// `.lateApprove` の遅れた「追加する」が返った回数
    var lateApprovals: Int { lock.withLock { lateApprovalCount } }
    var completions: [(name: String, source: String)] { lock.withLock { completed } }
    /// 照合が通った接続（`authenticated` の記録）
    var authenticated: [(id: PairingID, kind: PairingKind)] { lock.withLock { authenticatedList } }
    var respondCalls: Int { lock.withLock { respondCount } }
    var cancellations: Int { lock.withLock { cancelCount } }

    func register(_ id: PairingID, _ secret: Bytes32, _ kind: PairingKind) { lock.withLock { registry[id] = (secret, kind) } }
    func revoke(_ id: PairingID) { lock.withLock { _ = registry.removeValue(forKey: id) } }

    /// 止めたままの呼び出しを放す（試験の後片付け）
    func releaseParked() {
        let ks = lock.withLock { () -> [CheckedContinuation<Void, Never>] in let p = parked; parked = []; return p }
        ks.forEach { $0.resume() }
    }
    private func park() async { await withCheckedContinuation { k in lock.withLock { parked.append(k) } } }
    /// 取り消されるまで待つ。取り消しの印は呼び出しごとに新しくする
    private func waitUntilCancelled() async {
        let w = CancelWaiter()
        await withTaskCancellationHandler { await w.wait() } onCancel: {
            lock.withLock { cancelCount += 1 }
            w.cancel()
        }
    }

    func lookup(_ id: PairingID) -> (secret: Bytes32, kind: PairingKind)? { lock.withLock { registry[id].map { ($0.0, $0.1) } } }
    func consumeCode(_ id: PairingID) -> Bool { lock.withLock { usedCodes.insert(id).inserted } }
    func authenticated(_ id: PairingID, kind: PairingKind) { lock.withLock { authenticatedList.append((id, kind)) } }
    func approvePairing(codeID: PairingID, name: String, confirmationCode: Int, source: String) async -> Bool {
        lock.withLock { shownCodes.append(confirmationCode); shownSources.append(source); approvalStarts.append(.now) }
        switch approveMode {
        case .decide: return decide(name, confirmationCode)
        case .stuck: await park(); return true          // 放された後の値は使われない
        case .untilCancelled: await waitUntilCancelled(); return true
        case let .lateApprove(seconds):
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { k.resume() }
            }
            lock.withLock { lateApprovalCount += 1 }
            return true
        }
    }
    func completePairing(codeID: PairingID, name: String, source: String) -> Bytes32? {
        lock.withLock { completed.append((name, source)) }
        return newSecret
    }
    func respond(to request: Request, from id: PairingID) async -> Response {
        lock.withLock { respondCount += 1 }
        switch respondMode {
        case .immediate: break
        case .stuck: await park()
        case .untilCancelled: await waitUntilCancelled()
        }
        return respondWith(request)
    }
}

// ---- 待ち受け ----

/// ループバックだけで待ち受ける Host（接続ごとに HostConnection.serve を動かし、結末を集める）。
/// 受け付けの通知で取った時刻を `serve(acceptedAt:)` に渡し、経過秒数も同じ時刻から測る（`HostServer.accept` と同じ形。
/// `serve` を Task の中で呼ぶので、渡さないと製品の締め切りは Task が動き出した時から、試験の時計は受け付けから数えることになり、
/// Task の遅れの分だけ測った秒数が締め切りより長く見える。計画 2g）
final class LoopbackHost: @unchecked Sendable {
    private(set) var listener: NWListener!
    private let lock = NSLock()
    private var outcomes: [HostOutcome] = []
    private var durations: [Double] = []   // 受け付けから結末までの秒数（DispatchTime。製品の締め切りと同じ起点・同じ時計）
    private var ends: [ContinuousClock.Instant] = []   // 結末の時刻
    private var serving: [Task<Void, Never>] = []

    /// `startFirst` なら、接続を先に始めて .ready になってから serve に渡す（開始済みの接続の扱いを試す）
    init(psks: [PairingID: Bytes32], delegate: FakeDelegate, timeouts: HostTimeouts = fastTimeouts(), startFirst: Bool = false) throws {
        listener = try openLoopbackListener(label: "test.listener", parameters: {
            let p = TLSSettings.parameters(psks: psks); p.allowLocalEndpointReuse = true; return p
        }) { [self] l in l.newConnectionHandler = { [self] c in
            let accepted = DispatchTime.now()
            let task = Task {
                await hostLag()
                if startFirst {
                    c.start(queue: DispatchQueue(label: "test.prestarted"))
                    await waitFor(3) { c.state == .ready }
                }
                // 開始済みの接続（`startFirst`）は、渡した時から数える（先に始めて待った分を手続きの上限に入れない）
                let o = await HostConnection.serve(c, delegate: delegate, timeouts: timeouts, acceptedAt: startFirst ? .now() : accepted)
                self.lock.withLock { self.outcomes.append(o); self.durations.append(secondsSince(accepted)); self.ends.append(.now) }
            }
            lock.withLock { serving.append(task) }
        } }
    }

    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: listener.port!) }

    /// `count` 個の結末がそろうまで待つ（最大 `timeout` 秒）
    func outcomes(count: Int, timeout: Double = 10) async -> [HostOutcome] {
        await waitFor(timeout) { self.lock.withLock { self.outcomes.count >= count } }
        return lock.withLock { outcomes }
    }

    /// 結末の時刻（結末と同じ順）
    var finishedAt: [ContinuousClock.Instant] { lock.withLock { ends } }

    /// 結末と、受け付けから結末までの秒数
    func timedOutcomes(count: Int, timeout: Double = 10) async -> [(outcome: HostOutcome, seconds: Double)] {
        let o = await outcomes(count: count, timeout: timeout)
        let d = lock.withLock { durations }
        return Array(zip(o, d)).map { (outcome: $0.0, seconds: $0.1) }
    }

    /// serve を動かしているタスクを外から取り消す（解除したペアリングの接続を切る時を模す）
    func cancelServing() { lock.withLock { serving }.forEach { $0.cancel() } }

    func stop() { listener.cancel() }
}

/// 試験の中の偽の Host。TLS（PSK）を通し、最初の 1 行を読んだ後の振る舞いを `script` で決める
/// （`script` には接続・読んだ 1 行・版と方式を確かめた ekm を渡す）
final class ScriptedHost: @unchecked Sendable {
    let listener: NWListener

    init(psks: [PairingID: Bytes32], script: @escaping @Sendable (Channel, Data, Bytes32?) async -> Void) throws {
        listener = try openLoopbackListener(label: "test.scripted.listener", parameters: { TLSSettings.parameters(psks: psks) }) { l in l.newConnectionHandler = { c in
            Task {
                let ch = Channel(c, label: "test.scripted")
                let line: Data, ekm: Bytes32?
                do {
                    try await ch.waitReady(until: .now() + 5)
                    ekm = try? SessionCheck.verify(c).get()
                    line = try await ch.readLine(limit: Limits.requestMaxBytes, until: .now() + 5)
                } catch { ch.close(); return }
                await script(ch, line, ekm)
            }
        } }
    }

    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: listener.port!) }
    func stop() { listener.cancel() }
}

/// 生の TCP の中継（中身は変えない）。見る側から Host へのバイトを接続ごとに記録する
final class SniffingRelay: @unchecked Sendable {
    private(set) var listener: NWListener!
    private let lock = NSLock()
    private var upstream: [Data] = []

    /// `delayDownstream` 秒は Host から見る側へ流さない（TLS の手続きを遅らせる）
    init(to target: NWEndpoint, delayDownstream: Double = 0) throws {
        listener = try openLoopbackListener(label: "test.relay.listener", parameters: { .tcp }) { [self] l in l.newConnectionHandler = { [self] inbound in
            let index = lock.withLock { upstream.append(Data()); return upstream.count - 1 }
            let outbound = NWConnection(to: target, using: .tcp)
            let q = DispatchQueue(label: QueueNames.next("test.relay"))
            inbound.start(queue: q); outbound.start(queue: q)
            Self.pump(inbound, outbound) { d in self.lock.withLock { self.upstream[index].append(d) } }
            q.asyncAfter(deadline: .now() + delayDownstream) { Self.pump(outbound, inbound) { _ in } }
        } }
    }

    static func pump(_ from: NWConnection, _ to: NWConnection, record: @escaping @Sendable (Data) -> Void) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data, !data.isEmpty { record(data); to.send(content: data, completion: .contentProcessed { _ in }) }
            if done || error != nil { from.cancel(); to.cancel(); return }
            pump(from, to, record: record)
        }
    }

    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: listener.port!) }
    /// 接続ごとの、見る側から Host へのバイト
    var captured: [Data] { lock.withLock { upstream } }
    func stop() { listener.cancel() }
}

// ---- TLS の平文の読み取り ----

/// TLS 1.2 の平文の手続き（ChangeCipherSpec より前）の、handshake のメッセージ（型と中身）
func plaintextHandshakes(_ bytes: Data) -> [(type: UInt8, body: Data)] {
    let b = [UInt8](bytes)
    var payload: [UInt8] = []
    var i = 0
    while i + 5 <= b.count {
        let type = b[i], len = Int(b[i + 3]) << 8 | Int(b[i + 4])
        guard i + 5 + len <= b.count, type != 20 else { break }   // 20 = ChangeCipherSpec（以後は暗号化）
        if type == 22 { payload += b[(i + 5)..<(i + 5 + len)] }
        i += 5 + len
    }
    var out: [(type: UInt8, body: Data)] = []
    var j = 0
    while j + 4 <= payload.count {
        let len = Int(payload[j + 1]) << 16 | Int(payload[j + 2]) << 8 | Int(payload[j + 3])
        guard j + 4 + len <= payload.count else { break }
        out.append((payload[j], Data(payload[(j + 4)..<(j + 4 + len)])))
        j += 4 + len
    }
    return out
}

/// ClientHello の session_id の長さと、拡張の型の一覧
func clientHelloSummary(_ body: Data) -> (sessionIDLength: Int, extensions: [Int])? {
    let b = [UInt8](body)
    var i = 2 + 32
    guard i < b.count else { return nil }
    let sid = Int(b[i]); i += 1 + sid
    guard i + 2 <= b.count else { return nil }
    i += 2 + (Int(b[i]) << 8 | Int(b[i + 1]))          // cipher_suites
    guard i < b.count else { return nil }
    i += 1 + Int(b[i])                                  // compression_methods
    guard i + 2 <= b.count else { return (sid, []) }
    let end = i + 2 + (Int(b[i]) << 8 | Int(b[i + 1])); i += 2
    var exts: [Int] = []
    while i + 4 <= min(end, b.count) {
        exts.append(Int(b[i]) << 8 | Int(b[i + 1]))
        i += 4 + (Int(b[i + 2]) << 8 | Int(b[i + 3]))
    }
    return (sid, exts)
}

/// 配列の件数を確かめる（違えば試験を失敗にして false を返す）。結果の配列を添字で読む前に `guard hasCount(a, n) else { return }` で使い、
/// 件数が違った時に xctest ごと落ちないようにする（計画 2f-1 の点検）
func hasCount<T>(_ a: [T], _ n: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
    XCTAssertEqual(a.count, n, message, file: file, line: line)
    return a.count == n
}
