import XCTest
@testable import ShareScaleEngine
@testable import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// 指示への応答（偽のディスプレイ・偽の確認の窓。通信はしない）
final class HostControllerTests: TempDirTestCase {
    let identity = HostIdentity(name: { "Mac Studio" }, model: { "Mac Studio (2025)" })
    var fake: FakeDisplays!
    var maintainer: ScaleMaintainer!
    var log: HostLog!
    let addrs = Locked<[String]>(["studio.local"])

    func make(approver: PairingApprover? = nil, coalesce: TimeInterval = 0.02) -> HostController {
        fake = FakeDisplays([virtualDisplay(factor: 2)])
        let l = HostLog(directory: nil)
        log = l
        var s = ScaleMaintainer.Settings(); s.coalesceDelay = coalesce
        maintainer = ScaleMaintainer(provider: fake, file: EngineStateFile(url: dir.appendingPathComponent("engine.json")), settings: s,
                                     log: { l.write($0, topic: .engine) })
        let addrs = addrs
        return HostController(maintainer: maintainer, log: log, approver: approver, identity: identity,
                              addresses: { (47651, addrs.value) }, wallClock: { Date(timeIntervalSince1970: 1_800_000_000) })
    }
    func status(_ r: Response) -> StatusPayload? { if case let .status(s) = r { return s }; return nil }

    func testStatusReportsTheMaintainerSnapshot() async {
        let c = make()
        maintainer.evaluate(reason: "startup")   // 保存が無いので 1x に直す
        let r = await c.respond(to: .status, from: pid(1))
        let s = status(r)
        XCTAssertEqual(s?.name, "Mac Studio"); XCTAssertEqual(s?.model, "Mac Studio (2025)")
        XCTAssertEqual(s?.session, true); XCTAssertEqual(s?.paused, false); XCTAssertEqual(s?.mode, .oneX)
        XCTAssertEqual(s?.virtualDisplay, StatusPayload.VirtualDisplay(resolution: "1920x997", scaling: .oneX, source: .signature))
        XCTAssertEqual(s?.port, 47651); XCTAssertEqual(s?.addresses, ["studio.local"])
        XCTAssertNil(s?.setBy); XCTAssertNil(s?.lastError)
    }
    // set は mode と set_by を保存し、反映を待ってから状態を返す。set_by は自分か、ほかの見る側か
    func testSetWaitsForTheChangeAndRecordsWhoSetIt() async {
        let c = make()
        let r = await c.respond(to: .set(.twoX), from: pid(1))
        XCTAssertEqual(status(r)?.virtualDisplay?.scaling, .twoX)
        XCTAssertEqual(status(r)?.setBy, StatusPayload.SetBy(byYou: true, at: 1_800_000_000))
        let other = await c.respond(to: .status, from: pid(2))
        XCTAssertEqual(status(other)?.setBy, StatusPayload.SetBy(byYou: false, at: 1_800_000_000), "ほかの見る側の名前は渡さない")
        XCTAssertEqual(EngineStateFile(url: dir.appendingPathComponent("engine.json")).load().state.mode, .x2)
        let lines = log.recent(for: pid(1)).joined(separator: "\n")
        XCTAssertTrue(lines.contains("set 2x"), lines)
        XCTAssertFalse(log.recent(for: pid(2)).joined().contains("set 2x"), "ほかの見る側の set は含めない")
    }
    func testSetIsRefusedWhilePausedAndBusyWhileTheLastSetIsPending() async {
        let c = make(coalesce: 3600)            // 予定した判定を動かさない（前の指示が残る）
        maintainer.setPaused(true)
        let paused = await c.respond(to: .set(.oneX), from: pid(1))
        XCTAssertEqual(paused, .error(.paused))
        maintainer.setPaused(false)
        _ = maintainer.requestMode(.x2, by: pid(2).hex, at: 1)
        let busy = await c.respond(to: .set(.oneX), from: pid(1))
        XCTAssertEqual(busy, .error(.busy))
        let s = await c.respond(to: .status, from: pid(1))
        XCTAssertNotNil(status(s), "一時停止中・反映中でも status は使える")
    }
    func testLastErrorPrefersContention() {
        var s = EngineSnapshot()
        XCTAssertNil(HostController.lastError(s))
        s.lastError = "apply failed"
        XCTAssertEqual(HostController.lastError(s), "apply failed")
        s.contention = true
        XCTAssertEqual(HostController.lastError(s), "the scale keeps being changed back (another app may be changing it)")
        // 外からの理由（入れ替えの途中）は、`last_error` を作らない（倍率の維持が記録した文がそのまま出る。計画 2i で、ほかの常駐との競合の固定文を外した）
        s.holds = [.updating]
        XCTAssertEqual(HostController.lastError(s), "the scale keeps being changed back (another app may be changing it)")
        s.contention = false
        XCTAssertEqual(HostController.lastError(s), "apply failed")
    }
    func testStatusWithoutCandidateAddressesIsBusy() async {
        let c = make()
        addrs.value = []
        let r = await c.respond(to: .status, from: pid(1))
        XCTAssertEqual(r, .error(.busy), "0 件の addrs は見る側が拒否するので送らない")
    }
    func testLogAndPairingRequestsInOtherShapes() async {
        let c = make()
        maintainer.evaluate(reason: "startup")
        let r = await c.respond(to: .log, from: pid(1))
        guard case let .log(lines) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(lines.joined().contains("startup: applied 1x"), lines.joined(separator: "\n"))
        let hello = await c.respond(to: .unpair, from: pid(1))
        XCTAssertEqual(hello, .error(.badRequest), "unpair は HostServer が扱う")
    }
    func testApprovalGoesToTheApprover() async {
        let approver = FakeApprover(answer: true)
        let c = make(approver: approver)
        let ok = await c.approvePairing(codeID: pid(7), name: "MacBook", confirmationCode: 12345, source: "192.168.1.9", sourceClass: .privateV4)
        XCTAssertTrue(ok)
        XCTAssertEqual(approver.asked, [ApprovalRequest(codeID: pid(7), name: "MacBook", confirmationCode: 12345, source: "192.168.1.9", sourceClass: .privateV4)])
        XCTAssertEqual(approver.asked.first?.formattedCode, "012 345")
        let no = await make(approver: nil).approvePairing(codeID: pid(7), name: "MacBook", confirmationCode: 1, source: "?", sourceClass: .loopback)
        XCTAssertFalse(no, "窓が無ければ承認しない")
    }
    // 承認待ちが取り消されたら（時間切れ・切断）窓を取り下げ、承認しない
    func testCancelledApprovalIsWithdrawn() async {
        let approver = FakeApprover(hold: true)
        let c = make(approver: approver)
        let task = Task { await c.approvePairing(codeID: pid(7), name: "MacBook", confirmationCode: 1, source: "10.0.0.2", sourceClass: .privateV4) }
        await waitFor(3) { approver.asked.count == 1 }
        task.cancel()
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(approver.withdrawals.map(\.codeID), [pid(7)])
        XCTAssertTrue(log.recentAll().joined().contains("pairing withdrawn"), log.recentAll().joined(separator: "\n"))
    }
}
