import XCTest
@testable import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// ファイアウォール・FileVault の出力の解析と、診断の行（実物の `socketfilterfw`・`fdesetup`・`SMAppService` は呼ばない）
final class SystemDiagnosticsTests: XCTestCase {
    func testFirewallGlobalStateParsing() {
        XCTAssertEqual(FirewallOutput.globalState("Firewall is enabled. (State = 1)\n"), 1)
        XCTAssertEqual(FirewallOutput.globalState("Firewall is disabled. (State = 0)"), 0)
        XCTAssertEqual(FirewallOutput.globalState("Firewall is enabled. (State = 2)"), 2)
        XCTAssertNil(FirewallOutput.globalState("")); XCTAssertNil(FirewallOutput.globalState("State = x"))
    }
    // 文言は実測（2026-09-26・Darwin 27・sudo なし・確認の画面なし）
    let exe = "/Users/me/Applications/ShareScale.app/Contents/Library/LoginItems/ShareScale Host.app/Contents/MacOS/ShareScaleHost"
    let bundle = "/Users/me/Applications/ShareScale.app/Contents/Library/LoginItems/ShareScale Host.app"
    // 1 件目は実測どおり（コロンの前後に空白 1 つ・パスの末尾に空白 1 つ・次行は 13 個の空白と括弧内に空白なし）。2・3 件目は空白の違いにも耐えることの確かめ
    let list = "Total number of apps = 3\n1 : /Applications/Zoom.app \n             (Allow incoming connections)\n" +
        "2 :  /Users/me/Applications/ShareScale.app/Contents/Library/LoginItems/ShareScale Host.app\n \t ( Block incoming connections )\n" +
        "3 :  /Applications/Other.app\n \t ( Allow incoming connections )\n"
    func testBlockAllAndAppBlockedParsing() {
        XCTAssertEqual(FirewallOutput.blockAll("Firewall has block all state set to disabled.\n"), false)
        XCTAssertEqual(FirewallOutput.blockAll("Firewall has block all state set to enabled."), true)
        XCTAssertEqual(FirewallOutput.blockAll("Firewall is set to block all non-essential incoming connections"), true)
        XCTAssertNil(FirewallOutput.blockAll("???"))
        XCTAssertEqual(FirewallOutput.appBlocked("Incoming connection to \(exe) is blocked."), true)
        XCTAssertNil(FirewallOutput.appBlocked("Incoming connection to \(exe) is permitted."), "規則に無いものも permitted と出るので、許可とは読まない")
        XCTAssertNil(FirewallOutput.appBlocked("Usage: socketfilterfw …"))
    }
    func testListAppsAndAppRule() {
        let apps = FirewallOutput.listApps(list)
        XCTAssertEqual(apps.map(\.path), ["/Applications/Zoom.app", bundle, "/Applications/Other.app"])
        XCTAssertEqual(apps.map(\.allowed), [true, false, true])
        XCTAssertEqual(FirewallOutput.appRule(list: apps, executable: exe, bundle: bundle), .blocked, "バンドルのパスで一致")
        XCTAssertEqual(FirewallOutput.appRule(list: [(bundle + "/Contents/MacOS/ShareScaleHost", true)], executable: exe, bundle: bundle), .allowed, "実行体のパスで一致")
        XCTAssertEqual(FirewallOutput.appRule(list: apps, executable: "/x/ShareScaleHost", bundle: nil), .notInRules)
        XCTAssertEqual(FirewallOutput.appRule(list: [("/Applications/Zoom.app", true)], executable: "/x", bundle: "/Applications/Zoo"), .notInRules, "バンドルのパスは `/` 区切りで比べる")
        XCTAssertTrue(FirewallOutput.listApps("Total number of apps = 0").isEmpty)
        XCTAssertEqual(FirewallOutput.listApps("1 : /a\n2 : /b\n ( Block incoming connections )").map(\.path), ["/b"], "状態の行が無い項目は飛ばす")
    }
    func testFirewallStatusCombination() {
        let ok: (Int32?, String) = (0, "Firewall has block all state set to disabled.")
        let permitted: (Int32?, String) = (0, "Incoming connection to \(exe) is permitted.")
        func st(_ g: (Int32?, String), blockAll: (Int32?, String) = ok, list l: (Int32?, String), app: (Int32?, String) = (0, "")) -> FirewallStatus {
            FirewallOutput.status(global: g, blockAll: blockAll, list: l, app: app, executable: exe, bundle: bundle)
        }
        XCTAssertEqual(st((0, "Firewall is disabled. (State = 0)"), list: (0, list)), .off)
        XCTAssertEqual(st((0, "Firewall is enabled. (State = 1)"), list: (0, list), app: permitted), .on(.blocked), "--listapps の規則が勝つ")
        XCTAssertEqual(st((0, "State = 1"), list: (0, "Total number of apps = 0"), app: permitted), .on(.notInRules), "permitted でも規則に無ければ「規則なし」")
        XCTAssertEqual(st((0, "State = 1"), list: (255, ""), app: (0, "Incoming connection to \(exe) is blocked.")), .on(.blocked), "一覧が読めない時は blocked の検出だけ")
        XCTAssertEqual(st((0, "State = 1"), list: (255, ""), app: permitted), .on(.unknown))
        XCTAssertEqual(st((0, "State = 2"), list: (0, list)), .blockAll)
        XCTAssertEqual(st((0, "State = 1"), blockAll: (0, "Firewall has block all state set to enabled."), list: (0, list)), .blockAll)
        XCTAssertEqual(st((nil, ""), list: (0, list)), .unknown("socketfilterfw --getglobalstate: exit none"))
        XCTAssertEqual(st((1, "sudo required"), list: (0, list)), .unknown("socketfilterfw --getglobalstate: exit 1"))
    }
    func testFileVaultParsing() {
        XCTAssertEqual(FileVaultOutput.isOn(status: 0, output: "FileVault is On.\n"), true)
        XCTAssertEqual(FileVaultOutput.isOn(status: 0, output: "FileVault is Off."), false)
        XCTAssertNil(FileVaultOutput.isOn(status: 1, output: "FileVault is On.")); XCTAssertNil(FileVaultOutput.isOn(status: 0, output: "Deferred enablement"))
    }
    func testChecksUseTheRunnerWithTheExpectedArguments() {
        let calls = Locked<[[String]]>([])
        let run: SystemChecks.Runner = { url, args, _ in
            calls.update { $0.append([url.path] + args) }
            if args.first == "--getglobalstate" { return (0, "Firewall is enabled. (State = 1)") }
            if args.first == "--getblockall" { return (0, "Firewall has block all state set to disabled.") }
            if args.first == "--listapps" { return (0, "Total number of apps = 1\n1 :  /Applications/H.app\n \t ( Allow incoming connections )") }
            if args.first == "--getappblocked" { return (0, "Incoming connection to \(args.dropFirst().first ?? "") is permitted.") }
            return (0, "FileVault is Off.")
        }
        XCTAssertEqual(SystemChecks.firewall(executable: "/Applications/H.app/Contents/MacOS/ShareScaleHost", bundle: "/Applications/H.app", run: run), .on(.allowed))
        XCTAssertEqual(SystemChecks.fileVault(run: run), false)
        XCTAssertEqual(calls.value, [
            ["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate"],
            ["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getblockall"],
            ["/usr/libexec/ApplicationFirewall/socketfilterfw", "--listapps"],
            ["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getappblocked", "/Applications/H.app/Contents/MacOS/ShareScaleHost"],
            ["/usr/bin/fdesetup", "status"],
        ], "sudo は付けない")
    }
    func testReportLinesContainGuidanceAndNoSecrets() {
        var d = HostDiagnostics(); d.listener = .listening(port: 47651)
        d.storeProblems = [StoreProblem(name: pid(3).hex + ".key", reason: .wrongOwner), StoreProblem(name: "/x/pairings", reason: .folderLoosePermissions)]
        d.rejectedGlobalLast24h = 2
        var s = SystemDiagnostics(); s.firewall = .on(.blocked); s.fileVault = false; s.loginItem = .requiresApproval
        let t = Int64(1_800_000_000)
        let pairings = [pid(1): HostMeta(name: "MacBook", created: t - 10, lastSeen: t - 86_400 * 2, confirmed: true)]
        let lines = DiagnosticsReport.lines(host: d, system: s, pairings: pairings, version: "1.1.0 (10100)", now: Date(timeIntervalSince1970: TimeInterval(t)), language: .ja)
        let text = lines.joined(separator: "\n")
        XCTAssertEqual(lines.prefix(3), ["ShareScale Host 1.1.0 (10100)", "✓ 動作中", "✓ ローカルネットワークと Tailscale からの接続を受け付けています（ポート 47651）"])
        XCTAssertTrue(text.contains("✗ ファイアウォールが ShareScale Host への接続をブロックしています"), text)
        XCTAssertTrue(text.contains("✗ ログイン項目で ShareScale がオフになっています"), text)
        XCTAssertTrue(text.contains("✗ FileVault がオフです"), text)
        XCTAssertTrue(text.contains("✗ 読み込めないペアリングのファイル（ペアリングし直すか、アクセス権を直してください）: 03030303….key (wrongOwner), /x/pairings (folderLoosePermissions)"), text)
        XCTAssertTrue(text.contains("? 直近 24 時間に、インターネットからの接続を 2 件拒否しました"), text)
        XCTAssertTrue(text.contains("接続元の Mac: 1 台\n  MacBook (01010101) — 最後の接続: 2 日前"), text)
        XCTAssertFalse(text.contains(pid(1).hex), "id は先頭 8 文字だけ")
        let en = DiagnosticsReport.lines(host: HostDiagnostics(), system: SystemDiagnostics(), pairings: [:], version: "0", now: Date(), language: .en)
        XCTAssertTrue(en.contains("✗ Not accepting connections")); XCTAssertTrue(en.contains("? Can’t read the firewall state: not checked"))
        XCTAssertTrue(en.contains("? Login item: unknown")); XCTAssertTrue(en.contains("? FileVault: unknown")); XCTAssertTrue(en.contains("Macs allowed to connect: 0"))
        XCTAssertTrue(en.contains("✓ Last error: none"))
    }
    // 通信口が一時の通信口の範囲（49152〜65535）の時は注意を 1 行出す（黙って既定に戻さない。計画 2g の点検）
    func testReportWarnsWhenThePortIsInTheEphemeralRange() {
        func lines(_ port: Int, _ L: HostLanguage, listener: ListenerStatus? = nil) -> [String] {
            var d = HostDiagnostics(); d.port = port
            d.listener = listener ?? .listening(port: UInt16(port))
            return DiagnosticsReport.lines(host: d, system: SystemDiagnostics(), pairings: [:], version: "1", now: Date(), language: L)
        }
        let ja = "✗ ポート 50000 は 49152〜65535 の範囲です。この範囲のポートは macOS がほかの通信に割り当てるため、ポートを取られて接続を受け付けられなくなることがあります。ポートを 49152 より小さい値（既定は 47651）に戻してください"
        XCTAssertEqual(lines(50000, .ja)[2], "✓ ローカルネットワークと Tailscale からの接続を受け付けています（ポート 50000）")
        XCTAssertEqual(lines(50000, .ja)[3], ja, "受け付けの行のすぐ後に出す")
        XCTAssertTrue(lines(50000, .en).contains("✗ Port 50000 is in the range 49152–65535. macOS hands out ports in this range to other connections, so the port can be taken and ShareScale Host may stop accepting connections. Set the port back to a value below 49152 (the default is 47651)"))
        XCTAssertTrue(lines(49152, .ja).contains { $0.contains("ポート 49152 は 49152〜65535 の範囲です") })
        XCTAssertTrue(lines(65535, .ja).contains { $0.contains("ポート 65535 は 49152〜65535 の範囲です") })
        for ok in [47651, 49151, 1024] {
            XCTAssertFalse(lines(ok, .ja).contains { $0.contains("49152〜65535") }, "\(ok)")
        }
        XCTAssertTrue(lines(50000, .ja, listener: .portInUse(port: 50000, retryIn: 1)).contains(ja), "待ち受けられていない時（使用中）も出す")
        XCTAssertTrue(lines(50000, .ja, listener: .stopped).contains(ja), "止まっている時も、設定の通信口で出す")
        XCTAssertEqual(HostDiagnostics().port, 47651, "既定の通信口では出ない")
        XCTAssertEqual(Limits.ephemeralPortRange, 49152...65535); XCTAssertFalse(Limits.ephemeralPortRange.contains(Limits.defaultPort))
        let item = DiagnosticsReport.items(host: { var d = HostDiagnostics(); d.port = 50000; return d }(), system: SystemDiagnostics(), pairings: [:],
                                           version: "1", now: Date(), language: .ja).first { $0.text.contains("49152") }
        XCTAssertEqual(item?.mark, .bad); XCTAssertNil(item?.action, "システム設定で直すものではない")
    }
    // 奪い合いの行（点検 2i。ほかの常駐との競合の行を外した後も、この行は残す。相手の名前は挙げない）
    func testReportShowsContentionOnlyWhileItIsDetected() {
        var d = HostDiagnostics(); d.listener = .listening(port: 47651)
        func lines(_ L: HostLanguage) -> [String] { DiagnosticsReport.lines(host: d, system: SystemDiagnostics(), pairings: [:], version: "1", now: Date(), language: L) }
        XCTAssertFalse(lines(.ja).contains { $0.contains("元に戻されています") }, "立っていない時は出さない")
        XCTAssertEqual(lines(.ja).filter { $0.hasPrefix("✗") }, [])
        d.contention = true; d.lastError = "the scale keeps being changed back (another app may be changing it)"
        let ja = lines(.ja), en = lines(.en)
        XCTAssertEqual(ja.filter { $0.hasPrefix("✗") }, ["✗ 表示倍率が何度も元に戻されています"], "1 行だけ（直近のエラーは同じ内容なので重ねない。メニュー・設定のカードと同じ。再点検 2i）")
        XCTAssertFalse(ja.contains { $0.contains("直近のエラー") }, ja.joined(separator: "\n"))
        XCTAssertEqual(en.filter { $0.hasPrefix("✗") }, ["✗ The display scale keeps being changed back"])
        // 奪い合いが下りた後は、直近のエラーの行に出る。どちらも無ければ「なし」
        d.contention = false
        XCTAssertEqual(lines(.ja).filter { $0.hasPrefix("✗") }, ["✗ 直近のエラー: the scale keeps being changed back (another app may be changing it)"])
        d.lastError = nil
        XCTAssertTrue(lines(.ja).contains("✓ 直近のエラー: なし"))
        d.contention = true; d.lastError = "the scale keeps being changed back (another app may be changing it)"
        XCTAssertTrue(en.contains("✗ The display scale keeps being changed back"), en.joined(separator: "\n"))
        // FileVault の行の次に出る（前は、その間に、ほかの常駐との競合の行があった）
        guard let i = ja.firstIndex(of: "✗ 表示倍率が何度も元に戻されています"), i > 0 else { return XCTFail("奪い合いの行が無い") }
        XCTAssertTrue(ja[i - 1].hasPrefix("? FileVault"), ja[i - 1])
        let item = DiagnosticsReport.items(host: d, system: SystemDiagnostics(), pairings: [:], version: "1", now: Date(), language: .ja).first { $0.text.contains("元に戻されています") }
        XCTAssertEqual(item?.mark, .bad); XCTAssertNil(item?.action, "システム設定で直すものではない")
    }
    func testReportShowsRulesLoginItemNotFoundAndUpdatingWithoutDuplicateFailure() {
        var s = SystemDiagnostics(); s.loginItem = .notFound; s.firewall = .on(.notInRules)
        var d = HostDiagnostics(); d.updating = true; d.lastError = "ShareScale is being updated; not changing the scale until the new Host starts"
        let ja = DiagnosticsReport.lines(host: d, system: s, pairings: [:], version: "1", now: Date(), language: .ja)
        XCTAssertTrue(ja.contains("? ログイン項目: ShareScale で確認してください（ShareScale Host からは読み取れません）"), ja.joined(separator: "\n"))
        // まだ一覧に無い時は、確認が出たら「許可」を押すことまで言う（計画 2i。実機確認 B: 確認が出ている間、接続元は「接続できません」で止まった）。
        // 確認が出る時機は言い切らない（macOS 27 で、初めて接続を受けた時に出ることを確かめただけ。点検 2i）
        XCTAssertTrue(ja.contains("? ファイアウォール: オン（ShareScale Host はまだ一覧にありません。初めて接続を受けた時に、macOS が許可を求めることがあります。その時は「許可」をクリックしてください）"))
        XCTAssertTrue(DiagnosticsReport.lines(host: d, system: s, pairings: [:], version: "1", now: Date(), language: .en)
            .contains("? Firewall: on (ShareScale Host isn’t listed yet. macOS may ask the first time ShareScale Host receives a connection; if macOS asks, click Allow)"))
        XCTAssertTrue(ja.contains("✗ アップデートの途中です。ShareScale を開くと完了します"))
        XCTAssertFalse(ja.contains { $0.contains("直近のエラー") }, "更新の途中の時は直近の失敗（同じ内容）を重ねない")
        s.firewall = .on(.unknown)
        XCTAssertTrue(DiagnosticsReport.lines(host: d, system: s, pairings: [:], version: "1", now: Date(), language: .en).contains("? Firewall: on (can’t read the setting for ShareScale Host)"))
        XCTAssertEqual(DiagnosticsReport.shortName("notes.txt"), "notes.txt"); XCTAssertEqual(DiagnosticsReport.shortName(pid(1).hex + ".meta"), "01010101….meta")
    }
}
