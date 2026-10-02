import XCTest
@testable import ShareScaleProtocol

/// 通信の形を固定する。1 行の字句は仕様（「指示と応答」「接続コード」）の形から写したもので、キーの順は今の書き出しの順。
/// Swift の型や API を変えても、ここが通る限り相手の版とやりとりできる
final class WireFormatTests: XCTestCase {
    let id = "00112233445566778899aabbccddeeff"
    // base64url の値は Python の標準ライブラリで独立に計算したもの
    let c = "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM"        // 3 が 32 バイト
    let proof = "CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk"    // 9 が 32 バイト
    let r = "BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ"        // 4 が 32 バイト
    let k = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"        // 0〜31
    var auth: Auth { Auth(id: PairingID(hex: id)!, proof: .filled(9)) }

    func text(_ d: Data?) -> String? { d.map { String(decoding: $0, as: UTF8.self) } }

    // MARK: 指示（見る側 → Host）

    func testFirstRequests() {
        let a = #""id":"\#(id)","proof":"\#(proof)""#
        let cases: [(Request, String)] = [
            (.hello(name: "MacBook", commitment: .filled(3)), #"{"v":1,"op":"hello","name":"MacBook","c":"\#(c)",\#(a)}"#),
            (.status, #"{"v":1,"op":"status",\#(a)}"#),
            (.set(.oneX), #"{"v":1,"op":"set","mode":"1x",\#(a)}"#),
            (.set(.twoX), #"{"v":1,"op":"set","mode":"2x",\#(a)}"#),
            (.set(.off), #"{"v":1,"op":"set","mode":"off",\#(a)}"#),
            (.log, #"{"v":1,"op":"log",\#(a)}"#),
            (.unpair, #"{"v":1,"op":"unpair",\#(a)}"#),
        ]
        for (request, wire) in cases {
            XCTAssertEqual(text(request.encodedAsFirst(auth: auth)), wire + "\n", "書き出し: \(request)")
            guard case let .ready(gotAuth, body) = RequestReader.open(Data(wire.utf8), first: true) else { XCTFail(wire); continue }
            XCTAssertEqual(gotAuth, auth)
            XCTAssertEqual(RequestReader.request(body, first: true), request, "読み取り: \(wire)")
        }
    }
    func testRevealRequest() {
        let wire = #"{"v":1,"op":"reveal","r":"\#(r)"}"#
        XCTAssertEqual(text(Request.reveal(random: .filled(4)).encodedAsReveal()), wire + "\n")
        guard case let .ready(gotAuth, body) = RequestReader.open(Data(wire.utf8), first: false) else { return XCTFail() }
        XCTAssertNil(gotAuth)
        XCTAssertEqual(RequestReader.request(body, first: false), .reveal(random: .filled(4)))
    }

    // MARK: 応答（Host → 見る側）

    func check(_ response: Response, _ wire: String, _ expecting: [Response.Expectation], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(text(response.encoded()), wire + "\n", "書き出し", file: file, line: line)
        for e in expecting {
            XCTAssertEqual(try Response.decode(Data(wire.utf8), expecting: e), response, "読み取り（\(e)）", file: file, line: line)
        }
    }

    func testSuccessResponses() {
        check(.helloChallenge(hostRandom: .filled(4)), #"{"v":1,"ok":true,"r":"\#(r)"}"#, [.hello])
        check(.paired(newSecret: .counting), #"{"v":1,"ok":true,"k":"\#(k)"}"#, [.reveal])
        check(.log(["applied 2x", "ロック中"]), #"{"v":1,"ok":true,"lines":["applied 2x","ロック中"]}"#, [.log])
        check(.log([]), #"{"v":1,"ok":true,"lines":[]}"#, [.log])
        check(.ok, #"{"v":1,"ok":true}"#, [.unpair])
    }
    func testStatusResponses() {
        let full = StatusPayload(name: "居間のMac Studio", model: "Mac Studio", paused: false, session: true, mode: .oneX,
                                 virtualDisplay: .init(resolution: "1920x997", scaling: .oneX, source: .signature),
                                 ambiguous: false, lastError: nil, setBy: .init(byYou: true, at: 1_790_000_000),
                                 port: 47651, addresses: ["Studio.local", "100.101.77.7"])!
        check(.status(full), #"{"v":1,"ok":true,"status":{"name":"居間のMac Studio","model":"Mac Studio","paused":false,"session":true,"mode":"1x","vd":{"res":"1920x997","scaling":"1x","source":"signature"},"ambiguous":false,"last_error":null,"set_by":{"who":"you","at":1790000000},"addrs":{"p":47651,"a":["Studio.local","100.101.77.7"]}}}"#,
              [.status, .set])
        let other = StatusPayload(name: "x", model: "y", paused: true, session: false, mode: .off,
                                  virtualDisplay: .init(resolution: "3840x2160", scaling: .twoX, source: .learned),
                                  ambiguous: true, lastError: "apply failed", setBy: .init(byYou: false, at: 0),
                                  port: 1, addresses: ["fd7a:115c:a1e0::1"])!
        check(.status(other), #"{"v":1,"ok":true,"status":{"name":"x","model":"y","paused":true,"session":false,"mode":"off","vd":{"res":"3840x2160","scaling":"2x","source":"learned"},"ambiguous":true,"last_error":"apply failed","set_by":{"who":"other","at":0},"addrs":{"p":1,"a":["fd7a:115c:a1e0::1"]}}}"#,
              [.status, .set])
        let bare = StatusPayload(name: "x", model: "y", paused: false, session: false, mode: .twoX, virtualDisplay: nil,
                                 ambiguous: false, lastError: nil, setBy: nil, port: 47651, addresses: ["a.local"])!
        check(.status(bare), #"{"v":1,"ok":true,"status":{"name":"x","model":"y","paused":false,"session":false,"mode":"2x","vd":null,"ambiguous":false,"last_error":null,"set_by":null,"addrs":{"p":47651,"a":["a.local"]}}}"#,
              [.status, .set])
    }
    func testErrorResponses() {
        let all: [Response.Expectation] = [.hello, .reveal, .status, .set, .log, .unpair]
        check(.error(.unsupportedVersion), #"{"v":1,"ok":false,"error":"unsupported_version","supported":[1]}"#, all)
        check(.error(.badRequest), #"{"v":1,"ok":false,"error":"bad_request"}"#, all)
        check(.error(.paused), #"{"v":1,"ok":false,"error":"paused"}"#, all)
        check(.error(.busy), #"{"v":1,"ok":false,"error":"busy"}"#, all)
        check(.error(.notPaired), #"{"v":1,"ok":false,"error":"not_paired"}"#, all)
    }

    // MARK: 接続コード

    func testPairingCode() throws {
        let code = PairingCode(id: PairingID(hex: id)!, secret: .counting, port: 47651,
                               addresses: ["Studio.local", "100.101.77.7"], expiresAt: 1_790_000_000)!
        let json = #"{"v":1,"id":"\#(id)","k":"\#(k)","p":47651,"a":["Studio.local","100.101.77.7"],"x":1790000000}"#
        let wire = "sharescale1:" + Base64URL.encode(Data(json.utf8))
        XCTAssertEqual(code.encoded(), wire)
        XCTAssertEqual(try PairingCode.decode(wire), code)
    }
}
