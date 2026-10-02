import Network
import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

final class ListenerSupervisorTests: XCTestCase {
    /// 生の TCP でループバックに待ち受ける見張り。受け付けた接続はこだまを返す
    final class Harness: @unchecked Sendable {
        let port = Locked<UInt16?>(listenPortForTests())   // 通信口 0 にしない（`TestPorts`。見つからなければ試験を失敗にする）
        let available = Locked(true)
        let statuses = Locked<[ListenerStatus]>([])
        let accepted = Counter()
        var supervisor: ListenerSupervisor!
        init(retryDelays: [Double] = [0.3, 0.6], coalesceWindow: Double = ListenerSupervisor.standardCoalesceWindow) {
            let port = port, available = available, statuses = statuses, accepted = accepted
            supervisor = ListenerSupervisor(retryDelays: retryDelays, coalesceWindow: coalesceWindow, makeParameters: {
                guard available.value else { return nil }
                let p = NWParameters.tcp
                p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port.value.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
                return p
            }, onConnection: { c in
                accepted.add()
                c.stateUpdateHandler = { st in
                    guard case .ready = st else { return }
                    @Sendable func loop() { c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { d, _, done, e in
                        if let d { c.send(content: d, completion: .contentProcessed { _ in }) }
                        if !done && e == nil { loop() } } }
                    loop()
                }
                c.start(queue: DispatchQueue(label: "echo"))
            }, onStatus: { st in
                statuses.update { $0.append(st) }
                if case let .listening(p) = st, port.value == nil { port.value = p }
            })
        }
        var current: ListenerStatus { supervisor.currentStatus }
        func waitListening(opens: Int, _ timeout: Double = 5) async -> Bool {
            await waitFor(timeout) { [self] in if case .listening = current, supervisor.openCount >= opens { return true }; return false }
            if case .listening = current, supervisor.openCount >= opens { return true }
            // 開けなかった時に、何が起きたかが出力から分かるようにする（通信口を取られた・使用中のまま、など）
            print("ListenerSupervisorTests: \(opens) 回目の待ち受けが \(timeout) 秒で始まらない（通信口 \(port.value.map(String.init) ?? "?")・開いた回数 \(supervisor.openCount)・状態 \(statuses.value)）")
            return false
        }
        func connect() async throws -> NWConnection {
            let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port.value!)!, using: .tcp)
            let ch = Channel(c, label: "client")
            try await ch.waitReady(until: .now() + 3)
            return c
        }
        func echo(_ c: NWConnection, _ text: String) async throws -> String {
            let ch = Channel(c, label: "client")
            try await ch.send(Data((text + "\n").utf8), until: .now() + 2)
            return String(decoding: try await ch.readLine(limit: 1024, until: .now() + 2), as: UTF8.self)
        }
    }

    /// ループバックの通信口に TCP でつながるか（1 秒で諦める）
    func canConnect(_ port: UInt16) async -> Bool {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { c.cancel() }
        do { try await Channel(c, label: "probe").waitReady(until: .now() + 1); return true } catch { return false }
    }

    func testStartsListensAndAcceptsThenStops() async throws {
        let h = Harness(); h.supervisor.start(); defer { h.supervisor.stop() }
        let awaited1 = await h.waitListening(opens: 1)
        XCTAssertTrue(awaited1)
        let c = try await h.connect()
        let r = try await h.echo(c, "hi"); XCTAssertEqual(r, "hi"); XCTAssertEqual(h.accepted.value, 1)
        h.supervisor.stop()
        await waitFor(5) { h.current == .stopped }
        XCTAssertEqual(h.current, .stopped)
        // 閉じるのは非同期なので、つながらなくなるまで短い間隔で試す（止めた直後は、閉じ終える前で TCP がつながることがある。計画 2g）
        let port = try XCTUnwrap(h.port.value)
        var refused = false
        let end = ContinuousClock.now + .seconds(5)
        while !refused, ContinuousClock.now < end {
            refused = !(await canConnect(port))
            if !refused { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(refused, "止めた後はつながらない")
        c.cancel()
    }
    func testReopenRequestsAreCoalescedAndKeepAcceptedConnections() async throws {
        let h = Harness(coalesceWindow: 0.5)   // 負荷の下でも 5 回の要求が窓の中に収まるよう、まとめる窓を広げる
        h.supervisor.start(); defer { h.supervisor.stop() }
        let awaited2 = await h.waitListening(opens: 1)
        XCTAssertTrue(awaited2)
        let before = try await h.connect()
        for _ in 0..<5 { h.supervisor.requestReopen() }   // 窓の中の要求は 1 回にまとめる
        let awaited3 = await h.waitListening(opens: 2)
        XCTAssertTrue(awaited3)
        // まとめる窓（0.5 秒）と、古い受け側を待つ予備のタイマー（1 秒）より長く待ち、2 回目の開き直しが起きないことを見る
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(h.supervisor.openCount, 2, "5 回の要求で開き直しは 1 回: \(h.statuses.value)")
        let awaited4 = try await h.echo(before, "still")
        XCTAssertEqual(awaited4, "still", "開き直しても受け付け済みの接続は生きている")
        XCTAssertEqual(h.port.value, { if case let .listening(p) = h.current { return p }; return nil }(), "同じ通信口で開き直す")
        let after = try await h.connect()
        let echoedNew = try await h.echo(after, "new"); XCTAssertEqual(echoedNew, "new")
        before.cancel(); after.cancel()
    }
    func testReopeningOnTheSamePortNeverReportsItInUse() async throws {
        // 古い受け側が閉じ終えてから開くので、同じ通信口の開き直しが「使用中」になることは無い
        let h = Harness(coalesceWindow: 0.01); h.supervisor.start(); defer { h.supervisor.stop() }
        let first = await h.waitListening(opens: 1); XCTAssertTrue(first)
        for n in 2...21 {
            h.supervisor.requestReopen()
            let reopened = await h.waitListening(opens: n); XCTAssertTrue(reopened, "\(n) 回目")
        }
        XCTAssertEqual(h.supervisor.openCount, 21, "失敗してやり直した開き直しは無い: \(h.statuses.value.filter { if case .listening = $0 { return false }; return $0 != .starting })")
        XCTAssertFalse(h.statuses.value.contains { if case .portInUse = $0 { return true }; if case .failed = $0 { return true }; return false })
    }
    func testStopThenStartOnTheSamePortNeverReportsItInUse() async throws {
        // stop で閉じた受け側が閉じ終えてから start が開くので、止めてすぐ始めても「使用中」にならない
        let h = Harness(); h.supervisor.start(); defer { h.supervisor.stop() }
        let first = await h.waitListening(opens: 1); XCTAssertTrue(first)
        for n in 2...11 {
            h.supervisor.stop(); h.supervisor.start()
            let restarted = await h.waitListening(opens: n); XCTAssertTrue(restarted, "\(n) 回目")
        }
        XCTAssertEqual(h.supervisor.openCount, 11)
        XCTAssertFalse(h.statuses.value.contains { if case .portInUse = $0 { return true }; if case .failed = $0 { return true }; return false },
                       "\(h.statuses.value)")
    }
    func testPortInUseRetriesWithBackoffAndRecovers() async throws {
        // 先に別の待ち受けが通信口を占めている
        let blocker = try NWListener(using: loopbackParameters(.tcp)); blocker.newConnectionHandler = { $0.cancel() }
        try startListener(blocker, label: "blocker")
        let h = Harness(retryDelays: [0.3, 0.6, 1.2]); h.port.value = blocker.port!.rawValue
        h.supervisor.start(); defer { h.supervisor.stop() }
        await waitFor(3) { h.statuses.value.contains { if case .portInUse(_, 0.3) = $0 { return true }; return false } }
        await waitFor(3) { h.statuses.value.contains { if case .portInUse(_, 0.6) = $0 { return true }; return false } }
        XCTAssertTrue(h.statuses.value.contains { if case .portInUse(_, 0.6) = $0 { return true }; return false }, "1 回目 0.3 秒、2 回目 0.6 秒の間隔でやり直す: \(h.statuses.value)")
        blocker.cancel()
        let awaited5 = await h.waitListening(opens: 1, 5)
        XCTAssertTrue(awaited5, "通信口が空いたら待ち受ける")
        h.supervisor.requestReopen()
        let awaited6 = await h.waitListening(opens: 2)
        XCTAssertTrue(awaited6)
        let failedAgain = h.statuses.value.suffix(2).contains { if case .portInUse = $0 { return true }; return false }
        XCTAssertFalse(failedAgain, "成功したら間隔を戻す（次の開き直しは 1 回で開く）")
    }
    func testRepeatedReopenRequestsOnABusyPortDoNotResetTheBackoff() async throws {
        // 使用中の通信口で開き直しの要求が続いても、やり直しの間隔は最初（0.5 秒）に戻らない（戻すのは開けた時だけ）
        let blocker = try NWListener(using: loopbackParameters(.tcp)); blocker.newConnectionHandler = { $0.cancel() }
        try startListener(blocker, label: "blocker"); defer { blocker.cancel() }
        let blockedPort = blocker.port!.rawValue
        let h = Harness(retryDelays: [0.5, 1.0, 2.0, 4.0], coalesceWindow: 0.05); h.port.value = blockedPort
        h.supervisor.start(); defer { h.supervisor.stop() }
        let delays: @Sendable () -> [Double] = { h.statuses.value.compactMap { if case let .portInUse(_, r) = $0 { return r }; return nil } }
        await waitFor(3) { delays().count >= 1 }
        for n in 2...4 {
            h.supervisor.requestReopen()
            await waitFor(3) { delays().count >= n }
        }
        XCTAssertEqual(Array(delays().prefix(4)), [0.5, 1.0, 2.0, 4.0], "開き直しの要求で間隔を戻さない: \(h.statuses.value)")
        let ports = h.statuses.value.compactMap { if case let .portInUse(p, _) = $0 { return p }; return nil }
        XCTAssertEqual(Set(ports), [blockedPort], "使用中の通信口は、指定した通信口で知らせる")
    }
    func testReleasedSupervisorClosesItsListener() async throws {
        // stop() を呼ばずに手放しても、通信口は閉じる
        var h: Harness? = Harness()
        h!.supervisor.start()
        let listening = await h!.waitListening(opens: 1)
        XCTAssertTrue(listening)
        let port = try XCTUnwrap(h!.port.value)
        let released = Weak<ListenerSupervisor>(); released.set(h!.supervisor)
        h = nil
        await waitFor(2) { released.isGone }
        XCTAssertTrue(released.isGone, "見張りが解放される")
        // 閉じるのは非同期なので、つながらなくなるまで短い間隔で試す
        var refused = false
        let end = ContinuousClock.now + .seconds(3)
        while !refused, ContinuousClock.now < end {
            refused = !(await canConnect(port))
            if !refused { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(refused, "手放した見張りの通信口につながらない")
    }
    func testStatusAndOpenCountCanBeReadInsideTheStatusCallback() async throws {
        // 2c はメニューの更新を onEvent（→ onStatus）の中から行い、その中で受け側の状態を読む。止まってはいけない
        let box = Box<ListenerSupervisor>()
        let seen = Locked<[(status: ListenerStatus, opens: Int)]>([])
        let sup = ListenerSupervisor(makeParameters: { loopbackParameters(.tcp) }, onConnection: { $0.cancel() }, onStatus: { _ in
            guard let s = box.value else { return }
            seen.update { $0.append((s.currentStatus, s.openCount)) }   // 通知の中から読む
        })
        box.set(sup); sup.start(); defer { sup.stop() }
        await waitFor(3) { if case .listening = seen.value.last?.status { return true }; return false }
        let last = seen.value.last
        XCTAssertNotNil(last, "通知の中で読めた（止まらない）")
        if case .listening = last?.status {} else { XCTFail("\(String(describing: last))") }
        XCTAssertEqual(last?.opens, 1, "回数も通知の時点の値")
        XCTAssertEqual(seen.value.map(\.status), [.starting, sup.currentStatus], "通知の中で読んだ状態は、通知された状態と同じ")
    }
    func testWaitsForNetworkWhenParametersUnavailable() async throws {
        let h = Harness(); h.available.value = false
        h.supervisor.start(); defer { h.supervisor.stop() }
        await waitFor(2) { h.current == .waitingForNetwork }
        XCTAssertEqual(h.current, .waitingForNetwork)
        XCTAssertEqual(h.supervisor.openCount, 0, "受け付けない（全経路に戻さない）")
        h.available.value = true; h.supervisor.requestReopen()
        let awaited7 = await h.waitListening(opens: 1)
        XCTAssertTrue(awaited7)
    }
}
