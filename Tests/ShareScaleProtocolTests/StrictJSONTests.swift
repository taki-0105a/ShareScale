import XCTest
@testable import ShareScaleProtocol

final class StrictJSONTests: XCTestCase {
    func p(_ s: String) throws -> JSONValue { try StrictJSON.parse(Data(s.utf8)) }

    func testTypesAreDistinct() throws {
        XCTAssertEqual(try p(#"{"a":1,"b":true,"c":"1","d":null,"e":[1,-2]}"#),
                       .object([("a", .integer(1)), ("b", .bool(true)), ("c", .string("1")), ("d", .null), ("e", .array([.integer(1), .integer(-2)]))]))
    }
    func testNonIntegerNumbersRejected() {
        for s in ["1.0", "1e0", "1E2", "-0.5", "01", "-", "1.", "00"] {
            XCTAssertThrowsError(try p(s), s)
        }
        XCTAssertEqual(try? p("0"), .integer(0))
        XCTAssertEqual(try? p("-0"), .integer(0))
    }
    func testIntegerOverflowRejected() {
        XCTAssertThrowsError(try p("9223372036854775808"))
        XCTAssertEqual(try? p("9223372036854775807"), .integer(Int64.max))
    }
    func testDuplicateKeyRejected() {
        XCTAssertThrowsError(try p(#"{"v":1,"v":1}"#)) { XCTAssertEqual($0 as? StrictJSONError, .duplicateKey("v")) }
        XCTAssertThrowsError(try p(#"{"a":{"x":1,"x":2}}"#))
    }
    func testStringsAndEscapes() throws {
        XCTAssertEqual(try p(#""a\"b\\c\/d\né😀""#), .string("a\"b\\c/d\né😀"))
        XCTAssertThrowsError(try p(#""\ud83d""#), "対になっていない上位サロゲート")
        XCTAssertThrowsError(try p(#""\ude00""#), "単独の下位サロゲート")
        XCTAssertThrowsError(try p(#""\x""#))
        XCTAssertThrowsError(try p("\"a\u{01}b\""), "生の制御文字")
        XCTAssertThrowsError(try p(#""\u12G4""#))
    }
    func testEncodingAndStructure() {
        XCTAssertThrowsError(try StrictJSON.parse(Data([0xEF, 0xBB, 0xBF] + Array("{}".utf8))), "BOM")
        XCTAssertThrowsError(try StrictJSON.parse(Data([0x22, 0xC3, 0x28, 0x22])), "壊れた UTF-8")
        XCTAssertThrowsError(try p("{} {}"), "続きのデータ")
        XCTAssertThrowsError(try p(#"{"a":1,}"#), "末尾のコンマ")
        XCTAssertThrowsError(try p("tru"))
        XCTAssertThrowsError(try p(""))
        XCTAssertThrowsError(try p(String(repeating: "[", count: 10) + String(repeating: "]", count: 10)), "深すぎる")
        XCTAssertNoThrow(try p(String(repeating: "[", count: 9) + String(repeating: "]", count: 9)))
    }
    func testWriterRoundTrip() throws {
        let v: JSONValue = .object([("s", .string("改行\n\"引用\"\u{01}\u{2028}")), ("n", .integer(-5)), ("b", .bool(false)), ("z", .null), ("a", .array([]))])
        let text = JSONWriter.write(v)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertEqual(try p(text), v)
        XCTAssertEqual(JSONWriter.write(.object([("v", .integer(1)), ("ok", .bool(true))])), #"{"v":1,"ok":true}"#)
    }
    func testMembersAndExactKeys() {
        let v: JSONValue = .object([("a", .integer(1)), ("b", .null)])
        XCTAssertEqual(v.members(), ["a": .integer(1), "b": .null])
        XCTAssertEqual(v.exactKeys(["a", "b"]), ["a": .integer(1), "b": .null])
        XCTAssertNil(v.exactKeys(["a"]), "余分なキー")
        XCTAssertNil(v.exactKeys(["a", "b", "c"]), "足りないキー")
        XCTAssertNil(JSONValue.array([]).members(), "オブジェクトでない")
        let dup: JSONValue = .object([("a", .integer(1)), ("a", .integer(2))])
        XCTAssertNil(dup.members(), "手で作った同じキーは落ちずに nil")
        XCTAssertNil(dup.exactKeys(["a"]))
    }
    func testLineFraming() {
        XCTAssertEqual(LineFraming.extract(Data("abc".utf8), limit: 10), .needMore)
        XCTAssertEqual(LineFraming.extract(Data("abc\n".utf8), limit: 10), .line(Data("abc".utf8)))
        XCTAssertEqual(LineFraming.extract(Data("abc\r\n".utf8), limit: 10), .reject(.carriageReturn))
        XCTAssertEqual(LineFraming.extract(Data("abc\nx".utf8), limit: 10), .reject(.bytesAfterNewline))
        XCTAssertEqual(LineFraming.extract(Data("123456789\n".utf8), limit: 10), .line(Data("123456789".utf8)))
        XCTAssertEqual(LineFraming.extract(Data("1234567890\n".utf8), limit: 10), .reject(.tooLarge))
        XCTAssertEqual(LineFraming.extract(Data("1234567890".utf8), limit: 10), .reject(.tooLarge))
    }
    func testLineFramingOnSlices() {
        // 受け取ったバイトを切り出した Data は startIndex が 0 でない
        let whole = Data("xxabc\n".utf8)
        let slice = whole[2...]
        XCTAssertEqual(slice.startIndex, 2)
        guard case let .line(line) = LineFraming.extract(slice, limit: 10) else { return XCTFail() }
        XCTAssertEqual(line, Data("abc".utf8))
        XCTAssertEqual(line.startIndex, 0, "取り出した 1 行は 0 から始まる")
        XCTAssertEqual(LineFraming.extract(Data("xxabc".utf8)[2...], limit: 10), .needMore)
        XCTAssertEqual(LineFraming.extract(Data("xx12345".utf8)[2...], limit: 5), .reject(.tooLarge), "上限は切り出した分の長さで数える")
        XCTAssertEqual(LineFraming.extract(Data("xx1234".utf8)[2...], limit: 5), .needMore)
        XCTAssertEqual(LineFraming.extract(Data("xx1234\n".utf8)[2...], limit: 5), .line(Data("1234".utf8)))
        XCTAssertEqual(LineFraming.extract(Data("\nxab\n".utf8)[2...], limit: 10), .line(Data("ab".utf8)), "切り出す前の改行は見ない")
        XCTAssertEqual(LineFraming.extract(Data("xxa\nb".utf8)[2...], limit: 10), .reject(.bytesAfterNewline))
        XCTAssertEqual(LineFraming.extract(Data("xxa\r\n".utf8)[2...], limit: 10), .reject(.carriageReturn))
    }
}
