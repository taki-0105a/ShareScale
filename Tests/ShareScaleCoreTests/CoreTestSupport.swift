import Darwin
import Foundation
import XCTest
@testable import ShareScaleCore
import ShareScaleProtocol

// ---- 値 ----

/// 配列の件数を確かめる（違えば試験を失敗にして false を返す）。結果の配列を添字で読む前に `guard hasCount(a, n) else { return }` で使い、
/// 件数が違った時に xctest ごと落ちないようにする（計画 2f-1 の点検）
func hasCount<T>(_ a: [T], _ n: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
    XCTAssertEqual(a.count, n, message, file: file, line: line)
    return a.count == n
}

func pid(_ n: UInt8) -> PairingID { PairingID(bytes: [UInt8](repeating: n, count: 16))! }
func secret(_ n: UInt8) -> Bytes32 { Bytes32(Data(repeating: n, count: 32))! }

let lg = LocalDisplay(id: 1, name: "LG ULTRAWIDE", pixels: Resolution(width: 2560, height: 1080), backingScale: 1, isBuiltIn: false)
let builtIn = LocalDisplay(id: 2, name: "内蔵Retinaディスプレイ", pixels: Resolution(width: 3024, height: 1964), backingScale: 2, isBuiltIn: true)

/// Host の `status` の応答（既定は画面共有中・1x・仮想ディスプレイあり）
func payload(name: String = "Studio", model: String = "Mac Studio", paused: Bool = false, session: Bool = true, mode: Mode = .oneX,
             vd: StatusPayload.VirtualDisplay? = StatusPayload.VirtualDisplay(resolution: "1920x997", scaling: .oneX, source: .signature),
             ambiguous: Bool = false, lastError: String? = nil, setBy: StatusPayload.SetBy? = nil,
             port: Int = 47651, addresses: [String] = ["studio.local"]) -> StatusPayload {
    StatusPayload(name: name, model: model, paused: paused, session: session, mode: mode, virtualDisplay: vd, ambiguous: ambiguous,
                  lastError: lastError, setBy: setBy, port: port, addresses: addresses)!
}

/// 接続中の状態（画面共有中で、仮想ディスプレイが見分けられている）
func connected(mode: DisplayMode = .x1, scaling: DisplayMode = .x1) -> RemoteState {
    RemoteState(payload(mode: mode.wire, vd: StatusPayload.VirtualDisplay(resolution: "1920x997", scaling: scaling == .x2 ? .twoX : .oneX, source: .signature)))
}

// ---- 偽物 ----

/// 呼ばれた回数を数え、用意した結果を返す偽の接続先
final class FakeTarget: TargetControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: Result<RemoteState, ViewerFailure>
    private var _set: Result<RemoteState, ViewerFailure>?
    private var _statusCalls = 0
    private var _setCalls: [DisplayMode] = []
    init(_ status: Result<RemoteState, ViewerFailure>) { _status = status }
    var statusResult: Result<RemoteState, ViewerFailure> { get { lock.withLock { _status } } set { lock.withLock { _status = newValue } } }
    var setResult: Result<RemoteState, ViewerFailure>? { get { lock.withLock { _set } } set { lock.withLock { _set = newValue } } }
    var statusCalls: Int { lock.withLock { _statusCalls } }
    var setCalls: [DisplayMode] { lock.withLock { _setCalls } }
    func status() async -> Result<RemoteState, ViewerFailure> { lock.withLock { _statusCalls += 1; return _status } }
    func set(_ mode: DisplayMode) async -> Result<RemoteState, ViewerFailure> { lock.withLock { _setCalls.append(mode); return _set ?? _status } }
}

/// 結果を返すタイミングをテスト側で決められる偽の接続先（取り違えの再現用）
final class GatedTarget: TargetControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Result<RemoteState, ViewerFailure>, Never>] = []
    let result: Result<RemoteState, ViewerFailure>
    private var _setCalls: [DisplayMode] = []
    init(_ r: Result<RemoteState, ViewerFailure>) { result = r }
    var setCalls: [DisplayMode] { lock.withLock { _setCalls } }
    func status() async -> Result<RemoteState, ViewerFailure> { await withCheckedContinuation { k in lock.withLock { waiting.append(k) } } }
    func set(_ mode: DisplayMode) async -> Result<RemoteState, ViewerFailure> { lock.withLock { _setCalls.append(mode) }; return await status() }
    func release() {
        let ks = lock.withLock { () -> [CheckedContinuation<Result<RemoteState, ViewerFailure>, Never>] in let w = waiting; waiting = []; return w }
        ks.forEach { $0.resume(returning: result) }
    }
    var pending: Int { lock.withLock { waiting.count } }
}

/// VPN の確認を止めておき、テスト側の合図で結果を返す
final class VPNGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Bool, Never>?
    var isWaiting: Bool { lock.withLock { waiting != nil } }
    func wait() async -> Bool { await withCheckedContinuation { k in lock.withLock { waiting = k } } }
    func release(_ v: Bool) { let k = lock.withLock { () -> CheckedContinuation<Bool, Never>? in let w = waiting; waiting = nil; return w }; k?.resume(returning: v) }
}

/// メモリ上の保存先（`UserDefaults` の代わり。ファイルを作らない）
final class MemoryStore: StringStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value as? String } }
    var all: [String: String] { lock.withLock { values } }
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
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
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
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ssc-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        chmod(dir.path, 0o700)
        try? FileManager.default.removeItem(at: dir)
    }
    /// 見る側の保管の置き場所（`<dir>/support`）
    var support: URL { dir.appendingPathComponent("support", isDirectory: true) }
    var viewerDir: URL { support.appendingPathComponent("pairings/viewer", isDirectory: true) }
}
