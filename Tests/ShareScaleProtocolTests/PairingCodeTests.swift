import XCTest
@testable import ShareScaleProtocol

final class PairingCodeTests: XCTestCase {
    let sample = PairingCode(id: .sample, secret: .counting, port: 47651,
                             addresses: ["Studio.local", "100.101.77.7"], expiresAt: 1_790_000_000)!

    func encodeRaw(_ json: String) -> String { PairingCode.prefix + Base64URL.encode(Data(json.utf8)) }
    let k = Base64URL.encode(Data(0..<32))

    func testRoundTrip() throws {
        let text = sample.encoded()
        XCTAssertTrue(text.hasPrefix("sharescale1:"))
        XCTAssertEqual(try PairingCode.decode("  " + text + "\n"), sample)
    }
    func testRejections() {
        func expect(_ json: String, _ e: PairingCode.Invalid, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try PairingCode.decode(encodeRaw(json)), file: file, line: line) {
                XCTAssertEqual($0 as? PairingCode.Invalid, e, json, file: file, line: line)
            }
        }
        let id = "00112233445566778899aabbccddeeff"
        expect(#"{"v":2,"id":"\#(id)","k":"\#(k)","p":1,"a":["a.local"],"x":0}"#, .badVersion)
        expect(#"{"v":true,"id":"\#(id)","k":"\#(k)","p":1,"a":["a.local"],"x":0}"#, .badVersion)
        expect(#"{"v":1,"id":"\#(id.uppercased())","k":"\#(k)","p":1,"a":["a.local"],"x":0}"#, .badID)
        expect(#"{"v":1,"id":"0011","k":"\#(k)","p":1,"a":["a.local"],"x":0}"#, .badID)
        expect(#"{"v":1,"id":"\#(id)","k":"AAAA","p":1,"a":["a.local"],"x":0}"#, .badSecret)
        expect(#"{"v":1,"id":"\#(id)","k":"\#(k)","p":0,"a":["a.local"],"x":0}"#, .badPort)
        expect(#"{"v":1,"id":"\#(id)","k":"\#(k)","p":65536,"a":["a.local"],"x":0}"#, .badPort)
        expect(#"{"v":1,"id":"\#(id)","k":"\#(k)","p":1.0,"a":["a.local"],"x":0}"#, .badJSON)
        expect(#"{"v":1,"id":"\#(id)","k":"\#(k)","p":1,"a":[],"x":0}"#, .badAddresses)
        expect(#"{"v":1,"id":"\#(id)","k":"\#(k)","p":1,"a":["[fe80::1]"],"x":0}"#, .badAddresses)
        expect(#"{"v":1,"id":"\#(id)","k":"\#(k)","p":1,"a":["a","b","c","d","e","f","g","h","i"],"x":0}"#, .badAddresses)
        expect(#"{"v":1,"id":"\#(id)","k":"\#(k)","p":1,"a":["a.local"],"x":"0"}"#, .badExpiry)
        expect(#"{"v":1,"id":"\#(id)","k":"\#(k)","p":1,"a":["a.local"]}"#, .unknownOrMissingKey)
        expect(#"{"v":1,"id":"\#(id)","k":"\#(k)","p":1,"a":["a.local"],"x":0,"z":1}"#, .unknownOrMissingKey)
        expect(#"{"v":1,"v":1,"id":"\#(id)","k":"\#(k)","p":1,"a":["a.local"],"x":0}"#, .badJSON)
        XCTAssertThrowsError(try PairingCode.decode("sharescale2:AAAA")) { XCTAssertEqual($0 as? PairingCode.Invalid, .notSharescale) }
        XCTAssertThrowsError(try PairingCode.decode("sharescale1:AA==")) { XCTAssertEqual($0 as? PairingCode.Invalid, .badEncoding) }
        XCTAssertThrowsError(try PairingCode.decode("sharescale1:" + String(repeating: "A", count: 1100))) { XCTAssertEqual($0 as? PairingCode.Invalid, .tooLarge) }
    }
    func testExpiryIsOnlyAWarning() {
        XCTAssertFalse(sample.probablyExpired(now: sample.expiresAt + 599))
        XCTAssertTrue(sample.probablyExpired(now: sample.expiresAt + 600), "10 分以上過ぎていれば注意")
    }
    func testExtremeExpiryDoesNotCrash() {
        let now: Int64 = 1_790_000_000
        func code(_ x: Int64) -> PairingCode { PairingCode(id: sample.id, secret: sample.secret, port: 1, addresses: ["a.local"], expiresAt: x)! }
        XCTAssertFalse(code(.max).probablyExpired(now: now))
        XCTAssertTrue(code(.min).probablyExpired(now: now))
        XCTAssertEqual(try PairingCode.decode(code(.max).encoded()).expiresAt, .max)
    }
}
