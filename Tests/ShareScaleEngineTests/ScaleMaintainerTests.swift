import XCTest
@testable import ShareScaleEngine

/// 倍率の維持の筋書き（偽のディスプレイ・差し替えた時計。判定は `evaluate` を直接呼ぶ。
/// `requestMode` などが予定する判定は、まとめる待ち時間を長くして試験の間は動かさない）
final class ScaleMaintainerTests: TempDirTestCase {
    let clock = TestClock()
    let lines = Lines()

    func make(_ fake: FakeDisplays, boot: Int? = 1, edit: (inout ScaleMaintainer.Settings) -> Void = { _ in }) -> ScaleMaintainer {
        var s = ScaleMaintainer.Settings(); s.coalesceDelay = 3600; edit(&s)
        let clock = clock, lines = lines
        return ScaleMaintainer(provider: fake, file: stateFile, settings: s, now: { clock.now }, bootTime: boot, log: { lines.append($0) })
    }

    func testAppliesSavedModeToVirtualDisplay() {
        let fake = FakeDisplays([virtual(factor: 2), physical()])
        let m = make(fake)
        m.evaluate(reason: "startup")
        XCTAssertEqual(fake.applies, ["\(VIRT)@1"], "保存が無ければ 1x")
        XCTAssertEqual(m.snapshot.target?.scale, 1)
        XCTAssertEqual(m.snapshot.target?.source, .signature)
        XCTAssertTrue(m.snapshot.session)
        XCTAssertTrue(lines.text.contains("startup: applied 1x"), lines.text)
    }
    func testNoChangeIsLoggedOnce() {
        let fake = FakeDisplays([virtual(factor: 1)])
        let m = make(fake)
        for _ in 0..<3 { m.evaluate(reason: "check") }
        XCTAssertEqual(fake.applies, [])
        XCTAssertEqual(lines.count("ok (signature 1920x997@1x, mode 1x)"), 1, lines.text)
        XCTAssertEqual(m.snapshot.evaluations, 3)
    }
    func testAmbiguousDoesNothing() {
        let fake = FakeDisplays([virtual(), virtual(VIRT2)])
        let m = make(fake)
        m.evaluate(reason: "check")
        XCTAssertEqual(fake.applies, []); XCTAssertTrue(m.snapshot.ambiguous); XCTAssertNil(m.snapshot.target)
    }
    // 同じ構成が 10 秒続いた時だけ学習し、engine.json に残す
    func testLearnsOnlyAfterStableInterval() {
        let fake = FakeDisplays([physical()], port: false)
        let m = make(fake)
        m.evaluate(reason: "check"); clock.advance(5); m.evaluate(reason: "check")
        XCTAssertEqual(stateFile.load().state.learned, [], "10 秒たつまでは覚えない")
        clock.advance(5); m.evaluate(reason: "check")
        XCTAssertEqual(stateFile.load().state.learned, [PHYS])
        XCTAssertTrue(lines.text.contains("learned physical: \(PHYS) (known 1)"), lines.text)
    }
    // 再起動をまたいだ候補では学習しない（起動時刻が違えば数え直す）
    func testCandidateFromPreviousBootRestarts() {
        let fake = FakeDisplays([physical()], port: false)
        make(fake, boot: 1000).evaluate(reason: "check")
        clock.advance(20)
        let m = make(fake, boot: 2000)
        m.evaluate(reason: "check")
        XCTAssertEqual(stateFile.load().state.learned, [], "前の起動の候補では覚えない")
        clock.advance(10); m.evaluate(reason: "check")
        XCTAssertEqual(stateFile.load().state.learned, [PHYS])
    }
    // 以前に物理として覚えた ID が、画面共有の仮想ディスプレイの識別情報で見えたら学習済みから外す
    func testLearnedIDSeenAsVirtualIsForgotten() throws {
        var s = EngineState(); s.learned = [PHYS, VIRT]; try stateFile.save(s)
        let m = make(FakeDisplays([virtual(factor: 1), physical()]))
        m.evaluate(reason: "check")
        XCTAssertEqual(stateFile.load().state.learned, [PHYS])
        XCTAssertTrue(lines.text.contains("forgot learned (seen as screen sharing): \(VIRT)"), lines.text)
    }
    // 失敗が続く間は待ち時間を伸ばし、利用者がもう一度指示すれば（同じ倍率でも）すぐに試し直す
    func testFailureBacksOffAndRetryRequestBypasses() {
        let fake = FakeDisplays([virtual(factor: 2)])
        fake.applyFailure = "apply failed (CGError 1014)"
        let m = make(fake)
        m.evaluate(reason: "check")
        XCTAssertEqual(m.snapshot.lastError, "apply failed (CGError 1014)")
        XCTAssertTrue(lines.text.contains("apply 1x FAILED after 0.00s: apply failed (CGError 1014) (next try in 30s)"), lines.text)
        clock.advance(1); m.evaluate(reason: "check")
        XCTAssertEqual(fake.applies.count, 1, "待ち時間の間は試さない")
        XCTAssertEqual(m.requestMode(.x1, by: "aa", at: 5), .accepted(1))
        m.evaluate(reason: "retry requested")
        XCTAssertEqual(fake.applies.count, 2, "指示があれば待ち時間を捨てて試す")
        XCTAssertTrue(lines.text.contains("retry requested: apply 1x FAILED"), lines.text)
        XCTAssertEqual(stateFile.load().state.lastError, "apply failed (CGError 1014)", "直近の失敗も保存する")
    }
    // 何かが倍率を戻し続けると、20 秒に 4 回で止め（「戻し続けている」）、60 秒に 3 回戻されたら奪い合いを立てる
    func testThrashIsLimitedAndReportedAsContention() {
        let fake = FakeDisplays([virtual(factor: 2)])
        fake.afterEachApply { list in list = list.map { var d = $0; d.pixelWidth = d.width * 2; d.pixelHeight = d.height * 2; return d } }
        let m = make(fake)
        for _ in 0..<5 { m.evaluate(reason: "display changed"); clock.advance(1) }
        XCTAssertEqual(fake.applies.count, 4, "20 秒に 4 回まで")
        XCTAssertEqual(m.snapshot.lastError, "paused: switched too often (something keeps changing the scale back)")
        XCTAssertTrue(m.snapshot.contention)
        XCTAssertEqual(lines.count("the scale keeps being changed back"), 1, lines.text)
    }
    // 利用者がもう一度押して上限に当たった時は、「戻し続けている」とは言わない
    func testRetryLimitHasAccurateMessage() {
        let fake = FakeDisplays([virtual(factor: 2)])
        fake.applyFailure = "boom"
        let m = make(fake)
        for i in 1...5 {
            XCTAssertEqual(m.requestMode(.x1, by: "aa", at: Int64(i)), .accepted(i))
            m.evaluate(reason: "retry requested"); clock.advance(1)
        }
        XCTAssertEqual(fake.applies.count, 4)
        XCTAssertEqual(m.snapshot.lastError, "too many attempts; try again in a few seconds")
        XCTAssertFalse(m.snapshot.contention, "失敗は戻されたのではない")
    }
    func testContentionLowersWhenNoLongerChangedBack() {
        let fake = FakeDisplays([virtual(factor: 2)])
        fake.afterEachApply { list in list = list.map { var d = $0; d.pixelWidth = d.width * 2; return d } }
        let m = make(fake)
        for _ in 0..<3 { m.evaluate(reason: "display changed"); clock.advance(1) }
        m.evaluate(reason: "display changed")
        XCTAssertTrue(m.snapshot.contention)
        fake.afterEachApply { _ in }            // 戻されなくなった
        clock.advance(21); m.evaluate(reason: "check")
        clock.advance(61); m.evaluate(reason: "check")
        XCTAssertFalse(m.snapshot.contention)
        XCTAssertEqual(lines.count("the scale is no longer being changed back"), 1, lines.text)
    }
    func testResizingWindowIsNotContention() {
        let fake = FakeDisplays([virtual(factor: 2)])
        let counter = TestClock(0)
        fake.afterEachApply { list in                // 窓の大きさが変わり、新しい大きさでは 2x に戻る
            counter.advance(1)
            let w = 1900 + Int(counter.now)
            list = list.map { var d = $0; d.width = w; d.pixelWidth = w * 2; d.pixelHeight = d.height * 2; return d }
        }
        let m = make(fake, edit: { $0.maxApplies = 100 })
        for _ in 0..<5 { m.evaluate(reason: "display changed"); clock.advance(1) }
        XCTAssertEqual(fake.applies.count, 5)
        XCTAssertFalse(m.snapshot.contention)
    }
    // 画面共有が終わって仮想ディスプレイも無ければ、前の失敗の記録は消す
    func testLastErrorClearedWhenSessionEnds() throws {
        var s = EngineState(); s.mode = .x2; s.lastError = "apply timed out after 8s"; try stateFile.save(s)
        let m = make(FakeDisplays([physical()], port: false))
        XCTAssertEqual(m.snapshot.lastError, "apply timed out after 8s")
        m.evaluate(reason: "check")
        XCTAssertNil(m.snapshot.lastError); XCTAssertNil(stateFile.load().state.lastError)
    }
    // 一時停止と外からの理由（入れ替えの途中）の間は倍率を変えない。解けば直す
    func testPausedAndHoldsDoNotApply() {
        let fake = FakeDisplays([virtual(factor: 2)])
        let m = make(fake)
        m.setPaused(true)
        m.evaluate(reason: "check"); m.evaluate(reason: "check")
        XCTAssertEqual(fake.applies, [])
        XCTAssertEqual(lines.count("not changing the scale (paused)"), 1, lines.text)
        XCTAssertTrue(stateFile.load().state.paused, "一時停止は保存する")
        m.setPaused(false); m.setHold(.updating, true)
        m.evaluate(reason: "check")
        XCTAssertEqual(fake.applies, [])
        XCTAssertEqual(m.snapshot.holds, [.updating])
        XCTAssertTrue(lines.text.contains("not changing the scale (updating)"), lines.text)
        XCTAssertEqual(ExternalHold.allCases, [.updating], "外からの理由は、入れ替えの途中だけ（計画 2i）")
        m.setHold(.updating, false)
        m.evaluate(reason: "check")
        XCTAssertEqual(fake.applies, ["\(VIRT)@1"])
    }
    // 前の指示が判定されるまでは次の指示を断る（busy）。判定されれば受け付ける
    func testRequestModeIsBusyUntilEvaluated() {
        let m = make(FakeDisplays([virtual(factor: 1)]))
        XCTAssertEqual(m.requestMode(.x2, by: "aa", at: 1), .accepted(1))
        XCTAssertEqual(m.requestMode(.x1, by: "bb", at: 2), .busy)
        m.evaluate(reason: "mode changed to 2x")
        XCTAssertEqual(m.snapshot.coveredRequest, 1)
        XCTAssertEqual(m.snapshot.target?.scale, 2)
        XCTAssertEqual(m.requestMode(.x1, by: "bb", at: 2), .accepted(2))
    }
    // 指示は予定した判定で反映され、waitUntilCovered はそれを待つ（まとめる待ち時間は短くする）
    func testRequestModeSchedulesEvaluationAndWaits() async {
        let fake = FakeDisplays([virtual(factor: 1)])
        let m = make(fake, edit: { $0.coalesceDelay = 0.05 })
        guard case let .accepted(seq) = m.requestMode(.x2, by: "aa", at: 7) else { return XCTFail() }
        let s = await m.waitUntilCovered(seq, timeout: 3)
        XCTAssertEqual(s.target?.scale, 2)
        XCTAssertEqual(s.setBy, EngineState.SetRecord(by: "aa", at: 7))
        XCTAssertTrue(lines.text.contains("mode changed to 2x: applied 2x"), lines.text)
    }
    // 待っているタスクが取り消されたら、待ちは即座に終わる（空回りしない）
    func testWaitUntilCoveredReturnsAtOnceWhenCancelled() async {
        let m = make(FakeDisplays([virtual(factor: 1)]))   // 判定は予定しない（coalesceDelay 3600）
        guard case let .accepted(seq) = m.requestMode(.x2, by: "aa", at: 1) else { return XCTFail() }
        let t0 = ContinuousClock.now
        let task = Task { await m.waitUntilCovered(seq, timeout: 10) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let s = await task.value
        XCTAssertLessThan(ContinuousClock.now - t0, .seconds(4), "取り消しで戻る（上限の 10 秒を待たない）")
        XCTAssertEqual(s.coveredRequest, 0, "判定はまだ")
    }
    // 取り消さなければ上限まで待つ
    func testWaitUntilCoveredWaitsForTheTimeout() async {
        let m = make(FakeDisplays([virtual(factor: 1)]))
        guard case let .accepted(seq) = m.requestMode(.x2, by: "aa", at: 1) else { return XCTFail() }
        let t0 = ContinuousClock.now
        let s = await m.waitUntilCovered(seq, timeout: 0.3)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - t0, .milliseconds(300))
        XCTAssertEqual(s.coveredRequest, 0)
    }
    func testModeAndSetByPersistAcrossInstances() {
        let m = make(FakeDisplays([]))
        _ = m.requestMode(.off, by: "cc", at: 42)
        let again = make(FakeDisplays([]))
        XCTAssertEqual(again.snapshot.mode, .off)
        XCTAssertEqual(again.snapshot.setBy, EngineState.SetRecord(by: "cc", at: 42))
    }
    func testBrokenStateFileIsReportedAndDefaultsUsed() throws {
        try "garbage".write(to: stateFile.url, atomically: true, encoding: .utf8)
        let m = make(FakeDisplays([]))
        XCTAssertEqual(m.snapshot.mode, .x1)
        XCTAssertNotNil(m.snapshot.stateProblem)
        XCTAssertTrue(lines.text.contains("engine.json"), lines.text)
    }
    func testUnsavableStateIsReportedButModeIsKept() throws {
        let m = ScaleMaintainer(provider: FakeDisplays([]), file: EngineStateFile(url: dir.appendingPathComponent("missing/dir/engine.json")),
                                log: { _ in })
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("missing"), withIntermediateDirectories: true)
        chmod(dir.appendingPathComponent("missing").path, 0o500)
        defer { chmod(dir.appendingPathComponent("missing").path, 0o700) }
        XCTAssertEqual(m.requestMode(.x2, by: "aa", at: 1), .accepted(1))
        XCTAssertEqual(m.snapshot.mode, .x2, "この起動の間は指示どおりに動く")
        // 理由は `ErrorText.readable` の形（読める文の後ろに、種類と番号を括弧で。再点検 2h）。読める文は macOS の言語で変わるので、
        // 前の決まった部分と、末尾の種類と番号だけを見る
        let problem = try XCTUnwrap(m.snapshot.stateProblem)
        XCTAssertNotNil(problem.range(of: #"^engine\.json: could not save \(.+ \([A-Za-z.]+ -?\d+(, [A-Za-z.]+ -?\d+)?\)\)$"#, options: .regularExpression), problem)
        XCTAssertFalse(problem.contains("\n"), "1 行")
        XCTAssertFalse(problem.contains(dir.path), "置き場所のパスは入れない: \(problem)")
    }
    // 子プロセスで一覧を読めない時の記録は、同じ理由が続く間は 1 回だけ
    func testFallbackReasonIsLoggedOnce() {
        let fake = FakeDisplays([virtual(factor: 1)])
        fake.fallbackReason = "probe timed out after 3s"
        let m = make(fake)
        for _ in 0..<3 { m.evaluate(reason: "check") }
        XCTAssertEqual(lines.count("fresh display list unavailable (probe timed out after 3s)"), 1, lines.text)
    }
    // start で起動時の判定と見回りが動き、stop で止まる
    func testStartRunsStartupAndPeriodicChecks() async {
        let fake = FakeDisplays([virtual(factor: 1)])
        let m = make(fake, edit: { $0.coalesceDelay = 0.02; $0.checkInterval = 0.1 })
        m.start(); m.start()
        let end = ContinuousClock.now + .seconds(3)
        while m.snapshot.evaluations < 3, ContinuousClock.now < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertGreaterThanOrEqual(m.snapshot.evaluations, 3)
        XCTAssertTrue(lines.text.contains("startup: ok"), lines.text)
        m.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let after = m.snapshot.evaluations
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(m.snapshot.evaluations, after, "止めた後は見回らない")
    }
}
