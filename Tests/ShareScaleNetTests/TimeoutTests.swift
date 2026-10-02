import Network
import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

/// 時間の上限（仕様「時間の上限」）。上限は試験用に短くするが、負荷で Host の Task が 1 秒遅れても手続きと往復が収まる長さにし、
/// 断定の上限は「正しい時の値」と「誤りの時の値」の間に置く（正しい時の値から 2 秒、誤りの時の値からも 2 秒以上離す）。測り始めは製品の締め切りの起点にそろえる:
/// 受け付けから数える上限（全体）は受け付けから、承認待ちの上限は承認が呼ばれた時から、最初の指示の上限は見る側がつながった時から測る（計画 2g）
final class TimeoutTests: XCTestCase {
    let a = pid(0xA1), sa = secret(0x11)

    // ---- delegate.respond の上限 ----
    func testStuckRespondIsCutAtTotalDeadline() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered); d.respondMode = .stuck
        defer { d.releaseParked() }
        let h = try LoopbackHost(psks: [a: sa], delegate: d, timeouts: fastTimeouts { $0.total = 3.0 }); defer { h.stop() }
        do { _ = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: a, secret: sa, timeout: 12); XCTFail("応答が来た") }
        catch let e as NetError { XCTAssertEqual(e, .closed, "応答せずに閉じる") }
        let o = await h.timedOutcomes(count: 1, timeout: 5)
        XCTAssertEqual(o.map(\.outcome), [.delegateTimeout])
        XCTAssertGreaterThan(o.first?.seconds ?? 0, 2.9, "全体の上限（受け付けから 3 秒）より前には閉じない")
        XCTAssertLessThan(o.first?.seconds ?? 99, 5.0, "全体の上限（3 秒）で閉じる（止まった相手役を待たない。待つと、見る側が諦める 12 秒まで閉じない）")
        XCTAssertFalse(o.first?.outcome.countsAsFailure ?? true, "Host 側の遅れは失敗に数えない")
    }

    // ---- 承認待ちの上限 ----
    func testApprovalThatNeverReturnsEndsAtLimit() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code); d.approveMode = .stuck
        defer { d.releaseParked() }
        let h = try LoopbackHost(psks: [a: sa], delegate: d, timeouts: fastTimeouts { $0.approval = 1.0 }); defer { h.stop() }
        let ch = try await helloAndReveal(h, id: a, secret: sa)
        let r = try await ch.receive(expecting: .reveal, timeout: 8)
        XCTAssertEqual(r, .error(.notPaired), "時間切れは not_paired")
        let o = await h.outcomes(count: 1, timeout: 5)
        XCTAssertEqual(o, [.notPaired(.approvalTimeout)])
        // 承認待ちの上限は、承認が呼ばれた時から数える（受け付けからではない）。同じ起点から測る
        let asked = try XCTUnwrap(d.approvalStartedAt.first), ended = try XCTUnwrap(h.finishedAt.first)
        XCTAssertGreaterThan((ended - asked).seconds, 0.9, "承認待ちの上限（1 秒）より前には終わらない")
        XCTAssertLessThan((ended - asked).seconds, 3.0, "承認待ちの上限（1 秒）で終わる（返らない承認を待たない。待つと、見る側が諦める 8 秒まで終わらない）")
        XCTAssertTrue(o.first?.countsAsFailure ?? false)
    }
    func testApprovalTimeoutCancelsTheWindow() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code); d.approveMode = .untilCancelled
        let h = try LoopbackHost(psks: [a: sa], delegate: d, timeouts: fastTimeouts { $0.approval = 0.5 }); defer { h.stop() }
        let ch = try await helloAndReveal(h, id: a, secret: sa)
        let r = try await ch.receive(expecting: .reveal, timeout: 5)
        XCTAssertEqual(r, .error(.notPaired))
        await waitFor(2) { d.cancellations == 1 }
        XCTAssertEqual(d.cancellations, 1, "時間切れで確認の窓を取り下げる（子タスクの取り消し）")
    }
    func testViewerClosingDuringApprovalCancelsTheWindow() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code); d.approveMode = .untilCancelled
        let h = try LoopbackHost(psks: [a: sa], delegate: d, timeouts: fastTimeouts { $0.approval = 8 }); defer { h.stop() }
        let ch = try await helloAndReveal(h, id: a, secret: sa)
        await waitFor(5) { d.codes.count == 1 }
        XCTAssertEqual(d.codes.count, 1, "確認の窓が出ている")
        let t0 = ContinuousClock.now
        ch.close()
        let o = await h.outcomes(count: 1, timeout: 6)
        XCTAssertEqual(o, [.notPaired(.peerClosed)])
        XCTAssertLessThan(secondsSince(t0), 3.0, "承認待ちの上限（8 秒）を待たない")
        await waitFor(2) { d.cancellations == 1 }
        XCTAssertEqual(d.cancellations, 1, "見る側が閉じたら確認の窓を取り下げる")
    }

    // ---- 名乗り: 受け付けから確認の窓を出すまで（全体の上限）----
    func testHelloIsBoundByTotalEvenIfRevealLimitIsLonger() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code)
        let h = try LoopbackHost(psks: [a: sa], delegate: d, timeouts: fastTimeouts { $0.reveal = 10; $0.total = 3.0 }); defer { h.stop() }
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        try await ch.sendFirst(.hello(name: "MacBook", commitment: Commitment.make(Bytes32.random()!)))
        guard case .helloChallenge = try await ch.receive(expecting: .hello, timeout: 2) else { return XCTFail("乱数が来ない") }
        // 開示を送らない
        let o = await h.timedOutcomes(count: 1, timeout: 12)
        XCTAssertEqual(o.map(\.outcome), [.notPaired(.noReveal)])
        XCTAssertGreaterThan(o.first?.seconds ?? 0, 2.9, "全体の上限（受け付けから 3 秒）より前には切れない")
        XCTAssertLessThan(o.first?.seconds ?? 99, 5.0, "開示の上限（乱数を送ってから 10 秒）ではなく、受け付けからの全体の上限（3 秒）で切れる")
    }

    // ---- 遅い送り手 ----
    func testSlowSenderIsCutAtFirstRequestDeadline() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try LoopbackHost(psks: [a: sa], delegate: d, timeouts: fastTimeouts { $0.firstRequest = 1.0; $0.total = 20 }); defer { h.stop() }
        let beforeOpen = ContinuousClock.now   // Host の .ready は、これより後
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        let ready = ContinuousClock.now   // 最初の指示の上限は .ready から数える（見る側がつながった時とほぼ同じ時刻）
        // 1 バイトずつ 50 ミリ秒おきに 6 秒間送り続ける（改行は送らない）
        let sender = Task {
            for _ in 0..<120 {
                if Task.isCancelled { break }
                try? await ch.channel.send(Data("a".utf8), until: .now() + 1)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { sender.cancel() }
        let o = await h.outcomes(count: 1, timeout: 12)
        XCTAssertEqual(o, [.noRequest])
        let ended = try XCTUnwrap(h.finishedAt.first)
        XCTAssertLessThan((ended - ready).seconds, 3.5, "届いた塊ごとに締め切りを延ばさない（上限は .ready から 1 秒。延ばすと 6 秒以上）")
        XCTAssertGreaterThan((ended - beforeOpen).seconds, 0.9, "上限（.ready から 1 秒）より前には切らない（つなぎ始める前から測るので、1 秒より短くはならない）")
    }

    // ---- 受け付けの時刻から数える ----
    func testHandshakeLimitCountsFromAcceptedAt() async throws {
        // 受け付けてから serve まで待たせた（acceptedAt が過去）場合、手続きの上限はそこから数える
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let accepted = Box<NWConnection>()
        let l = try NWListener(using: loopbackParameters(TLSSettings.parameters(psks: [a: sa])))
        l.newConnectionHandler = { accepted.set($0) }
        try startListener(l, label: "test.accepted"); defer { l.cancel() }
        let port = l.port!, id = a, key = sa
        let viewer = Task { try? await ViewerChannel.open(to: .hostPort(host: "127.0.0.1", port: port), id: id, secret: key, readyTimeout: 3) }
        defer { viewer.cancel() }
        await waitFor(2) { accepted.value != nil }
        let c = try XCTUnwrap(accepted.value)
        let o = await HostConnection.serve(c, delegate: d, timeouts: fastTimeouts { $0.handshake = 1 }, acceptedAt: .now() - 2)
        XCTAssertEqual(o, .handshakeTimeout, "受け付けから 2 秒たっているので、手続きの上限（1 秒）はもう過ぎている")
    }
    func testTotalLimitCountsFromAcceptedAt() async throws {
        // 受け付けてから serve まで 2 秒待たせた場合、全体の上限（3 秒）は受け付けから数えるので、止まった応答は serve の 1 秒ほど後に切れる
        // （serve を呼んだ時から数えると 3 秒後）
        let d = FakeDelegate(); d.register(a, sa, .registered); d.respondMode = .stuck
        defer { d.releaseParked() }
        let accepted = Box<NWConnection>()
        let l = try NWListener(using: loopbackParameters(TLSSettings.parameters(psks: [a: sa])))
        l.newConnectionHandler = { accepted.set($0) }
        try startListener(l, label: "test.accepted.total"); defer { l.cancel() }
        let port = l.port!, id = a, key = sa
        let viewer = Task { try? await ViewerChannel.exchange(.status, expecting: .status, to: .hostPort(host: "127.0.0.1", port: port), id: id, secret: key, timeout: 12) }
        defer { viewer.cancel() }
        await waitFor(5) { accepted.value != nil }
        let c = try XCTUnwrap(accepted.value)
        let t0 = ContinuousClock.now
        let o = await HostConnection.serve(c, delegate: d, timeouts: fastTimeouts { $0.total = 3 }, acceptedAt: .now() - 2)
        let seconds = secondsSince(t0)
        XCTAssertEqual(o, .delegateTimeout)
        XCTAssertEqual(d.respondCalls, 1, "応答を作る所までは進んでいる")
        XCTAssertGreaterThan(seconds, 0.5, "受け付けから 3 秒（serve から 1 秒）より前には切らない")
        XCTAssertLessThan(seconds, 2.0, "受け付けから数える（serve を呼んだ時から数えると 3 秒）")
    }
}
