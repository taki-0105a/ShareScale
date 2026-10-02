import XCTest
@testable import ShareScaleCore
import ShareScaleNet
import ShareScaleProtocol

/// 接続先の切り替え（`ViewerTargets`）。一時フォルダの帳簿で、Host は使わない（削除は閉じた通信口に向けて「届かない」を作る）
@MainActor
final class ViewerTargetsTests: TempDirTestCase {
    override func setUp() { super.setUp(); AppLanguage.current = .ja }
    var fastConnector: Connector.Settings { var s = Connector.Settings(); s.readyTimeout = 1; s.total = 2; return s }

    func makeBook(_ settings: MemoryStore = MemoryStore()) -> TargetBook {
        TargetBook(store: SecretStore(base: support, role: .viewer, machine: "MAC-VIEWER"), settings: settings)
    }
    func add(_ b: TargetBook, _ n: UInt8, _ name: String, port: Int, confirmed: Bool = true) throws {
        try b.add(id: pid(n), secret: secret(n), meta: XCTUnwrap(ViewerMeta(name: name, port: port, addresses: ["127.0.0.1"], confirmed: confirmed)))
    }

    func testReloadSelectsAndSwitchesOnlyWhenTheTargetChanges() throws {
        let b = makeBook()
        let vm = ViewerModel(client: nil, displays: { [lg] })
        var switched: [String] = []
        let t = ViewerTargets(book: b, model: vm, connector: fastConnector, onSwitch: { switched.append($0.targetLabel) })
        t.reload()
        XCTAssertNil(t.selectedID); XCTAssertFalse(vm.hasTarget); XCTAssertEqual(switched, [])
        XCTAssertEqual(vm.notice?.title, "接続先がまだありません"); XCTAssertNil(t.storeNotice); XCTAssertFalse(t.isFull)
        XCTAssertTrue(t.canAdd); XCTAssertEqual(t.addNote, "接続先は 32 台まで登録できます。")
        let port = Int(closedLoopbackPort() ?? 9)
        try add(b, 2, "Studio", port: port)
        try add(b, 1, "Air", port: port, confirmed: false)
        t.reload()
        XCTAssertEqual(t.selectedID, pid(1), "選んでいなければ帳簿の 1 件目（id の順）")
        XCTAssertTrue(vm.hasTarget); XCTAssertEqual(vm.targetLabel, "Air"); XCTAssertTrue(vm.targetUnconfirmed)
        XCTAssertEqual(switched, ["Air"])
        t.reload()
        XCTAssertEqual(switched, ["Air"], "同じ接続先なら作り直さない（取り直しも起こさない）")
        t.select(pid(2))
        XCTAssertEqual(t.selectedID, pid(2)); XCTAssertEqual(b.selectedID, pid(2), "選んだ接続先を覚える"); XCTAssertEqual(vm.targetLabel, "Studio")
        XCTAssertFalse(vm.targetUnconfirmed); XCTAssertEqual(switched, ["Air", "Studio"])
        t.select(pid(9))
        XCTAssertEqual(t.selectedID, pid(2), "帳簿に無い id は選ばない")
        XCTAssertEqual(t.rows.map(\.name), ["Air", "Studio"]); XCTAssertEqual(t.rows.map(\.selected), [false, true])
        XCTAssertEqual(t.name(of: pid(1)), "Air")
        // 候補を手で直す: 使っている接続先なら相手を作り直す
        var e = ManualCandidatesEditor(try XCTUnwrap(t.selectedEntry).meta)
        e.addressesText = "127.0.0.1\n::1"
        try t.saveCandidates(pid(2), e.validate().get())
        XCTAssertEqual(t.selectedEntry?.meta.addresses, ["127.0.0.1", "::1"]); XCTAssertEqual(t.selectedEntry?.meta.manual, true)
        XCTAssertEqual(b.load().entry(pid(2))?.meta.manual, true)
        XCTAssertEqual(switched, ["Air", "Studio", "Studio"])
        // 読めないファイル（.meta の無い .key）→ 案内
        try b.store.save(StoredPairing(id: pid(3), secret: secret(3)))
        t.reload()
        XCTAssertEqual(t.storeNotice?.title, "読み込めない接続先のファイルがあります")
        XCTAssertTrue(t.storeNotice?.detail.hasPrefix("1 件のファイルを読み込めませんでした。") == true)
    }

    func testRemoveUnreachableTargetLocallyAndMoveTheSelection() async throws {
        let b = makeBook()
        let port = Int(try XCTUnwrap(closedLoopbackPort()))
        try add(b, 1, "Air", port: port); try add(b, 2, "Studio", port: port)
        let vm = ViewerModel(client: nil, displays: { [lg] })
        let t = ViewerTargets(book: b, model: vm, connector: fastConnector, onSwitch: { _ in })
        t.select(pid(1))
        let r = await t.remove(pid(1))
        XCTAssertEqual(r, .removedLocally(name: "Air"), "届かない（閉じた通信口）→ この Mac だけで消す")
        XCTAssertEqual(r.message.title, "「Air」をこの Mac から削除しました")
        XCTAssertEqual(b.load().entries.map(\.id), [pid(2)])
        XCTAssertEqual(t.selectedID, pid(2), "選んでいた接続先を消したら残りの 1 件目"); XCTAssertEqual(vm.targetLabel, "Studio")
        let r2 = await t.remove(pid(2))
        XCTAssertEqual(r2, .removedLocally(name: "Studio"))
        XCTAssertNil(t.selectedID); XCTAssertFalse(vm.hasTarget)
        let missing = await t.remove(pid(7))
        XCTAssertEqual(missing, .alreadyRemoved, "帳簿に無い接続先は「すでに削除されています」（点検 E）")
    }

    // 候補の手直しは、帳簿の今の付帯情報に候補・通信口・印の 3 つだけを当てる（窓を開いた後に確定・名前が変わっても保つ。点検 F）
    func testSavingCandidatesKeepsNewerNameAndConfirmation() throws {
        let b = makeBook()
        let port = Int(try XCTUnwrap(closedLoopbackPort()))
        try add(b, 1, "Air", port: port, confirmed: false)
        let vm = ViewerModel(client: nil, displays: { [lg] })
        let t = ViewerTargets(book: b, model: vm, connector: fastConnector, onSwitch: { _ in })
        t.reload()
        var e = ManualCandidatesEditor(try XCTUnwrap(t.selectedEntry).meta)     // 窓を開いた（未確定・名前 Air の写し）
        // 窓を開いている間に status が通った（名前・確定・前回の候補が変わった）
        try b.update(pid(1), XCTUnwrap(ViewerMeta(name: "Studio", port: port, addresses: ["127.0.0.1"], lastOKAddress: "127.0.0.1", confirmed: true)))
        e.addressesText = "127.0.0.1\n::1"
        try t.saveCandidates(pid(1), e.validate().get())
        let m = try XCTUnwrap(b.load().entry(pid(1))?.meta)
        XCTAssertEqual(m.name, "Studio"); XCTAssertTrue(m.confirmed, "古い写しの confirmed: false で上書きしない")
        XCTAssertEqual(m.lastOKAddress, "127.0.0.1"); XCTAssertEqual(m.addresses, ["127.0.0.1", "::1"]); XCTAssertTrue(m.manual)
        XCTAssertEqual(t.selectedEntry?.meta, m, "使っている接続先は作り直す")
        // 窓を開いている間に削除された → 保存しない
        try b.remove(pid(1))
        XCTAssertThrowsError(try t.saveCandidates(pid(1), e.validate().get())) { XCTAssertEqual($0 as? ViewerTargets.SaveError, .notFound) }
        XCTAssertEqual(b.load().entries, [], ".meta だけを書き戻さない")
        XCTAssertEqual(ViewerTargets.saveProblem(ViewerTargets.SaveError.notFound).text, "この接続先はすでに削除されています。")
        let other = ViewerTargets.saveProblem(CocoaError(.fileWriteNoPermission))
        XCTAssertEqual(other.text, "保存できませんでした。~/Library/Application Support/ShareScale/pairings/viewer/ のアクセス権を確認してください。")
        XCTAssertNotNil(other.detail, "生の理由は「詳細をコピー」へ")
    }

    // 計画 2f-1 案 6: 名前を付け直す。使っている接続先なら相手を作り直さずに見出しの名前だけを変える。空にすると Host の名前に戻る
    func testRenameChangesTheNameEverywhereWithoutSwitching() async throws {
        let b = makeBook()
        let port = Int(try XCTUnwrap(closedLoopbackPort()))
        try add(b, 1, "Mac Studio", port: port)
        try add(b, 2, "Air", port: port)
        let vm = ViewerModel(client: nil, displays: { [lg] })
        var switched = 0
        let t = ViewerTargets(book: b, model: vm, connector: fastConnector, onSwitch: { _ in switched += 1 })
        t.select(pid(1))
        XCTAssertEqual(switched, 1)
        let fake = FakeTarget(.success(connected()))
        vm.updateClient(fake, targetLabel: "Mac Studio")      // 状態の取り直しは偽物で（相手の名前は Studio）
        await vm.refresh()
        XCTAssertEqual(vm.title, "Studio", "名前を付けていなければ相手のコンピュータ名")
        let before = b.modifyCount
        try t.rename(pid(1), alias: "書斎の Mac")
        XCTAssertEqual(b.modifyCount, before + 1, "名前の変更は TargetBook.modify を通る")
        XCTAssertEqual(switched, 1, "相手を作り直さない（状態を取り直さない）")
        XCTAssertEqual(vm.title, "書斎の Mac", "付けた名前は相手のコンピュータ名より優先")
        XCTAssertEqual(vm.targetLabel, "書斎の Mac"); XCTAssertNotNil(vm.state, "状態はそのまま")
        XCTAssertEqual(t.rows.map(\.name), ["Air", "書斎の Mac"], "一覧は表示名の順")
        XCTAssertEqual(t.rows.last?.hostNameLine, "接続先での名前: Mac Studio")
        XCTAssertNil(t.rows.first?.hostNameLine)
        XCTAssertEqual(t.selectedEntry?.meta.alias, "書斎の Mac", "使っている相手の写しにも当てる")
        XCTAssertEqual(b.load().entry(pid(1))?.meta.name, "Mac Studio", "Host の名前は残す")
        try t.rename(pid(1), alias: nil)
        XCTAssertEqual(vm.title, "Studio"); XCTAssertEqual(vm.targetLabel, "Mac Studio"); XCTAssertNil(b.load().entry(pid(1))?.meta.alias)
        try t.rename(pid(2), alias: "居間")                     // 使っていない接続先
        XCTAssertEqual(vm.targetLabel, "Mac Studio", "使っている接続先の名前は変えない")
        XCTAssertEqual(b.load().entry(pid(2))?.displayName, "居間")
        try b.remove(pid(2))
        XCTAssertThrowsError(try t.rename(pid(2), alias: "x")) { XCTAssertEqual($0 as? ViewerTargets.SaveError, .notFound) }
        XCTAssertThrowsError(try t.rename(pid(1), alias: "a\nb")) { XCTAssertEqual($0 as? ViewerTargets.SaveError, .invalid) }
    }

    // 主の窓の案内の重さ（注意か、お知らせか）
    func testNoticeSeverity() async {
        let vm = ViewerModel(client: nil, displays: { [lg] })
        XCTAssertFalse(vm.noticeIsWarning, "未登録はお知らせ")
        let fake = FakeTarget(.success(connected()))
        vm.updateClient(fake, targetLabel: "Studio")
        await vm.refresh()
        XCTAssertNil(vm.notice); XCTAssertFalse(vm.noticeIsWarning)
        fake.statusResult = .success(RemoteState(payload(session: false, vd: nil)))
        await vm.refresh(force: true)
        XCTAssertEqual(vm.notice?.title, "画面共有を始めると、自動で 1x 等倍に切り替わります"); XCTAssertFalse(vm.noticeIsWarning)
        fake.statusResult = .success(RemoteState(payload(setBy: StatusPayload.SetBy(byYou: false, at: 1))))
        await vm.refresh(force: true)
        XCTAssertEqual(vm.notice?.title, "ほかの接続元の Mac が表示倍率を変更しました"); XCTAssertFalse(vm.noticeIsWarning)
        for s in [payload(paused: true), payload(vd: nil), payload(ambiguous: true), payload(lastError: "boom")] {
            fake.statusResult = .success(RemoteState(s))
            await vm.refresh(force: true)
            XCTAssertTrue(vm.noticeIsWarning, "\(s)")
        }
        fake.statusResult = .failure(.unreachable)
        await vm.refresh(force: true)
        XCTAssertTrue(vm.noticeIsWarning)
        vm.updateClient(fake, targetLabel: "Studio", unconfirmed: true)
        XCTAssertTrue(vm.noticeIsWarning, "未確定")
    }

    func testWithoutABookTheAppStillRuns() {
        let vm = ViewerModel(client: nil, displays: { [lg] })
        let t = ViewerTargets(book: nil, model: vm, onSwitch: { _ in XCTFail("切り替えない") })
        t.reload()
        XCTAssertFalse(vm.hasTarget)
        XCTAssertFalse(t.canAdd, "追加もできない"); XCTAssertFalse(t.isFull, "上限とは分ける（点検 M）")
        XCTAssertEqual(t.addNote, "接続先を保存できないため、今は追加できません。", "理由は上の案内が書くので重ねない")
        XCTAssertFalse(t.storeNotice?.detail.contains("IOPlatformUUID") ?? true, "内部の識別子の名前を出さない")
        XCTAssertEqual(t.storeNotice?.title, "接続先を保存できません")
        XCTAssertThrowsError(try t.saveCandidates(pid(1), ManualCandidatesEditor.Candidates(addresses: ["127.0.0.1"], port: 1, manual: true))) {
            XCTAssertEqual($0 as? ViewerTargets.SaveError, .unavailable)
        }
        XCTAssertNil(t.name(of: pid(1)))
    }
}
