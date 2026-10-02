import AppKit
import SwiftUI
import XCTest
import ShareScaleCore
@testable import ShareScaleUI

/// 設定のタブの高さ（計画 2h。実機確認 A: 「接続先」のタブ（251pt）から「この Mac の接続先」に移っても、窓が 251pt のままだった）。
/// ウインドウは出さない（`NSHostingController` に、最小・理想・最大の高さを聞くだけ）
@MainActor
final class SettingsPaneTests: XCTestCase {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var languageBefore = AppLanguage.current
    /// この試験が作った、表示しないウインドウ（終わったら手放す）
    private var windows: [NSWindow] = []
    override func setUp() async throws { languageBefore = AppLanguage.current; AppLanguage.current = .ja }
    override func tearDown() async throws { windows = []; AppLanguage.current = languageBefore }
    /// 高さの比べ方の幅（`fittingSize` は 1pt 単位に切り上げ、`sizeThatFits` は端数のまま返す）
    let rounding: CGFloat = 1

    /// 入れ物に入れた時の高さが、最小・理想・最大とも `expected` であること
    func assertPane(_ content: some View, limit: CGFloat, is expected: CGFloat, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let pane = Measure.heights(SettingsPane(maxHeight: limit) { content })
        XCTAssertEqual(pane.min, expected, accuracy: rounding, "最小: \(label)", file: file, line: line)
        XCTAssertEqual(pane.ideal, expected, accuracy: rounding, "理想: \(label)", file: file, line: line)
        XCTAssertEqual(pane.max, expected, accuracy: rounding, "最大: \(label)", file: file, line: line)
    }

    // 「この Mac の接続先」のタブ: 高さは中身に合わせ、上限で止める。最小・理想・最大が同じなので、窓が前のタブの高さのまま残らない
    func testHostTabTakesItsContentHeightUpToTheLimit() {
        var contentHeights: [Int: CGFloat] = [:]
        for viewers in [0, 3, 32] {
            let content = Measure.heights(hostContent(viewers: viewers))
            XCTAssertEqual(content.min, content.ideal, accuracy: rounding, "中身そのものは伸び縮みしない")
            contentHeights[viewers] = content.ideal
            for limit: CGFloat in [300, 620, 10_000] {
                assertPane(hostContent(viewers: viewers), limit: limit, is: min(content.ideal, limit), "接続元 \(viewers) 台・上限 \(limit)")
            }
        }
        let empty = contentHeights[0] ?? 0, many = contentHeights[32] ?? 0
        XCTAssertGreaterThan(empty, 251, "中身は、前のタブ（接続先が無い時の 251pt）より高い")
        XCTAssertGreaterThan(many, CGFloat(SettingsLayout.tallest), "接続元の Mac が 32 台なら、どの画面の上限も超える（中をスクロールする）")
        XCTAssertLessThanOrEqual(contentHeights[3] ?? 0, CGFloat(SettingsLayout.tallest), "3 台なら、大きい画面ではスクロールなしで収まる")
        XCTAssertLessThan(empty, CGFloat(SettingsLayout.maxPaneHeight(visibleHeight: 800)), "ふつうの画面では、スクロールなしで収まる")
    }

    // 直す前の形（`ScrollView` に上限だけを付ける）は、最小の高さが 0 で、窓が前のタブの高さのまま残る（この試験が、直した理由の記録）
    func testBareScrollViewHasNoMinimumHeight() {
        let old = Measure.heights(ScrollView { hostContent(viewers: 0) }.frame(maxHeight: 620))
        XCTAssertEqual(old.min, 0, accuracy: rounding, "ScrollView は 0 まで縮む")
        XCTAssertGreaterThan(old.ideal, 251)
    }

    // 「接続先」と「一般」のタブも同じ入れ物（接続先が 32 件の時・小さい画面で、窓が画面からはみ出さない）
    func testTargetsAndGeneralTabsFollowTheSameRule() async {
        for count in [0, 3, 32] {
            let h = Measure.heights(targetsContent(count)).ideal
            assertPane(targetsContent(count), limit: 620, is: min(h, 620), "接続先 \(count) 件")
            assertPane(targetsContent(count), limit: 10_000, is: h, "接続先 \(count) 件・上限なし")
        }
        XCTAssertGreaterThan(Measure.heights(targetsContent(32)).ideal, CGFloat(SettingsLayout.tallest))
        // 一般のタブは、日本語でも英語でも、いちばん高い形（通知が許可されていない・ログイン項目の承認待ち）でも、大きい画面ではスクロールなしで収まる
        for language in [AppLanguage.ja, .en] {
            AppLanguage.current = language
            let cases: [(String, GeneralSettings)] = [("一般", await generalContent()), ("一般・通知が許可されていない", await generalContent(.denied, notificationsOn: true)),
                                                     ("一般・いちばん高い形", await generalContent(.denied, notificationsOn: true, openAtLogin: .requiresApproval))]
            for (name, content) in cases {
                let h = Measure.heights(content).ideal
                assertPane(content, limit: 10_000, is: h, "\(name) \(language)")
                assertPane(content, limit: 500, is: 500, "\(name)・小さい画面 \(language)")
                XCTAssertLessThanOrEqual(h, CGFloat(SettingsLayout.tallest), "大きい画面では、一般のタブはスクロールなしで収まる: \(name) \(language)（\(h)）")
            }
            // 「この Mac の接続先」と「接続先」も、どちらの言語でも同じ決まり
            let host = Measure.heights(hostContent(viewers: 3)).ideal
            assertPane(hostContent(viewers: 3), limit: 10_000, is: host, "この Mac の接続先 \(language)")
            XCTAssertLessThanOrEqual(host, CGFloat(SettingsLayout.tallest), "\(language)（\(host)）")
            assertPane(targetsContent(32), limit: 620, is: 620, "接続先 32 件 \(language)")
        }
    }

    // 上限を超える分は、タブの中をスクロールする（入れ物は上限の高さで、中の `ScrollView` は中身の高さを持つ。点検 2h）
    func testContentBeyondTheLimitScrollsInsideThePane() throws {
        let content = hostContent(viewers: 32)
        let full = Measure.heights(content).ideal
        func scrollView(limit: CGFloat) throws -> NSScrollView {
            let host = NSHostingView(rootView: SettingsPane(maxHeight: limit) { content }.frame(width: 560))
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 560, height: limit), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            windows.append(window)
            func find(_ v: NSView) -> NSScrollView? { (v as? NSScrollView) ?? v.subviews.lazy.compactMap(find).first }
            return try XCTUnwrap(find(host), "ScrollView が見つからない")
        }
        // 中身（32 台）が上限を超える: スクロールの枠は上限の高さ、中身はそのままの高さ（切り詰めない）
        let scrolling = try scrollView(limit: 400)
        XCTAssertEqual(scrolling.frame.height, 400, accuracy: rounding)
        XCTAssertEqual(scrolling.documentView?.frame.height ?? 0, full, accuracy: rounding, "中身はそのままの高さで、枠の中をスクロールする")
        XCTAssertGreaterThan(scrolling.documentView?.frame.height ?? 0, scrolling.contentView.bounds.height + 100)
        // 収まる時は、枠と中身が同じ高さ（スクロールしない）
        let small = Measure.heights(hostContent(viewers: 0)).ideal
        let fitting = try scrollView(limit: 10_000)
        XCTAssertEqual(fitting.frame.height, full, accuracy: rounding)
        XCTAssertEqual(fitting.documentView?.frame.height ?? 0, fitting.contentView.bounds.height, accuracy: rounding)
        XCTAssertLessThan(small, full)
    }

    // 上限を渡さなければ、画面の見える高さから決める（`SettingsLayout.maxPaneHeight`）。窓に載る前は、キーの窓のある画面で見積もる
    func testLimitComesFromTheScreenWhenNotGiven() {
        let limit = CGFloat(SettingsLayout.maxPaneHeight(visibleHeight: NSScreen.main.map { Double($0.visibleFrame.height) }))
        let pane = Measure.heights(SettingsPane { hostContent(viewers: 32) })
        XCTAssertEqual(pane.min, limit, accuracy: rounding); XCTAssertEqual(pane.ideal, limit, accuracy: rounding); XCTAssertEqual(pane.max, limit, accuracy: rounding)
    }

    // 3 つのタブとも入れ物に入っている（タブの組み立ては実物の保管の口を持つので、ここではソースの形を見る）
    func testAllThreeTabsAreInThePane() throws {
        let s = try String(contentsOf: root.appendingPathComponent("Sources/ShareScaleUI/SettingsView.swift"), encoding: .utf8)
        XCTAssertEqual(s.components(separatedBy: "        SettingsPane {\n").count - 1, 3, "接続先・この Mac の接続先・一般")
        for tab in ["TargetsSettingsContent(rows: targets.rows", "HostSettingsContent(panel: store.panel", "GeneralSettings(version: version"] {
            XCTAssertTrue(s.contains("        SettingsPane {\n            " + tab), tab)
        }
        XCTAssertFalse(s.contains(".frame(maxHeight:"), "上限だけを付けた ScrollView に戻さない")
        // 上限は、入れ物が載っている窓のある画面から決める（その窓の知らせだけを見る。点検 2h）
        let c = try String(contentsOf: root.appendingPathComponent("Sources/ShareScaleUI/Components.swift"), encoding: .utf8)
        XCTAssertTrue(c.contains("observers.add(forName: NSWindow.didChangeScreenNotification, object: window)"), "その窓の知らせだけ")
        XCTAssertTrue(c.contains("let height = window?.screen.map { Double($0.visibleFrame.height) }"))
        XCTAssertTrue(c.contains("screen = SettingsLayout.adopt(height, at: ProcessInfo.processInfo.systemUptime, into: screen)"), "切り替えた直後は、小さくなる向きだけ採る")
        XCTAssertFalse(c.contains("NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)"), "どの窓の知らせでも取り直す形に戻さない")
        XCTAssertFalse(s.contains("        ScrollView {\n            HostSettingsContent"), "ScrollView をじかに置かない")
    }
}
