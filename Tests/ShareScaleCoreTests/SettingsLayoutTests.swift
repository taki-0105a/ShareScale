import XCTest
@testable import ShareScaleCore

/// 設定の窓のタブの高さの上限（計画 2h）。純粋な計算
final class SettingsLayoutTests: XCTestCase {
    func testLimitFitsTheVisibleHeightOfTheScreen() {
        // 高さ 800pt ほどの画面（メニューバーと Dock を除いた見える高さが 700pt 前後）: 窓の題名とタブの並びを足しても、画面からはみ出さない
        XCTAssertEqual(SettingsLayout.maxPaneHeight(visibleHeight: 700), 580)
        XCTAssertEqual(SettingsLayout.maxPaneHeight(visibleHeight: 775), 655)
        for visible in stride(from: 400.0, through: 2000.0, by: 25.0) {
            let limit = SettingsLayout.maxPaneHeight(visibleHeight: visible)
            XCTAssertLessThanOrEqual(limit + SettingsLayout.reserved, max(visible, SettingsLayout.shortest + SettingsLayout.reserved), "\(visible)")
            XCTAssertLessThanOrEqual(limit, SettingsLayout.tallest); XCTAssertGreaterThanOrEqual(limit, SettingsLayout.shortest)
        }
        // 大きい画面でも、決めた高さ（820）より高くしない。とても小さい画面でも、280 より低くしない
        XCTAssertEqual(SettingsLayout.tallest, 820)
        XCTAssertEqual(SettingsLayout.maxPaneHeight(visibleHeight: 1415), 820)
        XCTAssertEqual(SettingsLayout.maxPaneHeight(visibleHeight: 940), 820, "境目")
        XCTAssertEqual(SettingsLayout.maxPaneHeight(visibleHeight: 939), 819)
        XCTAssertEqual(SettingsLayout.maxPaneHeight(visibleHeight: 300), 280)
        // 画面の高さが分からない・おかしい値の時は、決めた値
        for odd in [nil, 0, -5, Double.nan, Double.infinity] as [Double?] {
            XCTAssertEqual(SettingsLayout.maxPaneHeight(visibleHeight: odd), SettingsLayout.fallback, "\(String(describing: odd))")
        }
    }

    // 窓のある画面が変わった知らせの採り入れ方（点検 2h・再点検 2h）: 切り替えた直後は、小さくなる向きだけ採る（画面の境目で、判定が入れ替わり続けない）
    func testScreenChangesRightAfterASwitchOnlyGoSmaller() {
        var s = SettingsLayout.PaneScreen()
        // 最初の 1 回は、すぐに採る
        s = SettingsLayout.adopt(1415, at: 100, into: s)
        XCTAssertEqual(s, SettingsLayout.PaneScreen(visibleHeight: 1415, changedAt: nil))
        // 同じ値・分からない値・おかしい値は、何も変えない
        for same in [1415, nil, 0, -1, Double.nan] as [Double?] { XCTAssertEqual(SettingsLayout.adopt(same, at: 100.1, into: s), s, "\(String(describing: same))") }
        // 別の画面（小さい方）に移った: 採る
        s = SettingsLayout.adopt(700, at: 200, into: s)
        XCTAssertEqual(s, SettingsLayout.PaneScreen(visibleHeight: 700, changedAt: 200))
        // 上限が変わって窓の高さが変わり、境目で大きい方の画面に戻ったと知らされても、直後（1 秒）は採らない
        for time in [200.05, 200.5, 200.99] { XCTAssertEqual(SettingsLayout.adopt(1415, at: time, into: s), s, "\(time)") }
        XCTAssertEqual(SettingsLayout.adopt(1415, at: 200 + SettingsLayout.settle, into: s).visibleHeight, 1415, "ちょうど 1 秒たてば、大きくなる向きも採る")
        // 大きい方へ切り替えた直後でも、小さい方への知らせは採る（窓がはみ出さないことを優先する）
        let big = SettingsLayout.adopt(1415, at: 300, into: s)
        XCTAssertEqual(big, SettingsLayout.PaneScreen(visibleHeight: 1415, changedAt: 300))
        XCTAssertEqual(SettingsLayout.adopt(700, at: 300.05, into: big), SettingsLayout.PaneScreen(visibleHeight: 700, changedAt: 300.05), "大 → 小は、1 秒の中でも採る")
        XCTAssertEqual(SettingsLayout.adopt(500, at: 300.06, into: SettingsLayout.adopt(700, at: 300.05, into: big)).visibleHeight, 500, "さらに小さい方へも")
    }

    // 画面の境目での入れ替わりは、多くても 2 回の切り替えで止まり、捨てて残る値は必ず小さい側（再点検 2h）
    func testFlipFloppingStopsWithinTwoSwitchesOnTheSmallerScreen() {
        let small = 700.0, large = 1415.0
        // 境目の窓の動き: 上限が大きい（窓が高い）と小さい画面に多く載り、上限が小さい（窓が低い）と大きい画面に多く載る。
        // 知らせは、こちらが切り替えた（窓の高さが変わった）時にだけ、30 ミリ秒後に来る。切り替えなければ、次の知らせは来ない
        func reported(for current: Double) -> Double { current == large ? small : large }
        for start in [large, small] {
            for settled in [true, false] {   // 落ち着いた状態から・切り替えた直後から
                var cur = SettingsLayout.PaneScreen(visibleHeight: start, changedAt: settled ? nil : 99.99)
                var switches = 0, t = 100.0
                while switches < 10 {
                    let proposed = reported(for: cur.visibleHeight ?? 0)
                    let next = SettingsLayout.adopt(proposed, at: t, into: cur)
                    if next == cur {
                        // 捨てた: 残っている値は、捨てた値より小さい（窓が収まる側）
                        XCTAssertLessThan(cur.visibleHeight ?? .infinity, proposed, "start \(start) settled \(settled)")
                        break
                    }
                    switches += 1; cur = next; t += 0.03
                }
                XCTAssertLessThanOrEqual(switches, 2, "start \(start) settled \(settled)")
                XCTAssertEqual(cur.visibleHeight, small, "最後に残るのは小さい側: start \(start) settled \(settled)")
            }
        }
        // 切り替えた直後の 1 秒の間に、入れ替わりの知らせがどんな順で来ても、切り替えは多くても 2 回・残るのは小さい側
        for first in [small, large] {
            var cur = SettingsLayout.adopt(first, at: 100, into: SettingsLayout.PaneScreen(visibleHeight: first == small ? large : small, changedAt: nil))
            var switches = 1
            for n in 0..<30 {   // 30 ミリ秒おきに 0.9 秒
                let proposed = (n % 2 == 0) == (first == small) ? large : small
                let next = SettingsLayout.adopt(proposed, at: 100.03 + Double(n) * 0.03, into: cur)
                if next != cur { switches += 1 } else if proposed != cur.visibleHeight { XCTAssertLessThan(cur.visibleHeight ?? .infinity, proposed) }
                cur = next
            }
            XCTAssertLessThanOrEqual(switches, 2, "first \(first)")
            XCTAssertEqual(cur.visibleHeight, small, "first \(first)")
        }
        // 3 つの画面の間でも、直後に採るのは小さくなる向きだけ
        var cur = SettingsLayout.adopt(1415, at: 10, into: SettingsLayout.PaneScreen(visibleHeight: 900, changedAt: nil))
        var seen: [Double] = []
        for (n, h) in [900.0, 1415, 700, 1415, 900, 700, 2000].enumerated() {
            cur = SettingsLayout.adopt(h, at: 10.01 + Double(n) * 0.01, into: cur)
            seen.append(cur.visibleHeight ?? 0)
        }
        XCTAssertEqual(seen, [900, 900, 700, 700, 700, 700, 700])
    }
}
