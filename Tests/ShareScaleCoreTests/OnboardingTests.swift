import XCTest
@testable import ShareScaleCore

/// 初回のガイド（計画 2f-2 案 3。純粋な状態機械と各段の文言。記憶の中の環境設定）
@MainActor
final class OnboardingTests: XCTestCase {
    override func setUp() { super.setUp(); AppLanguage.current = .ja }
    let code = (title: "接続元の Mac を追加…", enabled: true)

    func testShowsOnlyOnFirstLaunchWithNothingSetUp() {
        XCTAssertTrue(OnboardingFlow.shouldShow(hasTargets: false, hostRoleOn: false, seen: false))
        XCTAssertFalse(OnboardingFlow.shouldShow(hasTargets: true, hostRoleOn: false, seen: false), "接続先がある")
        XCTAssertFalse(OnboardingFlow.shouldShow(hasTargets: false, hostRoleOn: true, seen: false), "この Mac を接続先にしている")
        XCTAssertFalse(OnboardingFlow.shouldShow(hasTargets: false, hostRoleOn: false, seen: true), "ガイドを見た")
    }

    func testThreePaths() {
        // (a) 接続先を追加する段だけ
        var a = OnboardingFlow()
        XCTAssertEqual(a.next(hostRunning: true), .blocked, "1 画面目は選ぶまで進めない")
        a.choose(.connectFrom)
        XCTAssertEqual(a.step, .addTarget); XCTAssertEqual(a.progress?.index, 1); XCTAssertEqual(a.progress?.count, 1)
        XCTAssertEqual(a.next(hostRunning: false), .finished)
        // (b) この Mac を接続先にする → Host が動いたら 接続元の Mac を追加する → 完了
        var b = OnboardingFlow()
        b.choose(.beTarget)
        XCTAssertEqual(b.step, .hostSwitch)
        XCTAssertEqual(b.next(hostRunning: false), .blocked, "Host が動くまで進めない")
        XCTAssertEqual(b.next(hostRunning: true), .moved); XCTAssertEqual(b.step, .hostCode)
        XCTAssertEqual(b.progress?.index, 2); XCTAssertEqual(b.progress?.count, 2)
        XCTAssertEqual(b.next(hostRunning: true), .finished)
        // (c) (b) の後に (a)
        var c = OnboardingFlow()
        c.choose(.both)
        XCTAssertEqual(c.next(hostRunning: true), .moved); XCTAssertEqual(c.next(hostRunning: true), .moved)
        XCTAssertEqual(c.step, .addTarget); XCTAssertEqual(c.progress?.index, 3); XCTAssertEqual(c.progress?.count, 3)
        // 戻る
        c.back(); XCTAssertEqual(c.step, .hostCode)
        c.back(); XCTAssertEqual(c.step, .hostSwitch)
        c.back(); XCTAssertEqual(c.step, .choose); XCTAssertNil(c.goal); XCTAssertNil(c.progress)
        a = OnboardingFlow(); a.choose(.connectFrom); a.back()
        XCTAssertEqual(a.step, .choose)
        a.choose(.beTarget)
        XCTAssertEqual(a.step, .hostSwitch, "戻った後に選び直せる")
    }

    func testPages() {
        var f = OnboardingFlow()
        let first = OnboardingPage.make(f, hostRunning: false, canAddTarget: true, issueCode: code)
        XCTAssertEqual(first.title, "ShareScale でしたいこと")
        XCTAssertEqual(first.options.map(\.title), ["この Mac から、画面共有で別の Mac を操作する", "この Mac を、別の Mac から画面共有で操作される側にする", "両方"])
        XCTAssertEqual(first.options.map(\.arrow), ["arrow.right", "arrow.left", "arrow.left.arrow.right"])
        XCTAssertNil(first.back); XCTAssertEqual(first.later, "あとで"); XCTAssertNil(first.primary)
        f.choose(.both)
        let sw = OnboardingPage.make(f, hostRunning: false, canAddTarget: true, issueCode: code)
        XCTAssertTrue(sw.showsHostSwitch); XCTAssertEqual(sw.primary, OnboardingPage.PageButton(title: "次へ", enabled: false)); XCTAssertNil(sw.hostStatus)
        XCTAssertEqual(sw.progress, "1 / 3")
        let running = OnboardingPage.make(f, hostRunning: true, canAddTarget: true, issueCode: code)
        XCTAssertEqual(running.primary?.enabled, true); XCTAssertEqual(running.hostStatus, "ShareScale Host が動いています。")
        _ = f.next(hostRunning: true)
        let codePage = OnboardingPage.make(f, hostRunning: true, canAddTarget: true, issueCode: code)
        XCTAssertEqual(codePage.action, OnboardingPage.PageButton(title: "接続元の Mac を追加…", enabled: true))
        XCTAssertEqual(codePage.primary?.title, "次へ", "(c) は次に接続先を追加する")
        guard hasCount(codePage.steps, 3) else { return }
        XCTAssertEqual(codePage.steps[1], "接続元の Mac で ShareScale を開き、「接続先を追加…」にそのコードを貼り付けます。", "手順の文末を揃える（点検 2f-2）")
        XCTAssertEqual(OnboardingPage.make(f, hostRunning: false, canAddTarget: true, issueCode: code).action?.enabled, false, "Host が止まったら押せない")
        _ = f.next(hostRunning: true)
        XCTAssertTrue(sw.lead?.contains("macOS の画面共有をオンにしておきます") == true, "(b) は macOS の画面共有を先に言う（点検 2f-2）")
        var a = OnboardingFlow(); a.choose(.connectFrom)
        XCTAssertNil(OnboardingPage.make(a, hostRunning: false, canAddTarget: true, issueCode: code).progress, "段が 1 つなら「1 / 1」を出さない")
        let add = OnboardingPage.make(f, hostRunning: true, canAddTarget: false, issueCode: code)
        XCTAssertEqual(add.primary, OnboardingPage.PageButton(title: "接続先を追加…", enabled: false), "帳簿が使えない・上限なら押せない")
        var b = OnboardingFlow(); b.choose(.beTarget); _ = b.next(hostRunning: true)
        XCTAssertEqual(OnboardingPage.make(b, hostRunning: true, canAddTarget: true, issueCode: code).primary?.title, "完了")
        AppLanguage.current = .en
        XCTAssertEqual(OnboardingPage.make(OnboardingFlow(), hostRunning: false, canAddTarget: true, issueCode: code).title, "What do you want to do with ShareScale?")
    }

    func testGuideMarksSeenWhenClosedAndReopensFromSettings() {
        let store = MemoryStore()
        let g = OnboardingGuide(store: store)
        g.showIfNeeded(hasTargets: false, hostRoleOn: false)
        XCTAssertEqual(g.flow?.step, .choose)
        g.choose(.connectFrom)
        XCTAssertEqual(g.next(hostRunning: false), .finished)
        XCTAssertNil(g.flow); XCTAssertTrue(g.seen)
        g.showIfNeeded(hasTargets: false, hostRoleOn: false)
        XCTAssertNil(g.flow, "見た後は起動しても出さない")
        g.open()
        XCTAssertEqual(g.flow?.step, .choose, "設定の「はじめに…」からは出せる")
        g.close()
        XCTAssertNil(g.flow)
        let other = OnboardingGuide(store: MemoryStore())
        other.showIfNeeded(hasTargets: true, hostRoleOn: false)
        XCTAssertNil(other.flow)
        other.showIfNeeded(hasTargets: false, hostRoleOn: false)
        other.close()   // 「あとで」
        XCTAssertTrue(other.seen, "「あとで」でも印を付ける（次の起動からは出さない）")
    }
}
