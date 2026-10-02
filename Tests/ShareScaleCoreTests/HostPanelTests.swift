import Darwin
import XCTest
@testable import ShareScaleCore
import ShareScaleHostCore
import ShareScaleProtocol

/// Host が書く形の `state.json`（試験用。`HostControlState.encoded()` と同じキー）
func stateJSON(pid: Int64 = Int64(getpid()), running: Bool = true, paused: Bool = false, listener: String = #"{"status":"listening","port":47651}"#,
               pairings: [String] = [], code: Int64? = nil, tailscaleOnly: Bool = false, allowGlobal: Bool = false, updating: Bool = false,
               contention: Bool = false, lastError: String? = nil, storeProblems: Int = 0,
               firewall: String = "allowed", fileVault: Bool? = true, loginItem: String = "enabled") -> String {
    let err = lastError.map { "\"\($0)\"" } ?? "null"
    let fv = fileVault.map { $0 ? "true" : "false" } ?? "null"
    let codePart = code.map { #","code":{"expires":\#($0)}"# } ?? ""
    return #"{"format":1,"pid":\#(pid),"version":"1.1.0","build":10100,"running":\#(running),"paused":\#(paused),"listener":\#(listener),"pairings":[\#(pairings.joined(separator: ","))]\#(codePart),"diagnostics":{"tailscale_only":\#(tailscaleOnly),"allow_global":\#(allowGlobal),"tailscale":"none","updating":\#(updating),"contention":\#(contention),"last_error":\#(err),"store_problems":\#(storeProblems),"engine_problem":null,"log_problem":null,"rejected_global_24h":0,"pairing_count":\#(pairings.count),"firewall":"\#(firewall)","filevault":\#(fv),"login_item":"\#(loginItem)"},"updated":1800000000}"# + "\n"
}
func pairingJSON(_ id: PairingID, _ name: String, lastSeen: Int64? = nil, confirmed: Bool = true, stale: Bool = false) -> String {
    #"{"id":"\#(id.hex)","name":"\#(name)","last_seen":\#(lastSeen.map(String.init) ?? "null"),"confirmed":\#(confirmed),"stale":\#(stale)}"#
}
func summary(_ json: String) -> HostControlState.Summary { HostControlState.decode(Data(json.utf8))! }

/// 「この Mac の接続先」（`HostPanelModel`・`HostPanelStore`）
@MainActor
final class HostPanelTests: TempDirTestCase {
    override func setUp() { super.setUp(); AppLanguage.current = .ja }
    let now: Int64 = 1_800_000_000

    func testRunningHostShowsListenerViewersCodeAndNotices() {
        let s = summary(stateJSON(pairings: [pairingJSON(pid(1), "Taro の MacBook\\u0007", lastSeen: now - 3 * 86_400),
                                             pairingJSON(pid(2), "Air", lastSeen: nil, confirmed: false),
                                             pairingJSON(pid(3), "Old", lastSeen: now - 90 * 86_400, stale: true),
                                             pairingJSON(pid(4), " ", lastSeen: now - 60)],
                                  code: now + 125, lastError: "apply failed", fileVault: false))
        let m = HostPanelModel.make(.running(s), now: now)
        XCTAssertEqual(m.status, .running); XCTAssertEqual(m.symbol, "checkmark.circle"); XCTAssertEqual(m.statusText, "動作中")
        XCTAssertEqual(m.guidance, "操作しても反応がない場合は、「この Mac を接続先にする」をオフにしてから、もう一度オンにしてください。", "pid の使い回しに備える（計画 2e-1 でスイッチを指す文に戻した）")
        XCTAssertNil(m.guidanceDetail)
        XCTAssertEqual(m.listener, "ローカルネットワークと Tailscale からの接続を受け付けています（ポート 47651）")
        XCTAssertEqual(m.code, "接続コードを ShareScale Host の「接続コード」ウインドウに表示しています（残り 2:05）。", "コードの文字列は出さない（期限だけ）")
        XCTAssertEqual(m.viewers.map(\.title), ["Air", "「Old」は 80 日間使われていません。登録を解除しますか？", "Taro の MacBook", "名前のない Mac"],
                       "名前の順（制御文字は除く。空なら「名前の分からない見る側」）")
        XCTAssertEqual(m.viewers.map(\.detail), ["確認待ち（その Mac で登録が完了していません）", "最後の接続: 90 日前", "最後の接続: 3 日前", "最後の接続: 今日"])
        XCTAssertEqual(m.viewers.map(\.stale), [false, true, false, false])
        XCTAssertEqual(m.viewers.dropFirst(2).first?.accessibilityLabel, "Taro の MacBook、最後の接続: 3 日前")
        XCTAssertEqual(m.notices, ["直近のエラー: apply failed",
                                   "FileVault がオフです。ペアリングの鍵はディスクの暗号化で保護されるため、システム設定 › プライバシーとセキュリティ › FileVault でオンにすることをお勧めします。"])
        XCTAssertTrue(m.canOperate); XCTAssertTrue(m.canIssueCode); XCTAssertEqual(m.issueCodeTitle, "接続元の Mac を追加…")
        XCTAssertEqual(m.pauseAction, .pause); XCTAssertEqual(m.pauseTitle, "一時停止")
        XCTAssertEqual(m.version, "ShareScale Host 1.1.0")
        // 期限の過ぎたコードは出さない
        XCTAssertNil(HostPanelModel.make(.running(summary(stateJSON(code: now))), now: now).code)
    }

    // 受け付けの行は、設定の 3 つの状態で出し分ける（Host のメニューと同じ言葉。計画 2h）
    func testListenerLineHasThreeStates() {
        func line(tailscaleOnly: Bool = false, allowGlobal: Bool = false) -> String? {
            HostPanelModel.make(.running(summary(stateJSON(tailscaleOnly: tailscaleOnly, allowGlobal: allowGlobal))), now: now).listener
        }
        XCTAssertEqual(line(), "ローカルネットワークと Tailscale からの接続を受け付けています（ポート 47651）")
        XCTAssertEqual(line(allowGlobal: true), "インターネットを含むすべてのネットワークからの接続を受け付けています（ポート 47651）")
        XCTAssertEqual(line(tailscaleOnly: true), "Tailscale からの接続だけを受け付けています（ポート 47651）")
        XCTAssertEqual(line(tailscaleOnly: true, allowGlobal: true), "Tailscale からの接続だけを受け付けています（ポート 47651）", "Tailscale だけがオンなら、Tailscale だけ")
        AppLanguage.current = .en
        defer { AppLanguage.current = .ja }
        XCTAssertEqual(line(), "Accepting connections from local networks and Tailscale (port 47651)")
        XCTAssertEqual(line(allowGlobal: true), "Accepting connections from all networks, including the internet (port 47651)")
        XCTAssertEqual(line(tailscaleOnly: true), "Accepting connections from Tailscale only (port 47651)")
        // Host のメニューの行と、文字どおり同じ（ShareScale.app が読んだ state.json から。Tailscale の IPv4 がある時も。点検 2h）
        for language in [AppLanguage.ja, .en] {
            AppLanguage.current = language
            for (t, g) in [(false, false), (false, true), (true, false), (true, true)] {
                for tailscale in [#""tailscale":"none""#, #""tailscale":"found","tailscale_ipv4":"100.101.1.2""#, #""tailscale":"ipv4_only""#] {
                    let s = summary(stateJSON(tailscaleOnly: t, allowGlobal: g).replacingOccurrences(of: #""tailscale":"none""#, with: tailscale))
                    let menu = MenuModel.build(HostMenuFacts(summary: s), now: Date(timeIntervalSince1970: TimeInterval(now)), language: language.host)
                    guard case let .status(line)? = menu.dropFirst().first else { return XCTFail("メニューの 2 行目") }
                    XCTAssertEqual(HostPanelModel.make(.running(s), now: now).listener, line, "\(language) \(t) \(g) \(tailscale)")
                }
            }
        }
        AppLanguage.current = .ja
        let found = summary(stateJSON(tailscaleOnly: true).replacingOccurrences(of: #""tailscale":"none""#, with: #""tailscale":"found","tailscale_ipv4":"100.101.1.2""#))
        XCTAssertEqual(HostPanelModel.make(.running(found), now: now).listener, "Tailscale からの接続だけを受け付けています（100.101.1.2、ポート 47651）")
        // 既定で受け付ける範囲の注記（設定の「接続を受け付けるネットワーク」）
        XCTAssertEqual(HostPanelModel.defaultNetworkNote, "既定では、プライベートアドレス（同じネットワークや VPN など）と Tailscale の範囲（100.64.0.0/10・fc00::/7）からの接続を受け付けます。")
        AppLanguage.current = .en
        XCTAssertEqual(HostPanelModel.defaultNetworkNote,
                       "By default, connections are accepted from private addresses (the same network, a VPN, and so on) and from the ranges Tailscale uses (100.64.0.0/10 and fc00::/7).")
    }

    // アプリの CFBundleVersion と Host の build が違えば案内する（更新の途中の案内とは重ねない。計画 2e-1）
    func testVersionMismatchNotice() {
        let s = summary(stateJSON())   // build 10100
        XCTAssertEqual(HostPanelModel.make(.running(s), now: now, appBuild: 10100).notices, [], "同じ版なら出さない")
        XCTAssertEqual(HostPanelModel.make(.running(s), now: now).notices, [], "バンドルの外（版が分からない）では出さない")
        XCTAssertEqual(HostPanelModel.make(.running(s), now: now, appBuild: 10200).notices, ["ShareScale Host が古いバージョンで動いています。ShareScale を開き直すと新しいバージョンに切り替わります。"])
        XCTAssertEqual(HostPanelModel.make(.running(s), now: now, appBuild: 10000).notices,
                       ["ShareScale Host がこのアプリより新しいバージョンで動いています。新しいバージョンの ShareScale を開いてください。"])
        XCTAssertEqual(HostPanelModel.make(.running(summary(stateJSON(updating: true))), now: now, appBuild: 10200).notices,
                       ["アップデートの途中です。ShareScale を開き直すと完了します。"], "アップデートの途中の案内と重ねない")
        XCTAssertEqual(HostPanelModel.make(.notRunning(last: s), now: now, appBuild: 10200).notices, [], "動いていない Host には出さない")
        AppLanguage.current = .en
        XCTAssertEqual(HostPanelModel.make(.running(s), now: now, appBuild: 10200).notices, ["ShareScale Host is running an older version. Reopen ShareScale to switch to the new version."])
    }

    // 解除の確かめの窓は名前を使う（80 日の知らせの文を題名に重ねない。点検 C）
    func testViewerNameIsSeparateFromTheStaleNotice() {
        let m = HostPanelModel.make(.running(summary(stateJSON(pairings: [pairingJSON(pid(3), "Old\\u200b", lastSeen: now - 90 * 86_400, stale: true)]))), now: now)
        XCTAssertEqual(m.viewers.first?.name, "Old", "名前は制御文字を除いたもの")
        XCTAssertEqual(m.viewers.first?.title, "「Old」は 80 日間使われていません。登録を解除しますか？")
        AppLanguage.current = .en
        let en = HostPanelModel.make(.running(summary(stateJSON(pairings: [pairingJSON(pid(3), "Old", lastSeen: now - 90 * 86_400, stale: true)]))), now: now)
        XCTAssertEqual(en.viewers.first?.name, "Old"); XCTAssertEqual(en.viewers.first?.title, "“Old” hasn’t been used in 80 days. Remove it?")
    }

    func testPausedLimitsNoticesAndListenerStates() {
        let paused = HostPanelModel.make(.running(summary(stateJSON(paused: true, tailscaleOnly: true, updating: true, contention: true,
                                                                    lastError: "hidden", storeProblems: 2, firewall: "blocked", loginItem: "requires_approval"))), now: now)
        XCTAssertEqual(paused.status, .paused); XCTAssertEqual(paused.symbol, "pause.circle"); XCTAssertEqual(paused.statusText, "一時停止中（表示倍率を変更しません）")
        XCTAssertEqual(paused.pauseAction, .resume); XCTAssertEqual(paused.pauseTitle, "再開")
        XCTAssertEqual(paused.listener, "Tailscale からの接続だけを受け付けています（ポート 47651）"); XCTAssertTrue(paused.tailscaleOnly)
        XCTAssertEqual(paused.notices, ["アップデートの途中です。ShareScale を開き直すと完了します。",
                                        "表示倍率が何度も元に戻されています（ほかのアプリが変更している可能性があります）。",
                                        "読み込めないペアリングのファイルが 2 件あります。詳しくは ShareScale Host の「診断」で確認できます。",
                                        "ファイアウォールが ShareScale Host への接続をブロックしています。システム設定 › ネットワーク › ファイアウォール › オプションで、ShareScale Host を「外部からの接続を許可」にしてください。"],
                       "直近の失敗は奪い合い・更新の途中の時は出さない（Host のメニューと同じ）。文は「。」で終える。" +
                       "ログイン項目は Host の login_item ではなく ShareScale.app 側で読む（計画 2e-1。LoginItemController）")
        let full = HostPanelModel.make(.running(summary(stateJSON(pairings: (0..<32).map { pairingJSON(PairingID(bytes: [UInt8](repeating: UInt8($0), count: 16))!, "v\($0)") }))), now: now)
        XCTAssertFalse(full.canIssueCode); XCTAssertEqual(full.issueCodeTitle, "接続元の Mac を追加（上限の 32 台に達しています）")
        let waiting = HostPanelModel.make(.running(summary(stateJSON(listener: #"{"status":"waiting_for_network"}"#, tailscaleOnly: true))), now: now)
        XCTAssertFalse(waiting.canIssueCode); XCTAssertEqual(waiting.issueCodeTitle, "接続元の Mac を追加（接続を受け付けていません）")
        XCTAssertEqual(waiting.listener, "Tailscale が見つからないため、接続を受け付けていません。")
        XCTAssertEqual(HostPanelModel.make(.running(summary(stateJSON(listener: #"{"status":"port_in_use","port":47651,"retry_in":4}"#))), now: now).listener,
                       "ポート 47651 がほかのアプリ（別のユーザの ShareScale など）で使われているため、接続を受け付けられません。")
        XCTAssertEqual(HostPanelModel.make(.running(summary(stateJSON(firewall: "block_all"))), now: now).notices.count, 1)
        // ファイアウォールと FileVault の注意には「〜の設定を開く…」を添える（計画 2f-1 案 5）
        XCTAssertEqual(paused.noticeItems.map(\.action), [nil, nil, nil, .openFirewallSettings])
        XCTAssertEqual(HostPanelModel.make(.running(summary(stateJSON(firewall: "block_all"))), now: now).noticeItems.map(\.action), [.openFirewallSettings])
        // Host から来た版の文字列は切り詰める（点検 AC）
        let long = summary(stateJSON().replacingOccurrences(of: "\"version\":\"1.1.0\"", with: "\"version\":\"\(String(repeating: "9", count: 100))\""))
        XCTAssertEqual(HostPanelModel.make(.running(long), now: now).version, "ShareScale Host " + String(repeating: "9", count: 32))
    }

    // 奪い合いだけが立っている時: 設定の状態のカードの案内は 1 行だけ（直近のエラーは同じ内容なので重ねない。Host のメニューと同じ。点検 2i）
    func testContentionAloneGivesOneNoticeAndHidesTheSameLastError() {
        let error = "the scale keeps being changed back (another app may be changing it)"
        let fought = HostPanelModel.make(.running(summary(stateJSON(contention: true, lastError: error))), now: now)
        XCTAssertEqual(fought.notices, ["表示倍率が何度も元に戻されています（ほかのアプリが変更している可能性があります）。"])
        XCTAssertEqual(fought.noticeItems.map(\.action), [nil])
        // 奪い合いが下りた後は、直近のエラーとして出す。どちらも無ければ何も出さない
        XCTAssertEqual(HostPanelModel.make(.running(summary(stateJSON(lastError: error))), now: now).notices, ["直近のエラー: " + error])
        XCTAssertEqual(HostPanelModel.make(.running(summary(stateJSON())), now: now).notices, [])
        AppLanguage.current = .en
        XCTAssertEqual(HostPanelModel.make(.running(summary(stateJSON(contention: true, lastError: error))), now: now).notices,
                       ["The display scale keeps being changed back (another app may be changing it)."])
        AppLanguage.current = .ja
    }

    // 主の窓の案内に添える 1 行は、この Mac で Host が動いている時（一時停止中を含む）だけ（実機確認 2026-09-30）。名前の無い印は言語に合わせて出す
    func testHostIsRunningDecidesTheMainWindowHintAndUnnamedPlaceholderIsLocalized() {
        XCTAssertTrue(HostPanelModel.make(.running(summary(stateJSON())), now: now).hostIsRunning)
        XCTAssertTrue(HostPanelModel.make(.running(summary(stateJSON(paused: true))), now: now).hostIsRunning, "一時停止中も動いている")
        XCTAssertFalse(HostPanelModel.make(.notRunning(last: nil), now: now).hostIsRunning)
        XCTAssertFalse(HostPanelModel.make(.notRunning(last: summary(stateJSON(running: false))), now: now).hostIsRunning)
        XCTAssertFalse(HostPanelModel.make(.unknown(problem: "x"), now: now).hostIsRunning)
        XCTAssertTrue(HostPanelModel.mainWindowHint.contains("設定 › この Mac の接続先"))
        let m = HostPanelModel.make(.running(summary(stateJSON(pairings: [pairingJSON(pid(1), "名前の分からない見る側"), pairingJSON(pid(2), "名前のない Mac")]))), now: now)
        XCTAssertEqual(m.viewers.map(\.name), ["名前のない Mac", "名前のない Mac"], "以前の印も今の印も「名前のない Mac」")
        AppLanguage.current = .en
        XCTAssertEqual(HostPanelModel.make(.running(summary(stateJSON(pairings: [pairingJSON(pid(1), "名前のない Mac")]))), now: now).viewers.first?.name, "Unnamed Mac")
        XCTAssertTrue(HostPanelModel.mainWindowHint.contains("Settings › This Mac as a Target"))
    }

    func testStoppedAndUnknownHostsCannotBeOperated() {
        let never = HostPanelModel.make(.notRunning(last: nil), now: now)
        XCTAssertEqual(never.status, .stopped); XCTAssertEqual(never.statusText, "停止しています"); XCTAssertEqual(never.symbol, "xmark.circle")
        XCTAssertEqual(never.guidance, "この Mac の ShareScale Host はまだ動いていません。「この Mac を接続先にする」をオンにしてください。",
                       "スイッチが押せるようになったので HostCore の notRunningGuidance に戻した（計画 2e-1）")
        XCTAssertFalse(never.canOperate); XCTAssertFalse(never.canIssueCode)
        XCTAssertNil(never.listener); XCTAssertEqual(never.viewers, []); XCTAssertNil(never.version)
        let last = summary(stateJSON(running: false, pairings: [pairingJSON(pid(1), "Air", lastSeen: now)], tailscaleOnly: true))
        let stopped = HostPanelModel.make(.notRunning(last: last), now: now)
        XCTAssertEqual(stopped.guidance, "この Mac の ShareScale Host が動いていません。「この Mac を接続先にする」をオフにしてからもう一度オンにするか、システム設定 › 一般 › ログイン項目を確認してください。")
        XCTAssertEqual(stopped.viewers.map(\.title), ["Air"], "最後の状態の一覧は見せる（操作はできない）")
        XCTAssertTrue(stopped.tailscaleOnly); XCTAssertFalse(stopped.canOperate)
        let unknown = HostPanelModel.make(.unknown(problem: "state.json: permissions"), now: now)
        XCTAssertEqual(unknown.status, .unknown); XCTAssertEqual(unknown.symbol, "questionmark.circle"); XCTAssertEqual(unknown.statusText, "状態を読み取れません")
        XCTAssertFalse(unknown.guidance?.contains("permissions") ?? true, "生の理由は本文に出さない（点検 E）")
        XCTAssertFalse(unknown.guidance?.contains(unknown.statusText) ?? true, "見出しと同じ文を本文に重ねない（仕上げ 2026-09-30）")
        XCTAssertEqual(unknown.guidanceDetail, "state.json: permissions", "「詳細をコピー」へ")
        AppLanguage.current = .en
        XCTAssertEqual(HostPanelModel.make(.notRunning(last: nil), now: now).guidance, "ShareScale Host isn’t running on this Mac yet. Turn on Use This Mac as a Target.")
    }

    // pid が生きていない（running: true のまま落ちた Host）: 止まっている扱い。最後の一覧は見せ、操作はできない（点検 V）
    func testDeadPidWithRunningTrueIsShownAsStopped() {
        let last = summary(stateJSON(pid: 999_999, running: true, pairings: [pairingJSON(pid(1), "Air", lastSeen: now)]))
        let folder = HostControlFolder(directory: support.appendingPathComponent("host-control", isDirectory: true))
        try? folder.writeState(encoded: Data(stateJSON(pid: 999_999, running: true, pairings: [pairingJSON(pid(1), "Air", lastSeen: now)]).utf8))
        let state = HostControlClient(folder: folder, notify: {}, isAlive: { _ in false }).hostState()
        XCTAssertEqual(state, .notRunning(last: last), "running が真でも pid が生きていなければ動いていない")
        let m = HostPanelModel.make(state, now: now)
        XCTAssertEqual(m.status, .stopped); XCTAssertFalse(m.canOperate)
        XCTAssertEqual(m.viewers.map(\.name), ["Air"])
        XCTAssertEqual(m.guidance, "この Mac の ShareScale Host が動いていません。「この Mac を接続先にする」をオフにしてからもう一度オンにするか、システム設定 › 一般 › ログイン項目を確認してください。")
    }

    // 操作は Host が動いている時だけ host-control に指示を置いて通知し、少し待ってから state.json を読み直す（一時フォルダ。分散通知は送らない）
    func testStoreSendsRequestsAndRereads() async throws {
        let folder = HostControlFolder(directory: support.appendingPathComponent("host-control", isDirectory: true))
        let notified = Locked(0)
        let client = HostControlClient(folder: folder, notify: { notified.update { $0 += 1 } }, wallClock: { Date(timeIntervalSince1970: 1_800_000_000) })
        let store = HostPanelStore(client: client, clock: { 1_800_000_000 }, rereadDelays: [0.1])
        XCTAssertEqual(store.panel.status, .stopped, "state.json が無い")
        // 動いていない Host には置かない（点検 D）
        store.perform(.issueCode)
        XCTAssertEqual(store.actionMessage, "ShareScale Host が動いていません。「この Mac を接続先にする」をオンにしてから、もう一度操作してください。"); XCTAssertTrue(store.actionFailed)
        XCTAssertEqual(notified.value, 0)
        XCTAssertEqual(folder.readRequests(now: 1_800_000_000).requests, [], "指示は置かない")
        try folder.writeState(encoded: Data(stateJSON().utf8))
        store.reload()
        XCTAssertEqual(store.panel.status, .running)
        store.perform(.pause)
        XCTAssertEqual(store.actionMessage, "ShareScale Host に設定を送信しました。"); XCTAssertFalse(store.actionFailed); XCTAssertNil(store.actionDetail)
        XCTAssertEqual(notified.value, 1)
        XCTAssertEqual(folder.readRequests(now: 1_800_000_000).requests.map(\.op), [.pause])
        try folder.writeState(encoded: Data(stateJSON(paused: true).utf8))   // Host が処理して書いた
        await waitOnMain(2) { store.panel.status == .paused }
        XCTAssertEqual(store.panel.status, .paused, "操作の後に読み直す")
        store.perform(.issueCode)
        XCTAssertEqual(store.actionMessage, "ShareScale Host に接続コードの作成を指示しました。")
        // 受け付けのスイッチは、押したら読み直しまで新しい値を見せる（点検 Q）
        store.perform(.unpair(pid(1))); store.perform(.tailscaleOnly(true))
        XCTAssertTrue(store.panel.tailscaleOnly, "読み直しの前から新しい値")
        XCTAssertEqual(Set(folder.readRequests(now: 1_800_000_000).requests.map(\.op)), [.issueCode, .unpair, .setTailscaleOnly], "読んだ指示は消える（pause は上で読んだ）")
        try folder.writeState(encoded: Data(stateJSON(paused: true, tailscaleOnly: true).utf8))
        // 置けない（フォルダに書けない）→ 本文は何をすればよいかだけ、生の理由は「詳細をコピー」へ（点検 E）
        chmod(folder.directory.path, 0o500)
        defer { chmod(folder.directory.path, 0o700) }
        store.perform(.resume)
        XCTAssertTrue(store.actionFailed)
        XCTAssertEqual(store.actionMessage, "ShareScale Host に指示を送れませんでした。~/Library/Application Support/ShareScale/host-control/ のアクセス権を確認してください。")
        XCTAssertNotNil(store.actionDetail)
    }

    // 押したスイッチは、操作の後の最初の読み直しまで定期の読み直しで戻さない（再点検 軽微 4）
    func testOptimisticSwitchIsNotRevertedByPollingBeforeTheFirstReread() async throws {
        let folder = HostControlFolder(directory: support.appendingPathComponent("host-control", isDirectory: true))
        try folder.writeState(encoded: Data(stateJSON().utf8))
        // 操作の後の読み直しは 2 秒後（0.6 秒だと、負荷の下では下の 0.3 秒の待ちがそれを越えて、確かめる前に元へ戻る。計画 2g）
        let store = HostPanelStore(client: HostControlClient(folder: folder, notify: {}), clock: { 1_800_000_000 }, rereadDelays: [2.0])
        store.startPolling(every: 0.05)
        defer { store.stopPolling() }
        store.perform(.tailscaleOnly(true))
        XCTAssertTrue(store.panel.tailscaleOnly)
        try await Task.sleep(nanoseconds: 300_000_000)     // 定期の読み直しが何回か来る間（state.json は まだ false）
        XCTAssertTrue(store.panel.tailscaleOnly, "最初の読み直しまでは押した値のまま")
        await waitOnMain(8) { !store.panel.tailscaleOnly }
        XCTAssertFalse(store.panel.tailscaleOnly, "Host が処理しなければ、読み直しの後に元の値へ戻る")
    }

    // 開いている間だけ読み直す（点検 R）
    func testPollingStartsAndStops() async throws {
        let folder = HostControlFolder(directory: support.appendingPathComponent("host-control", isDirectory: true))
        try folder.writeState(encoded: Data(stateJSON().utf8))
        let store = HostPanelStore(client: HostControlClient(folder: folder, notify: {}), clock: { 1_800_000_000 }, rereadDelays: [])
        XCTAssertEqual(store.panel.status, .running); XCTAssertFalse(store.isPolling)
        store.startPolling(every: 0.05); store.startPolling(every: 0.05)
        XCTAssertTrue(store.isPolling)
        try folder.writeState(encoded: Data(stateJSON(paused: true).utf8))
        await waitOnMain(2) { store.panel.status == .paused }
        XCTAssertEqual(store.panel.status, .paused, "開いている間は読み直す")
        store.stopPolling()
        XCTAssertFalse(store.isPolling)
        try folder.writeState(encoded: Data(stateJSON(paused: false).utf8))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.panel.status, .paused, "閉じたら読み直さない")
        store.reload()
        XCTAssertEqual(store.panel.status, .running)
    }
}
