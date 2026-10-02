import XCTest
@testable import ShareScaleProtocol

/// 書き出しと読み取りの整合（Host が書き出したものは見る側の検査を必ず通る）
final class WriterReaderConsistencyTests: XCTestCase {
    func status(port: Int = 1, addresses: [String] = ["a.local"], resolution: String = "1920x997", at: Int64 = 0) -> StatusPayload? {
        StatusPayload(name: "x", model: "y", paused: false, session: true, mode: .oneX,
                      virtualDisplay: .init(resolution: resolution, scaling: .twoX, source: .learned), ambiguous: false,
                      lastError: nil, setBy: .init(byYou: false, at: at), port: port, addresses: addresses)
    }

    func testStatusAddressesMustBeOneToEight() {
        XCTAssertNil(status(addresses: []), "0 件は見る側の候補を空にしてしまう")
        XCTAssertNotNil(status(addresses: (1...8).map { "h\($0).local" }))
        XCTAssertNil(status(addresses: (1...9).map { "h\($0).local" }))
        // 手で作った 0 件の行は見る側が拒否する
        let text = String(decoding: Response.status(status()!).encoded().dropLast(), as: UTF8.self)
            .replacingOccurrences(of: #""a":["a.local"]"#, with: #""a":[]"#)
        XCTAssertThrowsError(try Response.decode(Data(text.utf8), expecting: .status))
    }
    func testStatusRejectsWhatTheViewerWouldReject() {
        XCTAssertNotNil(status())
        XCTAssertNil(status(port: 0)); XCTAssertNil(status(port: 65536)); XCTAssertNotNil(status(port: 65535))
        XCTAssertNil(status(addresses: ["[fe80::1]"])); XCTAssertNil(status(addresses: ["FD7A::1"]))
        XCTAssertNil(status(addresses: ["1.2.3.4\u{0}evil"])); XCTAssertNil(status(addresses: ["0x7f.1"]))
        XCTAssertNil(status(at: -1)); XCTAssertNotNil(status(at: .max))
        XCTAssertNil(status(resolution: "abc")); XCTAssertNil(status(resolution: "123456x1")); XCTAssertNotNil(status(resolution: "0x99999"))
    }
    func testPairingCodeRejectsWhatTheViewerWouldReject() {
        func code(secret: Bytes32 = .counting, port: Int = 1, addresses: [String] = ["a.local"]) -> PairingCode? {
            PairingCode(id: .sample, secret: secret, port: port, addresses: addresses, expiresAt: 0)
        }
        XCTAssertNotNil(code())
        XCTAssertNil(code(port: 0)); XCTAssertNil(code(port: 65536))
        XCTAssertNil(code(addresses: [])); XCTAssertNil(code(addresses: (1...9).map { "h\($0).local" }))
        XCTAssertNil(code(addresses: ["::ffff:1.2.3.4"]))
        let longest = [String](repeating: String(repeating: "a", count: 63), count: 4).joined(separator: ".").dropLast(2)
        XCTAssertTrue(CandidateAddress.isValid(String(longest)))
        XCTAssertNil(code(addresses: [String](repeating: String(longest), count: 8)), "書き出すと 1 KiB を超える")
    }

    /// 書き出したものは必ず読み取りを通る（決まった種のでたらめな値で）
    func testEverythingWrittenIsReadBack() throws {
        var rng = TestLCG(seed: 20260925)
        let texts = ["", "Mac", String(repeating: "あ", count: 200), "a\u{1B}[31m\u{202E}b", "😀\n\"\\", String(repeating: "\"", count: 300)]
        let longest = String([String](repeating: String(repeating: "b", count: 63), count: 4).joined(separator: ".").dropLast(2))
        let addrs = ["Studio.local", "a", "x-1.example", "100.101.77.7", "0.0.0.0", "fd7a:115c:a1e0::1", "::1", "fe80::1", longest]
        var codes = (made: 0, refused: 0)
        for _ in 0..<1_000 {
            let addresses = (0..<rng.inRange(1...8)).map { _ in rng.pick(addrs) }
            let port = rng.inRange(1...65535)
            let vd: StatusPayload.VirtualDisplay? = rng.bool() ? nil
                : .init(resolution: "\(rng.inRange(0...99999))x\(rng.inRange(0...99999))", scaling: rng.pick([.oneX, .twoX]), source: rng.pick([.signature, .learned]))
            let setBy: StatusPayload.SetBy? = rng.bool() ? nil : .init(byYou: rng.bool(), at: Int64(bitPattern: rng.next() >> 1))
            guard let s = StatusPayload(name: rng.pick(texts), model: rng.pick(texts), paused: rng.bool(), session: rng.bool(),
                                        mode: rng.pick([.oneX, .twoX, .off]), virtualDisplay: vd, ambiguous: rng.bool(),
                                        lastError: rng.bool() ? nil : rng.pick(texts), setBy: setBy, port: port, addresses: addresses)
            else { return XCTFail("正しい値で作れない: \(addresses)") }
            let line = Response.status(s).encoded()
            XCTAssertLessThanOrEqual(line.count, Limits.responseMaxBytes)
            guard case let .status(r) = try Response.decode(line.dropLast(), expecting: rng.pick([.status, .set])) else { return XCTFail() }
            XCTAssertEqual(r.addresses, s.addresses); XCTAssertEqual(r.port, s.port); XCTAssertEqual(r.virtualDisplay, s.virtualDisplay)
            XCTAssertEqual(r.setBy, s.setBy); XCTAssertEqual(r.name, TextRules.clip(s.name))

            let lines = (0..<rng.inRange(0...80)).map { _ in rng.pick(texts) }
            XCTAssertNoThrow(try Response.decode(Response.log(lines).encoded().dropLast(), expecting: .log))

            guard let id = PairingID(bytes: rng.bytes(16)) else { return XCTFail() }
            let expiresAt = Int64(bitPattern: rng.next())
            if let code = PairingCode(id: id, secret: Bytes32(Data(rng.bytes(32)))!, port: port, addresses: addresses, expiresAt: expiresAt) {
                codes.made += 1
                XCTAssertLessThanOrEqual(code.encoded().utf8.count, Limits.pairingCodeMaxBytes)
                XCTAssertEqual(try PairingCode.decode(code.encoded()), code)
            } else {
                codes.refused += 1   // 長いホスト名が多いと 1 KiB を超える
            }
        }
        XCTAssertGreaterThan(codes.made, 100)
        XCTAssertGreaterThan(codes.refused, 10, "大きさの上限を試せた")
    }
    func testLongLogAlwaysPassesTheViewer() throws {
        let worst = (0..<80).map { _ in String(repeating: "\"", count: 300) }   // 書き出すと 2 倍に膨らむ文字
        let data = Response.log(worst).encoded()
        XCTAssertLessThanOrEqual(data.count, Limits.responseMaxBytes)
        guard case let .log(lines) = try Response.decode(data.dropLast(), expecting: .log) else { return XCTFail() }
        XCTAssertLessThanOrEqual(lines.count, Limits.logMaxLines)
        XCTAssertTrue(lines.allSatisfy { $0.utf8.count <= Limits.textMaxBytes })
        XCTAssertFalse(lines.isEmpty, "入るだけは残す")
    }
    func testLogKeepsNewestLinesWhenTrimming() throws {
        let many = (0..<80).map { "line \($0)" }
        guard case let .log(lines) = try Response.decode(Response.log(many).encoded().dropLast(), expecting: .log) else { return XCTFail() }
        XCTAssertEqual(lines.last, "line 79", "新しい行を残す")
        XCTAssertEqual(lines.count, 50)
    }
    func testLongStatusTextIsClippedNotRejected() throws {
        let long = String(repeating: "あ", count: 200) + "\u{1B}"   // 600 バイト＋制御文字
        let s = StatusPayload(name: long, model: long, paused: false, session: true, mode: .oneX, virtualDisplay: nil, ambiguous: false,
                              lastError: long, setBy: nil, port: 1, addresses: ["a.local"])!
        guard case let .status(r) = try Response.decode(Response.status(s).encoded().dropLast(), expecting: .status) else { return XCTFail() }
        for t in [r.name, r.model, r.lastError!] {
            XCTAssertLessThanOrEqual(t.utf8.count, Limits.textMaxBytes)
            XCTAssertFalse(t.unicodeScalars.contains { $0.value == 0x1B })
        }
        XCTAssertEqual(r.name, String(repeating: "あ", count: 85), "UTF-8 の文字の途中で切らない（255 バイト）")
    }
    func testClipText() {
        XCTAssertEqual(TextRules.clip("abc", maxBytes: 2), "ab")
        XCTAssertEqual(TextRules.clip("aあ", maxBytes: 3), "a", "文字の途中で切らない")
        XCTAssertEqual(TextRules.clip("a😀", maxBytes: 4), "a", "4 バイトの文字の途中で切らない")
        XCTAssertEqual(TextRules.clip("a😀", maxBytes: 5), "a😀")
        XCTAssertEqual(TextRules.clip("a\nb\u{202E}c", maxBytes: 10), "abc", "制御文字を除く")
        XCTAssertEqual(TextRules.clip(String(repeating: "é", count: 200)).utf8.count, 256, "既定は 256 バイト")
    }
}
