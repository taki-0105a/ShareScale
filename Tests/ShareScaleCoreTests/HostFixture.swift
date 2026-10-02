import Darwin
import Foundation
import Network
import XCTest
@testable import ShareScaleCore
import ShareScaleEngine
import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

// ---- ループバックの Host（127.0.0.1 だけで待ち受ける。偽のディスプレイ・偽の確認の窓）----

/// 画面共有の仮想ディスプレイ（識別情報が一致するもの）
func virtualDisplay(factor: Int = 2) -> DisplaySnapshot {
    DisplaySnapshot(uuid: "V1", vendor: 0x6161706c, model: 0x1234, serial: 0x6d767300,
                    width: 1920, height: 997, pixelWidth: 1920 * factor, pixelHeight: 997 * factor)
}

/// 偽のディスプレイ（実際のディスプレイに触れない）。`apply` は一覧の実画素を書き換える
final class FakeDisplays: DisplayProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [DisplaySnapshot]
    init(_ displays: [DisplaySnapshot]) { list = displays }
    func listFresh() -> DisplayReading { lock.withLock { DisplayReading(displays: list) } }
    func apply(uuid: String, factor: Int) -> String? {
        lock.withLock {
            list = list.map { d in
                guard d.uuid == uuid else { return d }
                var n = d; n.pixelWidth = d.width * factor; n.pixelHeight = d.height * factor; return n
            }
            return nil
        }
    }
    func portSession(maxAge: TimeInterval) -> Bool { true }
}

/// 偽の確認の窓。`answer` を返す（確認番号を控える）。`delay` 秒待ってから答える（承認待ちの間の取り消しを試すため）
final class FakeApprover: PairingApprover, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [ApprovalRequest] = []
    private var withdrawn: [ApprovalRequest] = []
    private let _answer: Locked<Bool>
    let delay = Locked<Double>(0)
    init(answer: Bool = true) { _answer = Locked(answer) }
    var answer: Bool { get { _answer.value } set { _answer.value = newValue } }
    var asked: [ApprovalRequest] { lock.withLock { requests } }
    var withdrawals: [ApprovalRequest] { lock.withLock { withdrawn } }
    func requestApproval(_ request: ApprovalRequest) async -> Bool {
        lock.withLock { requests.append(request) }
        let d = delay.value
        if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) }
        return answer
    }
    func withdraw(_ request: ApprovalRequest) { lock.withLock { withdrawn.append(request) } }
}

/// 試験用の Host（`HostRuntime`。`listenScope = .loopbackOnly`）。受け付けの結末を集める
final class HostFixture: @unchecked Sendable {
    let runtime: HostRuntime
    let approver = FakeApprover()
    let events = Locked<[HostEvent]>([])
    /// `LocalHostName`（候補アドレス `<name>.local` の元。nil にすると候補を作れず、`status` は `busy` になる）
    let localHostName = Locked<String?>("studio")
    /// `status`（と `set`）の応答を作る前に待つ秒数（名前を読む所で待つ。TLS の手続きには触れずに 1 往復だけを遅くする）
    let statusDelay = Locked<Double>(0)
    let hostDir: URL

    /// - `maxPerSource`: 同じ送り元（ループバックでは常に 127.0.0.1）の同時接続の上限。余りの接続を試す時は 1 より大きくする
    init(support: URL, logs: URL, maxPerSource: Int = 1) {
        hostDir = support.appendingPathComponent("pairings/host", isDirectory: true)
        var c = HostRuntime.Configuration(supportDirectory: support, logDirectory: logs, machine: "MAC-HOST")
        c.port = listenPortForTests(); c.listenScope = .loopbackOnly   // 通信口 0 にしない（`TestPorts`）
        c.engine.coalesceDelay = 0.02; c.engine.checkInterval = 3600
        c.server.limits.maxPerSource = maxPerSource
        let events = events, localHostName = localHostName, statusDelay = statusDelay
        runtime = HostRuntime(configuration: c, displays: FakeDisplays([virtualDisplay(factor: 2)]), approver: approver,
                              identity: HostIdentity(name: {
                                  let d = statusDelay.value
                                  if d > 0 { Thread.sleep(forTimeInterval: d) }
                                  return "Mac Studio"
                              }, model: { "Mac Studio (2025)" }),
                              readAddresses: { [] }, localHostName: { localHostName.value },
                              onEvent: { e in events.update { $0.append(e) } })
    }

    /// 待ち受けを始め、通信口を返す
    func start() async -> UInt16? {
        runtime.start()
        await waitFor(5) { if case .listening = self.runtime.diagnostics.listener { return true }; return false }
        // 記録の「listener: listening」の行は別の列で後から書かれる。その行も待つ（まだ無い間に `issueCode` が開いた回数を数えると、
        // 初回の行が遅れて書かれた時点で「開き直した」と見て、コードの秘密を入れた開き直しの前に名乗りを送ってしまう）
        await waitFor(5) { self.listens >= 1 }
        if case let .listening(p) = runtime.diagnostics.listener { return p }
        return nil
    }
    func stop() { runtime.stop() }

    /// 受け付けの結末（受け付けた順）
    var outcomes: [HostOutcome] {
        events.value.compactMap { if case let .finished(_, _, _, o) = $0 { return o }; return nil }
    }
    /// `count` 個の結末がそろうまで待つ
    func outcomes(count: Int, timeout: Double = 10) async -> [HostOutcome] {
        await waitFor(timeout) { self.outcomes.count >= count }
        return outcomes
    }
    /// 受け側を開いた回数（記録の「listener: listening」の行の数）
    var listens: Int { runtime.log.recentAll(500).filter { $0.contains("listener: listening") }.count }
    /// コードの発行・名乗りの承認で受け側を開き直す（PSK の組が変わる）ので、直前の回数 `before` から 1 回増えるのを待つ
    func waitReopened(after before: Int) async { await waitFor(5) { self.listens >= before + 1 } }
    /// 新しいコードを出し、受け側が開き直るのを待つ
    func issueCode() async -> PairingCode? {
        let before = listens
        guard let code = runtime.issueCode() else { return nil }
        await waitReopened(after: before)
        return code
    }
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

// ---- つながらない候補の役 ----

/// 誰も待ち受けていないループバックの通信口（つなぐと ECONNREFUSED）。一時の通信口の範囲の外から選ぶ（`TestPorts`）
func closedLoopbackPort() -> UInt16? { TestPorts.shared.take() }

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

/// 生の TCP の中継（IPv6 のループバック `::1` の同じ通信口で待ち受け、Host（127.0.0.1）へ流す。中身は変えない）。
/// 候補は通信口を共有するので、Host と同じ通信口で別のアドレスが要る。macOS のループバックは 127.0.0.1 と ::1 だけなので（127.0.0.2 は bind できず、
/// つなぐと `readyTimeout` まで応答が無い＝黒穴）、役を持つ候補は `::1` の 1 つだけ作れる。
/// - `.relay(delay)`: Host から見る側への流れを `delay` 秒止める（TLS の手続きを遅らせる＝遅い候補の役）
/// - `.gated`: Host から見る側への流れを `release()` まで止める（順番を時間に依らずに決める。計画 2f-1 の点検）
/// - `.blackHole`: 受け付けたまま何も流さない（TLS の手続きが進まない＝`readyTimeout` まで応答が無い候補の役）
/// - `.reject`: 受け付けてすぐ閉じる（すぐ断られる候補の役）
/// - `.closedUntil(時刻)`: その時刻より前に受け付けた接続はすぐ閉じ、後に受け付けた接続は Host へ流す
///   （Host の受け側の開き直しが遅れて、その間つながらない役。判定は受け付けた時刻で行うので、試験の側のタイマーの遅れに依らない。計画 2g）
/// 役は途中で変えられる（`role`。変えた後に受け付けた接続から効く）
final class LoopbackRelay: @unchecked Sendable {
    enum Role { case relay(delay: Double), gated, blackHole, reject, closedUntil(ContinuousClock.Instant) }
    let listener: NWListener
    static let address = "::1"
    private let lock = NSLock()
    private var connections = 0
    /// 黒穴で受け付けた接続（持ち続けないと、負荷の下で先に解放されて閉じ、すぐ断られた候補に見えることがある。計画 2d-2 で見つけた揺れ）
    private var held: [NWConnection] = []
    /// `.gated` で止めている流れ（`release()` で流し始める。流した後に受け付けた接続はすぐ流す）
    private var gate: [() -> Void] = []
    private var released = false
    private var _role: Role
    var role: Role { get { lock.withLock { _role } } set { lock.withLock { _role = newValue } } }

    init(port: UInt16, role: Role) throws {
        _role = role
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(Self.address), port: NWEndpoint.Port(rawValue: port)!)
        p.allowLocalEndpointReuse = true
        listener = try NWListener(using: p)
        let target = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [self] inbound in
            lock.withLock { connections += 1 }
            let q = DispatchQueue(label: "test.relay.\(UUID().uuidString)")
            var role = self.role
            if case let .closedUntil(t) = role { role = ContinuousClock.now < t ? .reject : .relay(delay: 0) }
            switch role {
            case .blackHole:
                lock.withLock { held.append(inbound) }
                inbound.start(queue: q)                         // 受け付けたまま何もしない
            case .reject, .closedUntil:
                inbound.stateUpdateHandler = { if case .ready = $0 { inbound.cancel() } }   // 受け付けてすぐ閉じる
                inbound.start(queue: q)
            case let .relay(delay):
                let outbound = NWConnection(to: target, using: .tcp)
                inbound.start(queue: q); outbound.start(queue: q)
                Self.pump(inbound, outbound)
                q.asyncAfter(deadline: .now() + delay) { Self.pump(outbound, inbound) }
            case .gated:
                let outbound = NWConnection(to: target, using: .tcp)
                inbound.start(queue: q); outbound.start(queue: q)
                Self.pump(inbound, outbound)
                let back = { q.async { Self.pump(outbound, inbound) } }
                let now = lock.withLock { () -> Bool in if released { return true }; gate.append(back); return false }
                if now { back() }
            }
        }
        try startListener(listener, label: "test.relay.listener")
    }

    static func pump(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data, !data.isEmpty { to.send(content: data, completion: .contentProcessed { _ in }) }
            if done || error != nil { from.cancel(); to.cancel(); return }
            pump(from, to)
        }
    }

    /// `.gated` の流れを流し始める
    func release() {
        let g = lock.withLock { () -> [() -> Void] in released = true; defer { gate = [] }; return gate }
        g.forEach { $0() }
    }

    /// 受け付けた接続の数
    var accepted: Int { lock.withLock { connections } }
    func stop() {
        listener.cancel()
        let h = lock.withLock { () -> [NWConnection] in defer { held = [] }; return held }
        h.forEach { $0.cancel() }
    }
}

/// 経過秒数（ContinuousClock）
func secondsSince(_ t0: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - t0
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

/// Host と見る側の保管を持つ試験の土台（`<dir>/host` に Host、`<dir>/support` に見る側）。
/// XCTest は 1 つの試験を 1 つの実体で順に動かし、`host`・`port` は準備（`startHost`）の後に変えないので、
/// `waitFor` の閉包から読んだり `@MainActor` の試験から準備を呼んだりできるよう `@unchecked Sendable` にする
class HostViewerTestCase: TempDirTestCase, @unchecked Sendable {
    var host: HostFixture!
    var port: UInt16 = 0
    override func tearDown() { host?.stop(); host = nil; super.tearDown() }

    /// Host を作って待ち受けを始める。選んだ通信口をほかのプロセスに先に取られて開けなかった時は、通信口を取り直してやり直す（3 回まで）
    func startHost(maxPerSource: Int = 1) async throws {
        for _ in 0..<3 {
            host = HostFixture(support: dir.appendingPathComponent("host", isDirectory: true), logs: dir.appendingPathComponent("logs", isDirectory: true),
                               maxPerSource: maxPerSource)
            if let p = await host.start() { port = p; return }
            host.stop(); host = nil
        }
        XCTFail("待ち受けが始まらない"); throw NetError.timedOut(.connecting)
    }
    /// 見る側の帳簿（`<dir>/support/pairings/viewer`）
    func book(_ settings: MemoryStore = MemoryStore()) -> TargetBook {
        TargetBook(store: SecretStore(base: support, role: .viewer, machine: "MAC-VIEWER"), settings: settings)
    }
    /// Host にペアリング済みの接続先を 1 件作り（コードの発行 → 名乗り → 承認 → 保存 → `status` で確定）、帳簿にも入れる
    func pairedTarget(in b: TargetBook, addresses: [String]? = nil, confirmed: Bool = true) async throws -> TargetEntry {
        let issued = await host.issueCode()
        let code = try XCTUnwrap(issued)
        let before = host.listens
        let newSecret = try await ViewerChannel.pair(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                                     id: code.id, secret: code.secret, name: "MacBook", showCode: { _ in })
        await host.waitReopened(after: before)
        if confirmed {
            _ = try await ViewerChannel.exchange(.status, expecting: .status, to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                                 id: code.id, secret: newSecret)
        }
        let meta = try XCTUnwrap(ViewerMeta(name: "Mac Studio", port: Int(port), addresses: addresses ?? ["127.0.0.1"], confirmed: confirmed))
        try b.add(id: code.id, secret: newSecret, meta: meta)
        return TargetEntry(id: code.id, secret: newSecret, meta: meta)
    }
}
