import Foundation
import Network
import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

/// 点検で「壊しても通った」性質: セッションの再開、中継での確認番号、同時の名乗り
final class AttackTests: XCTestCase {
    let a = pid(0xA1), sa = secret(0x11)

    // ---- セッションの再開が使われない ----
    func testEveryConnectionDoesTheFullHandshake() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try LoopbackHost(psks: [a: sa], delegate: d); defer { h.stop() }
        let relay = try SniffingRelay(to: h.endpoint); defer { relay.stop() }
        // 同じ見る側（同じ設定の値）から、同じ宛先へ 2 回つなぐ（再開が有効なら 2 回目で使われるはずの条件）
        let params = TLSSettings.parameters(id: a, secret: sa)
        var ekms: [Bytes32] = []
        for _ in 0..<2 {
            let ch = try await ViewerChannel.open(to: relay.endpoint, id: a, secret: sa, parameters: params)
            ekms.append(ch.ekm)
            try await ch.sendFirst(.unpair)
            let r = try await ch.receive(expecting: .unpair, timeout: 2)
            XCTAssertEqual(r, .ok)
            ch.close()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard hasCount(ekms, 2) else { return }
        XCTAssertNotEqual(ekms[0], ekms[1])
        let flows = relay.captured
        XCTAssertEqual(flows.count, 2)
        for (n, flow) in flows.enumerated() {
            let hs = plaintextHandshakes(flow)
            let hello = try XCTUnwrap(hs.first { $0.type == 1 }, "接続 \(n + 1): ClientHello")
            let summary = try XCTUnwrap(clientHelloSummary(hello.body))
            XCTAssertEqual(summary.sessionIDLength, 0, "接続 \(n + 1): 前のセッションの ID を出さない")
            XCTAssertFalse(summary.extensions.contains(0x0023), "接続 \(n + 1): セッションチケットを申し出ない")
            XCTAssertTrue(hs.contains { $0.type == 16 }, "接続 \(n + 1): ClientKeyExchange がある（PSK と ECDHE で手続き全体を行った）")
        }
    }

    // 外のコマンドを同期に待つので、async にしない（async の試験は協調スレッドの上で動き、待つ間そのスレッドを塞ぐ。
    // スレッドが 1 本しか空いていない時は Host の Task が動けず、openssl が 5 秒で打ち切られていた。計画 2g）
    func testOpenSSLCannotResumeASession() throws {
        let candidates = ["/opt/homebrew/opt/openssl@3/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl", "/usr/local/bin/openssl"]
        guard let openssl = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              run(openssl, ["version"]).contains("OpenSSL") else { throw XCTSkip("OpenSSL（LibreSSL でないもの）が無い") }
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try LoopbackHost(psks: [a: sa], delegate: d); defer { h.stop() }
        guard case let .hostPort(_, port) = h.endpoint else { return XCTFail() }
        let sess = FileManager.default.temporaryDirectory.appendingPathComponent("sss-sess-\(UUID().uuidString).pem").path
        defer { unlink(sess) }
        let common = ["s_client", "-connect", "127.0.0.1:\(port.rawValue)", "-tls1_2", "-cipher", "ECDHE-PSK-CHACHA20-POLY1305",
                      "-psk_identity", a.hex, "-psk", sa.data.map { String(format: "%02x", $0) }.joined()]
        let first = run(openssl, common + ["-sess_out", sess])
        XCTAssertTrue(first.contains("New, TLSv1.2, Cipher is ECDHE-PSK-CHACHA20-POLY1305"), "対照: openssl でつながる\n\(first.suffix(600))")
        guard FileManager.default.fileExists(atPath: sess) else { return }   // 保存するセッションが無い（再開の手がかりも無い）
        let second = run(openssl, common + ["-sess_in", sess])
        XCTAssertFalse(second.contains("Reused,"), "保存したセッションで再開できてしまった\n\(second.suffix(600))")
        XCTAssertTrue(second.contains("New, TLSv1.2"), "手続き全体を行う\n\(second.suffix(600))")
    }

    /// 外のコマンドを 5 秒まで動かし、標準出力と標準エラーを返す（標準入力は空）
    func run(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); killer.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    // ---- 中継で確認番号が変わる ----
    func testRelayedHelloGivesDifferentConfirmationCodes() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code); d.decide = { _, _ in false }
        let host = try LoopbackHost(psks: [a: sa], delegate: d); defer { host.stop() }
        let hostEndpoint = host.endpoint
        let a = self.a, sa = self.sa
        let seen = Box<(viewerSide: Bytes32, hostSide: Bytes32)>()
        // 中継役: 見る側には偽の Host、Host には偽の見る側。どちらの側でもコードの秘密を知っている
        let relay = try ScriptedHost(psks: [a: sa]) { down, line, ekmDown in
            defer { down.close() }
            guard let ekmDown, case let .ready(_, body) = RequestReader.open(line, first: true),
                  case let .hello(name, commitment)? = RequestReader.request(body, first: true),
                  let up = try? await ViewerChannel.open(to: hostEndpoint, id: a, secret: sa) else { return }
            defer { up.close() }
            seen.set((ekmDown, up.ekm))
            // 名乗りは Host 側の TLS セッションの proof を付け直して送る（約束 c はそのまま）
            guard (try? await up.sendFirst(.hello(name: name, commitment: commitment))) != nil,
                  let challenge = try? await up.channel.readLine(limit: Limits.responseMaxBytes, until: .now() + 3),
                  (try? await down.send(challenge + Data([0x0A]), until: .now() + 3)) != nil,
                  // 見る側の開示はそのまま中継する
                  let reveal = try? await down.readLine(limit: Limits.requestMaxBytes, until: .now() + 3),
                  (try? await up.channel.send(reveal + Data([0x0A]), until: .now() + 3)) != nil,
                  let final = try? await up.channel.readLine(limit: Limits.responseMaxBytes, until: .now() + 3) else { return }
            _ = try? await down.send(final + Data([0x0A]), until: .now() + 3)
        }
        defer { relay.stop() }

        let ch = try await ViewerChannel.open(to: relay.endpoint, id: a, secret: sa); defer { ch.close() }
        let rv = Bytes32.random()!
        try await ch.sendFirst(.hello(name: "MacBook", commitment: Commitment.make(rv)))
        guard case let .helloChallenge(rh) = try await ch.receive(expecting: .hello, timeout: 2) else { return XCTFail("乱数が中継されない") }
        let viewerCode = ConfirmationCode.derive(ekm: ch.ekm, viewerRandom: rv, hostRandom: rh)
        try await ch.sendReveal(rv)
        let final = try await ch.receive(expecting: .reveal, timeout: 5)
        XCTAssertEqual(final, .error(.notPaired))
        XCTAssertEqual(d.codes.count, 1, "中継された名乗りで Host に確認の窓が出た（約束と開示は一致した）")
        XCTAssertNotEqual(d.codes.first, viewerCode, "見る側と Host の確認番号は一致しない")
        let ekms = try XCTUnwrap(seen.value)
        XCTAssertEqual(ekms.viewerSide, ch.ekm)
        XCTAssertNotEqual(ekms.viewerSide, ekms.hostSide, "中継の両側の ekm は違う")
    }

    // ---- 同時の名乗り ----
    func testConcurrentHellosWithOneCodeGetOneChallenge() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code)
        let h = try LoopbackHost(psks: [a: sa], delegate: d); defer { h.stop() }
        let endpoint = h.endpoint, a = self.a, sa = self.sa
        let responses = await withTaskGroup(of: Response?.self) { g in
            for _ in 0..<8 {
                g.addTask {
                    guard let ch = try? await ViewerChannel.open(to: endpoint, id: a, secret: sa) else { return nil }
                    defer { ch.close() }
                    guard (try? await ch.sendFirst(.hello(name: "MacBook", commitment: Commitment.make(Bytes32.random()!)))) != nil else { return nil }
                    return try? await ch.receive(expecting: .hello, timeout: 2)
                }
            }
            var all: [Response?] = []
            for await r in g { all.append(r) }
            return all
        }
        XCTAssertEqual(responses.count, 8)
        let challenges = responses.filter { if case .helloChallenge? = $0 { return true }; return false }
        XCTAssertEqual(challenges.count, 1, "乱数を受け取るのは 1 本だけ")
        XCTAssertEqual(responses.filter { $0 == .error(.notPaired) }.count, 7, "残りは not_paired")
        let o = await h.outcomes(count: 8)
        XCTAssertEqual(o.filter { $0 == .notPaired(.codeUsedOrExpired) }.count, 7)
    }
}
