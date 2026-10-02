import Network
import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

/// ネットワークに触れない小さな判定（版・方式、PSK の重複、.waiting の分け方、送り元の表記）
final class NetUnitTests: XCTestCase {
    // ---- 版・方式 ----
    func testSessionCheckAcceptsOnlyTLS12AndCCAC() {
        XCTAssertNil(SessionCheck.check(version: 0x0303, suite: 0xCCAC))
        for (v, s) in [(0x0304, 0xCCAC), (0x0302, 0xCCAC), (0x0301, 0xCCAC), (0x0303, 0xCCAB), (0x0303, 0x00A8), (0x0303, 0xC02F), (0x0304, 0x1303)] {
            XCTAssertEqual(SessionCheck.check(version: UInt16(v), suite: UInt16(s)), .unexpected(version: UInt16(v), suite: UInt16(s)),
                           String(format: "%04X/%04X", v, s))
        }
    }

    // ---- .waiting の分け方 ----
    func testStateErrorClassification() {
        XCTAssertEqual(Channel.stateError(.posix(.ECONNREFUSED), unsatisfiedReason: .localNetworkDenied), .localNetworkDenied)
        XCTAssertEqual(Channel.stateError(.posix(.ENETUNREACH), unsatisfiedReason: .localNetworkDenied), .localNetworkDenied)
        XCTAssertEqual(Channel.stateError(.posix(.ECONNREFUSED), unsatisfiedReason: nil), .unreachable(.posix(ECONNREFUSED)), "経路の理由が無ければ届かない")
        XCTAssertEqual(Channel.stateError(.posix(.ECONNREFUSED), unsatisfiedReason: .notAvailable), .unreachable(.posix(ECONNREFUSED)))
        XCTAssertEqual(Channel.stateError(.posix(.ENETDOWN), unsatisfiedReason: .cellularDenied), .unreachable(.posix(ENETDOWN)))
        XCTAssertEqual(Channel.stateError(.posix(.ENETDOWN), unsatisfiedReason: .wifiDenied), .unreachable(.posix(ENETDOWN)))
        XCTAssertEqual(Channel.stateError(.dns(-65554), unsatisfiedReason: nil), .unreachable(.dns(-65554)))
        XCTAssertEqual(Channel.stateError(.tls(-9820), unsatisfiedReason: nil), .handshakeFailed(.tls(-9820)), "TLS の失敗は手続きの失敗（誤った秘密など）")
        XCTAssertEqual(Channel.stateError(.tls(-9820), unsatisfiedReason: .localNetworkDenied), .handshakeFailed(.tls(-9820)))
    }

    // ---- 送り元の表記 ----
    func testSourceTextFromRawBytes() {
        XCTAssertEqual(HostConnection.sourceText(.ipv4(IPv4Address("192.168.1.20")!)), "192.168.1.20")
        XCTAssertEqual(HostConnection.sourceText(.ipv4(IPv4Address("127.0.0.1")!)), "127.0.0.1")
        XCTAssertEqual(HostConnection.sourceText(.ipv6(IPv6Address("::ffff:10.0.0.7")!)), "10.0.0.7", "IPv4-mapped は IPv4 に直す")
        XCTAssertEqual(HostConnection.sourceText(.ipv6(IPv6Address("FD7A:115C:A1E0:0:0:0:0:1")!)), "fd7a:115c:a1e0::1")
        XCTAssertEqual(HostConnection.sourceText(.ipv6(IPv6Address("fe80::1%lo0")!)), "fe80::1", "ゾーンは付けない")
        XCTAssertEqual(HostConnection.sourceText(.ipv6(IPv6Address("::1")!)), "::1")
        XCTAssertEqual(HostConnection.sourceText(.name("evil.local%0a", nil)), "?", "名前は表示しない")
        XCTAssertEqual(HostConnection.sourceText(.name("10.0.0.1", nil)), "?", "数字に見える名前も使わない")
        XCTAssertEqual(HostConnection.sourceText(endpoint: .hostPort(host: .ipv4(IPv4Address("10.1.2.3")!), port: 5)), "10.1.2.3")
        XCTAssertEqual(HostConnection.sourceText(endpoint: .service(name: "x", type: "_x._tcp", domain: "local", interface: nil)), "?")
    }

    // ---- 失敗に数えるもの（仕様「攻撃への備え」）----
    func testCountsAsFailureTable() {
        let a = pid(0xA1)
        var table: [(HostOutcome, Bool)] = [
            // 照合の前の切断・手続きの失敗
            (.handshakeFailed, true),
            (.handshakeTimeout, true),
            (.sessionRejected(.unexpected(version: 0x0303, suite: 0x00A8)), true),
            (.sessionRejected(.noMetadata), true),
            (.sessionRejected(.noKeyingMaterial), true),
            (.noRequest, true),
            (.dropped(.frame(.tooLarge)), true),
            (.dropped(.frame(.carriageReturn)), true),
            (.dropped(.frame(.bytesAfterNewline)), true),
            (.dropped(.request(.badJSON)), true),
            (.dropped(.request(.notObject)), true),
            (.dropped(.request(.noVersion)), true),
            (.unsupportedVersion, true),
            // Host 側の都合と、照合の後の規則違反・成功
            (.badRequest(a), false),
            (.sendFailed, false),
            (.delegateTimeout, false),
            (.cancelled, false),
            (.saveFailed(codeID: a), false),
            (.randomFailed, false),
            (.served(a, .status), false),
            (.paired(codeID: a), false),
        ]
        // 照合と名乗りの失敗、名乗りの途中の終わりは、理由によらず数える
        let reasons: [NotPairedReason] = [.noAuth, .proof, .codeUsedOrExpired, .noReveal, .revealUnreadable, .revealVersion,
                                          .commitment, .declined, .approvalTimeout, .peerClosed]
        table += reasons.map { (.notPaired($0), true) }
        for (o, expected) in table { XCTAssertEqual(o.countsAsFailure, expected, "\(o)") }
    }

    // 試験の受け側は、一時の通信口の範囲（49152〜65535）の外で待ち受ける（計画 2g。通信口 0 だと、受け側の通信口と接続の手元の通信口が
    // 同じ範囲から配られ、役が入れ替わった組がぶつかって `EADDRINUSE` になる）。選ぶ通信口は毎回違い、同じプロセスの中で使い回さない
    func testTestListenersStayOutsideTheEphemeralPortRange() async throws {
        let ephemeral: ClosedRange<UInt16> = 49152...65535
        let taken = (0..<60).compactMap { _ in TestPorts.shared.take() }
        XCTAssertEqual(taken.count, 60)
        XCTAssertEqual(Set(taken).count, 60, "同じ通信口を 2 度配らない（区画の境も越える）")
        XCTAssertTrue(taken.allSatisfy { TestPorts.range.contains($0) && !ephemeral.contains($0) }, "\(taken)")
        XCTAssertFalse(TestPorts.range.contains(UInt16(Limits.defaultPort)), "製品の既定の通信口（47651）とも重ならない")
        XCTAssertFalse(ephemeral.contains(UInt16(Limits.defaultPort)), "製品の Host は一時の通信口の範囲の外で待ち受ける")
        // 試験用の受け側のそれぞれ
        let d = FakeDelegate()
        let loop = try LoopbackHost(psks: [pid(1): secret(1)], delegate: d); defer { loop.stop() }
        let scripted = try ScriptedHost(psks: [pid(1): secret(1)]) { ch, _, _ in ch.close() }; defer { scripted.stop() }
        let relay = try SniffingRelay(to: loop.endpoint); defer { relay.stop() }
        let harness = ServerHarness(); await harness.start(); defer { harness.server.stop() }
        var ports: [UInt16] = []
        for e in [loop.endpoint, scripted.endpoint, relay.endpoint, harness.endpoint] {
            guard case let .hostPort(_, p) = e else { return XCTFail("\(e)") }
            ports.append(p.rawValue)
        }
        XCTAssertTrue(ports.allSatisfy { TestPorts.range.contains($0) }, "\(ports)")
        XCTAssertEqual(Set(ports).count, 4)
        XCTAssertFalse(TestPorts.isFree(ports[0]), "待ち受けている通信口は「空き」と見ない")
        let closed = try XCTUnwrap(closedLoopbackPort())
        XCTAssertTrue(TestPorts.range.contains(closed)); XCTAssertTrue(TestPorts.isFree(closed), "誰も待ち受けていない通信口")
    }

    // `TestPorts`（と `listenPortForTests`）は 3 つの試験群の補助に同じものを置いてある。1 つだけ直して食い違わないよう、1 字も違わないことを見る
    func testTestPortsIsTheSameInTheThreeTestTargets() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func block(_ path: String) throws -> String {
            let text = try String(contentsOf: tests.appendingPathComponent(path), encoding: .utf8)
            let start = try XCTUnwrap(text.range(of: "// ---- 試験の受け側の通信口 ----"), path)
            let head = try XCTUnwrap(text.range(of: "func listenPortForTests(", range: start.upperBound..<text.endIndex), path)
            let end = try XCTUnwrap(text.range(of: "\n}\n", range: head.upperBound..<text.endIndex), path)
            return String(text[start.lowerBound..<end.upperBound])
        }
        let net = try block("ShareScaleNetTests/TestSupport.swift")
        XCTAssertTrue(net.contains("final class TestPorts") && net.contains("O_CLOEXEC") && net.contains("XCTFail("), "切り出した範囲に型と関数が入っている")
        XCTAssertEqual(try block("ShareScaleCoreTests/HostFixture.swift"), net)
        XCTAssertEqual(try block("ShareScaleHostCoreTests/HostCoreTestSupport.swift"), net)
    }

    // 選んだ通信口を、空いていることを確かめてから開くまでの間にほかのプロセスに取られた時: 通信口を取り直して開く。
    // 3 回とも取られていれば、5 秒待たずに理由（使用中）で失敗する
    func testListenerPicksAnotherPortWhenTheChosenOneWasTakenAndFailsFastOtherwise() async throws {
        let blocker = try openLoopbackListener(label: "test.blocker", parameters: { .tcp }) { $0.newConnectionHandler = { $0.cancel() } }
        defer { blocker.cancel() }
        let taken = try XCTUnwrap(blocker.port?.rawValue)
        let free = try XCTUnwrap(TestPorts.shared.take())
        let offered = Locked<[UInt16]>([taken, free])
        let configured = Counter()
        let l = try openLoopbackListener(label: "test.retake", ports: { offered.update { $0.removeFirst() } }, parameters: { .tcp }) {
            configured.add(); $0.newConnectionHandler = { $0.cancel() }
        }
        defer { l.cancel() }
        XCTAssertEqual(l.port?.rawValue, free, "取られていた通信口の次に配られた通信口で開く")
        XCTAssertEqual(configured.value, 2, "取り直すたびに、受け付けの処理を付け直す")
        let t0 = ContinuousClock.now
        XCTAssertThrowsError(try openLoopbackListener(label: "test.retake.fail", ports: { taken }, parameters: { .tcp }) { $0.newConnectionHandler = { $0.cancel() } }) {
            guard case .posix(.EADDRINUSE)? = $0 as? NWError else { return XCTFail("使用中（EADDRINUSE）で失敗する: \($0)") }
        }
        XCTAssertLessThan(secondsSince(t0), 3.0, "3 回とも開けなければ、待ち切らずに失敗する（今までは 5 秒待って時間切れ）")
        // HostServer を動かす試験の土台も、取られていたら通信口を取り直して始める
        let h = ServerHarness(); h.port.value = taken
        await h.start(); defer { h.server.stop() }
        guard case let .listening(p) = h.server.listenerStatus else { return XCTFail("\(h.server.listenerStatus)") }
        XCTAssertNotEqual(p, taken); XCTAssertEqual(h.port.value, p); XCTAssertTrue(TestPorts.range.contains(p))
        XCTAssertEqual(h.listeningCount, 1, "取り直す前の記録は残さない")
    }
}
