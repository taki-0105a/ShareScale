import XCTest
@testable import ShareScaleCore
import ShareScaleProtocol

/// 見る側の判断（`ViewerModel`・`ViewerNotice`）: 取り直しと切り替え・案内の優先順・カードのバッジ・見出しとフッタ・接続先の切り替え・英語
@MainActor
final class ViewModelTests: XCTestCase {
    private var now = ContinuousClock.now
    // 実行する Mac の言語設定に左右されないよう固定する
    override func setUp() { AppLanguage.current = .ja }

    private func make(_ studio: FakeTarget, displays: [LocalDisplay] = [lg, builtIn]) -> ViewerModel {
        ViewerModel(client: studio, displays: { displays }, targetLabel: "studio", clock: { [unowned self] in self.now })
    }

    func testRefreshStoresState() async {
        let vm = make(FakeTarget(.success(connected())))
        await vm.refresh()
        XCTAssertEqual(vm.state?.mode, .x1)
        XCTAssertNil(vm.failure)
        XCTAssertFalse(vm.busy)
        XCTAssertTrue(vm.hasTarget)
    }

    // バグ5: 起動時に「表示されたとき」と「前面に来たとき」の2経路から取得が走る
    func testRefreshesInQuickSuccessionAreCoalesced() async {
        let studio = FakeTarget(.success(connected()))
        let vm = make(studio)
        await vm.refresh()
        await vm.refresh()
        XCTAssertEqual(studio.statusCalls, 1, "直後の2回目は通信しない")
        now += .seconds(5)
        await vm.refresh()
        XCTAssertEqual(studio.statusCalls, 2, "時間が経てば取り直す（スリープ中も進む時計）")
    }

    func testForcedRefreshIgnoresCoalescing() async {
        let studio = FakeTarget(.success(connected()))
        let vm = make(studio)
        await vm.refresh()
        await vm.refresh(force: true)
        XCTAssertEqual(studio.statusCalls, 2, "更新ボタンは必ず取り直す")
    }

    func testApplySendsModeAndStoresReturnedState() async {
        let studio = FakeTarget(.success(connected(mode: .x1)))
        studio.setResult = .success(connected(mode: .x2, scaling: .x2))
        let vm = make(studio)
        await vm.apply(.x2)
        XCTAssertEqual(studio.setCalls, [.x2])
        XCTAssertEqual(vm.state?.mode, .x2)
    }

    func testFailureIsShownAndCardsAreNotActive() async {
        let vm = make(FakeTarget(.failure(.unreachable)))
        await vm.refresh()
        XCTAssertEqual(vm.failure, .unreachable)
        XCTAssertFalse(vm.isActive(lg))
        XCTAssertEqual(vm.notice?.title, "接続先に接続できません")
        XCTAssertTrue(vm.notice?.detail.contains("studio") == true, "接続先の名前を出す")
        XCTAssertTrue(vm.notice?.detail.contains("診断") == true, "接続先の Host の診断も確かめてもらう")
        XCTAssertTrue(vm.suggestsSettings)
        XCTAssertEqual(vm.connection, .failed)
    }

    // 届かない時に確認することは 1 か所の定義で、ファイアウォールの手がかりを含む（計画 2i。実機確認 B: 接続先でファイアウォールの確認が
    // 出ている間、「接続先を追加」は「接続できません」で止まり、案内にファイアウォールの手がかりが無かった）
    func testUnreachableChecksNameTheFirewallEverywhere() async {
        let hint = "接続先の Mac のファイアウォールで、ShareScale Host への接続が許可されているかどうかも確認してください（接続先の Mac の ShareScale Host の「診断」で確認できます）。"
        XCTAssertEqual(ViewerNotice.firewallHint, hint)
        let named = "2 台の Mac が同じネットワーク（または Tailscale）に接続されているか、「studio」で ShareScale Host が動作しているかを確認してください。" + hint
        let unnamed = "2 台の Mac が同じネットワーク（または Tailscale）に接続されているか、接続先で ShareScale Host が動作しているかを確認してください。" + hint
        XCTAssertEqual(ViewerNotice.unreachableChecks(hostName: "studio"), named, "2 文。日本語の文と文の間に空白を入れない")
        XCTAssertEqual(ViewerNotice.unreachableChecks(hostName: nil), unnamed)
        // 主の窓の案内
        let vm = make(FakeTarget(.failure(.unreachable)))
        await vm.refresh()
        XCTAssertEqual(vm.notice, ViewerNotice.Text("接続先に接続できません", named))
        // ほかの VPN の疑いは、その後に続ける
        let vpn = ViewerNotice.forFailure(.unreachable, targetName: "studio", unconfirmed: false, vpnSuspected: true)
        XCTAssertEqual(vpn?.detail, named + "ほかの VPN（Surfshark など）や exit node が通信経路を使っているようです。その VPN を切断するか、Tailscale の通信（100.64.0.0/10）を VPN の対象外にしてください。")
        // 「接続先を追加」の結果（届かない・つなぐ途中の時間切れ）: 同じ見出し、同じ確認すること
        for f in [ViewerFailure.unreachable, .timedOut] {
            let r = AddTargetText.result(.failed(.connection(f)))
            XCTAssertEqual(r.text, ViewerNotice.Text("接続先に接続できません", unnamed), "\(f)")
            XCTAssertTrue(r.isError); XCTAssertNil(r.copyable)
        }
        // 診断の「接続」の行の対処も、同じ文で終わる
        let entry = TargetEntry(id: pid(1), secret: secret(1), meta: ViewerMeta(name: "S", port: 1, addresses: ["a"], confirmed: true)!)
        let line = ViewerDiagnostics.lines(target: entry, state: nil, failure: .unreachable, chosen: nil)[1]
        XCTAssertEqual(line.text, "接続: 接続できません")
        XCTAssertEqual(line.advice, "同じネットワーク（または Tailscale）に接続されているか、接続先のアドレスとポートが正しいかを確認してください。" + hint)
        // ファイアウォールの手がかりを出すのは、届かない時だけ（ほかの失敗の案内・診断の行には出さない）
        for f in [ViewerFailure.localNetworkDenied, .handshakeFailed(othersUnreachable: true), .notPaired, .unsupportedVersion, .paused, .busy, .timedOut, .other("x")] {
            XCTAssertFalse(ViewerNotice.forFailure(f, targetName: "studio", unconfirmed: false, vpnSuspected: true)?.detail.contains("ファイアウォール") ?? true, "\(f)")
            for l in ViewerDiagnostics.lines(target: entry, state: nil, failure: f, chosen: nil) { XCTAssertFalse(l.advice?.contains("ファイアウォール") ?? false, "\(f)") }
        }
        for f in [ViewerFailure.localNetworkDenied, .handshakeFailed(othersUnreachable: false), .notPaired, .other("x")] {
            XCTAssertFalse(AddTargetText.result(.failed(.connection(f))).text.detail.contains("ファイアウォール"), "\(f)")
        }
        // 英語: 文と文の間は空白 1 つ
        AppLanguage.current = .en
        let enHint = "Also make sure the Host’s firewall allows incoming connections to ShareScale Host (see ShareScale Host’s Diagnostics on the Host)."
        XCTAssertEqual(ViewerNotice.unreachableChecks(hostName: "studio"),
                       "Make sure both Macs are on the same network (or Tailscale) and that ShareScale Host is running on “studio”. " + enHint)
        XCTAssertEqual(AddTargetText.result(.failed(.connection(.unreachable))).text,
                       ViewerNotice.Text("Can’t connect to the Host", "Make sure both Macs are on the same network (or Tailscale) and that ShareScale Host is running on the Host. " + enHint))
        XCTAssertEqual(ViewerNotice.forFailure(.unreachable, targetName: "studio", unconfirmed: false, vpnSuspected: true)?.detail,
                       "Make sure both Macs are on the same network (or Tailscale) and that ShareScale Host is running on “studio”. " + enHint
                       + " Another VPN (such as Surfshark) or an exit node seems to be routing your traffic. Disconnect it, or exclude Tailscale traffic (100.64.0.0/10) from that VPN.")
        XCTAssertEqual(ViewerDiagnostics.lines(target: entry, state: nil, failure: .unreachable, chosen: nil)[1].advice,
                       "Make sure both Macs are on the same network (or Tailscale), and that the Host’s addresses and port are correct. " + enHint)
        AppLanguage.current = .ja
    }

    // バグ3: 想定外のエラーで生のエラー文を画面に出さない
    func testUnexpectedErrorDoesNotShowRawText() async {
        let raw = "malformedResponse: {\"v\":1"
        let vm = make(FakeTarget(.failure(.other(raw))))
        await vm.refresh()
        let n = try! XCTUnwrap(vm.notice)
        XCTAssertFalse(n.title.contains(raw))
        XCTAssertFalse(n.detail.contains(raw), "生のエラー文は出さない")
        XCTAssertEqual(vm.failureDetail, raw, "調査用には残す")
        XCTAssertEqual(vm.copyableDetail, raw)
        XCTAssertFalse(vm.suggestsSettings)
    }

    func testActiveCardFollowsMode() async {
        let vm = make(FakeTarget(.success(connected(mode: .x1))))
        await vm.refresh()
        XCTAssertTrue(vm.isActive(lg))
        XCTAssertFalse(vm.isActive(builtIn))
        XCTAssertEqual(vm.badge(for: builtIn), .none, "内蔵画面は既定で 2x を選ぶので、今の 1x とは別")
    }

    func testSettingTextUsesVirtualDisplaySize() async {
        let vm = make(FakeTarget(.success(connected())))
        await vm.refresh()
        XCTAssertEqual(vm.settingText(for: lg), "1920×997 · 1x")
        XCTAssertEqual(vm.settingText(for: builtIn), "3840×1994 · 2x")
    }

    func testSettingTextWithoutVirtualDisplay() async {
        let vm = make(FakeTarget(.success(RemoteState(payload(session: false, vd: nil)))))
        await vm.refresh()
        XCTAssertEqual(vm.settingText(for: lg), "1x", "値は等幅で出すので、注記は別に持つ")
        XCTAssertEqual(vm.settingNote(for: lg), "（接続後に適用）")
    }

    // 「（接続後に適用）」は、接続先が保っている倍率とこのカードで選んだ倍率が同じカード（バッジが「選択中」）だけ（点検 2f-1）
    func testSettingNoteOnlyOnTheCardWhoseScaleTheHostKeeps() async {
        let vm = make(FakeTarget(.success(RemoteState(payload(session: false, mode: .twoX, vd: nil)))))
        await vm.refresh()
        XCTAssertNil(vm.settingNote(for: lg), "1x を選んだカードはクリックしないと適用されない")
        XCTAssertEqual(vm.settingNote(for: builtIn), "（接続後に適用）"); XCTAssertEqual(vm.badge(for: builtIn), .selected)
        let off = make(FakeTarget(.success(RemoteState(payload(session: false, mode: .off, vd: nil)))))
        await off.refresh()
        XCTAssertNil(off.settingNote(for: lg), "自動調整がオフなら付けない")
    }

    func testNoticePriority() async {
        func notice(_ p: StatusPayload) async -> String? {
            let vm = make(FakeTarget(.success(RemoteState(p))))
            await vm.refresh()
            return vm.notice?.title
        }
        let none = await notice(payload())
        XCTAssertNil(none)
        let paused = await notice(payload(paused: true, ambiguous: true))
        XCTAssertEqual(paused, "接続先が一時停止中です")
        // 奪い合い（ほかのアプリが倍率を何度も戻している）は、Host の `last_error` に載って来る。特別な案内にはせず、切り替えの失敗として出す
        // （計画 2i で、ほかの常駐との競合の固定文と、その案内を外した）
        let contention = await notice(payload(ambiguous: true, lastError: "the scale keeps being changed back (another app may be changing it)"))
        XCTAssertEqual(contention, "接続先で表示倍率を切り替えられませんでした")
        let notFound = await notice(payload(vd: nil))
        XCTAssertEqual(notFound, "仮想ディスプレイが見つかりません")
        let ambiguous = await notice(payload(vd: nil, ambiguous: true))
        XCTAssertEqual(ambiguous, "仮想ディスプレイを特定できません")
        let noSession = await notice(payload(session: false, setBy: StatusPayload.SetBy(byYou: false, at: 1)))
        XCTAssertEqual(noSession, "画面共有を始めると、自動で 1x 等倍に切り替わります", "未接続の案内は結果を書く（計画 2f-1 案 4）")
        let other = await notice(payload(setBy: StatusPayload.SetBy(byYou: false, at: 1)))
        XCTAssertEqual(other, "ほかの接続元の Mac が表示倍率を変更しました")
        let you = await notice(payload(setBy: StatusPayload.SetBy(byYou: true, at: 1)))
        XCTAssertNil(you)
    }

    // 計画 2f-1 案 4: 画面共有が未接続の時は「一度選べば自動」を結果の文で伝える（接続先が保っている倍率。この Mac の選択が違えばカードを案内する）
    func testNotConnectedNoticeTellsWhatHappensWhenScreenSharingStarts() async {
        func notice(_ p: StatusPayload, displays: [LocalDisplay] = [lg]) async -> ViewerNotice.Text? {
            let vm = make(FakeTarget(.success(RemoteState(p))), displays: displays)
            await vm.refresh()
            return vm.notice
        }
        let same = await notice(payload(session: false, mode: .oneX, vd: nil))
        XCTAssertEqual(same, ViewerNotice.Text("画面共有を始めると、自動で 1x 等倍に切り替わります", "表示倍率は保存されているため、接続のたびに選び直す必要はありません。"))
        let differs = await notice(payload(session: false, mode: .twoX, vd: nil))
        XCTAssertEqual(differs?.title, "画面共有を始めると、自動で 2x Retina に切り替わります", "倍率は接続先が保っているもの（最後に選ばれたもの）")
        XCTAssertEqual(differs?.detail, "表示倍率は保存されているため、接続のたびに選び直す必要はありません。この Mac の設定（1x 等倍）にするには、カードをクリックしてください。")
        let other = await notice(payload(session: false, mode: .twoX, vd: nil, setBy: StatusPayload.SetBy(byYou: false, at: 1)))
        XCTAssertTrue(other?.detail.hasPrefix("ほかの接続元の Mac が最後に選んだ表示倍率です。") == true, "ほかの Mac が選んだ時はその旨")
        let two = await notice(payload(session: false, mode: .oneX, vd: nil), displays: [lg, builtIn])
        XCTAssertTrue(two?.detail.hasSuffix("別のディスプレイで画面共有を使う時は、そのディスプレイのカードをクリックしてください。") == true, "ディスプレイごとに違う倍率を選んでいる時")
        let off = await notice(payload(session: false, mode: .off, vd: nil))
        XCTAssertEqual(off?.title, "画面共有を始めても、表示倍率は自動では変わりません")
        let connectedOther = await notice(payload(setBy: StatusPayload.SetBy(byYou: false, at: 1)))
        XCTAssertEqual(connectedOther?.detail, "最後に変更した設定が有効です。カードをクリックすると、この Mac の設定に戻せます。", "接続中の文は変えない")
    }

    // A: 「適用中」は実際に仮想ディスプレイの倍率が一致しているときだけ。保存しただけなら「選択中」
    func testAppliedRequiresMatchingVirtualDisplay() async {
        let vm = make(FakeTarget(.success(connected(mode: .x1, scaling: .x1))))
        await vm.refresh()
        XCTAssertEqual(vm.badge(for: lg), .applied)
    }

    func testSelectedButNotConnectedIsNotApplied() async {
        let vm = make(FakeTarget(.success(RemoteState(payload(session: false, vd: nil)))))
        await vm.refresh()
        XCTAssertEqual(vm.badge(for: lg), .selected, "未接続では保存されているだけ")
    }

    func testSelectedButAmbiguousIsNotApplied() async {
        let vm = make(FakeTarget(.success(RemoteState(payload(vd: nil, ambiguous: true)))))
        await vm.refresh()
        XCTAssertEqual(vm.badge(for: lg), .selected)
    }

    func testSelectedButScalingNotYetMatchingIsNotApplied() async {
        // モードは 1x に保存済みだが、Host がまだ反映していない（2x のまま）
        let vm = make(FakeTarget(.success(connected(mode: .x1, scaling: .x2))))
        await vm.refresh()
        XCTAssertEqual(vm.badge(for: lg), .selected)
    }

    func testLightweightBadge() async {
        let vm = make(FakeTarget(.success(connected(mode: .x1, scaling: .x1))))
        await vm.refresh()
        XCTAssertEqual(vm.badge(for: builtIn), .none)
        XCTAssertEqual(vm.badge(for: lg), .applied)
    }

    func testNoBadgeOnFailure() async {
        let vm = make(FakeTarget(.failure(.unreachable)))
        await vm.refresh()
        XCTAssertEqual(vm.badge(for: lg), .none)
    }

    // B: 特定できないときのヘッダ・フッタ
    func testAmbiguousHeaderAndFooter() async {
        let vm = make(FakeTarget(.success(RemoteState(payload(vd: nil, ambiguous: true)))))
        await vm.refresh()
        XCTAssertEqual(vm.headerDetail, "仮想ディスプレイを特定できません")
        XCTAssertEqual(vm.footerText, "表示倍率を自動で保つ: 停止中", "理由は見出しが示す")
    }

    func testPausedFooterAndOffMode() async {
        let vm = make(FakeTarget(.success(RemoteState(payload(paused: true)))))
        await vm.refresh()
        XCTAssertEqual(vm.footerText, "表示倍率を自動で保つ: 一時停止中", "理由は案内が示す")
        let off = make(FakeTarget(.success(RemoteState(payload(mode: .off)))))
        await off.refresh()
        XCTAssertEqual(off.footerText, "表示倍率を自動で保つ: オフ")
        XCTAssertEqual(make(FakeTarget(.failure(.unreachable))).footerText, "表示倍率を自動で保つ: 不明")
        XCTAssertFalse(off.footerText.contains("自動維持"), "「自動維持」は画面に出さない（実機確認 2026-09-30）")
    }

    // C: 届かないときに「接続後に適用」と書かない
    func testSettingTextOnFailureDoesNotMentionConnection() async {
        let vm = make(FakeTarget(.failure(.unreachable)))
        await vm.refresh()
        XCTAssertEqual(vm.settingText(for: lg), "1x")
        XCTAssertEqual(vm.settingText(for: builtIn), "2x")
        XCTAssertNil(vm.settingNote(for: lg))
    }

    // 接続中なのに特定できないときに「接続後に適用」と書かない
    func testSettingTextWhenConnectedButAmbiguous() async {
        let vm = make(FakeTarget(.success(RemoteState(payload(vd: nil, ambiguous: true)))))
        await vm.refresh()
        XCTAssertEqual(vm.settingText(for: lg), "1x"); XCTAssertNil(vm.settingNote(for: lg))
        XCTAssertEqual(vm.headerDetail, "仮想ディスプレイを特定できません")
    }

    func testHeaderDetailAndTitle() async {
        let vm = make(FakeTarget(.success(connected())))
        XCTAssertEqual(vm.headerDetail, "状態を取得できません")
        await vm.refresh()
        XCTAssertEqual(vm.headerDetail, "等倍 (1x) を自動で保っています", "接続中で倍率が合っていれば、自動で保っていることを言う（計画 2f-1 案 4）")
        let paused = make(FakeTarget(.success(RemoteState(payload(paused: true)))))
        await paused.refresh()
        XCTAssertEqual(paused.headerDetail, "仮想ディスプレイ 1920×997 · 等倍 (1x)", "一時停止中は保っていないので言わない")
        // 画面共有が未接続で仮想ディスプレイも無い時は出さない（バッジと案内が言う。計画 2f-2）。接続中なのに無い時は出す
        let idle = make(FakeTarget(.success(RemoteState(payload(session: false, vd: nil)))))
        await idle.refresh()
        XCTAssertNil(idle.headerDetail); XCTAssertEqual(idle.connection, .disconnected)
        let noVD = make(FakeTarget(.success(RemoteState(payload(session: true, vd: nil)))))
        await noVD.refresh()
        XCTAssertEqual(noVD.headerDetail, "仮想ディスプレイはありません")
        XCTAssertEqual(vm.title, "Studio", "相手の名前")
        XCTAssertEqual(vm.connection, .connected)
        let failed = make(FakeTarget(.failure(.notPaired)))
        await failed.refresh()
        XCTAssertEqual(failed.title, "studio", "届かなければ帳簿の名前")
        XCTAssertNil(failed.headerDetail, "失敗した時は 2 行目を出さない（案内の見出しが言う。計画 2f-1）")
        XCTAssertEqual(failed.notice?.title, "ペアリングの登録が解除されたか、一致しません")
        XCTAssertTrue(failed.notice?.detail.contains("追加しない") == true)
        XCTAssertTrue(failed.suggestsSettings)
    }

    func testLastErrorIsReportedButNotShownRaw() async {
        let vm = make(FakeTarget(.success(RemoteState(payload(lastError: "apply failed (CGError 1014)")))))
        await vm.refresh()
        XCTAssertEqual(vm.notice?.title, "接続先で表示倍率を切り替えられませんでした")
        XCTAssertFalse(vm.notice?.detail.contains("1014") ?? true, "生のエラーは本文に出さない")
        XCTAssertEqual(vm.copyableDetail, "apply failed (CGError 1014)", "コピーはできる")
    }

    // ダイナミック解像度で 2x の設定が用意されていない時は、窓の大きさを変えるよう案内する
    func testMissingTwoXModeSuggestsResizingTheWindow() async {
        let vm = make(FakeTarget(.success(RemoteState(payload(lastError: "no 2x mode for 1923x997")))))
        await vm.refresh()
        XCTAssertEqual(vm.notice?.title, "今のウインドウの大きさでは 2x Retina を選べません")
        XCTAssertTrue(vm.notice?.detail.contains("大きさを少し変えて") == true)
        XCTAssertEqual(vm.copyableDetail, "no 2x mode for 1923x997")
    }
    func testTimeoutSaysItWillRetry() async {
        let vm = make(FakeTarget(.success(RemoteState(payload(lastError: "apply timed out after 8s (macOS did not complete the display change)")))))
        await vm.refresh()
        XCTAssertEqual(vm.notice?.title, "macOS が表示倍率の切り替えを完了しませんでした")
        XCTAssertTrue(vm.notice?.detail.contains("自動でもう一度試します") == true)
    }
    func testTwoVirtualDisplaysAdviceDependsOnSource() async {
        let two = make(FakeTarget(.success(RemoteState(payload(vd: StatusPayload.VirtualDisplay(resolution: "1920x997", scaling: .oneX, source: .signature), ambiguous: true)))))
        await two.refresh()
        XCTAssertTrue(two.notice?.detail.contains("1個の仮想ディスプレイ") == true, two.notice?.detail ?? "nil")
        let unfamiliar = make(FakeTarget(.success(RemoteState(payload(vd: nil, ambiguous: true)))))
        await unfamiliar.refresh()
        XCTAssertTrue(unfamiliar.notice?.detail.contains("見慣れない") == true)
    }

    // 取り消し: 状態も案内も変えず、処理中の印だけ下ろす
    func testCancelledResultChangesNothing() async {
        let studio = FakeTarget(.success(connected()))
        let vm = make(studio)
        await vm.refresh()
        studio.statusResult = .failure(.cancelled)
        await vm.refresh(force: true)
        XCTAssertEqual(vm.state, connected()); XCTAssertNil(vm.failure); XCTAssertNil(vm.notice); XCTAssertFalse(vm.busy)
        XCTAssertNil(ViewerNotice.make(state: nil, failure: .cancelled, targetName: "s", unconfirmed: true, vpnSuspected: false))
        let other = make(FakeTarget(.failure(.other("x"))))
        await other.refresh()
        XCTAssertEqual(other.notice?.title, "接続先と通信できませんでした")
    }

    // 取り消された refresh は、取り直したことにしない（次の refresh を間引かない。再点検）
    func testCancelledRefreshDoesNotCountForCoalescing() async {
        let studio = FakeTarget(.failure(.cancelled))
        let vm = make(studio)
        await vm.refresh()
        await vm.refresh()
        XCTAssertEqual(studio.statusCalls, 2, "取り消された後の refresh は間引かない")
        studio.statusResult = .success(connected())
        await vm.refresh()
        await vm.refresh()
        XCTAssertEqual(studio.statusCalls, 3, "通った後は間引く")
    }

    func testNoTargetShowsHowToAdd() async {
        let vm = ViewerModel(client: nil, displays: { [lg] })
        XCTAssertFalse(vm.hasTarget)
        await vm.refresh(); await vm.apply(.x2)
        XCTAssertNil(vm.state); XCTAssertFalse(vm.busy)
        XCTAssertEqual(vm.notice?.title, "接続先がまだありません")
        XCTAssertEqual(vm.settingText(for: lg), "1x")
    }

    // 未確定のペアリング: 失敗の種類を問わず、確定の案内を先に出す。status が通れば確定
    func testUnconfirmedTargetNoticeUntilAReplyArrives() async {
        let studio = FakeTarget(.failure(.unreachable))
        let vm = ViewerModel(client: studio, displays: { [] }, targetLabel: "studio", unconfirmed: true)
        await vm.refresh()
        XCTAssertEqual(vm.notice?.title, "ペアリングは確認待ちです")
        XCTAssertTrue(vm.targetUnconfirmed)
        studio.statusResult = .success(connected())
        await vm.refresh(force: true)
        XCTAssertFalse(vm.targetUnconfirmed)
        XCTAssertNil(vm.notice)
        // Host が断った応答（一時停止中・処理中）も照合済みなので、確定にする（「確認待ち」の案内を残さない。帳簿も `TargetSession` が確定を書く。計画 2i）
        for refusal in [ViewerFailure.paused, .busy] {
            let pending = FakeTarget(.failure(.unreachable))
            pending.setResult = .failure(refusal)
            let p = ViewerModel(client: pending, displays: { [] }, targetLabel: "studio", unconfirmed: true)
            await p.refresh()
            XCTAssertEqual(p.notice?.title, "ペアリングは確認待ちです")
            await p.apply(.x1)
            XCTAssertFalse(p.targetUnconfirmed, "\(refusal)")
            XCTAssertEqual(p.notice?.title, refusal == .paused ? "接続先が一時停止中です" : "接続先が前の変更を処理しています")
        }
        // 接続できない失敗・照合できない失敗では、確定にしない
        for f in [ViewerFailure.timedOut, .notPaired, .handshakeFailed(othersUnreachable: false), .other("x")] {
            let p = ViewerModel(client: FakeTarget(.failure(f)), displays: { [] }, targetLabel: "studio", unconfirmed: true)
            await p.refresh()
            XCTAssertTrue(p.targetUnconfirmed, "\(f)"); XCTAssertEqual(p.notice?.title, "ペアリングは確認待ちです", "\(f)")
        }
    }

    func testPausedAndBusySetFailuresKeepGuidance() async {
        let studio = FakeTarget(.success(RemoteState(payload(paused: true))))
        studio.setResult = .failure(.paused)
        let vm = make(studio)
        await vm.apply(.x2)
        XCTAssertEqual(vm.failure, .paused)
        XCTAssertEqual(vm.notice?.title, "接続先が一時停止中です")
        studio.setResult = .failure(.busy)
        await vm.apply(.x1)
        XCTAssertEqual(vm.notice?.title, "接続先が前の変更を処理しています")
        XCTAssertFalse(vm.suggestsSettings)
    }

    // Host が照合済みの応答で断った時（一時停止中・処理中）は、接続の状態を「接続できない」にしない（計画 2i。実機確認 B:
    // 一時停止の間にカードを押すと、案内は「接続先が一時停止中です」と正しいのに、バッジが「接続できません」になった。「更新」で「接続中」に戻った）
    func testRefusedSetKeepsTheConnectionState() async {
        let studio = FakeTarget(.success(connected()))
        let vm = make(studio)
        await vm.refresh()
        XCTAssertEqual(vm.connection, .connected); XCTAssertEqual(vm.badge(for: lg), .applied)
        studio.setResult = .failure(.paused)
        await vm.apply(.x2)
        XCTAssertEqual(vm.failure, .paused); XCTAssertNil(vm.connectionFailure, "断ったのは照合済みの Host。接続できない失敗ではない")
        XCTAssertEqual(vm.connection, .connected, "バッジは「接続中」のまま")
        XCTAssertEqual(vm.notice?.title, "接続先が一時停止中です"); XCTAssertTrue(vm.noticeIsWarning)
        XCTAssertEqual(vm.title, "Studio", "相手の名前のまま（帳簿の名前に戻さない）"); XCTAssertEqual(vm.targetModel, "Mac Studio", "機種の記号もそのまま")
        XCTAssertTrue(vm.hostPaused); XCTAssertEqual(vm.state?.paused, true, "Host が「一時停止中」と答えた")
        XCTAssertEqual(vm.headerDetail, "仮想ディスプレイ 1920×997 · 等倍 (1x)", "一時停止中は「自動で保っています」と言わない")
        XCTAssertEqual(vm.footerText, "表示倍率を自動で保つ: 一時停止中")
        XCTAssertEqual(vm.badge(for: lg), .applied, "接続先の倍率は変わっていない"); XCTAssertTrue(vm.isActive(lg))
        XCTAssertEqual(vm.badge(for: builtIn), .none); XCTAssertEqual(vm.settingText(for: lg), "1920×997 · 1x")
        XCTAssertFalse(vm.suggestsSettings); XCTAssertNil(vm.copyableDetail)
        // 「更新」で取り直した後と同じ見え方（実機で「更新」を押すと「接続中」に戻った）
        studio.statusResult = .success(RemoteState(payload(paused: true)))
        await vm.refresh(force: true)
        XCTAssertNil(vm.failure); XCTAssertEqual(vm.connection, .connected); XCTAssertEqual(vm.notice?.title, "接続先が一時停止中です")
        XCTAssertEqual(vm.headerDetail, "仮想ディスプレイ 1920×997 · 等倍 (1x)"); XCTAssertEqual(vm.footerText, "表示倍率を自動で保つ: 一時停止中")

        // 処理中で断られた時も同じ（一時停止とは言わない）
        let busyTarget = FakeTarget(.success(connected()))
        let busy = make(busyTarget)
        await busy.refresh()
        busyTarget.setResult = .failure(.busy)
        await busy.apply(.x2)
        XCTAssertEqual(busy.failure, .busy); XCTAssertEqual(busy.connection, .connected); XCTAssertFalse(busy.hostPaused)
        XCTAssertEqual(busy.state?.paused, false); XCTAssertEqual(busy.notice?.title, "接続先が前の変更を処理しています")
        XCTAssertEqual(busy.headerDetail, "等倍 (1x) を自動で保っています"); XCTAssertEqual(busy.badge(for: lg), .applied)

        // 画面共有が未接続の時は「未接続」のまま
        let idleTarget = FakeTarget(.success(RemoteState(payload(session: false, vd: nil))))
        let idle = make(idleTarget)
        await idle.refresh()
        idleTarget.setResult = .failure(.paused)
        await idle.apply(.x2)
        XCTAssertEqual(idle.connection, .disconnected); XCTAssertNil(idle.headerDetail); XCTAssertEqual(idle.badge(for: lg), .selected)

        // 状態をまだ知らない時（最初の問い合わせが通る前に断られた）も「接続できません」にしない。問い合わせる前と同じ「未接続」
        let freshTarget = FakeTarget(.failure(.unreachable))
        freshTarget.setResult = .failure(.paused)
        let fresh = make(freshTarget)
        await fresh.apply(.x1)
        XCTAssertNil(fresh.state); XCTAssertEqual(fresh.connection, .disconnected); XCTAssertTrue(fresh.hostPaused)
        XCTAssertNil(fresh.headerDetail, "案内の見出しが言う（「状態を取得できません」を重ねない）"); XCTAssertEqual(fresh.title, "studio")
        XCTAssertEqual(fresh.notice?.title, "接続先が一時停止中です"); XCTAssertEqual(fresh.badge(for: lg), .none)

        // 接続できない失敗は今までどおり（直前の状態が残っていても、接続できない扱い）
        for f in [ViewerFailure.unreachable, .timedOut, .notPaired, .handshakeFailed(othersUnreachable: false), .unsupportedVersion, .localNetworkDenied, .other("x")] {
            XCTAssertFalse(f.isRefusal, "\(f)")
            let t = FakeTarget(.success(connected()))
            let m = make(t)
            await m.refresh()
            t.statusResult = .failure(f)
            await m.refresh(force: true)
            XCTAssertEqual(m.connectionFailure, f); XCTAssertEqual(m.connection, .failed, "\(f)"); XCTAssertNil(m.headerDetail, "\(f)")
            XCTAssertEqual(m.title, "studio", "\(f)"); XCTAssertNil(m.targetModel, "\(f)"); XCTAssertEqual(m.badge(for: lg), .none, "\(f)")
            XCTAssertFalse(m.hostPaused, "\(f)")
        }
        XCTAssertTrue(ViewerFailure.paused.isRefusal); XCTAssertTrue(ViewerFailure.busy.isRefusal); XCTAssertFalse(ViewerFailure.cancelled.isRefusal)
        // 一時停止で断られた後に接続できなくなったら、「一時停止中」は言わない
        studio.setResult = .failure(.paused)
        await vm.apply(.x2)
        XCTAssertTrue(vm.hostPaused)
        studio.statusResult = .failure(.unreachable)
        await vm.refresh(force: true)
        XCTAssertEqual(vm.connection, .failed); XCTAssertFalse(vm.hostPaused)
    }

    // 届かなくなった後に断られた時は、手元の古い状態を「今の状態」として出さない（点検 2i。成功 → 届かない → 切り替えを断られた、の順で、
    // バッジ「接続中」・カード「適用中」が、届かなくなる前の状態から出ていた）
    func testRefusalAfterALostConnectionDropsTheStaleState() async {
        for lost in [ViewerFailure.unreachable, .timedOut, .notPaired, .handshakeFailed(othersUnreachable: false)] {
            for refusal in [ViewerFailure.paused, .busy] {
                let t = FakeTarget(.success(connected()))
                let vm = make(t)
                await vm.refresh()
                XCTAssertEqual(vm.badge(for: lg), .applied)
                t.statusResult = .failure(lost)
                await vm.refresh(force: true)
                XCTAssertEqual(vm.connection, .failed); XCTAssertNotNil(vm.state, "届かないだけでは、状態は捨てない（前からの作り。画面は出さない）")
                t.setResult = .failure(refusal)
                await vm.apply(.x2)
                XCTAssertEqual(vm.failure, refusal); XCTAssertNil(vm.state, "\(lost) → \(refusal): 古い状態は捨てる")
                XCTAssertEqual(vm.connection, .disconnected, "状態をまだ知らない時と同じ「未接続」（古い状態の「接続中」を出さない）")
                XCTAssertEqual(vm.badge(for: lg), .none); XCTAssertFalse(vm.isActive(lg)); XCTAssertEqual(vm.settingText(for: lg), "1x")
                XCTAssertEqual(vm.title, "studio"); XCTAssertNil(vm.targetModel); XCTAssertNil(vm.headerDetail)
                XCTAssertEqual(vm.footerText, "表示倍率を自動で保つ: 不明")
                XCTAssertEqual(vm.hostPaused, refusal == .paused)
                XCTAssertEqual(vm.notice?.title, refusal == .paused ? "接続先が一時停止中です" : "接続先が前の変更を処理しています")
                // 次に取り直せたら、本当の状態になる
                t.statusResult = .success(RemoteState(payload(paused: refusal == .paused)))
                await vm.refresh(force: true)
                XCTAssertEqual(vm.connection, .connected); XCTAssertEqual(vm.badge(for: lg), .applied)
            }
        }
        // 続けて断られた時（直前も断られた＝接続はできていた）は、状態を捨てない
        let t = FakeTarget(.success(connected()))
        let vm = make(t)
        await vm.refresh()
        t.setResult = .failure(.busy)
        await vm.apply(.x2)
        t.setResult = .failure(.paused)
        await vm.apply(.x2)
        XCTAssertNotNil(vm.state); XCTAssertEqual(vm.connection, .connected); XCTAssertEqual(vm.badge(for: lg), .applied)
    }

    // 取り直し（`status`）も「処理中」で断られうる（Host が候補アドレスを作れない時）。接続はできているので、直前の状態のまま（点検 2i）
    func testRefreshRefusedAsBusyKeepsTheConnectionState() async {
        let t = FakeTarget(.success(connected()))
        let vm = make(t)
        await vm.refresh()
        t.statusResult = .failure(.busy)
        await vm.refresh(force: true)
        XCTAssertEqual(vm.failure, .busy); XCTAssertNil(vm.connectionFailure)
        XCTAssertEqual(vm.connection, .connected); XCTAssertEqual(vm.title, "Studio"); XCTAssertEqual(vm.badge(for: lg), .applied)
        XCTAssertEqual(vm.footerText, "表示倍率を自動で保つ: オン"); XCTAssertFalse(vm.hostPaused)
        XCTAssertEqual(vm.notice?.title, "接続先が前の変更を処理しています")
        // 最初の取り直しが断られた（状態をまだ知らない）: 「接続できません」にしない
        let first = make(FakeTarget(.failure(.busy)))
        await first.refresh()
        XCTAssertNil(first.state); XCTAssertEqual(first.connection, .disconnected); XCTAssertNil(first.headerDetail)
        XCTAssertEqual(first.footerText, "表示倍率を自動で保つ: 不明")
    }

    // 断られた後の細かい所（点検 2i）: 直近のエラーのコピー・フッタ・一時停止の案内の本文
    func testRefusalDetailsFooterAndPausedNoticeText() async {
        // 直近のエラーのある状態で断られた: 「詳細をコピー」は出さない（案内は断られた理由で、直近のエラーの案内ではない）
        let t = FakeTarget(.success(RemoteState(payload(lastError: "apply failed (CGError 1014)"))))
        let vm = make(t)
        await vm.refresh()
        XCTAssertEqual(vm.copyableDetail, "apply failed (CGError 1014)")
        t.setResult = .failure(.paused)
        await vm.apply(.x2)
        XCTAssertNil(vm.copyableDetail); XCTAssertEqual(vm.notice?.title, "接続先が一時停止中です")
        // 一時停止の案内は、断られた時と、取り直した後（状態が一時停止中）で、見出しも本文も同じ
        let refused = vm.notice
        XCTAssertEqual(refused, ViewerNotice.Text("接続先が一時停止中です", "表示倍率は変更されません。接続先の ShareScale Host のメニューで「再開」を選択してください。"))
        t.statusResult = .success(RemoteState(payload(paused: true)))
        await vm.refresh(force: true)
        XCTAssertNil(vm.failure); XCTAssertEqual(vm.notice, refused, "「更新」を押しても、案内が変わらない")
        AppLanguage.current = .en
        XCTAssertEqual(ViewerNotice.forFailure(.paused, targetName: "s", unconfirmed: false, vpnSuspected: false),
                       ViewerNotice.Text("The Host is paused", "The display scale won’t change. Choose Resume in the ShareScale Host menu on the Host."))
        XCTAssertEqual(ViewerNotice.forState(RemoteState(payload(paused: true))), ViewerNotice.forFailure(.paused, targetName: "s", unconfirmed: false, vpnSuspected: false))
        AppLanguage.current = .ja
        // 断られた後に届かなくなった: フッタは「不明」（「一時停止中」を残さない）。届かなくなる前の「オン」も出さない
        t.setResult = .failure(.paused)
        await vm.apply(.x2)
        XCTAssertEqual(vm.footerText, "表示倍率を自動で保つ: 一時停止中")
        t.statusResult = .failure(.unreachable)
        await vm.refresh(force: true)
        XCTAssertEqual(vm.footerText, "表示倍率を自動で保つ: 不明")
        let on = FakeTarget(.success(connected()))
        let lostLater = make(on)
        await lostLater.refresh()
        XCTAssertEqual(lostLater.footerText, "表示倍率を自動で保つ: オン")
        on.statusResult = .failure(.timedOut)
        await lostLater.refresh(force: true)
        XCTAssertEqual(lostLater.footerText, "表示倍率を自動で保つ: 不明")
    }

    func testLocalNetworkDeniedIsDistinguishedFromUnreachable() async {
        let vm = make(FakeTarget(.failure(.localNetworkDenied)))
        await vm.refresh()
        XCTAssertEqual(vm.notice?.title, "ローカルネットワークへのアクセスが許可されていません")
        XCTAssertTrue(vm.notice?.detail.contains("プライバシーとセキュリティ") == true)
        XCTAssertTrue(vm.suggestsSettings)
        let unconfirmed = ViewerModel(client: FakeTarget(.failure(.localNetworkDenied)), displays: { [] }, targetLabel: "studio", unconfirmed: true)
        await unconfirmed.refresh()
        XCTAssertEqual(unconfirmed.notice?.title, "ローカルネットワークへのアクセスが許可されていません", "未確定よりローカルネットワークの拒否を先に")
        let mismatch = make(FakeTarget(.failure(.handshakeFailed(othersUnreachable: true))))
        await mismatch.refresh()
        XCTAssertEqual(mismatch.notice?.title, "ペアリングが一致しないか、別の機器が応答しています")
        XCTAssertTrue(mismatch.notice?.detail.contains("接続できないアドレスもありました") == true); XCTAssertTrue(mismatch.notice?.detail.contains("自動では削除されません") == true)
        XCTAssertTrue(mismatch.suggestsSettings)
        let alone = make(FakeTarget(.failure(.handshakeFailed(othersUnreachable: false))))
        await alone.refresh()
        XCTAssertFalse(alone.notice?.detail.contains("接続できないアドレス") ?? true)
        let old = make(FakeTarget(.failure(.unsupportedVersion)))
        await old.refresh()
        XCTAssertTrue(old.notice?.detail.contains("同じバージョン") == true)
        let slow = make(FakeTarget(.failure(.timedOut)))
        await slow.refresh()
        XCTAssertEqual(slow.notice?.title, "接続先から応答がありません")
    }
}

/// 取り違え（接続先の切り替え）と処理中の選択
@MainActor
final class HostSwitchRaceTests: XCTestCase {
    override func setUp() { AppLanguage.current = .ja }

    // B1: 古い接続先への問い合わせが終わる前に切り替えると、古い結果が新しい接続先の画面に出ていた
    func testLateResultFromOldHostIsDiscarded() async {
        let old = GatedTarget(.success(RemoteState(payload(name: "Old Mac"))))
        let vm = ViewerModel(client: old, displays: { [] }, targetLabel: "old")
        let inflight = Task { await vm.refresh() }
        while old.pending == 0 { await Task.yield() }

        vm.updateClient(FakeTarget(.success(RemoteState(payload(name: "New Mac")))), targetLabel: "new")
        await vm.refresh()                       // 切り替え直後の取得は、処理中でも捨てずに行う
        XCTAssertEqual(vm.title, "New Mac")

        old.release(); await inflight.value      // 古い結果が遅れて届く
        XCTAssertEqual(vm.title, "New Mac", "古い接続先の結果で上書きしない")
        XCTAssertFalse(vm.busy)
    }

    // L15: 古い接続先の「届かない」結果に続く VPN の確認が遅れて終わっても、新しい接続先には案内を出さない
    func testVPNHintNotAppliedToNewHost() async {
        let gate = VPNGate()
        let vm = ViewerModel(client: FakeTarget(.failure(.unreachable)), displays: { [] },
                             targetLabel: "old", vpnCheck: { await gate.wait() })
        let inflight = Task { await vm.refresh() }
        while !gate.isWaiting { await Task.yield() }

        vm.updateClient(FakeTarget(.success(RemoteState(payload(name: "New Mac")))), targetLabel: "new")
        gate.release(true)                       // 古い接続先の確認結果（VPN の疑いあり）が遅れて届く
        await inflight.value
        XCTAssertFalse(vm.vpnSuspected, "古い接続先の確認結果を新しい接続先に使わない")
    }

    func testChangingClientTriggersFreshStateAndClearingIt() async {
        let vm = ViewerModel(client: FakeTarget(.failure(.unreachable)), displays: { [] }, targetLabel: "old")
        await vm.refresh()
        vm.updateClient(FakeTarget(.success(connected())), targetLabel: "new")
        await vm.refresh()  // 直後でも、接続先を変えたら取り直す
        XCTAssertNil(vm.failure)
        XCTAssertEqual(vm.targetLabel, "new")
        vm.updateClient(nil, targetLabel: "")
        XCTAssertFalse(vm.hasTarget); XCTAssertNil(vm.state)
        XCTAssertEqual(vm.notice?.title, "接続先がまだありません")
    }

    func testVpnHintOnlyWhenUnreachable() async {
        let vm = ViewerModel(client: FakeTarget(.failure(.unreachable)), displays: { [] }, targetLabel: "studio", vpnCheck: { true })
        await vm.refresh()
        XCTAssertTrue(vm.notice?.detail.contains("VPN") == true, vm.notice?.detail ?? "nil")
        let calls = Locked(0)
        let ok = ViewerModel(client: FakeTarget(.success(connected())), displays: { [] }, targetLabel: "studio", vpnCheck: { calls.update { $0 += 1 }; return true })
        await ok.refresh()
        XCTAssertEqual(calls.value, 0, "届いている時は経路を調べない")
        XCTAssertFalse(ok.notice?.detail.contains("VPN") == true)
    }
}

/// L10: 処理中に選んだ倍率は、処理が終わってから送る（最後に選んだものだけ）
@MainActor
final class ChooseWhileBusyTests: XCTestCase {
    override func setUp() { AppLanguage.current = .ja }

    func testChooseWhileBusySendsAfterwards() async {
        let remote = GatedTarget(.success(connected()))
        let vm = ViewerModel(client: remote, displays: { [lg] }, preferences: DisplayPreferences(store: MemoryStore()))
        let inflight = Task { await vm.refresh() }
        while remote.pending == 0 { await Task.yield() }
        XCTAssertTrue(vm.busy)

        await vm.choose(.x1, for: lg)            // 処理中に選び直す。送るのは最後の 2x だけ
        await vm.choose(.x2, for: lg)
        XCTAssertEqual(remote.setCalls, [], "処理中はまだ送らない")

        remote.release()                         // 更新が終わる → 覚えていた倍率を送る
        let deadline = Date().addingTimeInterval(10)
        while remote.pending == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(remote.setCalls, [.x2])
        remote.release()
        await inflight.value
        XCTAssertEqual(remote.setCalls, [.x2], "ちょうど 1 回だけ送る")
        XCTAssertFalse(vm.busy)
        XCTAssertEqual(vm.chosenMode(for: lg), .x2)
    }

    // 更新が取り消されても、処理中に選んだ倍率は捨てずに、終わった後に送る（取り消しを受け継がない Task で。再点検）
    func testChooseWhileBusyIsSentAfterACancelledRefresh() async {
        let remote = GatedTarget(.failure(.cancelled))
        let vm = ViewerModel(client: remote, displays: { [lg] }, preferences: DisplayPreferences(store: MemoryStore()))
        let inflight = Task { await vm.refresh() }
        while remote.pending == 0 { await Task.yield() }

        await vm.choose(.x2, for: lg)
        remote.release()
        await inflight.value
        let deadline = Date().addingTimeInterval(10)
        while remote.pending == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(remote.setCalls, [.x2], "取り消された更新の後に、選んだ倍率を送る")
        remote.release()
        let idle = Date().addingTimeInterval(10)
        while vm.busy, Date() < idle { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(vm.busy)
        XCTAssertNil(vm.failure, "取り消しは案内しない")
    }

    // 更新が「届かない」で終わったら、覚えていた倍率は送らない（選んだものは保存済みで、次の更新やカードで適用される）
    func testChooseWhileBusyIsNotSentAfterUnreachable() async {
        let remote = GatedTarget(.failure(.unreachable))
        let vm = ViewerModel(client: remote, displays: { [lg] }, preferences: DisplayPreferences(store: MemoryStore()))
        let inflight = Task { await vm.refresh() }
        while remote.pending == 0 { await Task.yield() }

        await vm.choose(.x2, for: lg)
        remote.release()
        let deadline = Date().addingTimeInterval(0.5)
        while remote.pending == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        remote.release()                         // 万一送っていても、試験が止まらないように進める
        await inflight.value
        XCTAssertEqual(remote.setCalls, [], "届かなかった直後には送り直さない")
        XCTAssertEqual(vm.chosenMode(for: lg), .x2, "選んだものは保存されている")
        XCTAssertFalse(vm.busy)
    }
}

/// ご要望: カードごとに 1x/2x を選べ、ディスプレイごとに覚える
@MainActor
final class ChosenScaleTests: XCTestCase {
    override func setUp() { AppLanguage.current = .ja }
    private func vm(_ remote: FakeTarget = FakeTarget(.success(connected())), store: MemoryStore = MemoryStore()) -> ViewerModel {
        ViewerModel(client: remote, displays: { [lg, builtIn] }, preferences: DisplayPreferences(store: store))
    }

    func testDefaultsToRecommended() {
        let m = vm()
        XCTAssertEqual(m.chosenMode(for: lg), .x1); XCTAssertEqual(m.chosenMode(for: builtIn), .x2)
    }
    func testChoosingAppliesAndIsRemembered() async {
        let store = MemoryStore(), remote = FakeTarget(.success(connected()))
        let m = vm(remote, store: store)
        await m.choose(.x1, for: builtIn)
        XCTAssertEqual(remote.setCalls, [.x1], "選んだらその場で適用する")
        XCTAssertEqual(vm(store: store).chosenMode(for: builtIn), .x1, "次に開いても覚えている")
    }
    func testCardClickAppliesChosen() async {
        let store = MemoryStore(), remote = FakeTarget(.success(connected()))
        let m = vm(remote, store: store)
        await m.choose(.x1, for: builtIn)
        await m.applyChosen(for: builtIn)
        XCTAssertEqual(remote.setCalls, [.x1, .x1])
    }
    // カードを処理中に押した時も、終わった後に 1 回だけ送る（最後に押したもの）
    func testCardClickWhileBusyIsSentAfterwards() async {
        let remote = GatedTarget(.success(connected()))
        let m = ViewerModel(client: remote, displays: { [lg, builtIn] }, preferences: DisplayPreferences(store: MemoryStore()))
        let inflight = Task { await m.refresh() }
        while remote.pending == 0 { await Task.yield() }
        await m.applyChosen(for: lg)          // 1x
        await m.applyChosen(for: builtIn)     // 2x（最後）
        XCTAssertEqual(remote.setCalls, [], "処理中はまだ送らない")
        remote.release()
        let deadline = Date().addingTimeInterval(10)
        while remote.pending == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(remote.setCalls, [.x2])
        remote.release()
        await inflight.value
        XCTAssertEqual(remote.setCalls, [.x2], "ちょうど 1 回だけ")
    }
    func testBadgeAndTextFollowChosen() async {
        let m = vm(FakeTarget(.success(connected(mode: .x1, scaling: .x1))))
        await m.refresh()
        XCTAssertEqual(m.badge(for: builtIn), .none, "既定の 2x を選んでいる内蔵画面は、今の 1x とは違う")
        await m.choose(.x1, for: builtIn)
        XCTAssertEqual(m.badge(for: builtIn), .applied)
        XCTAssertEqual(m.settingText(for: builtIn), "1920×997 · 1x")
    }
    func testRememberedPerDisplay() async {
        let store = MemoryStore()
        await vm(store: store).choose(.x2, for: lg)
        let m = vm(store: store)
        XCTAssertEqual(m.chosenMode(for: lg), .x2); XCTAssertEqual(m.chosenMode(for: builtIn), .x2)
    }
    // D1: VoiceOver 用の読み上げ文は要点だけ
    func testAccessibilityLabel() async {
        let m = vm(); await m.refresh()
        let label = m.accessibilityLabel(for: lg)
        XCTAssertTrue(label.contains("LG ULTRAWIDE")); XCTAssertTrue(label.contains("1x")); XCTAssertTrue(label.contains("適用中"))
        XCTAssertFalse(label.contains("1920×997 ·"), "細かい数値は読み上げない")
        XCTAssertTrue(m.accessibilityLabel(for: builtIn).contains("未適用"))
    }
}

/// 英語表示（訳し漏れの検出）
@MainActor
final class EnglishTests: XCTestCase {
    override func tearDown() { AppLanguage.current = .ja }

    func testEnglishNoticeNamesHost() async {
        AppLanguage.current = .en
        let vm = ViewerModel(client: FakeTarget(.failure(.unreachable)), displays: { [] }, targetLabel: "my-mac")
        await vm.refresh()
        XCTAssertEqual(vm.notice?.title, "Can’t connect to the Host")
        XCTAssertTrue(vm.notice?.detail.contains("my-mac") == true)
        let ok = ViewerModel(client: FakeTarget(.success(connected())), displays: { [] })
        await ok.refresh()
        XCTAssertEqual(ok.footerText, "Keep display scale automatically: on")
        XCTAssertEqual(ok.headerDetail, "Keeping Standard (1x) automatically")
    }

    /// 英語表示に日本語が混ざっていないか
    func testNoJapaneseLeaksIntoEnglish() async {
        AppLanguage.current = .en
        let japanese = try! NSRegularExpression(pattern: "[ぁ-んァ-ヶ一-龠]")
        func check(_ s: String, _ where_: String) {
            XCTAssertNil(japanese.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), "\(where_): \(s)")
        }
        let failures: [ViewerFailure] = [.unreachable, .localNetworkDenied, .handshakeFailed(othersUnreachable: true), .handshakeFailed(othersUnreachable: false),
                                         .notPaired, .unsupportedVersion, .paused, .busy, .timedOut, .cancelled, .other("x")]
        for f in failures {
            for unconfirmed in [false, true] {
                if let n = ViewerNotice.forFailure(f, targetName: "h", unconfirmed: unconfirmed, vpnSuspected: true) { check(n.title, "\(f)"); check(n.detail, "\(f)") }
            }
        }
        let states: [StatusPayload] = [
            payload(), payload(paused: true), payload(lastError: "no 2x mode for 1x1"),
            payload(lastError: "apply timed out"), payload(lastError: "x"), payload(vd: nil), payload(vd: nil, ambiguous: true),
            payload(ambiguous: true), payload(session: false), payload(setBy: StatusPayload.SetBy(byYou: false, at: 1)),
            payload(session: false, mode: .off), payload(session: false, mode: .twoX, setBy: StatusPayload.SetBy(byYou: false, at: 1)),
        ]
        for p in states {
            let s = RemoteState(p)
            let vm = ViewerModel(client: FakeTarget(.success(s)), displays: { [lg, builtIn] })
            await vm.refresh()
            if let n = vm.notice { check(n.title, "\(p)"); check(n.detail, "\(p)") }
            check(vm.headerDetail ?? "", "\(p)"); check(vm.footerText, "\(p)")
            for d in [lg, builtIn] { check(vm.settingText(for: d), "\(p)"); check(vm.settingNote(for: d) ?? "", "\(p)"); check(d.panelLabel, "\(p)") }
            check(vm.accessibilityLabel(for: lg), "\(p)")   // 内蔵画面の名前は macOS が付けた日本語なので、lg だけ確かめる
            let entry = TargetEntry(id: pid(1), secret: secret(1), meta: ViewerMeta(name: "S", port: 1, addresses: ["a"], confirmed: false)!)
            for line in ViewerDiagnostics.lines(target: entry, state: s, failure: nil, chosen: .x2, readProblems: 1) { check(line.text, "\(p)"); check(line.advice ?? "", "\(p)") }
        }
        for f in failures {
            for line in ViewerDiagnostics.lines(target: nil, state: nil, failure: f, chosen: nil) { check(line.text, "\(f)"); check(line.advice ?? "", "\(f)") }
        }
        check(ViewerDiagnostics.report([], target: nil, version: "1.1.0"), "report")
        let none = ViewerModel(client: nil, displays: { [] })
        check(none.notice?.title ?? "", "none"); check(none.notice?.detail ?? "", "none")
    }
}
