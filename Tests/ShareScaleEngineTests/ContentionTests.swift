import XCTest
@testable import ShareScaleEngine

/// 「設定した倍率が繰り返し戻される」の検出（純粋な値。時刻は単調な時計の秒）
final class ContentionTests: XCTestCase {
    let c1 = "V1 1920x997"
    /// 直して成功 → 戻される を n 回（間隔 `every` 秒）
    func flip(_ d: inout ContentionDetector, times n: Int, from t0: TimeInterval, every: TimeInterval, condition: String? = nil) {
        for i in 0..<n {
            let t = t0 + Double(i) * every
            d.applied(condition: condition ?? c1, at: t)
            d.needsCorrection(condition: condition ?? c1, at: t + 1)
        }
    }
    func testThreeRevertsWithinAMinuteRaise() {
        var d = ContentionDetector()
        flip(&d, times: 2, from: 0, every: 10)
        XCTAssertFalse(d.active)
        flip(&d, times: 1, from: 20, every: 10)
        XCTAssertTrue(d.active, "60 秒に 3 回")
    }
    func testSpreadOutRevertsDoNotRaise() {
        var d = ContentionDetector()
        flip(&d, times: 5, from: 0, every: 31)
        XCTAssertFalse(d.active, "60 秒の中には 2 回しか入らない")
    }
    func testCountsOnlyOncePerApply() {
        var d = ContentionDetector()
        d.applied(condition: c1, at: 0)
        for t in stride(from: 1.0, to: 10, by: 2) { d.needsCorrection(condition: c1, at: t) }
        XCTAssertFalse(d.active, "直せずに見ている間は数えない")
    }
    func testResizeIsNotARevert() {
        var d = ContentionDetector()
        for i in 0..<5 {
            d.applied(condition: "V1 \(1900 + i)x997", at: Double(i))
            d.needsCorrection(condition: "V1 \(1901 + i)x997", at: Double(i) + 0.5)
        }
        XCTAssertFalse(d.active, "窓の大きさが変わった（ダイナミック解像度）ものは数えない")
    }
    func testLowersAfterAQuietMinute() {
        var d = ContentionDetector()
        flip(&d, times: 3, from: 0, every: 5)
        XCTAssertTrue(d.active)
        d.settled(at: 30)
        XCTAssertTrue(d.active, "戻されてから 60 秒たつまでは下ろさない")
        d.settled(at: 72)
        XCTAssertFalse(d.active)
    }
    func testResetClears() {
        var d = ContentionDetector()
        flip(&d, times: 3, from: 0, every: 5)
        d.reset()
        XCTAssertFalse(d.active)
        flip(&d, times: 2, from: 20, every: 5)
        XCTAssertFalse(d.active, "数え直す")
    }
}
