import XCTest
@testable import ShareScaleCore
import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// 端から端まで（仕様「テスト」の見る側）: ループバックの `HostRuntime` と偽の承認で、
/// ペアリング（`PairingFlow`）→ 確定 → `ViewerModel.refresh`（`status`）→ `apply`（`set`）→ 削除（`unpair`）を通す。
/// 候補は 3 件（応答の無い 2 件＋ループバック。3 件目はずらしの 600 ミリ秒後に始まる）で、選んだ 1 本にだけ送ることと `last_ok_addr` の更新を確かめる
@MainActor
final class EndToEndTests: HostViewerTestCase, @unchecked Sendable {
    override func setUp() { super.setUp(); AppLanguage.current = .ja }
    var fast: PairingFlow.Settings { var s = PairingFlow.Settings(); s.connector.readyTimeout = 2; s.connector.total = 5; s.confirmInterval = 0.5; return s }

    func testPairRefreshApplyAndRemoveThroughTheViewerModel() async throws {
        try await startHost()
        let settings = MemoryStore(); let b = book(settings)
        // 1. ペアリング（候補は 3 件: 応答の無い 2 件（127.0.0.2・127.0.0.3。macOS のループバックは 127.0.0.1 だけ）＋ループバック。
        //    2 件は readyTimeout まで応答が無いので、3 件目は 600 ミリ秒後に始まってつながる）
        let issued = await host.issueCode(); let code = try XCTUnwrap(issued)
        let entry = PairingFlow.Entry(id: code.id, secret: code.secret, port: Int(port), addresses: ["127.0.0.2", "127.0.0.3", "127.0.0.1"], expiresAt: code.expiresAt)
        let phases = Locked<[PairingFlow.Phase]>([])
        // 候補の試行全体の上限は 10 秒（応答の無い 2 件を待つ間に、負荷で 5 秒を使い切って揺れていた。計画 2f-1 の点検）
        var settings10 = fast; settings10.connector.total = 10
        let outcome = await PairingFlow.run(entry, book: b, computerName: { "MacBook" }, onPhase: { ph in phases.update { $0.append(ph) } }, settings: settings10)
        guard outcome == .success(.confirmed(code.id)) else {
            // 名乗りが確定しなければ、何が起きたかを出して抜ける（以下は確定を前提にしている）
            return XCTFail("\(outcome)\nphases: \(phases.value)\nHost の結末: \(host.outcomes)\nHost の記録:\n\(host.runtime.log.recentAll(50).joined(separator: "\n"))")
        }
        let shown = phases.value.compactMap { if case let .awaitingApproval(c) = $0 { return c }; return nil }
        XCTAssertEqual(shown.count, 1, "確認番号は選んだ 1 本の分だけ")
        XCTAssertEqual(shown.first, host.approver.asked.first?.confirmationCode)
        XCTAssertEqual(phases.value.prefix(2), [.connecting, .awaitingApproval(code: try XCTUnwrap(shown.first))])
        // 2. 帳簿: 確定済み・候補は status のもの。試験では Host の候補（studio.local）を解決しないので、手で直した候補（manual）に戻す
        let loaded = b.load()
        XCTAssertEqual(loaded.problems, [])
        var t = try XCTUnwrap(b.selected(in: loaded))
        XCTAssertEqual(t.id, code.id); XCTAssertTrue(t.meta.confirmed); XCTAssertEqual(t.meta.name, "Mac Studio")
        t.meta = try XCTUnwrap(ViewerMeta(name: t.meta.name, port: Int(port), addresses: ["127.0.0.2", "127.0.0.1", "127.0.0.3"], manual: true, confirmed: true))
        try b.update(t.id, t.meta)
        // 3. ViewerModel で refresh → apply → 候補の last_ok_addr が更新される
        let session = TargetSession(book: b, entry: t, settings: settings10.connector)
        let vm = ViewerModel(client: session, displays: { [lg, builtIn] }, targetLabel: t.displayName, unconfirmed: !t.meta.confirmed, preferences: DisplayPreferences(store: MemoryStore()))
        await vm.refresh()
        XCTAssertNil(vm.failure); XCTAssertEqual(vm.title, "Mac Studio"); XCTAssertEqual(vm.connection, .connected)
        XCTAssertEqual(vm.state?.virtualDisplay?.scaling, .x1); XCTAssertEqual(vm.badge(for: lg), .applied); XCTAssertEqual(vm.badge(for: builtIn), .none)
        XCTAssertNil(vm.notice)
        XCTAssertEqual(b.load().entry(t.id)?.meta.lastOKAddress, "127.0.0.1", "つながった候補を次回から先に試す")
        XCTAssertEqual(b.load().entry(t.id)?.meta.addresses, ["127.0.0.2", "127.0.0.1", "127.0.0.3"], "手で直した候補は書き換えない")
        await vm.applyChosen(for: builtIn)   // 2x
        XCTAssertNil(vm.failure); XCTAssertEqual(vm.state?.mode, .x2); XCTAssertEqual(vm.state?.virtualDisplay?.scaling, .x2)
        XCTAssertEqual(vm.badge(for: builtIn), .applied); XCTAssertEqual(vm.state?.setByOther, false)
        XCTAssertEqual(vm.footerText, "表示倍率を自動で保つ: オン")
        let lines = ViewerDiagnostics.lines(target: session.entry, state: vm.state, failure: vm.failure, chosen: vm.chosenMode(for: builtIn))
        XCTAssertEqual(lines.map(\.mark), Array(repeating: .ok, count: 8))
        // 4. 削除: unpair → 帳簿と Host の両方から消える
        let removal = try await session.remove()
        XCTAssertEqual(removal, .removed)
        XCTAssertEqual(b.load().entries, []); XCTAssertNil(b.selectedID)
        let id = t.id
        await waitFor(3) { self.host.runtime.pairings[id] == nil }
        XCTAssertNil(host.runtime.pairings[t.id])
        vm.updateClient(nil, targetLabel: "")
        XCTAssertEqual(vm.notice?.title, "接続先がまだありません")
        // Host の記録: hello・set・unpair はそれぞれ 1 本にだけ送られた
        // （Host が結末を書くのは応答を送って閉じた後。unpair の結末が書かれるのを待ってから読む。計画 2g）
        await waitFor(5) { self.host.outcomes.contains(.served(id, .unpair)) }
        let o = host.outcomes
        XCTAssertEqual(o.filter { if case .paired = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(o.filter { $0 == .served(t.id, .set) }.count, 1)
        XCTAssertEqual(o.filter { $0 == .served(t.id, .unpair) }.count, 1)
        XCTAssertFalse(o.contains(.noRequest), "余りの接続は無い（応答の無い候補は Host に届かない）")
    }

    // 解除された接続先: not_paired は消さずに案内する。利用者が削除を選べる
    func testRemovedOnTheHostIsReportedNotDeleted() async throws {
        try await startHost()
        let b = book()
        var t = try await pairedTarget(in: b); t.meta.manual = true; try b.update(t.id, t.meta)
        let before = host.listens
        try host.runtime.unpair(t.id)
        await host.waitReopened(after: before)   // 受け側が新しい PSK の組（この見る側を含まない）で開き直るまで
        let session = TargetSession(book: b, entry: t, settings: fast.connector)
        let vm = ViewerModel(client: session, displays: { [lg] }, targetLabel: t.displayName)
        await vm.refresh()
        XCTAssertEqual(vm.failure, .handshakeFailed(othersUnreachable: false), "解除された秘密は受け側に無く、TLS が成立しない")
        XCTAssertEqual(vm.notice?.title, "ペアリングが一致しないか、別の機器が応答しています")
        XCTAssertEqual(b.load().entries.map(\.id), [t.id], "エラーを理由に自動で消さない")
        let removal = try await session.remove()
        XCTAssertEqual(removal, .removed, "利用者が削除を選んだ: Host には無いので解除済みとして消す")
        XCTAssertEqual(b.load().entries, [])
    }
}
