import XCTest
@testable import ShareScaleCore

/// 裏での取り直し（計画 2f-2。通知の (b)(c) を前面にない時にも拾う。待たずに数える）
@MainActor
final class BackgroundRefreshTests: XCTestCase {
    func conditions(on: Bool = true, kinds: Set<ChangeNotificationKind> = Set(ChangeNotificationKind.allCases), active: Bool = false,
                    system: Bool = false, screens: Bool = false, woke: Bool = false, lowPower: Bool = false,
                    target: Bool = true, failed: Bool = false) -> BackgroundRefreshPolicy.Conditions {
        BackgroundRefreshPolicy.Conditions(notificationsOn: on, kinds: kinds, appActive: active, systemAsleep: system, screensAsleep: screens,
                                           wokeRecently: woke, lowPowerMode: lowPower, hasTarget: target, lastFailed: failed)
    }

    func testPolicy() {
        XCTAssertEqual(BackgroundRefreshPolicy.delay(conditions()), .seconds(60))
        XCTAssertEqual(BackgroundRefreshPolicy.delay(conditions(failed: true)), .seconds(300), "接続できない後は間を空ける")
        XCTAssertEqual(BackgroundRefreshPolicy.delay(conditions(lowPower: true)), .seconds(300), "低電力モードの間は間を空ける（点検 2f-2）")
        XCTAssertNil(BackgroundRefreshPolicy.delay(conditions(on: false)), "通知がオフなら取り直さない")
        XCTAssertNil(BackgroundRefreshPolicy.delay(conditions(kinds: [.scaleSwitched])), "(b)(c) を選んでいなければ取り直さない")
        XCTAssertEqual(BackgroundRefreshPolicy.delay(conditions(kinds: [.connectionLost])), .seconds(60))
        XCTAssertEqual(BackgroundRefreshPolicy.delay(conditions(kinds: [.changedByOther])), .seconds(60))
        XCTAssertNil(BackgroundRefreshPolicy.delay(conditions(active: true)), "前面にある時は取り直さない")
        XCTAssertNil(BackgroundRefreshPolicy.delay(conditions(system: true)), "システムが眠っている間は取り直さない")
        XCTAssertNil(BackgroundRefreshPolicy.delay(conditions(screens: true)), "画面が眠っている間も取り直さない")
        XCTAssertNil(BackgroundRefreshPolicy.delay(conditions(woke: true)), "戻った直後は取り直さない（誤報を防ぐ。点検 2f-2）")
        XCTAssertNil(BackgroundRefreshPolicy.delay(conditions(target: false)), "接続先が無い")
    }

    // 眠りの様子: システムと画面を別々に持ち、どちらかが眠っていれば眠っている。戻ってから 60 秒は「戻った直後」（点検 2f-2）
    func testSleepStateKeepsSystemAndScreensApartAndRemembersTheWake() {
        let t0 = ContinuousClock.now
        var s = SleepState()
        XCTAssertFalse(s.wokeRecently(at: t0))
        s.handle(.screensDidSleep, at: t0)
        s.handle(.willSleep, at: t0)
        s.handle(.didWake, at: t0 + .seconds(100))
        XCTAssertFalse(s.systemAsleep); XCTAssertTrue(s.screensAsleep, "システムが戻っても画面はまだ眠っている")
        s.handle(.screensDidWake, at: t0 + .seconds(110))
        XCTAssertFalse(s.screensAsleep)
        XCTAssertTrue(s.wokeRecently(at: t0 + .seconds(169)))
        XCTAssertFalse(s.wokeRecently(at: t0 + .seconds(170)), "最後に戻ってから 60 秒で終わる")
        // システムだけが戻った（画面の知らせが来ない）時も「戻った直後」（再点検 2f-2。一時の写しで didWake の時刻を覚えないようにすると落ちることを確かめた）
        var only = SleepState()
        only.handle(.willSleep, at: t0)
        only.handle(.didWake, at: t0 + .seconds(5))
        XCTAssertFalse(only.systemAsleep); XCTAssertTrue(only.wokeRecently(at: t0 + .seconds(30)))
    }

    func testRefresherWaitsThenChecksAgainBeforeRefreshing() async {
        var c = conditions()
        var slept: [Duration] = []
        var refreshes = 0
        let done = expectation(description: "5 回待った")
        var r: BackgroundRefresher?
        r = BackgroundRefresher(conditions: { c }, refresh: { refreshes += 1 }, sleep: { d in
            slept.append(d)
            switch slept.count {
            case 1: break                         // 60 秒待った → 取り直す
            case 2: c.appActive = true            // 待つ間に前面に来た → 取り直さない
            case 3: c.appActive = false; c.lastFailed = true   // 条件を確かめ直した（30 秒）→ 次は失敗の後なので 300 秒
            case 5: r?.stop(); done.fulfill()
            default: break
            }
            await Task.yield()
        })
        r?.start(); r?.start()   // 2 回目は何もしない
        XCTAssertEqual(r?.isRunning, true)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(slept.prefix(4).map { $0 }, [.seconds(60), .seconds(60), .seconds(30), .seconds(300)])
        XCTAssertEqual(refreshes, 2, "1 回目の後と、300 秒の後")
        XCTAssertEqual(r?.isRunning, false)
    }
}
