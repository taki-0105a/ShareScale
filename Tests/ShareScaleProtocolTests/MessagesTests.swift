import XCTest
@testable import ShareScaleProtocol

final class RequestTests: XCTestCase {
    func testKindNamesEveryRequest() {
        let all: [(Request, Request.Kind)] = [(.hello(name: "Mac", commitment: .filled(1)), .hello), (.reveal(random: .filled(2)), .reveal),
                                              (.status, .status), (.set(.twoX), .set), (.log, .log), (.unpair, .unpair)]
        for (r, k) in all { XCTAssertEqual(r.kind, k); XCTAssertEqual(r.kind.rawValue, r.op) }
    }
    let auth = Auth(id: .sample, proof: .filled(9))
    let c = Bytes32.filled(3)
    func line(_ s: String) -> Data { Data(s.utf8) }
    func strip(_ d: Data) -> Data { d.dropLast() }   // 改行を除く

    func testRoundTripEveryRequest() {
        let firsts: [Request] = [.hello(name: "MacBook", commitment: c), .status, .set(.twoX), .log, .unpair]
        for r in firsts {
            guard let data = r.encodedAsFirst(auth: auth) else { return XCTFail("\(r)") }
            XCTAssertNil(r.encodedAsReveal(), "名乗りの開示以外は 2 つ目の指示として書き出せない")
            XCTAssertEqual(data.last, 0x0A)
            guard case let .ready(a, body) = RequestReader.open(strip(data), first: true) else { return XCTFail("\(r)") }
            XCTAssertEqual(a, auth)
            XCTAssertEqual(RequestReader.request(body, first: true), r)
        }
        XCTAssertNil(Request.reveal(random: c).encodedAsFirst(auth: auth), "名乗りの開示は最初の指示にできない")
        guard let rev = Request.reveal(random: c).encodedAsReveal() else { return XCTFail() }
        XCTAssertFalse(String(decoding: rev, as: UTF8.self).contains("proof"))
        guard case let .ready(a, body) = RequestReader.open(strip(rev), first: false) else { return XCTFail() }
        XCTAssertNil(a)
        XCTAssertEqual(RequestReader.request(body, first: false), .reveal(random: c))
    }
    func testEnvelopeDecisions() {
        XCTAssertEqual(RequestReader.open(line("{"), first: true), .drop(.badJSON))
        XCTAssertEqual(RequestReader.open(line("[1]"), first: true), .drop(.notObject))
        XCTAssertEqual(RequestReader.open(line(#"{"op":"status"}"#), first: true), .drop(.noVersion))
        XCTAssertEqual(RequestReader.open(line(#"{"v":true,"op":"status"}"#), first: true), .drop(.noVersion), "true は 1 ではない")
        XCTAssertEqual(RequestReader.open(line(#"{"v":2,"op":"status"}"#), first: true), .unsupportedVersion)
        XCTAssertEqual(RequestReader.open(line(#"{"v":1,"op":"status"}"#), first: true), .notPaired, "最初の指示に id・proof が無い")
        XCTAssertEqual(RequestReader.open(line(#"{"v":1,"op":"status","id":"ABC","proof":"x"}"#), first: true), .notPaired)
        XCTAssertEqual(RequestReader.open(line(#"{"v":1,"v":1,"op":"status"}"#), first: true), .drop(.badJSON), "同じキー")
    }
    func testHelloNameMustPassTheHostRules() {
        let zwj = ["Office \u{1F468}\u{200D}\u{1F4BB} Mac", "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}Mac", "a\nb", "", "   "]
        for name in zwj {
            XCTAssertNil(NameRules.validate(name), name.debugDescription)
            XCTAssertNil(Request.hello(name: name, commitment: c).encodedAsFirst(auth: auth), "Host が拒否する名前は書き出さない: \(name.debugDescription)")
            let clean = NameRules.sanitize(name)
            guard let data = Request.hello(name: clean, commitment: c).encodedAsFirst(auth: auth),
                  case let .ready(_, body) = RequestReader.open(data.dropLast(), first: true) else { XCTFail("sanitize の後は書き出せる"); continue }
            XCTAssertEqual(RequestReader.request(body, first: true), .hello(name: clean, commitment: c))
        }
    }
    func testReasonsKeepTheirWireNames() {
        XCTAssertEqual([RequestReader.DropReason.badJSON, .notObject, .noVersion].map(\.rawValue), ["bad_json", "not_object", "no_version"])
        XCTAssertEqual([LineFraming.FrameRejection.tooLarge, .bytesAfterNewline, .carriageReturn].map(\.rawValue),
                       ["too_large", "bytes_after_newline", "carriage_return"])
    }
    func testHandMadeDuplicateKeysDoNotCrash() {
        let a: [(String, JSONValue)] = [("id", .string(auth.id.hex)), ("proof", .string(auth.proof.base64URL))]
        XCTAssertNil(RequestReader.request(.object([("v", .integer(1)), ("op", .string("status"))] + a + [("id", .string(auth.id.hex))]), first: true))
        XCTAssertNil(RequestReader.request(.object([("v", .integer(1)), ("op", .string("reveal")), ("r", .string("x")), ("r", .string("y"))]), first: false))
        XCTAssertNil(StatusPayload.from(.object([("name", .string("x")), ("name", .string("y"))])))
    }
    func testBadRequestsAfterVerification() {
        func req(_ s: String, first: Bool = true) -> Request? {
            guard case let .ready(_, body) = RequestReader.open(line(s), first: first) else { return .status }  // 1 段目で落ちたら不合格にする
            return RequestReader.request(body, first: first)
        }
        let a = #""id":"00112233445566778899aabbccddeeff","proof":"\#(Base64URL.encode(Data(repeating: 9, count: 32)))""#
        let cc = c.base64URL
        XCTAssertNil(req(#"{"v":1,"op":"shell",\#(a)}"#), "知らない op")
        XCTAssertNil(req(#"{"v":1,"op":"status","x":1,\#(a)}"#), "知らないキー")
        XCTAssertNil(req(#"{"v":1,"op":"set","mode":"3x",\#(a)}"#))
        XCTAssertNil(req(#"{"v":1,"op":"set",\#(a)}"#))
        XCTAssertNil(req(#"{"v":1,"op":"hello","name":"a\nb","c":"\#(cc)",\#(a)}"#), "名前の規則違反")
        XCTAssertNil(req(#"{"v":1,"op":"hello","name":"Mac","c":"AAAA",\#(a)}"#), "c が 32 バイトでない")
        XCTAssertNil(req(#"{"v":1,"op":"reveal","r":"\#(cc)",\#(a)}"#), "reveal は最初の指示にできない")
        XCTAssertNil(req(#"{"v":1,"op":"status"}"#, first: false), "名乗り以外の 2 つ目の指示")
        XCTAssertNil(req(#"{"v":1,"op":"reveal","r":"\#(cc)",\#(a)}"#, first: false), "2 つ目の指示に id・proof は付けない")
        XCTAssertEqual(req(#"{"v":1,"op":"hello","name":"Cafe\#u{301}","c":"\#(cc)",\#(a)}"#), .hello(name: "Café", commitment: c), "名前は NFC にして渡す")
    }
}

final class ResponseTests: XCTestCase {
    let status = StatusPayload(name: "居間のMac Studio", model: "Mac Studio", paused: false, session: true, mode: .oneX,
                               virtualDisplay: .init(resolution: "1920x997", scaling: .oneX, source: .signature),
                               ambiguous: false, lastError: nil, setBy: .init(byYou: true, at: 1_790_000_000),
                               port: 47651, addresses: ["Studio.local", "100.101.77.7"])!

    func roundTrip(_ r: Response, _ e: Response.Expectation) throws -> Response {
        let d = r.encoded()
        XCTAssertEqual(d.last, 0x0A)
        XCTAssertLessThanOrEqual(d.count, Limits.responseMaxBytes)
        return try Response.decode(d.dropLast(), expecting: e)
    }
    func testRoundTrips() throws {
        let r = Bytes32.filled(4)
        XCTAssertEqual(try roundTrip(.helloChallenge(hostRandom: r), .hello), .helloChallenge(hostRandom: r))
        XCTAssertEqual(try roundTrip(.paired(newSecret: r), .reveal), .paired(newSecret: r))
        XCTAssertEqual(try roundTrip(.status(status), .status), .status(status))
        let noVD = StatusPayload(name: "x", model: "y", paused: true, session: false, mode: .off, virtualDisplay: nil, ambiguous: true,
                                 lastError: "apply failed", setBy: nil, port: 1, addresses: ["a.local"])!
        XCTAssertEqual(try roundTrip(.status(noVD), .set), .status(noVD))
        XCTAssertEqual(try roundTrip(.log(["a", "b"]), .log), .log(["a", "b"]))
        XCTAssertEqual(try roundTrip(.ok, .unpair), .ok)
        for e in [ErrorCode.badRequest, .paused, .busy, .notPaired, .unsupportedVersion] {
            XCTAssertEqual(try roundTrip(.error(e), .status), .error(e))
        }
        XCTAssertTrue(String(decoding: Response.error(.unsupportedVersion).encoded(), as: UTF8.self).contains(#""supported":[1]"#))
    }
    func testLogIsCappedAt50Lines() throws {
        let many = (0..<80).map { "line \($0)" }
        guard case let .log(lines) = try roundTrip(.log(many), .log) else { return XCTFail() }
        XCTAssertEqual(lines.count, 50)
    }
    func testViewerRejectsUnexpectedShapes() {
        func bad(_ s: String, _ e: Response.Expectation, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try Response.decode(Data(s.utf8), expecting: e), s, file: file, line: line)
        }
        let r = Base64URL.encode(Data(repeating: 4, count: 32))
        bad(#"{"v":1,"ok":true,"r":"\#(r)","extra":1}"#, .hello)
        bad(#"{"v":1,"ok":true,"k":"AAAA"}"#, .reveal)
        bad(#"{"v":1,"ok":1,"r":"\#(r)"}"#, .hello)
        bad(#"{"v":2,"ok":true}"#, .unpair)
        bad(#"{"v":1,"ok":false,"error":"nope"}"#, .status)
        bad(#"{"v":1,"ok":false,"error":"unsupported_version"}"#, .status)
        bad(#"{"v":1,"ok":true,"r":"\#(r)"}"#, .status)  // 形の違う成功
        bad(#"{"v":1,"ok":true,"lines":["\#(String(repeating: "x", count: 257))"]}"#, .log)
        var s = String(decoding: Response.status(status).encoded().dropLast(), as: UTF8.self)
        s = s.replacingOccurrences(of: #""scaling":"1x""#, with: #""scaling":"3x""#)
        bad(s, .status)
        let badAddr = String(decoding: Response.status(status).encoded().dropLast(), as: UTF8.self)
            .replacingOccurrences(of: "Studio.local", with: "[fe80::1]")
        bad(badAddr, .status)
    }
}
