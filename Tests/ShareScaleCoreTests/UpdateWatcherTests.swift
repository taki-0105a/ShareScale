import XCTest
@testable import ShareScaleCore

/// 常駐している間に新しい版を見つける（点検 2f-2。一時フォルダの app-state.json と偽の Homebrew 側。開く・終了するは数えるだけ）
@MainActor
final class UpdateWatcherTests: TempDirTestCase {
    override func setUp() { super.setUp(); AppLanguage.current = .ja }
    let cellar = "/opt/homebrew/Cellar/sharescale/1.2.0/ShareScale.app"
    var stateFile: AppStateFile { AppStateFile(url: support.appendingPathComponent("app-state.json")) }
    func facts(_ v: Int, _ h: String) -> BundleFacts { BundleFacts(identifier: AppIdentifiers.app, version: v, cdhash: h) }

    final class Clock: @unchecked Sendable { var now = ContinuousClock.now }
    /// Homebrew 側の様子（押すまでの間に変えられる）
    final class Theirs: @unchecked Sendable {
        private let lock = NSLock()
        private var f: BundleFacts
        init(_ f: BundleFacts) { self.f = f }
        var facts: BundleFacts { get { lock.withLock { f } } set { lock.withLock { f = newValue } } }
    }

    func watcher(role: AppRole = .copy, theirs: Theirs, reads: Locked<Int> = Locked(0), clock: Clock = Clock(),
                 safety: HandoffSafety.Problem? = nil) -> UpdateWatcher {
        let cellar = cellar
        return UpdateWatcher(role: role, stateFile: stateFile, own: facts(10100, "aa"),
                             readSource: { _ in reads.update { $0 += 1 }; return .present(realPath: cellar, facts: theirs.facts) },
                             safety: { _ in safety }, clock: { clock.now })
    }

    func testFindsANewerVersionWithTheLaunchDecisionAndThrottles() async throws {
        try stateFile.save(AppState(source: "/opt/homebrew/opt/sharescale/ShareScale.app"))
        let reads = Locked(0), clock = Clock()
        let w = watcher(theirs: Theirs(facts(10200, "bb")), reads: reads, clock: clock)
        await w.check()
        XCTAssertEqual(w.pending, UpdateWatcher.Pending(attempt: AppState.Attempt(build: 10200, cdhash: "bb"), realPath: cellar))
        XCTAssertEqual(w.notice?.title, "新しいバージョンがあります"); XCTAssertEqual(UpdateWatcher.actionTitle, "ShareScale を終了して開き直す…")
        await w.check()
        XCTAssertEqual(reads.value, 1, "10 分に 1 回に間引く")
        clock.now = clock.now + .seconds(601)
        await w.check()
        XCTAssertEqual(reads.value, 2)
        await w.check(force: true)
        XCTAssertEqual(reads.value, 3)
        // 同じ・古い版なら出さない。開発の組み立てでは確かめない
        let same = watcher(theirs: Theirs(facts(10100, "aa")))
        await same.check()
        XCTAssertNil(same.pending); XCTAssertNil(same.notice)
        let devReads = Locked(0)
        let dev = watcher(role: .development, theirs: Theirs(facts(10200, "bb")), reads: devReads)
        await dev.check()
        XCTAssertNil(dev.pending); XCTAssertEqual(devReads.value, 0)
    }

    // 引き渡しの条件（Homebrew 側のバンドルの持ち主・権限）を満たさなければ、知らせも開きもしない（再点検 2f-2）。
    // 一時の写しで `decide` の条件を `{ _ in nil }` に壊すと、この試験が落ちることを確かめた
    func testUnsafeHomebrewBundleIsNotOffered() async throws {
        try stateFile.save(AppState(source: "/opt/homebrew/opt/sharescale/ShareScale.app"))
        let w = watcher(theirs: Theirs(facts(10200, "bb")), safety: .writableByOthers("/opt/homebrew/Cellar/sharescale"))
        await w.check()
        XCTAssertNil(w.pending); XCTAssertNil(w.notice)
        var opened = 0
        let ok = await w.handoff(open: { _ in opened += 1; return true }, terminate: {})
        XCTAssertFalse(ok); XCTAssertEqual(opened, 0)
        XCTAssertNil(stateFile.load().state.attemptedHandoff, "試みも記録しない")
    }

    func testHandoffRecordsTheAttemptOpensHomebrewAndQuits() async throws {
        try stateFile.save(AppState(source: "/opt/homebrew/opt/sharescale/ShareScale.app"))
        let w = watcher(theirs: Theirs(facts(10200, "bb")))
        await w.check()
        var opened: [String] = [], quits = 0
        let ok = await w.handoff(open: { opened.append($0.path); return true }, terminate: { quits += 1 })
        XCTAssertTrue(ok)
        XCTAssertEqual(opened, [cellar], "複製ではなく Homebrew 側（確かめた実体）を開く")
        XCTAssertEqual(quits, 1)
        XCTAssertEqual(stateFile.load().state.attemptedHandoff, AppState.Attempt(build: 10200, cdhash: "bb"), "起動時と同じく、開く前に試みを記録する")
        // 記録した後は、同じ版を知らせない（起動時と同じく 1 回だけ）
        await w.check(force: true)
        XCTAssertNil(w.pending)
        // 開けなければ終了せず、主の窓に 1 行
        try stateFile.save(AppState(source: "/opt/homebrew/opt/sharescale/ShareScale.app"))
        let w2 = watcher(theirs: Theirs(facts(10300, "cc")))
        await w2.check()
        let notOpened = await w2.handoff(open: { _ in false }, terminate: { quits += 1 })
        XCTAssertFalse(notOpened); XCTAssertEqual(quits, 1)
        XCTAssertTrue(w2.failed); XCTAssertEqual(w2.notice?.title, "新しいバージョンに切り替えられませんでした")
    }

    // 押した時に確かめ直す: 見つけてから押すまでの間に Homebrew 側が変わった（アップデートの途中など）時は開かない（再点検 2f-2）
    func testHandoffChecksAgainWhenPressed() async throws {
        try stateFile.save(AppState(source: "/opt/homebrew/opt/sharescale/ShareScale.app"))
        let theirs = Theirs(facts(10200, "bb"))
        let w = watcher(theirs: theirs)
        await w.check()
        theirs.facts = facts(10200, "cc")   // 押すまでの間に Homebrew 側の中身が替わった
        var opened = 0
        let ok = await w.handoff(open: { _ in opened += 1; return true }, terminate: {})
        XCTAssertFalse(ok); XCTAssertEqual(opened, 0, "見つけた時と違う版・実体は開かない")
        XCTAssertNil(stateFile.load().state.attemptedHandoff, "記録もしない")
        XCTAssertTrue(w.failed)
        XCTAssertEqual(w.notice?.detail, "Homebrew でのアップデートが終わってから、もう一度選択してください。")
        XCTAssertEqual(w.pending?.attempt, AppState.Attempt(build: 10200, cdhash: "cc"), "確かめ直した結果を次の候補にする")
        let second = await w.handoff(open: { _ in opened += 1; return true }, terminate: {})
        XCTAssertTrue(second); XCTAssertEqual(opened, 1, "もう一度押せば、確かめ直した版を開く")
    }
}
