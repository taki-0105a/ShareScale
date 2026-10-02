import XCTest
@testable import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// メニューの項目の組み立て（純粋な関数。AppKit には触れない）
final class MenuModelTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func listening(_ port: UInt16 = 47651) -> HostDiagnostics {
        var d = HostDiagnostics(); d.listener = .listening(port: port); return d
    }
    func titles(_ entries: [MenuEntry]) -> [String] {
        entries.map { e in
            switch e {
            case let .status(s), let .notice(s), let .diagnostics(s), let .openLog(s), let .quit(s), let .reviewViewers(s): return s
            case let .addViewer(t, on): return (on ? "" : "(off) ") + t
            case let .showCode(t): return t
            case let .viewer(_, t, d, _, _, _): return "\(t) — \(d)"
            case let .pause(t, _): return t
            case .separator: return "—"
            }
        }
    }

    func testRunningHostWithNoViewersInJapanese() {
        let m = MenuModel.build(diagnostics: listening(), pairings: [:], code: nil, now: now, language: .ja)
        XCTAssertEqual(titles(m), ["ShareScale Host は動作中です", "ローカルネットワークと Tailscale からの接続を受け付けています（ポート 47651）", "—", "接続元の Mac を追加…", "—",
                                   "接続元の Mac はまだありません", "—", "一時停止", "診断…", "ログを開く", "—", "ShareScale Host を終了"])
    }
    func testEnglishAndPausedAndCode() {
        var d = listening(); d.paused = true
        let m = MenuModel.build(diagnostics: d, pairings: [:], code: ("sharescale1:x", now.addingTimeInterval(599.9)), now: now, language: .en)
        XCTAssertEqual(titles(m).prefix(6).map { $0 },
                       ["ShareScale Host is paused", "Accepting connections from local networks and Tailscale (port 47651)", "—", "Add a Mac to Connect From…", "Show Pairing Code… (9:59 left)", "—"])
        if case .pause(let t, _)? = m.first(where: { if case .pause = $0 { return true }; return false }) {
            XCTAssertEqual(t, "Resume")
        } else { XCTFail("pause entry") }
    }
    func testListenerStates() {
        var d = HostDiagnostics()
        d.listener = .waitingForNetwork
        XCTAssertEqual(MenuModel.listenerLine(d, .ja), "Tailscale が見つからないため、接続を受け付けていません")
        d.listener = .portInUse(port: 47651, retryIn: 8)
        XCTAssertEqual(MenuModel.listenerLine(d, .ja), "ポート 47651 がほかのアプリ（別のユーザの ShareScale など）で使われているため、接続を受け付けられません。8 秒後にもう一度試します")
        d.listener = .failed("boom", retryIn: 1)
        XCTAssertEqual(MenuModel.listenerLine(d, .en), "Can’t accept connections (boom). Trying again in 1 second")
        d.listener = .listening(port: 5); d.tailscaleOnly = true; d.tailscale = .found(interface: "utun4", v4: ip("100.101.1.2"), v6: ip("fd7a:115c:a1e0::1"))
        XCTAssertEqual(MenuModel.listenerLine(d, .ja), "Tailscale からの接続だけを受け付けています（100.101.1.2、ポート 5）")
        d.listener = .stopped
        XCTAssertEqual(MenuModel.listenerLine(d, .en), "Not accepting connections")
    }
    // 受け付けている時の 1 行は、設定の 3 つの状態で出し分ける（計画 2h。実機確認 A: 既定でも「すべてのネットワークから」と出て、実際より広く読めた）
    func testAcceptingLineHasThreeStates() {
        var d = listening()
        XCTAssertEqual(MenuModel.listenerLine(d, .ja), "ローカルネットワークと Tailscale からの接続を受け付けています（ポート 47651）", "既定: グローバルなアドレスからは受け付けない")
        XCTAssertEqual(MenuModel.listenerLine(d, .en), "Accepting connections from local networks and Tailscale (port 47651)")
        d.allowGlobal = true
        XCTAssertEqual(MenuModel.listenerLine(d, .ja), "インターネットを含むすべてのネットワークからの接続を受け付けています（ポート 47651）")
        XCTAssertEqual(MenuModel.listenerLine(d, .en), "Accepting connections from all networks, including the internet (port 47651)")
        // 「Tailscale からの接続だけ」がオンなら、「インターネットからも」がオンでも Tailscale だけ（Tailscale 以外は TLS の前に断る）
        d.tailscaleOnly = true
        XCTAssertEqual(MenuModel.listenerLine(d, .ja), "Tailscale からの接続だけを受け付けています（ポート 47651）")
        XCTAssertEqual(MenuModel.listenerLine(d, .en), "Accepting connections from Tailscale only (port 47651)")
        d.allowGlobal = false
        XCTAssertEqual(MenuModel.listenerLine(d, .ja), "Tailscale からの接続だけを受け付けています（ポート 47651）")
        // 文言は、実際に受け付ける送り元と合っている（既定ではグローバルなアドレスを断り、「インターネットからも」で受け付ける）
        let global = ip("203.0.113.7")
        XCTAssertFalse(SourceClassifier.classify(global, localNetworks: [], allowGlobal: false).accepted)
        XCTAssertTrue(SourceClassifier.classify(global, localNetworks: [], allowGlobal: true).accepted)
        // プライベートアドレスは、同じサブネットでなくても受け付ける（「同じネットワーク」ではなく「ローカルネットワーク」と書く理由。点検 2h）
        XCTAssertTrue(SourceClassifier.classify(ip("10.9.8.7"), localNetworks: [IPNetwork("192.168.1.0/24")!], allowGlobal: false).accepted)
        for inside in ["127.0.0.1", "192.168.1.5", "169.254.3.4", "100.101.1.2", "fd7a:115c:a1e0::1"] {
            XCTAssertTrue(SourceClassifier.classify(ip(inside), localNetworks: [], allowGlobal: false).accepted, inside)
        }
        // メニューと診断の一覧も同じ行
        d = listening(); d.allowGlobal = true
        let menu = MenuModel.build(diagnostics: d, pairings: [:], code: nil, now: now, language: .ja)
        XCTAssertEqual(titles(menu)[1], "インターネットを含むすべてのネットワークからの接続を受け付けています（ポート 47651）")
        let report = DiagnosticsReport.lines(host: d, system: SystemDiagnostics(), pairings: [:], version: "1", now: now, language: .en)
        XCTAssertEqual(report[2], "✓ Accepting connections from all networks, including the internet (port 47651)")
    }
    func testAddViewerIsDisabledAtTheLimitAndWhenNotListening() {
        var d = listening(); d.pairingCount = Limits.maxPairings
        let full = MenuModel.build(diagnostics: d, pairings: [:], code: nil, now: now, language: .ja)
        XCTAssertTrue(titles(full).contains("(off) 接続元の Mac を追加（上限の 32 台に達しています）"), titles(full).joined(separator: "|"))
        var w = HostDiagnostics(); w.listener = .waitingForNetwork
        let waiting = MenuModel.build(diagnostics: w, pairings: [:], code: nil, now: now, language: .en)
        XCTAssertTrue(titles(waiting).contains("(off) Add a Mac to Connect From (not accepting connections)"))
    }
    func testViewersAreSortedByNameWithDetailsAndStaleNotice() {
        var d = listening(); d.staleNotices = [pid(2)]
        let t = Int64(now.timeIntervalSince1970)
        let pairings: [PairingID: HostMeta] = [
            pid(1): HostMeta(name: "MacBook\u{200B} Air", created: t - 100, lastSeen: t - 3 * 86_400, confirmed: true),
            pid(2): HostMeta(name: "Old", created: t - 100 * 86_400, lastSeen: t - 81 * 86_400, confirmed: true),
            pid(3): HostMeta(name: "Air", created: t, confirmed: false),
            pid(4): HostMeta(name: "Zed", created: t - 10, lastSeen: nil, confirmed: true),
            pid(5): HostMeta(name: "Air", created: t, lastSeen: t - 10, confirmed: true),
        ]
        let m = MenuModel.build(diagnostics: d, pairings: pairings, code: nil, now: now, language: .ja)
        let viewers = m.compactMap { e -> (PairingID, String, String, Bool, String?)? in
            if case let .viewer(id, title, detail, stale, _, later) = e { return (id, title, detail, stale, later) }; return nil
        }
        XCTAssertEqual(viewers.map(\.0), [pid(3), pid(5), pid(1), pid(2), pid(4)], "名前の順、同じ名前は id の順")
        guard hasCount(viewers.map(\.0), 5) else { return }
        XCTAssertEqual(viewers[0].2, "確認待ち（その Mac で登録が完了していません）")
        XCTAssertEqual(viewers[1].2, "最後の接続: 今日")
        XCTAssertEqual(viewers[2].1, "MacBook Air", "制御文字（ゼロ幅スペース）は除く")
        XCTAssertEqual(viewers[2].2, "最後の接続: 3 日前")
        XCTAssertEqual(viewers[3].1, "「Old」は 80 日間使われていません。登録を解除しますか？"); XCTAssertTrue(viewers[3].3); XCTAssertEqual(viewers[3].4, "あとで")
        XCTAssertEqual(viewers[4].2, "まだ接続していません"); XCTAssertNil(viewers[4].4)
        XCTAssertFalse(titles(m).contains("接続元の Mac はまだありません"))
        // 英語は数に合わせて単数・複数を書き分ける（“day(s)” と書かない。仕上げ 2026-09-30）
        XCTAssertEqual(MenuModel.detail(pairings[pid(1)]!, now: now, .en), "Last connected: 3 days ago")
        XCTAssertEqual(MenuModel.detail(HostMeta(name: "x", created: t, lastSeen: t - 86_400, confirmed: true), now: now, .en), "Last connected: 1 day ago")
        XCTAssertEqual(MenuModel.detail(pairings[pid(3)]!, now: now, .en), "Pending confirmation (not yet finished on that Mac)")
    }
    func testNoticesInOrder() {
        var d = listening()
        d.updating = true; d.contention = true; d.lastError = "apply failed"
        d.tailscaleOnly = true; d.tailscale = .ipv4Only(interface: "utun3", v4: ip("100.100.1.1"))
        d.storeProblems = [StoreProblem(name: "x.key", reason: .loosePermissions)]
        d.engineProblem = "engine.json: read-only"; d.logProblem = "host.log: EACCES"; d.rejectedGlobalLast24h = 3
        let n = MenuModel.notices(HostMenuFacts(diagnostics: d, pairings: [:], code: nil), .ja)
        guard hasCount(n, 7, n.joined(separator: "\n")) else { return }
        XCTAssertEqual(n[0], "アップデートの途中です。ShareScale を開くと完了します")
        XCTAssertEqual(n[1], "表示倍率が何度も元に戻されています（ほかのアプリが変更している可能性があります）")
        XCTAssertTrue(n[2].hasPrefix("Tailscale の IPv6 がオフ"), "奪い合いがある時は直近の失敗（同じ内容）を重ねて出さない")
        XCTAssertEqual(n[3], "読み込めないペアリングのファイルが 1 件あります（詳しくは診断で確認できます）")
        XCTAssertEqual(n[6], "直近 24 時間に、インターネットからの接続を 3 件拒否しました")
        var plain = listening(); plain.lastError = "apply\u{7} failed"
        XCTAssertEqual(MenuModel.notices(HostMenuFacts(diagnostics: plain, pairings: [:], code: nil), .en), ["Last error: apply failed"], "直近の失敗だけの時は出す（制御文字は除く）")
        // 奪い合いだけが立っている時: 案内は 1 行だけ（直近のエラーは同じ内容なので重ねない。点検 2i。前は、更新の途中と一緒に立てた場合しか見ていなかった）
        var fought = listening(); fought.contention = true; fought.lastError = "the scale keeps being changed back (another app may be changing it)"
        for facts in [HostMenuFacts(diagnostics: fought, pairings: [:], code: nil), { var f = HostMenuFacts(); f.listener = .listening(port: 47651); f.contention = true; f.lastError = fought.lastError; return f }()] {
            XCTAssertEqual(MenuModel.notices(facts, .ja), ["表示倍率が何度も元に戻されています（ほかのアプリが変更している可能性があります）"])
            XCTAssertEqual(MenuModel.notices(facts, .en), ["The display scale keeps being changed back (another app may be changing it)"])
        }
        fought.contention = false
        XCTAssertEqual(MenuModel.notices(HostMenuFacts(diagnostics: fought, pairings: [:], code: nil), .ja), ["直近のエラー: the scale keeps being changed back (another app may be changing it)"],
                       "奪い合いが下りた後は、直近のエラーとして出す")
        var up = listening(); up.updating = true; up.lastError = "ShareScale is being updated; not changing the scale until the new Host starts"
        XCTAssertEqual(MenuModel.notices(HostMenuFacts(diagnostics: up, pairings: [:], code: nil), .en), ["An update is in progress. Open ShareScale to finish it"], "更新の途中は直近の失敗（同じ内容）を重ねない")
    }
    func testLanguageDetectionAndClock() {
        XCTAssertEqual(HostLanguage.detect(["ja-JP", "en"]), .ja)
        XCTAssertEqual(HostLanguage.detect(["en-US", "ja"]), .en)
        XCTAssertEqual(HostLanguage.detect([]), .en)
        // 並びの中で、日本語か英語の最初のもの。どちらも無ければ英語（計画 2h の点検。前は「先頭が日本語なら日本語、それ以外は英語」）
        XCTAssertEqual(HostLanguage.detect(["fr-FR", "ja-JP", "en-US"]), .ja, "日英以外 → 日本語 → 英語 の並びは日本語（標準のメニューと同じ）")
        XCTAssertEqual(HostLanguage.detect(["fr-FR", "en-GB", "ja"]), .en)
        XCTAssertEqual(HostLanguage.detect(["fr-FR", "de"]), .en)
        // macOS が言語の宣言（en・ja）から標準のメニューの言語を選ぶ決まりと、同じ答えになる。
        // 比べるのは、macOS が返すふつうの形の並び（言語、言語と地域。区切りと大文字小文字の違い、ほかの言語、空）だけ
        let lists: [[String]] = [["ja-JP", "en-JP"], ["en-US"], ["fr-FR", "ja-JP", "en-US"], ["fr-FR", "en-GB", "ja"], ["fr-FR"], [], ["zh-Hans", "ko"], ["en-AU"],
                                 ["ja"], ["en"], ["JA-jp"], ["ja_JP"], ["en_US", "ja_JP"], ["de", "EN"], ["zh-Hant-JP", "ja-US"], ["fr", "de", "ja-JP"], ["", "ja"],
                                 ["en-JP", "ja-JP"], ["ko-KR", "ja-JP"], ["zh-Hans-CN", "en-CN", "ja-CN"], ["es-419", "ja-JP"]]
        for list in lists {
            let system = Bundle.preferredLocalizations(from: ["en", "ja"], forPreferences: list).first
            XCTAssertEqual(HostLanguage.detect(list) == .ja ? "ja" : "en", system, "\(list)")
        }
        // 文字の指定が付いた形: 2 番目の部分に 4 文字で書かれた時だけ見る（別の文字なら、その言語と見ない）。
        // それ以外の形（別の文字の名前・古い名前）は対象外（この関数の答えを書いておくだけで、macOS と比べない）
        XCTAssertEqual(HostLanguage.detect(["ja-Latn"]), .en); XCTAssertEqual(HostLanguage.detect(["ja-Latn", "ja"]), .ja)
        XCTAssertEqual(HostLanguage.detect(["ja-Jpan-JP", "en"]), .ja); XCTAssertEqual(HostLanguage.detect(["en-Latn-US", "ja"]), .en)
        XCTAssertEqual(HostLanguage.detect(["Japanese"]), .en); XCTAssertEqual(HostLanguage.detect(["jpn"]), .en)
        XCTAssertEqual(HostLanguage.clock(599), "9:59"); XCTAssertEqual(HostLanguage.clock(0), "0:00"); XCTAssertEqual(HostLanguage.clock(-5), "0:00")
        XCTAssertEqual(HostLanguage.ja.displayName(" \u{1B}\u{7}\u{200B} "), "名前のない Mac", "制御文字だけの名前は名前無し扱い")
        XCTAssertEqual(HostLanguage.en.displayName(MetaBook.unknownName), "Unnamed Mac", "名前の無い印は言語に合わせて出す")
        XCTAssertEqual(HostLanguage.ja.displayName("名前の分からない見る側"), "名前のない Mac", "以前に書いた名前の無い印も置き換える")
        XCTAssertEqual(HostLanguage.ja.displayName("Taro の MacBook"), "Taro の MacBook")
    }
}

/// 確認の窓とコードの窓の表示用の値（純粋な関数）
final class PresentationTests: XCTestCase {
    func testApprovalPresentationInJapaneseAndEnglish() {
        let r = ApprovalRequest(codeID: pid(7), name: "Mac\u{200B}Book", confirmationCode: 12_345, source: "100.101.1.2", sourceClass: .sharedCGNAT)
        let ja = ApprovalPresentation(r, language: .ja)
        XCTAssertEqual(ja.title, "「MacBook」（Tailscale 経由）を追加しますか？", "題名は名前と分類（アドレスは下の行だけ。ウインドウの題名の「接続元の Mac を追加」を繰り返さない）")
        XCTAssertEqual(ja.windowTitle, "接続元の Mac を追加")
        XCTAssertEqual(ja.source, "アドレス: 100.101.1.2")
        XCTAssertEqual(ja.code, "012 345"); XCTAssertEqual(ja.codeAccessibility, "確認番号 0 1 2 3 4 5")
        XCTAssertEqual(ja.approve, "追加する"); XCTAssertEqual(ja.decline, "追加しない")
        XCTAssertTrue(ja.instruction.contains("「追加しない」をクリックしてください"))
        let en = ApprovalPresentation(ApprovalRequest(codeID: pid(7), name: "?", confirmationCode: 0, source: "?", sourceClass: .otherGlobal), language: .en)
        XCTAssertEqual(en.title, "Add “?” (via the internet)?"); XCTAssertEqual(en.source, "Address: ?"); XCTAssertEqual(en.code, "000 000")
        // 同じ Mac からの名乗り: 題名の「この Mac」だけにし、127.0.0.1 の下の行は出さない（実機確認 2026-09-30: 127.0.0.1 が 2 回出ていた）
        let local = ApprovalPresentation(ApprovalRequest(codeID: pid(7), name: "MacBook Pro", confirmationCode: 1, source: "127.0.0.1", sourceClass: .loopback), language: .ja)
        XCTAssertEqual(local.title, "「MacBook Pro」（この Mac）を追加しますか？")
        XCTAssertEqual(local.source, "")
        XCTAssertFalse(local.title.contains("127.0.0.1"))
        XCTAssertEqual(ApprovalPresentation.describe(.loopback, .en), "this Mac")
        XCTAssertEqual(ApprovalPresentation.describe(.privateV4, .ja), "同じネットワーク")
        XCTAssertEqual(ApprovalPresentation.describe(.sameNetworkGlobal, .en), "on the same network")
        XCTAssertEqual(ApprovalPresentation.describe(.uniqueLocal, .en), "via Tailscale", "括弧を重ねない（IPv6 は下の行のアドレスで分かる）")
    }

    // ⌘C の取り合い（計画 2f-1）: ⌘C は選択した文字のコピー（編集のメニュー）、接続コードの「コピー」は ⇧⌘C
    func testEditMenuKeepsCommandCForSelectedText() {
        XCTAssertEqual(EditMenuModel.items(.ja), [EditMenuModel.Item(title: "コピー", action: "copy:", key: "c"),
                                                  EditMenuModel.Item(title: "すべてを選択", action: "selectAll:", key: "a")])
        XCTAssertEqual(EditMenuModel.items(.en).map(\.title), ["Copy", "Select All"]); XCTAssertEqual(EditMenuModel.title(.en), "Edit")
        let code = PairingCode(id: pid(7), secret: Bytes32(Data(repeating: 7, count: 32))!, port: 47651, addresses: ["studio.local"], expiresAt: 1_800_000_000)!
        XCTAssertEqual(CodePresentation(code, language: .ja).copyHelp, "接続コードをコピーします（⇧⌘C）")
        XCTAssertEqual(CodePresentation(code, language: .en).copyHelp, "Copy the pairing code (⇧⌘C)")
    }
    func testCodePresentation() throws {
        let secret = try XCTUnwrap(Bytes32(Data(repeating: 9, count: 32)))
        let code = try XCTUnwrap(PairingCode(id: pid(1), secret: secret, port: 47651, addresses: ["studio.local", "100.101.1.2"], expiresAt: 1_800_000_600))
        let p = CodePresentation(code, language: .ja)
        XCTAssertEqual(p.code, code.encoded())
        XCTAssertEqual(p.address, "studio.local", "既定の通信口は付けない。アドレスは最初の 1 件")
        XCTAssertEqual(p.key, ManualEntry.grouped(ManualEntry.encodeKey(id: pid(1), secret: secret)))
        XCTAssertEqual(p.keyGroups.count, 20); XCTAssertEqual(p.keyGroups.dropLast().map(\.count), Array(repeating: 4, count: 19)); XCTAssertEqual(p.keyGroups.last?.count, 2)
        XCTAssertEqual(try ManualEntry.decodeKey(p.key).id, pid(1), "表示したキーをそのまま読み戻せる")
        XCTAssertEqual(p.expires, Date(timeIntervalSince1970: 1_800_000_600))
        XCTAssertEqual(p.remaining(now: Date(timeIntervalSince1970: 1_800_000_000.5), language: .ja), "残り 9:59")
        XCTAssertEqual(p.remaining(now: Date(timeIntervalSince1970: 1_800_000_700), language: .en), "0:00 left")
        XCTAssertEqual(CodePresentation.manualAddress("fd7a:115c:a1e0::1", port: 5000), "[fd7a:115c:a1e0::1]:5000")
        XCTAssertEqual(CodePresentation.manualAddress("192.168.1.9", port: 47651), "192.168.1.9")
        XCTAssertEqual(p.copyKey, "キーをコピー"); XCTAssertEqual(p.copyAddress, "アドレスをコピー"); XCTAssertEqual(p.copied, "コピーしました")
    }
    // コピーするもの（実機確認 2026-09-30: キー・アドレスを選べなかった）。キーは区切りを除いた 78 文字で、手入力の欄がそのまま読める。
    // 秘密（接続コード・キー）にはクリップボードの印を付け、アドレスには付けない（クリップボードそのものには触れない）
    func testClipboardItemsForCodeKeyAndAddress() throws {
        let secret = try XCTUnwrap(Bytes32(Data(repeating: 3, count: 32)))
        let code = try XCTUnwrap(PairingCode(id: pid(2), secret: secret, port: 5000, addresses: ["studio.local"], expiresAt: 1_800_000_600))
        let p = CodePresentation(code, language: .en)
        XCTAssertEqual(p.clipboard(.code).text, code.encoded()); XCTAssertTrue(p.clipboard(.code).concealed)
        let key = p.clipboard(.key)
        XCTAssertEqual(key.text.count, 78); XCTAssertFalse(key.text.contains(" ")); XCTAssertTrue(key.concealed)
        XCTAssertEqual(key.text, p.keyRaw)
        let decoded = try ManualEntry.decodeKey(key.text)
        XCTAssertEqual(decoded.id, pid(2)); XCTAssertEqual(decoded.secret, secret)
        XCTAssertEqual(p.clipboard(.address).text, "studio.local:5000"); XCTAssertFalse(p.clipboard(.address).concealed, "アドレスは秘密ではない")
        XCTAssertEqual(p.copyKey, "Copy Key"); XCTAssertEqual(p.copied, "Copied")
    }
    // 初回の起動の知らせ（実機確認 2026-09-30: メニューバーの記号が切り欠きに隠れて見つからなかった）
    func testMenuBarNoticeTextAndPreferenceFlag() {
        let ja = MenuBarNoticePresentation(language: .ja)
        XCTAssertTrue(ja.message.contains("設定 › この Mac の接続先"), ja.message)
        XCTAssertEqual(ja.close, "閉じる")
        XCTAssertTrue(MenuBarNoticePresentation(language: .en).message.contains("Settings › This Mac as a Target"))
        XCTAssertFalse(HostPreferences().menuBarNoticeShown, "既定は未表示（初回に出す）")
        var p = HostPreferences(); p.menuBarNoticeShown = true
        XCTAssertTrue(HostPreferences(dictionary: p.dictionary).menuBarNoticeShown, "出した印を保存して読み戻せる")
        XCTAssertFalse(HostPreferences(dictionary: ["menuBarNoticeShown": "yes"]).menuBarNoticeShown, "型が違えば既定値")
    }
}
