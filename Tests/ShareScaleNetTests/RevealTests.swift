import Network
import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

/// 名乗りの 2 つ目の行（開示）の扱い（仕様「指示と応答」の「応答するかどうか」を開示にも当てる）
final class RevealTests: XCTestCase {
    let a = pid(0xA1), sa = secret(0x11)

    /// 名乗り → 乱数を受け取る → `line(r_v)` をそのまま送る → 応答（来なければそのエラー）と Host の結末。
    /// `limit` は開示の上限（秒）。開示を送る試験では、乱数を受け取ってから開示を送るまでが負荷で遅れても切れない長さ（5 秒）にし、
    /// 短くするのは「開示を送らない」試験だけ（計画 2g。0.5 秒を全部の試験に使っていて、負荷の下では送る前に切れていた）
    func reveal(limit: Double = 5, _ line: @escaping (Bytes32) -> Data?) async throws -> (Result<Response, Error>, HostOutcome?) {
        let d = FakeDelegate(); d.register(a, sa, .code); d.decide = { _, _ in true }
        let h = try LoopbackHost(psks: [a: sa], delegate: d, timeouts: fastTimeouts { $0.reveal = limit }); defer { h.stop() }
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        let rv = Bytes32.random()!
        try await ch.sendFirst(.hello(name: "MacBook", commitment: Commitment.make(rv)))
        guard case .helloChallenge = try await ch.receive(expecting: .hello, timeout: 5) else { XCTFail("乱数が来ない"); return (.failure(NetError.closed), nil) }
        if let l = line(rv) { try await ch.channel.send(l, until: .now() + 5) }
        let r: Result<Response, Error>
        do { r = .success(try await ch.receive(expecting: .reveal, timeout: 8)) } catch { r = .failure(error) }
        let o = await h.outcomes(count: 1, timeout: 5)
        XCTAssertEqual(d.codes, [], "確認の窓は出さない")
        return (r, o.first)
    }
    func b64(_ n: Int) -> String { Base64URL.encode(Data(repeating: 7, count: n)) }
    func assertClosedWithoutReply(_ r: Result<Response, Error>, file: StaticString = #filePath, line: UInt = #line) {
        switch r {
        case let .success(resp): XCTFail("応答が来た: \(resp)", file: file, line: line)
        case let .failure(e): XCTAssertEqual(e as? NetError, .closed, file: file, line: line)
        }
    }

    func testNoRevealIsNotPaired() async throws {
        let (r, o) = try await reveal(limit: 1.0) { _ in nil }   // 開示の上限（1 秒）で切れる。切れなければ、見る側が諦める 8 秒で `.timedOut` になり下の断定が落ちる
        assertClosedWithoutReply(r)
        XCTAssertEqual(o, .notPaired(.noReveal))
        XCTAssertEqual(o?.countsAsFailure, true)
    }
    func testUnreadableRevealIsDroppedWithoutReply() async throws {
        for bad in [Data("hello\n".utf8), Data("[1]\n".utf8), Data("{\"op\":\"reveal\"}\n".utf8),
                    Data(repeating: 0x61, count: Limits.requestMaxBytes + 1), Data("{\"v\":1}\r\n".utf8)] {
            let (r, o) = try await reveal { _ in bad }
            assertClosedWithoutReply(r)
            XCTAssertEqual(o, .notPaired(.revealUnreadable), String(decoding: bad.prefix(20), as: UTF8.self))
            XCTAssertEqual(o?.countsAsFailure, true, "名乗りの途中なので失敗に数える")
        }
    }
    func testRevealWithOtherVersionIsUnsupported() async throws {
        let (r, o) = try await reveal { rv in Data("{\"v\":2,\"op\":\"reveal\",\"r\":\"\(Base64URL.encode(rv.data))\"}\n".utf8) }
        XCTAssertEqual(try r.get(), .error(.unsupportedVersion))
        XCTAssertEqual(o, .notPaired(.revealVersion))
        XCTAssertEqual(o?.countsAsFailure, true)
    }
    func testRevealRuleViolationsAreBadRequest() async throws {
        let lines: [(String, (Bytes32) -> Data)] = [
            ("開示以外の指示", { _ in Data("{\"v\":1,\"op\":\"status\"}\n".utf8) }),
            ("余分なキー", { rv in Data("{\"v\":1,\"op\":\"reveal\",\"r\":\"\(Base64URL.encode(rv.data))\",\"x\":1}\n".utf8) }),
            ("id・proof を付けた", { rv in Data("{\"v\":1,\"op\":\"reveal\",\"r\":\"\(Base64URL.encode(rv.data))\",\"id\":\"\(self.a.hex)\",\"proof\":\"\(self.b64(32))\"}\n".utf8) }),
            ("31 バイトの r", { _ in Data("{\"v\":1,\"op\":\"reveal\",\"r\":\"\(self.b64(31))\"}\n".utf8) }),
            ("33 バイトの r", { _ in Data("{\"v\":1,\"op\":\"reveal\",\"r\":\"\(self.b64(33))\"}\n".utf8) }),
        ]
        for (label, line) in lines {
            let (r, o) = try await reveal(line)
            XCTAssertEqual(try r.get(), .error(.badRequest), label)
            XCTAssertEqual(o, .badRequest(a), label)
        }
    }
}
