import Combine
import XCTest
@testable import ShareScaleCore
import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// 端から端まで（計画 2d-2）: ループバックの `HostRuntime` と偽の承認で、接続先の追加の窓（`AddTargetModel`）→ 確定 →
/// 選んだ接続先の切り替え（`ViewerTargets`）→ 候補の手直し → `ViewerModel.refresh` までを通す。
/// 貼り付けるコードは、Host が出したコードの id・秘密・通信口で候補だけをループバックにしたもの（Host の候補 `studio.local` は試験では解決しない）
@MainActor
final class AddTargetEndToEndTests: HostViewerTestCase, @unchecked Sendable {
    override func setUp() { super.setUp(); AppLanguage.current = .ja }
    var fast: PairingFlow.Settings { var s = PairingFlow.Settings(); s.connector.readyTimeout = 2; s.connector.total = 5; s.confirmInterval = 0.5; return s }

    func testAddTargetConfirmsSelectsTheNewTargetAndRefreshes() async throws {
        try await startHost()
        let b = book()
        let existing = try await pairedTarget(in: b)            // 先に 1 件（確定済み）
        let vm = ViewerModel(client: nil, displays: { [lg, builtIn] }, preferences: DisplayPreferences(store: MemoryStore()))
        var switched = 0
        let targets = ViewerTargets(book: b, model: vm, connector: fast.connector, onSwitch: { _ in switched += 1 })
        targets.reload()
        XCTAssertEqual(targets.selectedID, existing.id); XCTAssertEqual(switched, 1)
        // 接続コードを貼り付けて「追加する」
        let issued = await host.issueCode(); let code = try XCTUnwrap(issued)
        let loopbackCode = try XCTUnwrap(PairingCode(id: code.id, secret: code.secret, port: code.port, addresses: ["127.0.0.1"], expiresAt: code.expiresAt))
        let pb = FakePasteboard()
        let add = AddTargetModel(runner: AddTargetModel.runner(book: b, computerName: { "MacBook" }, settings: fast), pasteboard: pb,
                                 names: { targets.name(of: $0) }, onFinish: { targets.pairingFinished($0) })
        var steps: [AddTargetFlow.Step] = []
        let sub = add.$flow.map(\.step).removeDuplicates().sink { steps.append($0) }
        defer { sub.cancel() }
        add.paste(loopbackCode.encoded())
        XCTAssertTrue(add.flow.canStart); XCTAssertNil(add.expiryWarning)
        add.start()
        await add.waitUntilFinished()
        XCTAssertEqual(add.flow.step, .finished(.confirmed(code.id, name: "Mac Studio")))
        XCTAssertEqual(AddTargetText.result(.confirmed(code.id, name: "Mac Studio")).text.title, "「Mac Studio」を追加しました")
        let shown = steps.compactMap { if case let .awaitingApproval(c) = $0 { return c }; return nil }
        XCTAssertEqual(shown, [try XCTUnwrap(host.approver.asked.last).confirmationCode], "確認番号は 1 つだけ出て、接続先の窓と一致する")
        XCTAssertEqual(steps.prefix(2), [.input, .connecting])
        XCTAssertTrue(steps.contains(.confirming(attempt: 1)))
        XCTAssertEqual(pb.cleared, 1, "貼り付けたままのクリップボードを消す")
        // 追加した接続先を選び、相手を切り替えた
        XCTAssertEqual(targets.selectedID, code.id); XCTAssertEqual(switched, 2)
        XCTAssertEqual(vm.targetLabel, "Mac Studio"); XCTAssertFalse(vm.targetUnconfirmed)
        XCTAssertEqual(targets.rows.map(\.id).sorted { $0.hex < $1.hex }, [existing.id, code.id].sorted { $0.hex < $1.hex })
        XCTAssertEqual(targets.rows.filter(\.selected).map(\.id), [code.id])
        // Host の候補（studio.local）はつながらないので、手で直す（`ManualCandidatesEditor`）→ 取り直す
        XCTAssertEqual(targets.selectedEntry?.meta.addresses, ["studio.local"])
        var editor = ManualCandidatesEditor(try XCTUnwrap(targets.selectedEntry).meta)
        editor.addressesText = "127.0.0.1"; editor.portText = String(port)
        try targets.saveCandidates(code.id, editor.validate().get())
        XCTAssertEqual(switched, 3)
        await vm.refresh()
        XCTAssertNil(vm.failure); XCTAssertEqual(vm.title, "Mac Studio"); XCTAssertEqual(vm.connection, .connected)
        XCTAssertEqual(vm.badge(for: lg), .applied)
        XCTAssertEqual(b.load().entry(code.id)?.meta.lastOKAddress, "127.0.0.1")
        // 前の接続先に切り替えても取り直せる
        targets.select(existing.id)
        await vm.refresh()
        XCTAssertNil(vm.failure); XCTAssertEqual(targets.selectedID, existing.id)
        // Host の記録: 名乗りはそれぞれ 1 本だけ
        XCTAssertEqual(host.outcomes.filter { if case .paired = $0 { return true }; return false }.count, 2)
    }
}
