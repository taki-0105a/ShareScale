import XCTest
@testable import ShareScaleCore
import ShareScaleProtocol

/// 見る側の診断（仕様「自己診断」の順・✓／✗／?・「結果をコピー」に秘密を含めない）
final class ViewerDiagnosticsTests: XCTestCase {
    override func setUp() { AppLanguage.current = .ja }
    let entry = TargetEntry(id: pid(0xAB), secret: secret(7), meta: ViewerMeta(name: "Mac Studio", port: 47651, addresses: ["studio.local", "100.101.1.2"], lastOKAddress: "100.101.1.2", confirmed: true)!)
    func marks(_ lines: [ViewerDiagnostics.Line]) -> [ViewerDiagnostics.Mark] { lines.map(\.mark) }
    func texts(_ lines: [ViewerDiagnostics.Line]) -> [String] { lines.map { String($0.text.prefix(while: { $0 != ":" })) } }

    func testOrderAndAllOKWhenEverythingWorks() {
        let s = RemoteState(payload())
        let lines = ViewerDiagnostics.lines(target: entry, state: s, failure: nil, chosen: .x1)
        XCTAssertEqual(texts(lines), ["ローカルネットワーク", "接続", "ペアリング", "接続先の ShareScale Host", "画面共有", "仮想ディスプレイ", "表示倍率", "直近のエラー"], "仕様の順")
        XCTAssertEqual(marks(lines), Array(repeating: .ok, count: 8))
        XCTAssertTrue(lines.allSatisfy { $0.advice == nil && $0.action == nil })
    }

    func testFailuresMarkTheRightLinesWithAdvice() {
        let denied = ViewerDiagnostics.lines(target: entry, state: nil, failure: .localNetworkDenied, chosen: .x1)
        guard hasCount(denied, 8) else { return }
        XCTAssertEqual(marks(denied), [.bad, .bad, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown])
        XCTAssertTrue(denied[0].advice?.contains("プライバシーとセキュリティ") == true)
        XCTAssertEqual(denied.compactMap(\.action), [.openLocalNetworkSettings], "ローカルネットワークの設定を開くボタン（計画 2f-1 案 5）")
        XCTAssertNil(ViewerDiagnostics.Line(.ok, "x", action: .openFirewallSettings).action, "✓ の行には付けない")
        let unreachable = ViewerDiagnostics.lines(target: entry, state: nil, failure: .unreachable, chosen: .x1)
        guard hasCount(unreachable, 8) else { return }
        XCTAssertEqual(marks(unreachable), [.unknown, .bad, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown])
        XCTAssertTrue(unreachable[3].advice?.contains("診断") == true, "Host が動いているかは分からない → Host の診断へ")
        let notPaired = ViewerDiagnostics.lines(target: entry, state: nil, failure: .notPaired, chosen: .x1)
        guard hasCount(notPaired, 8) else { return }
        XCTAssertEqual(marks(notPaired)[0...3], [.ok, .ok, .bad, .unknown])
        XCTAssertTrue(notPaired[2].advice?.contains("自動では削除されません") == true)
        let mismatch = ViewerDiagnostics.lines(target: entry, state: nil, failure: .handshakeFailed(othersUnreachable: true), chosen: .x1)
        guard hasCount(mismatch, 8) else { return }
        XCTAssertEqual(marks(mismatch)[0...3], [.ok, .bad, .bad, .unknown]); XCTAssertTrue(mismatch[1].text.contains("接続できないアドレス"))
        XCTAssertEqual(marks(ViewerDiagnostics.lines(target: entry, state: nil, failure: .handshakeFailed(othersUnreachable: false), chosen: .x1)).dropFirst().first, .ok)
        let cancelled = ViewerDiagnostics.lines(target: entry, state: nil, failure: .cancelled, chosen: nil)
        guard hasCount(cancelled, 8) else { return }
        XCTAssertEqual(marks(cancelled)[0...3], [.unknown, .unknown, .unknown, .unknown])
        let fresh = ViewerDiagnostics.lines(target: entry, state: nil, failure: nil, chosen: nil)
        guard hasCount(fresh, 8) else { return }
        XCTAssertEqual(marks(fresh)[0...3], [.unknown, .unknown, .unknown, .unknown], "まだ問い合わせていない")
        var unconfirmed = entry; unconfirmed.meta.confirmed = false
        let u = ViewerDiagnostics.lines(target: unconfirmed, state: nil, failure: .unreachable, chosen: nil)
        guard hasCount(u, 8) else { return }
        XCTAssertEqual(u[2].mark, .bad); XCTAssertTrue(u[2].text.contains("確認待ち"))
        let old = ViewerDiagnostics.lines(target: entry, state: nil, failure: .unsupportedVersion, chosen: nil)
        guard hasCount(old, 8) else { return }
        XCTAssertEqual(old[3].mark, .bad); XCTAssertTrue(old[3].advice?.contains("同じバージョン") == true)
        let none = ViewerDiagnostics.lines(target: nil, state: nil, failure: nil, chosen: nil)
        guard hasCount(none, 8) else { return }
        XCTAssertEqual(marks(none)[0...2], [.unknown, .bad, .bad])
        let problems = ViewerDiagnostics.lines(target: entry, state: RemoteState(payload()), failure: nil, chosen: .x1, readProblems: 2)
        guard hasCount(problems, 9) else { return }
        XCTAssertTrue(problems[3].text.contains("2 件")); XCTAssertTrue(problems[3].advice?.contains("pairings/viewer") == true)
    }

    func testStateLinesCoverScreenSharingDisplayScaleAndLastError() {
        let noSession = ViewerDiagnostics.lines(target: entry, state: RemoteState(payload(session: false, vd: nil)), failure: nil, chosen: .x1)
        guard hasCount(noSession, 8) else { return }
        XCTAssertEqual(marks(noSession)[4...7], [.bad, .unknown, .unknown, .ok])
        let notFound = ViewerDiagnostics.lines(target: entry, state: RemoteState(payload(vd: nil)), failure: nil, chosen: .x1)
        guard hasCount(notFound, 8) else { return }
        XCTAssertEqual(marks(notFound)[5], .bad); XCTAssertTrue(notFound[5].advice?.contains("接続し直して") == true)
        let ambiguous = ViewerDiagnostics.lines(target: entry, state: RemoteState(payload(vd: nil, ambiguous: true)), failure: nil, chosen: .x1)
        guard hasCount(ambiguous, 8) else { return }
        XCTAssertEqual(marks(ambiguous)[5...6], [.bad, .unknown])
        let mismatch = ViewerDiagnostics.lines(target: entry, state: RemoteState(payload(setBy: StatusPayload.SetBy(byYou: false, at: 1))), failure: nil, chosen: .x2)
        guard hasCount(mismatch, 8) else { return }
        XCTAssertEqual(mismatch[6].mark, .bad); XCTAssertTrue(mismatch[6].text.contains("設定は 2x、実際は 1x")); XCTAssertTrue(mismatch[6].advice?.contains("ほかの接続元の Mac") == true)
        let err = ViewerDiagnostics.lines(target: entry, state: RemoteState(payload(lastError: "apply failed\u{7} (CGError 1014)")), failure: nil, chosen: .x1)
        guard hasCount(err, 8) else { return }
        XCTAssertEqual(err[7].mark, .bad); XCTAssertEqual(err[7].text, "直近のエラー: apply failed (CGError 1014)")
        XCTAssertNil(err[7].advice, "直近のエラーは、Host が記録した文をそのまま出す（特別な文に言い換えるものは無い。計画 2i）")
        // 奪い合い（ほかのアプリが倍率を何度も戻している）も、Host の `last_error` の文のまま
        let contention = ViewerDiagnostics.lines(target: entry, state: RemoteState(payload(lastError: "the scale keeps being changed back (another app may be changing it)")),
                                                 failure: nil, chosen: .x1)
        guard hasCount(contention, 8) else { return }
        XCTAssertEqual(contention[7], ViewerDiagnostics.Line(.bad, "直近のエラー: the scale keeps being changed back (another app may be changing it)"))
        let paused = ViewerDiagnostics.lines(target: entry, state: RemoteState(payload(paused: true)), failure: nil, chosen: .x1)
        guard hasCount(paused, 9) else { return }
        XCTAssertEqual(paused[4].mark, .bad); XCTAssertTrue(paused[4].text.contains("一時停止"))
    }

    // Host が照合済みの応答で断った時（一時停止中・処理中）は、接続もペアリングも通っている（計画 2i。前は「接続先に接続できていないため…」「不明」と出ていた）
    func testRefusalsCountAsReached() {
        // 一時停止で断られた（直前の状態は、一時停止の前のもの）
        let refused = ViewerDiagnostics.lines(target: entry, state: RemoteState(payload()), failure: .paused, chosen: .x1)
        guard hasCount(refused, 9) else { return }
        XCTAssertEqual(refused.map(\.text), ["ローカルネットワーク: 許可されています（またはこの macOS では不要です）", "接続: 接続できます", "ペアリング: 有効です",
                                             "接続先の ShareScale Host: 動作中", "接続先の ShareScale Host: 一時停止中", "画面共有: 接続中",
                                             "仮想ディスプレイ: 1920×997（識別情報で特定）", "表示倍率: 設定どおり（1x）", "直近のエラー: なし"])
        XCTAssertEqual(marks(refused), [.ok, .ok, .ok, .ok, .bad, .ok, .ok, .ok, .ok])
        XCTAssertEqual(refused[4].advice, "接続先の ShareScale Host のメニューで「再開」を選択してください。")
        // 取り直した後（状態が「一時停止中」）と同じ行。一時停止の行は 1 回だけ
        let after = ViewerDiagnostics.lines(target: entry, state: RemoteState(payload(paused: true)), failure: nil, chosen: .x1)
        XCTAssertEqual(refused, after)
        XCTAssertEqual(ViewerDiagnostics.lines(target: entry, state: RemoteState(payload(paused: true)), failure: .paused, chosen: .x1), after)
        // 状態をまだ知らない時: 接続・ペアリング・Host は分かる。5〜8 は不明
        let unknown = ViewerDiagnostics.lines(target: entry, state: nil, failure: .paused, chosen: .x1)
        guard hasCount(unknown, 9) else { return }
        XCTAssertEqual(marks(unknown), [.ok, .ok, .ok, .ok, .bad, .unknown, .unknown, .unknown, .unknown])
        // 処理中で断られた: 一時停止の行は出さない
        let busy = ViewerDiagnostics.lines(target: entry, state: RemoteState(payload()), failure: .busy, chosen: .x1)
        guard hasCount(busy, 8) else { return }
        XCTAssertEqual(marks(busy), Array(repeating: .ok, count: 8)); XCTAssertEqual(busy[2].text, "ペアリング: 有効です")
        let busyUnknown = ViewerDiagnostics.lines(target: entry, state: nil, failure: .busy, chosen: nil)
        guard hasCount(busyUnknown, 8) else { return }
        XCTAssertEqual(marks(busyUnknown), [.ok, .ok, .ok, .ok, .unknown, .unknown, .unknown, .unknown])
        // 接続できない失敗は、直前の状態が残っていても今までどおり（一時停止の行も出さない）
        let lost = ViewerDiagnostics.lines(target: entry, state: RemoteState(payload(paused: true)), failure: .unreachable, chosen: .x1)
        guard hasCount(lost, 8) else { return }
        XCTAssertEqual(marks(lost), [.unknown, .bad, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown])
        XCTAssertEqual(lost[2].text, "ペアリング: 登録済み（接続先に接続できていないため、確認していません）")
    }

    func testReportHasNoSecretsAndShortID() {
        let lines = ViewerDiagnostics.lines(target: entry, state: RemoteState(payload(lastError: "x")), failure: nil, chosen: .x1)
        let text = ViewerDiagnostics.report(lines, target: entry, version: "1.1.0")
        XCTAssertTrue(text.hasPrefix("ShareScale 1.1.0 接続元の Mac の診断\n接続先: Mac Studio (abababab) アドレス studio.local, 100.101.1.2 ポート 47651\n✓ ローカルネットワーク"), text)
        XCTAssertFalse(text.contains(entry.id.hex), "id は 8 桁だけ")
        XCTAssertFalse(text.contains(secret(7).base64URL), "秘密は含めない")
        XCTAssertTrue(text.contains("✗ 直近のエラー: x"))
        XCTAssertEqual(text.components(separatedBy: "\n").count, 2 + lines.count)
        XCTAssertEqual(ViewerDiagnostics.report([], target: nil, version: "1.1.0"), "ShareScale 1.1.0 接続元の Mac の診断\n接続先: なし")
        var manual = entry; manual.meta.manual = true
        XCTAssertTrue(ViewerDiagnostics.report([], target: manual, version: "1.1.0").contains("手動"))
    }
}
