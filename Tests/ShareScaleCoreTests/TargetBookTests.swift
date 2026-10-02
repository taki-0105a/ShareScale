import Darwin
import XCTest
@testable import ShareScaleCore
import ShareScaleNet
import ShareScaleProtocol

/// 接続先の帳簿（仕様「保管」の見る側の `.meta`・「選んだ接続先」・上限）
final class TargetBookTests: TempDirTestCase {
    let settings = MemoryStore()
    func book(machine: String = "MAC-TEST") -> TargetBook { TargetBook(store: SecretStore(base: support, role: .viewer, machine: machine), settings: settings) }
    func meta(_ name: String = "Studio", addrs: [String] = ["studio.local", "100.101.1.2"], last: String? = nil, manual: Bool = false, confirmed: Bool = true) -> ViewerMeta {
        ViewerMeta(name: name, port: 47651, addresses: addrs, manual: manual, lastOKAddress: last, confirmed: confirmed)!
    }
    func mode(_ p: String) -> mode_t { var st = stat(); lstat(p, &st); return st.st_mode & 0o777 }

    func testMetaShapeRoundTripAndRules() throws {
        let m = meta(last: "100.101.1.2", confirmed: false)
        XCTAssertEqual(String(decoding: m.encoded(), as: UTF8.self),
                       "{\"format\":1,\"name\":\"Studio\",\"addrs\":{\"p\":47651,\"a\":[\"studio.local\",\"100.101.1.2\"]},\"manual\":false,\"last_ok_addr\":\"100.101.1.2\",\"confirmed\":false}\n")
        XCTAssertEqual(ViewerMeta.decode(m.encoded()), m)
        XCTAssertEqual(ViewerMeta.decode(Data("{\"format\":1,\"name\":\"S\",\"addrs\":{\"p\":1,\"a\":[\"a\"]},\"manual\":true,\"last_ok_addr\":null,\"confirmed\":true}".utf8))?.lastOKAddress, nil)
        XCTAssertNil(ViewerMeta(name: "S", port: 0, addresses: ["a"], confirmed: true), "通信口の範囲")
        XCTAssertNil(ViewerMeta(name: "S", port: 1, addresses: [], confirmed: true), "候補 0 件")
        XCTAssertNil(ViewerMeta(name: "S", port: 1, addresses: (0..<9).map { "h\($0)" }, confirmed: true), "候補 9 件")
        XCTAssertNil(ViewerMeta(name: "S", port: 1, addresses: ["FD7A::1"], confirmed: true), "書き直した形でない IP")
        XCTAssertNil(ViewerMeta(name: "S", port: 1, addresses: ["a", "b"], lastOKAddress: "c", confirmed: true)?.lastOKAddress, "候補に無い last_ok_addr は捨てる")
        XCTAssertEqual(ViewerMeta(name: "Stu\u{7}dio" + String(repeating: "x", count: 200), port: 1, addresses: ["a"], confirmed: true)?.name.utf8.count, NameRules.maxBytes, "制御文字を除いて 128 バイトに")
        for bad in ["{\"format\":2,\"name\":\"S\",\"addrs\":{\"p\":1,\"a\":[\"a\"]},\"manual\":true,\"last_ok_addr\":null,\"confirmed\":true}",
                    "{\"format\":1,\"name\":\"S\",\"addrs\":{\"p\":1,\"a\":[\"a\"]},\"manual\":true,\"last_ok_addr\":null,\"confirmed\":true,\"x\":1}",
                    "{\"format\":1,\"name\":\"S\",\"addrs\":{\"p\":1,\"a\":[\"a\"]},\"manual\":true,\"confirmed\":true}",
                    "{\"format\":1,\"name\":\"S\",\"addrs\":{\"p\":\"1\",\"a\":[\"a\"]},\"manual\":true,\"last_ok_addr\":null,\"confirmed\":true}",
                    "{\"format\":1,\"name\":\"S\",\"addrs\":{\"p\":1,\"a\":[1]},\"manual\":true,\"last_ok_addr\":null,\"confirmed\":true}",
                    "{\"format\":1,\"name\":\"S\",\"addrs\":{\"p\":1,\"a\":[\"a\"]},\"manual\":1,\"last_ok_addr\":null,\"confirmed\":true}",
                    "{\"format\":1,\"name\":\"S\",\"addrs\":{\"p\":1,\"a\":[\"a\"]},\"manual\":true,\"last_ok_addr\":1,\"confirmed\":true}",
                    "{\"format\":1,\"name\":\"S\",\"addrs\":{\"p\":1,\"a\":[\"010.1.1.1\"]},\"manual\":true,\"last_ok_addr\":null,\"confirmed\":true}", "", "[]"] {
            XCTAssertNil(ViewerMeta.decode(Data(bad.utf8)), bad)
        }
    }

    // 計画 2f-1 案 6: 利用者が付けた名前（`alias`）。付けていなければキーを書かない。読む時は無くても null でもよい
    func testAliasIsOptionalAndValidated() throws {
        let plain = meta()
        XCTAssertFalse(String(decoding: plain.encoded(), as: UTF8.self).contains("alias"), "付けていなければ今までと同じ形")
        let named = try XCTUnwrap(meta().withAlias("書斎の Mac"))
        XCTAssertEqual(String(decoding: named.encoded(), as: UTF8.self),
                       "{\"format\":1,\"name\":\"Studio\",\"addrs\":{\"p\":47651,\"a\":[\"studio.local\",\"100.101.1.2\"]},\"manual\":false,\"last_ok_addr\":null,\"confirmed\":true,\"alias\":\"書斎の Mac\"}\n")
        XCTAssertEqual(ViewerMeta.decode(named.encoded()), named)
        XCTAssertEqual(ViewerMeta.decode(Data("{\"format\":1,\"name\":\"S\",\"addrs\":{\"p\":1,\"a\":[\"a\"]},\"manual\":false,\"last_ok_addr\":null,\"confirmed\":true,\"alias\":null}".utf8))?.alias, .some(nil))
        for bad in ["{\"format\":1,\"name\":\"S\",\"addrs\":{\"p\":1,\"a\":[\"a\"]},\"manual\":false,\"last_ok_addr\":null,\"confirmed\":true,\"alias\":1}",
                    "{\"format\":1,\"name\":\"S\",\"addrs\":{\"p\":1,\"a\":[\"a\"]},\"manual\":false,\"last_ok_addr\":null,\"confirmed\":true,\"alias\":\"\"}",
                    "{\"format\":1,\"name\":\"S\",\"addrs\":{\"p\":1,\"a\":[\"a\"]},\"manual\":false,\"last_ok_addr\":null,\"confirmed\":true,\"alias\":\"a\\nb\"}",
                    "{\"format\":1,\"name\":\"S\",\"addrs\":{\"p\":1,\"a\":[\"a\"]},\"manual\":false,\"last_ok_addr\":null,\"confirmed\":true,\"alias\":\"\(String(repeating: "x", count: 65))\"}"] {
            XCTAssertNil(ViewerMeta.decode(Data(bad.utf8)), bad)
        }
        XCTAssertNil(meta().withAlias(" "), "空白だけは付けられない（`TargetAlias.validate` が nil にする）")
        let e = TargetEntry(id: pid(1), secret: secret(1), meta: named)
        XCTAssertEqual(e.displayName, "書斎の Mac"); XCTAssertEqual(e.hostName, "Studio")
        XCTAssertEqual(TargetEntry(id: pid(1), secret: secret(1), meta: meta("")).displayName, "01010101", "名前が空なら id の先頭 8 文字")
        // 画面の入力
        XCTAssertEqual(TargetAlias.validate("  書斎の Mac \n", hostName: "Studio"), .success("書斎の Mac"))
        XCTAssertEqual(TargetAlias.validate("   ", hostName: "Studio"), .success(nil), "空にすると接続先の名前に戻す")
        XCTAssertEqual(TargetAlias.validate("Studio", hostName: "Studio"), .success(nil), "接続先の名前と同じなら付けない（Host の名前の変更についていく）")
        XCTAssertEqual(TargetAlias.validate(String(repeating: "あ", count: 65), hostName: "Studio"), .failure(.invalid))
        XCTAssertEqual(TargetAlias.validate("a\u{200B}b", hostName: "Studio"), .failure(.invalid), "書式の文字（Cf）は使えない")
        XCTAssertEqual(TargetAlias.validate(String(repeating: "あ", count: 42), hostName: "Studio"), .success(String(repeating: "あ", count: 42)), "128 バイトまで")
    }

    // 書き戻し（`status` の応答で付帯情報を更新）と名前の変更を並べて走らせても、付けた名前が古い写しで消えない（`modify` の 1 つの鍵。点検 2f-1）
    func testWriteBackAndRenameDoNotLoseTheAlias() throws {
        let b = book()
        try b.add(id: pid(1), secret: secret(1), meta: meta(confirmed: false))
        let reply = payload(name: "Studio", addresses: ["studio.local"])
        // 書き戻しが帳簿を読んだ後、書く前に、別のスレッドで名前の変更を始める（0.3 秒待ってから古い写しで書く）。
        // 読みと書きが 1 つの鍵の中なら、名前の変更は書き戻しが終わるまで待たされ、最後に書くので名前が残る。
        // 読みと書きを分けた形（鍵の外で読む）では、名前の変更が先に書き、書き戻しが古い写しで名前を消す（再点検で確かめた）
        let renamed = DispatchGroup()
        renamed.enter()
        try b.modify(pid(1)) { l in
            DispatchQueue.global().async {
                try? b.modify(pid(1)) { l2 in l2.entry(pid(1))?.meta.withAlias("書斎の Mac") }
                renamed.leave()
            }
            _ = renamed.wait(timeout: .now() + 0.3)
            return l.entry(pid(1)).map { TargetSession.updatedMeta($0.meta, status: reply, via: "studio.local", confirmed: true) }
        }
        XCTAssertEqual(renamed.wait(timeout: .now() + 5), .success)
        let m = try XCTUnwrap(b.load().entry(pid(1))?.meta)
        XCTAssertEqual(m.alias, "書斎の Mac", "書き戻しの後に名前の変更が書く（古い写しで名前を消さない）")
        XCTAssertTrue(m.confirmed, "名前の変更は書き戻しの結果を読み直してから書く")
        XCTAssertEqual(b.modifyCount, 2)
        XCTAssertEqual(b.load().problems, [])
        // 帳簿に無い id は書かない
        try b.modify(pid(9)) { l in l.entry(pid(9))?.meta }
        XCTAssertNil(b.load().entry(pid(9)))
    }

    func testAddLoadUpdateRemoveWithStrictFiles() throws {
        let b = book()
        try b.add(id: pid(1), secret: secret(1), meta: meta(confirmed: false))
        try b.add(id: pid(2), secret: secret(2), meta: meta("Mini", addrs: ["mini.local"]))
        let l = b.load()
        XCTAssertEqual(l.problems, [])
        XCTAssertEqual(l.entries.map(\.id), [pid(1), pid(2)], "id の順")
        guard hasCount(l.entries, 2) else { return }
        XCTAssertEqual(l.entries[0].secret, secret(1)); XCTAssertEqual(l.entries[0].meta.confirmed, false)
        XCTAssertEqual(l.entries[1].displayName, "Mini")
        XCTAssertEqual(mode(viewerDir.path), 0o700); XCTAssertEqual(mode(viewerDir.appendingPathComponent(pid(1).hex + ".meta").path), 0o600)
        XCTAssertTrue(try String(contentsOf: viewerDir.appendingPathComponent(pid(1).hex + ".key"), encoding: .utf8).contains("\"role\":\"viewer\""))
        var m = l.entries[0].meta; m.confirmed = true; m.lastOKAddress = "100.101.1.2"
        var st = stat(); lstat(viewerDir.appendingPathComponent(pid(1).hex + ".key").path, &st); let ino = st.st_ino
        try b.update(pid(1), m)
        XCTAssertEqual(b.load().entry(pid(1))?.meta, m)
        lstat(viewerDir.appendingPathComponent(pid(1).hex + ".key").path, &st); XCTAssertEqual(st.st_ino, ino, "付帯情報の更新で秘密のファイルを書き直さない")
        b.selectedID = pid(1)
        try b.remove(pid(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: viewerDir.appendingPathComponent(pid(1).hex + ".key").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: viewerDir.appendingPathComponent(pid(1).hex + ".meta").path))
        XCTAssertNil(b.selectedID, "選んでいた接続先を消したら選択も消す")
        XCTAssertEqual(b.load().entries.map(\.id), [pid(2)])
        try b.remove(pid(1))   // 2 回目も失敗しない
    }

    func testUnusableFilesAreReportedNotUsed() throws {
        let b = book()
        try b.add(id: pid(1), secret: secret(1), meta: meta())
        try b.add(id: pid(2), secret: secret(2), meta: meta())
        try b.add(id: pid(3), secret: secret(3), meta: meta())
        try b.add(id: pid(4), secret: secret(4), meta: meta())
        unlink(viewerDir.appendingPathComponent(pid(2).hex + ".meta").path)                        // .meta の無い .key
        try Data("{\"format\":1}\n".utf8).write(to: viewerDir.appendingPathComponent(pid(3).hex + ".meta")) // 形の違う .meta（権限は 600 のまま）
        chmod(viewerDir.appendingPathComponent(pid(4).hex + ".key").path, 0o644)                    // 緩い .key
        try b.store.saveMeta(pid(5), meta().encoded())                                            // .key の無い .meta
        let l = b.load()
        XCTAssertEqual(l.entries.map(\.id), [pid(1)])
        XCTAssertEqual(Set(l.problems.map { "\($0.name.prefix(2)) \($0.reason.rawValue)" }), ["02 unreadable", "03 badFormat", "04 loosePermissions"], "\(l.problems)")
        XCTAssertEqual(book(machine: "MAC-OTHER").load().entries, [], "別の Mac の秘密は使わない")
        XCTAssertEqual(book(machine: "MAC-OTHER").load().problems.filter { $0.reason == .otherMachine }.count, 3, "緩い .key は権限の理由で先に落ちる")
    }

    func testLimitOf32IsCountedByKeysOnly() throws {
        let b = book()
        for i in 1...32 { try b.add(id: pid(UInt8(i)), secret: secret(1), meta: meta()) }
        XCTAssertTrue(b.isFull)
        chmod(viewerDir.appendingPathComponent(pid(32).hex + ".key").path, 0o644)
        XCTAssertEqual(b.load().entries.count, 31)
        XCTAssertTrue(b.isFull, "読めない .key も数える（add は上限で失敗するため）")
        chmod(viewerDir.appendingPathComponent(pid(32).hex + ".key").path, 0o600)
        XCTAssertThrowsError(try b.add(id: pid(40), secret: secret(1), meta: meta())) { XCTAssertEqual($0 as? SecretStoreError, .limitReached) }
        XCTAssertEqual(b.load().entries.count, 32)
        XCTAssertFalse(FileManager.default.fileExists(atPath: viewerDir.appendingPathComponent(pid(40).hex + ".meta").path), "上限で断った時に .meta も残さない")
        XCTAssertNoThrow(try b.update(pid(1), meta("Renamed")), "上限でも付帯情報の更新はできる")
        try b.remove(pid(1))
        XCTAssertFalse(b.isFull)
    }

    func testSelectionFallsBackToTheFirstEntry() throws {
        let b = book()
        XCTAssertNil(b.selected(in: b.load()))
        try b.add(id: pid(2), secret: secret(2), meta: meta("B"))
        try b.add(id: pid(1), secret: secret(1), meta: meta("A"))
        XCTAssertEqual(b.selected(in: b.load())?.id, pid(1), "選んでいなければ 1 件目（id の順）")
        b.selectedID = pid(2)
        XCTAssertEqual(settings.all[TargetBook.selectedKey], pid(2).hex)
        XCTAssertEqual(b.selected(in: b.load())?.id, pid(2))
        settings.set("not-hex", forKey: TargetBook.selectedKey)
        XCTAssertNil(b.selectedID); XCTAssertEqual(b.selected(in: b.load())?.id, pid(1))
        b.selectedID = pid(9)
        XCTAssertEqual(b.selected(in: b.load())?.id, pid(1), "帳簿に無い id を選んでいれば 1 件目")
        try b.add(id: pid(3), secret: secret(3), meta: meta("A"))
        XCTAssertEqual(b.load().sortedByName.map(\.id), [pid(1), pid(3), pid(2)], "表示名の順（同じ名前は id の順）")
    }
}
