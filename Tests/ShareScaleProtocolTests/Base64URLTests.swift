import XCTest
@testable import ShareScaleProtocol

final class Base64URLTests: XCTestCase {
    func testRoundTripAllLengths() {
        for n in 0...40 {
            let data = Data((0..<n).map { UInt8(($0 * 37 + 11) & 0xff) })
            let text = Base64URL.encode(data)
            XCTAssertFalse(text.contains("=") || text.contains("+") || text.contains("/"))
            XCTAssertEqual(Base64URL.decode(text), data, "長さ \(n)")
        }
    }
    func testKnownValue() {
        XCTAssertEqual(Base64URL.encode(Data([0xfb, 0xff, 0xbf])), "-_-_")
        XCTAssertEqual(Base64URL.decode("-_-_"), Data([0xfb, 0xff, 0xbf]))
    }
    func testRejectsNonCanonical() {
        XCTAssertNil(Base64URL.decode("AA=="), "パディング付き")
        XCTAssertNil(Base64URL.decode("+/+/"), "標準の base64 の文字")
        XCTAssertNil(Base64URL.decode("AAA A"), "空白")
        XCTAssertNil(Base64URL.decode("A"), "余り 1")
        XCTAssertNil(Base64URL.decode("AB"), "最後の文字に余りのビット（正しくは AA）")
        XCTAssertNotNil(Base64URL.decode("AA"))
    }
    func testByteCount() {
        let d = Data(repeating: 7, count: 32)
        XCTAssertEqual(Base64URL.decode(Base64URL.encode(d), byteCount: 32), d)
        XCTAssertNil(Base64URL.decode(Base64URL.encode(d), byteCount: 31))
    }
}
