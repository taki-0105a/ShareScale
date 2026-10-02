import XCTest
@testable import ShareScaleCore
import ShareScaleHostCore
import ShareScaleProtocol

/// ShareScale.app のメニューバーの項目（計画 2f-2 案 1・2。純粋な値。偽の接続先）
@MainActor
final class ViewerMenuTests: TempDirTestCase {
    override func setUp() { super.setUp(); AppLanguage.current = .ja }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 文字の一覧（書き出しと同じ形）
    func lines(_ items: [ViewerMenuItem]) -> [String] {
        items.flatMap { i -> [String] in
            switch i {
            case let .target(name, symbol): return ["[\(symbol)] \(name)"]
            case let .status(symbol, text): return ["(\(symbol)) \(text)"]
            case let .note(t): return [t]
            case let .addTarget(t, on): return [(on ? "" : "(off) ") + t]
            case let .display(_, title, choices):
                return ["# " + title] + choices.map { ($0.checked ? "✓ " : "  ") + ($0.enabled ? "" : "(off) ") + $0.title }
            case let .refresh(t, on): return [(on ? "" : "(off) ") + t]
            case let .switchTarget(t, choices): return [t + " › " + choices.map { ($0.checked ? "✓" : "") + $0.title }.joined(separator: " / ")]
            case let .openMain(t), let .settings(t), let .quit(t): return [t]
            case let .host(title, entries, settings):
                return ["# " + title] + entries.map { e -> String in
                    switch e {
                    case let .status(s), let .notice(s), let .diagnostics(s), let .openLog(s), let .quit(s): return s
                    case let .addViewer(t, on): return (on ? "" : "(off) ") + t
                    case let .showCode(t), let .pause(t, _), let .reviewViewers(t): return t
                    case let .viewer(_, t, _, _, _, _): return t
                    case .separator: return "—"
                    }
                } + [settings]
            case let .update(note, action): return [note, action]
            case .separator: return ["—"]
            }
        }
    }

    func testNoTargetOffersAddTarget() {
        let m = ViewerModel(client: nil, displays: { [lg] })
        XCTAssertEqual(lines(ViewerMenu.items(model: m, targets: [], canAddTarget: true, host: nil, now: now)),
                       ["接続先がまだありません", "接続先を追加…", "—", "ShareScale を開く", "設定…", "—", "ShareScale を終了"])
        XCTAssertEqual(lines(ViewerMenu.items(model: m, targets: [], canAddTarget: false, host: nil, now: now)).dropFirst().first, "(off) 接続先を追加…")
        // 新しい版がある時は、いちばん上に知らせと切り替えの項目（点検 2f-2）
        XCTAssertEqual(Array(lines(ViewerMenu.items(model: m, targets: [], canAddTarget: true, host: nil, updateAvailable: true, now: now)).prefix(4)),
                       ["新しいバージョンがあります", "ShareScale を終了して開き直す…", "—", "接続先がまだありません"])
    }

    func testDisplaysWithTheirChoicesAndStatus() async {
        let target = FakeTarget(.success(connected(mode: .x2, scaling: .x2)))
        let prefs = DisplayPreferences(store: MemoryStore())
        let m = ViewerModel(client: target, displays: { [lg, builtIn] }, targetLabel: "Studio", preferences: prefs)
        await m.refresh()
        await m.choose(.x2, for: lg)
        XCTAssertEqual(lines(ViewerMenu.items(model: m, targets: [], canAddTarget: true, host: nil, now: now)),
                       ["[macstudio] Studio", "(checkmark.circle) 画面共有で接続中", "—",
                        "# LG ULTRAWIDE", "  1x 等倍", "✓ 2x Retina",
                        "# 内蔵Retinaディスプレイ", "  1x 等倍", "✓ 2x Retina",
                        "更新", "—", "ShareScale を開く", "設定…", "—", "ShareScale を終了"])
        // 画面共有が未接続・一時停止・接続できない
        target.statusResult = .success(RemoteState(payload(session: false, vd: nil)))
        await m.refresh(force: true)
        XCTAssertEqual(ViewerMenu.status(m), .status(symbol: "info.circle", text: "画面共有は未接続"))
        target.statusResult = .success(RemoteState(payload(paused: true)))
        await m.refresh(force: true)
        XCTAssertEqual(ViewerMenu.status(m), .status(symbol: "pause.circle", text: "一時停止中（表示倍率を変更しません）"))
        // 一時停止の間に倍率を選んで断られても「接続できません」にしない（計画 2i。実機確認 B）。処理中で断られた時は、直前の状態のまま
        target.statusResult = .success(connected(mode: .x2, scaling: .x2))
        await m.refresh(force: true)
        target.setResult = .failure(.paused)
        await m.choose(.x1, for: lg)
        XCTAssertEqual(m.failure, .paused)
        XCTAssertEqual(ViewerMenu.status(m), .status(symbol: "pause.circle", text: "一時停止中（表示倍率を変更しません）"))
        XCTAssertEqual(lines(ViewerMenu.items(model: m, targets: [], canAddTarget: true, host: nil, now: now)).prefix(2).map { $0 },
                       ["[macstudio] Studio", "(pause.circle) 一時停止中（表示倍率を変更しません）"], "名前と機種の記号もそのまま")
        await m.refresh(force: true)
        target.setResult = .failure(.busy)
        await m.choose(.x2, for: lg)
        XCTAssertEqual(m.failure, .busy)
        XCTAssertEqual(ViewerMenu.status(m), .status(symbol: "checkmark.circle", text: "画面共有で接続中"))
        // 状態をまだ知らない時（最初の問い合わせが通る前に断られた）も、Host が「一時停止中」と答えたことは分かる
        let unknown = FakeTarget(.failure(.unreachable))
        unknown.setResult = .failure(.paused)
        let fresh = ViewerModel(client: unknown, displays: { [lg] }, targetLabel: "Studio")
        await fresh.apply(.x1)
        XCTAssertNil(fresh.state)
        XCTAssertEqual(ViewerMenu.status(fresh), .status(symbol: "pause.circle", text: "一時停止中（表示倍率を変更しません）"))
        // 状態を知らないまま、続けて「処理中」で断られても、「一時停止中」を覚えている（再点検 2i。前は「画面共有は未接続」に変わった）
        unknown.setResult = .failure(.busy)
        await fresh.apply(.x1)
        XCTAssertEqual(fresh.failure, .busy); XCTAssertNil(fresh.state); XCTAssertTrue(fresh.hostPaused)
        XCTAssertEqual(ViewerMenu.status(fresh), .status(symbol: "pause.circle", text: "一時停止中（表示倍率を変更しません）"))
        // 接続できなくなったら忘れる。取り直せて一時停止でなければ、忘れる
        unknown.setResult = nil
        await fresh.refresh(force: true)
        XCTAssertEqual(ViewerMenu.status(fresh), .status(symbol: "exclamationmark.triangle", text: "接続できません")); XCTAssertFalse(fresh.hostPaused)
        unknown.setResult = .failure(.busy)
        await fresh.apply(.x1)
        XCTAssertFalse(fresh.hostPaused, "接続できなくなった後の「処理中」では、一時停止とは言わない")
        unknown.setResult = .failure(.paused)
        await fresh.apply(.x1)
        XCTAssertTrue(fresh.hostPaused)
        unknown.setResult = nil; unknown.statusResult = .success(connected())
        await fresh.refresh(force: true)
        XCTAssertFalse(fresh.hostPaused); XCTAssertEqual(ViewerMenu.status(fresh), .status(symbol: "checkmark.circle", text: "画面共有で接続中"))
        // 接続先を切り替えたら、前の接続先の「一時停止中」を持ち越さない
        unknown.setResult = .failure(.paused)
        await fresh.apply(.x1)
        XCTAssertTrue(fresh.hostPaused)
        fresh.updateClient(FakeTarget(.failure(.busy)), targetLabel: "Air")
        XCTAssertFalse(fresh.hostPaused)
        await fresh.refresh()
        XCTAssertFalse(fresh.hostPaused, "新しい接続先に「処理中」で断られただけ")
        target.setResult = nil
        target.statusResult = .failure(.unreachable)
        await m.refresh(force: true)
        XCTAssertEqual(ViewerMenu.status(m), .status(symbol: "exclamationmark.triangle", text: "接続できません"))
        AppLanguage.current = .en
        XCTAssertEqual(lines(ViewerMenu.items(model: m, targets: [], canAddTarget: true, host: nil, now: now)).prefix(5).map { $0 },
                       ["[desktopcomputer] Studio", "(exclamationmark.triangle) Can’t connect", "—", "# LG ULTRAWIDE", "  1x Standard"])
    }

    // 取り直しの間も倍率は押せる（処理中なら終わった後に送る。開いた直後の取り直しで灰色にしない。点検 2f-2）。「更新」だけ押せない
    func testBusyKeepsTheChoicesButDisablesRefresh() async {
        let target = GatedTarget(.success(connected()))
        let m = ViewerModel(client: target, displays: { [lg] }, targetLabel: "Studio")
        let t = Task { await m.refresh() }
        await waitFor(2) { target.pending == 1 }
        let busy = lines(ViewerMenu.items(model: m, targets: [], canAddTarget: true, host: nil, now: now))
        XCTAssertEqual(Array(busy.prefix(7)), ["[desktopcomputer] Studio", "(ellipsis.circle) 確認しています…", "—", "# LG ULTRAWIDE", "✓ 1x 等倍", "  2x Retina", "(off) 更新"])
        await m.choose(.x2, for: lg)   // 処理中に選んだ倍率は、終わった後に送る
        XCTAssertEqual(target.setCalls, [])
        target.release()                               // 取り直しが終わると、同じ流れの中で選んだ倍率を送る（set も待たされる）
        await waitFor(2) { target.pending == 1 }
        XCTAssertEqual(target.setCalls, [.x2])
        target.release()
        await t.value
    }

    func testSwitchTargetsAndHostSection() async throws {
        let m = ViewerModel(client: FakeTarget(.success(connected())), displays: { [lg] }, targetLabel: "Studio")
        await m.refresh()
        var l = TargetBook.Loaded()
        l.entries = [TargetEntry(id: pid(1), secret: secret(1), meta: ViewerMeta(name: "Studio", port: 47651, addresses: ["studio.local"], manual: false, lastOKAddress: nil, confirmed: true)!),
                     TargetEntry(id: pid(2), secret: secret(2), meta: ViewerMeta(name: "Mini", port: 47651, addresses: ["mini.local"], manual: false, lastOKAddress: nil, confirmed: true)!)]
        let rows = TargetRow.rows(l, selectedID: pid(1))
        let host = HostMenuFacts(summary: summary(stateJSON(code: Int64(now.timeIntervalSince1970) + 421)))
        let items = lines(ViewerMenu.items(model: m, targets: rows, canAddTarget: true, host: .running(host, outdated: false), now: now))
        XCTAssertEqual(Array(items.suffix(16)),
                       ["更新", "接続先を切り替える › Mini / ✓Studio", "—", "ShareScale を開く", "設定…", "—",
                        "# この Mac の接続先", "ShareScale Host は動作中です", "ローカルネットワークと Tailscale からの接続を受け付けています（ポート 47651）",
                        "接続元の Mac を追加…", "接続コードを表示…（残り 7:01）", "一時停止", "診断…",
                        "この Mac の接続先の設定…", "—", "ShareScale を終了"])
        // 80 日の知らせは 1 行にまとめて設定へ導く。古い版の Host には新しい指示の項目を出さず、切り替え方を添える（点検 2f-2）
        let stale = HostMenuFacts(summary: summary(stateJSON(paused: true, pairings: [pairingJSON(pid(3), "Old", lastSeen: 1, stale: true)], code: Int64(now.timeIntervalSince1970) + 60)))
        let old = lines(ViewerMenu.items(model: m, targets: [], canAddTarget: true, host: .running(stale, outdated: true), now: now))
        XCTAssertEqual(Array(old.suffix(10)),
                       ["# この Mac の接続先", "ShareScale Host は一時停止中です", "ローカルネットワークと Tailscale からの接続を受け付けています（ポート 47651）",
                        "80 日間使われていない接続元の Mac があります…", "接続元の Mac を追加…", "再開",
                        "ShareScale Host が古いバージョンで動いています（ShareScale を終了して開き直すと切り替わります）",
                        "この Mac の接続先の設定…", "—", "ShareScale を終了"])
        // Host のプロセスはあるのに state.json を読めない
        let unreadable = lines(ViewerMenu.items(model: m, targets: [], canAddTarget: true, host: .unreadable, now: now))
        XCTAssertEqual(Array(unreadable.suffix(5)), ["# この Mac の接続先", "ShareScale Host の状態を読み取れません", "この Mac の接続先の設定…", "—", "ShareScale を終了"])
        AppLanguage.current = .en
        XCTAssertEqual(lines(ViewerMenu.items(model: m, targets: [], canAddTarget: true, host: .unreadable, now: now)).suffix(3).first,
                       "Settings for This Mac as a Target…")
    }

    // 起動・終了の途中は出し分け、読めない状態が 10 秒続いたら受け持ちを外す（読めるようになったら戻す。再点検 2f-2）
    func testStartingStoppingAndYieldingTheMenuBar() throws {
        let folder = HostControlFolder(directory: support.appendingPathComponent("host-control", isDirectory: true))
        final class Clock: @unchecked Sendable { var now = ContinuousClock.now }
        let clock = Clock()
        let store = HostPanelStore(client: HostControlClient(folder: folder, notify: {}), clock: { 1_800_000_000 }, rereadDelays: [],
                                   hostProcessRunning: { true }, monotonic: { clock.now },
                                   sleep: { _ in try? await Task.sleep(for: .seconds(600)) })   // 読み直しの予約は試験では動かさない
        XCTAssertEqual(store.menuSection, .starting)
        XCTAssertEqual(lines(ViewerMenu.items(model: ViewerModel(client: nil, displays: { [] }), targets: [], canAddTarget: true, host: .starting, now: now)).suffix(4).first,
                       "ShareScale Host を起動しています…")
        try folder.writeState(encoded: Data(stateJSON(running: false).utf8))
        store.reload()
        XCTAssertEqual(store.menuSection, .stopping, "running:false を書いた＝終了の途中")
        XCTAssertEqual(ViewerMenu.hostEntries(.stopping, now: now), [.status("ShareScale Host を終了しています…")])
        // 読めない（形が違う）が続く
        try Data("garbage".utf8).write(to: folder.directory.appendingPathComponent("state.json"))
        store.reload()
        XCTAssertEqual(store.menuSection, .unreadable); XCTAssertFalse(store.yieldsMenuBar)
        clock.now = clock.now + .seconds(9)
        store.reload()
        XCTAssertFalse(store.yieldsMenuBar, "10 秒まではまだ受け持つ")
        clock.now = clock.now + .seconds(1)
        store.reload()
        XCTAssertTrue(store.yieldsMenuBar, "10 秒続いたら Host にアイコンを戻させる")
        try folder.writeState(encoded: Data(stateJSON().utf8))
        store.reload()
        XCTAssertFalse(store.yieldsMenuBar, "読めるようになったら受け持ち直す")
        // 受け持ちの口: 常に表示するがオフの時だけ、譲る間は印を外す
        let claims = Locked<[Bool]>([])
        let a = AppearanceSettings(preferences: AppearancePreferences(store: MemoryStore()), applyDock: { _ in }, claim: { v in claims.update { $0.append(v) } })
        a.setYieldToHost(true); a.setYieldToHost(true); a.setYieldToHost(false)
        XCTAssertEqual(claims.value, [false, true])
        a.setHostIconAlwaysVisible(true); a.setYieldToHost(true); a.setYieldToHost(false)
        XCTAssertEqual(claims.value, [false, true, false, false, false], "常に表示する時は受け持たないまま")
    }

    // 節に出すもの: 動いている（アプリより古い版なら outdated）・プロセスはあるのに読めない・無し（点検 2f-2）
    func testStoreMenuSection() throws {
        let folder = HostControlFolder(directory: support.appendingPathComponent("host-control", isDirectory: true))
        let running = Locked(false)
        let store = HostPanelStore(client: HostControlClient(folder: folder, notify: {}), clock: { 1_800_000_000 }, rereadDelays: [], appBuild: 10200,
                                   hostProcessRunning: { running.value })
        XCTAssertNil(store.menuSection, "Host が無い")
        running.value = true
        store.reload()
        XCTAssertEqual(store.menuSection, .starting, "プロセスはあるのに state.json がまだ無い＝起動の途中（読み取れませんとは言わない。再点検 2f-2）")
        try folder.writeState(encoded: Data(stateJSON().utf8))   // build 10100
        store.reload()
        XCTAssertEqual(store.menuSection, .running(HostMenuFacts(summary: summary(stateJSON())), outdated: true))
        let same = HostPanelStore(client: HostControlClient(folder: folder, notify: {}), clock: { 1_800_000_000 }, rereadDelays: [], appBuild: 10100)
        XCTAssertEqual(same.menuSection, .running(HostMenuFacts(summary: summary(stateJSON())), outdated: false))
        // 読み直しは頼み手ごと（設定のタブとガイドの両方が開いている間は止めない）
        store.startPolling(every: 60, owner: "settings"); store.startPolling(every: 60, owner: "onboarding")
        store.stopPolling(owner: "settings")
        XCTAssertTrue(store.isPolling, "ガイドがまだ開いている")
        store.stopPolling(owner: "onboarding")
        XCTAssertFalse(store.isPolling)
    }

    // Host が動いている時だけ、Host のメニューの元の値を持つ（`state.json` を読む。一時フォルダ）
    func testStoreKeepsHostFactsOnlyWhileTheHostRuns() throws {
        let folder = HostControlFolder(directory: support.appendingPathComponent("host-control", isDirectory: true))
        let notified = Locked(0)
        let client = HostControlClient(folder: folder, notify: { notified.update { $0 += 1 } }, wallClock: { Date(timeIntervalSince1970: 1_800_000_000) })
        let store = HostPanelStore(client: client, clock: { 1_800_000_000 }, rereadDelays: [])
        XCTAssertNil(store.facts, "state.json が無い")
        try folder.writeState(encoded: Data(stateJSON(paused: true).utf8))
        store.reload()
        XCTAssertEqual(store.facts?.paused, true)
        // メニューからの操作は、結果の一言を「この Mac の接続先」のタブに残さない
        store.perform(.showDiagnostics, report: false)
        XCTAssertNil(store.actionMessage)
        store.perform(.showCode)
        XCTAssertEqual(store.actionMessage, "ShareScale Host に「接続コード」ウインドウの表示を指示しました。")
        XCTAssertEqual(Set(folder.readRequests(now: 1_800_000_000).requests.map(\.op)), [.showDiagnostics, .showCode])
        XCTAssertEqual(notified.value, 2)
        try folder.writeState(encoded: Data(stateJSON(running: false).utf8))
        store.reload()
        XCTAssertNil(store.facts, "止まったら出さない")
    }
}
