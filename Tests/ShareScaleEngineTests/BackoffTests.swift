import XCTest
@testable import ShareScaleEngine

/// 時刻は単調な時計の秒（壁時計の Date ではない。時計を戻しても判定が変わらないように）
final class BackoffTests: XCTestCase {
    let t0: TimeInterval = 1_000_000

    func testDoublesUpToMax() {
        var b = Backoff(base: 30, maxWait: 600)
        let waits = (0..<7).map { i in b.failed(condition: "2x", now: t0 + Double(i)) }
        XCTAssertEqual(waits, [30, 60, 120, 240, 480, 600, 600])
    }

    func testWaitsOnlyUntilDeadline() {
        var b = Backoff(base: 30, maxWait: 600)
        b.failed(condition: "2x", now: t0)
        XCTAssertTrue(b.shouldWait(condition: "2x", now: t0 + 29))
        XCTAssertFalse(b.shouldWait(condition: "2x", now: t0 + 30))
    }

    // 【L8】経過秒だけで判断する（1000.0 で失敗 → 1029.9 は待つ、1030.0 は待たない）
    func testBackoffWaitsByElapsedSeconds() {
        var b = Backoff(base: 30, maxWait: 600)
        XCTAssertEqual(b.failed(condition: "2x", now: 1000.0), 30)
        XCTAssertTrue(b.shouldWait(condition: "2x", now: 1029.9))
        XCTAssertFalse(b.shouldWait(condition: "2x", now: 1030.0))
    }

    func testModeChangeRetriesImmediatelyAndRestartsCount() {   // 利用者が設定を変えたら待たない
        var b = Backoff(base: 30, maxWait: 600)
        b.failed(condition: "2x", now: t0); b.failed(condition: "2x", now: t0)
        XCTAssertFalse(b.shouldWait(condition: "1x", now: t0 + 1))
        XCTAssertEqual(b.failed(condition: "1x", now: t0), 30)
    }

    func testDisplaySizeChangeRetriesImmediately() {   // 画面共有の窓の大きさが変わったら待たない
        var b = Backoff(base: 30, maxWait: 600)
        b.failed(condition: "2x 1923x997", now: t0)
        XCTAssertTrue(b.shouldWait(condition: "2x 1923x997", now: t0 + 1))
        XCTAssertFalse(b.shouldWait(condition: "2x 1901x997", now: t0 + 1))
    }

    func testResetClears() {
        var b = Backoff(base: 30, maxWait: 600)
        b.failed(condition: "2x", now: t0); b.reset()
        XCTAssertFalse(b.shouldWait(condition: "2x", now: t0 + 1))
        XCTAssertEqual(b.failures, 0)
    }
}
