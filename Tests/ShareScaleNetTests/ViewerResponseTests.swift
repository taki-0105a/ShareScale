import Network
import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

/// 見る側の応答の読み取りと締め切り（偽の Host を試験の中で作る）
final class ViewerResponseTests: XCTestCase {
    let a = pid(0xA1), sa = secret(0x11)

    func exchange(timeout: Double = 2, _ script: @escaping @Sendable (Channel, Data, Bytes32?) async -> Void) async throws -> (Result<Response, Error>, Double) {
        let h = try ScriptedHost(psks: [a: sa], script: script); defer { h.stop() }
        let t0 = ContinuousClock.now
        do {
            let r = try await ViewerChannel.exchange(.unpair, expecting: .unpair, to: h.endpoint, id: a, secret: sa, timeout: timeout)
            return (.success(r), secondsSince(t0))
        } catch { return (.failure(error), secondsSince(t0)) }
    }

    func testResponseOver16KiBIsRejected() async throws {
        let (r, _) = try await exchange { ch, _, _ in
            try? await ch.send(Data(repeating: 0x61, count: Limits.responseMaxBytes + 10) + Data([0x0A]), until: .now() + 2)
            try? await Task.sleep(nanoseconds: 1_000_000_000); ch.close()
        }
        XCTAssertThrowsError(try r.get()) { XCTAssertEqual($0 as? NetError, .frame(.tooLarge)) }
    }
    func testResponseAtTheLimitIsReadButMalformed() async throws {
        // 改行を含めてちょうど 16 KiB（上限内）。形が違うので malformedResponse（上限で切られない）
        let (r, _) = try await exchange { ch, _, _ in
            try? await ch.send(Data(repeating: 0x61, count: Limits.responseMaxBytes - 1) + Data([0x0A]), until: .now() + 2)
            try? await Task.sleep(nanoseconds: 1_000_000_000); ch.close()
        }
        XCTAssertThrowsError(try r.get()) { XCTAssertEqual($0 as? NetError, .malformedResponse) }
    }
    func testBytesAfterNewlineAreRejected() async throws {
        let (r, _) = try await exchange { ch, _, _ in
            try? await ch.send(Response.ok.encoded() + Data("{\"v\":1".utf8), until: .now() + 2)
            try? await Task.sleep(nanoseconds: 1_000_000_000); ch.close()
        }
        XCTAssertThrowsError(try r.get()) { XCTAssertEqual($0 as? NetError, .frame(.bytesAfterNewline)) }
    }
    func testWellFormedReplyIsReadAsControl() async throws {
        let (r, _) = try await exchange { ch, _, _ in
            try? await ch.send(Response.ok.encoded(), until: .now() + 2)
            try? await Task.sleep(nanoseconds: 500_000_000); ch.close()
        }
        XCTAssertEqual(try r.get(), .ok, "対照: 正しい応答は読める")
    }
    func testLateResponseIsCutAtTheDeadline() async throws {
        // 締め切り（2 秒）は接続と送信を含む。負荷の下でも手続きが締め切りの中に収まる長さにし、応答（6 秒後）との間に上限を置く（計画 2g）
        let (r, t) = try await exchange(timeout: 2.0) { ch, _, _ in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            try? await ch.send(Response.ok.encoded(), until: .now() + 2); ch.close()
        }
        XCTAssertThrowsError(try r.get()) { XCTAssertEqual($0 as? NetError, .timedOut(.receiving)) }
        XCTAssertLessThan(t, 4.0, "timeout 秒（2.0）で切れる（応答は 6 秒後）")
        XCTAssertGreaterThan(t, 1.9, "timeout 秒より前には切れない")
    }
    func testSlowHandshakeCountsTowardTheSameDeadline() async throws {
        // 応答しない偽の Host の前に、手続きを 2.0 秒遅らせる中継を置く（手続きの余裕は 1.0 秒）。受信だけ新しい締め切りにすると 5.0 秒以上になる。
        // 正しい時（3.0 秒）と誤りの時（5.0 秒以上）の間に上限を置く（1.5 秒 ±0.3 秒では、タイマーと戻ってからの遅れで外れていた。計画 2g）
        let h = try ScriptedHost(psks: [a: sa]) { ch, _, _ in try? await Task.sleep(nanoseconds: 10_000_000_000); ch.close() }
        defer { h.stop() }
        let relay = try SniffingRelay(to: h.endpoint, delayDownstream: 2.0); defer { relay.stop() }
        let t0 = ContinuousClock.now
        do { _ = try await ViewerChannel.exchange(.unpair, expecting: .unpair, to: relay.endpoint, id: a, secret: sa, timeout: 3.0); XCTFail("応答が来た") }
        catch let e as NetError { XCTAssertEqual(e, .timedOut(.receiving)) }
        let t = secondsSince(t0)
        XCTAssertGreaterThan(t, 2.9, "timeout 秒（3.0）より前には終わらない")
        XCTAssertLessThan(t, 4.0, "接続に使った時間も含めて timeout 秒で終わる（受信に新しい締め切りを与えない。与えると 5 秒以上）")
    }
    func testExchangeRefusesPairingRequests() async throws {
        // exchange で名乗りを送ると接続コードを使用済みにしてしまう。つなぐ前に断る（名乗りは pair で行う）
        let d = FakeDelegate(); d.register(a, sa, .code)
        let h = try LoopbackHost(psks: [a: sa], delegate: d); defer { h.stop() }
        for r in [Request.hello(name: "Mac", commitment: Commitment.make(Bytes32.random()!)), .reveal(random: Bytes32.random()!)] {
            do { _ = try await ViewerChannel.exchange(r, expecting: .hello, to: h.endpoint, id: a, secret: sa, timeout: 2); XCTFail("\(r)") }
            catch let e as NetError { XCTAssertEqual(e, .invalidRequest) }
        }
        let o = await h.outcomes(count: 1, timeout: 0.5)
        XCTAssertEqual(o, [], "つながずに断る")
    }
    func testSlowHandshakeBeyondTheDeadlineTimesOutWhileConnecting() async throws {
        let h = try ScriptedHost(psks: [a: sa]) { ch, _, _ in ch.close() }
        defer { h.stop() }
        let relay = try SniffingRelay(to: h.endpoint, delayDownstream: 2); defer { relay.stop() }
        do { _ = try await ViewerChannel.exchange(.unpair, expecting: .unpair, to: relay.endpoint, id: a, secret: sa, timeout: 0.5); XCTFail() }
        catch let e as NetError { XCTAssertEqual(e, .timedOut(.connecting), "時間切れの段階が分かる") }
    }
}
