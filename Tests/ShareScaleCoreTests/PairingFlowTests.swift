import Network
import XCTest
@testable import ShareScaleCore
import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// ペアリングの流れ（仕様「接続コード（検査）」「手入力」「名乗りと確認番号」「名乗りの後の確定」の見る側）。ループバックの Host で端から端まで
final class PairingFlowTests: HostViewerTestCase, @unchecked Sendable {
    var fast: PairingFlow.Settings { var s = PairingFlow.Settings(); s.connector.readyTimeout = 2; s.connector.total = 5; s.confirmInterval = 0.5; return s }   // 間隔は Host の受け側の開き直し（1 秒以内）に合わせる
    /// Host が出したコードの id・秘密・通信口で、候補だけをループバックにした入口（Host の候補 `studio.local` は試験では解決しない）
    func loopbackEntry(_ code: PairingCode) -> PairingFlow.Entry {
        PairingFlow.Entry(id: code.id, secret: code.secret, port: code.port, addresses: ["127.0.0.1"], expiresAt: code.expiresAt)
    }

    func testEntryFromCodeAndManualInputWithChecksAndExpiryNotice() throws {
        let code = try XCTUnwrap(PairingCode(id: pid(1), secret: secret(1), port: 47651, addresses: ["studio.local", "100.101.1.2"], expiresAt: 1_800_000_000))
        let e = try PairingFlow.entry(code: " " + code.encoded() + "\n").get()
        XCTAssertEqual(e, PairingFlow.Entry(id: pid(1), secret: secret(1), port: 47651, addresses: ["studio.local", "100.101.1.2"], expiresAt: 1_800_000_000))
        XCTAssertFalse(e.probablyExpired(now: 1_800_000_599)); XCTAssertTrue(e.probablyExpired(now: 1_800_000_600), "10 分以上過ぎたら注意（拒否はしない）")
        XCTAssertEqual(PairingFlow.entry(code: "hello"), .failure(.code(.notSharescale)))
        XCTAssertEqual(PairingFlow.entry(code: "sharescale1:!!"), .failure(.code(.badEncoding)))
        let key = ManualEntry.encodeKey(id: pid(2), secret: secret(2))
        let m = try PairingFlow.entry(address: "[::1]:5000", key: ManualEntry.grouped(key).lowercased()).get()
        XCTAssertEqual(m, PairingFlow.Entry(id: pid(2), secret: secret(2), port: 5000, addresses: ["::1"], expiresAt: nil))
        XCTAssertFalse(m.probablyExpired(now: .max), "手入力には期限が無い")
        XCTAssertEqual(try PairingFlow.entry(address: "ｓｔｕｄｉｏ．ｌｏｃａｌ", key: key).get().addresses, ["studio.local"], "全角は NFKC で半角に")
        XCTAssertEqual(try PairingFlow.entry(address: "studio.local", key: key).get().port, Limits.defaultPort)
        XCTAssertEqual(PairingFlow.entry(address: "", key: key), .failure(.address(.empty)))
        XCTAssertEqual(PairingFlow.entry(address: "fd7a::1", key: key), .failure(.address(.ipv6NeedsBrackets)))
        XCTAssertEqual(PairingFlow.entry(address: "studio:99999", key: key), .failure(.address(.badPort)))
        XCTAssertEqual(PairingFlow.entry(address: "studio", key: "ABCD"), .failure(.key(.badLength)))
        XCTAssertEqual(PairingFlow.entry(address: "studio", key: String(key.dropLast()) + "0"), .failure(.key(.checksumMismatch)))
    }

    // 確定を待つ間に名前を付けても、確定の書き込みで消さない（帳簿を読み直してから書く。点検 2f-1 の再点検）
    func testNameSetWhileConfirmingIsKept() async throws {
        try await startHost()
        let issued = await host.issueCode(); let code = try XCTUnwrap(issued)
        let b = book(MemoryStore())
        let r = await PairingFlow.run(loopbackEntry(code), book: b, computerName: { "MacBook" }, onPhase: { ph in
            guard ph == .confirming(attempt: 1), let m = b.load().entry(code.id)?.meta.withAlias("書斎の Mac") else { return }
            try? b.update(code.id, m)
        }, settings: fast)
        XCTAssertEqual(r, .success(.confirmed(code.id)))
        let m = try XCTUnwrap(b.load().entry(code.id)?.meta)
        XCTAssertTrue(m.confirmed)
        XCTAssertEqual(m.alias, "書斎の Mac", "確定の書き込みは読み直した帳簿に当てる")
        XCTAssertEqual(m.name, "Mac Studio")
    }

    func testPairingIsConfirmedAndOnlyTheNewSecretIsStored() async throws {
        try await startHost()
        let issued = await host.issueCode(); let code = try XCTUnwrap(issued)
        let settings = MemoryStore(); let b = book(settings)
        let phases = Locked<[PairingFlow.Phase]>([])
        let r = await PairingFlow.run(loopbackEntry(code), book: b, computerName: { "Taro's MacBook\u{7}" }, onPhase: { ph in phases.update { $0.append(ph) } }, settings: fast)
        XCTAssertEqual(r, .success(.confirmed(code.id)))
        XCTAssertEqual(host.approver.asked.map(\.name), ["Taro's MacBook"], "名前は規則で整えてから送る")
        let shown = phases.value.compactMap { if case let .awaitingApproval(code) = $0 { return code }; return nil }
        XCTAssertEqual(shown, host.approver.asked.map(\.confirmationCode), "確認番号は 1 つだけ表示され、Host の窓と一致する")
        XCTAssertEqual(phases.value.first, .connecting)
        XCTAssertEqual(phases.value.filter { if case .confirming = $0 { return true }; return false }.first, .confirming(attempt: 1))
        XCTAssertLessThanOrEqual(phases.value.filter { if case .confirming = $0 { return true }; return false }.count, 3)
        let l = b.load()
        XCTAssertEqual(l.problems, [])
        let e = try XCTUnwrap(l.entry(code.id))
        XCTAssertNotEqual(e.secret, code.secret, "保存するのは承認後の新しい秘密")
        XCTAssertTrue(e.meta.confirmed)
        XCTAssertEqual(e.meta.name, "Mac Studio", "名前は status の name")
        XCTAssertEqual(e.meta.addresses, ["studio.local"], "候補は照合済みの status の addrs")
        XCTAssertEqual(e.meta.port, Int(port))
        XCTAssertNil(e.meta.lastOKAddress, "つながった候補（127.0.0.1）が新しい候補に無ければ持たない")
        XCTAssertEqual(b.selectedID, code.id, "追加した接続先を選ぶ")
        let keyText = try String(contentsOf: viewerDir.appendingPathComponent(code.id.hex + ".key"), encoding: .utf8)
        XCTAssertFalse(keyText.contains(code.secret.base64URL), "コードの秘密は保存しない")
        await waitFor(3) { self.host.runtime.pairings[code.id]?.confirmed == true }
        XCTAssertEqual(host.runtime.pairings[code.id]?.confirmed, true, "Host 側も確定")
        let o = await host.outcomes(count: 2)
        XCTAssertEqual(o.first, .paired(codeID: code.id), "名乗りは 1 本")
        XCTAssertEqual(o.filter { $0 == .served(code.id, .status) }.count, 1, "確定の status が通るのは 1 回（受け側の開き直しの前の試みは TLS が成立しない）: \(o)")
        XCTAssertTrue(o.dropFirst().allSatisfy { $0 == .served(code.id, .status) || $0 == .handshakeFailed }, "\(o)")
    }

    // 同じ Mac の中の Host（実機確認 2026-09-30）: Host が出したそのままのコード（候補は「自分の名前.local」だけ）を貼り付けて名乗り、確定まで通る。
    // この Mac 自身の判定は差し替えた `LocalIdentity`（名前は Host の LocalHostName と同じ「studio」）。`.local` の名前解決はしない
    // （127.0.0.1 を単独で先に試し、この Mac 自身を指す候補そのものはつながない）
    func testPairingWithTheHostOnThisMacUsesLoopbackForTheOwnLocalName() async throws {
        try await startHost()
        let issued = await host.issueCode(); let code = try XCTUnwrap(issued)
        XCTAssertEqual(code.addresses, ["studio.local"], "Host の候補は自分の名前.local だけ")
        let entry = try PairingFlow.entry(code: code.encoded()).get()
        var s = fast; s.connector.localIdentity = { LocalIdentity(localHostName: "studio", addresses: []) }
        let b = book()
        let r = await PairingFlow.run(entry, book: b, computerName: { "Taro の MacBook" }, onPhase: { _ in }, settings: s)
        XCTAssertEqual(r, .success(.confirmed(code.id)))
        let e = try XCTUnwrap(b.load().entry(code.id))
        XCTAssertEqual(e.meta.addresses, ["studio.local"], "127.0.0.1 は帳簿に書かない（つなぐたびに判定する）")
        XCTAssertEqual(e.meta.lastOKAddress, "studio.local", "つながった候補は、この Mac 自身を指していた候補として持つ")
        // 帳簿の候補（status の addrs で書き換わったもの）でも同じ判定が当たる
        let st = await Connector.exchange(.status, expecting: .status, candidates: Connector.Candidates(e.meta), id: e.id, secret: e.secret, settings: s.connector)
        guard case let .success(ok) = st else { return XCTFail("\(st)") }
        XCTAssertEqual(ok.address, "studio.local")
        // 足さない場合（ほかの Mac の候補）は `ConnectorTests.testSelfPointingCandidatesAreTriedViaLoopbackFirst` で確かめる（外への通信をしないため、ここではつながない）
    }

    func testDeclinedPairingStoresNothingAndTheCodeCannotBeReused() async throws {
        try await startHost()
        host.approver.answer = false
        let issued = await host.issueCode(); let code = try XCTUnwrap(issued)
        let b = book()
        let r = await PairingFlow.run(loopbackEntry(code), book: b, computerName: { nil }, onPhase: { _ in }, settings: fast)
        XCTAssertEqual(r, .failure(.pairing(.notPaired)))
        XCTAssertEqual(host.approver.asked.map(\.name), ["Mac"], "名前が無ければ Mac")
        XCTAssertEqual(b.load().entries, [])
        XCTAssertNil(b.selectedID)
        await waitFor(3) { self.host.runtime.currentCode == nil }
        host.approver.answer = true
        let again = await PairingFlow.run(loopbackEntry(code), book: b, computerName: { nil }, onPhase: { _ in }, settings: fast)
        XCTAssertTrue(again == .failure(.connection(.handshakeFailed(othersUnreachable: false))) || again == .failure(.pairing(.notPaired)),
                      "使用済みのコード: 受け側が開き直った後は TLS が成立せず、その前なら名乗りが not_paired: \(again)")
        XCTAssertEqual(host.approver.asked.count, 1, "2 回目は確認の窓を出さない")
    }

    func testUnconfirmedWhenStatusFailsThreeTimesAndConfirmedLater() async throws {
        try await startHost()
        let issued = await host.issueCode(); let code = try XCTUnwrap(issued)
        host.localHostName.value = nil   // 候補アドレスを作れない → status は busy（名乗りは通る）
        let b = book()
        let key = ManualEntry.encodeKey(id: code.id, secret: code.secret)
        let entry = try PairingFlow.entry(address: "127.0.0.1:\(port)", key: key).get()
        let r = await PairingFlow.run(entry, book: b, computerName: { "MacBook" }, onPhase: { _ in }, settings: fast)
        guard case let .success(.unconfirmed(id, reason)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(id, code.id); XCTAssertTrue(reason.contains("busy"), reason)
        XCTAssertEqual(b.selectedID, code.id, "未確定でも選んだ接続先にする")
        let e = try XCTUnwrap(b.load().entry(code.id))
        XCTAssertFalse(e.meta.confirmed, "未確定のまま残す")
        XCTAssertEqual(e.meta.addresses, ["127.0.0.1"]); XCTAssertEqual(e.meta.lastOKAddress, "127.0.0.1"); XCTAssertEqual(e.meta.name, "127.0.0.1")
        let o = await host.outcomes(count: 4)
        XCTAssertEqual(o.count, 4, "名乗り 1 回と status 3 回: \(o)")
        XCTAssertGreaterThanOrEqual(o.filter { $0 == .served(code.id, .status) }.count, 2, "受け側が開き直った後の status は busy で断られる: \(o)")
        // 次に使う時に status が通れば確定する（TargetSession）
        host.localHostName.value = "studio"
        let session = TargetSession(book: b, entry: e, settings: fast.connector)
        let st = await session.status()
        guard case .success = st else { return XCTFail("\(st)") }
        XCTAssertEqual(b.load().entry(code.id)?.meta.confirmed, true)
    }

    func testLimitReachedDoesNotConnect() async throws {
        try await startHost()
        let b = book()
        for i in 1...32 { try b.add(id: pid(UInt8(i)), secret: secret(1), meta: ViewerMeta(name: "x", port: 1, addresses: ["a"], confirmed: true)!) }
        let entry = PairingFlow.Entry(id: pid(40), secret: secret(1), port: Int(port), addresses: ["127.0.0.1"], expiresAt: nil)
        let r = await PairingFlow.run(entry, book: b, computerName: { nil }, onPhase: { _ in }, settings: fast)
        XCTAssertEqual(r, .failure(.limitReached))
        XCTAssertEqual(host.outcomes, [], "つながない")
    }

    // 承認待ちの間に呼び出し側が取り消す → `.cancelled`。何も保存しない。Host の確認の窓は取り下げられる
    func testCancellationWhileAwaitingApprovalStoresNothing() async throws {
        try await startHost()
        host.approver.delay.value = 5
        let issued = await host.issueCode(); let code = try XCTUnwrap(issued)
        let b = book()
        let phases = Locked<[PairingFlow.Phase]>([])
        let entry = loopbackEntry(code), settings = fast
        let task = Task { await PairingFlow.run(entry, book: b, computerName: { "MacBook" }, onPhase: { ph in phases.update { $0.append(ph) } }, settings: settings) }
        await waitFor(5) { phases.value.contains { if case .awaitingApproval = $0 { return true }; return false } }
        task.cancel()
        let r = await task.value
        XCTAssertEqual(r, .failure(.cancelled))
        XCTAssertEqual(b.load().entries, [], "保存しない")
        await waitFor(5) { !self.host.approver.withdrawals.isEmpty }
        XCTAssertEqual(host.approver.withdrawals.count, 1, "見る側が閉じたので Host は確認の窓を取り下げる")
    }

    // 確定を帳簿に書けない（確定の直前に見る側のフォルダを読み取りだけにする）→ 失敗を飲み込まず `.unconfirmed(_, reason:)`（点検 H）
    func testBookWriteFailureAtConfirmationIsUnconfirmedWithReason() async throws {
        try await startHost()
        let issued = await host.issueCode(); let code = try XCTUnwrap(issued)
        let b = book()
        let folder = viewerDir.path
        let r = await PairingFlow.run(loopbackEntry(code), book: b, computerName: { "MacBook" },
                                      onPhase: { ph in if ph == .confirming(attempt: 1) { chmod(folder, 0o500) } }, settings: fast)
        chmod(folder, 0o700)
        guard case let .success(.unconfirmed(id, reason)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(id, code.id)
        XCTAssertTrue(reason.hasPrefix("could not write the book"), reason)
        XCTAssertEqual(b.load().entry(code.id)?.meta.confirmed, false, "確定を書けなかったので未確定のまま残る")
        XCTAssertEqual(b.selectedID, code.id)
        await waitFor(3) { self.host.runtime.pairings[code.id]?.confirmed == true }
        XCTAssertEqual(host.runtime.pairings[code.id]?.confirmed, true, "status は通っている（Host 側は確定）")
    }

    // 確定の status の 1 回ごとの候補の試行は `confirmTotal` で打ち切る（`readyTimeout` 5 秒を待たない）。
    // 名乗りは `::1` の中継を通し、確定に入ったら中継を黒穴に変える
    func testConfirmationAttemptsAreCutByConfirmTotal() async throws {
        try await startHost()
        let relay = try LoopbackRelay(port: port, role: .relay(delay: 0)); defer { relay.stop() }
        let issued = await host.issueCode(); let code = try XCTUnwrap(issued)
        let b = book()
        var s = fast; s.connector.readyTimeout = 5; s.connector.total = 10; s.confirmTotal = 0.3; s.confirmInterval = 0.2
        let entry = PairingFlow.Entry(id: code.id, secret: code.secret, port: code.port, addresses: ["::1"], expiresAt: code.expiresAt)
        let confirmStart = Locked<ContinuousClock.Instant?>(nil)
        let r = await PairingFlow.run(entry, book: b, computerName: { "MacBook" }, onPhase: { ph in
            if ph == .confirming(attempt: 1) { relay.role = .blackHole; confirmStart.value = .now }
        }, settings: s)
        let start = try XCTUnwrap(confirmStart.value)
        let elapsed = secondsSince(start)
        guard case let .success(.unconfirmed(id, reason)) = r else { return XCTFail("\(r)") }
        await waitFor(2) { relay.accepted >= 4 }   // 中継が最後の接続を受け付けるまで（数えるのは中継の側で、少し遅れることがある）
        XCTAssertEqual(id, code.id)
        XCTAssertTrue(reason.contains("timedOut"), reason)
        XCTAssertGreaterThanOrEqual(elapsed, 1.1, "3 回×0.3 秒＋間の 0.2 秒と 0.6 秒")
        XCTAssertLessThan(elapsed, 4.5, "1 回ごとに 0.3 秒で打ち切る（5 秒の readyTimeout を待たない。3 回とも待てば 15 秒を超える）")
        XCTAssertEqual(relay.accepted, 4, "名乗り 1 本＋確定の 3 回")
    }

    // ---- 確定の猶予と、Host の受け側の開き直し（計画 2g）----

    // 確定を試す間は 1 秒・3 秒と広げる（保存から 0・1・4 秒）。最後の試みまでの 4 秒は、Host の受け側の開き直しの最悪の時間
    // （まとめる窓 0.2 秒＋閉じ終えるのを待つ上限 1 秒＋「使用中」の時の 1 回目のやり直し 1 秒）より 1.5 秒以上長い
    func testConfirmationWindowOutlastsTheHostReopenWorstCase() {
        let s = PairingFlow.Settings.standard
        XCTAssertEqual(s.confirmAttempts, 3, "画面の「（n/3）」と合う")
        XCTAssertEqual((2...3).map { s.confirmWait(before: $0) }, [1, 3])
        XCTAssertEqual(s.confirmWindow, 4)
        XCTAssertEqual(ListenerSupervisor.standardReopenWorstCase, 2.2, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(s.confirmWindow, ListenerSupervisor.standardReopenWorstCase + 1.5,
                                    "Host が重くて開き直しが遅れても、最後の試みが開き直しの後になる")
        var one = PairingFlow.Settings(); one.confirmAttempts = 1
        XCTAssertEqual(one.confirmWindow, 0, "1 回だけなら待たない")
        var quick = PairingFlow.Settings(); quick.confirmInterval = 0.2; quick.confirmAttempts = 4
        XCTAssertEqual(quick.confirmWindow, 0.2 + 0.6 + 1.0, accuracy: 0.001)
    }

    // Host の受け側の開き直しが遅れて、保存から 3 秒はつながらない場合でも、製品の既定の猶予（0・1・4 秒）の中で確定する。
    // 開き直しの間は `::1` の中継が「受け付けてすぐ閉じる」役をし、その時刻を過ぎて受け付けた接続だけを Host へ流す。
    // 1 秒おきに 3 回（0・1・2 秒）のままだと、3 回とも外れて未確定になる（直す前の形で確かめた）
    func testHostReopeningSlowlyIsStillConfirmedWithinTheWindow() async throws {
        try await startHost()
        let relay = try LoopbackRelay(port: port, role: .relay(delay: 0)); defer { relay.stop() }
        let issued = await host.issueCode(); let code = try XCTUnwrap(issued)
        let b = book()
        var s = PairingFlow.Settings(); s.connector.total = 10   // 確定の回数と間は製品の既定のまま
        let entry = PairingFlow.Entry(id: code.id, secret: code.secret, port: code.port, addresses: ["::1"], expiresAt: code.expiresAt)
        let phases = Locked<[PairingFlow.Phase]>([])
        let r = await PairingFlow.run(entry, book: b, computerName: { "MacBook" }, onPhase: { ph in
            phases.update { $0.append(ph) }
            if ph == .confirming(attempt: 1) { relay.role = .closedUntil(.now + .seconds(3)) }
        }, settings: s)
        XCTAssertEqual(r, .success(.confirmed(code.id)), "開き直しに 3 秒かかっても、3 回目（4 秒）で確定する")
        XCTAssertEqual(phases.value.filter { if case .confirming = $0 { return true }; return false },
                       [.confirming(attempt: 1), .confirming(attempt: 2), .confirming(attempt: 3)])
        XCTAssertEqual(b.load().entry(code.id)?.meta.confirmed, true)
        await waitFor(5) { self.host.runtime.pairings[code.id]?.confirmed == true }
        XCTAssertEqual(host.runtime.pairings[code.id]?.confirmed, true, "Host 側も確定")
        let o = await host.outcomes(count: 2)
        XCTAssertEqual(o, [.paired(codeID: code.id), .served(code.id, .status)], "開き直しの間に断られた試みは Host まで届かない（失敗に数えない）")
    }

    // 開き直しが猶予より長くかかって 3 回とも外れた時: 未確定のまま残る（消さない）。受け側が無い間に断られた試みは Host まで届かないので、
    // 「失敗」に数えられず、締め出しに近づかない（古い受け側に当たった試みだけが TLS の失敗 1 件になる。ここでは中継が 3 回とも断る）。
    // 追加の窓には「確認待ち」の注意が出る。開き直した後の次の `status`（接続先を切り替えた時の取り直し・その後の取り直し）で、両側とも確定する
    func testReopenSlowerThanTheWindowStaysUnconfirmedAndTheNextStatusConfirms() async throws {
        try await startHost()
        let relay = try LoopbackRelay(port: port, role: .relay(delay: 0)); defer { relay.stop() }
        let issued = await host.issueCode(); let code = try XCTUnwrap(issued)
        let b = book()
        var s = fast; s.confirmInterval = 0.2
        let entry = PairingFlow.Entry(id: code.id, secret: code.secret, port: code.port, addresses: ["::1"], expiresAt: code.expiresAt)
        let r = await PairingFlow.run(entry, book: b, computerName: { "MacBook" }, onPhase: { ph in
            if ph == .confirming(attempt: 1) { relay.role = .reject }
        }, settings: s)
        guard case let .success(.unconfirmed(id, reason)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(id, code.id); XCTAssertTrue(reason.hasPrefix("status failed"), reason)
        let e = try XCTUnwrap(b.load().entry(code.id), "消さずに残す")
        XCTAssertFalse(e.meta.confirmed)
        XCTAssertEqual(b.selectedID, code.id, "未確定でも選んだ接続先にする（切り替えの取り直しが、次の status になる）")
        await waitFor(5) { self.host.runtime.pairings[code.id] != nil }   // Host の付帯情報は、別の列で後から書かれる
        XCTAssertEqual(host.runtime.pairings[code.id]?.confirmed, false, "Host 側は確認待ち（10 分の間に status が通れば確定する）")
        await waitFor(3) { relay.accepted >= 4 }
        XCTAssertEqual(relay.accepted, 4, "名乗り 1 本＋確定の 3 回")
        XCTAssertEqual(host.outcomes, [.paired(codeID: code.id)], "断られた 3 回は Host の結末にならない（失敗に数えない）")
        let text = AddTargetText.result(.unconfirmed(code.id, name: "Mac Studio", reason: reason))
        XCTAssertTrue(text.isError, "追加の窓は注意として出す"); XCTAssertEqual(text.copyable, reason)
        // 開き直しが済んだ後の次の status
        relay.role = .relay(delay: 0)
        let st = await TargetSession(book: b, entry: e, settings: s.connector).status()
        guard case .success = st else { return XCTFail("\(st)") }
        XCTAssertEqual(b.load().entry(code.id)?.meta.confirmed, true, "見る側が確定")
        await waitFor(5) { self.host.runtime.pairings[code.id]?.confirmed == true }
        XCTAssertEqual(host.runtime.pairings[code.id]?.confirmed, true, "Host 側も確定")
    }
}
