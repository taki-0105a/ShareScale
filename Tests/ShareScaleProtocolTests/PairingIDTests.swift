import XCTest
@testable import ShareScaleProtocol

extension PairingID {
    /// 試験で使う決まった ID
    static let sample = PairingID(hex: "00112233445566778899aabbccddeeff")!
}

final class PairingIDTests: XCTestCase {
    func testHexRoundTrip() {
        let id = PairingID(hex: "00112233445566778899aabbccddeeff")
        XCTAssertEqual(id?.hex, "00112233445566778899aabbccddeeff")
        XCTAssertEqual(id?.bytes, [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
        XCTAssertEqual(PairingID(bytes: Array(0..<16))?.hex, "000102030405060708090a0b0c0d0e0f")
    }
    func testRejectsAnythingButExactly32LowercaseHex() {
        let good = "00112233445566778899aabbccddeeff"
        let tail = String(good.dropFirst()), head = String(good.dropLast())
        let bads: [String] = ["", good.uppercased(), head, good + "0", "0x" + String(good.dropFirst(2)),
                              "g" + tail, "+" + tail, " " + tail, head + "\u{0}", "０" + tail]
        for bad in bads {
            XCTAssertNil(PairingID(hex: bad), bad.debugDescription)
        }
    }
    func testBytesMustBe16() {
        XCTAssertNil(PairingID(bytes: Array(repeating: 1, count: 15)))
        XCTAssertNil(PairingID(bytes: Array(repeating: 1, count: 17)))
        XCTAssertNil(PairingID(bytes: []))
    }
}
