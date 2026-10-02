import Network
import XCTest
@testable import ShareScaleCore
import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// 候補の試し方（仕様「見る側」）。ループバックの Host と、閉じた通信口・中継（遅い／つながらない）を候補にする
final class ConnectorTests: HostViewerTestCase, @unchecked Sendable {
    var fast: Connector.Settings { var s = Connector.Settings(); s.readyTimeout = 1; s.total = 4; return s }
    // 試験の Host は、一時の通信口の範囲（49152〜65535）の外で待ち受ける（計画 2g。`TestPorts`）。`::1` の中継も同じ通信口で開ける
    func testTheTestHostListensOutsideTheEphemeralPortRange() async throws {
        try await startHost()
        XCTAssertTrue(TestPorts.range.contains(port), "\(port)")
        XCTAssertFalse((49152...65535).contains(port))
        let relay = try LoopbackRelay(port: port, role: .reject); defer { relay.stop() }
        XCTAssertEqual(relay.listener.port?.rawValue, port)
    }

    /// 候補 1 つの上限が試したい性質に関係ない試験に使う（負荷の下でも、ループバックの手続きが上限の中に収まる。計画 2g）
    var roomy: Connector.Settings { var s = Connector.Settings(); s.readyTimeout = 5; s.total = 10; return s }

    func testOrderPutsLastOKFirstAndDropsUnknownLastOK() {
        let c = Connector.Candidates(port: 1, addresses: ["a", "b", "c"], lastOK: "b")
        XCTAssertEqual(c.ordered, ["b", "a", "c"])
        XCTAssertNil(Connector.Candidates(port: 1, addresses: ["a"], lastOK: "zz").lastOK, "候補に無い last_ok_addr は使わない")
        XCTAssertEqual(Connector.Candidates(port: 1, addresses: ["a", "b"]).ordered, ["a", "b"])
        let m = ViewerMeta(name: "S", port: 5, addresses: ["x", "y"], lastOKAddress: "y", confirmed: true)!
        XCTAssertEqual(Connector.Candidates(m), Connector.Candidates(port: 5, addresses: ["x", "y"], lastOK: "y"))
    }

    // 同じ Mac の中の Host（実機確認 2026-09-30）: 候補がこの Mac 自身を指せば 127.0.0.1 を先頭に足す。名前解決はせず、文字列と差し替えたアドレスの一覧だけで判定する
    func testSelfPointingCandidatesAreTriedViaLoopbackFirst() throws {
        let me = LocalIdentity(localHostName: "Taro-Mac", addresses: [try XCTUnwrap(IPAddress("192.168.1.5")), try XCTUnwrap(IPAddress("100.101.1.2")),
                                                                      try XCTUnwrap(IPAddress("127.0.0.1")), try XCTUnwrap(IPAddress("::1"))])
        typealias A = Connector.Candidates.Attempt
        XCTAssertTrue(CandidateAddress.isValid(LocalIdentity.loopback), "127.0.0.1 は候補の規則を通る")
        XCTAssertTrue(me.pointsToSelf("Taro-Mac.local")); XCTAssertTrue(me.pointsToSelf("taro-mac.LOCAL"), "大文字小文字は区別しない")
        XCTAssertTrue(me.pointsToSelf("100.101.1.2")); XCTAssertTrue(me.pointsToSelf("192.168.1.5"))
        XCTAssertFalse(me.pointsToSelf("studio.local")); XCTAssertFalse(me.pointsToSelf("Taro-Mac")); XCTAssertFalse(me.pointsToSelf("100.101.1.3"))
        XCTAssertFalse(me.pointsToSelf("127.0.0.1")); XCTAssertFalse(me.pointsToSelf("::1"), "ループバックはそのままつながるので足さない")
        XCTAssertFalse(LocalIdentity(localHostName: nil, addresses: []).pointsToSelf("Taro-Mac.local"), "名前が読めなければ .local は自分と見なさない")
        XCTAssertFalse(LocalIdentity(localHostName: " ", addresses: []).pointsToSelf(".local"))

        // 接続コードの既定の候補（`<LocalHostName>.local` と自分の Tailscale の IPv4）→ 127.0.0.1 だけを単独で先に試す（報告は前の候補）
        let code = Connector.Candidates(port: 1, addresses: ["Taro-Mac.local", "100.101.1.2"])
        XCTAssertEqual(code.plan(me).alone, A(dial: "127.0.0.1", report: "Taro-Mac.local"))
        XCTAssertEqual(code.plan(me).rest, [], "この Mac 自身を指す候補そのものはつながない（通信が進まないため）")
        // 前回つながった候補がこの Mac 自身ならそれを報告する（帳簿の last_ok_addr が候補の中に留まる）
        XCTAssertEqual(Connector.Candidates(port: 1, addresses: ["Taro-Mac.local", "100.101.1.2"], lastOK: "100.101.1.2").plan(me).alone,
                       A(dial: "127.0.0.1", report: "100.101.1.2"))
        // IP だけが一致する（LAN のアドレス）
        XCTAssertEqual(Connector.Candidates(port: 1, addresses: ["192.168.1.5"]).plan(me).alone, A(dial: "127.0.0.1", report: "192.168.1.5"))
        // 自分以外の候補は残りとして従来どおり試す。127.0.0.1 が候補にあっても重ねない
        let mixed = Connector.Candidates(port: 1, addresses: ["Taro-Mac.local", "192.0.2.9", "127.0.0.1"])
        XCTAssertEqual(mixed.plan(me).alone, A(dial: "127.0.0.1", report: "Taro-Mac.local"))
        XCTAssertEqual(mixed.plan(me).rest, [A(dial: "192.0.2.9", report: "192.0.2.9")])

        // 足さない: ほかの Mac の候補・ループバックだけの候補・何も分からない時
        let other = Connector.Candidates(port: 1, addresses: ["studio.local", "100.101.1.3"])
        XCTAssertNil(other.plan(me).alone)
        XCTAssertEqual(other.plan(me).rest, [A(dial: "studio.local", report: "studio.local"), A(dial: "100.101.1.3", report: "100.101.1.3")])
        let loop = Connector.Candidates(port: 1, addresses: ["::1", "127.0.0.1"], lastOK: "127.0.0.1")
        XCTAssertEqual(loop.plan(me).alone, A(dial: "127.0.0.1", report: "127.0.0.1"), "従来どおり前回の候補を単独で先に")
        XCTAssertEqual(loop.plan(me).rest, [A(dial: "::1", report: "::1")])
        XCTAssertNil(code.plan(.none).alone, "この Mac のことが分からなければ足さない")
        XCTAssertEqual(code.plan(.none).rest.map(\.dial), ["Taro-Mac.local", "100.101.1.2"])
    }

    func testClassifyPrefersLocalNetworkDeniedThenHandshake() {
        XCTAssertEqual(Connector.classify([NetError.unreachable(.posix(ECONNREFUSED)), .localNetworkDenied, .handshakeFailed(.tls(-9820))]), .localNetworkDenied)
        XCTAssertEqual(Connector.classify([NetError.unreachable(.posix(ECONNREFUSED)), .handshakeFailed(.tls(-9820))]), .handshakeFailed(othersUnreachable: true),
                       "TLS の失敗は秘密が一致しないか別の機器。届かない候補が混ざればその旨")
        XCTAssertEqual(Connector.classify([NetError.handshakeFailed(.tls(-9820))]), .handshakeFailed(othersUnreachable: false))
        XCTAssertEqual(Connector.classify([NetError.unreachable(.posix(ECONNREFUSED)), .timedOut(.connecting)]), .unreachable)
        XCTAssertEqual(Connector.classify([]), .unreachable)
        // 全体の締め切りで終わった時（締め切りで打ち切られた候補の時間切れは数えずに渡す。計画 2f-1 の点検）
        XCTAssertEqual(Connector.atDeadline([]), .timedOut)
        XCTAssertEqual(Connector.atDeadline([NetError.unreachable(.posix(ECONNREFUSED))]), .unreachable, "締め切りより前に分かった理由はそのまま")
    }

    // 候補の締め切りと全体の締め切りが同じ時刻の時、出来事がどちらの順で届いても同じ理由になる（点検 2f-1 の再点検。`Connector.Tally`）
    func testDeadlineRaceGivesTheSameReasonInEitherOrder() {
        let atDeadline = NetError.timedOut(.connecting)
        let refused = NetError.unreachable(.posix(ECONNREFUSED))
        typealias E = Connector.Event
        // 候補の時間切れ → 全候補の失敗（どちらも締め切りの後）と、全体の時間切れが先
        let candidateFirst = Connector.Tally.reason([(E.failed("::1", atDeadline), true), (E.exhausted, true)])
        let timeoutFirst = Connector.Tally.reason([(E.timeout, true), (E.failed("::1", atDeadline), true), (E.exhausted, true)])
        XCTAssertEqual(candidateFirst, .timedOut)
        XCTAssertEqual(timeoutFirst, .timedOut)
        // 締め切りより前に断られた候補があれば、どちらの順でもその理由
        XCTAssertEqual(Connector.Tally.reason([(E.failed("a", refused), false), (E.failed("::1", atDeadline), true), (E.exhausted, true)]), .unreachable)
        XCTAssertEqual(Connector.Tally.reason([(E.failed("a", refused), false), (E.timeout, true)]), .unreachable)
        // 締め切りより前の候補の時間切れ（候補の 5 秒）は、今までどおり候補の失敗（届かない）
        XCTAssertEqual(Connector.Tally.reason([(E.failed("a", atDeadline), false), (E.exhausted, false)]), .unreachable)
        XCTAssertNil(Connector.Tally.reason([(E.failed("a", refused), false)]), "まだ決まらない")
        XCTAssertEqual(Connector.classify(CancellationError()), .cancelled)
        XCTAssertEqual(Connector.classify(NetError.cancelled), .cancelled)
        XCTAssertNil(ViewerFailure(response: .ok)); XCTAssertEqual(ViewerFailure(response: .error(.paused)), .paused)
        XCTAssertEqual(Connector.classify(NetError.rejected(.notPaired)), .notPaired)
        XCTAssertEqual(Connector.classify(NetError.rejected(.paused)), .paused)
        XCTAssertEqual(Connector.classify(NetError.rejected(.busy)), .busy)
        XCTAssertEqual(Connector.classify(NetError.rejected(.unsupportedVersion)), .unsupportedVersion)
        XCTAssertEqual(Connector.classify(NetError.timedOut(.receiving)), .timedOut)
        XCTAssertEqual(Connector.classify(NetError.closed), .unreachable)
        XCTAssertEqual(Connector.classify(NetError.malformedResponse), .other("malformedResponse"))
        XCTAssertEqual(ViewerFailure(.badRequest), .other("bad_request"))
    }

    // すぐ断られる候補（`::1` の受け付けてすぐ閉じる中継）＋ループバック。失敗したら次をずらさずに始める → ずらしを待たずにつながる。
    // ずらしを 3 秒にして見る（300 ミリ秒のままで「0.25 秒未満」を見ると、負荷の下では手続きと 1 往復がそれより長くかかって落ちる。計画 2g）
    func testFailedCandidatesDoNotDelayTheNext() async throws {
        try await startHost()
        let b = book()
        let reject = try LoopbackRelay(port: port, role: .reject); defer { reject.stop() }
        let t = try await pairedTarget(in: b, addresses: ["::1", "127.0.0.1"])
        var settings = roomy; settings.stagger = 3
        let t0 = ContinuousClock.now
        let r = await Connector.exchange(.status, expecting: .status, candidates: Connector.Candidates(t.meta), id: t.id, secret: t.secret, settings: settings)
        let elapsed = secondsSince(t0)
        guard case let .success(ok) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(ok.address, "127.0.0.1")
        guard case let .status(s) = ok.response else { return XCTFail("\(ok.response)") }
        XCTAssertEqual(s.name, "Mac Studio")
        XCTAssertEqual(reject.accepted, 1)
        XCTAssertLessThan(elapsed, 2.0, "すぐ断られた候補の次はずらさずに始める（ずらしの 3 秒を待たない）")
        let o = await host.outcomes(count: 3)   // 準備の名乗りと確定の status の後に 1 件
        XCTAssertEqual(o.suffix(1), [.served(t.id, .status)], "status は選んだ 1 本にだけ（断られた候補は Host に届かない）")
        XCTAssertEqual(o.count, 3)
    }

    // ずらし: 1 本目が `readyTimeout` まで応答の無い候補（黒穴）なら、2 本目はずらしの後に始める（点検 A: 「始めた」の印を Task の外で立てる）。
    // ずらしは 1 秒・候補の上限は 5 秒にして見る（正しければ 1 秒後。ずらしが飛ばされれば 0 秒、1 本目の失敗を待てば 5 秒。計画 2g）。
    // 候補の Task の本体を 0.2 秒止めてから始める（差し込み口 `startTask`）。印を Task の中で立てると、本体がまだ走っていない間に
    // ずらしの判定が「始めた候補がすべて失敗」と見て、2 本目をすぐ始めてしまう（並行の実行では新しい Task がすぐ走るので、止めないと見えない）
    func testSecondCandidateStartsAfterTheStagger() async throws {
        try await startHost()
        let b = book()
        let hole = try LoopbackRelay(port: port, role: .blackHole); defer { hole.stop() }
        let t = try await pairedTarget(in: b, addresses: ["::1", "127.0.0.1"])
        let t0 = ContinuousClock.now
        let starts = Locked<[(address: String, at: Double)]>([])
        let startTask: Connector.StartTask = { address, body in
            starts.update { $0.append((address, secondsSince(t0))) }
            return Task { try? await Task.sleep(nanoseconds: 200_000_000); return await body() }
        }
        var settings = roomy; settings.stagger = 1
        let r = await Connector.connect(Connector.Candidates(t.meta), id: t.id, secret: t.secret, kind: .registered, settings: settings, startTask: startTask)
        guard case let .success(conn) = r else { return XCTFail("\(r)") }
        conn.channel.close()
        XCTAssertEqual(conn.address, "127.0.0.1")
        XCTAssertEqual(hole.accepted, 1, "1 本目は黒穴に届いている")
        let s = starts.value
        XCTAssertEqual(s.map { $0.address }, ["::1", "127.0.0.1"])
        guard s.count == 2 else { return }
        XCTAssertGreaterThanOrEqual(s[1].at - s[0].at, 0.98, "2 本目はずらし（1 秒）の後に始める（1 本目の本体がまだ走っていなくても、ずらしが飛ばされない）")
        XCTAssertLessThan(s[1].at - s[0].at, 3.5, "1 本目の失敗（5 秒）を待たない")
    }

    // 戻った後（ここでは全体の上限 0.1 秒）に、まだ始めていない候補を始めない（戻る時に「選んだ」の印を立てる。点検の再点検）
    func testNoNewCandidateStartsAfterReturning() async throws {
        try await startHost()
        let b = book()
        let hole = try LoopbackRelay(port: port, role: .blackHole); defer { hole.stop() }
        let t = try await pairedTarget(in: b, addresses: ["::1", "127.0.0.1"])
        let before = await host.outcomes(count: 2).count   // 準備の名乗りと確定の status
        var s = fast; s.total = 0.1
        let r = await Connector.connect(Connector.Candidates(t.meta), id: t.id, secret: t.secret, kind: .registered, settings: s)
        guard case let .failure(f) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(f, .timedOut)
        try? await Task.sleep(nanoseconds: 800_000_000)   // ずらし（0.3 秒）の後に 2 本目が始まっていれば、Host に届く時間
        XCTAssertEqual(host.outcomes.count, before, "戻った後に 2 本目を始めない（Host に何も届かない）: \(host.outcomes)")
        XCTAssertEqual(hole.accepted, 1)
    }

    // 1 往復の締め切りはつないでから取る（点検 D）。Host が status の応答を 3 秒遅らせ、全体の上限（2 秒）の後に届いても、
    // 1 往復には `exchange`（10 秒）がある（締め切りを候補の試行の上限の残りで取ると、応答が届く前に時間切れになる）。
    // つなぐのはループバックなので、負荷の下でも 2 秒の上限の中に収まる（0.5 秒では収まらないことがある。計画 2g）
    func testExchangeDeadlineStartsAfterConnecting() async throws {
        try await startHost()
        let b = book()
        let t = try await pairedTarget(in: b)
        host.statusDelay.value = 3
        var s = roomy; s.total = 2
        let t0 = ContinuousClock.now
        let r = await Connector.exchange(.status, expecting: .status, candidates: Connector.Candidates(t.meta), id: t.id, secret: t.secret, settings: s)
        let elapsed = secondsSince(t0)
        host.statusDelay.value = 0
        guard case let .success(ok) = r else { return XCTFail("\(r)（\(elapsed) 秒）") }
        XCTAssertEqual(ok.address, "127.0.0.1")
        guard case .status = ok.response else { return XCTFail("\(ok.response)") }
        XCTAssertGreaterThan(elapsed, s.total, "応答は候補の試行の上限を過ぎてから届いている（この試験が締め切りの取り方を確かめていること）")
    }

    // 呼び出し側の取り消し: `.cancelled` ですぐ戻り、遅れて `.ready` になった接続は余りとして片付ける（登録済みの秘密なら status を送って閉じる）
    func testCancellationReturnsCancelledAndLateReadyBecomesSurplus() async throws {
        try await startHost(maxPerSource: 4)
        let b = book()
        // `::1` の中継は Host からの流れを止めておき、取り消しで戻った後に流す（0.6 秒の遅れと 0.15 秒の待ちに頼ると、
        // 負荷の下では取り消しの前につながってしまう。計画 2g）
        let slow = try LoopbackRelay(port: port, role: .gated); defer { slow.stop() }
        let t = try await pairedTarget(in: b, addresses: ["::1"])
        let settings = roomy
        let task = Task { await Connector.connect(Connector.Candidates(t.meta), id: t.id, secret: t.secret, kind: .registered, settings: settings) }
        await waitFor(5) { slow.accepted == 1 }   // 接続が中継に届いた（手続きは止まっている）
        let t0 = ContinuousClock.now
        task.cancel()
        let r = await task.value
        guard case let .failure(f) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(f, .cancelled)
        XCTAssertLessThan(secondsSince(t0), 2.0, "取り消しですぐ戻る（接続は打ち切らない。候補の上限の 5 秒を待たない）")
        slow.release()
        // 準備の 2 件（名乗りと確定の status）の後に、遅れてつながった接続の status が 1 件
        // （今までは 2 件そろった所で見ていて、準備の status が「余りの status」の代わりに数えられていた。計画 2g）
        let o = await host.outcomes(count: 3)
        XCTAssertEqual(o, [.paired(codeID: t.id), .served(t.id, .status), .served(t.id, .status)], "遅れてつながった接続は status を送って閉じる（余り）: \(o)")
    }

    // 前回つながったアドレスをまずそれだけ試す。つながらなければ（2 秒）残りを並行に試す
    func testLastOKIsTriedAloneFirst() async throws {
        try await startHost()
        let b = book()
        let hole = try LoopbackRelay(port: port, role: .blackHole); defer { hole.stop() }
        let t = try await pairedTarget(in: b, addresses: ["127.0.0.1", "::1"])
        var meta = t.meta; meta.lastOKAddress = "::1"
        let t0 = ContinuousClock.now
        var settings = roomy; settings.readyTimeout = 2   // 残りの候補（ループバック）の手続きも、負荷の下でこの上限に収まる
        let r = await Connector.connect(Connector.Candidates(meta), id: t.id, secret: t.secret, kind: .registered, settings: settings)
        let elapsed = secondsSince(t0)
        guard case let .success(conn) = r else { return XCTFail("\(r)") }
        conn.channel.close()
        XCTAssertEqual(conn.address, "127.0.0.1")
        XCTAssertEqual(hole.accepted, 1, "前回のアドレスを先に試す")
        XCTAssertGreaterThan(elapsed, 1.9, "前回のアドレスの上限（2 秒）まで待ってから残りを試す")
        XCTAssertLessThan(elapsed, 3.0, "残りの候補は、その後すぐつながる（さらに上限の 2 秒を待てば 4 秒）")
    }

    // 余りの接続（登録済みの秘密）は status だけを送って閉じる。選んだ 1 本は何も送らずに閉じる
    // （2 本目が 300 ミリ秒後に始まることは `testSecondCandidateStartsAfterTheStagger` で確かめる。ここでは遅い 1 本目が余りになることを見る）
    func testSurplusRegisteredConnectionSendsStatusOnly() async throws {
        try await startHost(maxPerSource: 4)
        let b = book()
        // `::1` の中継は Host からの流れを止めておき、127.0.0.1 が選ばれた後に流す（0.6 秒の遅れに頼ると、負荷の下では
        // 300 ミリ秒後に始めた候補の手続きが間に合わず、遅い候補が選ばれる。計画 2g。順番を時間に依らずに決める形は下の試験と同じ）
        let slow = try LoopbackRelay(port: port, role: .gated); defer { slow.stop() }
        let t = try await pairedTarget(in: b, addresses: ["::1", "127.0.0.1"])
        let r = await Connector.connect(Connector.Candidates(t.meta), id: t.id, secret: t.secret, kind: .registered, settings: roomy)
        slow.release()
        guard case let .success(conn) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(conn.address, "127.0.0.1", "止まっている候補より、300 ミリ秒後に始めた候補が先につながる")
        conn.channel.close()
        // 準備の 2 件（名乗りと確定の status）の後に、選んだ 1 本（指示なし）と余り（status）の 2 件。順は問わない
        // （今までは 3 件そろった所で数えていて、余りの status が届く前に見ていた。準備の status が「余りの status」の代わりに数えられていた）
        let o = await host.outcomes(count: 4)
        XCTAssertEqual(o.count, 4, "\(o)")
        XCTAssertEqual(o.prefix(2), [.paired(codeID: t.id), .served(t.id, .status)], "準備: \(o)")
        XCTAssertEqual(o.dropFirst(2).filter { $0 == .noRequest }.count, 1, "選んだ 1 本は閉じただけ: \(o)")
        XCTAssertEqual(o.dropFirst(2).filter { $0 == .served(t.id, .status) }.count, 1, "余りは status を送って閉じる: \(o)")
        XCTAssertEqual(slow.accepted, 1)
        XCTAssertEqual(host.runtime.log.recentAll(500).filter { $0.contains("pairing requested") }.count, 1, "名乗りは準備の 1 回だけ（余りは hello を送らない）")
    }

    // 余りの接続（コードの秘密）は何も送らずに閉じる（Host では失敗 1 件）。hello は送られない
    func testSurplusCodeConnectionSendsNothing() async throws {
        try await startHost(maxPerSource: 4)
        // `::1` の中継は Host からの流れを止めておき、127.0.0.1 が選ばれた後に流す（順番を時間に依らずに決める。計画 2f-1 の点検）
        let slow = try LoopbackRelay(port: port, role: .gated); defer { slow.stop() }
        let issued = await host.issueCode()
        let code = try XCTUnwrap(issued)
        let c = Connector.Candidates(port: Int(port), addresses: ["::1", "127.0.0.1"])
        let r = await Connector.connect(c, id: code.id, secret: code.secret, kind: .code, settings: roomy)   // 止めている候補が、選ぶ前に上限（1 秒）で切れないように
        slow.release()
        guard case let .success(conn) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(conn.address, "127.0.0.1")
        conn.channel.close()
        let o = await host.outcomes(count: 2)
        XCTAssertEqual(o, [.noRequest, .noRequest])
        XCTAssertTrue(host.approver.asked.isEmpty, "確認の窓は出ない（hello を送っていない）")
        XCTAssertNotNil(host.runtime.currentCode, "コードは使用済みにならない")
    }

    func testAllCandidatesFailingGivesUnreachableAndWrongSecretGivesHandshakeFailed() async throws {
        try await startHost()
        // 127.0.0.7・127.0.0.8 は誰も応答しない（macOS のループバックは 127.0.0.1 だけ）。`readyTimeout`（3 秒）で「届かない」になる。
        // 2 つは並行に試す（300 ミリ秒ずらし）ので 3.3 秒ほど。順に試せば 6 秒
        var settings = fast; settings.readyTimeout = 3; settings.total = 10
        let c = Connector.Candidates(port: Int(port), addresses: ["127.0.0.7", "127.0.0.8"])
        let t0 = ContinuousClock.now
        let r = await Connector.connect(c, id: pid(1), secret: secret(1), kind: .registered, settings: settings)
        guard case let .failure(f) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(f, .unreachable)
        XCTAssertLessThan(secondsSince(t0), 4.8, "2 つを並行に試す（順に試せば 6 秒）")
        let wrong = await Connector.exchange(.status, expecting: .status, candidates: Connector.Candidates(port: Int(port), addresses: ["127.0.0.1"]),
                                             id: pid(1), secret: secret(1), settings: roomy)
        guard case let .failure(w) = wrong else { return XCTFail("\(wrong)") }
        XCTAssertEqual(w, .handshakeFailed(othersUnreachable: false), "Host に無い秘密は TLS が成立しない → 一致しないか別の機器")
        let o = await host.outcomes(count: 1)
        XCTAssertEqual(o, [.handshakeFailed])
    }

    func testOverallTimeoutWithOnlyUnansweredCandidates() async throws {
        try await startHost()
        let hole = try LoopbackRelay(port: port, role: .blackHole); defer { hole.stop() }
        var s = Connector.Settings(); s.readyTimeout = 5; s.total = 0.5
        let t0 = ContinuousClock.now
        let r = await Connector.connect(Connector.Candidates(port: Int(port), addresses: ["::1"]), id: pid(1), secret: secret(1), kind: .registered, settings: s)
        guard case let .failure(f) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(f, .timedOut)
        XCTAssertLessThan(secondsSince(t0), 3.5, "全体の上限（0.5 秒）で戻る（候補の上限の 5 秒を待たない）")
    }
}
