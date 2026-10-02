import Combine
import XCTest
@testable import ShareScaleCore
import ShareScaleProtocol

/// 偽のクリップボード（`NSPasteboard.general` に触れない）
final class FakePasteboard: PasteboardAccess {
    var changeCount = 10
    private(set) var cleared = 0
    func clearContents() { cleared += 1; changeCount += 1 }
}

/// 試験側の合図で進む門（`open` の回数だけ `wait` が戻る）
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var permits = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            let go = lock.withLock { () -> Bool in if permits > 0 { permits -= 1; return true }; waiting.append(k); return false }
            if go { k.resume() }
        }
    }
    func open() {
        let k = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if waiting.isEmpty { permits += 1; return nil }
            return waiting.removeFirst()
        }
        k?.resume()
    }
}

/// 主スレッドの値が条件を満たすまで待つ（最大 `timeout` 秒）
@MainActor func waitOnMain(_ timeout: Double, _ cond: () -> Bool) async {
    let end = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
    while !cond(), ContinuousClock.now < end { try? await Task.sleep(nanoseconds: 10_000_000) }
}

/// 接続先の追加の窓（`AddTargetFlow` の状態の移り変わり・入力の検査の文言、`AddTargetModel` の取り消し・`onPhase` の順・クリップボード）
@MainActor
final class AddTargetFlowTests: XCTestCase {
    override func setUp() { super.setUp(); AppLanguage.current = .ja }

    let code = PairingCode(id: pid(1), secret: secret(1), port: 47651, addresses: ["studio.local"], expiresAt: 1_800_000_000)!
    var key: String { ManualEntry.encodeKey(id: pid(2), secret: secret(2)) }

    func testInputChecksAndMessages() {
        var f = AddTargetFlow()
        XCTAssertEqual(f.check, .empty); XCTAssertFalse(f.canStart)
        f.code = "hello"
        XCTAssertEqual(f.check, .invalid("接続コードは「sharescale1:」で始まります。接続先の「接続コード」ウインドウで「コピー」をクリックし、貼り付け直してください。"))
        f.code = String(code.encoded().dropLast(8))
        XCTAssertEqual(f.check, .invalid("接続コードが途中で切れているか、形式が正しくありません。接続先の「接続コード」ウインドウで「コピー」をクリックし、貼り付け直してください。"))
        f.code = "\n" + code.encoded() + " "
        XCTAssertEqual(f.check, .ready(PairingFlow.Entry(id: pid(1), secret: secret(1), port: 47651, addresses: ["studio.local"], expiresAt: 1_800_000_000)))
        XCTAssertTrue(f.canStart)
        XCTAssertNil(f.expiryWarning(now: 1_800_000_599))
        XCTAssertEqual(f.expiryWarning(now: 1_800_000_600), "この接続コードは有効期限が過ぎている可能性があります。このまま試すこともできますが、接続できない場合は接続先で新しいコードを作成してください。")
        // 手入力: 途中は理由を出さない。アドレスの誤りはすぐ、キーは 78 文字になってから
        f.tab = .manual
        XCTAssertEqual(f.check, .empty)
        f.key = "ab"
        XCTAssertEqual(f.check, .invalid("アドレスを入力してください。"), "キーより先にアドレスを求める（点検 N）")
        f.key = ""
        f.address = "fd7a::1"
        XCTAssertEqual(f.check, .invalid("IPv6 のアドレスは [ ] で囲んでください（例 [fd7a::1]:47651）。"))
        f.address = "ｓｔｕｄｉｏ．ｌｏｃａｌ:5000"
        f.key = String(key.prefix(40))
        XCTAssertEqual(f.check, .empty, "キーを打っている途中")
        f.key = key + "0"
        XCTAssertEqual(f.check, .invalid("キーの文字数が正しくありません（区切りの空白を除いて 78 文字です）。"))
        f.key = String(key.dropLast()) + (key.last == "0" ? "1" : "0")
        XCTAssertEqual(f.check, .invalid("キーに入力の誤りがあります。接続先の「接続コード」ウインドウの「キー」と 4 文字ずつ見比べてください。"))
        f.key = ManualEntry.grouped(key).lowercased()
        XCTAssertEqual(f.check, .ready(PairingFlow.Entry(id: pid(2), secret: secret(2), port: 5000, addresses: ["studio.local"], expiresAt: nil)))
        XCTAssertNil(f.expiryWarning(now: .max), "手入力には期限が無い")
        f.address = "studio:0"
        XCTAssertEqual(f.check, .invalid("ポート（「:」の後）は 1〜65535 の数字にしてください。"))
        // すべての理由は 1 文で、「！」を使わない
        let errors: [PairingFlow.InputError] = [.code(.tooLarge), .code(.notSharescale), .code(.badEncoding), .code(.badJSON), .code(.unknownOrMissingKey),
                                               .code(.badVersion), .code(.badID), .code(.badSecret), .code(.badPort), .code(.badAddresses), .code(.badExpiry),
                                               .address(.empty), .address(.badHost), .address(.badPort), .address(.ipv6NeedsBrackets),
                                               .key(.badLength), .key(.badCharacter), .key(.badPadding), .key(.checksumMismatch)]
        for lang in [AppLanguage.ja, .en] {
            AppLanguage.current = lang
            for e in errors {
                let m = AddTargetText.inputProblem(e)
                XCTAssertFalse(m.isEmpty); XCTAssertFalse(m.contains("！")); XCTAssertFalse(m.contains("!"), m)
                XCTAssertTrue(m.hasSuffix(lang == .ja ? "。" : "."), m)
            }
        }
    }

    func testKeyPreviewAndConfirmationCodeReading() {
        let p = AddTargetText.keyPreview("ａｂｃｄ-efgh ij")
        XCTAssertEqual(p.groups, ["ABCD", "EFGH", "IJ"]); XCTAssertEqual(p.count, 10)
        XCTAssertEqual(p.accessibility, ["A B C D", "E F G H", "I J"], "VoiceOver はまとまりごとに、文字を 1 つずつ")
        XCTAssertEqual(AddTargetText.keyPreview(ManualEntry.grouped(key)).count, AddTargetText.keyLength)
        XCTAssertEqual(AddTargetText.code(12345), "012 345")
        XCTAssertEqual(AddTargetText.codeAccessibility(12345), "確認番号 0 1 2 3 4 5", "数字を 1 つずつ読む")
        XCTAssertTrue(AddTargetFlow.looksPasted(old: "", new: code.encoded()))
        XCTAssertFalse(AddTargetFlow.looksPasted(old: "sharescale1:abc", new: "sharescale1:abcd"), "1 文字ずつ打った")
        XCTAssertFalse(AddTargetFlow.looksPasted(old: "", new: String(repeating: "x", count: 40)), "コードでない文字列")
    }

    func testStepsMoveForwardOnlyAndStaleRunsAreIgnored() {
        var f = AddTargetFlow()
        f.code = code.encoded()
        let (run, entry) = try! XCTUnwrap(f.start())
        XCTAssertEqual(run, 1); XCTAssertEqual(entry.id, pid(1)); XCTAssertEqual(f.step, .connecting); XCTAssertEqual(f.usedTab, .code)
        XCTAssertNil(f.start(), "進行中はもう一度始められない")
        f.receive(.awaitingApproval(code: 42), run: run)
        XCTAssertEqual(f.step, .awaitingApproval(code: 42))
        f.receive(.connecting, run: run)
        XCTAssertEqual(f.step, .awaitingApproval(code: 42), "前の段階には戻らない（主スレッドへ移す途中で順が入れ替わっても）")
        f.receive(.confirming(attempt: 2), run: run)
        f.receive(.confirming(attempt: 1), run: run)
        XCTAssertEqual(f.step, .confirming(attempt: 2))
        f.receive(.confirming(attempt: 3), run: run + 1)
        XCTAssertEqual(f.step, .confirming(attempt: 2), "別の試行の知らせは捨てる")
        f.finish(.success(.confirmed(pid(1))), run: run, name: "Mac Studio")
        XCTAssertEqual(f.step, .finished(.confirmed(pid(1), name: "Mac Studio")))
        f.receive(.confirming(attempt: 3), run: run)
        XCTAssertEqual(f.step, .finished(.confirmed(pid(1), name: "Mac Studio")), "終わった後の知らせは捨てる")
        f.retry()
        XCTAssertEqual(f.step, .finished(.confirmed(pid(1), name: "Mac Studio")), "成功の後はやり直さない（閉じるだけ）")
        XCTAssertFalse(f.cancel(), "終わった後の「やめる」は窓を閉じるだけ")
        // 失敗 → やり直す（入力は残る）→ やめる（取り消し）→ やめた
        var g = AddTargetFlow(); g.code = code.encoded()
        let r1 = g.start()!.run
        g.finish(.failure(.connection(.unreachable)), run: r1, name: nil)
        XCTAssertEqual(g.step, .finished(.failed(.connection(.unreachable))))
        g.retry()
        XCTAssertEqual(g.step, .input); XCTAssertEqual(g.code, code.encoded())
        let r2 = g.start()!.run
        XCTAssertEqual(r2, 2)
        g.finish(.failure(.connection(.unreachable)), run: r1, name: nil)
        XCTAssertEqual(g.step, .connecting, "前の試行の結果は捨てる")
        XCTAssertTrue(g.cancel())
        XCTAssertEqual(g.step, .cancelling); XCTAssertTrue(g.isRunning)
        g.receive(.awaitingApproval(code: 1), run: r2)
        XCTAssertEqual(g.step, .cancelling, "やめている途中は進み具合を出さない")
        g.finish(.failure(.cancelled), run: r2, name: nil)
        XCTAssertEqual(g.step, .finished(.cancelled)); XCTAssertFalse(g.isRunning)
        // やめた直後に保存・確定まで済んでいた（取り消しが間に合わなかった）→ 結果をそのまま出す
        var h = AddTargetFlow(); h.code = code.encoded()
        let r3 = h.start()!.run
        _ = h.cancel()
        h.finish(.success(.unconfirmed(pid(1), reason: "status failed")), run: r3, name: nil)
        XCTAssertEqual(h.step, .finished(.unconfirmed(pid(1), name: String(pid(1).hex.prefix(8)), reason: "status failed")))
        // 保存の後（確定の status を試している間）にやめた → 「やめた」とは分ける（接続先は未確定のまま帳簿に残っている）
        var k = AddTargetFlow(); k.code = code.encoded()
        let r4 = k.start()!.run
        k.receive(.confirming(attempt: 1), run: r4)
        XCTAssertTrue(k.cancel())
        k.finish(.failure(.cancelled), run: r4, name: "Mac Studio", saved: pid(1))
        XCTAssertEqual(k.step, .finished(.cancelledAfterSave(pid(1), name: "Mac Studio")))
        k.retry()
        XCTAssertEqual(k.step, .finished(.cancelledAfterSave(pid(1), name: "Mac Studio")), "保存は済んでいるので、やり直さない（閉じるだけ）")
        var k2 = AddTargetFlow(); k2.code = code.encoded()
        let r5 = k2.start()!.run
        _ = k2.cancel()
        k2.finish(.failure(.cancelled), run: r5, name: nil, saved: pid(1))
        XCTAssertEqual(k2.step, .finished(.cancelledAfterSave(pid(1), name: String(pid(1).hex.prefix(8)))), "名前が分からなければ id の先頭 8 文字")
    }

    // 保存の後にやめた時の案内: 「キャンセルしました」とは出さず、追加は済んでいること・不要なら削除できることを伝える（計画 2g の点検）
    func testResultTextForCancellationAfterSaving() {
        let r = AddTargetText.result(.cancelledAfterSave(pid(1), name: "Mac Studio"))
        XCTAssertEqual(r.text.title, "「Mac Studio」は追加されています（確認待ち）")
        XCTAssertEqual(r.text.detail, "キャンセルの前に、接続先での登録が済んでいました。不要な場合は、設定 › 接続先で削除してください。")
        XCTAssertTrue(r.isError, "注意として出す"); XCTAssertNil(r.copyable)
        XCTAssertNotEqual(r.text.title, AddTargetText.result(.cancelled).text.title, "保存の前にやめた時とは違う案内")
        XCTAssertEqual(AddTargetText.result(.cancelled).text.title, "追加をキャンセルしました")
    }

    // 確定中に「キャンセル」: 取り消しで戻った時に帳簿にその接続先が残っていれば、保存の後にやめたものとして出す。
    // 貼り付けたコードは使用済みなので、クリップボードがそのコードのままなら消す
    func testCancelWhileConfirmingIsReportedAsAddedPendingConfirmation() async {
        let confirming = Locked(false)
        let saved = Locked(false)   // 帳簿にその接続先がある（始めは無い。名乗りが承認されて保存した時に入る）
        let saves = Locked(true)    // この試行で保存まで進むか
        let runner: AddTargetModel.Runner = { _, onPhase in
            onPhase(.awaitingApproval(code: 7))
            if saves.value { saved.value = true }
            onPhase(.confirming(attempt: 1))
            confirming.value = true
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return .failure(.cancelled) }
            return .failure(.pairing(.timedOut))
        }
        let id = code.id
        var finished = 0
        let pb = FakePasteboard()
        let m = AddTargetModel(runner: runner, pasteboard: pb, names: { $0 == id && saved.value ? "Mac Studio" : nil }, onFinish: { _ in finished += 1 })
        m.paste(code.encoded())
        m.start()
        await waitFor(5) { confirming.value }
        await waitOnMain(5) { m.flow.step == .confirming(attempt: 1) }
        m.cancel()
        XCTAssertEqual(m.flow.step, .cancelling)
        await m.waitUntilFinished()
        XCTAssertEqual(m.flow.step, .finished(.cancelledAfterSave(id, name: "Mac Studio")))
        XCTAssertEqual(finished, 1, "終わりは知らせる（帳簿を読み直して、一覧に確認待ちの行を出す）")
        XCTAssertEqual(pb.cleared, 1, "保存まで済んでいるので、コードは使用済み")
        // 帳簿に無ければ（保存の前にやめた）、今までどおり「やめた」
        saved.value = false; saves.value = false
        let pb2 = FakePasteboard()
        let m2 = AddTargetModel(runner: runner, pasteboard: pb2, names: { $0 == id && saved.value ? "Mac Studio" : nil })
        m2.paste(code.encoded())
        confirming.value = false
        m2.start()
        await waitFor(5) { confirming.value }
        m2.cancel()
        await m2.waitUntilFinished()
        XCTAssertEqual(m2.flow.step, .finished(.cancelled)); XCTAssertEqual(pb2.cleared, 0)
    }

    // 始めから帳簿にある id（使用済みのコードや同じキーをもう一度入れた）でやめた時は、保存の後にやめたものと見ない:
    // 「追加をキャンセルしました」のままで、クリップボードも消さない（再点検 N1）
    func testCancelWithAnIDAlreadyInTheBookIsStillReportedAsCancelled() async {
        let started = Locked(false)
        let runner: AddTargetModel.Runner = { _, onPhase in
            onPhase(.connecting)
            started.value = true
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return .failure(.cancelled) }
            return .failure(.pairing(.timedOut))
        }
        let id = code.id
        let lookups = Locked(0)
        let pb = FakePasteboard()
        let m = AddTargetModel(runner: runner, pasteboard: pb, names: { asked in lookups.update { $0 += 1 }; return asked == id ? "Mac Studio" : nil })
        m.paste(code.encoded())
        m.start()
        XCTAssertEqual(lookups.value, 1, "始める時に、帳簿にあるかを控える")
        await waitFor(5) { started.value }
        m.cancel()
        await m.waitUntilFinished()
        XCTAssertEqual(m.flow.step, .finished(.cancelled), "この試行で保存したものではない")
        XCTAssertEqual(AddTargetText.result(.cancelled).text.title, "追加をキャンセルしました")
        XCTAssertEqual(pb.cleared, 0, "コードを使っていないので、クリップボードは消さない")
        m.retry()
        XCTAssertEqual(m.flow.step, .input, "やり直せる")
    }

    func testResultTexts() {
        XCTAssertEqual(AddTargetText.result(.confirmed(pid(1), name: "Mac Studio")).text.title, "「Mac Studio」を追加しました")
        let u = AddTargetText.result(.unconfirmed(pid(1), name: "Mac Studio", reason: "status failed: timedOut"))
        XCTAssertEqual(u.text.detail, "接続先の ShareScale Host のメニューにこの Mac が表示されているか確認し、表示されていなければペアリングし直してください。")
        XCTAssertTrue(u.isError); XCTAssertEqual(u.copyable, "status failed: timedOut", "理由は「詳細をコピー」へ")
        XCTAssertEqual(AddTargetText.result(.failed(.pairing(.notPaired))).text.detail,
                       "接続先に確認のウインドウが表示されている場合は「追加しない」をクリックしてから、新しい接続コードでペアリングし直してください。")
        XCTAssertEqual(u.text.title, "「Mac Studio」を追加しました（確認待ち）", "題名の最後の「です」だけが次の行に行かないよう短くした")
        XCTAssertEqual(AddTargetText.result(.failed(.connection(.handshakeFailed(othersUnreachable: false)))).text.title, "接続コードを使えませんでした")
        XCTAssertEqual(AddTargetText.result(.failed(.connection(.localNetworkDenied))).text.title, "ローカルネットワークへのアクセスが許可されていません")
        XCTAssertEqual(AddTargetText.result(.failed(.limitReached)).text.detail, "接続先は 32 台まで登録できます。設定 › 接続先で、使わない接続先を削除してください。")
        XCTAssertEqual(AddTargetText.result(.failed(.save("EACCES"))).copyable, "EACCES")
        XCTAssertEqual(AddTargetText.progress(.awaitingApproval(code: 1))?.detail, "接続先に同じ番号が表示されていれば、接続先で「追加する」をクリックしてください。")
        XCTAssertEqual(AddTargetText.progress(.confirming(attempt: 2))?.title, "登録を確認しています（2/3）…")
        XCTAssertNil(AddTargetText.progress(.input))
    }

    // `onPhase` は主スレッドに移して、呼ばれた順に段階を進める。成功したら貼り付けたままのクリップボードを消し、終わりを知らせる
    func testModelFollowsPhasesInOrderAndClearsTheClipboard() async throws {
        let gate = Gate()
        let runner: AddTargetModel.Runner = { entry, onPhase in
            onPhase(.connecting); await gate.wait()
            onPhase(.awaitingApproval(code: 123_456)); await gate.wait()
            onPhase(.confirming(attempt: 1)); await gate.wait()
            onPhase(.confirming(attempt: 2)); await gate.wait()
            return .success(.confirmed(entry.id))
        }
        let pb = FakePasteboard()
        var finished: [Result<PairingFlow.Outcome, PairingFlow.Failure>] = []
        let m = AddTargetModel(runner: runner, pasteboard: pb, names: { _ in "Mac Studio" }, clock: { 1_800_000_000 }, onFinish: { finished.append($0) })
        var steps: [AddTargetFlow.Step] = []
        let sub = m.$flow.map(\.step).removeDuplicates().sink { steps.append($0) }
        defer { sub.cancel() }
        m.paste(code.encoded())
        XCTAssertEqual(m.changeCountAtPaste, 10); XCTAssertEqual(m.flow.tab, .code)
        m.start()
        XCTAssertEqual(steps.last, .connecting, "「追加する」を押したらすぐ名乗り中")
        for _ in 0..<4 {   // 1 段ずつ進め、画面の段階が変わるのを待つ
            let before = steps.count
            gate.open()
            await waitOnMain(2) { steps.count > before }
        }
        await m.waitUntilFinished()
        XCTAssertEqual(steps, [.input, .connecting, .awaitingApproval(code: 123_456), .confirming(attempt: 1), .confirming(attempt: 2),
                               .finished(.confirmed(pid(1), name: "Mac Studio"))])
        XCTAssertEqual(pb.cleared, 1, "貼り付けた時のままなら消す")
        XCTAssertEqual(finished.count, 1)
    }

    func testClipboardIsKeptWhenChangedOrNotPasted() async {
        let runner: AddTargetModel.Runner = { entry, _ in .success(.unconfirmed(entry.id, reason: "x")) }
        // 貼り付けの後にクリップボードが変わった → 消さない
        let pb = FakePasteboard()
        let m = AddTargetModel(runner: runner, pasteboard: pb)
        m.setCode(code.encoded())      // ⌘V（1 回の変更でコードが入った）
        XCTAssertEqual(m.changeCountAtPaste, 10)
        pb.changeCount = 11
        m.start(); await m.waitUntilFinished()
        XCTAssertEqual(pb.cleared, 0)
        // 手入力で始めた → 消さない
        let pb2 = FakePasteboard()
        let m2 = AddTargetModel(runner: runner, pasteboard: pb2)
        m2.paste(code.encoded())
        m2.setTab(.manual); m2.setAddress("studio.local"); m2.setKey(key)
        m2.start(); await m2.waitUntilFinished()
        XCTAssertEqual(pb2.cleared, 0)
        XCTAssertEqual(m2.flow.step, .finished(.unconfirmed(pid(2), name: String(pid(2).hex.prefix(8)), reason: "x")))
        m2.setKey("")
        XCTAssertEqual(m2.flow.key, key, "入力中でなければ欄は変わらない")
        // 1 文字ずつ打った変更は貼り付けとみなさない・空にすれば控えを捨てる
        let m3 = AddTargetModel(runner: runner, pasteboard: FakePasteboard())
        m3.setCode("sharescale1:ab"); m3.setCode("sharescale1:abc")
        XCTAssertNil(m3.changeCountAtPaste)
        m3.paste(code.encoded()); m3.setCode(" ")
        XCTAssertNil(m3.changeCountAtPaste)
        // 失敗した時は消さない
        let pb4 = FakePasteboard()
        let m4 = AddTargetModel(runner: { _, _ in .failure(.pairing(.notPaired)) }, pasteboard: pb4)
        m4.paste(code.encoded()); m4.start(); await m4.waitUntilFinished()
        XCTAssertEqual(pb4.cleared, 0); XCTAssertEqual(m4.flow.step, .finished(.failed(.pairing(.notPaired))))
    }

    // ⌘V の見分け: コードの上に別のコードを貼った（選んで置き換え）→ 控える
    func testPastingACodeOverAnotherCodeIsRecorded() {
        let other = PairingCode(id: pid(3), secret: secret(3), port: 47651, addresses: ["studio.local"], expiresAt: 1_800_000_000)!.encoded()
        XCTAssertTrue(AddTargetFlow.looksPasted(old: code.encoded(), new: other), "共通の先頭（sharescale1:…）と末尾を除いた挿入部分が 20 文字以上")
        XCTAssertTrue(AddTargetFlow.looksPasted(old: "ab", new: "a" + code.encoded() + "b"), "途中への挿入も貼り付け")
        let pb = FakePasteboard()
        let m = AddTargetModel(runner: { entry, _ in .success(.confirmed(entry.id)) }, pasteboard: pb)
        m.paste(code.encoded())
        XCTAssertEqual(m.changeCountAtPaste, 10)
        pb.changeCount = 12            // 別のコードをコピーした
        m.setCode(other)               // ⌘V で欄の中身を置き換えた
        XCTAssertEqual(m.changeCountAtPaste, 12)
    }

    // ⌘V の見分け: 「sharescale1」の後に「:」を 1 文字打った → 控えない（新しい文字列は sharescale1: を含むが、挿入は 1 文字）
    func testTypingTheColonAfterThePrefixIsNotAPaste() {
        XCTAssertFalse(AddTargetFlow.looksPasted(old: "sharescale1", new: "sharescale1:"))
        XCTAssertFalse(AddTargetFlow.looksPasted(old: String(code.encoded().dropLast()), new: code.encoded()),
                       "長いコードの末尾に 1 文字（全体の長さではなく挿入部分で見る）")
        let pb = FakePasteboard()
        let m = AddTargetModel(runner: { entry, _ in .success(.confirmed(entry.id)) }, pasteboard: pb)
        m.setCode("sharescale1")
        m.setCode("sharescale1:")
        XCTAssertNil(m.changeCountAtPaste)
        m.setCode(code.encoded())                 // ⌘V
        XCTAssertEqual(m.changeCountAtPaste, 10)
        pb.changeCount = 13                       // 別のものをコピーした
        m.setCode(code.encoded() + "x")           // 長いコードに 1 文字足した
        XCTAssertEqual(m.changeCountAtPaste, 10, "1 文字の変更では控えを変えない")
    }

    // 「やめる」: 名乗りの Task を取り消し、`PairingFlow.run` が戻ってから「やめた」にする。終わりは知らせる（帳簿を読み直すため）
    func testCancelCancelsTheRunAndWaitsForItToReturn() async {
        let started = Locked(false)
        let runner: AddTargetModel.Runner = { _, onPhase in
            onPhase(.awaitingApproval(code: 7))
            started.value = true
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return .failure(.cancelled) }
            return .failure(.pairing(.timedOut))
        }
        var finished = 0
        let pb = FakePasteboard()
        let m = AddTargetModel(runner: runner, pasteboard: pb, onFinish: { _ in finished += 1 })
        m.paste(code.encoded())
        m.start()
        await waitFor(2) { started.value }
        await waitOnMain(2) { m.flow.step == .awaitingApproval(code: 7) }
        XCTAssertEqual(m.flow.step, .awaitingApproval(code: 7))
        let t0 = ContinuousClock.now
        m.cancel()
        XCTAssertEqual(m.flow.step, .cancelling)
        await m.waitUntilFinished()
        XCTAssertLessThan(secondsSince(t0), 5, "取り消しですぐ終わる（取り消しを聞かなければ 30 秒）")
        XCTAssertEqual(m.flow.step, .finished(.cancelled)); XCTAssertEqual(finished, 1); XCTAssertEqual(pb.cleared, 0)
        // 入力中の「やめる」は何もしない（窓を閉じるのは画面）
        let m2 = AddTargetModel(runner: runner, pasteboard: pb)
        m2.cancel()
        XCTAssertEqual(m2.flow.step, .input)
    }
}
