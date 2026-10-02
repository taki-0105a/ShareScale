import XCTest
@testable import ShareScaleCore
import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// 接続先との通信（`status`・`set`・削除）と、照合済みの応答での付帯情報の更新（仕様「見る側」の候補の更新・「解除」）
final class TargetSessionTests: HostViewerTestCase, @unchecked Sendable {
    var fast: Connector.Settings { var s = Connector.Settings(); s.readyTimeout = 2; s.total = 5; return s }

    func testUpdatedMetaFollowsStatusUnlessManual() throws {
        let m = try XCTUnwrap(ViewerMeta(name: "old", port: 1, addresses: ["a", "b"], lastOKAddress: "a", confirmed: false))
        let s = payload(name: "New\u{7}", port: 2, addresses: ["c"])
        let u = TargetSession.updatedMeta(m, status: s, via: "b", confirmed: true)
        XCTAssertEqual(u, ViewerMeta(name: "New", port: 2, addresses: ["c"], manual: false, lastOKAddress: nil, confirmed: true), "候補は status のもの。つながった候補が無くなれば last_ok_addr は持たない")
        var manual = m; manual.manual = true
        let v = TargetSession.updatedMeta(manual, status: s, via: "b", confirmed: true)
        XCTAssertEqual(v, ViewerMeta(name: "New", port: 1, addresses: ["a", "b"], manual: true, lastOKAddress: "b", confirmed: true), "手で直した候補と通信口は書き換えない")
        XCTAssertEqual(TargetSession.updatedMeta(m, status: payload(name: "\u{7}", port: 2, addresses: ["c"]), via: "c", confirmed: false).name, "old", "名前が空なら今のまま")
        XCTAssertTrue(TargetSession.updatedMeta(manual, status: s, via: "a", confirmed: false).confirmed == false)
        var c = m; c.confirmed = true
        XCTAssertTrue(TargetSession.updatedMeta(c, status: s, via: "a", confirmed: false).confirmed, "確定は戻さない")
        let named = try XCTUnwrap(m.withAlias("書斎"))
        XCTAssertEqual(TargetSession.updatedMeta(named, status: s, via: "c", confirmed: true).alias, "書斎", "付けた名前は Host の名前が変わっても保つ（計画 2f-1 案 6）")
        XCTAssertEqual(TargetSession.updatedMeta(named, status: s, via: "c", confirmed: true).name, "New")
        XCTAssertEqual(TargetSession.confirmedMeta(named, via: "a").alias, "書斎")
    }

    // `status` の書き戻し（帳簿を読み直してから書く）で、付けた名前を消さない（計画 2f-1 案 6）
    func testStatusWriteBackKeepsTheAlias() async throws {
        try await startHost()
        let b = book()
        let t = try await pairedTarget(in: b)
        let session = TargetSession(book: b, entry: t, settings: fast)   // 名前を付ける前の写しを持つ
        try b.update(t.id, XCTUnwrap(t.meta.withAlias("書斎の Mac")))    // 設定で名前を付けた
        let before = b.modifyCount
        let r = await session.status()
        guard case .success = r else { return XCTFail("\(r)") }
        let m = try XCTUnwrap(b.load().entry(t.id)?.meta)
        XCTAssertEqual(m.alias, "書斎の Mac", "読み直した帳簿の名前を保つ")
        XCTAssertEqual(m.name, "Mac Studio", "Host の名前は応答のもの")
        XCTAssertEqual(b.load().entry(t.id)?.displayName, "書斎の Mac")
        XCTAssertEqual(b.modifyCount, before + 1, "書き戻しは TargetBook.modify を通る（読みと書きが 1 つの鍵の中）")
        session.adoptAlias(nil)
        XCTAssertNil(session.currentMeta.alias)
    }

    func testStatusUpdatesTheBookFromTheReply() async throws {
        try await startHost()
        let b = book()
        let t = try await pairedTarget(in: b)
        let session = TargetSession(book: b, entry: t, settings: fast)
        let r = await session.status()
        guard case let .success(s) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(s.computerName, "Mac Studio"); XCTAssertEqual(s.model, "Mac Studio (2025)"); XCTAssertTrue(s.sessionActive)
        XCTAssertEqual(s.addresses, ["studio.local"]); XCTAssertEqual(s.port, Int(port))
        let m = try XCTUnwrap(b.load().entry(t.id)?.meta)
        XCTAssertEqual(m.addresses, ["studio.local"], "照合済みの status の addrs で候補を書き換える")
        XCTAssertEqual(m.name, "Mac Studio"); XCTAssertTrue(m.confirmed)
        XCTAssertEqual(session.currentMeta, m)
    }

    func testManualCandidatesAreKeptSetAppliesAndUnpairRemoves() async throws {
        try await startHost()
        let b = book()
        var t = try await pairedTarget(in: b)
        t.meta.manual = true; try b.update(t.id, t.meta)
        let session = TargetSession(book: b, entry: t, settings: fast)
        let st = await session.status()
        guard case let .success(s0) = st else { return XCTFail("\(st)") }
        XCTAssertEqual(s0.virtualDisplay?.scaling, .x1, "Host は起動時に 1x に直す")
        XCTAssertEqual(b.load().entry(t.id)?.meta.addresses, ["127.0.0.1"], "手で直した候補は書き換えない")
        XCTAssertEqual(b.load().entry(t.id)?.meta.lastOKAddress, "127.0.0.1")
        let set = await session.set(.x2)
        guard case let .success(s1) = set else { return XCTFail("\(set)") }
        XCTAssertEqual(s1.mode, .x2); XCTAssertEqual(s1.virtualDisplay?.scaling, .x2); XCTAssertEqual(s1.setByOther, false)
        let removal = try await session.remove()
        XCTAssertEqual(removal, .removed)
        XCTAssertEqual(b.load().entries, [])
        let id = t.id
        await waitFor(3) { self.host.runtime.pairings[id] == nil }
        XCTAssertNil(host.runtime.pairings[t.id], "Host 側も解除")
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.hostDir.appendingPathComponent(t.id.hex + ".key").path))
        let o = await host.outcomes(count: 5)
        XCTAssertEqual(o.suffix(3), [.served(t.id, .status), .served(t.id, .set), .served(t.id, .unpair)], "set・unpair は 1 本にだけ")
        // 解除済みの接続先をもう一度消す: TLS が成立しない（not_paired）→ 解除済みとして消す
        try b.add(id: t.id, secret: t.secret, meta: t.meta)
        let again = try await TargetSession(book: b, entry: t, settings: fast).remove()
        XCTAssertEqual(again, .removed)
        XCTAssertEqual(b.load().entries, [])
    }

    // 画面で手直しした（manual）後の status は、古い写しで手直しを上書きしない（書く前に帳簿を読み直す）
    func testStatusRereadsTheBookBeforeWriting() async throws {
        try await startHost()
        let b = book()
        let t = try await pairedTarget(in: b)
        let session = TargetSession(book: b, entry: t, settings: fast)   // 写しは manual: false
        var edited = t.meta; edited.manual = true; edited.addresses = ["127.0.0.1", "::1"]
        try b.update(t.id, edited)                                        // 画面の手直し（セッションの写しは古いまま）
        let r = await session.status()
        guard case .success = r else { return XCTFail("\(r)") }
        let m = try XCTUnwrap(b.load().entry(t.id)?.meta)
        XCTAssertTrue(m.manual); XCTAssertEqual(m.addresses, ["127.0.0.1", "::1"], "手直しは保たれる")
        XCTAssertEqual(m.lastOKAddress, "127.0.0.1"); XCTAssertEqual(m.name, "Mac Studio")
        XCTAssertEqual(session.currentMeta, m, "写しも読み直したものに")
    }

    // set の応答が paused（照合済み）でも確定を書く
    func testVerifiedPausedReplyConfirmsThePairing() async throws {
        try await startHost()
        let b = book()
        var t = try await pairedTarget(in: b, confirmed: false); t.meta.manual = true; try b.update(t.id, t.meta)
        XCTAssertFalse(t.meta.confirmed)
        host.runtime.setPaused(true)
        let session = TargetSession(book: b, entry: t, settings: fast)
        let set = await session.set(.x2)
        XCTAssertEqual(set, .failure(.paused))
        let m = try XCTUnwrap(b.load().entry(t.id)?.meta)
        XCTAssertTrue(m.confirmed, "照合は通っている（Host は確定している）"); XCTAssertEqual(m.lastOKAddress, "127.0.0.1")
        XCTAssertEqual(m.addresses, ["127.0.0.1"], "候補は応答に無いので変えない")
        XCTAssertEqual(TargetSession.confirmedMeta(ViewerMeta(name: "n", port: 1, addresses: ["a"], confirmed: false)!, via: "a").confirmed, true)
        XCTAssertNil(TargetSession.confirmedMeta(ViewerMeta(name: "n", port: 1, addresses: ["a"], confirmed: false)!, via: "zz").lastOKAddress)
    }

    func testRemoveWhenUnreachableRemovesLocally() async throws {
        try await startHost()
        let b = book()
        var t = try await pairedTarget(in: b)
        t.meta = ViewerMeta(name: "S", port: Int(port), addresses: ["127.0.0.2"], manual: true, confirmed: true)!
        try b.update(t.id, t.meta)
        let removal = try await TargetSession(book: b, entry: t, settings: fast).remove()
        XCTAssertEqual(removal, .removedLocally, "届かなければ見る側だけで消す（接続先のメニューからも解除してもらう）")
        XCTAssertEqual(b.load().entries, [])
        XCTAssertNotNil(host.runtime.pairings[t.id], "Host には残る")
    }

    func testPausedHostRefusesSetButAnswersStatus() async throws {
        try await startHost()
        let b = book()
        var t = try await pairedTarget(in: b); t.meta.manual = true; try b.update(t.id, t.meta)
        host.runtime.setPaused(true)
        let session = TargetSession(book: b, entry: t, settings: fast)
        let set = await session.set(.x2)
        XCTAssertEqual(set, .failure(.paused))
        let st = await session.status()
        guard case let .success(s) = st else { return XCTFail("\(st)") }
        XCTAssertTrue(s.paused)
    }

    // 問い合わせの間に帳簿から削除された → 応答で `.meta` を書き戻さない（`.meta` だけが残らない。再点検）
    func testStatusAfterRemovalDoesNotWriteTheMetaBack() async throws {
        try await startHost()
        let b = book()
        let t = try await pairedTarget(in: b)
        let session = TargetSession(book: b, entry: t, settings: fast)
        try b.remove(t.id)
        let st = await session.status()
        guard case .success = st else { return XCTFail("\(st)") }
        XCTAssertEqual(b.load().entries, []); XCTAssertEqual(b.load().problems, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: viewerDir.appendingPathComponent(t.id.hex + ".meta").path), "削除した接続先の .meta を書き戻さない")
        XCTAssertEqual(session.currentMeta.addresses, ["studio.local"], "記憶の中の写しは応答で更新する")
    }
}
