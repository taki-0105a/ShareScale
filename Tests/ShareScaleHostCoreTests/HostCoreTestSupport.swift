import Foundation
import XCTest
@testable import ShareScaleEngine
@testable import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// 配列の件数を確かめる（違えば試験を失敗にして false を返す）。結果の配列を添字で読む前に `guard hasCount(a, n) else { return }` で使い、
/// 件数が違った時に xctest ごと落ちないようにする（計画 2f-1 の点検）
func hasCount<T>(_ a: [T], _ n: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
    XCTAssertEqual(a.count, n, message, file: file, line: line)
    return a.count == n
}

func pid(_ n: UInt8) -> PairingID { PairingID(bytes: [UInt8](repeating: n, count: 16))! }
func ip(_ s: String) -> ShareScaleProtocol.IPAddress { ShareScaleProtocol.IPAddress(s)! }

/// 画面共有の仮想ディスプレイ（識別情報が一致するもの）と物理モニタ
func virtualDisplay(factor: Int = 2) -> DisplaySnapshot {
    DisplaySnapshot(uuid: "V1", vendor: 0x6161706c, model: 0x1234, serial: 0x6d767300,
                    width: 1920, height: 997, pixelWidth: 1920 * factor, pixelHeight: 997 * factor)
}

/// 偽のディスプレイ（実際のディスプレイに触れない）。`apply` は一覧の実画素を書き換える
final class FakeDisplays: DisplayProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [DisplaySnapshot]
    init(_ displays: [DisplaySnapshot]) { list = displays }
    var displays: [DisplaySnapshot] { lock.withLock { list } }
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

/// 条件が満たされるまで待つ（最大 `timeout` 秒）
func waitFor(_ timeout: Double, _ cond: @escaping @Sendable () -> Bool) async {
    let end = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
    while !cond(), ContinuousClock.now < end { try? await Task.sleep(nanoseconds: 10_000_000) }
}

/// 試験ごとの一時フォルダ（自分で作ったものだけ消す。利用者のホームの実際の置き場所には書かない）
class TempDirTestCase: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sshc-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        chmod(dir.path, 0o700)
        try? FileManager.default.removeItem(at: dir)
    }
    var hostDir: URL { dir.appendingPathComponent("support/pairings/host", isDirectory: true) }
    func hostStore() -> SecretStore { SecretStore(base: dir.appendingPathComponent("support", isDirectory: true), role: .host, machine: "MAC-TEST") }
}

/// 偽の確認の窓。`answer` を返す。`hold` なら取り消されるまで待つ
final class FakeApprover: PairingApprover, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [ApprovalRequest] = []
    private var withdrawn: [ApprovalRequest] = []
    let answer: Bool
    let hold: Bool
    init(answer: Bool = true, hold: Bool = false) { self.answer = answer; self.hold = hold }
    var asked: [ApprovalRequest] { lock.withLock { requests } }
    var withdrawals: [ApprovalRequest] { lock.withLock { withdrawn } }
    func requestApproval(_ request: ApprovalRequest) async -> Bool {
        lock.withLock { requests.append(request) }
        if hold { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }; return false }
        return answer
    }
    func withdraw(_ request: ApprovalRequest) { lock.withLock { withdrawn.append(request) } }
}
