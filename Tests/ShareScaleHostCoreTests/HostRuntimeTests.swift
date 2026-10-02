import Network
import XCTest
@testable import ShareScaleEngine
@testable import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// 組み立て役を端から端まで（127.0.0.1 だけで待ち受ける。偽のディスプレイ・偽の確認の窓）
final class HostRuntimeTests: TempDirTestCase {
    var runtime: HostRuntime?
    let approver = FakeApprover(answer: true)
    let addresses = Locked<[InterfaceAddress]>([])

    override func tearDown() { runtime?.stop(); runtime = nil; super.tearDown() }

    func make(tailscaleOnly: Bool = false) -> HostRuntime {
        var c = HostRuntime.Configuration(supportDirectory: dir.appendingPathComponent("support", isDirectory: true),
                                          logDirectory: dir.appendingPathComponent("logs", isDirectory: true), machine: "MAC-TEST")
        c.port = listenPortForTests(); c.listenScope = .loopbackOnly; c.tailscaleOnly = tailscaleOnly
        c.engine.coalesceDelay = 0.02; c.engine.checkInterval = 3600
        let addresses = addresses
        let r = HostRuntime(configuration: c, displays: FakeDisplays([virtualDisplay(factor: 2)]), approver: approver,
                            identity: HostIdentity(name: { "Mac Studio" }, model: { "Mac Studio (2025)" }),
                            readAddresses: { addresses.value }, localHostName: { "studio" })
        runtime = r
        return r
    }
    func listeningPort(_ r: HostRuntime) async -> UInt16? {
        await waitFor(5) { if case .listening = r.diagnostics.listener { return true }; return false }
        if case let .listening(p) = r.diagnostics.listener { return p }
        return nil
    }
    /// 受け側を開いた回数（記録の「listener: listening」の行の数）
    func listens(_ r: HostRuntime) -> Int { Self.listens(r) }
    static func listens(_ r: HostRuntime) -> Int { r.log.recentAll(500).filter { $0.contains("listener: listening") }.count }
    /// コードの発行・名乗りの承認で受け側を開き直す（PSK の組が変わる）ので、直前の回数 `before` から 1 回増えるのを待ってからつなぐ
    func waitReopened(_ r: HostRuntime, after before: Int) async {
        await waitFor(5) { Self.listens(r) >= before + 1 }
        XCTAssertGreaterThanOrEqual(listens(r), before + 1)
    }
    func endpoint(_ p: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: p)!) }

    // 試験の Host は、一時の通信口の範囲（49152〜65535）の外で待ち受ける（計画 2g。`TestPorts`）。開き直しても同じ通信口
    func testTheTestHostListensOutsideTheEphemeralPortRange() async throws {
        let r = make()
        // 待ち受けていない時は、設定の通信口（既定の 47651 ではなく、渡した値）を診断に出す（再点検 N2）
        XCTAssertNotEqual(Int(r.configuration.port), Limits.defaultPort)
        XCTAssertEqual(r.diagnostics.port, Int(r.configuration.port), "始める前は設定の値")
        r.start()
        let listening = await listeningPort(r)
        let port = try XCTUnwrap(listening, "待ち受けが始まらない")
        XCTAssertTrue(TestPorts.range.contains(port), "\(port)")
        XCTAssertFalse((49152...65535).contains(port))
        let before = listens(r)
        XCTAssertNotNil(r.issueCode())
        await waitReopened(r, after: before)
        let again = await listeningPort(r)
        XCTAssertEqual(again, port)
        XCTAssertEqual(r.diagnostics.port, Int(port), "診断にも待ち受けている通信口が出る")
    }
    /// 付帯情報を読む関数（待つ条件の閉包から使えるよう、self を持たない）
    func metaReader() -> @Sendable (PairingID) -> HostMeta? {
        let store = hostStore()
        return { id in store.loadMetas().metas[id].flatMap(HostMeta.decode) }
    }

    // ペアリング → 確定（.meta）→ status・set・log → unpair（.key と .meta が消える）
    func testPairStatusSetLogAndUnpair() async throws {
        let r = make()
        r.start()
        guard let port = await listeningPort(r) else { return XCTFail("待ち受けが始まらない") }
        await waitFor(3) { r.monitor.pathUpdates >= 1 && !r.monitor.snapshot.interfaceNames.isEmpty }   // ネットワークの様子が届いた
        XCTAssertGreaterThanOrEqual(r.monitor.pathUpdates, 1)
        XCTAssertEqual(listens(r), 1, "起動直後にネットワークの様子が届いても開き直さない（結び付けは変わらない）")
        XCTAssertNil(r.currentCode)
        var before = listens(r)
        let code = try XCTUnwrap(r.issueCode())
        XCTAssertEqual(code.addresses, ["studio.local"]); XCTAssertEqual(code.port, Int(port))
        XCTAssertEqual(r.currentCode?.text, code.encoded(), "発行中のコードを再表示できる")
        XCTAssertEqual(r.currentCode?.expires, Date(timeIntervalSince1970: TimeInterval(code.expiresAt)))
        await waitReopened(r, after: before)
        before = listens(r)
        let newSecret = try await ViewerChannel.pair(to: endpoint(port), id: code.id, secret: code.secret, name: "MacBook Air", showCode: { _ in })
        XCTAssertEqual(approver.asked.map(\.name), ["MacBook Air"])
        XCTAssertEqual(approver.asked.first?.sourceClass, .loopback)
        let meta = metaReader()
        await waitFor(3) { meta(code.id) != nil }
        XCTAssertEqual(meta(code.id)?.confirmed, false, "承認して保存した時点では未確定")
        await waitReopened(r, after: before)
        await waitFor(3) { r.currentCode == nil }
        XCTAssertNil(r.currentCode, "名乗りが終わればコードの写しは消える")

        let st = try await ViewerChannel.exchange(.status, expecting: .status, to: endpoint(port), id: code.id, secret: newSecret)
        guard case let .status(s) = st else { return XCTFail("\(st)") }
        XCTAssertEqual(s.name, "Mac Studio"); XCTAssertEqual(s.addresses, ["studio.local"]); XCTAssertEqual(s.port, Int(port))
        await waitFor(3) { meta(code.id)?.confirmed == true }
        XCTAssertEqual(meta(code.id)?.name, "MacBook Air")
        XCTAssertNotNil(meta(code.id)?.lastSeen)
        XCTAssertEqual(r.pairings[code.id]?.confirmed, true)

        let set = try await ViewerChannel.exchange(.set(.oneX), expecting: .set, to: endpoint(port), id: code.id, secret: newSecret)
        guard case let .status(after) = set else { return XCTFail("\(set)") }
        XCTAssertEqual(after.virtualDisplay?.scaling, .oneX)
        XCTAssertEqual(after.setBy?.byYou, true)

        let lg = try await ViewerChannel.exchange(.log, expecting: .log, to: endpoint(port), id: code.id, secret: newSecret)
        guard case let .log(lines) = lg else { return XCTFail("\(lg)") }
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("applied 1x"), text)
        XCTAssertTrue(text.contains("set 1x"), text)
        XCTAssertFalse(text.contains("127.0.0.1"), "送り元は含めない")

        let un = try await ViewerChannel.exchange(.unpair, expecting: .unpair, to: endpoint(port), id: code.id, secret: newSecret)
        XCTAssertEqual(un, .ok)
        await waitFor(3) { r.pairings[code.id] == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostDir.appendingPathComponent(code.id.hex + ".key").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostDir.appendingPathComponent(code.id.hex + ".meta").path))
        let fileLog = try String(contentsOf: dir.appendingPathComponent("logs/host.log"), encoding: .utf8)
        XCTAssertTrue(fileLog.contains("pairing requested by \"MacBook Air\" from 127.0.0.1"), "送り元はファイルの記録にだけ書く")
        XCTAssertTrue(fileLog.contains("unpaired \"MacBook Air\""), fileLog)
    }
    // 起動時、.meta で確定していないペアリングは確定待ちに入る（10 分の自動解除の対象）。.meta の無いものは確定扱い
    func testUnconfirmedMetaIsPendingAfterStart() throws {
        let s = hostStore()
        try s.save(StoredPairing(id: pid(1), secret: Bytes32(Data(repeating: 1, count: 32))!))
        try s.save(StoredPairing(id: pid(2), secret: Bytes32(Data(repeating: 2, count: 32))!))
        try s.saveMeta(pid(1), HostMeta(name: "Pending", created: 1, confirmed: false).encoded())
        let r = make()
        r.start()
        XCTAssertEqual(r.registry.pendingIDs, [pid(1)])
        XCTAssertEqual(r.pairings[pid(2)]?.name, MetaBook.unknownName)
        XCTAssertEqual(r.diagnostics.pairingCount, 2)
        XCTAssertFalse(r.diagnostics.allowGlobal)
    }
    // 取り消しでコードの写しが消える
    func testRevokedCodeIsForgotten() async throws {
        let r = make()
        r.start()
        _ = await listeningPort(r)
        XCTAssertNotNil(r.issueCode())
        r.revokeCode()
        await waitFor(3) { r.currentCode == nil }
        XCTAssertNil(r.currentCode)
    }
    // 「Tailscale 経由だけ」: Tailscale が無ければ受け付けず、見つかったら開き直して受け付ける
    func testTailscaleOnlyWaitsUntilTailscaleAppears() async {
        let r = make(tailscaleOnly: true)
        r.start()
        await waitFor(5) { r.diagnostics.listener == .waitingForNetwork }
        XCTAssertEqual(r.diagnostics.listener, .waitingForNetwork)
        XCTAssertEqual(r.diagnostics.binding, .unavailable)
        XCTAssertNil(r.issueCode(), "候補アドレスが無く（通信口も未確定で）コードを出さない")
        addresses.value = [InterfaceAddress(name: "utun4", address: ip("100.101.1.2"), prefix: 32),
                           InterfaceAddress(name: "utun4", address: ip("fd7a:115c:a1e0::1"), prefix: 128)]
        r.monitor.refresh()
        let port = await listeningPort(r)
        XCTAssertNotNil(port)
        XCTAssertEqual(r.issueCode()?.addresses, ["100.101.1.2"], "Tailscale の IPv4 だけ")
    }
    // 起動した Host は、倍率を変えない外からの理由を持たずに始まり、すぐに倍率を直す（計画 2i。前は、起動時にほかの常駐を
    // 確かめ終えるまで待ち、その後も 60 秒ごとに外部コマンドを起こしていた）
    func testStartsWithoutHoldsAndCorrectsTheScale() async {
        let r = make()
        r.start()
        await waitFor(3) { r.maintainer.snapshot.target?.scale == 1 }
        XCTAssertEqual(r.maintainer.snapshot.target?.scale, 1)
        XCTAssertEqual(r.maintainer.snapshot.holds, [])
        XCTAssertNil(r.diagnostics.lastError); XCTAssertFalse(r.diagnostics.updating); XCTAssertFalse(r.diagnostics.contention)
    }
    // 奪い合い（設定した倍率が、ほかから繰り返し戻される）は、Host の診断・`state.json`・メニューの案内・診断の行・`status` の `last_error` に出る
    // （点検 2i。ほかの常駐の検出を外した後も、この一般の検出と案内は残す。前は、`HostRuntime` が診断に写す所を外しても落ちる試験が無かった）
    func testContentionReachesDiagnosticsStateFileMenuAndStatus() async throws {
        /// 倍率を変えても、すぐ 2x に戻る偽のディスプレイ（`apply` は成功を返すが、一覧は 2x のまま＝ほかのアプリが戻した形）
        final class RevertedDisplays: DisplayProvider, @unchecked Sendable {
            let applies = Locked(0)
            func listFresh() -> DisplayReading { DisplayReading(displays: [virtualDisplay(factor: 2)]) }
            func apply(uuid: String, factor: Int) -> String? { applies.update { $0 += 1 }; return nil }
            func portSession(maxAge: TimeInterval) -> Bool { true }
        }
        let displays = RevertedDisplays()
        var c = HostRuntime.Configuration(supportDirectory: dir.appendingPathComponent("support", isDirectory: true),
                                          logDirectory: dir.appendingPathComponent("logs", isDirectory: true), machine: "MAC-TEST")
        c.port = listenPortForTests(); c.listenScope = .loopbackOnly
        c.engine.coalesceDelay = 0.02; c.engine.checkInterval = 3600
        let r = HostRuntime(configuration: c, displays: displays, approver: approver,
                            identity: HostIdentity(name: { "Mac Studio" }, model: { "Mac Studio (2025)" }),
                            readAddresses: { [] }, localHostName: { "studio" })
        runtime = r
        XCTAssertFalse(r.diagnostics.contention)
        r.start()
        // 画面構成の変化のたびに判定する。直しても戻るので、60 秒に 3 回戻された所で奪い合いが立つ
        for _ in 0..<100 where !r.diagnostics.contention {
            r.displayConfigurationChanged()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(r.maintainer.snapshot.contention, "倍率の維持が奪い合いを見つけた（apply \(displays.applies.value) 回）")
        let d = r.diagnostics
        XCTAssertTrue(d.contention, "Host の診断に写る")
        XCTAssertEqual(d.lastError, "the scale keeps being changed back (another app may be changing it)", "`status` の `last_error` は、奪い合いを先に出す")
        // `state.json` に出て、ShareScale.app の側（読み手）でも同じ案内になる
        let st = HostControlState(runtime: r, running: true, system: SystemDiagnostics(), version: "1.1.0", build: 10100, now: Date())
        XCTAssertTrue(String(decoding: st.encoded(), as: UTF8.self).contains(#""updating":false,"contention":true,"last_error":"the scale keeps being changed back (another app may be changing it)""#))
        let summary = try XCTUnwrap(HostControlState.decode(st.encoded()))
        XCTAssertTrue(summary.contention)
        let notice = "表示倍率が何度も元に戻されています（ほかのアプリが変更している可能性があります）"
        XCTAssertEqual(MenuModel.notices(HostMenuFacts(summary: summary), .ja), [notice], "案内は 1 行だけ（直近のエラーは同じ内容なので重ねない）")
        XCTAssertEqual(MenuModel.notices(HostMenuFacts(diagnostics: d, pairings: [:], code: nil), .ja), [notice])
        // 診断の行
        let report = DiagnosticsReport.lines(host: d, system: SystemDiagnostics(), pairings: [:], version: "1", now: Date(), language: .ja)
        XCTAssertTrue(report.contains("✗ 表示倍率が何度も元に戻されています"), report.joined(separator: "\n"))
        // 見る側への応答
        let reply = await r.controller.respond(to: .status, from: pid(1))
        guard case let .status(payload) = reply else { return XCTFail("\(reply)") }
        XCTAssertEqual(payload.lastError, "the scale keeps being changed back (another app may be changing it)")
    }
    func testStopAndStartAgain() async {
        let r = make()
        r.start(); r.start()
        _ = await listeningPort(r)
        r.stop()
        await waitFor(3) { r.diagnostics.listener == .stopped }
        XCTAssertEqual(r.diagnostics.listener, .stopped)
        r.start()
        let port = await listeningPort(r)
        XCTAssertNotNil(port)
    }
}
