import XCTest
@testable import ShareScaleProtocol

final class NameRulesTests: XCTestCase {
    func testValidNames() {
        XCTAssertEqual(NameRules.validate("居間のMacBook Pro"), "居間のMacBook Pro")
        XCTAssertEqual(NameRules.validate("Cafe\u{301}"), "Café", "NFC にする")
        XCTAssertEqual(NameRules.validate(String(repeating: "a", count: 64)), String(repeating: "a", count: 64))
    }
    func testRejected() {
        XCTAssertNil(NameRules.validate(""))
        XCTAssertNil(NameRules.validate(String(repeating: "a", count: 65)), "65 スカラー")
        XCTAssertNil(NameRules.validate(String(repeating: "あ", count: 43)), "129 バイト")
        XCTAssertNotNil(NameRules.validate(String(repeating: "あ", count: 42)), "126 バイト")
        XCTAssertNil(NameRules.validate("a\nb"), "改行（Cc）")
        XCTAssertNil(NameRules.validate("a\u{202E}b"), "双方向の上書き（Cf）")
        XCTAssertNil(NameRules.validate("a\u{2028}b"), "行区切り（Zl）")
        XCTAssertNil(NameRules.validate("a\u{2029}b"), "段落区切り（Zp）")
        XCTAssertNil(NameRules.validate("a\u{200B}b"), "ゼロ幅の空白（Cf）")
        XCTAssertNil(NameRules.validate("e" + String(repeating: "\u{301}", count: 70)), "結合文字の積み重ね")
    }
    func testSanitize() {
        XCTAssertEqual(NameRules.sanitize("My\u{202E}Mac\n"), "MyMac")
        XCTAssertEqual(NameRules.sanitize("\u{200B}\n"), "Mac")
        XCTAssertEqual(NameRules.sanitize(String(repeating: "あ", count: 100)), String(repeating: "あ", count: 42))
        XCTAssertNotNil(NameRules.validate(NameRules.sanitize("e" + String(repeating: "\u{301}", count: 70))))
        XCTAssertEqual(TextRules.stripControls("a\u{1B}[31mb\u{202E}"), "a[31mb")
    }
}

final class AppVersionTests: XCTestCase {
    func testParseAndBundleVersion() {
        XCTAssertEqual(AppVersion("1.2.3")?.bundleVersion, 10203)
        XCTAssertEqual(AppVersion("0.0.0")?.bundleVersion, 0)
        XCTAssertEqual(AppVersion("99.99.99")?.bundleVersion, 999999)
        XCTAssertEqual(AppVersion("1.10.0\n")?.shortString, "1.10.0")
    }
    func testRejected() {
        for s in ["1.2", "1.2.3.4", "1.100.0", "1.02.0", "a.b.c", "1..3", "-1.2.3", "１.2.3", ""] {
            XCTAssertNil(AppVersion(s), s)
        }
    }
    func testOrderingMatchesComponents() {
        XCTAssertLessThan(AppVersion("1.9.9")!, AppVersion("1.10.0")!)
        XCTAssertLessThan(AppVersion("1.2.3")!, AppVersion("2.0.0")!)
        XCTAssertEqual(AppVersion("1.2.3"), AppVersion("1.2.3"))
    }
}
