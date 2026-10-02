import XCTest
@testable import ShareScaleCore
import ShareScaleNet
import ShareScaleProtocol

/// 接続先の一覧の行（`TargetRow`）と候補の手直し（`ManualCandidatesEditor`）
final class TargetListTests: XCTestCase {
    override func setUp() { super.setUp(); AppLanguage.current = .ja }

    func meta(_ name: String, confirmed: Bool = true, manual: Bool = false, last: String? = nil, addrs: [String] = ["studio.local", "100.101.1.2"]) -> ViewerMeta {
        ViewerMeta(name: name, port: 47651, addresses: addrs, manual: manual, lastOKAddress: last, confirmed: confirmed)!
    }

    func testRowsShowStatusWithSymbolAndTextSortedByName() {
        var l = TargetBook.Loaded()
        l.entries = [TargetEntry(id: pid(1), secret: secret(1), meta: meta("Studio", last: "100.101.1.2")),
                     TargetEntry(id: pid(2), secret: secret(2), meta: meta("Air", confirmed: false, manual: true, addrs: ["10.0.0.5"])),
                     TargetEntry(id: pid(3), secret: secret(3), meta: meta(""))]
        let rows = TargetRow.rows(l, selectedID: pid(1))
        XCTAssertEqual(rows.map(\.name), [String(pid(3).hex.prefix(8)), "Air", "Studio"], "表示名の順（名前が空なら id の先頭 8 文字）")
        XCTAssertEqual(rows.map(\.selected), [false, false, true])
        guard hasCount(rows, 3) else { return }
        let studio = rows[2]
        XCTAssertEqual(studio.symbol, "checkmark.circle"); XCTAssertEqual(studio.status, "登録済み")
        XCTAssertEqual(studio.lastOK, "前回の接続: 100.101.1.2")
        XCTAssertEqual(studio.candidates, "接続先のアドレス: studio.local, 100.101.1.2（ポート 47651）")
        XCTAssertEqual(studio.accessibilityLabel, "Studio、使用中、登録済み、前回の接続: 100.101.1.2")
        let air = rows[1]
        XCTAssertEqual(air.symbol, "exclamationmark.triangle"); XCTAssertEqual(air.status, "確認待ち", "色だけで示さない（記号と文字）")
        XCTAssertEqual(air.lastOK, "まだ接続していません")
        XCTAssertEqual(air.candidates, "接続先のアドレス（手動で設定）: 10.0.0.5（ポート 47651）")
        XCTAssertEqual(air.removeConfirmation.title, "「Air」を削除しますか？")
        // 選んだものが帳簿に無ければ 1 件目（id の順）を使う
        XCTAssertEqual(TargetRow.rows(l, selectedID: pid(9)).filter(\.selected).map(\.id), [pid(1)])
        XCTAssertEqual(TargetRow.rows(l, selectedID: nil).filter(\.selected).map(\.id), [pid(1)])
        XCTAssertEqual(TargetRow.rows(TargetBook.Loaded(), selectedID: nil), [])
        // 削除の結果の文言
        XCTAssertEqual(TargetRemoval.removedLocally(name: "Air").message.detail, "接続先に接続できなかったため、接続先の ShareScale Host のメニューでも、この Mac の登録を解除してください。")
        XCTAssertTrue(TargetRemoval.removedLocally(name: "Air").isError); XCTAssertFalse(TargetRemoval.removed(name: "Air").isError)
        // 生の理由は本文に出さず「詳細をコピー」へ（点検 E）
        let failed = TargetRemoval.failed(name: "Air", reason: "EACCES")
        XCTAssertEqual(failed.message.detail, "~/Library/Application Support/ShareScale/pairings/viewer/ のアクセス権を確認してから、もう一度削除してください。")
        XCTAssertFalse(failed.message.detail.contains("EACCES")); XCTAssertEqual(failed.copyable, "EACCES")
        XCTAssertEqual(TargetRemoval.alreadyRemoved.message.title, "この接続先はすでに削除されています", "対象が無い時に「「」を削除できませんでした」と出さない")
        XCTAssertFalse(TargetRemoval.alreadyRemoved.isError); XCTAssertNil(TargetRemoval.alreadyRemoved.copyable)
    }

    func testManualCandidatesAreCheckedAndMarkedManual() throws {
        let original = meta("Studio", last: "100.101.1.2")
        var e = ManualCandidatesEditor(original)
        XCTAssertEqual(e.addressesText, "studio.local\n100.101.1.2"); XCTAssertEqual(e.portText, "47651")
        // 行・カンマ区切り、全角は半角に、IPv6 は角括弧を外して書き直した形、同じものは 1 件
        e.addressesText = " ｓｔｕｄｉｏ．ｌｏｃａｌ \n\n[FD7A:0:0:0:0:0:0:1], 100.101.1.2\nstudio.local"
        e.portText = "５０００"
        let c = try e.validate().get()
        XCTAssertEqual(c, ManualCandidatesEditor.Candidates(addresses: ["studio.local", "fd7a::1", "100.101.1.2"], port: 5000, manual: true),
                       "返すのは候補・通信口・手で直した印の 3 つだけ")
        let m = try XCTUnwrap(c.applied(to: original))
        XCTAssertTrue(m.manual, "手で直した印"); XCTAssertEqual(m.name, "Studio"); XCTAssertTrue(m.confirmed)
        XCTAssertEqual(m.lastOKAddress, "100.101.1.2", "前回の候補は残っていれば持つ")
        e.addressesText = "studio.local"
        XCTAssertNil(try e.validate().get().applied(to: original)?.lastOKAddress, "候補から外れたら持たない")
        e.portText = ""
        XCTAssertEqual(try e.validate().get().port, 47651, "空なら既定の通信口")
        // 断る
        e.portText = "70000"
        XCTAssertEqual(e.validate(), .failure(.badPort))
        e.portText = "47651"; e.addressesText = "\n \n"
        XCTAssertEqual(e.validate(), .failure(.empty))
        e.addressesText = "studio.local\n\n  ,\n0x7f.1"
        XCTAssertEqual(e.validate(), .failure(.badAddress(line: 2, text: "0x7f.1")), "空白だけの項目は数えない（点検 U）")
        e.addressesText = "fe80::1%en0"
        XCTAssertEqual(e.validate(), .failure(.badAddress(line: 1, text: "fe80::1%en0")), "ゾーンは付けられない")
        e.addressesText = "010.1.1.1"
        XCTAssertEqual(e.validate(), .failure(.badAddress(line: 1, text: "010.1.1.1")))
        e.addressesText = (1...9).map { "10.0.0.\($0)" }.joined(separator: "\n")
        XCTAssertEqual(e.validate(), .failure(.tooMany(9)))
        XCTAssertEqual(ManualCandidatesEditor.message(.badAddress(line: 2, text: "0x7f.1")),
                       "2 番目の「0x7f.1」はアドレスとして使えません。ホスト名（例: studio.local）か IP アドレスを入力してください。")
        XCTAssertEqual(ManualCandidatesEditor.message(.tooMany(9)), "アドレスは 8 個まで入力できます（今は 9 個）。")
        XCTAssertEqual(ManualCandidatesEditor.message(.invalid), "アドレスの形式が正しくありません。ホスト名か IP アドレスを 1 行に 1 つずつ入力してください。")
        // 接続先に任せる（手で直した印を外す。候補は今のまま）
        let auto = ManualCandidatesEditor(meta("Studio", manual: true, addrs: ["10.0.0.5"])).automatic
        XCTAssertFalse(auto.manual); XCTAssertEqual(auto.addresses, ["10.0.0.5"])
    }
}
