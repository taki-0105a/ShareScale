import XCTest
@testable import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// Host のメニューの元の値（`HostMenuFacts`）は、Host の様子からと `state.json` からで同じになる（計画 2f-2 案 2）
final class MenuFactsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

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

    /// Host が書く `state.json` を ShareScale.app が読んだ形（Host の書き手 `encoded` と読み手 `decode` を通す）
    func throughStateFile(_ d: HostDiagnostics, _ pairings: [PairingID: HostMeta], code: (text: String, expires: Date)?) throws -> HostMenuFacts {
        let st = HostControlState(pid: 1, version: "1.1.0", build: 10100, running: true, paused: d.paused, listener: d.listener,
                                  pairings: HostControlState.pairings(pairings, stale: Set(d.staleNotices)),
                                  codeExpires: code.map { Int64($0.expires.timeIntervalSince1970) }, host: d, system: SystemDiagnostics(), updated: 1)
        return HostMenuFacts(summary: try XCTUnwrap(HostControlState.decode(st.encoded())))
    }

    func testBothEntriesGiveTheSameMenu() throws {
        let t = Int64(now.timeIntervalSince1970)
        let pairings: [PairingID: HostMeta] = [
            pid(1): HostMeta(name: "MacBook\u{200B} Air", created: t - 100, lastSeen: t - 3 * 86_400, confirmed: true),
            pid(2): HostMeta(name: "Old", created: t - 100 * 86_400, lastSeen: t - 81 * 86_400, confirmed: true),
            pid(3): HostMeta(name: "New", created: t, confirmed: false),
        ]
        let listeners: [ListenerStatus] = [.listening(port: 47651), .waitingForNetwork, .portInUse(port: 47651, retryIn: 8.9),
                                           .failed("boom\u{7}", retryIn: 2.5), .starting, .stopped]
        let tailscales: [TailscaleDetection] = [.none, .ipv4Only(interface: "utun4", v4: ip("100.101.1.2")),
                                                .found(interface: "utun4", v4: ip("100.101.1.2"), v6: ip("fd7a:115c:a1e0::1"))]
        let code = (text: "sharescale1:x", expires: now.addingTimeInterval(421.7))
        for l in listeners {
            for ts in tailscales {
                for (paused, flags) in [(false, false), (true, true)] {
                    var d = HostDiagnostics()
                    d.listener = l; d.tailscale = ts; d.tailscaleOnly = true; d.paused = paused
                    d.contention = flags; d.updating = flags
                    d.lastError = "x\u{7}y"; d.storeProblems = [StoreProblem(name: "x.key", reason: .unreadable)]; d.engineProblem = "e"; d.logProblem = "l"
                    d.rejectedGlobalLast24h = 2; d.pairingCount = pairings.count; d.staleNotices = [pid(2)]
                    let host = HostMenuFacts(diagnostics: d, pairings: pairings, code: code)
                    let app = try throughStateFile(d, pairings, code: code)
                    XCTAssertEqual(app, host, "\(l) \(ts) \(paused)")
                    for L in [HostLanguage.ja, .en] {
                        XCTAssertEqual(MenuModel.build(app, now: now, language: L),
                                       MenuModel.build(diagnostics: d, pairings: pairings, code: code, now: now, language: L), "\(l) \(ts) \(L)")
                    }
                }
            }
        }
    }

    /// Host の様子から作ったものと state.json を通したものが、値もメニューも同じか
    func assertSame(_ d: HostDiagnostics, _ pairings: [PairingID: HostMeta], code: (text: String, expires: Date)?, _ label: String,
                    file: StaticString = #filePath, line: UInt = #line) throws {
        let host = HostMenuFacts(diagnostics: d, pairings: pairings, code: code)
        let app = try throughStateFile(d, pairings, code: code)
        XCTAssertEqual(app, host, label, file: file, line: line)
        for L in [HostLanguage.ja, .en] {
            XCTAssertEqual(MenuModel.build(app, now: now, language: L), MenuModel.build(host, now: now, language: L), label, file: file, line: line)
            XCTAssertEqual(MenuModel.companion(app, now: now, language: L), MenuModel.companion(host, now: now, language: L), label, file: file, line: line)
        }
    }

    // 真偽の項目を 1 つずつ別々に立てる（同じ値をまとめて立てると、項目の取り違えを捕まえられない。点検 2f-2）。
    // 一時の写しで `contention = s.updating`・`tailscaleOnly = true` と壊すと、この試験が落ちることを確かめた
    func testEachFlagAloneAndTheEmptyCases() throws {
        var base = HostDiagnostics(); base.listener = .listening(port: 47651)
        try assertSame(base, [:], code: nil, "何も立てない・tailscaleOnly オフ・コード無し・接続元 0 件")
        let flags: [(String, WritableKeyPath<HostDiagnostics, Bool>)] = [("paused", \.paused), ("tailscaleOnly", \.tailscaleOnly), ("allowGlobal", \.allowGlobal),
                                                                         ("updating", \.updating), ("contention", \.contention)]
        for (name, key) in flags {
            var d = base; d[keyPath: key] = true
            try assertSame(d, [:], code: nil, name)
            let f = try throughStateFile(d, [:], code: nil)
            XCTAssertEqual(f.paused, name == "paused"); XCTAssertEqual(f.tailscaleOnly, name == "tailscaleOnly")
            XCTAssertEqual(f.allowGlobal, name == "allowGlobal", "受け付けの行の出し分けに使う（計画 2h）")
            XCTAssertEqual(f.updating, name == "updating")
            XCTAssertEqual(f.contention, name == "contention", name)
        }
        // 受け付けの行は、state.json を通しても 3 つの状態で出し分ける（計画 2h。ShareScale のメニューの「この Mac の接続先」）
        var internet = base; internet.allowGlobal = true
        XCTAssertEqual(titles(MenuModel.companion(try throughStateFile(base, [:], code: nil), now: now, language: .ja))[1],
                       "ローカルネットワークと Tailscale からの接続を受け付けています（ポート 47651）")
        XCTAssertEqual(titles(MenuModel.companion(try throughStateFile(internet, [:], code: nil), now: now, language: .ja))[1],
                       "インターネットを含むすべてのネットワークからの接続を受け付けています（ポート 47651）")
        XCTAssertEqual(titles(MenuModel.companion(try throughStateFile(internet, [:], code: nil), now: now, language: .en))[1],
                       "Accepting connections from all networks, including the internet (port 47651)")
        var both = internet; both.tailscaleOnly = true
        XCTAssertEqual(titles(MenuModel.companion(try throughStateFile(both, [:], code: nil), now: now, language: .ja))[1],
                       "Tailscale からの接続だけを受け付けています（ポート 47651）", "Tailscale だけがオンなら、Tailscale だけ")
        // pairing_count を pairings の件数と違う値に（上限の判定は pairing_count を使う）
        var full = base; full.pairingCount = Limits.maxPairings
        let t = Int64(now.timeIntervalSince1970)
        let one: [PairingID: HostMeta] = [pid(1): HostMeta(name: "Air", created: t, lastSeen: t - 10, confirmed: true)]
        try assertSame(full, one, code: nil, "pairing_count ≠ pairings.count")
        XCTAssertEqual(try throughStateFile(full, one, code: nil).pairingCount, Limits.maxPairings)
        XCTAssertTrue(titles(MenuModel.companion(try throughStateFile(full, one, code: nil), now: now, language: .ja)).contains("(off) 接続元の Mac を追加（上限の 32 台に達しています）"))
        // 数の項目も 1 つずつ
        var counts = base; counts.rejectedGlobalLast24h = 3
        try assertSame(counts, [:], code: nil, "rejected")
        var problems = base; problems.storeProblems = [StoreProblem(name: "a.key", reason: .unreadable), StoreProblem(name: "b.key", reason: .unreadable)]
        try assertSame(problems, [:], code: nil, "storeProblems")
    }

    func testOlderStateFileWithoutTheMenuKeysStillReads() throws {
        // 2f-2 より前の Host が書いた `state.json`（`tailscale_ipv4` が無い・`listener` に `detail` が無い）も読め、既定値になる
        let json = #"{"format":1,"pid":1,"version":"1.0.0","build":10000,"running":true,"paused":false,"listener":{"status":"failed"},"pairings":[],"diagnostics":{"tailscale_only":true,"allow_global":false,"tailscale":"found","updating":false,"contention":false,"last_error":null,"store_problems":0,"firewall":"off","filevault":null,"login_item":"enabled"},"updated":1}"#
        let s = try XCTUnwrap(HostControlState.decode(Data(json.utf8)))
        let f = HostMenuFacts(summary: s)
        XCTAssertEqual(f.listener, .failed(detail: "", retryIn: 0))
        XCTAssertNil(f.tailscaleIPv4); XCTAssertEqual(f.pairingCount, 0); XCTAssertEqual(f.rejectedGlobalLast24h, 0)
        XCTAssertEqual(MenuModel.listenerLine(f, .ja), "接続を受け付けられません（）。0 秒後にもう一度試します")
        // `allow_global` は始めから `state.json` にある（書式は変えていない。計画 2h）。古い Host の「インターネットからも」も読める
        let internet = json.replacingOccurrences(of: #""listener":{"status":"failed"}"#, with: #""listener":{"status":"listening","port":47651}"#)
            .replacingOccurrences(of: #""tailscale_only":true,"allow_global":false"#, with: #""tailscale_only":false,"allow_global":true"#)
        let g = HostMenuFacts(summary: try XCTUnwrap(HostControlState.decode(Data(internet.utf8))))
        XCTAssertTrue(g.allowGlobal)
        XCTAssertEqual(MenuModel.listenerLine(g, .ja), "インターネットを含むすべてのネットワークからの接続を受け付けています（ポート 47651）")
    }

    // `state.json` の読み手は、知らない項目を読み飛ばす（項目を足したり外したりした別の版の Host が書いたものも読める。計画 2i で `diagnostics` から
    // 項目を 1 つ外した時に、新しい ShareScale.app が入れ替わる前の Host の `state.json` を読めることを、この性質で保つ）。
    // 書き手が書く `diagnostics` の項目は、ここに挙げた並びだけ（足す・外す時は、読み手が求める項目と、版が食い違う間の読め方を確かめてから）
    func testStateFileReaderSkipsUnknownKeysAndTheWriterKeepsItsKeyList() throws {
        var d = HostDiagnostics(); d.listener = .listening(port: 47651); d.contention = true
        let st = HostControlState(pid: 42, version: "1.1.0", build: 10100, running: true, paused: false, listener: d.listener, pairings: [],
                                  codeExpires: nil, host: d, system: SystemDiagnostics(), updated: 1_800_000_000)
        let text = String(decoding: st.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains(#""diagnostics":{"tailscale_only":false,"allow_global":false,"tailscale":"none","updating":false,"contention":true,"last_error":null,"#
                                    + #""store_problems":0,"engine_problem":null,"log_problem":null,"rejected_global_24h":0,"pairing_count":0,"#
                                    + #""firewall":"unknown","filevault":null,"login_item":"unknown"},"updated":1800000000}"#), text)
        let now = try XCTUnwrap(HostControlState.decode(st.encoded()), "今の書き手が書いたものを読める")
        // 別の版の Host が、`diagnostics` や根に項目を足していても読める（真偽・文字・数・入れ子のどれでも）
        for extra in [#""another_agent_running":true,"#, #""another_agent_running":false,"#, #""note":"x","count":3,"nested":{"a":[1,2]},"#] {
            let other = text.replacingOccurrences(of: #""tailscale":"none","updating""#, with: #""tailscale":"none","# + extra + #""updating""#)
                .replacingOccurrences(of: #"{"format":1,"#, with: #"{"format":1,"added_later":null,"#)
            XCTAssertNotEqual(other, text)
            let s = try XCTUnwrap(HostControlState.decode(Data(other.utf8)), extra)
            XCTAssertEqual(s, now, "知らない項目は読み飛ばす（ほかの値は同じ）: " + extra)
            XCTAssertEqual(HostMenuFacts(summary: s), HostMenuFacts(diagnostics: d, pairings: [:], code: nil))
            XCTAssertEqual(MenuModel.notices(HostMenuFacts(summary: s), .ja), ["表示倍率が何度も元に戻されています（ほかのアプリが変更している可能性があります）"])
        }
        // 書式の番号は 1 のまま（番号を変えると、別の版のアプリと Host が互いの `state.json` を一切読めなくなる）
        XCTAssertEqual(HostControlState.format, 1); XCTAssertTrue(text.hasPrefix(#"{"format":1,"#))
        XCTAssertNil(HostControlState.decode(Data(text.replacingOccurrences(of: #"{"format":1,"#, with: #"{"format":2,"#).utf8)))
    }

    func testCompanionSectionPicksTheStatusNoticesAndActions() {
        var f = HostMenuFacts()
        f.listener = .listening(port: 47651); f.contention = true; f.pairingCount = 1
        f.codeExpires = Int64(now.timeIntervalSince1970) + 421
        f.viewers = [HostMenuFacts.Viewer(id: pid(1), name: "Air", lastSeen: nil, confirmed: true, stale: false)]
        XCTAssertEqual(titles(MenuModel.companion(f, now: now, language: .ja)),
                       ["ShareScale Host は動作中です", "ローカルネットワークと Tailscale からの接続を受け付けています（ポート 47651）",
                        "表示倍率が何度も元に戻されています（ほかのアプリが変更している可能性があります）", "接続元の Mac を追加…",
                        "接続コードを表示…（残り 7:01）", "一時停止", "診断…"], "受け付けの行はいつも出す（点検 2f-2）")
        f.paused = true; f.contention = false; f.codeExpires = nil; f.listener = .waitingForNetwork
        f.viewers.append(HostMenuFacts.Viewer(id: pid(2), name: "Old", lastSeen: 1, confirmed: true, stale: true))
        f.viewers.append(HostMenuFacts.Viewer(id: pid(3), name: "Older", lastSeen: 1, confirmed: true, stale: true))
        let paused = MenuModel.companion(f, now: now, language: .en)
        XCTAssertEqual(titles(paused),
                       ["ShareScale Host is paused", "Not accepting connections because Tailscale wasn’t found", "Some Macs haven’t connected in 80 days…",
                        "(off) Add a Mac to Connect From (not accepting connections)", "Resume", "Diagnostics…"],
                       "80 日の知らせは何台でも 1 行にまとめる（押すと設定へ）")
        XCTAssertTrue(paused.contains(.pause(title: "Resume", resume: true)), "押すと再開（判断はメニューの項目に持つ）")
        XCTAssertTrue(titles(MenuModel.companion(f, now: now, language: .ja)).contains("80 日間使われていない接続元の Mac があります…"))
    }
}
