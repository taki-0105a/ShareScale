import Network
import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

/// 外からの取り消しと、承認と保存の 2 段（取り消しの後に秘密を保存しない）
final class CancellationTests: XCTestCase {
    let a = pid(0xA1), sa = secret(0x11)

    // ---- 外からの取り消し（誤りなら 5〜8 秒かかるものを 2 秒で見る。負荷の下でも、正しい時の値と誤りの時の値の間に上限が入るように。計画 2g）----
    func testCancellingServeDuringApprovalReturnsAtOnce() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code); d.approveMode = .untilCancelled
        let h = try LoopbackHost(psks: [a: sa], delegate: d, timeouts: fastTimeouts { $0.approval = 8 }); defer { h.stop() }
        let ch = try await helloAndReveal(h, id: a, secret: sa)
        await waitFor(5) { d.codes.count == 1 }
        XCTAssertEqual(d.codes.count, 1, "承認待ちに入った")
        let t0 = ContinuousClock.now
        h.cancelServing()
        let o = await h.outcomes(count: 1, timeout: 5)
        XCTAssertLessThan(secondsSince(t0), 2.0, "承認の上限（8 秒）を待たずに戻る")
        XCTAssertEqual(o, [.cancelled])
        XCTAssertFalse(HostOutcome.cancelled.countsAsFailure)
        await waitFor(3) { d.cancellations == 1 }
        XCTAssertEqual(d.cancellations, 1, "承認のタスクも取り消す（確認の窓を取り下げる）")
        XCTAssertTrue(d.completions.isEmpty, "保存しない")
        do { _ = try await ch.receive(expecting: .reveal, timeout: 2); XCTFail("応答が来た") }
        catch let e as NetError { XCTAssertEqual(e, .closed, "接続を閉じる") }
    }
    func testCancellingServeDuringRespondReturnsAtOnce() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered); d.respondMode = .untilCancelled
        let h = try LoopbackHost(psks: [a: sa], delegate: d, timeouts: fastTimeouts { $0.firstRequest = 5; $0.total = 8 }); defer { h.stop() }
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        try await ch.sendFirst(.status)
        await waitFor(5) { d.respondCalls == 1 }
        XCTAssertEqual(d.respondCalls, 1, "応答を作っている途中")
        let t0 = ContinuousClock.now
        h.cancelServing()
        let o = await h.outcomes(count: 1, timeout: 5)
        XCTAssertLessThan(secondsSince(t0), 2.0, "全体の上限（8 秒）を待たずに戻る")
        XCTAssertEqual(o, [.cancelled])
        await waitFor(3) { d.cancellations == 1 }
        XCTAssertEqual(d.cancellations, 1, "respond のタスクも取り消す")
        do { _ = try await ch.receive(expecting: .status, timeout: 2); XCTFail("応答が来た") }
        catch let e as NetError { XCTAssertEqual(e, .closed) }
    }
    func testCancellingServeWhileWaitingForTheFirstRequestReturnsAtOnce() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try LoopbackHost(psks: [a: sa], delegate: d, timeouts: fastTimeouts { $0.firstRequest = 5; $0.total = 8 }); defer { h.stop() }
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        try await Task.sleep(nanoseconds: 100_000_000)
        let t0 = ContinuousClock.now
        h.cancelServing()
        let o = await h.outcomes(count: 1, timeout: 5)
        XCTAssertLessThan(secondsSince(t0), 2.0, "読み取りの上限（5 秒）を待たずに戻る")
        XCTAssertEqual(o, [.cancelled])
        withExtendedLifetime(ch) {}
    }
    func testViewerCancellationIsReportedAsCancelled() async throws {
        // 見る側のタスクの取り消しは NetError.cancelled（閉じられた・時間切れと区別する）
        let h = try ScriptedHost(psks: [a: sa]) { ch, _, _ in try? await Task.sleep(nanoseconds: 8_000_000_000); ch.close() }
        defer { h.stop() }
        let endpoint = h.endpoint, a = self.a, sa = self.sa
        let task = Task { try await ViewerChannel.exchange(.unpair, expecting: .unpair, to: endpoint, id: a, secret: sa, timeout: 10) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let t0 = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch let e as NetError { XCTAssertEqual(e, .cancelled) }
        XCTAssertLessThan(secondsSince(t0), 2.0, "偽の Host が閉じる 8 秒・締め切りの 10 秒を待たずに戻る")
    }

    // ---- 承認と保存の 2 段 ----
    func testApprovalArrivingJustAfterTheDeadlineIsNotSaved() async throws {
        // 上限（0.5 秒）から 1 秒遅れて「追加する」が返る
        let d = FakeDelegate(); d.register(a, sa, .code); d.approveMode = .lateApprove(1.5)
        let h = try LoopbackHost(psks: [a: sa], delegate: d, timeouts: fastTimeouts { $0.approval = 0.5 }); defer { h.stop() }
        let ch = try await helloAndReveal(h, id: a, secret: sa)
        let r = try await ch.receive(expecting: .reveal, timeout: 5)
        XCTAssertEqual(r, .error(.notPaired))
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.notPaired(.approvalTimeout)])
        // 遅れた「追加する」が返るのを待ち（時間の決め打ちでなく出来事を待つ）、その後も保存されないことを見る
        await waitFor(5) { d.lateApprovals == 1 }
        XCTAssertEqual(d.lateApprovals, 1, "遅れた「追加する」が返った")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(d.completions.isEmpty, "時間切れの後の承認では保存しない")
    }
    func testSaveFailureIsNotPairedForTheViewerAndNotAFailure() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code); d.decide = { _, _ in true }; d.newSecret = nil
        let h = try LoopbackHost(psks: [a: sa], delegate: d); defer { h.stop() }
        do { _ = try await ViewerChannel.pair(to: h.endpoint, id: a, secret: sa, name: "MacBook", showCode: { _ in }); XCTFail() }
        catch let e as NetError { XCTAssertEqual(e, .rejected(.notPaired), "保存できなければ not_paired") }
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.saveFailed(codeID: a)])
        XCTAssertEqual(o.first?.countsAsFailure, false, "Host 側の都合なので失敗に数えない")
        XCTAssertEqual(d.completions.count, 1)
    }
}
