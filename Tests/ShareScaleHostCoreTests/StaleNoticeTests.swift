import XCTest
@testable import ShareScaleHostCore
import ShareScaleProtocol

final class StaleNoticeTests: XCTestCase {
    let now: Int64 = 1_800_000_000
    let day: Int64 = 86_400
    func meta(lastSeen: Int64?, created: Int64 = 1_700_000_000, confirmed: Bool = true, snoozed: Int64? = nil) -> HostMeta {
        HostMeta(name: "A", created: created, lastSeen: lastSeen, confirmed: confirmed, noticeSnoozedUntil: snoozed)
    }
    func testDueAfter80Days() {
        let metas: [PairingID: HostMeta] = [pid(1): meta(lastSeen: now - 80 * day), pid(2): meta(lastSeen: now - 80 * day + 1),
                                            pid(3): meta(lastSeen: nil, created: now - 81 * day), pid(4): meta(lastSeen: nil, created: now - day)]
        XCTAssertEqual(StaleNotice.due(metas, now: now), [pid(1), pid(3)], "一度も使われていなければ作った時から数える")
    }
    func testFutureLastSeenAndUnconfirmedAreNotJudged() {
        XCTAssertEqual(StaleNotice.due([pid(1): meta(lastSeen: now + day)], now: now), [], "last_seen が未来なら判定しない")
        XCTAssertEqual(StaleNotice.due([pid(1): meta(lastSeen: now - 100 * day, confirmed: false)], now: now), [])
    }
    func testSnoozeHides30Days() {
        let until = StaleNotice.snoozeUntil(now: now)
        XCTAssertEqual(until, now + 30 * day)
        let m = [pid(1): meta(lastSeen: now - 90 * day, snoozed: until)]
        XCTAssertEqual(StaleNotice.due(m, now: now + 29 * day), [])
        XCTAssertEqual(StaleNotice.due(m, now: now + 30 * day), [pid(1)])
    }
    // 手で作った極端な時刻（読み込みでは拒否される）でも落ちない
    func testExtremeTimesDoNotCrash() {
        let metas: [PairingID: HostMeta] = [pid(1): meta(lastSeen: Int64.min), pid(2): meta(lastSeen: nil, created: Int64.min),
                                            pid(3): meta(lastSeen: Int64.max), pid(4): meta(lastSeen: 0)]
        XCTAssertEqual(StaleNotice.due(metas, now: now), [pid(4)], "あふれるものは判定せず、Int64.max は未来")
        XCTAssertEqual(StaleNotice.due(metas, now: Int64.max), [pid(4)], "Int64.max の last_seen は今と同じで 80 日たっていない。Int64.min はあふれるので判定しない")
        XCTAssertEqual(StaleNotice.due(metas, now: Int64.min), [])
    }
    func testClockJumpingFarAheadOnlyNotifies() {
        let m = [pid(1): meta(lastSeen: now)]
        XCTAssertEqual(StaleNotice.due(m, now: now + 10_000 * day), [pid(1)], "知らせが出るだけで、何も消さない（判定は純粋な関数）")
    }
}
