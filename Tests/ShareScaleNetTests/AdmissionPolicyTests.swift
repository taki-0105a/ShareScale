import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

final class AdmissionPolicyTests: XCTestCase {
    var t0: ContinuousClock.Instant { ContinuousClock.now }
    func ip(_ s: String) -> IPAddress { IPAddress(s)! }
    func admit(_ p: inout AdmissionPolicy, _ s: String, at now: ContinuousClock.Instant) -> AdmissionTicket? {
        if case let .admit(t) = p.decide(source: ip(s), now: now) { return t }
        return nil
    }
    func reject(_ p: inout AdmissionPolicy, _ s: String, at now: ContinuousClock.Instant) -> RejectReason? {
        if case let .reject(r) = p.decide(source: ip(s), now: now) { return r }
        return nil
    }

    func testAcceptedClassesAndDefaults() {
        var p = AdmissionPolicy()
        let now = t0
        XCTAssertNotNil(admit(&p, "127.0.0.1", at: now))
        XCTAssertNotNil(admit(&p, "192.168.1.9", at: now))
        XCTAssertNotNil(admit(&p, "100.101.77.7", at: now))
        XCTAssertEqual(reject(&p, "8.8.8.8", at: now), .sourceNotAccepted, "グローバルは既定で断る")
        XCTAssertEqual(p.decide(source: nil, now: now), .reject(.unknownSource))
        p.network.allowGlobal = true
        XCTAssertEqual(reject(&p, "8.8.8.8", at: now), .reservedForKnown, "4 本目は知っている送り元のため（3 本は開いている）")
    }
    func testTailscaleOnly() {
        var p = AdmissionPolicy(network: NetworkPolicy(tailscaleOnly: true))
        XCTAssertEqual(reject(&p, "192.168.1.9", at: t0), .notTailscale)
        XCTAssertEqual(reject(&p, "127.0.0.1", at: t0), .notTailscale)
        XCTAssertNotNil(admit(&p, "100.64.0.1", at: t0))
        XCTAssertNotNil(admit(&p, "fd7a:115c:a1e0::9", at: t0))
    }
    func testConnectionLimits() {
        var p = AdmissionPolicy()
        let now = t0
        let first = admit(&p, "10.0.0.1", at: now)!
        XCTAssertEqual(reject(&p, "10.0.0.1", at: now), .tooManyFromSource, "同じ送り元は 1 本")
        XCTAssertEqual(reject(&p, "::ffff:10.0.0.1", at: now), .tooManyFromSource, "IPv4-mapped も同じ送り元")
        p.finish(first, outcome: .served(pid(1), .status), authenticated: true, now: now)   // 10.0.0.1 は照合に成功した（知っている送り元）
        _ = admit(&p, "10.0.0.2", at: now)!; _ = admit(&p, "10.0.0.3", at: now)!; _ = admit(&p, "10.0.0.4", at: now)!
        XCTAssertEqual(p.openConnections, 3)
        XCTAssertEqual(reject(&p, "10.0.0.5", at: now), .reservedForKnown, "知らない送り元は 3 本まで")
        let known = admit(&p, "10.0.0.1", at: now)
        XCTAssertNotNil(known, "知っている送り元は 4 本目を使える")
        XCTAssertEqual(reject(&p, "10.0.0.9", at: now), .tooManyConnections, "4 本で全体の上限")
        p.finish(known!, outcome: .noRequest, authenticated: false, now: now)
        XCTAssertEqual(reject(&p, "10.0.0.5", at: now), .reservedForKnown, "空いた 4 本目も知らない送り元には渡さない")
        XCTAssertEqual(reject(&p, "10.0.0.1", at: now + .seconds(24 * 3600 + 1)), .reservedForKnown, "24 時間過ぎれば知らない送り元")
        XCTAssertNotNil(admit(&p, "10.0.0.1", at: now + .seconds(24 * 3600 - 1)), "24 時間以内なら知っている")
    }
    func testLinkLocalAndTailnetAreBucketedPerAddress() {
        var p = AdmissionPolicy()
        _ = admit(&p, "fe80::1", at: t0)!
        XCTAssertNotNil(admit(&p, "fe80::2", at: t0), "リンクローカルはアドレスごと（/64 で全員を止めない）")
        _ = admit(&p, "fd7a:115c:a1e0::1", at: t0)!
        XCTAssertEqual(reject(&p, "fd7a:115c:a1e0::2", at: t0), .reservedForKnown, "上限 3 本に達した（同じ送り元ではない）")
    }
    func testLockoutAfterElevenFailuresInAMinute() {
        var p = AdmissionPolicy()
        var now = t0
        for i in 0..<10 {
            let t = admit(&p, "10.0.0.5", at: now)!
            p.finish(t, outcome: .handshakeFailed, authenticated: false, now: now)
            now += .seconds(1)
            let again = admit(&p, "10.0.0.5", at: now)
            XCTAssertNotNil(again, "\(i + 1) 回目までは受け付ける")
            if let again { p.finish(again, outcome: .served(pid(1), .status), authenticated: true, now: now) }   // 成功は数えない
            let other = admit(&p, "10.0.0.5", at: now)
            XCTAssertNotNil(other)
            if let other { p.finish(other, outcome: .badRequest(pid(1)), authenticated: true, now: now) }         // 照合の後の規則違反も数えない
        }
        // 10 回の失敗（1 秒おき）は締め出さない。11 回目で締め出す
        let t = admit(&p, "10.0.0.5", at: now)!
        p.finish(t, outcome: .notPaired(.proof), authenticated: false, now: now)
        XCTAssertEqual(reject(&p, "10.0.0.5", at: now), .lockedOut)
        XCTAssertTrue(p.isLockedOut("10.0.0.5/32", now: now))
        XCTAssertEqual(reject(&p, "10.0.0.5", at: now + .seconds(299)), .lockedOut)
        XCTAssertNotNil(admit(&p, "10.0.0.5", at: now + .seconds(301)), "5 分で解ける")
        XCTAssertNotNil(admit(&p, "10.0.0.6", at: now), "別の送り元は巻き込まない")
    }
    func testFailuresOutsideTheWindowDoNotCount() {
        var p = AdmissionPolicy()
        var now = t0
        for _ in 0..<10 { let t = admit(&p, "10.0.0.7", at: now)!; p.finish(t, outcome: .handshakeTimeout, authenticated: false, now: now) }
        now += .seconds(61)
        let t = admit(&p, "10.0.0.7", at: now)!; p.finish(t, outcome: .handshakeTimeout, authenticated: false, now: now)
        XCTAssertNotNil(admit(&p, "10.0.0.7", at: now), "60 秒より前の失敗は数えない")
    }
    func testRejectionsAndSuccessesDoNotCountAsFailures() {
        var p = AdmissionPolicy()
        let now = t0
        for _ in 0..<30 { _ = reject(&p, "8.8.8.8", at: now) }                      // 断るだけ（TLS の前）
        p.network.allowGlobal = true
        XCTAssertNotNil(admit(&p, "8.8.8.8", at: now), "断った回数は失敗に数えない")
        for _ in 0..<30 { let t = admit(&p, "10.0.0.8", at: now)!; p.finish(t, outcome: .badRequest(pid(1)), authenticated: true, now: now) }
        XCTAssertNotNil(admit(&p, "10.0.0.8", at: now), "照合の後の規則違反は数えない")
        XCTAssertEqual(p.rejectionCounts(since: now)[.sourceNotAccepted], 30)
    }
    func testKnownIsDecidedByAuthenticationNotByOutcome() {
        var p = AdmissionPolicy()
        let now = t0
        let t1 = admit(&p, "10.3.0.1", at: now)!
        p.finish(t1, outcome: .badRequest(pid(1)), authenticated: true, now: now)
        XCTAssertTrue(p.isKnown("10.3.0.1/32", now: now), "照合の後の規則違反でも、照合に成功した送り元は知っている")
        let t2 = admit(&p, "10.3.0.2", at: now)!
        p.finish(t2, outcome: .cancelled, authenticated: true, now: now)
        XCTAssertTrue(p.isKnown("10.3.0.2/32", now: now), "照合の後に切られても同じ")
        let t3 = admit(&p, "10.3.0.3", at: now)!
        p.finish(t3, outcome: .noRequest, authenticated: false, now: now)
        XCTAssertFalse(p.isKnown("10.3.0.3/32", now: now), "失敗しかしていない送り元は知らない")
        let t4 = admit(&p, "10.3.0.4", at: now)!
        p.finish(t4, outcome: .notPaired(.proof), authenticated: false, now: now)
        XCTAssertFalse(p.isKnown("10.3.0.4/32", now: now))
    }
    func testTablesAreBounded() {
        var limits = AdmissionLimits(); limits.lockoutTableMax = 3; limits.knownTableMax = 2; limits.failuresPerWindow = 0
        var p = AdmissionPolicy(limits: limits)
        var now = t0
        for i in 1...5 {
            let t = admit(&p, "10.1.0.\(i)", at: now)!; p.finish(t, outcome: .handshakeFailed, authenticated: false, now: now); now += .seconds(1)
        }
        XCTAssertFalse(p.isLockedOut("10.1.0.1/32", now: now), "古い締め出しから捨てる（表は 3 件まで）")
        XCTAssertFalse(p.isLockedOut("10.1.0.2/32", now: now))
        XCTAssertTrue(p.isLockedOut("10.1.0.5/32", now: now))
        for i in 1...3 { let t = admit(&p, "10.2.0.\(i)", at: now)!; p.finish(t, outcome: .served(pid(1), .status), authenticated: true, now: now); now += .seconds(1) }
        XCTAssertFalse(p.isKnown("10.2.0.1/32", now: now), "知っている送り元の表は 2 件まで")
        XCTAssertTrue(p.isKnown("10.2.0.3/32", now: now))
    }
    func testRejectionsAreCountedPerMinuteAndDroppedAfterADay() {
        var p = AdmissionPolicy()
        let t0 = self.t0
        _ = reject(&p, "8.8.8.8", at: t0)                      // 0 分目
        _ = reject(&p, "8.8.8.8", at: t0 + .seconds(61))       // 1 分目
        _ = reject(&p, "8.8.4.4", at: t0 + .seconds(62))       // 1 分目（同じ理由）
        XCTAssertEqual(p.rejectionCounts(since: t0)[.sourceNotAccepted], 3)
        XCTAssertEqual(p.rejectionCounts(since: t0 + .seconds(60))[.sourceNotAccepted], 2, "分の単位で数える")
        XCTAssertEqual(p.rejectionCounts(since: t0 + .seconds(120))[.sourceNotAccepted], nil)
        _ = reject(&p, "8.8.8.8", at: t0 + .seconds(24 * 3600 + 120))   // 24 時間より古い分は捨てる
        XCTAssertEqual(p.rejectionCounts(since: t0)[.sourceNotAccepted], 1, "24 時間より古い分は残らない")
        XCTAssertEqual(p.rejectionMinutes, 1, "残っているのは 1 分ぶんだけ")
        for _ in 0..<20_000 { _ = reject(&p, "8.8.8.8", at: t0 + .seconds(24 * 3600 + 121)) }
        XCTAssertEqual(p.rejectionCounts(since: t0)[.sourceNotAccepted], 20_001, "件数は上限なく数える（配列で持たない）")
        XCTAssertEqual(p.rejectionMinutes, 1)
    }
    func testSameNetworkGlobalIsAcceptedPerAddress() {
        let nets = LocalNetworks.make([LocalInterface(kind: .wifi, address: ip("2001:db8:1:2::10"), prefix: 64)])
        var p = AdmissionPolicy(network: NetworkPolicy(localNetworks: nets))
        XCTAssertNotNil(admit(&p, "2001:db8:1:2::99", at: t0))
        XCTAssertEqual(reject(&p, "2001:db8:1:3::99", at: t0), .sourceNotAccepted)
    }
}
