import XCTest
@testable import ShareScaleProtocol

extension Bytes32 {
    /// 試験で使う決まった値
    static func filled(_ b: UInt8) -> Bytes32 { Bytes32(Data(repeating: b, count: 32))! }
    static let counting = Bytes32(Data(0..<32))!   // 0〜31
}

final class Bytes32Tests: XCTestCase {
    func testExactly32Bytes() {
        XCTAssertNil(Bytes32(Data()))
        XCTAssertNil(Bytes32(Data(0..<31)))
        XCTAssertNil(Bytes32(Data(0..<33)))
        XCTAssertEqual(Bytes32(Data(0..<32))?.data, Data(0..<32))
    }
    func testSlicesAreRebased() {
        let whole = Data(0..<40)
        let b = Bytes32(whole[8..<40])
        XCTAssertEqual(b?.data, Data(8..<40))
        XCTAssertEqual(b?.data.startIndex, 0, "中身は 0 から始まる Data で持つ")
        XCTAssertEqual(b, Bytes32(Data(8..<40)), "切り出しかどうかで等しさが変わらない")
    }
    func testEquality() {
        XCTAssertEqual(Bytes32.filled(1), Bytes32.filled(1))
        XCTAssertNotEqual(Bytes32.filled(1), Bytes32.filled(2))
        var d = Data(repeating: 1, count: 32); d[31] = 0
        XCTAssertNotEqual(Bytes32.filled(1), Bytes32(d)!)
        XCTAssertEqual(Set([Bytes32.filled(1), .filled(1), .filled(2)]).count, 2)
    }
    func testBase64URL() {
        XCTAssertEqual(Bytes32.counting.base64URL, "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        XCTAssertEqual(Bytes32(base64URL: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"), .counting)
        XCTAssertNil(Bytes32(base64URL: "AAAA"), "32 バイトでない")
        XCTAssertNil(Bytes32(base64URL: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="), "パディング付き")
    }
    func testRandomIs32FreshBytes() {
        let a = Bytes32.random(), b = Bytes32.random()
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b, "毎回違う")
    }
}
