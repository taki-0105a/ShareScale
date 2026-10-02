import Foundation
import XCTest
@testable import ShareScaleEngine

/// 差し替えられる単調な時計（秒）
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval
    init(_ t: TimeInterval = 1000) { self.t = t }
    var now: TimeInterval { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

/// 記録の行を集める
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [String] = []
    func append(_ s: String) { lock.withLock { v.append(s) } }
    var all: [String] { lock.withLock { v } }
    var text: String { all.joined(separator: "\n") }
    func count(_ needle: String) -> Int { all.filter { $0.contains(needle) }.count }
}

/// 試験ごとの一時フォルダ（自分で作ったものだけ消す）
class TempDirTestCase: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sse-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }
    var stateFile: EngineStateFile { EngineStateFile(url: dir.appendingPathComponent("engine.json")) }
}

/// 偽のディスプレイ（実際のディスプレイに触れない）。`apply` は一覧の実画素を書き換える
final class FakeDisplays: DisplayProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [DisplaySnapshot]
    private var port: Bool
    private var fallback: String?
    private var failure: String?
    private var applied: [String] = []
    private var afterApply: (@Sendable (inout [DisplaySnapshot]) -> Void)?

    init(_ displays: [DisplaySnapshot], port: Bool = true) { list = displays; self.port = port }

    var displays: [DisplaySnapshot] {
        get { lock.withLock { list } }
        set { lock.withLock { list = newValue } }
    }
    var portOpen: Bool {
        get { lock.withLock { port } }
        set { lock.withLock { port = newValue } }
    }
    var fallbackReason: String? {
        get { lock.withLock { fallback } }
        set { lock.withLock { fallback = newValue } }
    }
    /// 次からの適用を失敗させる（nil で成功に戻す）
    var applyFailure: String? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    /// 適用の後に一覧を書き換える（ほかの何かが倍率を戻す、など）
    func afterEachApply(_ f: @escaping @Sendable (inout [DisplaySnapshot]) -> Void) { lock.withLock { afterApply = f } }
    /// 行った適用（"uuid@factor"）
    var applies: [String] { lock.withLock { applied } }

    func listFresh() -> DisplayReading { lock.withLock { DisplayReading(displays: list, fallbackReason: fallback) } }
    func apply(uuid: String, factor: Int) -> String? {
        lock.withLock {
            applied.append("\(uuid)@\(factor)")
            if let failure { return failure }
            list = list.map { d in
                guard d.uuid == uuid else { return d }
                var n = d; n.pixelWidth = d.width * factor; n.pixelHeight = d.height * factor; return n
            }
            afterApply?(&list)
            return nil
        }
    }
    func portSession(maxAge: TimeInterval) -> Bool { lock.withLock { port } }
}
