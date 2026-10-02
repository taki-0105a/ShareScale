import XCTest
@testable import ShareScaleProtocol

final class ManualEntryTests: XCTestCase {
    let id = PairingID.sample
    let secret = Bytes32.counting
    // 期待値は Python で独立に計算したもの
    let expected = "008J4CT4ANK7F24SNAXWSQFEZW0020G30G2GC1R81450P30D1R7H048J2CA1A5GQ30CHM6RW3MF1Y" + "6"

    func testEncodeKnownAnswer() {
        let key = ManualEntry.encodeKey(id: id, secret: secret)
        XCTAssertEqual(key, expected)
        XCTAssertEqual(key.count, 78)
    }
    func testDecodeForgiving() throws {
        let grouped = ManualEntry.grouped(expected)
        XCTAssertTrue(grouped.hasPrefix("008J 4CT4 "))
        let r = try ManualEntry.decodeKey(grouped.lowercased().replacingOccurrences(of: "1", with: "l").replacingOccurrences(of: "0", with: "o"))
        XCTAssertEqual(r.id, id); XCTAssertEqual(r.secret, secret)
        let fullWidth = expected.map { c -> String in
            guard let a = c.asciiValue, a >= 0x21, a <= 0x7E else { return String(c) }
            return String(UnicodeScalar(UInt32(a) + 0xFEE0)!)
        }.joined()
        XCTAssertEqual(try ManualEntry.decodeKey("  " + fullWidth + " ").secret, secret, "全角")
        XCTAssertEqual(try ManualEntry.decodeKey(expected.replacingOccurrences(of: "4", with: "4-")).id, id, "ハイフン")
    }
    func testDecodeRejects() {
        var typo = Array(expected); typo[10] = typo[10] == "A" ? "B" : "A"
        XCTAssertThrowsError(try ManualEntry.decodeKey(String(typo))) { XCTAssertEqual($0 as? ManualEntry.KeyError, .checksumMismatch) }
        XCTAssertThrowsError(try ManualEntry.decodeKey(String(expected.dropLast()))) { XCTAssertEqual($0 as? ManualEntry.KeyError, .badLength) }
        XCTAssertThrowsError(try ManualEntry.decodeKey("U" + expected.dropFirst())) { XCTAssertEqual($0 as? ManualEntry.KeyError, .badCharacter) }
        var pad = Array(expected); pad[76] = "Z"   // 最後の文字の余りのビットが立つ
        XCTAssertThrowsError(try ManualEntry.decodeKey(String(pad))) { XCTAssertEqual($0 as? ManualEntry.KeyError, .badPadding) }
    }
    func testChecksumCatchesEverySingleSubstitution() {
        let chars = Array(expected)
        for i in 0..<77 {
            for c in ManualEntry.alphabet where c != chars[i] {
                var t = chars; t[i] = c
                guard let r = try? ManualEntry.decodeKey(String(t)) else { continue }
                XCTFail("位置 \(i) を \(c) にした誤りを見逃した: \(r.id)")
            }
        }
    }
    func testAddress() throws {
        XCTAssertTrue(try ManualEntry.parseAddress("Studio.local") == ("Studio.local", 47651))
        XCTAssertTrue(try ManualEntry.parseAddress(" 100.101.77.7:5000 ") == ("100.101.77.7", 5000))
        XCTAssertTrue(try ManualEntry.parseAddress("[fd7a:115c:a1e0::1]:47651") == ("fd7a:115c:a1e0::1", 47651))
        XCTAssertTrue(try ManualEntry.parseAddress("[fd7a:115c:a1e0::1]") == ("fd7a:115c:a1e0::1", 47651))
        XCTAssertTrue(try ManualEntry.parseAddress("１００.１０１.７７.７") == ("100.101.77.7", 47651), "全角")
        XCTAssertThrowsError(try ManualEntry.parseAddress("fd7a::1")) { XCTAssertEqual($0 as? ManualEntry.AddressError, .ipv6NeedsBrackets) }
        XCTAssertThrowsError(try ManualEntry.parseAddress("a.local:0")) { XCTAssertEqual($0 as? ManualEntry.AddressError, .badPort) }
        XCTAssertThrowsError(try ManualEntry.parseAddress("a.local:65536"))
        XCTAssertThrowsError(try ManualEntry.parseAddress("a.local:"))
        XCTAssertThrowsError(try ManualEntry.parseAddress("[fe80::1%en0]"))
        XCTAssertThrowsError(try ManualEntry.parseAddress("[10.0.0.1]"))
        XCTAssertThrowsError(try ManualEntry.parseAddress(""))
    }
}
