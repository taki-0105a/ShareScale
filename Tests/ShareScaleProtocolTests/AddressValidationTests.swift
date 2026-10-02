import XCTest
@testable import ShareScaleProtocol

/// アドレスの字句の確認: 使える文字の限定（NUL などで読み取りを止めさせない）、候補アドレスは書き直した形だけ、
/// IPv4 として読まれるホスト名の拒否、バイトからの作り方、手入力の書き直し
final class AddressValidationTests: XCTestCase {
    func testNULAndOtherCharactersCannotSmuggleText() {
        for s in ["1.2.3.4\u{0}evil.example", "fd7a::1\u{0}x", "1.2.3.4 ", "1.2.3.4\n", "fd7a::1\u{0}", "1.2.3.4%en0"] {
            XCTAssertNil(IPAddress(s), s.debugDescription)
            XCTAssertFalse(CandidateAddress.isValid(s), s.debugDescription)
        }
        XCTAssertNotNil(IPAddress("fe80::1%en0"), "IPv6 のゾーンは除いて読む")
        XCTAssertNil(IPAddress("fe80::1%en0\u{0}x"))
        XCTAssertNil(IPAddress("fe80::1%"))
    }
    func testPairingCodeWithNULAddressRejected() {
        let json = #"{"v":1,"id":"00112233445566778899aabbccddeeff","k":"\#(Base64URL.encode(Data(0..<32)))","p":1,"a":["1.2.3.4\u0000evil.example"],"x":0}"#
        XCTAssertThrowsError(try PairingCode.decode(PairingCode.prefix + Base64URL.encode(Data(json.utf8))))
    }
    func testCandidatesMustBeCanonical() {
        XCTAssertTrue(CandidateAddress.isValid("fd7a:115c:a1e0::1"))
        XCTAssertFalse(CandidateAddress.isValid("FD7A:115C:A1E0::1"), "IP は書き直した形と同じ時だけ（表示と接続先を一致させる）")
        XCTAssertFalse(CandidateAddress.isValid("fd7a:115c:a1e0:0:0:0:0:1"))
        XCTAssertFalse(CandidateAddress.isValid("::ffff:1.2.3.4"), "IPv4-mapped は IPv4 で書く")
        XCTAssertTrue(CandidateAddress.isValid("1.2.3.4"))
    }
    func testNumericLookingHostnamesRejected() {
        for s in ["0x7f.1", "0x7f000001", "a.123", "2130706433", "host.0X1f", "1.2.3"] {
            XCTAssertFalse(CandidateAddress.isValid(s), s)
        }
        XCTAssertTrue(CandidateAddress.isValid("mac-studio.local"))
        XCTAssertTrue(CandidateAddress.isValid("a1.b2c"), "最後のラベルが数字だけでなければよい")
    }
    func testCandidateLists() {
        XCTAssertTrue(CandidateAddress.isValidList(["a.local"]))
        XCTAssertTrue(CandidateAddress.isValidList((1...8).map { "h\($0).local" }))
        XCTAssertFalse(CandidateAddress.isValidList([]), "0 件")
        XCTAssertFalse(CandidateAddress.isValidList((1...9).map { "h\($0).local" }), "9 件")
        XCTAssertFalse(CandidateAddress.isValidList(["a.local", "FD7A::1"]), "1 件でも正しくなければ")
    }
    func testBytesMustHaveTheRightLength() {
        XCTAssertNil(IPAddress(bytes: [1, 2, 3]))
        XCTAssertNil(IPAddress(bytes: [UInt8](repeating: 1, count: 5)))
        XCTAssertEqual(IPAddress(bytes: [10, 0, 0, 1])?.text, "10.0.0.1")
        XCTAssertEqual(IPAddress(bytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1]), IPAddress(bytes: [10, 0, 0, 1]), "IPv4-mapped は IPv4 に直す")
    }
    func testManualAddressIsCanonicalized() throws {
        XCTAssertEqual(try ManualEntry.parseAddress("[FD7A:115C:A1E0::1]").host, "fd7a:115c:a1e0::1")
        XCTAssertThrowsError(try ManualEntry.parseAddress("0x7f.1"))
    }
    func testRequestReaderNeverCrashesOnHandMadeDuplicateKeys() {
        let body = JSONValue.object([("v", .integer(1)), ("op", .string("status")), ("op", .string("log"))])
        XCTAssertNil(RequestReader.request(body, first: true))
    }
}
