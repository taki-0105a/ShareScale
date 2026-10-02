import Network
import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

/// 試験用の Host の本体（確認の窓と応答）
final class FakeApp: HostApplication, @unchecked Sendable {
    let approve = Locked<@Sendable (String, Int) -> Bool>({ _, _ in true })
    let approveHold = Locked(false)   // true の間は承認の答えを出さずに待つ（承認待ちの最中を試す）
    let shownCodes = Locked<[Int]>([])
    let shownSourceClasses = Locked<[SourceClass]>([])
    let respondDelay = Locked<Double>(0)
    let respondHold = Locked(false)   // true の間は応答を返さずに待つ（接続を開いたままにして、その間の受け付けを試す。時間の決め打ちをしない）
    let responding = Counter()        // `respond` が呼ばれた回数（照合が済んで、応答を作る所まで来た）
    let respondUntilCancelled = Locked(false)
    let cancellations = Counter()
    let status: StatusPayload
    init(status: StatusPayload) { self.status = status }
    func approvePairing(codeID: PairingID, name: String, confirmationCode: Int, source: String, sourceClass: SourceClass) async -> Bool {
        shownCodes.update { $0.append(confirmationCode) }; shownSourceClasses.update { $0.append(sourceClass) }
        while approveHold.value, !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
        return approve.value(name, confirmationCode)
    }
    func respond(to request: Request, from id: PairingID) async -> Response {
        responding.add()
        while respondHold.value, !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
        if respondUntilCancelled.value {
            let w = CancelWaiter()
            await withTaskCancellationHandler { await w.wait() } onCancel: { cancellations.add(); w.cancel() }
            return .ok
        }
        let d = respondDelay.value
        if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) }
        return .status(status)
    }
}

/// HostServer を、ループバック・一時的な保管・差し替えた送り元で動かす
final class ServerHarness: @unchecked Sendable {
    let base: URL
    let store: SecretStore
    let registry: PairingRegistry
    let app: FakeApp
    let events = Locked<[HostEvent]>([])
    let port = Locked<UInt16?>(listenPortForTests())   // 通信口 0 にしない（`TestPorts`。開き直しても同じ通信口。見つからなければ試験を失敗にする）
    private let hasListened = Locked(false)             // 1 度でも待ち受けた（その後の「使用中」では通信口を取り直さない）
    let spoofedSources = Locked<[ShareScaleProtocol.IPAddress]>([])
    let clockOffset = Locked<Duration>(.zero)
    var server: HostServer!
    static let status = StatusPayload(name: "Studio", model: "Mac Studio", paused: false, session: true, mode: .oneX, virtualDisplay: nil,
                                      ambiguous: false, lastError: nil, setBy: nil, port: 47651, addresses: ["studio.local"])!

    /// `makeParameters` に渡された受け付けるネットワーク（開き直しのたびに 1 つ）
    let networksSeen = Locked<[NetworkPolicy]>([])

    init(limits: AdmissionLimits = .standard, network: NetworkPolicy = NetworkPolicy(), timeouts: HostTimeouts = fastTimeouts()) {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("hs-\(UUID().uuidString)", isDirectory: true)
        store = SecretStore(base: base, role: .host, machine: "MAC-1")
        app = FakeApp(status: Self.status)
        registry = PairingRegistry(store: store)
        let port = port, events = events, spoofed = spoofedSources, registry = registry, offset = clockOffset, networks = networksSeen
        let configuration = HostServer.Configuration(limits: limits, network: network, timeouts: timeouts, sweepInterval: 0.1)
        server = HostServer(registry: registry, app: app, configuration: configuration, makeParameters: { network in
            networks.update { $0.append(network) }
            let p = TLSSettings.parameters(psks: registry.pskSet)
            p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port.value.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
            return p
        }, clock: { ContinuousClock.now + offset.value }, resolveSource: { c in
            if testHostLag > 0 { Thread.sleep(forTimeInterval: testHostLag) }
            if let s = spoofed.update({ $0.isEmpty ? nil : $0.removeFirst() }) { return s }
            return HostConnection.sourceAddress(of: c.endpoint)
        }, onEvent: { e in
            events.update { $0.append(e) }
            if case let .listener(.listening(p)) = e, port.value == nil { port.value = p }
        })
    }
    deinit { try? FileManager.default.removeItem(at: base) }

    /// Host の時計（`clockOffset` を足した今）
    var now: ContinuousClock.Instant { ContinuousClock.now + clockOffset.value }
    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port.value!)!) }
    @discardableResult
    func start(unconfirmed: Set<PairingID> = []) async -> [StoreProblem] {
        var problems = server.start(unconfirmed: unconfirmed)
        for _ in 0..<2 {
            await waitFor(5) { [self] in
                switch server.listenerStatus { case .listening, .portInUse, .failed: return true; default: return false }
            }
            guard case .portInUse = server.listenerStatus, !hasListened.value else { break }
            // 選んだ通信口を、空いていることを確かめてから開くまでの間にほかのプロセスに取られた: 止めて、通信口を取り直す（記録も始めからにする）。
            // 取り直すのは、まだ 1 度も待ち受けていない時だけ（止めた後の 2 回目の `start` や開き直しで通信口が変わると、試験の前提が変わる）
            server.stop()
            await waitFor(5) { [self] in server.listenerStatus == .stopped }
            port.value = listenPortForTests()
            events.update { $0.removeAll() }; networksSeen.update { $0.removeAll() }
            problems = server.start(unconfirmed: unconfirmed)
        }
        switch server.listenerStatus {
        case .listening: hasListened.value = true
        case .portInUse, .failed:
            // 1 度も待ち受けられなかった時だけ、ここで失敗にする（2 回目以降の `start` で使用中なのは、試験が見る）
            if !hasListened.value { XCTFail("試験の Host が待ち受けを始められない: \(server.listenerStatus)") }
        default: break
        }
        return problems
    }
    /// 待ち受けを始めた回数（`.listening` の通知の数）
    var listeningCount: Int { events.value.filter { if case .listener(.listening) = $0 { return true }; return false }.count }
    /// 開き直しが `opens` 回目まで済むのを待つ
    func waitReopened(_ opens: Int) async -> Bool {
        let done: @Sendable () -> Bool = { [self] in
            if case .listening = server.listenerStatus { return listeningCount >= opens }
            return false
        }
        await waitFor(5, done)
        return done()
    }
    var outcomes: [HostOutcome] { events.value.compactMap { if case let .finished(_, _, _, o) = $0 { return o }; return nil } }
    var finished: [HostEvent] { events.value.filter { if case .finished = $0 { return true }; return false } }
    var rejections: [RejectReason] { events.value.compactMap { if case let .rejected(_, r) = $0 { return r }; return nil } }
    func waitOutcomes(_ n: Int, _ timeout: Double = 5) async -> [HostOutcome] { await waitFor(timeout) { [self] in outcomes.count >= n }; return outcomes }
}

final class HostServerTests: XCTestCase {
    func testConfigurationIsClampedToUsableValues() {
        let c = HostServer.Configuration(sweepInterval: -1, listenerRetryDelays: [], coalesceWindow: .nan).validated()
        XCTAssertEqual(c.sweepInterval, 0.05)
        XCTAssertEqual(c.listenerRetryDelays, ListenerSupervisor.standardRetryDelays, "空なら既定")
        XCTAssertEqual(c.coalesceWindow, ListenerSupervisor.standardCoalesceWindow)
        let d = HostServer.Configuration(sweepInterval: .infinity, listenerRetryDelays: [.nan, 0, 1e9], coalesceWindow: 60).validated()
        XCTAssertEqual(d.sweepInterval, 5)
        XCTAssertEqual(d.listenerRetryDelays, [0.05, 3600])
        XCTAssertEqual(d.coalesceWindow, 5)
        XCTAssertEqual(HostServer.Configuration.standard.validated().listenerRetryDelays, [1, 2, 4, 8, 16, 32, 60], "既定値は変えない")
    }
    func testStatusRoundTripConfirmsPending() async throws {
        let h = ServerHarness()
        try h.store.save(StoredPairing(id: pid(1), secret: secret(1)))
        await h.start(unconfirmed: [pid(1)]); defer { h.server.stop() }
        XCTAssertEqual(h.registry.pendingIDs, [pid(1)])
        let r = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1))
        XCTAssertEqual(r, .status(ServerHarness.status))
        let served = await h.waitOutcomes(1)
        XCTAssertEqual(served, [.served(pid(1), .status)])
        XCTAssertEqual(h.registry.pendingIDs, [], "登録済みの秘密で照合に成功したら確定")
        XCTAssertTrue(h.events.value.contains(.registry(.confirmed(pid(1)))))
        XCTAssertEqual(h.server.openConnections, 0)
        XCTAssertEqual(h.finished, [.finished(source: ShareScaleProtocol.IPAddress("127.0.0.1")!, id: pid(1), sourceClass: .loopback, outcome: .served(pid(1), .status))],
                       "結末には照合したペアリングと送り元の分類を載せる")
        _ = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1))
        await waitFor(3) { h.events.value.contains(.registry(.seen(pid(1)))) }
        XCTAssertTrue(h.events.value.contains(.registry(.seen(pid(1)))), "確定済みなら最終接続の更新（.seen）")
    }
    func testAuthenticationConfirmsPendingBeforeTheResponse() async throws {
        let h = ServerHarness()
        try h.store.save(StoredPairing(id: pid(1), secret: secret(1)))
        await h.start(unconfirmed: [pid(1)]); defer { h.server.stop() }
        h.app.respondHold.value = true   // 応答を止めておく（1 秒の遅れに頼ると、負荷の下では確かめる前に応答が終わる。計画 2g）
        let t = Task { try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1)) }
        await waitFor(5) { h.registry.pendingIDs.isEmpty }
        XCTAssertEqual(h.registry.pendingIDs, [], "照合に成功した時点で確定する（応答を待たない）")
        XCTAssertEqual(h.outcomes, [], "まだ応答の途中")
        XCTAssertEqual(h.server.openConnections, 1)
        h.app.respondHold.value = false
        let r = try await t.value
        XCTAssertEqual(r, .status(ServerHarness.status))
    }
    func testUnpairDisconnectsOtherConnectionsOfTheIDButNotTheSender() async throws {
        let h = ServerHarness(); try h.store.save(StoredPairing(id: pid(1), secret: secret(1))); try h.store.save(StoredPairing(id: pid(2), secret: secret(2)))
        await h.start(); defer { h.server.stop() }
        h.app.respondUntilCancelled.value = true
        // 同じ id の応答待ちの接続（別の送り元）と、別の id の応答待ちの接続
        h.spoofedSources.value = [ShareScaleProtocol.IPAddress("10.0.0.2")!, ShareScaleProtocol.IPAddress("10.0.0.3")!]
        let same = Task { try? await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1), timeout: 5) }
        await waitFor(3) { h.server.openConnections == 1 }
        let other = Task { try? await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(2), secret: secret(2), timeout: 5) }
        await waitFor(3) { h.server.openConnections == 2 }
        let r = try await ViewerChannel.exchange(.unpair, expecting: .unpair, to: h.endpoint, id: pid(1), secret: secret(1))
        XCTAssertEqual(r, .ok, "解除の指示を送った接続自身は切らない（応答が届く）")
        let endings = await h.waitOutcomes(2)
        XCTAssertTrue(endings.contains(.served(pid(1), .unpair)) && endings.contains(.cancelled), "同じ id の応答待ちの接続を切る: \(endings)")
        let sameResult = await same.value
        XCTAssertNil(sameResult)
        XCTAssertEqual(h.server.openConnections, 1, "別の id の接続は残る")
        h.server.stop()
        let otherResult = await other.value
        XCTAssertNil(otherResult)
    }
    func testPairingEndToEndThroughTheServer() async throws {
        let h = ServerHarness(); await h.start(); defer { h.server.stop() }
        let code = try XCTUnwrap(h.registry.issueCode(now: ContinuousClock.now))
        let reopenedForCode = await h.waitReopened(2)
        XCTAssertTrue(reopenedForCode, "コードの発行で受け側を開き直す")
        let shown = Box<Int>()
        let newSecret = try await ViewerChannel.pair(to: h.endpoint, id: code.id, secret: code.secret, name: "MacBook", showCode: { shown.set($0) }, timeout: 10)
        XCTAssertEqual(h.app.shownCodes.value, [shown.value!], "見る側と Host の確認番号が一致")
        XCTAssertEqual(h.app.shownSourceClasses.value, [.loopback], "確認の窓に送り元の分類を渡す")
        let paired = await h.waitOutcomes(1)
        XCTAssertEqual(paired, [.paired(codeID: code.id)])
        XCTAssertEqual(h.registry.pendingIDs, [code.id]); XCTAssertNil(h.registry.currentCode)
        XCTAssertTrue(h.events.value.contains(.registry(.paired(code.id, name: "MacBook"))))
        let reopenedAfterPairing = await h.waitReopened(3)
        XCTAssertTrue(reopenedAfterPairing, "承認の後（応答を送り終えてから）開き直す")
        let r = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: code.id, secret: newSecret)
        XCTAssertEqual(r, .status(ServerHarness.status), "新しい秘密でつながる")
        let lastOutcome = await h.waitOutcomes(2).last
        XCTAssertEqual(lastOutcome, .served(code.id, .status))
        XCTAssertEqual(h.registry.pendingIDs, [], "確定した")
        XCTAssertEqual(h.store.loadAll().pairings.map(\.id), [code.id])
    }
    func testDeclinedPairingDropsTheCode() async throws {
        let h = ServerHarness(); await h.start(); defer { h.server.stop() }
        h.app.approve.value = { _, _ in false }
        let code = try XCTUnwrap(h.registry.issueCode(now: ContinuousClock.now))
        let reopenedForCode = await h.waitReopened(2); XCTAssertTrue(reopenedForCode)
        do { _ = try await ViewerChannel.pair(to: h.endpoint, id: code.id, secret: code.secret, name: "MacBook", showCode: { _ in }, timeout: 10); XCTFail() }
        catch let e as NetError { XCTAssertEqual(e, .rejected(.notPaired)) }
        let declined = await h.waitOutcomes(1)
        XCTAssertEqual(declined, [.notPaired(.declined)])
        await waitFor(2) { h.registry.currentCode == nil }
        XCTAssertNil(h.registry.currentCode, "拒否されたら使用済みのコードを捨てる")
        XCTAssertTrue(h.events.value.contains(.registry(.codeAbandoned)))
        let reopenedAfterDecline = await h.waitReopened(3)
        XCTAssertTrue(reopenedAfterDecline)
    }
    func testConsumedCodeSurvivesExpiryWhileApprovalIsPending() async throws {
        let h = ServerHarness(); await h.start(); defer { h.server.stop() }
        h.app.approveHold.value = true
        let code = try XCTUnwrap(h.registry.issueCode(now: h.now))
        let reopenedForCode = await h.waitReopened(2); XCTAssertTrue(reopenedForCode)
        let pairing = Task { try await ViewerChannel.pair(to: h.endpoint, id: code.id, secret: code.secret, name: "MacBook", showCode: { _ in }, timeout: 10) }
        await waitFor(3) { !h.app.shownCodes.value.isEmpty }
        XCTAssertEqual(h.app.shownCodes.value.count, 1, "承認待ちに入った")
        // 承認待ちの間に Host の時計がコードの期限（10 分）を越える。sweeper（100 ミリ秒ごと）に加え、ここでも 1 回 sweep して確かめる
        h.clockOffset.value = .seconds(700)
        h.server.sweep()
        XCTAssertNotNil(h.registry.currentCode, "承認待ちの使用済みのコードは期限が来ても消えない")
        XCTAssertFalse(h.events.value.contains(.registry(.codeExpired)))
        h.app.approveHold.value = false
        let newSecret = try await pairing.value
        let paired = await h.waitOutcomes(1)
        XCTAssertEqual(paired, [.paired(codeID: code.id)], "承認でペアリングが完了する")
        XCTAssertEqual(h.registry.lookup(code.id, now: h.now)?.secret, newSecret)
    }
    func testUnrelatedFailuresDoNotDropTheConsumedCode() async throws {
        let h = ServerHarness(); await h.start(); defer { h.server.stop() }
        h.app.approveHold.value = true
        let code = try XCTUnwrap(h.registry.issueCode(now: ContinuousClock.now))
        let reopenedForCode = await h.waitReopened(2); XCTAssertTrue(reopenedForCode)
        let pairing = Task { try await ViewerChannel.pair(to: h.endpoint, id: code.id, secret: code.secret, name: "MacBook", showCode: { _ in }, timeout: 10) }
        await waitFor(3) { !h.app.shownCodes.value.isEmpty }
        XCTAssertEqual(h.app.shownCodes.value.count, 1, "承認待ちに入った")
        // 承認待ちの最中に、別の送り元が誤った秘密で TLS に失敗する
        h.spoofedSources.value = [ShareScaleProtocol.IPAddress("10.0.0.2")!]
        do { _ = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: code.id, secret: secret(9), timeout: 3); XCTFail() } catch {}
        let handshakeOutcome = await h.waitOutcomes(1)
        XCTAssertEqual(handshakeOutcome, [.handshakeFailed])
        XCTAssertNotNil(h.registry.currentCode, "無関係な接続の失敗では使用済みのコードを捨てない")
        // 2 回目の名乗り（同じコード。使用済みなので not_paired）も 1 回目を壊さない
        h.spoofedSources.value = [ShareScaleProtocol.IPAddress("10.0.0.3")!]
        do { _ = try await ViewerChannel.pair(to: h.endpoint, id: code.id, secret: code.secret, name: "Other", showCode: { _ in }, timeout: 5); XCTFail() }
        catch let e as NetError { XCTAssertEqual(e, .rejected(.notPaired)) }
        let afterSecondHello = await h.waitOutcomes(2)
        XCTAssertEqual(afterSecondHello.last, .notPaired(.codeUsedOrExpired))
        XCTAssertNotNil(h.registry.currentCode, "2 回目の名乗りは 1 回目のコードを捨てない")
        XCTAssertFalse(h.events.value.contains(.registry(.codeAbandoned)))
        XCTAssertEqual(h.app.shownCodes.value.count, 1, "2 回目の名乗りでは確認の窓を出さない")
        h.app.approveHold.value = false
        let newSecret = try await pairing.value
        let afterApproval = await h.waitOutcomes(3)
        XCTAssertEqual(afterApproval.last, .paired(codeID: code.id), "承認すると 1 回目の名乗りが完了する")
        XCTAssertNil(h.registry.currentCode)
        XCTAssertEqual(h.registry.lookup(code.id, now: ContinuousClock.now)?.secret, newSecret)
    }
    func testSameSourceIsLimitedToOneConnection() async throws {
        let h = ServerHarness(); try h.store.save(StoredPairing(id: pid(1), secret: secret(1)))
        await h.start(); defer { h.server.stop() }
        // 1 本目を応答の途中で止めておき、開いていることを確かめてから 2 本目を送る
        // （0.8 秒の遅れと 250 ミリ秒の待ちに頼ると、負荷の下では 1 本目が受け付けられる前に 2 本目が着く・2 本目が着く前に 1 本目が終わる。計画 2g）
        h.app.respondHold.value = true
        async let first = ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1), timeout: 20)
        await waitFor(5) { h.app.responding.value == 1 }
        XCTAssertEqual(h.server.openConnections, 1, "1 本目が開いている")
        do { _ = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1), timeout: 3); XCTFail("同じ送り元の 2 本目が通った") }
        catch {}
        await waitFor(5) { !h.rejections.isEmpty }
        XCTAssertEqual(h.rejections, [.tooManyFromSource])
        XCTAssertEqual(h.app.responding.value, 1, "2 本目は相手役まで届かない")
        h.app.respondHold.value = false
        let firstReply = try await first
        XCTAssertEqual(firstReply, .status(ServerHarness.status))
        let onlyOutcome = await h.waitOutcomes(1)
        XCTAssertEqual(onlyOutcome, [.served(pid(1), .status)], "断った接続は失敗に数えず、結末にもならない")
    }
    func testLockoutAfterRepeatedFailures() async throws {
        // 締め出しの長さは既定（300 秒）のまま、Host の時計を進めて解く（700 ミリ秒の窓と 800 ミリ秒の待ちに頼らない。計画 2g）
        var limits = AdmissionLimits(); limits.failuresPerWindow = 2
        let h = ServerHarness(limits: limits); try h.store.save(StoredPairing(id: pid(1), secret: secret(1)))
        await h.start(); defer { h.server.stop() }
        for n in 1...3 {
            do { _ = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(9), timeout: 5); XCTFail() } catch {}
            // Host が結末を書く（同じ送り元の 1 本の枠が空く）のを待ってから次を送る。待たないと、次が枠に当たって断られ、失敗が 3 回に届かない
            let soFar = await h.waitOutcomes(n)
            XCTAssertEqual(soFar.count, n, "\(n) 本目の結末")
        }
        XCTAssertEqual(h.outcomes.filter { $0 == .handshakeFailed }.count, 3)
        XCTAssertEqual(h.rejections, [], "失敗の 3 本は受け付けられている（断られていない）")
        do { _ = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1), timeout: 3); XCTFail("締め出し中に通った") } catch {}
        await waitFor(5) { !h.rejections.isEmpty }
        XCTAssertEqual(h.rejections, [.lockedOut], "正しい秘密でも締め出し中は TLS の前に断る")
        h.clockOffset.value = .seconds(240)   // 実時間の経過（数秒）を足しても 300 秒に届かない
        do { _ = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1), timeout: 3); XCTFail("締め出しの 300 秒より前に通った") } catch {}
        await waitFor(5) { h.rejections.count == 2 }
        XCTAssertEqual(h.rejections, [.lockedOut, .lockedOut], "240 秒ではまだ締め出し中")
        h.clockOffset.value = .seconds(301)
        let r = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1))
        XCTAssertEqual(r, .status(ServerHarness.status), "締め出しが解ければ通る")
    }
    func testUnpairDeletesReopensAndOldSecretStopsWorking() async throws {
        let h = ServerHarness(); try h.store.save(StoredPairing(id: pid(1), secret: secret(1)))
        await h.start(); defer { h.server.stop() }
        let r = try await ViewerChannel.exchange(.unpair, expecting: .unpair, to: h.endpoint, id: pid(1), secret: secret(1))
        XCTAssertEqual(r, .ok)
        XCTAssertEqual(h.store.loadAll().pairings, [], "秘密のファイルを消す")
        XCTAssertTrue(h.events.value.contains(.registry(.unpaired(pid(1)))))
        let reopenedAfterUnpair = await h.waitReopened(2)
        XCTAssertTrue(reopenedAfterUnpair, "解除で開き直す")
        do { _ = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1), timeout: 3); XCTFail("解除した秘密で通った") }
        catch let e as NetError { if case .handshakeFailed = e {} else { XCTFail("\(e)") } }
    }
    func testCodeAndPendingExpiryAreSwept() async throws {
        let h = ServerHarness(); await h.start(); defer { h.server.stop() }
        let c1 = try XCTUnwrap(h.registry.issueCode(now: h.now))
        let reopenedForC1 = await h.waitReopened(2); XCTAssertTrue(reopenedForC1)
        h.clockOffset.value = .seconds(700)   // コードの期限（10 分）を越える
        await waitFor(3) { h.events.value.contains(.registry(.codeExpired)) }
        XCTAssertTrue(h.events.value.contains(.registry(.codeExpired)), "期限切れのコードを定期的に片付ける")
        XCTAssertNil(h.registry.lookup(c1.id, now: h.now))
        let reopenedForExpiry = await h.waitReopened(3); XCTAssertTrue(reopenedForExpiry)
        let c2 = try XCTUnwrap(h.registry.issueCode(now: h.now))
        let reopenedForC2 = await h.waitReopened(4); XCTAssertTrue(reopenedForC2)
        _ = try await ViewerChannel.pair(to: h.endpoint, id: c2.id, secret: c2.secret, name: "MacBook", showCode: { _ in }, timeout: 10)
        XCTAssertEqual(h.registry.pendingIDs, [c2.id])
        h.clockOffset.value = .seconds(1400)   // 承認から 10 分、新しい秘密で一度も照合しないまま過ぎる
        await waitFor(3) { h.events.value.contains(.registry(.pendingExpired(c2.id))) }
        XCTAssertTrue(h.events.value.contains(.registry(.pendingExpired(c2.id))), "確定されないペアリングは自動で解除")
        XCTAssertEqual(h.store.loadAll().pairings, []); XCTAssertEqual(h.registry.registeredIDs, [])
    }
    func testReservedSlotForKnownSources() async throws {
        let h = ServerHarness(); try h.store.save(StoredPairing(id: pid(1), secret: secret(1)))
        await h.start(); defer { h.server.stop() }
        // 3 本を応答の途中で止めておき、3 本とも開いていることを確かめてから 4 本目を送る
        // （1 秒の遅れと 150 ミリ秒おきの待ちに頼ると、負荷の下では 4 本目が着く前に先の接続が終わって枠が空く。計画 2g）
        h.app.respondHold.value = true
        h.spoofedSources.value = ["10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4"].map { ShareScaleProtocol.IPAddress($0)! }
        let group = Locked<[Task<Response?, Never>]>([])
        for n in 1...3 {
            group.update { $0.append(Task { try? await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1), timeout: 20) }) }
            await waitFor(5) { h.app.responding.value == n }   // 1 本ずつ受け付けさせる（差し替えた送り元を順に使う）
        }
        XCTAssertEqual(h.server.openConnections, 3, "3 本が開いている")
        do { _ = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1), timeout: 3); XCTFail("知らない 4 本目が通った") } catch {}
        await waitFor(5) { !h.rejections.isEmpty }
        XCTAssertEqual(h.rejections, [.reservedForKnown])
        h.app.respondHold.value = false
        for t in group.value { let r = await t.value; XCTAssertEqual(r, .status(ServerHarness.status)) }
        _ = await h.waitOutcomes(3)
        XCTAssertEqual(h.outcomes.count, 3)
    }
    func testTailscaleOnlyRejectsOtherSourcesBeforeTLS() async throws {
        let h = ServerHarness(network: NetworkPolicy(tailscaleOnly: true)); try h.store.save(StoredPairing(id: pid(1), secret: secret(1)))
        await h.start(); defer { h.server.stop() }
        do { _ = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1), timeout: 2); XCTFail() } catch {}
        XCTAssertEqual(h.rejections, [.notTailscale]); XCTAssertEqual(h.outcomes, [], "TLS の前に断り、失敗にも数えない")
        h.spoofedSources.value = [ShareScaleProtocol.IPAddress("100.64.0.9")!]
        let r = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1))
        XCTAssertEqual(r, .status(ServerHarness.status))
        XCTAssertEqual(h.server.rejectionCounts(since: ContinuousClock.now - .seconds(60))[.notTailscale], 1)
    }
    func testStopCancelsInFlightConnections() async throws {
        let h = ServerHarness(); try h.store.save(StoredPairing(id: pid(1), secret: secret(1)))
        await h.start()
        h.app.respondUntilCancelled.value = true
        let t = Task { try? await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(1), secret: secret(1), timeout: 5) }
        // 相手役が応答を作り始めるのを待ってから止める（受け付けただけで止めると、手続きの途中で取り消されて相手役まで届かない。計画 2g）
        await waitFor(5) { h.app.responding.value == 1 }
        XCTAssertEqual(h.server.openConnections, 1)
        h.server.stop()
        let cancelled = await h.waitOutcomes(1, 5)
        XCTAssertEqual(cancelled, [.cancelled])
        XCTAssertEqual(h.app.cancellations.value, 1, "止めると応答の途中の相手役も取り消す")
        let viewerResult = await t.value
        XCTAssertNil(viewerResult)
    }

    func testRequestReopenAndNetworkChangesReopenWithTheCurrentNetwork() async throws {
        let h = ServerHarness(); await h.start(); defer { h.server.stop() }
        XCTAssertEqual(h.networksSeen.value, [NetworkPolicy()])
        h.server.requestReopen()
        let reopened = await h.waitReopened(2); XCTAssertTrue(reopened, "2c の開き直しの要求で開き直す")
        let global = NetworkPolicy(allowGlobal: true)
        h.server.network = global
        let reopenedForNetwork = await h.waitReopened(3); XCTAssertTrue(reopenedForNetwork, "受け付けるネットワークを変えると開き直す")
        XCTAssertEqual(h.networksSeen.value.last, global, "開き直す時に、その時点のネットワークを渡す")
        let opens = h.listeningCount
        h.server.updateLocalNetworks([IPNetwork("2001:db8:1:2::/64")!])
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(h.listeningCount, opens, "同じネットワークの範囲だけの更新では開き直さない")
        XCTAssertEqual(h.server.network.localNetworks, [IPNetwork("2001:db8:1:2::/64")!])
        XCTAssertEqual(h.server.network.allowGlobal, true, "ほかの設定は変えない")
        h.server.updateNetwork { $0.allowGlobal = false }
        let reopenedForUpdate = await h.waitReopened(4); XCTAssertTrue(reopenedForUpdate, "ロックの中で変えてから開き直す")
        XCTAssertEqual(h.server.network, NetworkPolicy(tailscaleOnly: false, allowGlobal: false, localNetworks: [IPNetwork("2001:db8:1:2::/64")!]))
    }
    func testStartTwiceIsHarmlessAndStartAfterStopWorks() async throws {
        let h = ServerHarness(); try h.store.save(StoredPairing(id: pid(1), secret: secret(1)))
        await h.start()
        let firstPort = try XCTUnwrap(h.port.value)
        try h.store.save(StoredPairing(id: pid(2), secret: secret(2)))
        XCTAssertEqual(h.server.start(), [], "動いている間の start は何もしない")
        XCTAssertEqual(h.registry.registeredIDs, [pid(1)], "読み直さない")
        h.server.stop()
        await waitFor(3) { h.server.listenerStatus == .stopped }
        XCTAssertEqual(h.server.listenerStatus, .stopped)
        await h.start(); defer { h.server.stop() }
        XCTAssertEqual(h.port.value, firstPort, "止めた後の 2 回目の start でも、通信口は前と同じ（取り直さない）")
        XCTAssertEqual(h.server.listenerStatus, .listening(port: firstPort))
        XCTAssertEqual(h.registry.registeredIDs, [pid(1), pid(2)], "止めた後の start は読み直す")
        let r = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: pid(2), secret: secret(2))
        XCTAssertEqual(r, .status(ServerHarness.status), "止めた後にもう一度始められる")
    }
    // 試験の土台: 通信口を取り直すのは、まだ 1 度も待ち受けていない時だけ。止めた後の 2 回目の `start` で通信口が使用中でも、
    // 通信口は変えない（製品と同じに「使用中」でやり直し、空いたら同じ通信口で待ち受ける。再点検 N4）
    func testSecondStartKeepsThePortEvenWhenItIsInUse() async throws {
        let h = ServerHarness(); try h.store.save(StoredPairing(id: pid(1), secret: secret(1)))
        await h.start(); defer { h.server.stop() }
        let first = try XCTUnwrap(h.port.value)
        h.server.stop()
        await waitFor(5) { h.server.listenerStatus == .stopped }
        // 止めている間に、ほかの受け側がその通信口を取る（閉じ終えるまで少しかかるので、開けるまで試す）
        var blocker: NWListener?
        for _ in 0..<50 where blocker == nil {
            blocker = try? openLoopbackListener(label: "test.blocker", ports: { first }, parameters: { .tcp }) { $0.newConnectionHandler = { $0.cancel() } }
            if blocker == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        let held = try XCTUnwrap(blocker, "止めた後の通信口を取れない")
        await h.start()
        XCTAssertEqual(h.port.value, first, "2 回目の start では通信口を取り直さない")
        guard case let .portInUse(p, _) = h.server.listenerStatus else { held.cancel(); return XCTFail("\(h.server.listenerStatus)") }
        XCTAssertEqual(p, first)
        held.cancel()
        await waitFor(10) { h.server.listenerStatus == .listening(port: first) }
        XCTAssertEqual(h.server.listenerStatus, .listening(port: first), "空いたら、同じ通信口で待ち受ける")
    }
    func testStartReportsUnreadablePairings() async throws {
        let h = ServerHarness(); try h.store.save(StoredPairing(id: pid(1), secret: secret(1)))
        let bad = h.base.appendingPathComponent("pairings/host/\(pid(2).hex).key").path
        XCTAssertTrue(FileManager.default.createFile(atPath: bad, contents: Data("not json".utf8), attributes: [.posixPermissions: 0o600]))
        let problems = await h.start(); defer { h.server.stop() }
        XCTAssertEqual(problems, [StoreProblem(name: "\(pid(2).hex).key", reason: .badFormat)])
        XCTAssertTrue(h.events.value.contains(.storeProblems(problems)), "読めないファイルは事象で知らせる")
        XCTAssertEqual(h.registry.registeredIDs, [pid(1)], "読めたものだけで動く")
    }
    func testReleasedServerIsDeallocated() async throws {
        // 登録表・受け側・sweeper のどれも HostServer を強く持たない（循環参照が無い）
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let registry = PairingRegistry(store: SecretStore(base: base, role: .host, machine: "MAC-1"))
        let released = Weak<HostServer>()
        do {
            let server = HostServer(registry: registry, app: FakeApp(status: ServerHarness.status),
                                    configuration: HostServer.Configuration(sweepInterval: 0.05),
                                    makeParameters: { _ in loopbackParameters(TLSSettings.parameters(psks: registry.pskSet)) }, onEvent: { _ in })
            server.start()
            await waitFor(3) { if case .listening = server.listenerStatus { return true }; return false }
            released.set(server)
        }
        await waitFor(3) { released.isGone }
        XCTAssertTrue(released.isGone, "stop() を呼ばずに手放しても解放される")
        _ = registry.issueCode(now: ContinuousClock.now)   // 解放の後の変化の通知も安全
    }
}
