import Network
import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

/// 見る側と Host の 1 接続（ループバック）: 照合・指示と応答・名乗り
final class HostConnectionTests: XCTestCase {
    let a = pid(0xA1), b = pid(0xB2)
    let sa = secret(0x11), sb = secret(0x22)
    let status = StatusPayload(name: "Studio", model: "Mac Studio", paused: false, session: true, mode: .oneX, virtualDisplay: nil,
                               ambiguous: false, lastError: nil, setBy: nil, port: 47651, addresses: ["studio.local"])!

    func makeHost(_ d: FakeDelegate, psks: [PairingID: Bytes32]? = nil, timeouts: HostTimeouts = fastTimeouts(),
                  startFirst: Bool = false) throws -> LoopbackHost {
        try LoopbackHost(psks: psks ?? [a: sa, b: sb], delegate: d, timeouts: timeouts, startFirst: startFirst)
    }

    // ---- 照合 ----
    func testRegisteredSecretGetsStatus() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let s = status; d.respondWith = { _ in .status(s) }
        let h = try makeHost(d); defer { h.stop() }
        let r = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: a, secret: sa)
        XCTAssertEqual(r, .status(status))
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.served(a, .status)])
    }
    func testAlreadyStartedConnectionIsServed() async throws {
        // 受け付けた接続を先に始め、.ready になってから serve に渡す（M-2: 以前は handshakeTimeout になった）
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d, timeouts: fastTimeouts { $0.handshake = 1 }, startFirst: true); defer { h.stop() }
        let r = try await ViewerChannel.exchange(.unpair, expecting: .unpair, to: h.endpoint, id: a, secret: sa)
        XCTAssertEqual(r, .ok)
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.served(a, .unpair)])
    }
    func testWrongSecretFailsTLS() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d); defer { h.stop() }
        do { _ = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: a, secret: secret(0x99)); XCTFail("通ってしまった") }
        catch let e as NetError {
            guard case .handshakeFailed(.tls) = e else { return XCTFail("誤った秘密は TLS の失敗: \(e)") }
        }
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.handshakeFailed])
        XCTAssertEqual(o.first?.countsAsFailure, true)
    }
    func testClosedPortIsUnreachableNotTLS() async throws {
        // 誤った秘密（TLS の失敗）と、通信の失敗を見分けられる。
        // 通信口は、一度 bind して閉じたもの（受け側を閉じて 100 ミリ秒待つ形は、閉じ終える前につながることがあった。計画 2g）
        let closed = try XCTUnwrap(closedLoopbackPort()), port = try XCTUnwrap(NWEndpoint.Port(rawValue: closed))
        do { _ = try await ViewerChannel.exchange(.status, expecting: .status, to: .hostPort(host: "127.0.0.1", port: port), id: a, secret: sa, timeout: 5); XCTFail() }
        catch let e as NetError {
            guard case .unreachable(.posix(ECONNREFUSED)) = e else { return XCTFail("閉じた通信口は unreachable(ECONNREFUSED): \(e)") }
        }
    }
    func testRevokedAfterListenerCreatedIsNotPaired() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d); defer { h.stop() }
        d.revoke(a)   // 受け側を開き直す前（TLS は通る）でも、照合は今の登録表で断る
        let r = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: a, secret: sa)
        XCTAssertEqual(r, .error(.notPaired))
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.notPaired(.proof)])
    }
    func testClaimingAnotherIDIsNotPaired() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered); d.register(b, sb, .registered)
        let h = try makeHost(d); defer { h.stop() }
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        // a の秘密で TLS を通り、b を名乗る（proof は a の秘密で計算）
        let fake = Auth(id: b, proof: Binding.proof(secret: sa, id: b, ekm: ch.ekm))
        try await ch.channel.send(Request.status.encodedAsFirst(auth: fake)!, until: .now() + 2)
        let claimedOther = try await ch.receive(expecting: .status, timeout: 2)
        XCTAssertEqual(claimedOther, .error(.notPaired))
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.notPaired(.proof)])
        XCTAssertTrue(d.authenticated.isEmpty, "照合に失敗した接続は知らせない")
    }
    func testEkmDiffersPerConnection() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d); defer { h.stop() }
        let first = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        let second = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        XCTAssertNotEqual(first.ekm, second.ekm)
    }
    func testProofFromAnotherSessionIsNotPaired() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d); defer { h.stop() }
        let first = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        let oldProof = Binding.proof(secret: sa, id: a, ekm: first.ekm); first.close()
        let second = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        try await second.channel.send(Request.status.encodedAsFirst(auth: Auth(id: a, proof: oldProof))!, until: .now() + 2)
        let replayed = try await second.receive(expecting: .status, timeout: 2)
        XCTAssertEqual(replayed, .error(.notPaired))
    }
    func testDowngradeToPlainPSKIsRejectedBeforeReading() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d); defer { h.stop() }
        // 見る側が 0xA8（ECDHE なし）だけを出す → TLS は成立してしまうが（試作 7）、両側の確かめで断る
        let p2 = NWProtocolTLS.Options(); let o2 = p2.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(o2, TLSSettings.dispatchData(sa.data), TLSSettings.dispatchData(TLSSettings.identity(a)))
        sec_protocol_options_set_min_tls_protocol_version(o2, .TLSv12); sec_protocol_options_set_max_tls_protocol_version(o2, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(o2, tls_ciphersuite_t(rawValue: 0x00A8)!)
        do { _ = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa, parameters: NWParameters(tls: p2)); XCTFail("見る側が断らなかった") }
        catch let e as NetError { XCTAssertEqual(e, .session(.unexpected(version: 0x0303, suite: 0x00A8))) }
        let out = await h.outcomes(count: 1)
        XCTAssertEqual(out, [.sessionRejected(.unexpected(version: 0x0303, suite: 0x00A8))])
    }

    // ---- 応答するかどうか ----
    func testSilentPeerIsNoRequest() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d, timeouts: fastTimeouts { $0.firstRequest = 0.5 }); defer { h.stop() }
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        let o = await h.outcomes(count: 1, timeout: 5)
        XCTAssertEqual(o, [.noRequest])
        XCTAssertEqual(o.first?.countsAsFailure, true, "TLS が成立しても指示が無ければ失敗に数える")
        ch.close()
    }
    func testOversizeLineIsDropped() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d); defer { h.stop() }
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        try await ch.channel.send(Data(repeating: 0x61, count: Limits.requestMaxBytes + 10), until: .now() + 2)
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.dropped(.frame(.tooLarge))])
        XCTAssertEqual(o.first?.countsAsFailure, true, "照合の前の切断は失敗に数える")
    }
    func testCarriageReturnIsDropped() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d); defer { h.stop() }
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        try await ch.channel.send(Data("{\"v\":1}\r\n".utf8), until: .now() + 2)
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.dropped(.frame(.carriageReturn))])
    }
    func testNotJSONIsDropped() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d); defer { h.stop() }
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        try await ch.channel.send(Data("hello\n".utf8), until: .now() + 2)
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.dropped(.request(.badJSON))])
    }
    func testOtherVersionIsUnsupported() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d); defer { h.stop() }
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        try await ch.channel.send(Data("{\"v\":2,\"op\":\"status\"}\n".utf8), until: .now() + 2)
        let versionReply = try await ch.receive(expecting: .status, timeout: 2)
        XCTAssertEqual(versionReply, .error(.unsupportedVersion))
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.unsupportedVersion])
        XCTAssertEqual(o.first?.countsAsFailure, true, "照合の前")
    }
    func testUnknownOpAfterVerificationIsBadRequest() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d); defer { h.stop() }
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        let auth = Auth(id: a, proof: Binding.proof(secret: sa, id: a, ekm: ch.ekm))
        let line = String(decoding: Request.status.encodedAsFirst(auth: auth)!, as: UTF8.self).replacingOccurrences(of: "\"status\"", with: "\"shell\"")
        try await ch.channel.send(Data(line.utf8), until: .now() + 2)
        let unknownOpReply = try await ch.receive(expecting: .status, timeout: 2)
        XCTAssertEqual(unknownOpReply, .error(.badRequest))
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.badRequest(a)])
        XCTAssertEqual(o.first?.countsAsFailure, false, "照合の後")
        XCTAssertEqual(d.authenticated.map(\.id), [a], "照合が通った時点で相手役に知らせる（規則違反の前）")
        XCTAssertEqual(d.authenticated.map(\.kind), [.registered])
    }
    func testHostClosesAfterReplying() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d, timeouts: fastTimeouts { $0.firstRequest = 5 }); defer { h.stop() }
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        try await ch.sendFirst(.unpair)
        let r = try await ch.receive(expecting: .unpair, timeout: 2)
        XCTAssertEqual(r, .ok)
        let t0 = ContinuousClock.now
        do { _ = try await ch.channel.readLine(limit: Limits.responseMaxBytes, until: .now() + 8); XCTFail("続きが読めた") }
        catch let e as NetError { XCTAssertEqual(e, .closed, "応答の後、Host は接続を閉じる") }
        XCTAssertLessThan(secondsSince(t0), 4.0, "読み取りの締め切り（8 秒）を待たずに閉じている")
    }
    func testCodeSecretCannotSendStatus() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code)
        let h = try makeHost(d); defer { h.stop() }
        let r = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: a, secret: sa)
        XCTAssertEqual(r, .error(.badRequest))
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.badRequest(a)])
        XCTAssertEqual(o.first?.countsAsFailure, false, "照合に成功しているので失敗に数えない")
    }
    func testStatusWithCodeSecretLeavesTheCodeUsable() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code); d.decide = { _, _ in true }
        let h = try makeHost(d); defer { h.stop() }
        _ = try await ViewerChannel.exchange(.status, expecting: .status, to: h.endpoint, id: a, secret: sa)
        let k = try await ViewerChannel.pair(to: h.endpoint, id: a, secret: sa, name: "MacBook", showCode: { _ in })
        XCTAssertEqual(k, secret(0x77), "コードは使用済みにならない（このあと名乗れる）")
    }

    // ---- 名乗り（公開の pair）----
    func testPairingApprovedAndCodesMatch() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code)
        d.decide = { name, _ in name == "MacBook" }; d.newSecret = secret(0x55)
        let h = try makeHost(d); defer { h.stop() }
        let shown = Box<Int>()
        let k = try await ViewerChannel.pair(to: h.endpoint, id: a, secret: sa, name: "MacBook", showCode: { shown.set($0) })
        XCTAssertEqual(k, secret(0x55))
        XCTAssertEqual(d.codes, [try XCTUnwrap(shown.value)], "見る側と Host の確認番号が一致する")
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.paired(codeID: a)])
        XCTAssertEqual(d.completions.map(\.name), ["MacBook"], "承認された時だけ、名前と送り元を添えて保存する")
        XCTAssertEqual(d.completions.map(\.source), ["127.0.0.1"])
    }
    func testPairSanitizesTheName() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code); d.decide = { name, _ in name == "Office Mac" }
        let h = try makeHost(d); defer { h.stop() }
        let k = try await ViewerChannel.pair(to: h.endpoint, id: a, secret: sa, name: "Office \u{200D}Mac", showCode: { _ in })
        XCTAssertEqual(k, secret(0x77), "許されない文字を除いてから送る")
    }
    func testPairingDeclinedThrowsRejected() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code); d.decide = { _, _ in false }
        let h = try makeHost(d); defer { h.stop() }
        do { _ = try await ViewerChannel.pair(to: h.endpoint, id: a, secret: sa, name: "MacBook", showCode: { _ in }); XCTFail() }
        catch let e as NetError { XCTAssertEqual(e, .rejected(.notPaired)) }
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.notPaired(.declined)])
        XCTAssertTrue(d.completions.isEmpty, "拒否なら保存しない")
    }
    func testCodeIsSingleUse() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code); d.decide = { _, _ in false }
        let h = try makeHost(d); defer { h.stop() }
        _ = try? await ViewerChannel.pair(to: h.endpoint, id: a, secret: sa, name: "MacBook", showCode: { _ in })
        let shown = Box<Int>()
        do { _ = try await ViewerChannel.pair(to: h.endpoint, id: a, secret: sa, name: "MacBook", showCode: { shown.set($0) }); XCTFail() }
        catch let e as NetError { XCTAssertEqual(e, .rejected(.notPaired), "2 回目の名乗りは断る") }
        XCTAssertNil(shown.value, "確認番号は出ない")
    }
    func testRevealMustMatchCommitment() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code); d.decide = { _, _ in true }
        let h = try makeHost(d); defer { h.stop() }
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        try await ch.sendFirst(.hello(name: "MacBook", commitment: Commitment.make(Bytes32.random()!)))
        _ = try await ch.receive(expecting: .hello, timeout: 2)
        try await ch.sendReveal(Bytes32.random()!)   // 約束と違う開示
        let r = try await ch.receive(expecting: .reveal, timeout: 2)
        XCTAssertEqual(r, .error(.notPaired))
        XCTAssertEqual(d.codes, [], "約束が合わなければ確認の窓を出さない")
        let o = await h.outcomes(count: 1)
        XCTAssertEqual(o, [.notPaired(.commitment)])
    }
    func testRegisteredSecretCannotHello() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d); defer { h.stop() }
        do { _ = try await ViewerChannel.pair(to: h.endpoint, id: a, secret: sa, name: "MacBook", showCode: { _ in }); XCTFail() }
        catch let e as NetError { XCTAssertEqual(e, .rejected(.badRequest)) }
    }
    func testInvalidNameIsNotSent() async throws {
        let d = FakeDelegate(); d.register(a, sa, .code)
        let h = try makeHost(d); defer { h.stop() }
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        do { try await ch.sendFirst(.hello(name: "Office \u{200D} Mac", commitment: Commitment.make(Bytes32.random()!))); XCTFail() }
        catch let e as NetError { XCTAssertEqual(e, .invalidRequest) }
    }

    // ---- 受け側の PSK の数 ----
    func testListenerWith32PairingsAndOneCodeAcceptsEverySecret() async throws {
        let d = FakeDelegate()
        var psks: [PairingID: Bytes32] = [:]
        for n in 1...Limits.maxPairings {
            let id = pid(UInt8(n)), s = secret(UInt8(0x40 + n))
            d.register(id, s, .registered); psks[id] = s
        }
        let code = pid(0xC0), sc = secret(0xC0)
        d.register(code, sc, .code); psks[code] = sc
        XCTAssertEqual(psks.count, 33)
        let h = try makeHost(d, psks: psks); defer { h.stop() }
        for (id, s) in psks {
            let r = try await ViewerChannel.exchange(.unpair, expecting: .unpair, to: h.endpoint, id: id, secret: s, timeout: 5)
            // 登録済みは応答、コードの秘密は bad_request（どちらも TLS と照合は通っている）
            XCTAssertEqual(r, id == code ? .error(.badRequest) : .ok, id.hex)
        }
    }

    // ---- 受け側の開き直し ----
    func testListenerCancelKeepsAcceptedConnection() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d, timeouts: fastTimeouts { $0.firstRequest = 5 })
        let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
        h.stop()   // 受け側を閉じる（開き直しの途中を模す）
        try await Task.sleep(nanoseconds: 300_000_000)
        try await ch.sendFirst(.unpair)
        let afterListenerClosed = try await ch.receive(expecting: .unpair, timeout: 2)
        XCTAssertEqual(afterListenerClosed, .ok, "受け付け済みの接続は閉じた後も応答する")
    }

    // ---- 見る側の後片付け ----
    func testDroppingAViewerChannelClosesTheConnection() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d, timeouts: fastTimeouts { $0.firstRequest = 8 }); defer { h.stop() }
        weak var weakChannel: ViewerChannel?
        weak var weakInner: Channel?
        do {
            let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa)
            weakChannel = ch; weakInner = ch.channel
        }
        XCTAssertNil(weakChannel, "循環参照が無く、手放したら解放される")
        XCTAssertNil(weakInner)
        let o = await h.timedOutcomes(count: 1, timeout: 10)
        XCTAssertEqual(o.map(\.outcome), [.noRequest])
        XCTAssertLessThan(o.first?.seconds ?? 99, 5.0, "close を呼ばなくても deinit で閉じる（最初の指示の上限は .ready から 8 秒。待つと 8 秒以上）")
    }
    func testNWConnectionIsReleasedAfterUse() async throws {
        let d = FakeDelegate(); d.register(a, sa, .registered)
        let h = try makeHost(d); defer { h.stop() }
        let watch = Weak<NWConnection>()
        // 締め切りのタイマーは、取り消しても締め切りの時刻まで接続を持つ（GCD は取り消した処理を、予定の時刻まで手放さない）。
        // だから締め切りは短くするが、手続きまで 0.5 秒で済ませることは求めない（試したいのは解放。負荷の下では手続きが 0.5 秒を超える。計画 2g）
        do {
            let ch = try await ViewerChannel.open(to: h.endpoint, id: a, secret: sa, readyTimeout: 3)
            watch.set(ch.channel.connection)
            try await ch.sendFirst(.unpair, timeout: 3)
            _ = try await ch.receive(expecting: .unpair, timeout: 3)
        }
        XCTAssertFalse(watch.isGone, "締め切りのタイマーが残っている間は持たれている（下の待ちが、解放を実際に見ていることの対照）")
        await waitFor(10) { watch.isGone }
        XCTAssertTrue(watch.isGone, "接続と状態の見張りの間に循環参照が残らない")
    }
}
